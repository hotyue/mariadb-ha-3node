#!/bin/bash
set -u

# ==============================================================================
# MariaDB HA v3.2 - Auto Monitor (EnvVar Injection)
# ==============================================================================
# 依赖: 必须先运行 scripts/save_secrets.sh 生成 .secrets.env
# Fix 1: 使用 MYSQL_PWD 环境变量传递密码，彻底支持特殊字符 (*, #, @, !)
# Fix 2: 兼容性健康检查 (mariadb-admin / mysqladmin / SQL)
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

# 3. 加载加密凭据
if [ -f "$SECRET_FILE" ]; then 
    source "$SECRET_FILE"
else 
    echo "Error: 找不到 .secrets.env"
    echo "请先运行 ./scripts/save_secrets.sh 输入密码！"
    exit 1
fi

# 4. 参数设置
MAX_RETRIES=3
CHECK_INTERVAL=5
FAIL_COUNT=0

# 日志函数
log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }

# 5. 识别本机身份
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then MY_ROLE="NODE_1"; fi
if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then MY_ROLE="NODE_2"; fi
if [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then MY_ROLE="NODE_3"; fi

log ">>> 哨兵启动 (Monitor v3.2-EnvVar)"
log ">>> 监控目标: Node-1 ($NODE_1_IP)"
log ">>> 本机角色: $MY_ROLE"

# ==============================================================================
# 辅助函数: 健康检查 (兼容性增强)
# ==============================================================================
check_master_health() {
    local target_ip=$1
    # 方法 A: 尝试 mariadb-admin (新版容器标准工具)
    if docker exec mariadb mariadb-admin -h "$target_ip" -u monitor -pmonitor_pass ping --connect-timeout=3 >/dev/null 2>&1; then
        return 0
    fi
    
    # 方法 B: 尝试 mysqladmin (旧版容器兼容)
    if docker exec mariadb mysqladmin -h "$target_ip" -u monitor -pmonitor_pass ping --connect-timeout=3 >/dev/null 2>&1; then
        return 0
    fi
    
    # 方法 C: 尝试 SQL 简单查询 (最底层兜底，只要能连上就算活)
    if docker exec mariadb mariadb -h "$target_ip" -u monitor -pmonitor_pass -e "DO 1;" --connect-timeout=3 >/dev/null 2>&1; then
        return 0
    fi

    # 全部失败，判定为挂了
    return 1
}

# ==============================================================================
# 核心函数 (使用环境变量注入密码)
# ==============================================================================

promote_db_to_master() {
    log ">>> [DB Action] 正在停止复制并提升为主库..."
    
    # [FIX] 使用 -e MYSQL_PWD 传递 Root 密码
    # 避免 CLI 参数解析问题 (如 # 被视为注释)
    docker exec -e MYSQL_PWD="$AUTO_DB_ROOT_PASS" mariadb mariadb -uroot -e \
        "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=0;" >> "$LOG_FILE" 2>&1
        
    if [ $? -eq 0 ]; then
        log ">>> [Success] 数据库已成功提升为 Master！"
    else
        log ">>> [Error] 数据库提升失败，请检查密码或容器日志。"
    fi
}

switch_proxysql_routing() {
    local new_writer_ip=$1
    log ">>> [ProxySQL Action] 将写流量 (HG 10) 切换至: $new_writer_ip"

    # [FIX] 使用 -e MYSQL_PWD 传递 Admin 密码
    # 这里是处理特殊字符最关键的地方
    docker exec -e MYSQL_PWD="$AUTO_PROXY_ADMIN_PASS" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL >> "$LOG_FILE" 2>&1
        -- 1. 删除旧的 Writer
        DELETE FROM mysql_servers WHERE hostgroup_id=10;
        
        -- 2. 插入新的 Writer
        INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$new_writer_ip', 3306);
        
        -- 3. 生效
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
SQL
    
    # 增加简单的退出码检查
    if [ $? -eq 0 ]; then
        log ">>> [Success] 本地 ProxySQL 路由已更新。"
    else
        log ">>> [Error] ProxySQL 更新失败 (Access Denied 或 容器未运行)。"
    fi
}

# ==============================================================================
# 主循环
# ==============================================================================

while true; do
    if [ "$MY_ROLE" == "NODE_1" ]; then sleep 60; continue; fi

    # 调用兼容性检测函数
    if check_master_health "$NODE_1_IP"; then
        # === Master 活着 ===
        if [ $FAIL_COUNT -gt 0 ]; then
            log "Master ($NODE_1_IP) 恢复正常。"
        fi
        FAIL_COUNT=0
    else
        # === Master 连不上 ===
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "[Alert] 连接 Master 失败! ($FAIL_COUNT/$MAX_RETRIES)"

        if [ $FAIL_COUNT -ge $MAX_RETRIES ]; then
            log "!!! [CRITICAL] 判定 Master (Node-1) 已宕机 !!!"
            log "!!! 启动故障转移程序 !!!"
            
            # 1. 数据库层切换 (仅 Node-2)
            if [ "$MY_ROLE" == "NODE_2" ]; then
                promote_db_to_master
            fi

            # 2. 路由层切换 (Node-2 & Node-3)
            switch_proxysql_routing "$NODE_2_IP"

            log ">>> 故障转移完成。Writer 已指向 Node-2 ($NODE_2_IP)。"
            exit 0
        fi
    fi

    sleep $CHECK_INTERVAL
done
