#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# install.sh
# v1.1.2 one-command installer
# 职责：协调环境检查、自动化部署及运行状态验证
###############################################################################

PHASE_TOTAL=3

# 终端颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { printf "[install][INFO] %s\n"  "$*"; }
log_warn()  { printf "[install][WARN] ${YELLOW}%s${NC}\n"  "$*"; }
log_error() { printf "[install][ERROR] ${RED}%s${NC}\n" "$*" >&2; }

phase_start() {
  printf '\n${YELLOW}[install][PHASE %s/%s] %s...${NC}\n' "$1" "$PHASE_TOTAL" "$2"
}

phase_ok() {
  printf '${GREEN}[install][PHASE %s/%s] OK: %s${NC}\n' "$1" "$PHASE_TOTAL" "$2"
}

phase_fail() {
  printf '${RED}[install][PHASE %s/%s] FAILED: %s${NC}\n' "$1" "$PHASE_TOTAL" "$2" >&2
}

###############################################################################
# PHASE 1: Prerequisites Check
###############################################################################
phase_start 1 "Prerequisites check"

# 1. 权限提醒
if [[ $EUID -ne 0 ]]; then
   log_warn "Current user is not root. If docker requires sudo, this may fail."
fi

# 2. Docker 环境检查
if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker not found. Please install docker first."
  phase_fail 1 "Prerequisites check"
  exit 1
fi
log_info "Docker found"

if ! docker ps >/dev/null 2>&1; then
  log_error "Docker daemon not reachable. Ensure docker service is started."
  phase_fail 1 "Prerequisites check"
  exit 1
fi
log_info "Docker daemon reachable"

# 3. 脚本执行权限自动修复
log_info "Ensuring all scripts are executable..."
find . -name "*.sh" -exec chmod +x {} +

# 4. 核心组件存在性检查
ESSENTIAL_FILES=(
  "./bootstrap/entrypoint.sh"
  "./bootstrap/lib/mysql.sh"
  "./runtime/start.sh"
  "./runtime/status.sh"
)

for f in "${ESSENTIAL_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    log_error "Critical file missing: $f"
    phase_fail 1 "Prerequisites check"
    exit 1
  fi
done
log_info "All essential scripts found"

phase_ok 1 "Prerequisites check"

###############################################################################
# PHASE 2: Bootstrap (Infrastructure Setup)
###############################################################################
phase_start 2 "Bootstrap"

log_info "Executing: ./bootstrap/entrypoint.sh"
# 启动引导程序，包括网络创建、容器启动、同步配置、代理设置
if ! ./bootstrap/entrypoint.sh; then
  rc=$?
  phase_fail 2 "Bootstrap"
  log_error "Bootstrap failed with exit code ${rc}"
  exit "${rc}"
fi

phase_ok 2 "Bootstrap"

###############################################################################
# PHASE 3: Runtime Verification
###############################################################################
phase_start 3 "Runtime Status Verification"

log_info "Executing: ./runtime/status.sh"
# 引导完成后，直接通过状态脚本检查集群当前的整体健康度
if ! ./runtime/status.sh; then
  rc=$?
  phase_fail 3 "Runtime Verification"
  log_error "Final status check failed with exit code ${rc}"
  exit "${rc}"
fi

phase_ok 3 "Runtime Status Verification"

###############################################################################
# Final Summary
###############################################################################
echo -e "\n${GREEN}==============================================================="
echo "  MariaDB HA Cluster (3-Node) Deployment Completed!"
echo -e "===============================================================${NC}"

log_info "Quick Commands:"
log_info "  - Check Cluster:  ./runtime/status.sh"
log_info "  - Stop Cluster:   ./runtime/stop.sh"
log_info "  - Start Cluster:  ./runtime/start.sh"
log_info ""
log_info "Verification:"
log_info "  - Test Read/Write: ./verify/02-readwrite.sh"
log_info "  - Test Failover:   ./verify/03-failover.sh"
log_info ""
log_info "Web UI:"
log_info "  - Orchestrator: http://localhost:3000"

exit 0