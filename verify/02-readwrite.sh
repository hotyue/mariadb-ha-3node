#!/usr/bin/env bash
set -euo pipefail

# 1. 环境定位
VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${VERIFY_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/bootstrap/lib"

# 2. 加载基础库
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/mysql.sh"

# 3. 配置信息
PROXY_CONTAINER="proxysql"
APP_USER="app"
APP_PW="apppass"
TEST_DB="test_rw_split"
TEST_TABLE="traffic_log"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info "Starting Read/Write Split Verification..."

# --- Step 1: 准备环境 (使用 Root 在 Master 操作) ---
log_info "[1/4] Preparing test schema on Master..."

# 修复核心：先创建用户，再授权
# Master 上创建的用户会自动同步到 Slaves
mysql_exec_local "mariadb-1" "CREATE DATABASE IF NOT EXISTS ${TEST_DB};"
mysql_exec_local "mariadb-1" "CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${APP_PW}';"
mysql_exec_local "mariadb-1" "GRANT ALL PRIVILEGES ON ${TEST_DB}.* TO '${APP_USER}'@'%';"
mysql_exec_local "mariadb-1" "FLUSH PRIVILEGES;"

mysql_exec_local "mariadb-1" "
  CREATE TABLE IF NOT EXISTS ${TEST_DB}.${TEST_TABLE} (
    id INT PRIMARY KEY AUTO_INCREMENT,
    source_node VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );"

# --- Step 2: 测试写入 (Write -> Master) ---
log_info "[2/4] Testing WRITE traffic via ProxySQL (Port 6033)..."
log_info "      Sending INSERT requests..."

# 通过 ProxySQL 插入数据
for i in {1..3}; do
  docker exec "${PROXY_CONTAINER}" mysql -u"${APP_USER}" -p"${APP_PW}" -h127.0.0.1 -P6033 -e \
    "INSERT INTO ${TEST_DB}.${TEST_TABLE} (source_node) VALUES (@@hostname);"
done

# 验证 Master 是否收到了数据
MASTER_COUNT=$(mysql_query_value "mariadb-1" "SELECT COUNT(*) FROM ${TEST_DB}.${TEST_TABLE};")
if [[ "${MASTER_COUNT}" -ge 3 ]]; then
  log_info "      [OK] Master (mariadb-1) confirms ${MASTER_COUNT} records."
else
  log_error "     [FAIL] Master missing records! Found: ${MASTER_COUNT}"
  exit 1
fi

# --- Step 3: 测试读取 (Read -> Slaves) ---
log_info "[3/4] Testing READ traffic via ProxySQL (Port 6033)..."
log_info "      Sending SELECT requests (Should hit Slaves)..."

echo ""
echo -e "   | Req | Traffic Type | Handled By Node | Expected Role | Status |"
echo "   |-----|--------------|-----------------|---------------|--------|"

# 循环读取 6 次，观察负载均衡效果
for i in {1..6}; do
  # 查询 @@hostname 看看请求被路由到了哪里
  HANDLER=$(docker exec "${PROXY_CONTAINER}" mysql -u"${APP_USER}" -p"${APP_PW}" -h127.0.0.1 -P6033 -Nse \
    "SELECT @@hostname")
  
  # 判断逻辑
  if [[ "$HANDLER" == "mariadb-1" ]]; then
      ROLE="Master"
      STATUS="${YELLOW}Writer${NC}" 
  else
      ROLE="Slave"
      STATUS="${GREEN}Reader${NC}"
  fi
  
  printf "   | %-3s | %-12s | %-15s | %-13s | %-6s |\n" "$i" "SELECT" "$HANDLER" "$ROLE" "$STATUS"
done
echo ""

# --- Step 4: 清理 ---
log_info "[4/4] Cleaning up..."
mysql_exec_local "mariadb-1" "DROP DATABASE IF EXISTS ${TEST_DB};"

log_info "Verification Completed Successfully!"