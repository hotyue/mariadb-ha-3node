#!/usr/bin/env bash
set -euo pipefail

# Verify read/write split via ProxySQL runtime

PROXYSQL_CONTAINER="proxysql"

RUNTIME_HOST="127.0.0.1"
RUNTIME_PORT="6033"

APP_USER="app"
APP_PW="apppass"

MASTER="mariadb-1"
SLAVES=("mariadb-2" "mariadb-3")

TEST_DB="proxysql_verify"
TEST_TABLE="rw_test"

log() {
  printf '[verify][readwrite] %s\n' "$1"
}

fail() {
  printf '[verify][readwrite][ERROR] %s\n' "$1" >&2
  exit 1
}

run_via_proxysql() {
  local sql="$1"
  docker exec "${PROXYSQL_CONTAINER}" mysql \
    -h "${RUNTIME_HOST}" -P "${RUNTIME_PORT}" \
    -u"${APP_USER}" -p"${APP_PW}" \
    -e "${sql}"
}

run_on_mariadb() {
  local node="$1"
  local sql="$2"
  docker exec "${node}" mysql \
    -u"${APP_USER}" -p"${APP_PW}" \
    -e "${sql}"
}

log "preparing test schema via ProxySQL (write path)"

run_via_proxysql "
CREATE DATABASE IF NOT EXISTS ${TEST_DB};
USE ${TEST_DB};
CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note VARCHAR(64),
  ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
"

log "writing test row via ProxySQL (should go to master)"

run_via_proxysql "
USE ${TEST_DB};
INSERT INTO ${TEST_TABLE}(note) VALUES ('proxysql-rw-test');
"

log "verifying data exists on master"

MASTER_COUNT=$(run_on_mariadb "${MASTER}" "
USE ${TEST_DB};
SELECT COUNT(*) FROM ${TEST_TABLE} WHERE note='proxysql-rw-test';
" | tail -n 1)

if [[ "${MASTER_COUNT}" != "1" ]]; then
  fail "write not found on master (${MASTER})"
fi

log "verifying data readable on at least one slave"

FOUND_ON_SLAVE="no"

for slave in "${SLAVES[@]}"; do
  COUNT=$(run_on_mariadb "${slave}" "
USE ${TEST_DB};
SELECT COUNT(*) FROM ${TEST_TABLE} WHERE note='proxysql-rw-test';
" | tail -n 1)

  if [[ "${COUNT}" == "1" ]]; then
    log "data found on slave: ${slave}"
    FOUND_ON_SLAVE="yes"
    break
  fi
done

if [[ "${FOUND_ON_SLAVE}" != "yes" ]]; then
  fail "data not found on any slave (replication/read path failed)"
fi

log "read/write split verification passed"
exit 0
