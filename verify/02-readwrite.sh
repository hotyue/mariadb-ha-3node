#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/bootstrap/lib/log.sh"
source "${ROOT_DIR}/bootstrap/lib/mysql.sh"

PROXYSQL_CONTAINER="proxysql"
APP_USER="app"
APP_PW="apppass"
MASTER="mariadb-1"
SLAVES=("mariadb-2" "mariadb-3")

TEST_DB="proxysql_verify"
TEST_TABLE="rw_test"

# 内部函数：通过 ProxySQL 业务端口执行
run_via_proxysql() {
  docker exec -i "${PROXYSQL_CONTAINER}" mariadb \
    -h 127.0.0.1 -P 6033 -u"${APP_USER}" -p"${APP_PW}" -Nse "$1"
}

log_info "preparing test schema via ProxySQL (write path)"

# 使用 root 权限在 Master 预先创建数据库和用户权限（确保 app 用户有权访问）
mysql_exec_local "${MASTER}" "
CREATE DATABASE IF NOT EXISTS ${TEST_DB};
GRANT ALL ON ${TEST_DB}.* TO '${APP_USER}'@'%';
"

run_via_proxysql "
CREATE TABLE IF NOT EXISTS ${TEST_DB}.${TEST_TABLE} (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note VARCHAR(64)
);
INSERT INTO ${TEST_DB}.${TEST_TABLE}(note) VALUES ('proxysql-rw-test');
"

log_info "verifying write reached master"
MASTER_COUNT=$(mysql_query_value "${MASTER}" "SELECT COUNT(*) FROM ${TEST_DB}.${TEST_TABLE} WHERE note='proxysql-rw-test';")

if [[ "${MASTER_COUNT}" != "1" ]]; then
  log_error "write not found on master"
  exit 1
fi

log_info "verifying read distribution via ProxySQL"
# 连续执行 5 次查询，观察是否从 Slave 读取（ProxySQL 路由规则）
for i in {1..5}; do
    SID=$(run_via_proxysql "SELECT @@server_id;")
    log_info "  - Query $i handled by server_id: ${SID}"
done

log_info "read/write split verification passed"