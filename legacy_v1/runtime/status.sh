#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${RUNTIME_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/bootstrap/lib"

# 引入日志库
if [[ -f "${LIB_DIR}/log.sh" ]]; then
  source "${LIB_DIR}/log.sh"
else
  echo "Error: log.sh not found."
  exit 1
fi

# 定义颜色方便查看
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info "--- MariaDB HA Cluster Status ---"

# 1. 容器状态概览
echo ""
log_info "[1] Container Overview:"
# 过滤显示相关容器，包括 adminer
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "mariadb|proxysql|adminer" || echo "No containers found."

# 2. 主从复制状态
echo ""
log_info "[2] Replication Status (Slaves):"
for node in mariadb-2 mariadb-3; do
    # 检查容器是否存活
    if ! docker ps | grep -q "${node}"; then
        echo -e "  ${node}: ${RED}Container Down${NC}"
        continue
    fi

    # 直接使用 docker exec 在容器内检查，避开 Socket 路径差异，确保使用 socket 协议
    STATUS=$(docker exec "${node}" mariadb -uroot -prootpass --protocol=socket -e "SHOW SLAVE STATUS\G" 2>/dev/null || true)
    
    IO=$(echo "${STATUS}" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL=$(echo "${STATUS}" | grep "Slave_SQL_Running:" | awk '{print $2}')

    if [[ "${IO}" == "Yes" && "${SQL}" == "Yes" ]]; then
        echo -e "  ${node}: ${GREEN}OK (Syncing)${NC}"
    else
        echo -e "  ${node}: ${RED}Error (IO:${IO:-No}, SQL:${SQL:-No})${NC}"
    fi
done

# 3. ProxySQL 后端状态
echo ""
log_info "[3] ProxySQL Backend Pool:"
if docker ps | grep -q "proxysql"; then
    # 直接在容器内查询 admin 接口，绕过外部连接权限限制
    # -t: 表格格式输出
    docker exec proxysql mysql -uadmin -padmin -h127.0.0.1 -P6032 -t -e \
      "SELECT hostgroup_id, hostname, status, port FROM runtime_mysql_servers ORDER BY hostname;" || echo -e "${RED}Failed to query ProxySQL${NC}"
else
    echo -e "${RED}ProxySQL Container Down${NC}"
fi

# 4. 管理界面 (Adminer) 状态
echo ""
log_info "[4] Management UI (Adminer):"
if curl -sI "http://localhost:8080" | grep -q "200 OK"; then
    echo -e "  URL: ${GREEN}http://localhost:8080 (Online)${NC}"
    echo "       (Login: System=MySQL, Server=mariadb-1, User=root, Pass=rootpass)"
else
    if docker ps | grep -q "adminer"; then
        echo -e "  URL: ${RED}Unreachable (Container Up, Check Logs)${NC}"
    else
        echo -e "  URL: ${RED}Offline (Container Down)${NC}"
    fi
fi

echo ""
log_info "--- Status Check Completed ---"