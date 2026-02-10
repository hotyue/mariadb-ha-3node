#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.2 - Emergency Failover (The Red Button)
# ==============================================================================
# 作用: 强制将当前节点提升为新 Master
# 适用场景: 原 Master (Node-1) 宕机，Monitor 自动切换失效，需要人工介入
# 安全特性: 全程使用 MYSQL_PWD 环境变量，支持任意特殊字符密码
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOPOLOGY_FILE="${BASE_DIR}/topology.env"
SECRET_FILE="${BASE_DIR}/.secrets.env"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 加载配置
if [ -f "$TOPOLOGY_FILE" ]; then source "$TOPOLOGY_FILE"; else echo "Error: topology.env missing"; exit 1; fi

# 2. 尝试自动加载凭据
if [ -f "$SECRET_FILE" ]; then 
    source "$SECRET_FILE"
    DB_ROOT_PASS="${AUTO_DB_ROOT_PASS:-}"
    PROXY_ADMIN_PASS="${AUTO_PROXY_ADMIN_PASS:-}"
fi

echo -e "${RED}==========================================================${NC}"
echo -e "${RED}   警告: 你正在启动手动故障转移 (Manual Failover)！${NC}"
echo -e "${RED}==========================================================${NC}"
echo "此操作将:"
echo "1. 停止本机的从库复制 (STOP SLAVE)"
echo "2. 解除本机的只读限制 (READ_ONLY = 0)"
echo "3. 强制修改本机 ProxySQL，将写流量指向自己"
echo ""
echo -e "${YELLOW}只有在 Node-1 (原Master) 彻底宕机且 Monitor 未生效时才执行此操作！${NC}"
echo ""

# 3. 确认执行
read -p "确认要执行吗? (输入 YES 确认): " confirm
if [ "$confirm" != "YES" ]; then
    echo "操作已取消 (需输入 YES)。"
    exit 0
fi

# 4. 补全密码 (如果 .secrets.env 不存在)
if [ -z "${DB_ROOT_PASS:-}" ]; then
    echo ""
    read -r -s -p "请输入 DB Root 密码: " DB_ROOT_PASS < /dev/tty
    echo ""
fi
if [ -z "${PROXY_ADMIN_PASS:-}" ]; then
    echo ""
    read -r -s -p "请输入 ProxySQL Admin 密码: " PROXY_ADMIN_PASS < /dev/tty
    echo ""
fi

# 5. 识别本机身份 (用于写入路由表)
LOCAL_IPS=$(hostname -I)
MY_PUBLIC_IP=""

if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then 
    MY_PUBLIC_IP="$NODE_2_IP"
    echo -e "${BLUE}>>> 识别本机为: Node-2 ($NODE_2_IP)${NC}"
elif [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then 
    MY_PUBLIC_IP="$NODE_3_IP"
    echo -e "${BLUE}>>> 识别本机为: Node-3 ($NODE_3_IP)${NC}"
else
    # 无法识别时回退到 127.0.0.1，或者要求用户手动输入
    echo -e "${YELLOW}[WARN] 无法通过 IP 识别本机角色，将使用 127.0.0.1 作为写入目标。${NC}"
    MY_PUBLIC_IP="127.0.0.1"
fi

# ==============================================================================
# 核心操作 1: 提升 MariaDB
# ==============================================================================
echo -e "\n>>> [1/3] 正在提升 MariaDB 为 Master..."

# [FIX] 使用 MYSQL_PWD 传递 Root 密码，防止特殊字符截断
docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=0;"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}成功! 本机 MariaDB 已停止复制并可写。${NC}"
else
    echo -e "${RED}失败! 无法连接数据库 (密码错误或容器未运行)。${NC}"
    exit 1
fi

# ==============================================================================
# 核心操作 2: 更新 ProxySQL
# ==============================================================================
echo -e ">>> [2/3] 正在更新 ProxySQL 路由 (Writer -> $MY_PUBLIC_IP)..."

# 定义探测函数 (复用 init_proxysql 的逻辑)
check_proxysql_pass() {
    local pass=$1
    if docker exec -e MYSQL_PWD="${pass}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 智能探测当前有效密码
ACTUAL_PROXY_PASS=""
if check_proxysql_pass "${PROXY_ADMIN_PASS}"; then
    ACTUAL_PROXY_PASS="${PROXY_ADMIN_PASS}"
elif check_proxysql_pass "admin"; then
    ACTUAL_PROXY_PASS="admin"
    echo -e "${YELLOW}[注意] ProxySQL 正在使用默认密码 'admin'，将使用默认密码进行操作。${NC}"
else
    echo -e "${RED}[错误] 无法连接 ProxySQL，请检查密码或容器状态。${NC}"
    exit 1
fi

# 执行路由切换 (使用 MYSQL_PWD)
docker exec -e MYSQL_PWD="${ACTUAL_PROXY_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL
    -- 1. 清除旧的 Writer (HG 10)
    DELETE FROM mysql_servers WHERE hostgroup_id=10;
    
    -- 2. 将本机插入为 Writer
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$MY_PUBLIC_IP', 3306);
    
    -- 3. 立即生效
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
SQL

if [ $? -eq 0 ]; then
    echo -e "${GREEN}>>> [3/3] 故障转移完成！ProxySQL 路由已更新。${NC}"
else
    echo -e "${RED}>>> [Error] ProxySQL 更新失败。${NC}"
    exit 1
fi

echo "----------------------------------------------------------"
echo -e "当前状态: [${GREEN}Master${NC}] -> 本机 ($MY_PUBLIC_IP)"
echo "----------------------------------------------------------"
echo "后续步骤:"
echo "1. 请检查业务连接是否恢复。"
echo "2. 其他存活的 Slave 节点需要手动指向本机 (CHANGE MASTER TO $MY_PUBLIC_IP)。"
echo "----------------------------------------------------------"