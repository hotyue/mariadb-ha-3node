#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=../lib/mysql.sh
source "${LIB_DIR}/mysql.sh"

NETWORK_NAME="mariadb-ha"

PROXYSQL_CONTAINER="proxysql"
PROXYSQL_IMAGE="proxysql/proxysql:2.6.0"

# ProxySQL Admin（容器内 TCP 访问其管理接口）
PXA_USER="admin"
PXA_PW="admin"
PXA_HOST="127.0.0.1"
PXA_PORT="6032"

# ProxySQL 监控账号（在 MariaDB 中创建）
MON_USER="monitor"
MON_PW="monitorpass"

# 应用账号（通过 6033 访问数据库）
APP_USER="app"
APP_PW="apppass"

# Hostgroups 路由定义
HG_WRITER="10"
HG_READER="20"

# 内部函数：通过 ProxySQL Admin 接口执行 SQL
proxysql_admin_exec() {
  local sql="$1"
  docker exec "${PROXYSQL_CONTAINER}" mariadb \
    -h "${PXA_HOST}" -P "${PXA_PORT}" \
    -u"${PXA_USER}" -p"${PXA_PW}" \
    -e "${sql}"
}

log_info "starting proxysql container (if needed): ${PROXYSQL_CONTAINER}"

if docker ps -a --format '{{.Names}}' | grep -qx "${PROXYSQL_CONTAINER}"; then
  if docker ps --format '{{.Names}}' | grep -qx "${PROXYSQL_CONTAINER}"; then
    log_info "proxysql already running: ${PROXYSQL_CONTAINER}"
  else
    log_info "starting existing proxysql container: ${PROXYSQL_CONTAINER}"
    docker start "${PROXYSQL_CONTAINER}" >/dev/null
  fi
else
  log_info "creating proxysql container: ${PROXYSQL_CONTAINER}"
  docker run -d \
    --name "${PROXYSQL_CONTAINER}" \
    --network "${NETWORK_NAME}" \
    -v "${PROXYSQL_CONTAINER}-data:/var/lib/proxysql" \
    "${PROXYSQL_IMAGE}" >/dev/null
fi

log_info "waiting for proxysql admin (container-local TCP ${PXA_HOST}:${PXA_PORT})"

for i in {1..40}; do
  if docker exec "${PROXYSQL_CONTAINER}" mariadb \
       -h "${PXA_HOST}" -P "${PXA_PORT}" \
       -u"${PXA_USER}" -p"${PXA_PW}" \
       -e "SELECT 1;" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

log_info "ensuring monitor user exists on MariaDB master (replicates)"

# 使用 mysql_exec_local 避开 MariaDB root 密码验证问题
mysql_exec_local mariadb-1 "
CREATE USER IF NOT EXISTS '${MON_USER}'@'%' IDENTIFIED BY '${MON_PW}';
GRANT USAGE, PROCESS, REPLICATION CLIENT ON *.* TO '${MON_USER}'@'%';
FLUSH PRIVILEGES;
"

log_info "configuring proxysql (admin via TCP)"

# 1) 全局变量：配置监控账号（用于 ProxySQL 检查后端存活）
proxysql_admin_exec "
REPLACE INTO global_variables(variable_name, variable_value) VALUES
 ('mysql-monitor_username','${MON_USER}'),
 ('mysql-monitor_password','${MON_PW}');
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
"

# 2) 后端节点：配置读写 Hostgroups
proxysql_admin_exec "
REPLACE INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections) VALUES
 (${HG_WRITER}, 'mariadb-1', 3306, 1000, 200),
 (${HG_READER}, 'mariadb-2', 3306, 1000, 200),
 (${HG_READER}, 'mariadb-3', 3306, 1000, 200);
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
"

# 3) 业务用户：创建供应用连接的代理账号
proxysql_admin_exec "
REPLACE INTO mysql_users(username, password, default_hostgroup, active, transaction_persistent)
VALUES ('${APP_USER}', '${APP_PW}', ${HG_WRITER}, 1, 1);
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
"

# 4) 读写分离规则：SELECT 路由到读组
proxysql_admin_exec "
REPLACE INTO mysql_query_rules(rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES (1, 1, '^[[:space:]]*SELECT', ${HG_READER}, 1);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
"

log_info "proxysql initialization completed"