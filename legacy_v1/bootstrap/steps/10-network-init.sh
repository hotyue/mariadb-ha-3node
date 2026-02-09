#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"

NETWORK_NAME="mariadb-ha"

log_info "checking docker network: ${NETWORK_NAME}"

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  log_info "docker network already exists: ${NETWORK_NAME}"
  exit 0
fi

log_info "creating docker network: ${NETWORK_NAME}"

docker network create "${NETWORK_NAME}" >/dev/null

log_info "docker network created: ${NETWORK_NAME}"
