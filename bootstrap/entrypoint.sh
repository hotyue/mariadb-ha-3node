#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# bootstrap/entrypoint.sh
# 职责：按顺序执行 steps 目录下的所有初始化脚本，并严格监控返回码。
# 改进：强制子脚本执行环境，确保错误不再被隐式忽略。
###############################################################################

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${BOOTSTRAP_DIR}/steps"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# 1. 基础库存在性校验
if [[ -f "${LIB_DIR}/log.sh" ]]; then
  # shellcheck source=lib/log.sh
  source "${LIB_DIR}/log.sh"
else
  echo "[ERROR] log library not found at ${LIB_DIR}/log.sh"
  exit 1
fi

log_info "bootstrap started"
log_info "bootstrap dir: ${BOOTSTRAP_DIR}"

# 2. 目录存在性校验
if [[ ! -d "${STEPS_DIR}" ]]; then
  log_error "steps directory not found: ${STEPS_DIR}"
  exit 1
fi

# 3. 收集并排序所有 .sh 脚本
# 使用 find 并排除自身，确保逻辑严密
mapfile -t STEPS < <(find "${STEPS_DIR}" -maxdepth 1 -type f -name "*.sh" | sort)

if [[ "${#STEPS[@]}" -eq 0 ]]; then
  log_error "no step scripts found under ${STEPS_DIR}"
  exit 1
fi

# 4. 逐个顺序执行
for step in "${STEPS[@]}"; do
  step_name="$(basename "${step}")"

  log_info "running step: ${step_name}"

  # 执行权限自动修复
  if [[ ! -x "${step}" ]]; then
    log_warn "fixing execution bit for: ${step_name}"
    chmod +x "${step}"
  fi

  # 核心改动：
  # 1. 使用 bash -e 强制子脚本在遇到任何未捕获错误时立即退出
  # 2. if ! 判断能够捕获该 bash 进程的非零退出码
  if ! bash -e "${step}"; then
    status=$?
    log_error "step failed with exit code ${status}: ${step_name}"
    # 立即终止整个 bootstrap 过程，并将错误码回传给 install.sh
    exit "${status}"
  fi

  log_info "step completed: ${step_name}"
done

log_info "bootstrap finished successfully"