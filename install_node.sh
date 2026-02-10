#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.0 - Node Installation Script (Sidecar Architecture)
# ==============================================================================

# 0. 基础环境加载
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${BASE_DIR}/topology.env" ]; then
    echo "Error: topology.env not found."
    exit 1
fi
source "${BASE_DIR}/topology.env"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${RED}[WARN]${NC} $1"; }

# 1. 角色识别 (Identity Check)
# ------------------------------------------------------------------------------
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
MY_IP=""

# [自动匹配] 适用于拥有公网 IP 或内网直通的机器
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    MY_ROLE="MASTER"
    MY_IP="$NODE_1_IP"
elif [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then
    MY_ROLE="SLAVE"
    MY_IP="$NODE_2_IP"
elif [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then
    MY_ROLE="SLAVE"
    MY_IP="$NODE_3_IP"
fi

# [手动匹配] 如果自动匹配失败 (通常是云服务器 NAT 环境)，则手动询问
if [ "$MY_ROLE" == "UNKNOWN" ]; then
    warn "无法通过本地 IP (${LOCAL_IPS}) 自动识别本机角色。"
    warn "检测到可能处于公有云 NAT 环境 (内网 IP 与配置的公网 IP 不一致)。"
    echo ""
    echo "请手动选择本机是哪一个节点 (根据 topology.env 配置):"
    echo " 1) Node-1 (Master): ${NODE_1_IP}"
    echo " 2) Node-2 (Slave):  ${NODE_2_IP}"
    echo " 3) Node-3 (Slave):  ${NODE_3_IP}"
    echo "----------------------------------------------------------"
    
    # 强制从 tty 读取输入，防止 curl 管道中断
    read -p "请输入序号 (1/2/3): " NODE_IDX < /dev/tty
    
    case "$NODE_IDX" in
        1) MY_ROLE="MASTER"; MY_IP="$NODE_1_IP" ;;
        2) MY_ROLE="SLAVE";  MY_IP="$NODE_2_IP" ;;
        3) MY_ROLE="SLAVE";  MY_IP="$NODE_3_IP" ;;
        *) echo "无效输入，退出。"; exit 1 ;;
    esac
fi

# 使用 IP 的最后一段作为 Server ID (确保唯一性)
SERVER_ID=$(echo "$MY_IP" | awk -F. '{print $4}')

echo "=========================================================="
echo -e " 节点角色: ${GREEN}${MY_ROLE}${NC}"
echo -e " 节点 IP:  ${GREEN}${MY_IP}${NC} (ServerID: ${SERVER_ID})"
echo "=========================================================="
echo ""

# 2. 安全交互：获取密码
# ------------------------------------------------------------------------------
echo ">>> 请输入集群密码 (输入不显示)"
echo "----------------------------------------------------------"

# 强制从 tty 读取
read -s -p "1. 输入 Root 密码 (DB_ROOT_PASS): " ROOT_PASS < /dev/tty
echo ""
if [ -z "$ROOT_PASS" ]; then echo "密码不能为空"; exit 1; fi

# [v3.0变更] 因为所有节点都要运行 ProxySQL，所以必须在所有节点都询问此密码
read -s -p "2. 输入 ProxySQL Admin 密码:      " PROXY_ADMIN_PASS < /dev/tty
echo ""
if [ -z "$PROXY_ADMIN_PASS" ]; then echo "密码不能为空"; exit 1; fi

echo "----------------------------------------------------------"
log "密码已读入内存，准备部署..."

# 3. 清理旧容器
# ------------------------------------------------------------------------------
# 为了防止旧版本残留，强制清理
docker rm -f mariadb proxysql adminer >/dev/null 2>&1 || true

# 4. 部署 MariaDB (所有节点)
# ------------------------------------------------------------------------------
log "启动 MariaDB (${MARIADB_IMAGE})..."

# 使用 host 网络模式，提升性能并避免端口映射麻烦
docker run -d \
    --name mariadb \
    --restart unless-stopped \
    --network host \
    -e MYSQL_ROOT_PASSWORD="${ROOT_PASS}" \
    -e MYSQL_INITDB_SKIP_TZINFO=yes \
    "${MARIADB_IMAGE}" \
    --server-id="${SERVER_ID}" \
    --log-bin=mysql-bin \
    --binlog-format=ROW \
    --gtid-domain-id="${SERVER_ID}" \
    --bind-address=0.0.0.0 >/dev/null

# 5. [v3.0核心] 部署 ProxySQL Sidecar (所有节点)
# ------------------------------------------------------------------------------
log "启动 ProxySQL Sidecar (${PROXYSQL_IMAGE})..."

# Sidecar 模式：每个节点都在本地运行一个路由层
# 业务程序直接连接 localhost:6033，由 ProxySQL 负责转发到后端真实的 Master
docker run -d \
    --name proxysql \
    --restart unless-stopped \
    --network host \
    -e DB_cluster_nodes="${NODE_1_IP},${NODE_2_IP},${NODE_3_IP}" \
    -e DB_root_password="${ROOT_PASS}" \
    -e PROXY_ADMIN_PASS="${PROXY_ADMIN_PASS}" \
    "${PROXYSQL_IMAGE}" >/dev/null

# 6. 部署 Adminer (仅 Master 可选)
# ------------------------------------------------------------------------------
# 只有 Master 节点需要提供 Web 管理界面，节省 Slave 资源
if [ "$MY_ROLE" == "MASTER" ]; then
    log "启动 Adminer (${ADMINER_IMAGE})..."
    docker run -d \
        --name adminer \
        --restart unless-stopped \
        -p ${ADMINER_PORT}:8080 \
        "${ADMINER_IMAGE}" >/dev/null
fi

# 7. 完成提示
# ------------------------------------------------------------------------------
echo ""
log "v3.0 (Sidecar模式) 安装完成！"
echo "----------------------------------------------------------"
echo " [业务接入指南] 请在您的应用程序中使用以下配置:"
echo -e "   Host: ${GREEN}127.0.0.1${NC} (或本机内网IP)"
echo -e "   Port: ${GREEN}6033${NC}      (ProxySQL 读写分离入口)"
echo "   User: app"
echo "   Pass: app_pass"
echo ""
echo " [架构说明]"
echo "   - 您的应用连接本地 ProxySQL，无需关心后端 Master 是谁。"
echo "   - 当发生故障转移时，本地 ProxySQL 会自动路由到新 Master。"
echo "----------------------------------------------------------"