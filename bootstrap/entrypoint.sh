#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${BOOTSTRAP_DIR}/steps"
LIB_DIR="${BOOTSTRAP_DIR}/lib"

# shellcheck source=lib/log.sh
source "${LIB_DIR}/log.sh"

log_info "bootstrap started"
log_info "bootstrap dir: ${BOOTSTRAP_DIR}"

if [[ ! -d "${STEPS_DIR}" ]]; then
  log_error "steps directory not found: ${STEPS_DIR}"
  exit 1
fi

mapfile -t STEPS < <(find "${STEPS_DIR}" -type f -name "*.sh" | sort)

if [[ "${#STEPS[@]}" -eq 0 ]]; then
  log_error "no step scripts found under ${STEPS_DIR}"
  exit 1
fi

for step in "${STEPS[@]}"; do
  step_name="$(basename "${step}")"

  log_info "running step: ${step_name}"

  if [[ ! -x "${step}" ]]; then
    log_error "step not executable: ${step_name}"
    exit 1
  fi

  "${step}"

  log_info "step completed: ${step_name}"
done

log_info "bootstrap finished successfully"
