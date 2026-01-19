#!/usr/bin/env bash
set -euo pipefail

# ProxySQL runtime healthcheck
# - container running
# - runtime port reachable
# - simple query succeeds

PROXYSQL_CONTAINER="proxysql"

# Runtime interface (ProxySQL -> App)
RUNTIME_HOST="127.0.0.1"
RUNTIME_PORT="6033"

# App user (as configured in Phase 5)
APP_USER="app"
APP_PW="apppass"

log() {
  printf '[proxysql][healthcheck] %s\n' "$1"
}

fail() {
  printf '[proxysql][healthcheck][ERROR] %s\n' "$1" >&2
  exit 1
}

log "checking proxysql container existence"

if ! docker ps --format '{{.Names}}' | grep -qx "${PROXYSQL_CONTAINER}"; then
  fail "container not running: ${PROXYSQL_CONTAINER}"
fi

log "checking runtime connectivity (${RUNTIME_HOST}:${RUNTIME_PORT})"

if ! docker exec "${PROXYSQL_CONTAINER}" mysql \
     -h "${RUNTIME_HOST}" -P "${RUNTIME_PORT}" \
     -u"${APP_USER}" -p"${APP_PW}" \
     -e "SELECT 1;" >/dev/null 2>&1; then
  fail "runtime query failed on ${RUNTIME_HOST}:${RUNTIME_PORT}"
fi

log "proxysql runtime healthy"
exit 0
