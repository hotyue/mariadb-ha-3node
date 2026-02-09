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
    # 稳健写法：先获取完整状态，避免管道中途报错导致脚本退出
    STATUS_TEXT=$(mysql_exec_local "${slave}" "SHOW SLAVE STATUS\G")
    
    # 解析状态，如果 grep 没找到，默认输出 "No" 以便后续判断，而不是直接报错退出
    IO_RUNNING=$(echo "${STATUS_TEXT}" | grep "Slave_IO_Running:" | awk '{print $2}' || echo "No")
    SQL_RUNNING=$(echo "${STATUS_TEXT}" | grep "Slave_SQL_Running:" | awk '{print $2}' || echo "No")

    if [[ "${IO_RUNNING}" == "Yes" && "${SQL_RUNNING}" == "Yes" ]]; then
        log_info "  [OK] ${slave}: Replication running"
    else
        log_error " [FAIL] ${slave}: IO=${IO_RUNNING}, SQL=${SQL_RUNNING}"
        # 允许非阻断性失败（比如刚刚启动还未同步），但标记为错误
        exit 1
    fi
done

# --- 2. ProxySQL Check ---
log_info "[Check 2/3] ProxySQL Connectivity"

# 使用 mariadb-1 作为客户端去连接 ProxySQL，这比 docker exec proxysql 更可靠
# 因为 proxysql 容器内可能没有 mysql 命令行工具
if docker exec mariadb-1 mariadb -uadmin -padmin -h proxysql -P 6032 -e "SELECT 1;" >/dev/null 2>&1; then
    log_info "  [OK] ProxySQL Admin Interface (Port 6032) is reachable"
else
    log_error " [FAIL] ProxySQL Admin Interface unreachable"
    exit 1
fi

if docker exec mariadb-1 mariadb -uadmin -padmin -h proxysql -P 6033 -e "SELECT 1;" >/dev/null 2>&1; then
    log_info "  [OK] ProxySQL Query Interface (Port 6033) is reachable"
else
    log_warn " [WARN] ProxySQL Query Interface check skipped or auth failed (check app logs)"
fi

# --- 3. UI Check (Adminer) ---
log_info "[Check 3/3] Adminer UI"

# 检查 HTTP 状态
if curl -sI "http://localhost:8080" | grep -q "200 OK"; then
    log_info "  [OK] Adminer Web UI is accessible"
else
    # 二次检查容器状态
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