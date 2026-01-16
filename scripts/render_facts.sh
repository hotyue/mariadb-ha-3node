#!/usr/bin/env bash
set -euo pipefail

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
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOW_EPOCH="$(date -u +"%s")"

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
# 这里先写死结构，后续由你接 Orchestrator API / mysql / orchestrator-client
NODES_JSON=$(cat <<'EOF'
{
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
}
EOF
)

# ============================================================
# TODO 区域（实现阶段再填）
#
# 在这里，你将来可以：
# - 调 orchestrator-client
# - 查 orchestrator backend DB
# - 解析 mysql 状态
#
# 然后只做一件事：
#   → 填充上面的 FACT_* 变量
#
# 任何失败：
#   → 保持默认 reject_write 语义
# ============================================================

# ---------- 渲染最终 JSON ----------
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
mv "${TMP_FILE}" "${FACTS_FILE}"

exit 0
