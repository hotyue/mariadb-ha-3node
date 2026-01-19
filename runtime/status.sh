#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[runtime][status] %s\n' "$1"
}

echo
log "containers"
docker ps --format 'table {{.Names}}\t{{.Status}}' \
  | grep -E 'mariadb-|proxysql' || true

echo
log "replication status"
docker exec mariadb-2 mysql -uroot -prootpass -e \
  "SHOW SLAVE STATUS\G" | egrep "Slave_(IO|SQL)_Running" || true

echo
log "proxysql runtime health"
bash healthcheck/proxysql.sh || true

echo
log "status completed"
