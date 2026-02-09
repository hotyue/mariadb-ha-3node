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
SOCKET_PATH="/run/mysqld/mysqld.sock"

NODES=(
  "mariadb-1"
  "mariadb-2"
  "mariadb-3"
)

###############################################################################
# MariaDB readiness check (Enhanced Three-Stage Validation)
###############################################################################
wait_mysql_ready() {
  local cname="$1"
  log_info "waiting for mariadb socket and protocol readiness: ${cname}"

  for i in {1..45}; do
    # 阶段 1: 检查容器日志是否显示就绪
    if docker logs "${cname}" 2>&1 | grep -q "ready for connections"; then
      
      # 阶段 2: 检查 Socket 文件是否在容器内创建
      if docker exec "${cname}" ls "${SOCKET_PATH}" >/dev/null 2>&1; then
        
        # 阶段 3: 尝试通过 Socket 协议进行 Ping（绕过 TCP 认证限制）
        if docker exec "${cname}" mariadb-admin -uroot -p"${ROOT_PASSWORD}" \
           --protocol=socket --socket="${SOCKET_PATH}" ping >/dev/null 2>&1; then
           log_info "mariadb is fully ready and responding: ${cname}"
           return 0
        fi
      fi
    fi
    
    # 只有在初次尝试时降低频率，后续加快轮询
    [[ $i -eq 1 ]] && sleep 5 || sleep 2
  done

  log_error "mariadb failed readiness check after 45 attempts: ${cname}"
  return 1
}

for node in "${NODES[@]}"; do
  log_info "processing mariadb node: ${node}"

  # 固化 server-id
  case "${node}" in
    mariadb-1) SERVER_ID=1 ;;
    mariadb-2) SERVER_ID=2 ;;
    mariadb-3) SERVER_ID=3 ;;
    *)
      log_error "unknown node name for server-id assignment: ${node}"
      exit 1
      ;;
  esac

  # 判断容器状态
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

  # 阻塞等待直到数据库完全可用
  if ! wait_mysql_ready "${node}"; then
    log_error "mariadb boot failed, dumping last 20 lines of logs:"
    docker logs --tail 20 "${node}" >&2
    exit 1
  fi
done

log_info "all mariadb nodes are up and sockets are accessible"