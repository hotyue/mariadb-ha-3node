#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.2 - Bootstrap (One-Click Installer)
# ==============================================================================
# 部署架构:
#   Root Base:   /opt/docker
#   Project Dir: /opt/docker/mariadb-ha-3node
# 版本特性:
#   - 自动适配 v3.2 安全架构 (Secrets Manager)
#   - 兼容 GitHub Main 分支结构
# ==============================================================================

# 配置
BRANCH="main"
REPO="mariadb-ha-3node"
# 使用 -L 跟随重定向，-f 失败不输出 HTML 错误
DOWNLOAD_URL="https://github.com/hotyue/$REPO/archive/refs/heads/$BRANCH.tar.gz"

# [关键路径定义]
INSTALL_BASE="/opt/docker"
PROJECT_DIR="$INSTALL_BASE/$REPO"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}>>> [1/5] 正在下载安装包 ($BRANCH)...${NC}"

# 使用临时目录处理下载，防止污染环境
TEMP_DIR=$(mktemp -d)
if ! curl -fsSL -k "$DOWNLOAD_URL" -o "$TEMP_DIR/ha.tar.gz"; then
    echo -e "${RED}下载失败！请检查网络或 URL。${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 解压
tar -xzf "$TEMP_DIR/ha.tar.gz" -C "$TEMP_DIR"

# 准备安装目录
echo -e "${BLUE}>>> 准备安装目录: $PROJECT_DIR ...${NC}"
mkdir -p "$INSTALL_BASE"

# 如果项目目录已存在，先备份 (防止覆盖配置或误删)
if [ -d "$PROJECT_DIR" ]; then
    BACKUP_NAME="${PROJECT_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}发现旧版本，正在备份至: $BACKUP_NAME${NC}"
    mv "$PROJECT_DIR" "$BACKUP_NAME"
fi

# 移动解压后的文件
# GitHub 压缩包解压后的目录名通常为 repo-branch (例如 mariadb-ha-3node-main)
EXTRACTED_NAME="$REPO-$BRANCH"
if [ -d "$TEMP_DIR/$EXTRACTED_NAME" ]; then
    mv "$TEMP_DIR/$EXTRACTED_NAME" "$PROJECT_DIR"
else
    # 兼容性处理：如果解压出来的名字不一样，尝试找唯一的目录
    DETECTED_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    mv "$DETECTED_DIR" "$PROJECT_DIR"
fi

rm -rf "$TEMP_DIR"

# 进入项目目录
cd "$PROJECT_DIR"

echo -e "${BLUE}>>> [2/5] 初始化配置向导${NC}"
echo "-------------------------------------------------------"
echo "请输入集群节点的公网/内网 IP 地址 (确保三台机器互通):"
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

echo -e "${BLUE}>>> [3/5] 开始安装节点软件 (Docker + Sidecar)${NC}"
echo "-------------------------------------------------------"
# 启动容器
./install_node.sh

echo ""
echo -e "${BLUE}>>> [4/5] 录入安全凭据 (v3.2 核心步骤)${NC}"
echo "-------------------------------------------------------"
echo "Monitor 和 ProxySQL 需要统一的凭据文件才能工作。"
echo "请按照提示录入您的 Root 密码和 ProxySQL Admin 密码。"
echo "-------------------------------------------------------"
sleep 1
# [关键新增] 必须运行此脚本生成 .secrets.env，否则 monitor 无法启动
./scripts/save_secrets.sh

echo ""
echo -e "${BLUE}>>> [5/5] 配置集群互联关系${NC}"
echo "-------------------------------------------------------"
echo "即将启动交互式配置..."
echo "1. 如果本机是 Node-1，请选择 MASTER -> 脚本将自动创建复制账号。"
echo "2. 如果本机是 Node-2/3，请选择 SLAVE -> 脚本将自动连接 Node-1。"
echo "-------------------------------------------------------"
sleep 2

# 调用互联脚本
./scripts/init_replication.sh

echo ""
echo -e "${GREEN}>>> 基础安装流程结束！${NC}"
echo "后续步骤建议："
echo "1. 运行 ./scripts/init_proxysql.sh 初始化路由 (推荐)"
echo "2. 运行 ./scripts/monitor.sh 启动自动故障转移 (推荐)"
echo "-------------------------------------------------------"
echo -e "项目路径: ${GREEN}$PROJECT_DIR${NC}"