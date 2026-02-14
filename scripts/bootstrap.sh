#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v4.0.0 - Bootstrap (Auto-Pilot 流水线安装器)
# ==============================================================================
# 架构变更:
#   1. [New] 升级至 v4.0 一键全自动流水线部署，告别繁琐的手动步骤。
#   2. [Fix] 使用 OpenSSL 本地计算哈希，彻底解决 Docker 容器启动失败导致的中断问题。
#   3. [New] 在安装阶段录入 REPL_PASS 并持久化，支持全链条静默执行。
#   4. [New] 植入 Systemd 开机自愈拦截器，彻底杜绝物理机重启导致的短暂脑裂。
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

echo -e "${BLUE}>>> [1/6] 正在下载安装包 ($BRANCH)...${NC}"

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

echo -e "${BLUE}>>> [2/6] 初始化集群拓扑配置${NC}"
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

# ==============================================================================
# [3/6] 智能身份识别 (预处理)
# ==============================================================================
echo ""
echo -e "${BLUE}>>> [3/6] 智能识别本机角色${NC}"
echo "-------------------------------------------------------"

LOCAL_IPS=$(hostname -I)
MY_ROLE=""

# 尝试自动匹配
if [[ "$LOCAL_IPS" == *"$N1"* ]]; then
    MY_ROLE="MASTER"
elif [[ "$LOCAL_IPS" == *"$N2"* ]] || [[ "$LOCAL_IPS" == *"$N3"* ]]; then
    MY_ROLE="SLAVE"
else
    # 智能检测失败 (针对 GCP/AWS 等严格 NAT 环境)，弹出手动选择
    echo -e "${RED}[WARN] 无法通过公网 IP 智能匹配本机身份 (可能处于 NAT 环境)。${NC}"
    echo "请手动指定本机角色:"
    echo "1) MASTER (Node-1: $N1)"
    echo "2) SLAVE  (Node-2 / Node-3)"
    read -p "请输入 [1/2]: " role_choice < /dev/tty
    if [ "$role_choice" == "1" ]; then MY_ROLE="MASTER"; else MY_ROLE="SLAVE"; fi
fi

echo -e "识别结果: 本机作为 ${GREEN}${MY_ROLE}${NC} 节点加入集群。"

# ==============================================================================
# [4/6] 录入安全凭据并持久化
# ==============================================================================
echo ""
echo -e "${BLUE}>>> [4/6] 录入核心安全凭据 (v4.0)${NC}"
echo "-------------------------------------------------------"
echo "一次录入，全程静默。系统将自动生成明文和哈希两个版本的凭据。"
echo "-------------------------------------------------------"

# [工具函数] 使用 OpenSSL 计算 MySQL Native Password 哈希
generate_hash() {
    local pwd="$1"
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}错误: 未找到 openssl 命令。无法计算哈希。${NC}" >&2
        exit 1
    fi
    local h
    h=$(echo -n "$pwd" | openssl dgst -sha1 -binary | openssl dgst -sha1 | awk '{print toupper($NF)}')
    echo "*$h"
}

# 1. Root 密码
while true; do
    read -r -s -p "请输入 DB Root 密码 (用于数据库连接): " ROOT_PASS < /dev/tty; echo ""
    read -r -s -p "请再次输入 DB Root 密码: " ROOT_PASS_CONFIRM < /dev/tty; echo ""
    if [ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ] || [ -z "$ROOT_PASS" ]; then
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    else
        break
    fi
done

# 2. Proxy Admin 密码
while true; do
    read -r -s -p "请输入 ProxySQL Admin 密码 (用于管理接口): " PROXY_PASS < /dev/tty; echo ""
    read -r -s -p "请再次输入 ProxySQL Admin 密码: " PROXY_PASS_CONFIRM < /dev/tty; echo ""
    if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ] || [ -z "$PROXY_PASS" ]; then
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    else
        break
    fi
done

# 3. Replication 密码
while true; do
    read -r -s -p "请输入 Replication 复制密码 (用于节点间同步): " REPL_PASS < /dev/tty; echo ""
    read -r -s -p "请再次输入 Replication 复制密码: " REPL_PASS_CONFIRM < /dev/tty; echo ""
    if [ "$REPL_PASS" != "$REPL_PASS_CONFIRM" ] || [ -z "$REPL_PASS" ]; then
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    else
        break
    fi
