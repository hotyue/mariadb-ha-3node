#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/bootstrap/lib/log.sh"
source "${ROOT_DIR}/bootstrap/lib/mysql.sh"

ORC_CONTAINER="orchestrator"
MASTER="mariadb-1"

log_info "!!! WARNING: Starting Failover Test (killing ${MASTER}) !!!"

# 1. 确认当前主库
CURRENT_MASTER=$(docker exec "${ORC_CONTAINER}" orchestrator-client -c master -i "mariadb-ha" | cut -d':' -f1)
log_info "Current master detected by Orchestrator: ${CURRENT_MASTER}"

# 2. 模拟故障
log_info "Stopping container: ${CURRENT_MASTER}"
docker stop "${CURRENT_MASTER}" >/dev/null

# 3. 等待 Orchestrator 检测并触发切换 (通常需要 10-30 秒)
log_info "Waiting for Orchestrator to promote a new master..."
NEW_MASTER=""
for i in {1..20}; do
    sleep 3
    CHECK=$(docker exec "${ORC_CONTAINER}" orchestrator-client -c master -i "mariadb-ha" 2>/dev/null | cut -d':' -f1 || true)
    if [[ -n "${CHECK}" && "${CHECK}" != "${CURRENT_MASTER}" ]]; then
        NEW_MASTER="${CHECK}"
        break
    fi
    log_info "  - Still waiting... (${i}/20)"
done

if [[ -z "${NEW_MASTER}" ]]; then
    log_error "Failover FAILED: Orchestrator did not promote a new master in time."
    exit 1
fi

log_info "SUCCESS: New master promoted: ${NEW_MASTER}"

# 4. 验证 ProxySQL 是否更新路由
log_info "Checking ProxySQL routing status..."
sleep 5 # 给 ProxySQL Monitor 一点探测时间
WRITER_HOST=$(docker exec proxysql mariadb -uadmin -padmin -h127.0.0.1 -P6032 -Nse \
    "SELECT hostname FROM runtime_mysql_servers WHERE hostgroup_id=10 AND status='ONLINE';")

if [[ "${WRITER_HOST}" == "${NEW_MASTER}" ]]; then
    log_info "SUCCESS: ProxySQL updated writer hostgroup to ${NEW_MASTER}"
else
    log_error "FAILURE: ProxySQL still pointing to ${WRITER_HOST} instead of ${NEW_MASTER}"
    exit 1
fi

log_info "Failover verification complete. Remember to start ${CURRENT_MASTER} back up!"