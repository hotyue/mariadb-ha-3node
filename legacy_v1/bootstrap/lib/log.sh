#!/usr/bin/env bash
set -euo pipefail

_log_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

_log() {
  local level="$1"
  local msg="$2"
  printf '%s [%s] %s\n' "$(_log_ts)" "${level}" "${msg}"
}

log_info() {
  _log "INFO" "$1"
}

log_warn() {
  _log "WARN" "$1"
}

log_error() {
  _log "ERROR" "$1" >&2
}
