#!/bin/bash
set -u

# =================配置区域=================
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"

# 日志与状态
LOG_FILE="/var/log/ha-monitor.log"
STATE_FILE="${BASE_DIR}/cluster_status.state"

# 阈值
MAX_RETRIES=3
CHECK_INTERVAL=5
# =========================================

log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }

# 1. 识别本机身份
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then MY_ROLE="NODE_1"; fi
if [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]]; then MY_ROLE="NODE_2"; fi
if [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then MY_ROLE="NODE_3"; fi

# 2. 获取当前的 Master IP (默认为 Node-1)
CURRENT_MASTER=$NODE_1_IP
if [ -f "$STATE_FILE" ]; then
    CURRENT_MASTER=$(cat "$STATE_FILE")
fi

# ------------------------------------------------------------------------------
# 动作：将本地 ProxySQL 的 Writer 指向新 Master
# ------------------------------------------------------------------------------
switch_proxysql_writer() {
    local new_master_ip=$1
    log ">>> [ProxySQL] 更新路由规则：Writer -> $new_master_ip"
    
    # 这里的密码我们在 topology.env 里没有存明文，
    # 实际生产中应使用配置文件的密码。这里为了简化演示，假设密码已知或通过 args 传入
    # v3.0 简化版：我们直接修改 mysql_servers 表
    
    # 注意：ProxySQL 容器里的 admin 密码此时应该是用户设置的那个
    # 这是一个难点：脚本如何知道用户设了什么 ProxySQL 密码？
    # 临时方案：尝试用默认 admin 或 topology.env 里的变量 (如果用户手动填入了)
    # 假设用户在 topology.env 里填了 PROXY_ADMIN_PASS (虽然 bootstrap 没填)
    
    # *关键*：因为无法获取 ProxySQL 密码，我们这里仅打印日志，
    # 真正的全自动需要将密码持久化到 topology.env
    log "[TODO] 请手动执行 ProxySQL 切换 (由于密码安全限制，脚本暂不自动修改 ProxySQL)"
    log "SQL: UPDATE mysql_servers SET hostgroup_id=10 WHERE hostname='$new_master_ip';"
}

# ------------------------------------------------------------------------------
# 动作：Node-2 晋升为 Master
# ------------------------------------------------------------------------------
promote_node2() {
    log "!!! 正在将本节点 (Node-2) 提升为 Master !!!"
    
    # 1. 停止复制
    docker exec mariadb mariadb -uroot -p"${DB_ROOT_PASS}" -e "STOP SLAVE; RESET SLAVE ALL;"
    
    # 2. 解除只读 (如果有)
    docker exec mariadb mariadb -uroot -p"${DB_ROOT_PASS}" -e "SET GLOBAL read_only=0;"
    
    log ">>> 晋升成功！Node-2 现在是新的 Master。"
    echo "$NODE_2_IP" > "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 动作：Node-3 指向新 Master (Node-2)
# ------------------------------------------------------------------------------
follow_node2() {
    log "!!! 正在将本节点 (Node-3) 指向新 Master (Node-2) !!!"
    
    # 1. 指向 Node-2
    # 注意：这里需要复制账号密码。v3.0 简化版假设 repl_user / 密码已知
    # 这是一个演示逻辑，实际需要从 Master 获取 Binlog 位置
    log "[注意] 请手动执行 CHANGE MASTER TO MASTER_HOST='$NODE_2_IP'..."
    
    echo "$NODE_2_IP" > "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 核心循环
# ------------------------------------------------------------------------------
FAIL_COUNT=0

log "哨兵启动。本机: $MY_ROLE, 当前Master: $CURRENT_MASTER"

while true; do
    # 如果我是当前 Master，不需要监控自己
    if [[ "$LOCAL_IPS" == *"$CURRENT_MASTER"* ]]; then
        sleep 60
        continue
    fi

    # 检测 Master 健康
    if docker exec mariadb mysqladmin -h "$CURRENT_MASTER" -u monitor -pmonitor_pass ping --connect-timeout=3 >/dev/null 2>&1; then
        # 健康
        if [ $FAIL_COUNT -gt 0 ]; then log "Master ($CURRENT_MASTER) 恢复正常。"; fi
        FAIL_COUNT=0
    else
        # 异常
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "[警告] 无法连接 Master ($CURRENT_MASTER) - 重试 $FAIL_COUNT/$MAX_RETRIES"
        
        if [ $FAIL_COUNT -ge $MAX_RETRIES ]; then
            log "[CRITICAL] Master 确认宕机！"
            
            # 触发故障转移
            if [ "$MY_ROLE" == "NODE_2" ] && [ "$CURRENT_MASTER" == "$NODE_1_IP" ]; then
                promote_node2
                CURRENT_MASTER=$NODE_2_IP
            elif [ "$MY_ROLE" == "NODE_3" ] && [ "$CURRENT_MASTER" == "$NODE_1_IP" ]; then
                follow_node2
                CURRENT_MASTER=$NODE_2_IP
            fi
            
            # 避免重复触发
            sleep 300
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
