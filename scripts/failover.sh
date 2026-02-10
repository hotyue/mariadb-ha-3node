#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.0 - Emergency Failover (The Red Button)
# ==============================================================================
# 作用: 强制将当前节点提升为新 Master
# 适用场景: 原 Master (Node-1) 宕机，需要人工介入切换
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}==========================================================${NC}"
echo -e "${RED}   警告: 你正在启动故障转移 (Failover) 程序！${NC}"
echo -e "${RED}==========================================================${NC}"
echo "此操作将:"
echo "1. 停止本机的从库复制 (STOP SLAVE)"
echo "2. 解除本机的只读限制 (READ_ONLY = 0)"
echo "3. 修改本机 ProxySQL，将写流量指向自己 (Writer -> Localhost)"
echo ""
echo -e "${YELLOW}只有在 Node-1 (原Master) 彻底宕机时才应执行此操作！${NC}"
echo ""

read -p "确认要执行吗? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "操作已取消。"
    exit 0
fi

# 1. 交互式获取密码
echo ""
echo ">>> 请输入密码以执行特权操作:"
if [ -z "${DB_ROOT_PASS:-}" ]; then
    read -s -p "请输入 DB Root 密码: " DB_ROOT_PASS
    echo ""
fi
if [ -z "${PROXY_ADMIN_PASS:-}" ]; then
    read -s -p "请输入 ProxySQL Admin 密码: " PROXY_ADMIN_PASS
    echo ""
fi

# 2. 提升 MariaDB 自身权限
echo -e "\n>>> [1/3] 正在提升 MariaDB 为 Master..."
docker exec -i mariadb mariadb -uroot -p"${DB_ROOT_PASS}" -e "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=0;"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}成功! 本机 MariaDB 已停止复制并可写。${NC}"
else
    echo -e "${RED}失败! 密码错误或容器异常。${NC}"
    exit 1
fi

# 3. 获取本机 IP
LOCAL_IP=$(hostname -I | awk '{print $1}')
# 这里简单处理，假设 hostname -I 第一个是外网IP，如果不是需人工确认
# 更好的方式是读取 topology.env 里的对应变量，但脚本不知道自己是 Node-2 还是 3
# 我们简单点，直接把 Writer 指向 127.0.0.1 (本机)
# 或者更好的：Writer 指向本机公网 IP。

# 尝试匹配本机 IP 属于哪个 NODE 变量
MY_PUBLIC_IP=""
if [[ "$(hostname -I)" == *"$NODE_2_IP"* ]]; then MY_PUBLIC_IP="$NODE_2_IP"; fi
if [[ "$(hostname -I)" == *"$NODE_3_IP"* ]]; then MY_PUBLIC_IP="$NODE_3_IP"; fi

if [ -z "$MY_PUBLIC_IP" ]; then
    echo -e "${YELLOW}无法自动识别本机公网 IP，将使用 127.0.0.1 (仅限本机应用访问)${NC}"
    MY_PUBLIC_IP="127.0.0.1"
fi

# 4. 修改 ProxySQL 路由
echo -e ">>> [2/3] 正在更新 ProxySQL 路由 (Writer -> $MY_PUBLIC_IP)..."

# 智能探测 ProxySQL 密码 (admin vs 自定义)
CURRENT_PASS="${PROXY_ADMIN_PASS}"
if ! docker exec -i proxysql mysql -u admin -p"${PROXY_ADMIN_PASS}" -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
    # 如果用户输入的密码不对，尝试默认 admin
    if docker exec -i proxysql mysql -u admin -p"admin" -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
        CURRENT_PASS="admin"
    fi
fi

docker exec -i proxysql mysql -u admin -p"${CURRENT_PASS}" -h 127.0.0.1 -P 6032 <<-SQL
    -- 将 Writer (HG 10) 指向自己
    DELETE FROM mysql_servers WHERE hostgroup_id=10;
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$MY_PUBLIC_IP', 3306);
    
    -- 立即生效
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
SQL

echo -e "${GREEN}>>> [3/3] 故障转移完成！${NC}"
echo "----------------------------------------------------------"
echo "当前状态: 本机 ($MY_PUBLIC_IP) 已成为新的 Master。"
echo "请注意：集群中其他存活的 Slave 节点需要手动执行 'CHANGE MASTER TO' 指向本机。"
echo "----------------------------------------------------------"
