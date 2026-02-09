#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# bootstrap/entrypoint.sh
# 职责：按顺序执行 steps 目录下的所有初始化脚本，并严格监控返回码。
###############################################################################

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${BOOTSTRAP_DIR}/steps"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# 确保日志库存在并引入
if [[ -f "${LIB_DIR}/log.sh" ]]; then
  # shellcheck source=lib/log.sh
  source "${LIB_DIR}/log.sh"
else
  echo "[ERROR] log library not found at ${LIB_DIR}/log.sh"
  exit 1
fi

log_info "bootstrap started"
log_info "bootstrap dir: ${BOOTSTRAP_DIR}"

# 1. 目录存在性校验
if [[ ! -d "${STEPS_DIR}" ]]; then
  log_error "steps directory not found: ${STEPS_DIR}"
  exit 1
fi

# 2. 收集并排序所有 .sh 脚本
mapfile -t STEPS < <(find "${STEPS_DIR}" -type f -name "*.sh" | sort)

if [[ "${#STEPS[@]}" -eq 0 ]]; then
  log_error "no step scripts found under ${STEPS_DIR}"
  exit 1
fi

# 3. 逐个执行步骤
for step in "${STEPS[@]}"; do
  step_name="$(basename "${step}")"

  log_info "running step: ${step_name}"

  # 确保脚本具有执行权限（虽然 install.sh 已经做过，但此处作为双重保险）
  if [[ ! -x "${step}" ]]; then
    log_warn "step not executable, attempting to fix: ${step_name}"
    chmod +x "${step}"
  fi

  # 执行脚本
  # 使用子 Shell 执行，防止子脚本中的 exit 直接杀掉主进程，同时捕获其返回码
  if ! "${step}"; then
    status=$?
    log_error "step failed with exit code ${status}: ${step_name}"
    exit "${status}"
  fi

  log_info "step completed: ${step_name}"
done

log_info "bootstrap finished successfully"