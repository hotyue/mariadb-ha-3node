#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.3 - Auto Rejoin Script (智能归队程序)
# ==============================================================================
# 适用场景:
#   节点宕机修复后，执行此脚本使其自动归队。
# 核心功能:
#   1. 自动扫描局域网，识别当前 Read_Only=OFF 的 Master 节点。
#   2. 重置本机 MariaDB 复制状态，指向新 Master。
#   3. 修正本机 ProxySQL 路由表 (HG10 -> 新 Master)。
#   4. 重启本机 Monitor 哨兵。
# ==============================================================================

# 基础路径配置
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"
SECRETS_FILE="${BASE_DIR}/.secrets.env"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "----------------------------------------------------------"
echo ">>> MariaDB HA 节点归队程序 (v3.3)"
echo "----------------------------------------------------------"

# 1. 加载安全凭据
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
    # 使用明文密码连接数据库和 ProxySQL
    DB_ROOT_PASS="${AUTO_DB_ROOT_PASS}"
    PROXY_ADMIN_PASS="${AUTO_PROXY_ADMIN_PASS}"
else
    err "未找到 .secrets.env 文件！无法获取连接凭据。"
fi

# 2. 获取复制密码 (REPL_PASS)
# 默认尝试从环境变量获取，如果没有则交互式询问
# (Bootstrap 阶段默认未将 repl_user 密码存入 secrets，需手动输入)
if [ -z "${REPL_PASS:-}" ]; then
    echo "请输入复制用户 (repl_user) 的密码:"
    echo "(即 Bootstrap 初始化时设置的密码)"
    read -r -s REPL_PASS
    echo ""
fi

# 3. 扫描集群寻找新 Master
log "正在扫描集群寻找当前 Master..."
NEW_MASTER_IP=""

# 定义探测函数: 检查目标是否为 Master (read_only = OFF)
check_if_master() {
    local target_ip=$1
    # 跳过本机 IP
    local local_ips=$(hostname -I)
    if [[ "$local_ips" == *"$target_ip"* ]]; then return 1; fi

    # 使用 docker 客户端远程探测
    # 注意: 这里依赖 target_ip 的 3306 端口开放且允许 root 远程登录
    local is_ro
    if is_ro=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -h "$target_ip" -N -e "SELECT @@read_only;" 2>/dev/null); then
        # 0 = OFF (Master), 1 = ON (Slave)
        if [ "$is_ro" == "0" ]; then
            echo "$target_ip"
            return 0
        fi
    fi
    return 1
}

# 遍历拓扑中的所有 IP
for IP in "$NODE_1_IP" "$NODE_2_IP" "$NODE_3_IP"; do
    if [ -n "$IP" ]; then
        if FOUND_IP=$(check_if_master "$IP"); then
            NEW_MASTER_IP="$FOUND_IP"
            break
        fi
    fi
done

if [ -z "${NEW_MASTER_IP}" ]; then
    err "扫描失败！未找到任何在线的 Master 节点。\n可能原因: 集群全挂了，或者网络不通，或者 Master 也是 read_only=ON。"
else
    ok "发现新 Master: ${NEW_MASTER_IP}"
fi

echo "----------------------------------------------------------"
log "即将在本机执行归队操作..."
log "1. 停止 Slave 进程 & 重置状态"
log "2. 指向新 Master: ${NEW_MASTER_IP}"
log "3. 修正 ProxySQL 路由"
log "4. 重启监控哨兵"
echo "----------------------------------------------------------"
log "按任意键开始，或 Ctrl+C 取消..."
read -n 1 -s -r

# 4. 数据库层归队 (MariaDB)
log "正在配置 MariaDB..."

# 停止复制，重置状态 (GTID 模式下 RESET SLAVE ALL 会清除连接信息但保留 GTID 位置)
docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "STOP SLAVE; RESET SLAVE ALL;"

# 配置新主库 (使用 GTID 自动定位)
# 注意: MASTER_USE_GTID=slave_pos 是 MariaDB 的核心特性，用于自动找点
CHANGE_SQL="CHANGE MASTER TO 
  MASTER_HOST='${NEW_MASTER_IP}', 
  MASTER_PORT=${DB_PORT}, 
  MASTER_USER='${REPL_USER}', 
  MASTER_PASSWORD='${REPL_PASS}', 
  MASTER_USE_GTID=slave_pos; 
START SLAVE;"

docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "${CHANGE_SQL}"

# 验证状态
sleep 2
SLAVE_STATUS=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "SHOW SLAVE STATUS\G")
IO_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')

if [ "$IO_RUNNING" == "Yes" ] && [ "$SQL_RUNNING" == "Yes" ]; then
    ok "MariaDB 复制已启动 (IO: Yes, SQL: Yes)"
    # 强制设为只读 (防止双写)
    docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "SET GLOBAL read_only=ON;"
else
    err "MariaDB 复制启动失败！请检查日志或密码是否正确。\n状态: IO=$IO_RUNNING, SQL=$SQL_RUNNING"
fi

# 5. 流量层归队 (ProxySQL)
log "正在修正 ProxySQL 路由..."

# 修正路由表：将 HG 10 (写) 指向新 Master，确保 HG 20 (读) 包含所有节点
docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-EOF
    -- 1. 清空写组，指向新主
    DELETE FROM mysql_servers WHERE hostgroup_id=10;
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '${NEW_MASTER_IP}', 3306);
    
    -- 2. 确保读组里有所有节点 (使用 REPLACE 防止重复报错)
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_1_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_2_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_3_IP}', 3306);
    
    -- 3. 落地生效
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
EOF

ok "ProxySQL 路由已更新 (Writer -> ${NEW_MASTER_IP})"

# 6. 重启监控
log "重启 HA Monitor..."
# 杀死旧的监控进程 (防止多开)
pkill -f monitor.sh || true
# 后台启动新监控
nohup "${BASE_DIR}/scripts/monitor.sh" > /var/log/ha-monitor.log 2>&1 &

echo "----------------------------------------------------------"
ok "✅ 归队完成！本机已作为 Slave 加入集群，并开始监控 Master。"
echo "----------------------------------------------------------"