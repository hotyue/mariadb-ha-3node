#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.0 - Bootstrap (One-Click Installer)
# ==============================================================================

# 配置
BRANCH="dev-v3"
REPO="mariadb-ha-3node"
DOWNLOAD_URL="https://github.com/hotyue/$REPO/archive/refs/heads/$BRANCH.tar.gz"
INSTALL_DIR="/opt/docker/mariadb-ha"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}>>> [1/4] 正在下载安装包 ($BRANCH)...${NC}"

# 使用临时目录处理下载，保持环境整洁
TEMP_DIR=$(mktemp -d)
curl -L -k "$DOWNLOAD_URL" -o "$TEMP_DIR/ha.tar.gz"
tar -xzf "$TEMP_DIR/ha.tar.gz" -C "$TEMP_DIR"

# 准备标准安装目录
mkdir -p /opt/docker
if [ -d "$INSTALL_DIR" ]; then
    echo "备份旧目录..."
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
fi

# 移动解压后的文件 (通常解压出的目录名为 repo-branch)
mv "$TEMP_DIR/$REPO-$BRANCH" "$INSTALL_DIR"
rm -rf "$TEMP_DIR"

cd "$INSTALL_DIR"

echo -e "${BLUE}>>> [2/4] 初始化配置向导${NC}"
echo "-------------------------------------------------------"
echo "请输入集群节点的公网 IP 地址 (请查阅您的云服务商控制台):"
read -p "Node-1 (Master): " N1
read -p "Node-2 (Slave):  " N2
read -p "Node-3 (Slave):  " N3

# 生成配置文件
cat <<EOF > topology.env
NODE_1_IP="$N1"
NODE_2_IP="$N2"
NODE_3_IP="$N3"
# --- 端口定义 ---
DB_PORT=3306
PROXY_ADMIN_PORT=6032
PROXY_QUERY_PORT=6033
ADMINER_PORT=8080
# --- 镜像版本 ---
MARIADB_IMAGE="mariadb:latest"
PROXYSQL_IMAGE="proxysql/proxysql:latest"
ADMINER_IMAGE="adminer:latest"
# --- 复制账号 ---
REPL_USER="repl_user"
EOF

# 赋予脚本执行权限
chmod +x install_node.sh scripts/*.sh

echo -e "${BLUE}>>> [3/4] 开始安装节点软件 (Docker + Sidecar)${NC}"
echo "-------------------------------------------------------"
./install_node.sh

echo ""
echo -e "${BLUE}>>> [4/4] 配置集群互联关系${NC}"
echo "-------------------------------------------------------"
echo "即将启动交互式配置..."
echo "1. 如果本机是 Node-1，请选择 MASTER -> 脚本将自动创建复制账号。"
echo "2. 如果本机是 Node-2/3，请选择 SLAVE -> 脚本将自动连接 Node-1。"
echo "-------------------------------------------------------"
sleep 2

# [关键修复] 自动调用互联脚本，完成闭环
./scripts/init_replication.sh

echo ""
echo -e "${GREEN}>>> 全部安装流程结束！${NC}"