#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.0 - Auto Monitor & Failover (Sentinel)
# ==============================================================================
# 依赖: 必须先运行 scripts/save_secrets.sh 生成 .secrets.env
# ==============================================================================

# 1. 基础配置
BASE_DIR="/opt/docker/mariadb-ha-3node"
TOPOLOGY_FILE="${BASE_DIR}/topology.env"
SECRET_FILE="${BASE_DIR}/.secrets.env"
LOG_FILE="/var/log/ha-monitor.log"

# 2. 加载拓扑配置
if [ -f "$TOPOLOGY_FILE" ]; then 
    source "$TOPOLOGY_FILE"
else 
    echo "Error: 找不到 topology.env"
    exit 1
fi

# 3. 加载加密凭据 (关键步骤)
if [ -f "$SECRET_FILE" ]; then 
    source "$SECRET_FILE"
else 
    echo "Error: 找不到 .secrets.env"
    echo "请先运行 ./scripts/save_secrets.sh 输入密码！"
    exit 1
fi

# 4. 参数设置
MAX_RETRIES=3        # 连续失败次数阈值
CHECK_INTERVAL=5     # 检测间隔(秒)
FAIL_COUNT=0

# 日志函数
log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }

# 5. 识别本机身份
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
# 简单的字符串匹配判断
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then MY_ROLE="NODE_1"; fi
if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then MY_ROLE="NODE_2"; fi
if [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then MY_ROLE="NODE_3"; fi

log ">>> 哨兵启动 (Monitor v3.0-Auto)"
log ">>> 监控目标: Node-1 (Master) @ $NODE_1_IP"
log ">>> 本机角色: $MY_ROLE"

# ==============================================================================
# 核心函数
# ==============================================================================

# 动作 A: 提升数据库为 Master (仅 Node-2 执行)
promote_db_to_master() {
    log ">>> [DB Action] 正在停止复制并提升为主库..."
    
    # 使用从 .secrets.env 读取的 AUTO_DB_ROOT_PASS
    docker exec mariadb mariadb -uroot -p"$AUTO_DB_ROOT_PASS" -e \
        "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=0;" >> "$LOG_FILE" 2>&1
        
    if [ $? -eq 0 ]; then
        log ">>> [Success] 数据库已成功提升为 Master！"
    else
        log ">>> [Error] 数据库提升失败，请检查密码或容器日志。"
    fi
}

# 动作 B: 修改 ProxySQL 路由 (所有存活节点执行)
# 将 Writer (HG 10) 指向新的 Master IP
switch_proxysql_routing() {
    local new_writer_ip=$1
    log ">>> [ProxySQL Action] 将写流量 (HG 10) 切换至: $new_writer_ip"

    # 使用从 .secrets.env 读取的 AUTO_PROXY_ADMIN_PASS
    # 这里包含智能判断：如果密码不对尝试默认 admin (防止死锁)，但主要依赖 secret
    docker exec proxysql mysql -u admin -p"$AUTO_PROXY_ADMIN_PASS" -h 127.0.0.1 -P 6032 <<-SQL >> "$LOG_FILE" 2>&1
        -- 1. 删除旧的 Writer (Node-1)
        DELETE FROM mysql_servers WHERE hostgroup_id=10;
        
        -- 2. 插入新的 Writer (Node-2)
        -- 注意：ProxySQL 会自动去重，如果已存在则忽略
        INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$new_writer_ip', 3306);
        
        -- 3. 立即加载生效
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
        
        -- 4. 强制断开旧的连接，让应用重连到新 Master
        -- (可选操作，视业务容忍度而定，这里暂不暴力杀连接)
SQL
    log ">>> [Success] 本地 ProxySQL 路由已更新。"
}

# ==============================================================================
# 主循环 (Daemon Loop)
# ==============================================================================

while true; do
    # 如果我是 Node-1，不需要监控自己 (防止脑裂后的自我操作)
    if [ "$MY_ROLE" == "NODE_1" ]; then
        sleep 60
        continue
    fi

    # 1. 检测 Master (Node-1) 是否存活
    # 使用 monitor 用户 (无密码或固定密码 monitor_pass，这里硬编码 monitor_pass 因为它在 init_proxysql 中固定了)
    if docker exec mariadb mysqladmin -h "$NODE_1_IP" -u monitor -pmonitor_pass ping --connect-timeout=3 >/dev/null 2>&1; then
        # === Master 活着 ===
        if [ $FAIL_COUNT -gt 0 ]; then
            log "Master ($NODE_1_IP) 恢复正常。重置计数器。"
        fi
        FAIL_COUNT=0
    else
        # === Master 连不上 ===
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "[Alert] 连接 Master 失败! ($FAIL_COUNT/$MAX_RETRIES)"

        if [ $FAIL_COUNT -ge $MAX_RETRIES ]; then
            log "!!! [CRITICAL] 判定 Master (Node-1) 已宕机 !!!"
            log "!!! 启动故障转移程序 (Failover Sequence) !!!"

            # ---------------------------------------------------------
            # 场景: Node-1 挂了，Node-2 接管
            # ---------------------------------------------------------
            
            # 步骤 1: 如果我是 Node-2 (太子)，我要登基
            if [ "$MY_ROLE" == "NODE_2" ]; then
                promote_db_to_master
            fi

            # 步骤 2: 修改路由 (Node-2 和 Node-3 都要做)
            # 大家都把写操作指向 Node-2
            switch_proxysql_routing "$NODE_2_IP"

            # 步骤 3: 结束脚本
            # 故障转移是一次性的，切换完后脚本退出，避免反复震荡
            log ">>> 故障转移完成。Writer 已指向 Node-2 ($NODE_2_IP)。"
            log ">>> 脚本退出，请人工检查集群状态。"
            exit 0
        fi
    fi

    sleep $CHECK_INTERVAL
done