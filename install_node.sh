#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v4.0 - Node Installer (Docker Compose + NAT Support + 静默版)
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASE_DIR}/topology.env"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
WARN='\033[1;33m'

echo "=========================================================="
echo " 正在识别节点身份并配置环境..."
echo "=========================================================="

# 1. 角色识别 (Identity Check)
# ------------------------------------------------------------------------------
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
MY_IP=""
MY_ID=0

# [自动匹配]
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    MY_ROLE="MASTER"; MY_IP="$NODE_1_IP"
elif [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then
    MY_ROLE="SLAVE";  MY_IP="$NODE_2_IP"
elif [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then
    MY_ROLE="SLAVE";  MY_IP="$NODE_3_IP"
fi

# [手动匹配] NAT 环境支持
if [ "$MY_ROLE" == "UNKNOWN" ]; then
    echo -e "${WARN}[WARN] 无法通过本地 IP (${LOCAL_IPS}) 自动识别本机角色。${NC}"
    echo "检测到可能处于公有云 NAT 环境。"
    echo ""
    echo "请手动选择本机是哪一个节点 (根据 topology.env 配置):"
    echo " 1) Node-1 (Master): ${NODE_1_IP}"
    echo " 2) Node-2 (Slave):  ${NODE_2_IP}"
    echo " 3) Node-3 (Slave):  ${NODE_3_IP}"
    echo "----------------------------------------------------------"
    
    # 强制从 tty 读取
    read -p "请输入序号 (1/2/3): " NODE_IDX < /dev/tty
    
    case "$NODE_IDX" in
        1) MY_ROLE="MASTER"; MY_IP="$NODE_1_IP" ;;
        2) MY_ROLE="SLAVE";  MY_IP="$NODE_2_IP";;
        3) MY_ROLE="SLAVE";  MY_IP="$NODE_3_IP" ;;
        *) echo "无效输入，退出。"; exit 1 ;;
    esac
fi

# 生成 Server ID (取 IP 最后一段)
MY_ID=$(echo "$MY_IP" | awk -F. '{print $4}')

echo "----------------------------------------------------------"
echo -e " 节点角色: ${GREEN}${MY_ROLE}${NC}"
echo -e " 节点 IP:  ${GREEN}${MY_IP}${NC} (ServerID: ${MY_ID})"
echo "----------------------------------------------------------"

# 2. 静默获取密码 (v4.0 核心)
# ------------------------------------------------------------------------------
if [ -f "${BASE_DIR}/.secrets.env" ]; then
    source "${BASE_DIR}/.secrets.env"
else
    echo -e "${RED}[ERROR] 未找到 .secrets.env，凭据传递失败！请先运行 bootstrap.sh${NC}"
    exit 1
fi

export DB_ROOT_PASS="${AUTO_DB_ROOT_PASS}"
export PROXY_ADMIN_PASS="${AUTO_PROXY_ADMIN_PASS}"
export MY_ID
export MY_IP

echo -e "${BLUE}[INFO] 核心凭据已静默加载，准备部署容器组...${NC}"

# 3. 生成 docker-compose.yml
# ------------------------------------------------------------------------------
cat <<YAML > docker-compose.yml
services:
  mariadb:
    image: ${MARIADB_IMAGE}
    container_name: mariadb
    restart: always
    network_mode: "host"
    environment:
      MARIADB_ROOT_PASSWORD: "\${DB_ROOT_PASS}"
      MYSQL_INITDB_SKIP_TZINFO: "yes"
    command: >
      --port=${DB_PORT}
      --server-id=${MY_ID}
      --log-bin=mysql-bin
      --binlog-format=ROW
      --gtid-strict-mode=ON
      --log-slave-updates=ON
      --bind-address=0.0.0.0
    volumes:
      - ./data/mysql:/var/lib/mysql
      - ./conf/my.cnf:/etc/mysql/conf.d/custom.cnf

  proxysql:
    image: ${PROXYSQL_IMAGE}
    container_name: proxysql
    restart: always
    network_mode: "host"
    depends_on:
      - mariadb
    volumes:
      - proxysql_data:/var/lib/proxysql
    environment:
      DB_cluster_nodes: "${NODE_1_IP},${NODE_2_IP},${NODE_3_IP}"

  adminer:
    image: ${ADMINER_IMAGE}
    container_name: adminer
    restart: always
    network_mode: "host"
    environment:
      ADMINER_DEFAULT_SERVER: 127.0.0.1

volumes:
  proxysql_data:
YAML

# 4. 启动容器
# ------------------------------------------------------------------------------
echo -e "${BLUE}[INFO] 启动 MariaDB (${MARIADB_IMAGE})...${NC}"
echo -e "${BLUE}[INFO] 启动 ProxySQL Sidecar (${PROXYSQL_IMAGE})...${NC}"

# 强制重建
docker compose down >/dev/null 2>&1 || true
docker compose up -d

echo ""
echo -e "${GREEN}[INFO] v4.0 (Sidecar模式) 安装完成！${NC}"
echo "----------------------------------------------------------"
echo " [业务接入指南] 请在您的应用程序中使用以下配置:"
echo "   Host: 127.0.0.1 (或本机内网IP)"
echo "   Port: ${PROXY_QUERY_PORT}      (ProxySQL 读写分离入口)"
echo "   User: app"
echo "   Pass: app_pass"
echo "----------------------------------------------------------"