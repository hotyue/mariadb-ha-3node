#!/usr/bin/env bash
set -u # 注意：不使用 -e，防止检测失败导致脚本直接退出

# =================配置区域=================
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "${BASE_DIR}/topology.env" ]; then
    echo "Error: topology.env not found."
    exit 1
fi
source "${BASE_DIR}/topology.env"

# 日志文件
LOG_FILE="/var/log/mariadb-ha-monitor.log"
# 状态文件 (记录当前谁是 Master)
STATE_FILE="${BASE_DIR}/current_master.state"

# 容错阈值 (检测失败多少次才算真挂了)
MAX_RETRIES=3
CHECK_INTERVAL=10
# =========================================

# 初始化日志
touch "$LOG_FILE"
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# 初始化状态
if [ ! -f "$STATE_FILE" ]; then
    echo "$NODE_1_IP" > "$STATE_FILE"
fi

# 获取本机角色和 IP
LOCAL_IPS=$(hostname -I)
MY_ID="UNKNOWN"

# 简单识别本机身份 (用于决定监控逻辑)
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then MY_ID="NODE_1"; fi
if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then MY_ID="NODE_2"; fi
if [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then MY_ID="NODE_3"; fi

log "哨兵启动。本机身份: $MY_ID"

# ------------------------------------------------------------------------------
# 核心函数: 检测 Master 健康状态
# ------------------------------------------------------------------------------
check_master_health() {
    local master_ip=$(cat "$STATE_FILE")
    
    # 如果本机就是 Master，那不需要监控自己 (或者监控外网连通性)
    if [[ "$LOCAL_IPS" == *"$master_ip"* ]]; then
        return 0
    fi

    # 使用 docker exec 调用 mysqladmin ping，避免宿主机依赖
    # 注意：这里我们 ping Master 的公网 IP
    # 设置超时时间 5 秒
    docker exec mariadb mysqladmin -h "$master_ip" -u root -p"$DB_ROOT_PASS" ping --connect-timeout=5 >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        return 0 # 健康
    else
        return 1 # 异常
    fi
}

# ------------------------------------------------------------------------------
# 核心函数: 触发故障转移 (Failover) - Phase 3 将填充此处
# ------------------------------------------------------------------------------
trigger_failover() {
    local old_master=$(cat "$STATE_FILE")
    log "!!! [CRITICAL] 确认 Master ($old_master) 已宕机 !!!"
    
    if [ "$MY_ID" == "NODE_2" ]; then
        log ">>> [Node-2] 我是第一顺位继承人，准备登基..."
        # TODO (Phase 3): 
        # 1. STOP SLAVE; RESET SLAVE ALL;
        # 2. 更新 ProxySQL 路由指向自己
        # 3. 更新 current_master.state
    elif [ "$MY_ID" == "NODE_3" ]; then
        log ">>> [Node-3] Master 挂了，我需要寻找新的 Master (Node-2)..."
        # TODO (Phase 3):
        # 1. CHANGE MASTER TO Node-2
        # 2. 更新 ProxySQL 路由指向 Node-2
    fi
}

# ------------------------------------------------------------------------------
# 主循环 (Daemon Loop)
# ------------------------------------------------------------------------------
FAIL_COUNT=0

while true; do
    # 1. 只有 Slave 节点才需要运行监控
    if [ "$MY_ID" == "NODE_1" ]; then
        # 如果我是 Master，我只需要活着 (可以加个简单的自检)
        sleep 60
        continue
    fi

    # 2. 执行检测
    if check_master_health; then
        # 如果成功，重置计数器
        if [ $FAIL_COUNT -gt 0 ]; then
            log "Master 恢复正常。($FAIL_COUNT -> 0)"
        fi
        FAIL_COUNT=0
    else
        # 如果失败，增加计数器
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "[WARN] 检测 Master 连接失败！重试计数: $FAIL_COUNT/$MAX_RETRIES"
        
        # 3. 判定故障
        if [ $FAIL_COUNT -ge $MAX_RETRIES ]; then
            trigger_failover
            
            # 避免重复触发，休眠更久或退出脚本等待人工介入(v3初期)
            sleep 60 
        fi
    fi

    sleep $CHECK_INTERVAL
done
