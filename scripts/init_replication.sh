#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v4.0.1 - Auto Replication Init (TCP 协议加固版)
# ==============================================================================
# 核心升级:
#   1. [修复] 强制使用 -h127.0.0.1 绕过 Unix Socket 尚未就绪导致的 2002 连接错误。
#   2. 静默读取 .secrets.env，彻底免除密码重复输入。
#   3. 优先接收 bootstrap.sh 传入的角色，解决云环境 NAT 导致的角色判断失误。
#   4. 增加智能等待循环，确保容器内部 mysqld 真正可用后再注入 SQL。
# ==============================================================================

# 0. 加载配置与凭据
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "${BASE_DIR}/topology.env" ]; then
    echo "Error: topology.env not found."
    exit 1
fi
if [ ! -f "${BASE_DIR}/.secrets.env" ]; then
    echo "Error: .secrets.env not found. 凭据文件丢失！"
    exit 1
fi

source "${BASE_DIR}/topology.env"
source "${BASE_DIR}/.secrets.env"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${RED}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo -e "${BLUE}==========================================================${NC}"
echo -e " 正在全自动初始化复制关系..."

# ==============================================================================
# 1. 身份识别 (智能匹配 + 云环境降级保护)
# ==============================================================================
if [ -n "${LOCAL_ROLE:-}" ]; then
    # 优先使用 bootstrap.sh 传递的角色
    MY_ROLE="${LOCAL_ROLE}"
else
    # 独立运行时尝试智能检测
    LOCAL_IPS=$(hostname -I)
    if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
        MY_ROLE="MASTER"
    elif [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]] || [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then
        MY_ROLE="SLAVE"
    else
        warn "无法通过 IP 智能匹配本机身份 (针对 NAT 环境)。"
        echo "请手动指定本机角色:"
        echo "1) MASTER (Node-1: $NODE_1_IP)"
        echo "2) SLAVE  (Node-2 / Node-3)"
        read -p "请输入序号 [1/2]: " role_choice < /dev/tty
        if [ "$role_choice" == "1" ]; then MY_ROLE="MASTER"; else MY_ROLE="SLAVE"; fi
    fi
fi

echo -e " 本机角色: ${GREEN}${MY_ROLE}${NC}"
echo -e " Master IP 指向: ${NODE_1_IP}"
echo -e "${BLUE}==========================================================${NC}"

# ==============================================================================
# 2. 静默获取密码
# ==============================================================================
ROOT_PASS="${AUTO_DB_ROOT_PASS}"
REPL_PASS="${AUTO_REPL_PASS}"

if [ -z "$ROOT_PASS" ] || [ -z "$REPL_PASS" ]; then 
    err "未能从 .secrets.env 读取到有效的密码配置！"
fi

# ==============================================================================
# 辅助函数
# ==============================================================================

# [核心修复] 执行 SQL 时显式指定 -h127.0.0.1，强制走网络栈避开 Socket 竞争
exec_sql() {
    docker exec -i -e MYSQL_PWD="${ROOT_PASS}" mariadb mariadb -h127.0.0.1 -uroot -e "$1"
}

# SQL 转义函数
escape_sql_str() {
    local input="$1"
    local output="${input//\\/\\\\}"
    output="${output//\'/\\\'}"
    echo "$output"
}

# ==============================================================================
# [冷启动保护] 智能等待 MariaDB 完全就绪
# ==============================================================================
log "正在检测 MariaDB 服务状态..."
DB_READY=false
for i in {1..30}; do
    if exec_sql "SELECT 1;" >/dev/null 2>&1; then
        DB_READY=true
        log "MariaDB 已响应 TCP 请求 (耗时约 $((i*2)) 秒)"
        break
    fi
    sleep 2
done

if [ "$DB_READY" = false ]; then
    err "等待超时！容器虽已启动但数据库进程未能就绪。请查看: docker logs mariadb"
fi

# ==============================================================================
# 3. Master 逻辑
# ==============================================================================
if [ "${MY_ROLE}" == "MASTER" ]; then
    log "[Master] 配置复制用户 '${REPL_USER}'..."
    
    SAFE_REPL_PASS=$(escape_sql_str "${REPL_PASS}")

    exec_sql "CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${SAFE_REPL_PASS}';"
    exec_sql "GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';"
    exec_sql "FLUSH PRIVILEGES;"
    
    log "[Master] 复制账号已就绪。"

# ==============================================================================
# 4. Slave 逻辑
# ==============================================================================
else
    log "[Slave] 正在建立与 Master (${NODE_1_IP}) 的连接..."
    
    exec_sql "STOP SLAVE; RESET SLAVE ALL;" || true
    
    SAFE_REPL_PASS=$(escape_sql_str "${REPL_PASS}")
    
    SQL_CMD="CHANGE MASTER TO \
        MASTER_HOST='${NODE_1_IP}', \
        MASTER_PORT=${DB_PORT}, \
        MASTER_USER='${REPL_USER}', \
        MASTER_PASSWORD='${SAFE_REPL_PASS}', \
        MASTER_USE_GTID=slave_pos;"

    exec_sql "${SQL_CMD}"
    exec_sql "START SLAVE;"
    
    log "[Slave] 复制指令已下发，正在同步..."
    sleep 3
    
    # 检查状态
    STATUS=$(exec_sql "SHOW SLAVE STATUS\G")
    IO=$(echo "${STATUS}" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r')
    SQL=$(echo "${STATUS}" | grep "Slave_SQL_Running:" | awk '{print $2}' | tr -d '\r')
    
    if [[ "${IO}" == "Yes" && "${SQL}" == "Yes" ]]; then
        echo -e "${GREEN}>>> 成功！集群同步正常 (IO: Yes, SQL: Yes)${NC}"
        # 成功后锁定只读，严防多点写入导致的脑裂
        exec_sql "SET GLOBAL read_only=ON;"
    else
        echo -e "${RED}>>> 警告！同步链路异常 (IO: ${IO}, SQL: ${SQL})${NC}"
        echo "请检查防火墙端口 ${DB_PORT} 是否开启。"
        echo "错误详情:"
        echo "${STATUS}" | grep "Last_Error" || true
    fi
fi