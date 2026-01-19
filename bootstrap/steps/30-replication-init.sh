#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"

ROOT_PW="rootpass"
REPL_USER="repl"
REPL_PW="replpass"

MASTER="mariadb-1"
SLAVES=("mariadb-2" "mariadb-3")

mysql_exec() {
  local node="$1"
  local sql="$2"
  docker exec "${node}" mysql -uroot -p"${ROOT_PW}" -e "${sql}"
}

mysql_query_value() {
  local node="$1"
  local sql="$2"
  docker exec "${node}" mysql -uroot -p"${ROOT_PW}" -Nse "${sql}"
}

log_info "setting server-id on all nodes"

mysql_exec "${MASTER}" "SET GLOBAL server_id = 1;"
mysql_exec "mariadb-2" "SET GLOBAL server_id = 2;"
mysql_exec "mariadb-3" "SET GLOBAL server_id = 3;"

log_info "checking binlog status on master"
mysql_exec "${MASTER}" "SHOW VARIABLES LIKE 'log_bin';"

log_info "creating replication user on master"

mysql_exec "${MASTER}" "
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PW}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
"

log_info "configuring replication on slaves"

STATUS=$(mysql_exec "${MASTER}" "SHOW MASTER STATUS\G")
LOG_FILE=$(echo "${STATUS}" | awk '/File:/ {print $2}')
LOG_POS=$(echo "${STATUS}" | awk '/Position:/ {print $2}')

if [[ -z "${LOG_FILE}" || -z "${LOG_POS}" ]]; then
  log_error "failed to get master status (binlog likely off)"
  exit 1
fi

for slave in "${SLAVES[@]}"; do
  if mysql_exec "${slave}" "SHOW SLAVE STATUS\G" | grep -q "Slave_IO_State"; then
    log_info "replication already configured on ${slave}, skipping"
    continue
  fi

  log_info "initializing replication on ${slave}"

  mysql_exec "${slave}" "
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='${MASTER}',
  MASTER_USER='${REPL_USER}',
  MASTER_PASSWORD='${REPL_PW}',
  MASTER_LOG_FILE='${LOG_FILE}',
  MASTER_LOG_POS=${LOG_POS};
START SLAVE;
"
done

log_info "enabling semi-synchronous replication (MariaDB built-in)"

mysql_exec "${MASTER}" "
SET GLOBAL rpl_semi_sync_master_enabled = 1;
"

for slave in "${SLAVES[@]}"; do
  mysql_exec "${slave}" "
SET GLOBAL rpl_semi_sync_slave_enabled = 1;
"
done

log_info "verifying replication status"

for slave in "${SLAVES[@]}"; do
  STATUS=$(mysql_exec "${slave}" "SHOW SLAVE STATUS\G")
  echo "${STATUS}" | grep -q "Slave_IO_Running: Yes"
  echo "${STATUS}" | grep -q "Slave_SQL_Running: Yes"
  log_info "replication running on ${slave}"
done

log_info "replication initialization completed"
