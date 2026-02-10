#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.0 - Bootstrap (One-Click Installer)
# ------------------------------------------------------------------------------
# 部署架构:
#   Root Base:   /opt/docker
#   Project Dir: /opt/docker/mariadb-ha-3node
# ==============================================================================

# 配置
BRANCH="dev-v3"
REPO="mariadb-ha-3node"
DOWNLOAD_URL="https://github.com/hotyue/$REPO/archive/refs/heads/$BRANCH.tar.gz"

# [关键路径定义]
INSTALL_BASE="/opt/docker"
PROJECT_DIR="$INSTALL_BASE/$REPO"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}>>> [1/4] 正在下载安装包 ($BRANCH)...${NC}"

# 使用临时目录处理下载，防止污染环境
TEMP_DIR=$(mktemp -d)
curl -L -k "$DOWNLOAD_URL" -o "$TEMP_DIR/ha.tar.gz"
tar -xzf "$TEMP_DIR/ha.tar.gz" -C "$TEMP_DIR"

# 准备安装目录
echo -e "${BLUE}>>> 准备安装目录: $PROJECT_DIR ...${NC}"
mkdir -p "$INSTALL_BASE"

# 如果项目目录已存在，先备份 (防止覆盖配置或误删)
if [ -d "$PROJECT_DIR" ]; then
    BACKUP_NAME="${PROJECT_DIR}.bak.$(date +%s)"
    echo "发现旧版本，正在备份至: $BACKUP_NAME"
    mv "$PROJECT_DIR" "$BACKUP_NAME"
fi

# 移动解压后的文件 (GitHub 压缩包解压目录名通常为 Repo-Branch)
mv "$TEMP_DIR/$REPO-$BRANCH" "$PROJECT_DIR"
rm -rf "$TEMP_DIR"

# 进入项目目录
cd "$PROJECT_DIR"

echo -e "${BLUE}>>> [2/4] 初始化配置向导${NC}"
echo "-------------------------------------------------------"
echo "请输入集群节点的公网 IP 地址 (请查阅您的云服务商控制台):"
read -p "Node-1 (Master): " N1
read -p "Node-2 (Slave):  " N2
read -p "Node-3 (Slave):  " N3

# 生成配置文件 topology.env 到项目目录下
cat <<CONFIG > topology.env
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
CONFIG

# 赋予脚本执行权限
chmod +x install_node.sh scripts/*.sh

echo -e "${BLUE}>>> [3/4] 开始安装节点软件 (Docker + Sidecar)${NC}"
echo "-------------------------------------------------------"
# 此时位于 /opt/docker/mariadb-ha-3node/ 下执行
./install_node.sh

echo ""
echo -e "${BLUE}>>> [4/4] 配置集群互联关系${NC}"
echo "-------------------------------------------------------"
echo "即将启动交互式配置..."
echo "1. 如果本机是 Node-1，请选择 MASTER -> 脚本将自动创建复制账号。"
echo "2. 如果本机是 Node-2/3，请选择 SLAVE -> 脚本将自动连接 Node-1。"
echo "-------------------------------------------------------"
sleep 2

# 调用互联脚本 (自动闭环)
./scripts/init_replication.sh

echo ""
echo -e "${GREEN}>>> 全部安装流程结束！${NC}"
echo -e "项目已部署在: ${GREEN}$PROJECT_DIR${NC}"