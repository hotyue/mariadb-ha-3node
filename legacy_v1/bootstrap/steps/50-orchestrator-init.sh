#!/usr/bin/env bash
set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${STEP_DIR}/.." && pwd)"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"

NETWORK_NAME="mariadb-ha"
# 替换为 Adminer：官方镜像，极小，绝对稳定
CONTAINER_NAME="adminer"
IMAGE="adminer:latest"

log_info "Deploying Adminer (Lightweight Database GUI) instead of Orchestrator..."

# 清理旧容器
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# 启动 Adminer
# 映射端口 8080
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  -p 8080:8080 \
  "${IMAGE}" >/dev/null

log_info "waiting for Adminer..."

# 简单的健康检查
for i in {1..10}; do
    if curl -sI "http://localhost:8080" | grep -q "200 OK"; then
        log_info "Adminer is up and running"
        break
    fi
    sleep 1
done

log_info "--------------------------------------------------------"
log_info "Web UI Ready: http://<YOUR-IP>:8080"
log_info "Login System: MySQL"
log_info "Server:       mariadb-1 (or mariadb-2, mariadb-3)"
log_info "Username:     root"
log_info "Password:     rootpass"
log_info "--------------------------------------------------------"

log_info "GUI initialization completed"