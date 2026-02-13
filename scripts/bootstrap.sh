#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.3 - Bootstrap (One-Click Installer)
# ==============================================================================
# 部署架构:
#   Root Base:   /opt/docker
#   Project Dir: /opt/docker/mariadb-ha-3node
# 版本特性:
#   - 自动适配 v3.3 安全架构 (双态存储: 明文 + Hash)
#   - 兼容 GitHub Main 分支结构
# ==============================================================================

# 配置
BRANCH="main"
REPO="mariadb-ha-3node"
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

# 使用临时目录处理下载
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

# 备份旧版本
if [ -d "$PROJECT_DIR" ]; then
    BACKUP_NAME="${PROJECT_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}发现旧版本，正在备份至: $BACKUP_NAME${NC}"
    mv "$PROJECT_DIR" "$BACKUP_NAME"
fi

# 移动文件 (兼容 GitHub 目录结构)
EXTRACTED_NAME="$REPO-$BRANCH"
if [ -d "$TEMP_DIR/$EXTRACTED_NAME" ]; then
    mv "$TEMP_DIR/$EXTRACTED_NAME" "$PROJECT_DIR"
else
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

# 生成 topology.env
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

# 赋予权限
chmod +x install_node.sh scripts/*.sh

echo -e "${BLUE}>>> [3/5] 开始安装节点软件 (Docker + Sidecar)${NC}"
echo "-------------------------------------------------------"
# 启动容器 (这一步会安装 Docker 并拉取镜像，为后面计算 Hash 做准备)
./install_node.sh

# ==============================================================================
# [4/5] 录入安全凭据 (双态存储升级版)
# ==============================================================================
echo ""
echo -e "${BLUE}>>> [4/5] 录入安全凭据 (v3.3 Dual-State Mode)${NC}"
echo "-------------------------------------------------------"
echo "Monitor 和 ProxySQL 需要统一的凭据文件才能工作。"
echo "系统将自动生成明文和哈希两个版本的凭据。"
echo "-------------------------------------------------------"

# 定义哈希生成函数
generate_hash() {
    local pwd="$1"
    # 利用 install_node.sh 刚刚拉取的 mariadb 镜像来计算哈希
    docker run --rm mariadb:latest mariadb -N -e "SELECT PASSWORD('${pwd}')" 2>/dev/null
}

# 交互式录入 Root 密码
while true; do
    echo "请输入 DB Root 密码 (用于数据库连接):"
    read -r -s ROOT_PASS
    echo "请再次输入 DB Root 密码:"
    read -r -s ROOT_PASS_CONFIRM
    if [ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ] || [ -z "$ROOT_PASS" ]; then
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    else
        break
    fi
done

# 交互式录入 Proxy 密码
while true; do
    echo "请输入 ProxySQL Admin 密码 (用于管理接口):"
    read -r -s PROXY_PASS
    echo "请再次输入 ProxySQL Admin 密码:"
    read -r -s PROXY_PASS_CONFIRM
    if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ] || [ -z "$PROXY_PASS" ]; then
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    else
        break
    fi
done

echo ""
echo "正在计算加密哈希 (使用 MariaDB 引擎)..."

# 计算哈希
ROOT_HASH=$(generate_hash "${ROOT_PASS}")
PROXY_HASH=$(generate_hash "${PROXY_PASS}")

echo "正在生成双态凭据文件..."

# [修正] 使用 PROJECT_DIR 而不是 BASE_DIR
SECRETS_FILE="${PROJECT_DIR}/.secrets.env"

cat > "${SECRETS_FILE}" <<EOF
# MariaDB HA Secrets (Auto-generated)
# Created at: $(date)

# [Plaintext] 用于 monitor.sh 脚本连接数据库 (必须明文)
export AUTO_DB_ROOT_PASS='${ROOT_PASS}'
export AUTO_PROXY_ADMIN_PASS='${PROXY_PASS}'

# [Hash] 用于 init_proxysql.sh 注入底层配置 (安全无坑)
# 格式: MySQL Native Password (* + 40位Hex)
export AUTO_DB_ROOT_HASH='${ROOT_HASH}'
export AUTO_PROXY_ADMIN_HASH='${PROXY_HASH}'
EOF

chmod 600 "${SECRETS_FILE}"
echo -e "${GREEN}>>> 成功！凭据已保存至: .secrets.env${NC}"
echo "    包含明文与哈希双重校验，安全等级: High"

# [修正] 删除了 redundant 的 ./scripts/save_secrets.sh 调用

sleep 1

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