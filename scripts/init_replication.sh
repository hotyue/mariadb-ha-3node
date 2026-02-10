#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.2 - Replication Setup (Escaped String Mode)
# ==============================================================================
# 修复: 解决 CHANGE MASTER 不支持 Hex (X'...') 语法的问题
# 方案: 使用 Bash 字符串替换进行转义，支持特殊字符 (', \, #)
# ==============================================================================

# 0. 加载配置
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "${BASE_DIR}/topology.env" ]; then
    echo "Error: topology.env not found."
    exit 1
fi
source "${BASE_DIR}/topology.env"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${RED}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ==============================================================================
# 1. 身份识别
# ==============================================================================
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"

# 尝试自动匹配
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    MY_ROLE="MASTER"
elif [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]] || [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then
    MY_ROLE="SLAVE"
fi

# 手动修正 (如果自动匹配失败)
if [ "$MY_ROLE" == "UNKNOWN" ]; then
    echo "----------------------------------------------------------"
    warn "无法通过内网 IP ($LOCAL_IPS) 自动识别本机角色。"
    echo "请手动选择本机身份:"
    echo " 1) Master (Node-1: $NODE_1_IP)"
    echo " 2) Slave  (Node-2: $NODE_2_IP)"
    echo " 3) Slave  (Node-3: $NODE_3_IP)"
    echo "----------------------------------------------------------"
    
    # 强制从 tty 读取
    read -p "请输入序号 (1/2/3): " NODE_IDX < /dev/tty
    
    case "$NODE_IDX" in
        1) MY_ROLE="MASTER" ;;
        2) MY_ROLE="SLAVE" ;;
        3) MY_ROLE="SLAVE" ;;
        *) err "无效输入，退出。" ;;
    esac
fi

echo "=========================================================="
echo " 正在初始化复制关系..."
echo " 本机角色: ${MY_ROLE}"
echo " Master IP: ${NODE_1_IP}"
echo "=========================================================="

# ==============================================================================
# 2. 安全交互：获取密码
# ==============================================================================
echo ">>> 请输入密码以配置复制 (输入不显示)"

# 使用 -r 防止反斜杠被转义
read -r -s -p "1. 输入 Root 密码: " ROOT_PASS < /dev/tty
echo ""
if [ -z "$ROOT_PASS" ]; then err "密码不能为空"; fi

read -r -s -p "2. 输入 复制用户(repl) 密码: " REPL_PASS < /dev/tty
echo ""
if [ -z "$REPL_PASS" ]; then err "密码不能为空"; fi

# ==============================================================================
# 辅助函数
# ==============================================================================

# 执行 SQL (使用 MYSQL_PWD 环境变量)
exec_sql() {
    docker exec -i -e MYSQL_PWD="${ROOT_PASS}" mariadb mariadb -uroot -e "$1"
}

# [关键修复] SQL 转义函数
# 1. 将反斜杠 \ 替换为 \\ (必须先做)
# 2. 将单引号 ' 替换为 \'
escape_sql_str() {
    local input="$1"
    local output="${input//\\/\\\\}"
    output="${output//\'/\\\'}"
    echo "$output"
}

# ==============================================================================
# 3. Master 逻辑
# ==============================================================================
if [ "${MY_ROLE}" == "MASTER" ]; then
    log "[Master] 创建复制用户 '${REPL_USER}'..."
    
    # 对密码进行转义处理，防止 SQL 注入或语法错误
    SAFE_REPL_PASS=$(escape_sql_str "${REPL_PASS}")

    # 使用标准 SQL 语法创建用户
    exec_sql "CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${SAFE_REPL_PASS}';"
    exec_sql "GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';"
    exec_sql "FLUSH PRIVILEGES;"
    
    log "[Master] 复制用户准备就绪。"

# ==============================================================================
# 4. Slave 逻辑
# ==============================================================================
else
    log "[Slave] 正在连接 Master (${NODE_1_IP})..."
    
    # 1. 停止同步 (防止报错)
    exec_sql "STOP SLAVE; RESET SLAVE ALL;" || true
    
    # 2. 对密码进行转义处理 (修复 'X' Hex 语法错误)
    SAFE_REPL_PASS=$(escape_sql_str "${REPL_PASS}")
    
    # 3. 配置 GTID 复制
    # 这里使用标准的单引号包裹密码，因为内部已转义，所以支持包含单引号或反斜杠的密码
    # 注意: SQL_CMD 变量构建时，Bash 会展开变量，但不会二次转义
    
    SQL_CMD="CHANGE MASTER TO \
        MASTER_HOST='${NODE_1_IP}', \
        MASTER_PORT=${DB_PORT}, \
        MASTER_USER='${REPL_USER}', \
        MASTER_PASSWORD='${SAFE_REPL_PASS}', \
        MASTER_USE_GTID=slave_pos;"
    
    # 调试输出 (隐藏密码)
    # echo "DEBUG SQL: ${SQL_CMD}" | sed "s/MASTER_PASSWORD='.*'/MASTER_PASSWORD='******'/g"

    exec_sql "${SQL_CMD}"
    exec_sql "START SLAVE;"
    
    log "[Slave] 复制已启动，正在检查状态..."
    sleep 3
    
    # 4. 检查状态
    STATUS=$(exec_sql "SHOW SLAVE STATUS\G")
    IO=$(echo "${STATUS}" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL=$(echo "${STATUS}" | grep "Slave_SQL_Running:" | awk '{print $2}')
    
    if [[ "${IO}" == "Yes" && "${SQL}" == "Yes" ]]; then
        echo -e "${GREEN}>>> 成功！复制正在运行 (IO: Yes, SQL: Yes)${NC}"
    else
        echo -e "${RED}>>> 警告！复制状态异常 (IO: ${IO}, SQL: ${SQL})${NC}"
        echo "请检查防火墙端口 ${DB_PORT} 是否开放，或密码是否正确。"
        echo "错误详情:"
        echo "${STATUS}" | grep "Last_Error"
    fi
fi
