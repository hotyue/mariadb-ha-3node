#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# install.sh
# v1.1.1 one-command installer (wrapper only)
###############################################################################

PHASE_TOTAL=3

log_info()  { printf '[install][INFO] %s\n'  "$*"; }
log_warn()  { printf '[install][WARN] %s\n'  "$*"; }
log_error() { printf '[install][ERROR] %s\n' "$*" >&2; }

phase_start() {
  printf '[install][PHASE %s/%s] %s...\n' "$1" "$PHASE_TOTAL" "$2"
}

phase_ok() {
  printf '[install][PHASE %s/%s] OK: %s\n' "$1" "$PHASE_TOTAL" "$2"
}

phase_fail() {
  printf '[install][PHASE %s/%s] FAILED: %s\n' "$1" "$PHASE_TOTAL" "$2" >&2
}

###############################################################################
# PHASE 1: prerequisites
###############################################################################
phase_start 1 "prerequisites check"

if ! command -v docker >/dev/null 2>&1; then
  log_error "docker not found in PATH"
  phase_fail 1 "prerequisites check"
  exit 1
fi
log_info "docker found"

if ! docker ps >/dev/null 2>&1; then
  log_error "docker daemon not reachable (try: systemctl start docker)"
  phase_fail 1 "prerequisites check"
  exit 1
fi
log_info "docker daemon reachable"

if [[ ! -f "./bootstrap/entrypoint.sh" ]]; then
  log_error "missing file: bootstrap/entrypoint.sh"
  phase_fail 1 "prerequisites check"
  exit 1
fi
log_info "bootstrap entrypoint found"

if [[ ! -f "./runtime/start.sh" ]]; then
  log_error "missing file: runtime/start.sh"
  phase_fail 1 "prerequisites check"
  exit 1
fi
log_info "runtime start script found"

phase_ok 1 "prerequisites check"

###############################################################################
# PHASE 2: bootstrap
###############################################################################
phase_start 2 "bootstrap"

log_info "running: bootstrap/entrypoint.sh"
if ! bash ./bootstrap/entrypoint.sh; then
  rc=$?
  phase_fail 2 "bootstrap"
  log_error "bootstrap failed (exit=${rc})"
  log_error "see logs above"
  exit "${rc}"
fi

phase_ok 2 "bootstrap"

###############################################################################
# PHASE 3: runtime start
###############################################################################
phase_start 3 "runtime start"

log_info "running: runtime/start.sh"
if ! bash ./runtime/start.sh; then
  rc=$?
  phase_fail 3 "runtime start"
  log_error "runtime start failed (exit=${rc})"
  log_error "see logs above"
  exit "${rc}"
fi

phase_ok 3 "runtime start"

###############################################################################
# SUCCESS
###############################################################################
log_info "all done"
log_info "next: check status via: ./runtime/status.sh"
log_info "next: stop via: ./runtime/stop.sh"
log_info "optional: verification scripts under ./verify/"

exit 0
