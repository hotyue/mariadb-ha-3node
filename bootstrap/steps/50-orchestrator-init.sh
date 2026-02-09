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
ORC_IMAGE="openark/orchestrator:3.2.6"

# Orchestrator 在 MariaDB 中使用的监控/管理账号
ORC_USER="orc_admin"
ORC_PW="orcpass"

# MariaDB 节点列表（用于初始发现）
MASTER="mariadb-1"
NODES=("mariadb-1" "mariadb-2" "mariadb-3")

log_info "ensuring orchestrator user exists on all MariaDB nodes"

for node in "${NODES[@]}"; do
    mysql_exec_local "${node}" "
    CREATE USER IF NOT EXISTS '${ORC_USER}'@'%' IDENTIFIED BY '${ORC_PW}';
    GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO '${ORC_USER}'@'%';
    GRANT SELECT ON mysql.slave_master_info TO '${ORC_USER}'@'%';
    FLUSH PRIVILEGES;
    "
done

log_info "starting orchestrator container: ${ORC_CONTAINER}"

# 注意：Orchestrator 通常需要配置文件或环境变量来指定后端数据库
# 这里使用环境变量直接连接 mariadb-1 作为 Orchestrator 的后端存储 (Backend DB)
if docker ps -a --format '{{.Names}}' | grep -qx "${ORC_CONTAINER}"; then
    log_info "container already exists, restarting: ${ORC_CONTAINER}"
    docker stop "${ORC_CONTAINER}" >/dev/null 2>&1 || true
    docker rm "${ORC_CONTAINER}" >/dev/null 2>&1 || true
fi

# 启动 Orchestrator
# ORC_TOPOLOGY_USER/PASS 用于探测拓扑
# ORC_DB_USER/PASS 用于连接它自己的元数据库 (这里复用 mariadb-1)
docker run -d \
  --name "${ORC_CONTAINER}" \
  --network "${NETWORK_NAME}" \
  -e ORC_DB_NAME="orchestrator" \
  -e ORC_USER="${ORC_USER}" \
  -e ORC_PASSWORD="${ORC_PW}" \
  -e ORC_DB_HOST="mariadb-1" \
  -e ORC_TOPOLOGY_USER="${ORC_USER}" \
  -e ORC_TOPOLOGY_PASSWORD="${ORC_PW}" \
  -p 3000:3000 \
  "${ORC_IMAGE}" >/dev/null

log_info "waiting for orchestrator API to be ready..."

for i in {1..30}; do
    if curl -s "http://localhost:3000/api/health" | grep -q "OK" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

log_info "discovering initial topology via ${MASTER}"

# 让 Orchestrator 开始扫描整个集群
docker exec "${ORC_CONTAINER}" orchestrator-client -c discover -i "${MASTER}:3306" || true

log_info "orchestrator initialization completed"