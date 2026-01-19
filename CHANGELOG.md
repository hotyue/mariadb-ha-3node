# Changelog

记录 mariadb-ha-3node 项目的已发布版本变更。

---

## v1.0.0 - 2026-01-16

**控制面 Facts 渲染最小闭环**

- 新增控制面事实渲染脚本 `scripts/render_facts.sh`
- 生成统一的运行期事实快照 `runtime/facts.json`
- facts 输出具备原子性，始终为完整 JSON
- 默认安全策略为 `reject_write`（失败优先）
- facts 渲染不做推断、不做补偿

**未包含：**

- 数据面实际操作（MariaDB / ProxySQL）
- 自动故障检测与切主
- 性能与可用性调优

Tag：`v1.0.0`  
Commit：`9ba37ff`
