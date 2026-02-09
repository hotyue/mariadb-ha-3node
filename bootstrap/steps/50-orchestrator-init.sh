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
ORC_CONTAINER="orchestrator"

# 终极修正：切换到 GitHub 官方容器注册表 (GHCR)
# 如果此镜像依然拉取失败，脚本会自动尝试 Percona 的镜像作为备选
ORC_IMAGE_OFFICIAL="ghcr.io/openark/orchestrator:v3.2.6"
ORC_IMAGE_FALLBACK="perconalab/orchestrator:3.2.6"

# Orchestrator 在 MariaDB 中使用的拓扑探测账号
ORC_USER="orc_admin"
ORC_PW="orcpass"

MASTER="mariadb-1"
NODES=("mariadb-1" "mariadb-2" "mariadb-3")

log_info "ensuring orchestrator user exists on all MariaDB nodes"

for node in "${NODES[@]}"; do
    log_info "configuring permissions on ${node}"
    
    # 1. 创建用户
    mysql_exec_local "${node}" "CREATE USER IF NOT EXISTS '${ORC_USER}'@'%' IDENTIFIED BY '${ORC_PW}';"
    
    # 2. 授予核心权限 (MariaDB 兼容)
    mysql_exec_local "${node}" "GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO '${ORC_USER}'@'%';"
    
    # 3. 授予系统表查询权限
    mysql_exec_local "${node}" "GRANT SELECT ON mysql.* TO '${ORC_USER}'@'%';"
    
    # 4. (可选) 如果未来想把 Orchestrator 数据存放在 mariadb-1
    if [[ "${node}" == "${MASTER}" ]]; then
         mysql_exec_local "${node}" "CREATE DATABASE IF NOT EXISTS orchestrator;"
         mysql_exec_local "${node}" "GRANT ALL PRIVILEGES ON orchestrator.* TO '${ORC_USER}'@'%';"
    fi
    
    mysql_exec_local "${node}" "FLUSH PRIVILEGES;"
done

log_info "starting orchestrator container: ${ORC_CONTAINER}"

if docker ps -a --format '{{.Names}}' | grep -qx "${ORC_CONTAINER}"; then
    docker rm -f "${ORC_CONTAINER}" >/dev/null 2>&1 || true
fi

# 尝试拉取镜像，具备自动降级机制
log_info "pulling orchestrator image..."
if docker pull "${ORC_IMAGE_OFFICIAL}"; then
    TARGET_IMAGE="${ORC_IMAGE_OFFICIAL}"
elif docker pull "${ORC_IMAGE_FALLBACK}"; then
    log_warn "official image failed, falling back to Percona image"
    TARGET_IMAGE="${ORC_IMAGE_FALLBACK}"
else
    log_error "failed to pull both official and fallback orchestrator images. Please check your network."
    exit 1
fi

# 启动 Orchestrator
# 使用 SQLite 后端 (默认)，无状态启动，最稳健。
docker run -d \
  --name "${ORC_CONTAINER}" \
  --network "${NETWORK_NAME}" \
  -p 3000:3000 \
  -e ORC_TOPOLOGY_USER="${ORC_USER}" \
  -e ORC_TOPOLOGY_PASSWORD="${ORC_PW}" \
  "${TARGET_IMAGE}" http >/dev/null

log_info "waiting for orchestrator API..."

# 健康检查循环
for i in {1..30}; do
    if curl -s "http://localhost:3000/api/health" | grep -q "OK"; then
        log_info "orchestrator is up"
        break
    fi
    
    if [ $i -eq 30 ]; then
        log_error "orchestrator failed to start within 60s"
        docker logs --tail 20 "${ORC_CONTAINER}"
        exit 1
    fi
    sleep 2
done

log_info "triggering discovery of ${MASTER}"

# 触发拓扑发现
docker exec "${ORC_CONTAINER}" orchestrator-client -c discover -i "${MASTER}" || log_warn "discovery trigger returned non-zero, but process might be async"

log_info "orchestrator initialization completed"