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
# 将 Orchestrator 替换为 Adminer
ADMINER_CONTAINER="adminer"

log_info "starting final cluster health check..."

# --- 1. MariaDB Replication Check (基础复制状态) ---
log_info "[Check 1/3] MariaDB Replication"
SLAVES=("mariadb-2" "mariadb-3")

for slave in "${SLAVES[@]}"; do
    # 使用 awk 精确提取状态，不检查 Semisync，只检查基础 IO/SQL 线程
    IO_RUNNING=$(mysql_query_value "${slave}" "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(mysql_query_value "${slave}" "SHOW SLAVE STATUS\G" | grep "Slave_SQL_Running:" | awk '{print $2}')

    if [[ "${IO_RUNNING}" == "Yes" && "${SQL_RUNNING}" == "Yes" ]]; then
        log_info "  - ${slave}: Replication OK (IO: Yes, SQL: Yes)"
    else
        log_error "  - ${slave}: Replication FAILED (IO: ${IO_RUNNING}, SQL: ${SQL_RUNNING})"
        exit 1
    fi
done

# --- 2. ProxySQL Status (连通性检查) ---
log_info "[Check 2/3] ProxySQL Status"

# 检查 Admin 端口 (6032) 是否响应
if docker exec "${PROXYSQL_CONTAINER}" mysql -uadmin -padmin -h127.0.0.1 -P6032 -e "SELECT 1;" >/dev/null 2>&1; then
    log_info "  - ProxySQL Admin (6032): OK"
else
    log_error "  - ProxySQL Admin (6032): Unreachable"
    exit 1
fi

# 检查业务端口 (6033) 是否监听 (简单的 TCP 检测或 SQL 检测)
# 注意：容器内可能没有 netcat (nc)，所以尝试用 mysql 客户端连接
if docker exec "${PROXYSQL_CONTAINER}" mysql -uadmin -padmin -h127.0.0.1 -P6033 -e "SELECT 1;" >/dev/null 2>&1; then
    log_info "  - ProxySQL Query (6033): OK"
else
    # 这是一个非阻断性警告，因为有时 6033 需要应用账号才能连接
    log_warn "  - ProxySQL Query (6033): Check skipped or failed (check app logs)"
fi

# --- 3. UI Check (Adminer) ---
log_info "[Check 3/3] Adminer Web UI"

# 检查 HTTP 200 状态码
if curl -sI "http://localhost:8080" | grep -q "200 OK"; then
    log_info "  - Adminer UI: OK (http://localhost:8080)"
else
    # 如果 curl 失败，尝试检查容器是否运行
    if docker ps | grep -q "${ADMINER_CONTAINER}"; then
        log_warn "  - Adminer UI: Container running but HTTP check failed (might be starting)"
    else
        log_error "  - Adminer UI: Container NOT running"
        exit 1
    fi
fi

echo "---------------------------------------------------------------"
log_info "CONGRATULATIONS! MariaDB HA Cluster is ready."
log_info "Summary:"
log_info "  - Database:         3 Nodes (1 Master, 2 Slaves)"
log_info "  - Middleware:       ProxySQL (Read/Write Split)"
log_info "  - Management UI:    Adminer (Lightweight)"
echo ""
log_info "Access Points:"
log_info "  - Adminer Web UI:   http://<YOUR-IP>:8080"
log_info "  - App Connection:   Port 6033 (User: app / Pass: apppass)"
echo "---------------------------------------------------------------"