#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v4.0 - 节点智能归队程序 (Auto-Rejoin 终极版)
# ==============================================================================
# 核心升级:
#   1. 智能冷启动探测：取代死板 sleep，确保容器内部 mysqld 就绪后再执行 SQL。
#   2. 绝对路径自适应：完美支持 Systemd 开机自启环境。
#   3. 全量凭据静默流转：支持复杂密码转义与 SSL 警告过滤。
#   4. 哨兵守护：配合 KillMode=process 确保归队后监控进程持续运行。
# ==============================================================================

# 自动获取脚本绝对路径，确保 Systemd 环境下能定位到同级脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 加载配置
if [ -f "${BASE_DIR}/topology.env" ]; then source "${BASE_DIR}/topology.env"; fi
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
echo -e "${BLUE}>>> MariaDB HA 节点归队程序 (v4.0 Auto-Pilot)${NC}"
echo "----------------------------------------------------------"

# ==============================================================================
# 1. 自动环境修复与智能就绪探测
# ==============================================================================
# 检查容器状态
if [ "$(docker inspect -f '{{.State.Running}}' mariadb 2>/dev/null)" != "true" ]; then
    log "检测到 MariaDB 容器未运行，正在执行自动启动..."
    docker start mariadb
fi

# 加载凭据用于探测
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
else
    err "未找到 .secrets.env 文件！无法执行静默归队。"
fi

log "正在等待 MariaDB 内部 SQL 服务就绪..."
DB_READY=false
for i in {1..30}; do
    # 探测本地数据库是否响应，同时过滤掉可能的客户端 SSL 警告
    if docker exec -e MYSQL_PWD="${AUTO_DB_ROOT_PASS}" mariadb mariadb -uroot -e "SELECT 1;" >/dev/null 2>&1; then
        DB_READY=true
        ok "MariaDB 内部服务已就绪。"
        break
    fi
    sleep 2
done

if [ "$DB_READY" = false ]; then
    err "等待超时！MariaDB 容器启动后无法在 60s 内响应 SQL 请求。"
fi

# ==============================================================================
# 2. 扫描集群寻找当前真 Master (分布式寻主)
# ==============================================================================
log "正在扫描集群寻找当前活跃 Master..."
NEW_MASTER_IP=""

for IP in "$NODE_1_IP" "$NODE_2_IP" "$NODE_3_IP"; do
    # 跳过本机 IP
    if [[ "$(hostname -I)" == *"$IP"* ]]; then continue; fi
    
    # 远程探测 Master (read_only 必须为 0 或 OFF)
    # tr 清理不可见字符，tail 过滤 SSL 警告
    is_ro=$(docker exec -e MYSQL_PWD="${AUTO_DB_ROOT_PASS}" mariadb mariadb -uroot -h "$IP" -N -e "SELECT @@read_only;" 2>/dev/null | tail -n 1 | tr -d '\r' | tr -d ' ')
    
    if [ "$is_ro" == "0" ] || [ "${is_ro^^}" == "OFF" ]; then
        NEW_MASTER_IP="$IP"
        break
    fi
done

if [ -z "${NEW_MASTER_IP}" ]; then
    err "归队中止：集群中未发现可写状态 (read_only=OFF) 的 Master 节点。"
fi
ok "发现当前集群 Master: ${NEW_MASTER_IP}"

# ==============================================================================
# 3. 执行归队：重置复制、修正路由、重启哨兵
# ==============================================================================
echo "----------------------------------------------------------"
log "即将在本机执行自愈操作..."
log "1. 停止 Slave 进程并重置拓扑记忆"
log "2. 指向活跃 Master: ${NEW_MASTER_IP}"
log "3. 强制同步本地 ProxySQL 路由表"
log "4. 在后台拉起监控哨兵"
echo "----------------------------------------------------------"

log "正在配置 MariaDB 复制关系..."
# 复杂密码转义处理
SAFE_REPL_PASS="${AUTO_REPL_PASS//\\/\\\\}"
SAFE_REPL_PASS="${SAFE_REPL_PASS//\'/\\\'}"

docker exec -i -e MYSQL_PWD="${AUTO_DB_ROOT_PASS}" mariadb mariadb -uroot <<-EOSQL
    STOP SLAVE;
    RESET SLAVE ALL;
    CHANGE MASTER TO 
        MASTER_HOST='${NEW_MASTER_IP}', 
        MASTER_PORT=${DB_PORT}, 
        MASTER_USER='${REPL_USER}', 
        MASTER_PASSWORD='${SAFE_REPL_PASS}', 
        MASTER_USE_GTID=slave_pos;
    START SLAVE;
    SET GLOBAL read_only=ON;
EOSQL

sleep 2
# 验证 IO 线程状态
IO_STATUS=$(docker exec -e MYSQL_PWD="${AUTO_DB_ROOT_PASS}" mariadb mariadb -uroot -e "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r')

if [ "$IO_STATUS" == "Yes" ]; then
    ok "MariaDB 复制链路已成功建立。"
else
    err "复制建立失败！请手动检查网络连接或 Master 复制账号权限。"
fi

log "正在同步本地 ProxySQL 路由规则..."
docker exec -i -e MYSQL_PWD="${AUTO_PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL
    DELETE FROM mysql_servers WHERE hostgroup_id=10;
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '${NEW_MASTER_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_1_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_2_IP}', 3306);
    REPLACE INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${NODE_3_IP}', 3306);
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
SQL
ok "ProxySQL 路由已修正：写流量 -> ${NEW_MASTER_IP}"

log "正在激活后台监控哨兵..."
pkill -f monitor.sh || true
# 使用绝对路径启动，确保在开机引导环境下的稳定性
nohup "${SCRIPT_DIR}/monitor.sh" > /var/log/ha-monitor.log 2>&1 &

echo "----------------------------------------------------------"
ok "✅ 归队完成！本机状态已恢复，哨兵已开始监控 Master 节点。"
echo "----------------------------------------------------------"