#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.4.1 - Auto Rejoin Script (智能全自动修复版)
# ==============================================================================
# 核心升级:
#   1. 自动启动 MariaDB 容器 (解决 "未找到 Master" 报错)
#   2. 自动读取复制密码 (实现无人值守)
#   3. 自动修正 ProxySQL 路由表
#   4. [核心修复] 过滤 MariaDB 客户端 SSL 警告，兼容返回值为 0 或 OFF 的探测逻辑
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"
SECRETS_FILE="${BASE_DIR}/.secrets.env"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "----------------------------------------------------------"
echo ">>> MariaDB HA 节点归队程序 (v3.4.1 Auto)"
echo "----------------------------------------------------------"

# ==============================================================================
# 1. 自动环境修复 (关键步骤)
# ==============================================================================
# 检查 MariaDB 是否运行。如果宕机后容器是 Stop 状态，必须先启动才能探测。
if [ "$(docker inspect -f '{{.State.Running}}' mariadb 2>/dev/null)" != "true" ]; then
    log "检测到 MariaDB 容器未运行，正在执行自动启动..."
    docker start mariadb
    log "等待数据库冷启动就绪 (10s)..."
    sleep 10
else
    log "MariaDB 容器运行正常。"
fi

# ==============================================================================
# 2. 加载全量凭据
# ==============================================================================
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
    DB_ROOT_PASS="${AUTO_DB_ROOT_PASS}"
    PROXY_ADMIN_PASS="${AUTO_PROXY_ADMIN_PASS}"
    
    # [v3.4 新增] 自动读取复制密码
    REPL_PASS="${AUTO_REPL_PASS:-}"
else
    err "未找到 .secrets.env 文件！无法自动操作。"
fi

# 兼容性兜底: 如果是从旧版升级上来，文件里没存 REPL_PASS，则回退到手动输入
if [ -z "${REPL_PASS:-}" ]; then
    echo -e "${RED}[WARN] .secrets.env 中未找到 AUTO_REPL_PASS。${NC}"
    echo "请输入复制用户 (repl_user) 的密码:"
    read -r -s REPL_PASS
    echo ""
fi

# ==============================================================================
# 3. 扫描集群寻找新 Master
# ==============================================================================
log "正在扫描集群寻找当前 Master..."
NEW_MASTER_IP=""

check_if_master() {
    local target_ip=$1
    local local_ips=$(hostname -I)
    
    # 跳过本机
    if [[ "$local_ips" == *"$target_ip"* ]]; then return 1; fi

    # 远程探测: 必须是 Read_Only=OFF 才是 Master
    # [v3.4.1 修复] 使用 tail -n 1 过滤 SSL 警告，并清理回车和空格字符
    local is_ro
    is_ro=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -h "$target_ip" -N -e "SELECT @@read_only;" 2>/dev/null | tail -n 1 | tr -d '\r' | tr -d ' ')

    # 0 = OFF (Master), 1 = ON (Slave)，兼容最新版镜像返回的字符串 OFF
    if [ "$is_ro" == "0" ] || [ "${is_ro^^}" == "OFF" ]; then
        echo "$target_ip"
        return 0
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
    err "扫描失败！未找到任何在线的 Master 节点。\n可能原因: 集群全挂了，或者网络不通，或者目标 Master 也是 read_only=ON。"
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

# ==============================================================================
# 4. 数据库层归队 (MariaDB)
# ==============================================================================
log "正在配置 MariaDB 复制..."

# 停止复制，重置状态
docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "STOP SLAVE; RESET SLAVE ALL;"

# 配置新主库 (使用 GTID 自动定位)
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

if [ "$IO_RUNNING" == "Yes" ]; then
    ok "MariaDB 复制已启动 (IO: Yes)"
    # 强制设为只读 (防止双写)
    docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot -e "SET GLOBAL read_only=ON;"
else
    err "MariaDB 复制启动失败！请检查日志。"
fi

# ==============================================================================
# 5. 流量层归队 (ProxySQL)
# ==============================================================================
log "正在修正 ProxySQL 路由..."

# 修正路由表：将 HG 10 (写) 指向新 Master，将 HG 20 (读) 包含所有节点
# 注意：这里会清空 HG10 并重新指向新主，这是最安全的做法
docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-EOF
    DELETE FROM mysql_servers WHERE hostgroup_id=10;
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '${NEW_MASTER_IP}', 3306);
    
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_1_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_2_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_3_IP}', 3306);
    
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
EOF

ok "ProxySQL 路由表已更新 (Writer -> ${NEW_MASTER_IP})"

# ==============================================================================
# 6. 重启监控
# ==============================================================================
log "重启 HA Monitor..."
# 杀死旧的监控进程 (防止多开)
pkill -f monitor.sh || true
# 后台启动新监控
nohup "${BASE_DIR}/scripts/monitor.sh" > /var/log/ha-monitor.log 2>&1 &

echo "----------------------------------------------------------"
ok "✅ 归队完成！本机已作为 Slave 加入集群，并开始监控 Master。"
echo "----------------------------------------------------------"