#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# bootstrap/entrypoint.sh
# 职责：按顺序执行 steps 目录下的所有初始化脚本，并严格监控返回码。
# 改进：使用 set +e 显式捕获退出码，避免 '!' 逻辑取反导致错误码丢失 (变为0)。
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
  # 使用 set +e 暂时关闭自动退出，以便精准捕获子脚本的原始退出码。
  # 之前的 'if ! cmd' 写法会导致 $? 被 '!' 逻辑取反为 0，从而丢失真实错误码。
  set +e
  bash -e "${step}"
  status=$?
  set -e

  # 检查退出码
  if [ "${status}" -ne 0 ]; then
    log_error "step failed with exit code ${status}: ${step_name}"
    # 立即终止整个 bootstrap 过程，并将错误码回传给 install.sh
    exit "${status}"
  fi

  log_info "step completed: ${step_name}"
done

log_info "bootstrap finished successfully"