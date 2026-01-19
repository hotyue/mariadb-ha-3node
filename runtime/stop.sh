#!/usr/bin/env bash
set -euo pipefail

CONTAINERS=(
  proxysql
  mariadb-3
  mariadb-2
  mariadb-1
)

log() {
  printf '[runtime][stop] %s\n' "$1"
}

for c in "${CONTAINERS[@]}"; do
  if docker ps --format '{{.Names}}' | grep -qx "${c}"; then
    log "stopping container: ${c}"
    docker stop "${c}" >/dev/null
  else
    log "container already stopped: ${c}"
  fi
done

log "runtime stop completed"
