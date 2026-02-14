#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.5 - Enterprise Auto Monitor (企业级动态哨兵)
# ==============================================================================
# 核心特性:
#   1. 动态寻主: 自动从 ProxySQL 读取当前 Master IP 进行监控。
#   2. 确定性选举: 宕机后按优先级 (Node 1 > 2 > 3) 自动推举新 Master。
#   3. 无限守护: 切换完成后不退出，继续监控新 Master。
#   4. 抗干扰: 过滤 SSL 警告，完美兼容特殊字符密码。
# ==============================================================================

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

# 4. 识别本机身份与 IP
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
MY_IP=""
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then MY_ROLE="NODE_1"; MY_IP="$NODE_1_IP"; fi
if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then MY_ROLE="NODE_2"; MY_IP="$NODE_2_IP"; fi
if [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then MY_ROLE="NODE_3"; MY_IP="$NODE_3_IP"; fi

log "=========================================================="
log ">>> 哨兵启动 (Monitor v3.5 Enterprise)"
log ">>> 本机角色: $MY_ROLE ($MY_IP)"
log "=========================================================="

# ==============================================================================
# 辅助函数
# ==============================================================================

# 从 ProxySQL 动态获取当前写库 (Master) 的 IP
get_current_master() {
    local master_ip
    # 查询 HG 10，过滤 SSL 警告，提取纯 IP
    master_ip=$(docker exec -e MYSQL_PWD="$AUTO_PROXY_ADMIN_PASS" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -N -e "SELECT hostname FROM mysql_servers WHERE hostgroup_id=10 LIMIT 1;" 2>/dev/null | tail -n 1 | tr -d '\r' | tr -d ' ')
    echo "$master_ip"
}

# 探测节点是否存活 (使用 Root 账号直连探测)
check_node_health() {
    local target_ip=$1
    if docker exec -e MYSQL_PWD="$AUTO_DB_ROOT_PASS" mariadb mariadb -h "$target_ip" -uroot -N -e "DO 1;" --connect-timeout=3 >/dev/null 2>&1; then
        return 0 # Alive
    fi
    return 1 # Dead
}

# 提升本机为 Master
promote_self_to_master() {
    log ">>> [DB Action] 我是新任 Master！正在停止复制并解锁读写..."
    docker exec -e MYSQL_PWD="$AUTO_DB_ROOT_PASS" mariadb mariadb -uroot -e \
        "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=0;" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        log ">>> [Success] 数据库提升成功！"
    else
        log ">>> [Error] 数据库提升失败！"
    fi
}

# 切换本地 ProxySQL 路由
switch_proxysql_routing() {
    local new_writer_ip=$1
    log ">>> [ProxySQL Action] 更新本地路由表 (HG 10) 指向: $new_writer_ip"
    docker exec -e MYSQL_PWD="$AUTO_PROXY_ADMIN_PASS" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL >> "$LOG_FILE" 2>&1
        DELETE FROM mysql_servers WHERE hostgroup_id=10;
        INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$new_writer_ip', 3306);
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
SQL
    log ">>> [Success] 本地 ProxySQL 路由已刷新。"
}

# ==============================================================================
# 主循环 (无限守护)
# ==============================================================================

while true; do
    # 1. 动态获取当前 Master
    CURRENT_MASTER=$(get_current_master)
    
    if [ -z "$CURRENT_MASTER" ]; then
        log "[Warn] 无法从 ProxySQL 读取当前 Master，可能 ProxySQL 尚未就绪，重试中..."
        sleep $CHECK_INTERVAL
        continue
    fi

    # 2. 检查当前 Master 是否存活
    if check_node_health "$CURRENT_MASTER"; then
        # === Master 活着 ===
        if [ $FAIL_COUNT -gt 0 ]; then
            log "[Recover] 监控目标 ($CURRENT_MASTER) 恢复正常。"
            FAIL_COUNT=0
        fi
    else
        # === Master 连不上 ===
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "[Alert] 目标 $CURRENT_MASTER 连接失败! ($FAIL_COUNT/$MAX_RETRIES)"

        # 达到最大重试次数，触发故障转移
        if [ $FAIL_COUNT -ge $MAX_RETRIES ]; then
            log "!!! [CRITICAL] 判定当前 Master ($CURRENT_MASTER) 已宕机 !!!"
            log "!!! 启动自动选举与故障转移程序 !!!"
            
            # 选举逻辑: 按节点优先级 (Node 1 > 2 > 3) 寻找活着的节点
            NEW_MASTER=""
            for ip in "$NODE_1_IP" "$NODE_2_IP" "$NODE_3_IP"; do
                # 排除死掉的前任
                if [ "$ip" == "$CURRENT_MASTER" ] || [ -z "$ip" ]; then continue; fi
                
                if check_node_health "$ip"; then
                    NEW_MASTER="$ip"
                    break # 找到最高优先级的存活节点，立刻停止选举
                fi
            done

            if [ -z "$NEW_MASTER" ]; then
                log "[Fatal] 所有备用节点均无法连接！集群完全瘫痪！"
                FAIL_COUNT=0
                sleep 10
                continue
            fi

            log ">>> 选举结果: 新 Master 是 $NEW_MASTER"

            # 执行转移步骤 A: 如果自己被选为主，则提升自己
            if [ "$MY_IP" == "$NEW_MASTER" ]; then
                promote_self_to_master
            fi

            # 执行转移步骤 B: 所有人更新自己的 ProxySQL
            switch_proxysql_routing "$NEW_MASTER"
            
            log ">>> 故障转移完成！集群现由 $NEW_MASTER 接管。"
            
            # 重置计数器，下一轮循环将自动监控新 Master (无限守护)
            FAIL_COUNT=0
            log ">>> 哨兵重置，开始监控新目标..."
            sleep 3
        fi
    fi

    # 休息一下进入下一轮探测
    sleep $CHECK_INTERVAL
done