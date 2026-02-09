#!/usr/bin/env bash
set -euo pipefail

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
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
MY_IP=""

# 尝试自动匹配 (适用于拥有公网 IP 或内网直通的机器)
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

# [核心修复] 如果自动匹配失败 (通常是云服务器 NAT 环境)，则手动询问
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
        1)
            MY_ROLE="MASTER"
            MY_IP="$NODE_1_IP"
            ;;
        2)
            MY_ROLE="SLAVE"
            MY_IP="$NODE_2_IP"
            ;;
        3)
            MY_ROLE="SLAVE"
            MY_IP="$NODE_3_IP"
            ;;
        *)
            echo "无效输入，退出。"
            exit 1
            ;;
    esac
fi

# 使用配置中的 IP (公网IP) 的最后一段作为 Server ID
SERVER_ID=$(echo "$MY_IP" | awk -F. '{print $4}')

echo "=========================================================="
echo -e " 节点角色: ${GREEN}${MY_ROLE}${NC}"
echo -e " 节点 IP:  ${GREEN}${MY_IP}${NC} (ServerID: ${SERVER_ID})"
echo "=========================================================="
echo ""

# 2. 安全交互：获取密码
echo ">>> 请输入集群密码 (输入不显示)"
echo "----------------------------------------------------------"

# 强制从 tty 读取
read -s -p "1. 输入 Root 密码 (DB_ROOT_PASS): " ROOT_PASS < /dev/tty
echo ""
if [ -z "$ROOT_PASS" ]; then echo "密码不能为空"; exit 1; fi

if [ "$MY_ROLE" == "MASTER" ]; then
    read -s -p "2. 输入 ProxySQL Admin 密码:      " PROXY_ADMIN_PASS < /dev/tty
    echo ""
fi

echo "----------------------------------------------------------"
log "密码已读入内存，准备部署..."

# 3. 清理旧容器
docker rm -f mariadb proxysql adminer >/dev/null 2>&1 || true

# 4. 部署 MariaDB (所有节点)
log "启动 MariaDB (${MARIADB_IMAGE})..."

# [Docker 语法修复] 镜像名放在中间，参数放在最后
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

# 5. 部署中间件 (仅 Master)
if [ "$MY_ROLE" == "MASTER" ]; then
    log "启动 Adminer (${ADMINER_IMAGE})..."
    docker run -d \
        --name adminer \
        --restart unless-stopped \
        -p ${ADMINER_PORT}:8080 \
        "${ADMINER_IMAGE}" >/dev/null
        
    log "启动 ProxySQL (${PROXYSQL_IMAGE})..."
    docker run -d \
        --name proxysql \
        --restart unless-stopped \
        -p ${PROXY_ADMIN_PORT}:6032 \
        -p ${PROXY_QUERY_PORT}:6033 \
        "${PROXYSQL_IMAGE}" >/dev/null
fi

echo ""
log "安装完成！请确保防火墙已放行端口 ${DB_PORT}。"
if [ "$MY_ROLE" == "MASTER" ]; then
    echo "   - ProxySQL Admin: ${PROXY_ADMIN_PORT}"
    echo "   - ProxySQL Query: ${PROXY_QUERY_PORT}"
    echo "   - Adminer UI:     ${ADMINER_PORT}"
fi