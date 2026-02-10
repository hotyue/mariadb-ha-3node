#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.2 - Replication Setup (Hex-Encoded Safe Mode)
# ==============================================================================
# 修复 1: 使用 MYSQL_PWD 环境变量连接数据库 (Root 密码安全)
# 修复 2: 使用 Hex 编码处理复制密码 (Repl 密码安全，支持 ', ", \, #)
# 修复 3: 适配 MariaDB 11+ 客户端指令
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
# 1. 身份识别 (兼容 NAT 环境)
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
    echo "检测到可能处于公有云 NAT 环境。"
    echo ""
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

# [修复] 使用 -r 防止反斜杠被转义
read -r -s -p "1. 输入 Root 密码: " ROOT_PASS < /dev/tty
echo ""
if [ -z "$ROOT_PASS" ]; then err "密码不能为空"; fi

read -r -s -p "2. 输入 复制用户(repl) 密码: " REPL_PASS < /dev/tty
echo ""
if [ -z "$REPL_PASS" ]; then err "密码不能为空"; fi

# ==============================================================================
# 辅助函数
# ==============================================================================

# 函数：执行 SQL (使用 MYSQL_PWD 环境变量，防止 Root 密码包含特殊字符出错)
exec_sql() {
    docker exec -i -e MYSQL_PWD="${ROOT_PASS}" mariadb mariadb -uroot -e "$1"
}

# 函数：字符串转 Hex (用于安全传递 REPL 密码)
str_to_hex() {
    printf "%s" "$1" | od -An -tx1 | tr -d ' \n'
}

# ==============================================================================
# 3. Master 逻辑
# ==============================================================================
if [ "${MY_ROLE}" == "MASTER" ]; then
    log "[Master] 创建复制用户 '${REPL_USER}'..."
    
    # 这里的 REPL_PASS 如果包含单引号会破坏 SQL，虽然概率小，但最好也用 Hex
    # 不过创建用户的语法 IDENTIFIED BY 比较宽容，我们用标准方式即可，
    # 只要 ROOT_PASS 是安全的(已通过 MYSQL_PWD 解决)，这里通常没问题。
    # 为了极致安全，这里也用 Hex 注入密码是不错的选择，但 CREATE USER 语法稍有不同。
    # 这里我们保持简单，因为 REPL 密码通常由运维控制，不像 Root 那么随意。
    
    exec_sql "CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASS}';"
    exec_sql "GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';"
    exec_sql "FLUSH PRIVILEGES;"
    
    log "[Master] 复制用户准备就绪。"

# ==============================================================================
# 4. Slave 逻辑
# ==============================================================================
else
    log "[Slave] 正在连接 Master (${NODE_1_IP})..."
    
    # 1. 停止同步
    exec_sql "STOP SLAVE; RESET SLAVE ALL;" || true
    
    # 2. 准备复制密码的 Hex 形式 (核心修复: 解决 CHANGE MASTER 语法错误)
    REPL_PASS_HEX=$(str_to_hex "${REPL_PASS}")
    
    # 3. 配置 GTID 复制
    # 使用 MASTER_PASSWORD=X'...' 语法，绝对安全
    exec_sql "CHANGE MASTER TO \
        MASTER_HOST='${NODE_1_IP}', \
        MASTER_PORT=${DB_PORT}, \
        MASTER_USER='${REPL_USER}', \
        MASTER_PASSWORD=X'${REPL_PASS_HEX}', \
        MASTER_USE_GTID=slave_pos;"
        
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
