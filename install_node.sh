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

if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    MY_ROLE="MASTER"
    MY_IP="$NODE_1_IP"
elif [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then
    MY_ROLE="SLAVE"
    MY_IP="$NODE_2_IP"
elif [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then
    MY_ROLE="SLAVE"
    MY_IP="$NODE_3_IP"
else
    warn "本机 IP (${LOCAL_IPS}) 未在 topology.env 中定义！"
    echo "请修改 topology.env 填入本机真实 IP。"
    exit 1
fi

# 2. 从 IP 生成唯一的 Server ID (取 IP 最后一段)
SERVER_ID=$(echo "$MY_IP" | awk -F. '{print $4}')

echo "=========================================================="
echo -e " 节点角色: ${GREEN}${MY_ROLE}${NC}"
echo -e " 节点 IP:  ${GREEN}${MY_IP}${NC} (ServerID: ${SERVER_ID})"
echo "=========================================================="
echo ""

# 3. 安全交互：获取密码
echo ">>> 请输入集群密码 (输入不显示)"
echo "----------------------------------------------------------"

read -s -p "1. 输入 Root 密码 (DB_ROOT_PASS): " ROOT_PASS
echo ""
if [ -z "$ROOT_PASS" ]; then echo "密码不能为空"; exit 1; fi

# Master 节点额外询问 ProxySQL 密码
if [ "$MY_ROLE" == "MASTER" ]; then
    read -s -p "2. 输入 ProxySQL Admin 密码:      " PROXY_ADMIN_PASS
    echo ""
fi

echo "----------------------------------------------------------"
log "密码已读入内存，准备部署..."

# 4. 清理旧容器
docker rm -f mariadb proxysql adminer >/dev/null 2>&1 || true

# 5. 部署 MariaDB (所有节点)
log "启动 MariaDB (${MARIADB_IMAGE})..."
docker run -d \
    --name mariadb \
    --restart unless-stopped \
    --network host \
    -e MYSQL_ROOT_PASSWORD="${ROOT_PASS}" \
    -e MYSQL_INITDB_SKIP_TZINFO=yes \
    --server-id="${SERVER_ID}" \
    --log-bin=mysql-bin \
    --binlog-format=ROW \
    --gtid-domain-id="${SERVER_ID}" \
    --bind-address=0.0.0.0 \
    "${MARIADB_IMAGE}" >/dev/null

# 6. 部署中间件 (仅 Master)
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

# 7. 防火墙提示
log "安装完成！请确保防火墙已放行端口 ${DB_PORT}。"
if [ "$MY_ROLE" == "MASTER" ]; then
    echo "   - ProxySQL Admin: ${PROXY_ADMIN_PORT}"
    echo "   - ProxySQL Query: ${PROXY_QUERY_PORT}"
    echo "   - Adminer UI:     ${ADMINER_PORT}"
fi
echo "=========================================================="