done

echo ""
echo "正在计算加密哈希 (使用 OpenSSL)..."

set +e
ROOT_HASH=$(generate_hash "${ROOT_PASS}")
PROXY_HASH=$(generate_hash "${PROXY_PASS}")
RET=$?
set -e

if [ $RET -ne 0 ] || [ -z "$ROOT_HASH" ]; then
    echo -e "${RED}>>> 计算失败！请确保系统安装了 openssl。${NC}"
    exit 1
fi

SECRETS_FILE="${PROJECT_DIR}/.secrets.env"

cat > "${SECRETS_FILE}" <<SEC
# MariaDB HA Secrets (Auto-generated v4.0.0)
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
echo -e "${GREEN}>>> 成功！凭据已安全生成并加载。${NC}"

# ==============================================================================
# [5/6] 启动核心容器组
# ==============================================================================
echo ""
echo -e "${BLUE}>>> [5/6] 启动 MariaDB & ProxySQL 容器组${NC}"
echo "-------------------------------------------------------"
./install_node.sh

# ==============================================================================
# [6/6] 全自动流水线 (Auto-Pilot)
# ==============================================================================
echo ""
echo -e "${BLUE}>>> [6/6] 执行流水线: 自动建主从 -> 刷路由 -> 挂哨兵 -> 植入免疫抗体${NC}"
echo "-------------------------------------------------------"

# 1. 自动配置复制关系 (透传角色，免去子脚本二次检测和询问)
export LOCAL_ROLE="$MY_ROLE"
./scripts/init_replication.sh

# 2. 静默刷入 ProxySQL 路由
./scripts/init_proxysql.sh

# 3. 启动 v3.5 永不宕机哨兵
echo -e "${BLUE}[INFO] 正在后台挂载 HA Monitor 哨兵...${NC}"
pkill -f monitor.sh || true
nohup ./scripts/monitor.sh > /var/log/ha-monitor.log 2>&1 &
sleep 2

# ==============================================================================
# 终极防御：植入 Systemd 开机自愈拦截器 (防脑裂)
# ==============================================================================
echo -e "${BLUE}[INFO] 正在植入底层防御：系统开机自愈服务 (Systemd)...${NC}"
cat << 'EOF' > /etc/systemd/system/mariadb-ha-boot.service
[Unit]
Description=MariaDB HA Boot Interceptor & Auto-Rejoin
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
# [修复 1] 注入完整的环境变量，确保能找到 docker 和其他基础命令
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# [修复 2] 动态等待，直到 docker 引擎真正响应为止，再额外留 10 秒给容器启动
ExecStartPre=/bin/sh -c 'while ! docker info >/dev/null 2>&1; do sleep 1; done; sleep 10'

# 执行核心归队逻辑
ExecStart=/opt/docker/mariadb-ha-3node/scripts/rejoin.sh

StandardOutput=append:/var/log/ha-boot-rejoin.log
StandardError=append:/var/log/ha-boot-rejoin.log

# [修复 3 核心] 告诉 Systemd：脚本执行完就拉倒，绝对不要去杀它留在后台的 monitor.sh！
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mariadb-ha-boot.service >/dev/null 2>&1
echo -e "${GREEN}[OK] 开机防脑裂疫苗注射完毕！${NC}"

echo ""
echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}🎉 部署全部完成！真正的一键流水线 (v4.0 终极版)${NC}"
echo -e "${GREEN}=======================================================${NC}"
echo -e " ✅ 基础容器已启动 (MariaDB + ProxySQL + Adminer)"
echo -e " ✅ 主从复制已自动建立并校验成功"
echo -e " ✅ 读写分离路由规则已注入"
echo -e " ✅ 高可用监控哨兵已在后台守护"
echo -e " 🛡️  开机自愈防御系统已植入系统底层 (Systemd)"
echo -e "-------------------------------------------------------"
echo -e " 🚀 业务接入入口: ${GREEN}127.0.0.1:6033${NC} (或本机内网IP:6033)"
echo -e " 👁️  查看哨兵日志: ${BLUE}tail -f /var/log/ha-monitor.log${NC}"
echo -e " 👁️  查看开机自愈日志: ${BLUE}cat /var/log/ha-boot-rejoin.log${NC}"
echo -e "-------------------------------------------------------"
echo -e " [项目路径]: ${PROJECT_DIR}"