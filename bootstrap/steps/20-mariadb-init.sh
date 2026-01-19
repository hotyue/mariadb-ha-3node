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

###############################################################################
# MariaDB readiness check
#
# IMPORTANT:
# - MariaDB 11+/12+ official images no longer guarantee root TCP login
# - mariadb-admin ping WITHOUT credentials uses socket and is stable across versions
###############################################################################
wait_mysql_ready() {
  local cname="$1"
  
  log_info "waiting for mariadb ready: ${cname}"

  for i in {1..60}; do
    # 使用 docker logs 来检查 MariaDB 是否准备好
    if docker logs "${cname}" 2>&1 | grep -q "ready for connections"; then
      log_info "mariadb is ready in container: ${cname}"
      return 0
    fi
    sleep 5
  done

  log_error "mariadb not ready in container: ${cname}"
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
      -e MARIADB_ROOT_PASSWORD="${ROOT_PASSWORD}" \
      -v "${node}-data:/var/lib/mysql" \
      "${IMAGE}" \
      --server-id="${SERVER_ID}" \
      --log-bin=mysql-bin >/dev/null
  fi

  log_info "waiting for mariadb ready: ${node}"

  if ! wait_mysql_ready "${node}"; then
    log_error "mariadb not ready in container: ${node}"
    docker logs --tail 50 "${node}" >&2 || true
    exit 1
  fi

  log_info "mariadb ready: ${node}"
done

log_info "all mariadb nodes are up"
