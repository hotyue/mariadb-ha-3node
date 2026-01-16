#!/usr/bin/env bash
set -euo pipefail

FACTS_FILE="./runtime/facts.json"

# ProxySQL admin 连接信息（示例）
PROXYSQL_ADMIN_HOST="127.0.0.1"
PROXYSQL_ADMIN_PORT=6032
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"

mysql_admin() {
  mysql -h"${PROXYSQL_ADMIN_HOST}" -P"${PROXYSQL_ADMIN_PORT}" \
        -u"${PROXYSQL_ADMIN_USER}" -p"${PROXYSQL_ADMIN_PASS}" \
        -N -B -e "$1"
}

# ---------- 读取事实 ----------
if ! jq -e . "${FACTS_FILE}" >/dev/null 2>&1; then
  echo "facts.json 不存在或非法，进入拒写态"
  WRITE_ALLOWED=false
else
  EXPIRED=$(jq -r '
    (now | floor) >
    ((.generated_at_utc | fromdateiso8601) + .valid_for_seconds)
  ' "${FACTS_FILE}")

  CURRENT_PRIMARY=$(jq -r '.current_primary' "${FACTS_FILE}")
  WRITE_CONDITION=$(jq -r '.write_condition' "${FACTS_FILE}")

  if [[ "${EXPIRED}" == "true" ]] ||
     [[ "${CURRENT_PRIMARY}" == "null" ]] ||
     [[ "${WRITE_CONDITION}" != "true" ]]; then
    WRITE_ALLOWED=false
  else
    WRITE_ALLOWED=true
  fi
fi

# ---------- 同步写路由 ----------
if [[ "${WRITE_ALLOWED}" == "true" ]]; then
  echo "允许写：路由到 hostgroup 10"
  mysql_admin "
    UPDATE mysql_query_rules
       SET destination_hostgroup=10
     WHERE rule_name='write_rule';
    LOAD MYSQL QUERY RULES TO RUNTIME;
  "
else
  echo "拒绝写：路由到黑洞 hostgroup 999"
  mysql_admin "
    UPDATE mysql_query_rules
       SET destination_hostgroup=999
     WHERE rule_name='write_rule';
    LOAD MYSQL QUERY RULES TO RUNTIME;
  "
fi
