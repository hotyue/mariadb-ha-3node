#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"

NETWORK_NAME="mariadb-ha"
IMAGE="mariadb:latest"
ROOT_PASSWORD="rootpass"

NODES=(
  "mariadb-1"
  "mariadb-2"
  "mariadb-3"
)

wait_mysql_ready() {
  local cname="$1"

  for i in {1..30}; do
    if docker exec "${cname}" mysqladmin ping \
        -uroot -p"${ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

for node in "${NODES[@]}"; do
  log_info "processing mariadb node: ${node}"

  # ===== 固化 server-id（关键）=====
  case "${node}" in
    mariadb-1) SERVER_ID=1 ;;
    mariadb-2) SERVER_ID=2 ;;
    mariadb-3) SERVER_ID=3 ;;
    *)
      log_error "unknown node name for server-id assignment: ${node}"
      exit 1
      ;;
  esac
  # ==================================

  if docker ps -a --format '{{.Names}}' | grep -qx "${node}"; then
    if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      log_info "container already running: ${node}"
    else
      log_info "starting existing container: ${node}"
      docker start "${node}" >/dev/null
    fi
  else
    log_info "creating mariadb container: ${node} (server-id=${SERVER_ID})"

    docker run -d \
      --name "${node}" \
      --network "${NETWORK_NAME}" \
      -e MYSQL_ROOT_PASSWORD="${ROOT_PASSWORD}" \
      -v "${node}-data:/var/lib/mysql" \
      "${IMAGE}" \
      --server-id="${SERVER_ID}" \
      --log-bin=mysql-bin >/dev/null
  fi

  log_info "waiting for mysql ready: ${node}"

  if ! wait_mysql_ready "${node}"; then
    log_error "mysql not ready in container: ${node}"
    exit 1
  fi

  log_info "mysql ready: ${node}"
done

log_info "all mariadb nodes are up"
