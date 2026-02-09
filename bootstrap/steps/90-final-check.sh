#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=../lib/mysql.sh
source "${LIB_DIR}/mysql.sh"

PROXYSQL_CONTAINER="proxysql"
ORC_CONTAINER="orchestrator"

log_info "starting final cluster health check..."

# 1. 检查 MariaDB 复制状态
log_info "[Check 1/4] MariaDB Replication"
for node in "mariadb-2" "mariadb-3"; do
    IO_RUNNING=$(mysql_query_value "${node}" "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(mysql_query_value "${node}" "SHOW SLAVE STATUS\G" | grep "Slave_SQL_Running:" | awk '{print $2}')
    
    if [[ "${IO_RUNNING}" == "Yes" && "${SQL_RUNNING}" == "Yes" ]]; then
        log_info "  - ${node}: Replication OK"
    else
        log_error "  - ${node}: Replication FAILED (IO: ${IO_RUNNING}, SQL: ${SQL_RUNNING})"
        exit 1
    fi
done

# 2. 检查 ProxySQL 后端识别
log_info "[Check 2/4] ProxySQL Backends"
# 统计 ONLINE 状态的后端数量
ONLINE_NODES=$(docker exec "${PROXYSQL_CONTAINER}" mariadb -uadmin -padmin -h127.0.0.1 -P6032 -Nse \
    "SELECT COUNT(*) FROM runtime_mysql_servers WHERE status='ONLINE';")

if [ "${ONLINE_NODES}" -ge 3 ]; then
    log_info "  - ProxySQL: All 3 nodes are ONLINE"
else
    log_error "  - ProxySQL: Only ${ONLINE_NODES} nodes are ONLINE"
    exit 1
fi

# 3. 检查 Orchestrator 拓扑接管
log_info "[Check 3/4] Orchestrator Topology"
# 获取 orchestrator 发现的实例数量
INSTANCES=$(docker exec "${ORC_CONTAINER}" orchestrator-client -c clusters | wc -l)

if [ "${INSTANCES}" -gt 0 ]; then
    log_info "  - Orchestrator: Topology discovered"
else
    log_warn "  - Orchestrator: No clusters found yet (discovery might be in progress)"
fi

# 4. 业务用户访问测试 (通过 ProxySQL 6033 端口)
log_info "[Check 4/4] Application User Access (via ProxySQL)"
if docker exec "${PROXYSQL_CONTAINER}" mariadb -uapp -papppass -h127.0.0.1 -P6033 -e "SELECT @@server_id;" >/dev/null 2>&1; then
    log_info "  - App access test: OK"
else
    log_error "  - App access test: FAILED"
    exit 1
fi

echo "---------------------------------------------------------------"
log_info "CONGRATULATIONS! MariaDB HA Cluster is ready."
log_info "Endpoints:"
log_info "  - ProxySQL (App):   localhost:6033"
log_info "  - ProxySQL (Admin): localhost:6032"
log_info "  - Orchestrator Web: http://localhost:3000"
echo "---------------------------------------------------------------"