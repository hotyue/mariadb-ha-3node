#!/usr/bin/env bash
set -euo pipefail

NETWORK="mariadb-ha"
CONTAINERS=(
  mariadb-1
  mariadb-2
  mariadb-3
  proxysql
)

log() {
  printf '[runtime][start] %s\n' "$1"
}

log "checking docker network: ${NETWORK}"
docker network inspect "${NETWORK}" >/dev/null 2>&1 || {
  echo "[runtime][start][ERROR] network not found: ${NETWORK}"
  exit 1
}

for c in "${CONTAINERS[@]}"; do
  if docker ps --format '{{.Names}}' | grep -qx "${c}"; then
    log "container already running: ${c}"
  else
    if docker ps -a --format '{{.Names}}' | grep -qx "${c}"; then
      log "starting container: ${c}"
      docker start "${c}" >/dev/null
    else
      echo "[runtime][start][ERROR] container missing: ${c}"
      exit 1
    fi
  fi
done

log "runtime start completed"
