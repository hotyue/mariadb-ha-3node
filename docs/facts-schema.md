# 控制面事实快照规范（Facts Schema）

本文档定义 **控制面（Orchestrator）对外发布的事实快照（Facts Snapshot）**
的**数据结构、字段语义与合法取值**。

事实快照是本项目中 **唯一被数据面（ProxySQL）信任的状态来源**，
用于决定写入是否允许、路由指向以及失败行为。

> 本规范是 **控制面 → 数据面** 的硬契约。  
> 任何实现若无法满足本规范，应视为实现不合格，而非规范需要妥协。

---

## 1. 设计目标

事实快照设计遵循以下目标：

1. **单一事实源**  
   - ProxySQL 不再自行判断拓扑或主节点
   - 所有决策均基于事实快照

2. **显式与可解释**  
   - 每一个“可写 / 不可写”的决定都有可追溯原因

3. **最小但完备**  
   - 不包含实现细节
   - 只包含决策所需的最小信息集

4. **实现无关**  
   - 不绑定 Orchestrator 的具体 API
   - 可通过文件、HTTP、KV、SQL 等方式生成

---

## 2. 事实快照的载体约定

在本项目的参考实现中，事实快照以 **JSON 文件** 形式存在：

runtime/facts.json

说明：

- `runtime/` 目录为**运行期目录**，不应纳入 Git 版本控制
- 文件内容应被视为 **完整快照**，而非增量更新

---

## 3. 顶层结构总览

```json
{
  "schema_version": 1,
  "topology_version": 0,
  "generated_at_utc": "ISO-8601",
  "valid_for_seconds": 0,

  "quorum_available": false,
  "current_primary": null,
  "primary_reachable": false,

  "write_condition": false,
  "write_ack_required": 1,
  "write_ack_available": 0,

  "nodes": { },
  "decision": { }
}
```

## 4. 元信息字段（Meta）
### 4.1 schema_version（必填）

- 类型：number

- 说明：事实格式版本号

- 当前值：1

用途：

- 支持未来格式演进

- ProxySQL 若遇到未知版本，必须拒写

### 4.2 topology_version（必填）

- 类型：number

- 说明：拓扑版本号，必须单调递增

- 变更时机包括但不限于：

    - 主节点切换

    - 进入/退出拒写状态

    - fencing 状态变化

用途：

- 判断事实是否发生关键变化

- 便于日志、审计、回放

### 4.3 generated_at_utc（必填）

- 类型：string

- 格式：ISO-8601（UTC）

示例：
```makefile
2026-01-16T12:34:56Z
```
### 4.4 valid_for_seconds（必填）

- 类型：number

- 说明：事实快照的有效期（秒）

规则：

- ProxySQL 不得使用过期事实

- 若当前时间 > generated_at_utc + valid_for_seconds：

    - 必须拒绝写请求

## 5. 一致性与写入判定字段（核心）
### 5.1 quorum_available

- 类型：boolean

- 说明：是否满足决策 Quorum

- 仅用于控制面判断是否允许切主

### 5.2 current_primary

- 类型：string 或 null

- 说明：当前被认可的唯一 Primary 节点名

- 若为 null：

    - 表示当前不存在合法 Primary

    - ProxySQL 必须拒绝写

### 5.3 primary_reachable

- 类型：boolean

- 说明：Primary 是否可达（网络/进程层面）

### 5.4 write_condition

- 类型：boolean

- 说明：是否满足写条件

语义定义：
```nginx
write_condition == true
⇔ primary_reachable == true
   且 write_ack_available ≥ write_ack_required
```
### 5.5 write_ack_required

- 类型：number

- 固定值：1

- 说明：写入所需 ACK 数（半同步）

### 5.6 write_ack_available

- 类型：number

- 说明：当前可用 ACK 数

- 通常等于：

    - 可达 Replica 的数量（满足半同步条件）

## 6. 节点状态映射（nodes）
### 6.1 结构定义
```json
"nodes": {
  "node-1": {
    "role": "primary",
    "reachable": true,
    "readable": true,
    "writable": true,
    "gtid_executed": "string",
    "replication_lag_seconds": 0
  }
}
```
### 6.2 字段说明
| 字段  |  	类型  |  	说明  |
| ---- | ---- | ---- |
| role | 	string | 	primary / replica |
| reachable | 	boolean | 	是否可达 |
| readable | 	boolean | 	是否允许读 |
| writable | 	boolean | 	是否允许写（仅 Primary 为 true） |
| gtid_executed | 	string | 	当前 GTID 位点（用于解释/选主） |
| replication_lag_seconds | 	number | 	复制延迟（秒） |

说明：

- nodes 字段主要用于：

    - 可观测性

    - 决策解释

- ProxySQL 不应基于 nodes 自行选主

## 7. 决策解释字段（decision）
### 7.1 结构定义
```json
"decision": {
  "mode": "reject_write",
  "reason": "ack_unavailable",
  "fencing_required": true,
  "fenced_nodes": ["node-1"]
}
```
### 7.2 字段说明
| 字段  |  	类型  |  	说明 |
| ----  | ---- | ---- |
| mode | 	string | 	当前系统模式 |
| reason | 	string | 	机器可读原因码 |
| fencing_required | 	boolean | 	是否必须执行 fencing |
| fenced_nodes | 	array | 	已被隔离的节点列表 |
### 7.3 mode 合法值（建议）

- normal：正常运行

- degraded：降级但仍可写

- failover：正在切主

- readonly：只读

- reject_write：明确拒绝写

## 8. ProxySQL 的最小消费规则（规范性要求）

ProxySQL 或其同步脚本 必须严格遵循：

- facts.json 不存在或解析失败 → 拒写

- facts.json 过期 → 拒写

- current_primary == null → 拒写

- write_condition == false → 拒写

- 仅当以上条件均满足时：

    - 写 → current_primary

    - 读 → readable == true && reachable == true 的节点

## 9. 规范一致性声明

本事实快照规范必须满足：

- 不削弱 failure-semantics.md 中的任何拒写条件

- 不允许通过字段组合“绕过” Quorum

- 不引入隐式一致性降级路径

## 10. 总结

本项目通过 facts.json 实现了一个明确的原则：

> 控制面只输出事实，
> 数据面只执行事实，
> 失败时拒绝写，而不是解释失败。

这是在非共识数据库体系下，
实现“教科书级多地高可用”的关键设计点。