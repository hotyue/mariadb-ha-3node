# mariadb-ha-3node

一个基于 Docker 的 **三节点 MariaDB 高可用基础实现仓库**，提供  
**可重复部署、可冷启动恢复、可运维控制、可验证运行态** 的最小稳定形态。

本仓库以 **事实驱动** 为原则，所有能力均来自  
**已实现、已执行、已验证，并已并入《项目总事实账本》的结果**。

---

## 一、仓库定位

**mariadb-ha-3node** 的定位是：

> 提供一个 _确定性_ 的  
> **MariaDB 主从复制 + ProxySQL 读写分离** 的基础实现，  
> 用于学习、验证、演示，并作为后续版本演进的稳定上游基线。

**本仓库不是：**

- 自动化运维平台  
- 全功能 HA 管控系统  
- 云原生 Operator  
- 一键生产级交付方案  

---

## 二、当前能力（v1.1.2）

> v1.1.2 在 v1.1.0 的能力基础上，  
> **仅新增部署入口方式，不改变任何集群、复制或运行态行为。**

### 1. MariaDB 集群

- 三节点 MariaDB（1 主 2 从）
- 经典主从复制模型
- MariaDB 内建半同步复制
- 通过启动参数固化：
  - `server-id`
  - `log-bin`
- 容器冷启动（stop / start）后复制可自动恢复

### 2. ProxySQL

- ProxySQL 作为独立 Docker 容器运行
- 明确区分：
  - Admin 接口（6032）
  - Runtime 接口（6033）
- 后端节点分组：
  - 写组（主库）
  - 读组（从库）
- 基于真实 SQL 验证的读写分离行为

### 3. 初始化与启动

- 统一 bootstrap 机制
- 分阶段初始化：
  - Docker 网络
  - MariaDB 容器
  - 主从复制关系
  - ProxySQL 配置
- 所有初始化脚本具备幂等性，可安全重复执行

### 4. 运行态与运维

- 提供基础运维脚本：
  - `runtime/start.sh`
  - `runtime/stop.sh`
  - `runtime/status.sh`
- 明确职责：
  - 启停控制
  - 状态观测
  - **不包含自动修复逻辑**

### 5. 健康检查与验证

- ProxySQL Runtime 健康检查脚本
- 读写分离验证脚本
- 所有验证基于真实容器与真实 SQL 执行结果

---

## 三、一键部署入口（v1.1.1+）

自 **v1.1.1** 起，本仓库提供统一的一键部署入口，  
用于封装既有 bootstrap / runtime 逻辑。

### 1. 本地一键部署（v1.1.1）

在仓库根目录执行：

```bash
./install.sh
```

事实说明：

- install.sh 仅作为封装入口

- 不包含新的部署逻辑

- 不改变原有执行顺序或失败语义

### 2. 远程一行命令部署（v1.1.2）

无需 clone 仓库，直接执行：
```bansh
curl -fsSL https://raw.githubusercontent.com/hotyue/mariadb-ha-3node/main/install-remote.sh | bash
```

事实说明：

- install-remote.sh 仅为 install.sh 的远程入口封装

- 不包含任何部署逻辑

- 自动准备 /opt/docker 目录（如不存在）

- 仓库内容固定展开并执行于：
```text
/opt/docker/mariadb-ha-3node
```

- 与本地 ./install.sh 行为 完全等价

## 四、仓库结构说明
```text
mariadb-ha-3node/
├── install.sh              # 一键部署入口（v1.1.1+）
├── install-remote.sh       # 远程部署入口（v1.1.2+）
├── bootstrap/              # 初始化入口与分阶段脚本
│   ├── entrypoint.sh
│   ├── lib/
│   └── steps/
├── runtime/                # 运行态运维脚本
│   ├── start.sh
│   ├── stop.sh
│   └── status.sh
├── healthcheck/            # 运行态健康检查
│   └── proxysql.sh
├── verify/                 # 功能验证脚本
│   └── 02-readwrite.sh
├── docker/                 # Docker / Compose 相关文件
└── README.md
```
## 五、基本使用流程（概览）
### 方式一：一键部署（推荐）
```bash
./install.sh
```

或（远程）：
```bash
curl -fsSL ... | bash
```
### 方式二：手工分阶段（用于理解内部结构）
```bash
bash bootstrap/entrypoint.sh
bash runtime/status.sh
bash runtime/stop.sh
bash runtime/start.sh
bash verify/02-readwrite.sh
```
## 六、使用前提

- Linux 主机

- Docker（支持 docker run / docker network）

- Bash（支持 set -euo pipefail）

本仓库默认以 单机 Docker 环境 为运行载体。

## 七、事实原则说明

本仓库遵循以下原则：

- 所有能力必须：

    - 已实现

    - 已执行

    - 已验证

- README 仅描述：

    - 已并入《项目总事实账本》的事实能力

- README 不描述：

    - 未来计划

    - 未冻结行为

    - 推测性能力

## 八、版本状态

- 当前稳定版本：v1.1.2

- v1.1.0 / v1.1.1 / v1.1.2 的所有实现与行为：

    - 已被冻结为项目事实

- 后续版本（v1.2.0+）：

    - 仅能在既有事实之上演进

## 九、适用场景

- MariaDB 主从复制学习与验证

- ProxySQL 读写分离行为理解

- HA 基础机制实验环境

- 作为更复杂系统的上游基线

## 十、非目标声明

以下内容 不在 v1.1.x 范围内：

- 自动故障切换

- 脑裂处理

- 多主写入

- 云厂商集成

- 自动扩缩容

## 十一、许可与使用

本仓库用于技术实现与机制验证，
请根据自身环境评估生产使用风险。

