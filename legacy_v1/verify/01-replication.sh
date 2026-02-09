#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/bootstrap/lib/log.sh"
source "${ROOT_DIR}/bootstrap/lib/mysql.sh"

MASTER="mariadb-1"
SLAVES=("mariadb-2" "mariadb-3")
TEST_DB="repl_verify"

log_info "starting replication verification..."

# 1. 在 Master 创建测试数据
log_info "creating test data on master: ${MASTER}"
mysql_exec_local "${MASTER}" "
CREATE DATABASE IF NOT EXISTS ${TEST_DB};
CREATE TABLE IF NOT EXISTS ${TEST_DB}.test_sync (
    id INT PRIMARY KEY,
    msg VARCHAR(50),
    ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO ${TEST_DB}.test_sync (id, msg) VALUES (UNIX_TIMESTAMP(), 'sync-test-from-master') 
ON DUPLICATE KEY UPDATE msg='sync-test-from-master';
"

# 2. 等待同步（半同步通常极快，这里给 2 秒缓冲）
sleep 2

# 3. 在所有 Slave 上校验数据
for slave in "${SLAVES[@]}"; do
    log_info "checking data on slave: ${slave}"
    RESULT=$(mysql_query_value "${slave}" "SELECT msg FROM ${TEST_DB}.test_sync LIMIT 1;")
    
    if [[ "${RESULT}" == "sync-test-from-master" ]]; then
        log_info "  - ${slave}: data synced successfully"
    else
        log_error "  - ${slave}: data sync FAILED (result: ${RESULT})"
        exit 1
    fi
done

log_info "replication verification passed"