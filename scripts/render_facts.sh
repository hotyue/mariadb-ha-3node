#!/usr/bin/env bash
set -u -o pipefail

# ============================================================
# render_facts.sh
#
# 目的：
#   从控制面（Orchestrator 或其派生信息源）生成
#   一个完整、原子、可消费的 facts.json 快照。
#
# 重要原则：
#   - 只渲染事实，不推断、不补偿
#   - 不满足条件时，输出“拒写事实”，而不是退出
#   - 永远输出完整 JSON（不可输出半成品）
# ============================================================

# ---------- 基本路径 ----------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/runtime"
FACTS_FILE="${RUNTIME_DIR}/facts.json"
TMP_FILE="${FACTS_FILE}.tmp"

mkdir -p "${RUNTIME_DIR}"

# ---------- 常量 ----------
SCHEMA_VERSION=1
VALID_FOR_SECONDS=10

# ---------- 时间 ----------
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z")"
NOW_EPOCH="$(date -u +"%s" 2>/dev/null || echo 0)"

# ---------- 默认：拒写态 ----------
# 任何无法确定的情况，都必须退化为 reject_write
FACT_QUORUM_AVAILABLE=false
FACT_CURRENT_PRIMARY=null
FACT_PRIMARY_REACHABLE=false
FACT_WRITE_CONDITION=false
FACT_ACK_REQUIRED=1
FACT_ACK_AVAILABLE=0
FACT_TOPOLOGY_VERSION=0

DECISION_MODE="reject_write"
DECISION_REASON="insufficient_or_unknown_state"
DECISION_FENCING_REQUIRED=false
DECISION_FENCED_NODES="[]"

# ---------- 节点事实（占位） ----------
NODES_JSON='{
  "node-1": {
    "role": "unknown",
    "reachable": false,
    "readable": false,
    "writable": false,
    "gtid_executed": "",
    "replication_lag_seconds": -1
  },
  "node-2": {
    "role": "unknown",
    "reachable": false,
    "readable": false,
    "writable": false,
    "gtid_executed": "",
    "replication_lag_seconds": -1
  },
  "node-3": {
    "role": "unknown",
    "reachable": false,
    "readable": false,
    "writable": false,
    "gtid_executed": "",
    "replication_lag_seconds": -1
  }
}'

# ============================================================
# 实现填充区（v1.0.0：保持为空）
#
# 在这里你将来可以：
#   - 调 orchestrator-client
#   - 查询 orchestrator backend DB
#   - 解析 mysql / replication 状态
#
# 约束：
#   - 只能修改 FACT_* / DECISION_* 变量
#   - 任一失败 → 不得 exit
#   - 不得推断、不补偿、不“猜一个最合理值”
#
# 当前版本行为：
#   - 明确输出 reject_write
# ============================================================

# （v1.0.0 无实现，保持默认拒写态）

# ---------- 渲染最终 JSON ----------
# 保证：即使上游完全不可用，这里也能产出完整 JSON
cat > "${TMP_FILE}" <<EOF
{
  "schema_version": ${SCHEMA_VERSION},
  "topology_version": ${FACT_TOPOLOGY_VERSION},
  "generated_at_utc": "${NOW_UTC}",
  "valid_for_seconds": ${VALID_FOR_SECONDS},

  "quorum_available": ${FACT_QUORUM_AVAILABLE},
  "current_primary": ${FACT_CURRENT_PRIMARY},
  "primary_reachable": ${FACT_PRIMARY_REACHABLE},

  "write_condition": ${FACT_WRITE_CONDITION},
  "write_ack_required": ${FACT_ACK_REQUIRED},
  "write_ack_available": ${FACT_ACK_AVAILABLE},

  "nodes": ${NODES_JSON},

  "decision": {
    "mode": "${DECISION_MODE}",
    "reason": "${DECISION_REASON}",
    "fencing_required": ${DECISION_FENCING_REQUIRED},
    "fenced_nodes": ${DECISION_FENCED_NODES}
  }
}
EOF

# ---------- 原子替换 ----------
mv -f "${TMP_FILE}" "${FACTS_FILE}"

exit 0
