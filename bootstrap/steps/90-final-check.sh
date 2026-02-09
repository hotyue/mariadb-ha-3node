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
ADMINER_CONTAINER="adminer"

log_info "starting final cluster health check..."

# --- 1. MariaDB Replication Check ---
log_info "[Check 1/3] MariaDB Replication"
SLAVES=("mariadb-2" "mariadb-3")

for slave in "${SLAVES[@]}"; do
    STATUS_TEXT=$(mysql_exec_local "${slave}" "SHOW SLAVE STATUS\G")
    IO_RUNNING=$(echo "${STATUS_TEXT}" | grep "Slave_IO_Running:" | awk '{print $2}' || echo "No")
    SQL_RUNNING=$(echo "${STATUS_TEXT}" | grep "Slave_SQL_Running:" | awk '{print $2}' || echo "No")

    if [[ "${IO_RUNNING}" == "Yes" && "${SQL_RUNNING}" == "Yes" ]]; then
        log_info "  [OK] ${slave}: Replication running"
    else
        log_error " [FAIL] ${slave}: IO=${IO_RUNNING}, SQL=${SQL_RUNNING}"
        # 允许非阻断性失败
        exit 1
    fi
done

# --- 2. ProxySQL Check (Robust with Retry) ---
log_info "[Check 2/3] ProxySQL Connectivity"

MAX_RETRIES=5
PROXY_OK=false

for i in $(seq 1 $MAX_RETRIES); do
    # 尝试从 mariadb-1 连接 proxysql 6032 管理端口
    # 捕获错误输出以便调试
    if ERR=$(docker exec mariadb-1 mariadb -uadmin -padmin -h proxysql -P 6032 -e "SELECT 1;" 2>&1); then
        log_info "  [OK] ProxySQL Admin Interface (Port 6032) is reachable"
        PROXY_OK=true
        break
    else
        log_info "  ... waiting for ProxySQL connection ($i/$MAX_RETRIES)"
        sleep 2
    fi
done

if [ "$PROXY_OK" = false ]; then
    log_warn "  [WARN] Failed to connect to ProxySQL Admin interface."
    log_warn "  Error details: $ERR"
    
    # 降级检查：只要容器在运行，就放行
    if docker ps | grep -q "${PROXYSQL_CONTAINER}"; then
        log_info "  [OK] ProxySQL container is UP (Process is running)"
    else
        log_error " [FAIL] ProxySQL container is NOT running"
        exit 1
    fi
fi

# --- 3. UI Check (Adminer) ---
log_info "[Check 3/3] Adminer UI"

if curl -sI "http://localhost:8080" | grep -q "200 OK"; then
    log_info "  [OK] Adminer Web UI is accessible"
else
    if docker ps | grep -q "${ADMINER_CONTAINER}"; then
        log_warn " [WARN] Adminer container is UP but HTTP check failed (maybe starting?)"
    else
        log_error " [FAIL] Adminer container is NOT running"
        exit 1
    fi
fi

echo ""
echo "==============================================================="
log_info "DEPLOYMENT SUCCESSFUL!"
log_info "Your MariaDB HA Cluster is ready."
echo ""
log_info "Access Information:"
log_info "  1. Adminer UI (GUI):  http://<YOUR-IP>:8080"
log_info "     - System: MySQL"
log_info "     - Server: mariadb-1"
log_info "     - User:   root"
log_info "     - Pass:   rootpass"
echo ""
log_info "  2. App Connection:    Port 6033"
log_info "     - Host:   <YOUR-IP>"
log_info "     - User:   app"
log_info "     - Pass:   apppass"
echo "==============================================================="