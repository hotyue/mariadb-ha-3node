#!/usr/bin/env bash
set -e

# ============================================================
# MariaDB HA v2.0 - 分布式集群一键安装向导
# ============================================================

REPO_URL="https://github.com/hotyue/mariadb-ha-3node/archive/refs/heads/main.tar.gz"
INSTALL_DIR="/opt/docker/mariadb-ha-v2"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}>>> 开始下载安装包...${NC}"

# 1. 准备目录
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# 2. 下载并解压
curl -L -s "${REPO_URL}" | tar xz --strip-components=1

# 3. 赋予执行权限
chmod +x install_node.sh scripts/*.sh

echo -e "${GREEN}>>> 下载完成！${NC}"
echo "========================================================"
echo "   欢迎使用 MariaDB 高可用集群 (v2.0 分布式版) 安装向导"
echo "========================================================"
echo "请准备好 3 台服务器的内网/公网 IP 地址。"
echo "本机将被自动识别并安装对应的角色 (Master 或 Slave)。"
echo "--------------------------------------------------------"

# 4. 交互式生成配置文件
CONF_FILE="topology.env"

# 逻辑：只要是从远程 curl 安装，我们就强制重新生成配置，防止旧配置干扰
echo -e "${BLUE}>>> 请配置集群拓扑 (请输入真实 IP):${NC}"

# [关键修复] 使用 < /dev/tty 强制从终端读取用户输入，兼容 curl | bash
read -p "1. 请输入 主节点 (Node-1) IP: " NODE_1 < /dev/tty
while [[ -z "$NODE_1" ]]; do read -p "   IP不能为空，请重新输入: " NODE_1 < /dev/tty; done

read -p "2. 请输入 从节点 (Node-2) IP: " NODE_2 < /dev/tty
while [[ -z "$NODE_2" ]]; do read -p "   IP不能为空，请重新输入: " NODE_2 < /dev/tty; done

read -p "3. 请输入 从节点 (Node-3) IP: " NODE_3 < /dev/tty
while [[ -z "$NODE_3" ]]; do read -p "   IP不能为空，请重新输入: " NODE_3 < /dev/tty; done

# 写入文件
cat <<EOC > "${CONF_FILE}"
# 自动生成的拓扑配置
NODE_1_IP="${NODE_1}"
NODE_2_IP="${NODE_2}"
NODE_3_IP="${NODE_3}"

# 端口配置
DB_PORT=3306
PROXY_ADMIN_PORT=6032
PROXY_QUERY_PORT=6033
ADMINER_PORT=8080

# 镜像版本
MARIADB_IMAGE="mariadb:latest"
PROXYSQL_IMAGE="proxysql/proxysql:latest"
ADMINER_IMAGE="adminer:latest"

# 账号定义
REPL_USER="repl_user"
APP_USER="app"
EOC

echo -e "${GREEN}>>> 配置已保存至 ${CONF_FILE}${NC}"
echo ""

# 5. 调用核心安装脚本
echo -e "${BLUE}>>> 准备开始安装...${NC}"
sleep 1
./install_node.sh
