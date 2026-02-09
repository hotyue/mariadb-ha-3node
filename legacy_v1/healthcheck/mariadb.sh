#!/usr/bin/env bash
set -euo pipefail

# 用法: ./mariadb.sh [node_name]
# 例如: ./mariadb.sh mariadb-1

NODE="${1:-mariadb-1}"

log() {
  printf '[mariadb][%s][healthcheck] %s\n' "${NODE}" "$1"
}

fail() {
  printf '[mariadb][%s][healthcheck][ERROR] %s\n' "${NODE}" "$1" >&2
  exit 1
}

# 1. 检查容器状态
if ! docker ps --format '{{.Names}}' | grep -qx "${NODE}"; then
  fail "container not running"
fi

# 2. 使用 mariadb-admin ping 进行存活检测
# 这种方式在容器内通过 socket 运行，不需要 TCP 密码
if ! docker exec "${NODE}" mariadb-admin ping >/dev/null 2>&1; then
  fail "mariadb service not responding to ping"
fi

# 3. 检查只读状态 (可选，用于区分 Master/Slave)
# mysql_query_value 在 lib/mysql.sh 中，这里直接用 docker exec 简单实现
READ_ONLY=$(docker exec "${NODE}" mariadb -uroot -Nse "SELECT @@read_only;")
if [[ "${READ_ONLY}" == "1" ]]; then
    log "node is healthy (Mode: Read-Only)"
else
    log "node is healthy (Mode: Read-Write/Master)"
fi

exit 0