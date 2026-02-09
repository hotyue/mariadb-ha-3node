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

# 2. 下载并解压 (覆盖模式)
curl -L -s "${REPO_URL}" | tar xz --strip-components=1

# 3. 赋予执行权限
chmod +x install_node.sh scripts/*.sh

echo -e "${GREEN}>>> 下载完成！${NC}"
echo "========================================================"
echo "   欢迎使用 MariaDB 高可用集群 (v2.0 分布式版) 安装向导"
echo "========================================================"
echo "请准备好 3 台服务器的内网 IP 地址。"
echo "本机将被自动识别并安装对应的角色 (Master 或 Slave)。"
echo "--------------------------------------------------------"

# 4. 交互式生成配置文件 (如果不存在)
CONF_FILE="topology.env"

if [ -f "${CONF_FILE}" ]; then
    echo -e "${BLUE}检测到配置文件已存在，跳过配置步骤。${NC}"
    echo "如果是配置错误，请删除 ${INSTALL_DIR}/${CONF_FILE} 后重试。"
else
    echo -e "${BLUE}>>> 请配置集群拓扑 (请输入真实 IP):${NC}"
    
    # 交互输入 IP
    read -p "1. 请输入 主节点 (Node-1) IP: " NODE_1
    while [[ -z "$NODE_1" ]]; do read -p "   IP不能为空，请重新输入: " NODE_1; done

    read -p "2. 请输入 从节点 (Node-2) IP: " NODE_2
    while [[ -z "$NODE_2" ]]; do read -p "   IP不能为空，请重新输入: " NODE_2; done

    read -p "3. 请输入 从节点 (Node-3) IP: " NODE_3
    while [[ -z "$NODE_3" ]]; do read -p "   IP不能为空，请重新输入: " NODE_3; done

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
fi

echo ""
echo -e "${BLUE}>>> 准备开始安装...${NC}"
echo "即将执行本地安装脚本..."
sleep 2

# 5. 调用核心安装脚本
./install_node.sh
