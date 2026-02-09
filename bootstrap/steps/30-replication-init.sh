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

# 注意：20-mariadb-init.sh 启动时已带参数，此处为双重保险
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

# 获取 Master 状态（使用 \G 格式化输出以便 awk 解析）
STATUS=$(mysql_exec_local "${MASTER}" "SHOW MASTER STATUS\G")
LOG_FILE=$(echo "${STATUS}" | awk '/File:/ {print $2}')
LOG_POS=$(echo "${STATUS}" | awk '/Position:/ {print $2}')

if [[ -z "${LOG_FILE}" || -z "${LOG_POS}" ]]; then
  log_error "failed to get master status (binlog likely off)"
  exit 1
fi

for slave in "${SLAVES[@]}"; do
  # 检查是否已经配置过主从
  if mysql_exec_local "${slave}" "SHOW SLAVE STATUS\G" | grep -q "Slave_IO_State"; then
    log_info "replication already configured on ${slave}, skipping"
    continue
  fi

  log_info "initializing replication on ${slave}"

  mysql_exec_local "${slave}" "
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

# 兼容性处理：尝试加载插件，如果失败（如 .so 找不到）则跳过，不中断部署流程
log_info "attempting to load semisync plugins..."
mysql_exec_local "${MASTER}" "INSTALL SONAME 'semisync_master';" || log_warn "semisync_master plugin not found, skipping installation"
mysql_exec_local "${MASTER}" "SET GLOBAL rpl_semi_sync_master_enabled = 1;" || log_warn "failed to set rpl_semi_sync_master_enabled"

for slave in "${SLAVES[@]}"; do
  mysql_exec_local "${slave}" "INSTALL SONAME 'semisync_slave';" || log_warn "semisync_slave plugin not found on ${slave}, skipping installation"
  mysql_exec_local "${slave}" "SET GLOBAL rpl_semi_sync_slave_enabled = 1;" || log_warn "failed to set rpl_semi_sync_slave_enabled on ${slave}"
done

log_info "verifying replication status"

for slave in "${SLAVES[@]}"; do
  # 验证主从 IO 和 SQL 线程是否正常运行
  IO_RUNNING=$(mysql_query_value "${slave}" "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running:" | awk '{print $2}')
  SQL_RUNNING=$(mysql_query_value "${slave}" "SHOW SLAVE STATUS\G" | grep "Slave_SQL_Running:" | awk '{print $2}')
  
  if [[ "${IO_RUNNING}" == "Yes" && "${SQL_RUNNING}" == "Yes" ]]; then
    log_info "replication running on ${slave}"
  else
    log_error "replication failure on ${slave}: IO=${IO_RUNNING}, SQL=${SQL_RUNNING}"
    # 这里保持 exit 1，因为主从同步失败是核心故障，必须拦截
    exit 1
  fi
done

log_info "replication initialization completed"