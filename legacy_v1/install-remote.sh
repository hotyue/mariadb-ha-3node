#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# install-remote.sh
# v1.1.2 remote entry wrapper (wrapper only)
#
# Responsibilities:
# - ensure working tree under /opt/docker/mariadb-ha-3node
# - fetch repo tarball and extract into that directory
# - execute ./install.sh from repo root
#
# Forbidden:
# - re-implement bootstrap/runtime/verify logic
# - introduce complex branches / config systems
###############################################################################

TARGET_BASE="/opt/docker"
TARGET_DIR="${TARGET_BASE}/mariadb-ha-3node"

REPO_TARBALL_URL="https://github.com/hotyue/mariadb-ha-3node/archive/refs/heads/main.tar.gz"

log_info()  { printf '[remote][INFO] %s\n'  "$*"; }
log_warn()  { printf '[remote][WARN] %s\n'  "$*"; }
log_error() { printf '[remote][ERROR] %s\n' "$*" >&2; }

fail() {
  log_error "$*"
  exit 1
}

need_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || fail "required command not found: ${c}"
}

main() {
  need_cmd bash
  need_cmd curl
  need_cmd tar

  # ---------------------------------------------------------------------------
  # 1. ensure base directory exists (小白友好：自动创建)
  # ---------------------------------------------------------------------------
  if [[ ! -d "${TARGET_BASE}" ]]; then
    log_warn "base directory not found, creating: ${TARGET_BASE}"
    mkdir -p "${TARGET_BASE}" || fail "failed to create ${TARGET_BASE}"
  fi

  # ---------------------------------------------------------------------------
  # 2. ensure base directory writable
  # ---------------------------------------------------------------------------
  if [[ ! -w "${TARGET_BASE}" ]]; then
    fail "base directory not writable: ${TARGET_BASE} (try: sudo)"
  fi

  # ---------------------------------------------------------------------------
  # 3. prepare project directory
  # ---------------------------------------------------------------------------
  mkdir -p "${TARGET_DIR}"

  log_info "target dir: ${TARGET_DIR}"
  log_info "downloading and extracting repository tarball"
  log_info "source: ${REPO_TARBALL_URL}"

  # Extract tarball directly into target dir.
  # NOTE: this overwrites existing files with same paths, but does not delete extra files.
  # This behavior is intentionally minimal to avoid touching runtime/state under /opt/docker/*.
  if ! curl -fsSL "${REPO_TARBALL_URL}" | tar -xz -C "${TARGET_DIR}" --strip-components=1; then
    fail "download/extract failed"
  fi

  # ---------------------------------------------------------------------------
  # 4. sanity check
  # ---------------------------------------------------------------------------
  if [[ ! -f "${TARGET_DIR}/install.sh" ]]; then
    fail "missing file after extract: ${TARGET_DIR}/install.sh"
  fi

  if [[ ! -x "${TARGET_DIR}/install.sh" ]]; then
    fail "install.sh is not executable: ${TARGET_DIR}/install.sh"
  fi

  cd "${TARGET_DIR}"

  log_info "execute: ./install.sh"
  exec ./install.sh
}

main "$@"
