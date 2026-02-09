#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${RUNTIME_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/bootstrap/lib"

# 引入日志和 MySQL 库
source "${ROOT_DIR}/bootstrap/lib/log.sh"
source "${LIB_DIR}/mysql.sh"

log_info "--- MariaDB HA Cluster Status ---"

log_info "Containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
  | grep -E 'mariadb-|proxysql|orchestrator' || true

echo
log_info "Replication Status (Slaves):"
for node in "mariadb-2" "mariadb-3"; do
    printf "[%s]: " "${node}"
    # 使用 mysql_query_value 避免密码警告
    mysql_query_value "${node}" "SHOW SLAVE STATUS\G" | grep -E "Slave_(IO|SQL)_Running" | xargs || echo "Not configured"
done

echo
log_info "ProxySQL Backend Health:"
if [ -f "${ROOT_DIR}/healthcheck/proxysql.sh" ]; then
    bash "${ROOT_DIR}/healthcheck/proxysql.sh" || true
else
    # 回退方案：直接查表
    docker exec proxysql mariadb -uadmin -padmin -h127.0.0.1 -P6032 -e \
      "SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers;" || true
fi

echo
log_info "Orchestrator Health:"
curl -s "http://localhost:3000/api/health" | grep "OK" && echo "API: OK" || echo "API: Unreachable"

log_info "--- Status Check Completed ---"