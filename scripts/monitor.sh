#!/bin/bash
# ==============================================================================
# MariaDB HA v4.0 - Mutual Exclusion Monitor (互斥仲裁哨兵)
# ==============================================================================
# 核心特性:
#   1. 优先级协商：Node 1 > Node 2 > Node 3，彻底根除双主脑裂。
#   2. 礼让机制：低优先级节点在故障时强制等待，优先由高优先级节点接管。
#   3. TCP 探测：强制使用 -h127.0.0.1 避开 Socket 竞争。
#   4. 动态寻主：永远以 ProxySQL 的 HG 10 配置作为监控准则。
# ==============================================================================

set -u

# 1. 基础配置
BASE_DIR="/opt/docker/mariadb-ha-3node"
TOPOLOGY_FILE="${BASE_DIR}/topology.env"
SECRET_FILE="${BASE_DIR}/.secrets.env"
LOG_FILE="/var/log/ha-monitor.log"

# 2. 加载配置与凭据
if [ -f "$TOPOLOGY_FILE" ]; then source "$TOPOLOGY_FILE"; else exit 1; fi
if [ -f "$SECRET_FILE" ]; then source "$SECRET_FILE"; else exit 1; fi

# 3. 参数设置
MAX_RETRIES=3
CHECK_INTERVAL=5
FAIL_COUNT=0

# 日志函数
log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }

# 4. 识别本机身份与优先级 (Node1=10, Node2=20, Node3=30)
LOCAL_IPS=$(hostname -I)
MY_PRIO=99
MY_IP=""
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then MY_PRIO=10; MY_IP="$NODE_1_IP"; fi
if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then MY_PRIO=20; MY_IP="$NODE_2_IP"; fi
if [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then MY_PRIO=30; MY_IP="$NODE_3_IP"; fi

log "=========================================================="
log ">>> 哨兵启动 (Monitor v4.0 Mutual Exclusion)"
log ">>> 本机优先级: $MY_PRIO (IP: $MY_IP)"
log "=========================================================="

# ==============================================================================
# 辅助函数
# ==============================================================================

# 从 ProxySQL 动态获取当前写库 (Master) 的 IP
get_current_master() {
    docker exec -e MYSQL_PWD="$AUTO_PROXY_ADMIN_PASS" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -N -e "SELECT hostname FROM mysql_servers WHERE hostgroup_id=10 LIMIT 1;" 2>/dev/null | tail -n 1 | tr -d '\r' | tr -d ' '
}

# 探测节点是否存活 (使用 Root 账号通过 TCP 探测)
check_node_health() {
    local target_ip=$1
    if docker exec -e MYSQL_PWD="$AUTO_DB_ROOT_PASS" mariadb mariadb -h "$target_ip" -uroot -N -e "SELECT 1;" --connect-timeout=2 >/dev/null 2>&1; then
        return 0 # Alive
    fi
    return 1 # Dead
}

# 检查节点是否已经是 Master (read_only=OFF)
is_node_master() {
    local target_ip=$1
    local ro
    ro=$(docker exec -e MYSQL_PWD="$AUTO_DB_ROOT_PASS" mariadb mariadb -h "$target_ip" -uroot -N -e "SELECT @@read_only;" 2>/dev/null | tail -n 1 | tr -d '\r' | tr -d ' ')
    if [ "$ro" == "0" ] || [ "${ro^^}" == "OFF" ]; then return 0; fi # 是主
    return 1 # 还是从
}

# 提升本机为 Master
promote_self_to_master() {
    log ">>> [DB Action] 我是优先级最高的存活节点，正在提升为主库..."
    docker exec -e MYSQL_PWD="$AUTO_DB_ROOT_PASS" mariadb mariadb -h 127.0.0.1 -uroot -e \
        "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=0;" >> "$LOG_FILE" 2>&1
    log ">>> [Success] 数据库提升完成。"
}

# 切换本地 ProxySQL 路由
switch_proxysql_routing() {
    local new_writer_ip=$1
    log ">>> [ProxySQL Action] 修正路由表 (HG 10) -> $new_writer_ip"
    docker exec -i -e MYSQL_PWD="$AUTO_PROXY_ADMIN_PASS" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL >> "$LOG_FILE" 2>&1
        DELETE FROM mysql_servers WHERE hostgroup_id=10;
        INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$new_writer_ip', 3306);
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
SQL
}

# ==============================================================================
# 主循环
# ==============================================================================

while true; do
    CURRENT_MASTER=$(get_current_master)
    
    if [ -z "$CURRENT_MASTER" ]; then
        log "[Warn] ProxySQL 尚未初始化主库路由，等待中..."
        sleep $CHECK_INTERVAL
        continue
    fi

    if check_node_health "$CURRENT_MASTER"; then
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "[Alert] 目标 $CURRENT_MASTER 连接失败 ($FAIL_COUNT/$MAX_RETRIES)"

        if [ $FAIL_COUNT -ge $MAX_RETRIES ]; then
            log "!!! [CRITICAL] 判定 Master ($CURRENT_MASTER) 已宕机 !!!"
            
            # --- [核心选举仲裁逻辑] ---
            NEW_MASTER=""
            
            # 1. 确定谁才是合法的继任者 (按 1 > 2 > 3 排序)
            CANDIDATE_LIST=("$NODE_1_IP" "$NODE_2_IP" "$NODE_3_IP")
            for ip in "${CANDIDATE_LIST[@]}"; do
                if [ "$ip" == "$CURRENT_MASTER" ]; then continue; fi
                if check_node_health "$ip"; then
                    NEW_MASTER="$ip"
                    break # 找到最高优先级的幸存者
                fi
            done

            if [ -z "$NEW_MASTER" ]; then
                log "[Fatal] 全线崩溃，无存活节点！"
                FAIL_COUNT=0; sleep 10; continue
            fi

            log ">>> 选举共识：幸存者中优先级最高的是 $NEW_MASTER"

            # 2. 角色行为分支
            if [ "$MY_IP" == "$NEW_MASTER" ]; then
                # 如果我是最高优先级节点，立刻上位
                promote_self_to_master
                switch_proxysql_routing "$MY_IP"
            else
                # 如果我不是最高优先级，执行“礼让等待”
                log ">>> [Arbitration] 我不是最高优先级，礼让 10 秒给 $NEW_MASTER 上位..."
                sleep 10
                # 检查新主是否已经上位成功
                if is_node_master "$NEW_MASTER"; then
                    log ">>> [Success] 检测到 $NEW_MASTER 已成功上位。"
                else
                    log ">>> [Warn] $NEW_MASTER 似乎上位失败，下一轮循环重新仲裁。"
                    FAIL_COUNT=0; continue
                fi
                switch_proxysql_routing "$NEW_MASTER"
            fi
            
            log ">>> 故障转移流程结束。当前集群 Master: $NEW_MASTER"
            FAIL_COUNT=0
            sleep 3
        fi
    fi
    sleep $CHECK_INTERVAL
done