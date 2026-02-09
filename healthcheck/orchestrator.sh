#!/usr/bin/env bash
set -euo pipefail

ORC_CONTAINER="orchestrator"
ORC_API_PORT="3000"

log() {
  printf '[orchestrator][healthcheck] %s\n' "$1"
}

fail() {
  printf '[orchestrator][healthcheck][ERROR] %s\n' "$1" >&2
  exit 1
}

# 1. 检查容器状态
if ! docker ps --format '{{.Names}}' | grep -qx "${ORC_CONTAINER}"; then
  fail "container not running"
fi

# 2. 检查 API 健康度
# 请求 /api/health 接口，Orchestrator 会返回 "OK"
if ! curl -s "http://localhost:${ORC_API_PORT}/api/health" | grep -q "OK"; then
  fail "API health check failed (is the backend database up?)"
fi

log "orchestrator is healthy"
exit 0