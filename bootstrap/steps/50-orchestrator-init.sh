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
# 修正：使用具体版本号，官方仓库没有 latest 标签
ORC_IMAGE="openark/orchestrator:3.2.6"

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
    # - SUPER/REPLICATION CLIENT: 发现主从结构
    # - PROCESS: 查看连接列表
    # - RELOAD: 允许执行 RESET SLAVE 等操作 (故障切换必需)
    mysql_exec_local "${node}" "GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO '${ORC_USER}'@'%';"
    
    # 3. 授予系统表查询权限
    # 修复: 移除了 mysql.slave_master_info (MySQL特有)，改为授予 mysql 库只读权限
    mysql_exec_local "${node}" "GRANT SELECT ON mysql.* TO '${ORC_USER}'@'%';"
    
    # 4. (可选) 如果未来想把 Orchestrator 数据存放在 mariadb-1，预留权限
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

# 启动 Orchestrator
# 策略：使用内置 SQLite 作为后端存储 (默认配置)，确保启动零依赖、高成功率。
# 环境变量说明：
# - ORC_TOPOLOGY_USER/PASSWORD: 告诉 Orchestrator 用什么账号去连接 MariaDB 集群
docker run -d \
  --name "${ORC_CONTAINER}" \
  --network "${NETWORK_NAME}" \
  -p 3000:3000 \
  -e ORC_TOPOLOGY_USER="${ORC_USER}" \
  -e ORC_TOPOLOGY_PASSWORD="${ORC_PW}" \
  "${ORC_IMAGE}" http >/dev/null

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
# Orchestrator 会连接 mariadb-1，然后自动顺藤摸瓜发现 mariadb-2 和 3
docker exec "${ORC_CONTAINER}" orchestrator-client -c discover -i "${MASTER}" || log_warn "discovery trigger returned non-zero, but process might be async"

log_info "orchestrator initialization completed"