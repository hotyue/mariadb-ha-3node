#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=../lib/mysql.sh
source "${LIB_DIR}/mysql.sh"

REPL_USER="repl"
REPL_PW="replpass"

MASTER="mariadb-1"
SLAVES=("mariadb-2" "mariadb-3")

log_info "setting server-id on all nodes"
mysql_exec_local "${MASTER}" "SET GLOBAL server_id = 1;"
mysql_exec_local "mariadb-2" "SET GLOBAL server_id = 2;"
mysql_exec_local "mariadb-3" "SET GLOBAL server_id = 3;"

log_info "checking binlog status on master"
mysql_exec_local "${MASTER}" "SHOW VARIABLES LIKE 'log_bin';"

log_info "creating replication user on master"
mysql_exec_local "${MASTER}" "
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PW}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
"

log_info "configuring replication on slaves"

# 获取 Master 状态
STATUS=$(mysql_exec_local "${MASTER}" "SHOW MASTER STATUS\G")
LOG_FILE=$(echo "${STATUS}" | awk '/File:/ {print $2}')
LOG_POS=$(echo "${STATUS}" | awk '/Position:/ {print $2}')

if [[ -z "${LOG_FILE}" || -z "${LOG_POS}" ]]; then
  log_error "failed to get master status (binlog likely off)"
  exit 1
fi

for slave in "${SLAVES[@]}"; do
  log_info "initializing replication on ${slave} (forced reset)"
  
  # 强制停止并清理旧拓扑信息，确保无论是否有旧数据卷残留都能配置成功
  mysql_exec_local "${slave}" "
STOP SLAVE;
RESET SLAVE ALL;
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
mysql_exec_local "${MASTER}" "INSTALL SONAME 'semisync_master';" || log_warn "semisync_master plugin not found, skipping installation"
mysql_exec_local "${MASTER}" "SET GLOBAL rpl_semi_sync_master_enabled = 1;" || log_warn "failed to set rpl_semi_sync_master_enabled"

for slave in "${SLAVES[@]}"; do
  mysql_exec_local "${slave}" "INSTALL SONAME 'semisync_slave';" || log_warn "semisync_slave plugin not found on ${slave}, skipping installation"
  mysql_exec_local "${slave}" "SET GLOBAL rpl_semi_sync_slave_enabled = 1;" || log_warn "failed to set rpl_semi_sync_slave_enabled on ${slave}"
done

log_info "verifying replication status with retries"

for slave in "${SLAVES[@]}"; do
  # 增加重试机制，防止因 IO/SQL 线程还未完全起来导致的瞬时验证失败
  RETRY_COUNT=0
  MAX_RETRIES=5
  while true; do
    STATUS_OUT=$(mysql_exec_local "${slave}" "SHOW SLAVE STATUS\G")
    IO_RUNNING=$(echo "${STATUS_OUT}" | grep "Slave_IO_Running:" | awk '{print $2}' || echo "No")
    SQL_RUNNING=$(echo "${STATUS_OUT}" | grep "Slave_SQL_Running:" | awk '{print $2}' || echo "No")
    
    if [[ "${IO_RUNNING}" == "Yes" && "${SQL_RUNNING}" == "Yes" ]]; then
      log_info "  - ${slave}: replication is Up and Running"
      break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
      log_error "  - ${slave}: replication failure (IO=${IO_RUNNING}, SQL=${SQL_RUNNING})"
      exit 1
    fi
    
    log_info "  - ${slave}: waiting for replication threads... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 3
  done
done

log_info "replication initialization completed successfully"