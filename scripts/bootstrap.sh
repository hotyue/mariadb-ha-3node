#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.4 - Bootstrap (One-Click Installer)
# ==============================================================================
# 架构变更:
#   1. [Fix] 使用 OpenSSL 本地计算哈希，彻底解决 Docker 容器启动失败导致的中断问题
#   2. [New] 在安装阶段录入 REPL_PASS 并持久化，支持 rejoin.sh 全自动归队
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
# 启动容器
./install_node.sh

# ==============================================================================
# [4/5] 录入安全凭据 (v3.4 Full-Auto Mode)
# ==============================================================================
echo ""
echo -e "${BLUE}>>> [4/5] 录入安全凭据 (v3.4 Full-Auto Mode)${NC}"
echo "-------------------------------------------------------"
echo "Monitor 和 ProxySQL 需要统一的凭据文件才能工作。"
echo "系统将自动生成明文和哈希两个版本的凭据。"
echo "-------------------------------------------------------"

# [工具函数] 使用 OpenSSL 计算 MySQL Native Password 哈希
# 算法: SHA1(SHA1(password)) -> Hex -> Upper -> Prepend *
generate_hash() {
    local pwd="$1"
    
    # 检查 openssl 是否存在
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}错误: 未找到 openssl 命令。无法计算哈希。${NC}" >&2
        exit 1
    fi

    # 计算哈希 (兼容 OpenSSL 不同版本的输出格式)
    # awk '{print $NF}' 用于提取最后一段 (哈希值)，忽略可能存在的 "(stdin)=" 前缀
    local h
    h=$(echo -n "$pwd" | openssl dgst -sha1 -binary | openssl dgst -sha1 | awk '{print toupper($NF)}')
    
    echo "*$h"
}

# 1. Root 密码
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

# 2. Proxy Admin 密码
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

# 3. [新增] Replication 密码 (为了 rejoin.sh 自动化)
while true; do
    echo "请输入 Replication 复制密码 (用于节点间同步):"
    read -r -s REPL_PASS
    echo "请再次输入 Replication 复制密码:"
    read -r -s REPL_PASS_CONFIRM
    if [ "$REPL_PASS" != "$REPL_PASS_CONFIRM" ] || [ -z "$REPL_PASS" ]; then
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    else
        break
    fi
done

echo ""
echo "正在计算加密哈希 (使用 OpenSSL)..."

# 临时关闭 set -e 以捕获错误
set +e
ROOT_HASH=$(generate_hash "${ROOT_PASS}")
PROXY_HASH=$(generate_hash "${PROXY_PASS}")
RET=$?
set -e

if [ $RET -ne 0 ] || [ -z "$ROOT_HASH" ]; then
    echo -e "${RED}>>> 计算失败！请确保系统安装了 openssl。${NC}"
    echo "调试信息: RootHash=[$ROOT_HASH]"
    exit 1
fi

echo "正在生成全量凭据文件..."

SECRETS_FILE="${PROJECT_DIR}/.secrets.env"

cat > "${SECRETS_FILE}" <<SEC
# MariaDB HA Secrets (Auto-generated v3.4)
# Created at: $(date)

# [Plaintext] 用于 monitor.sh 和 rejoin.sh
export AUTO_DB_ROOT_PASS='${ROOT_PASS}'
export AUTO_PROXY_ADMIN_PASS='${PROXY_PASS}'
export AUTO_REPL_PASS='${REPL_PASS}'

# [Hash] 用于 init_proxysql.sh 注入底层配置
export AUTO_DB_ROOT_HASH='${ROOT_HASH}'
export AUTO_PROXY_ADMIN_HASH='${PROXY_HASH}'
SEC

chmod 600 "${SECRETS_FILE}"
echo -e "${GREEN}>>> 成功！凭据已保存至: .secrets.env${NC}"

sleep 1

echo ""
echo -e "${BLUE}>>> [5/5] 配置集群互联关系${NC}"
echo "-------------------------------------------------------"
echo "即将启动交互式配置..."
echo "1. 如果本机是 Node-1，请选择 MASTER。"
echo "2. 如果本机是 Node-2/3，请选择 SLAVE。"
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