# 🚀 MariaDB HA 3-Node Cluster (v3.5 Enterprise)

基于 Docker + ProxySQL 构建的 **轻量级、企业级、全自动容灾** 的 MariaDB 三节点高可用读写分离集群。

无需沉重的 Etcd 或 Consul，通过独创的 **动态哨兵 (Dynamic Sentinel)** 与 **智能归队 (Smart Rejoin)** 脚本，实现 24/7 永不宕机的数据库架构。完美抗击脑裂，无惧单点故障。

---

## 🌟 核心特性 (Key Features)

* **⚡ 一键傻瓜式部署**: 运行 `bootstrap.sh` 即可全自动完成 Docker 安装、容器编排、主从复制初始化和安全凭据生成。
* **🧠 企业级动态哨兵 (`monitor.sh`)**:
    * **动态寻主**: 告别硬编码，自动从 ProxySQL 识别当前真・Master，死盯目标。
    * **确定性选举**: Master 宕机时，按优先级 (Node 1 > 2 > 3) 毫秒级推举新主，彻底杜绝并发脑裂。
    * **无限守护**: 故障转移完成后顺滑衔接，继续监控新主库，永不退出。
* **🧟 僵尸复活与智能归队 (`rejoin.sh`)**:
    * **0 交互自愈**: 宕机节点修复后，一键运行，自动拉起数据库容器。
    * **智能认主**: 自动扫描全网发现新老大，自动重置 GTID 复制状态降级为 Slave，并自动修正 ProxySQL 路由。
* **🛡️ 极致抗干扰底座**:
    * 完美兼容各种包含特殊字符 (`%`, `^`, `$`, `&` 等) 的极端变态密码（基于 `MYSQL_PWD` 环境变量注入）。
    * 精准过滤 MariaDB 11+ 客户端 SSL 警告，状态探测 100% 准确。
    * 基于 OpenSSL 的安全的本地密码 Hash 计算。

---

## 🏗️ 架构拓扑 (Architecture)

采用 **Sidecar 模式**，每个节点均部署一整套服务：
* **MariaDB (3306)**: 底层数据存储，基于 GTID 的异步/半同步复制。
* **ProxySQL (6032/6033)**: 流量网关。负责读写分离（HG 10 写，HG 20 读）与故障转移时的流量切换。
* **Adminer (8080)**: 轻量级 Web 数据库管理面板。
* **HA Sentinel (宿主机后台)**: 守护进程，负责健康检查与选举。

业务端只需连接 **本机 (127.0.0.1)** 的 ProxySQL `6033` 端口，底层节点的生死对业务层完全透明。

---

## 🚀 快速开始 (Quick Start)

### 1. 环境准备
* 3 台 Linux 服务器（推荐 Ubuntu/Debian），确保网络互通。
* 开放防火墙端口: `3306`, `6032`, `6033`, `8080`。

### 2. 一键安装 (在三台机器上分别执行)
```bash
curl -fsSL [https://raw.githubusercontent.com/hotyue/mariadb-ha-3node/main/scripts/bootstrap.sh](https://raw.githubusercontent.com/hotyue/mariadb-ha-3node/main/scripts/bootstrap.sh) -o bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh
```

交互提示时：第一台机器选择 MASTER，后两台机器选择 SLAVE。请牢记输入的三个密码。

### 3. 初始化路由并启动哨兵 (在三台机器上分别执行)
进入项目目录并执行：

```Bash
cd /opt/docker/mariadb-ha-3node

# 1. 注入 ProxySQL 路由规则与安全密码 Hash
./scripts/init_proxysql.sh

# 2. 启动后台守护哨兵
nohup ./scripts/monitor.sh > /var/log/ha-monitor.log 2>&1 &
```

至此，高可用集群已搭建完毕！🎉

## ⚔️ 混沌工程：容灾测试指南
我们强烈建议您在上线前进行一次“拔网线”测试，体验其自愈能力：

### 第一幕：主库宕机与自动切换

- 在存活的从库 (如 Node-2) 上盯盘：tail -f /var/log/ha-monitor.log

- 登录当前主库 (Node-1)，直接杀掉数据库：docker stop mariadb

- 观察 Node-2 日志，您将看到它：连接失败 -> 发起选举 -> 提升自己为 Master -> 刷新所有人的 ProxySQL 路由 -> 开始监控新主库。整个过程在 15 秒内全自动完成。

### 第二幕：宕机节点修复与归队

- 回到刚才死掉的 Node-1。

- 直接运行归队脚本：

```Bash
/opt/docker/mariadb-ha-3node/scripts/rejoin.sh
```
- 您将看到 Node-1 自动启动数据库、扫描发现 Node-2 是新老大、自动降级为 Slave 开始同步，并重新挂载哨兵。集群恢复完整三节点健康状态！

## 🔌 业务接入指南
您的应用程序只需要连接本地的 ProxySQL 即可享受高可用和读写分离，无需关心真实的 Master IP 是多少：

- Host: 127.0.0.1 (或当前应用所在服务器的内网 IP)

- Port: 6033 (ProxySQL 读写分离入口)

- User/Pass: （请在 Adminer 或 Master 节点中自行创建您的业务账号，它会自动同步到所有节点并被 ProxySQL 代理）

## 📂 目录结构
```text
Plaintext
/opt/docker/mariadb-ha-3node/
├── docker-compose.yml       # 容器编排文件
├── topology.env             # 集群 IP 及端口配置 (自动生成)
├── .secrets.env             # 核心凭据持久化 (安全隔离)
└── scripts/                 # 核心大脑
    ├── bootstrap.sh         # 一键安装引导程序
    ├── init_replication.sh  # 初始化主从复制
    ├── init_proxysql.sh     # 初始化流量网关
    ├── monitor.sh           # v3.5 核心：动态故障转移哨兵
    └── rejoin.sh            # v3.5 核心：宕机智能归队自愈程序
```

## 📜 更新日志 (v3.5 Enterprise)
- [重构] 彻底重写 monitor.sh，实现基于 ProxySQL 的动态寻主与确定性防脑裂选举机制。

- [新增] 增加全自动化 rejoin.sh 归队脚本，宕机恢复实现 0 交互。

- [修复] 修复 Docker 管道标准输入 -i 参数缺失导致的路由未刷新致命 Bug。

- [修复] 增强 MYSQL_PWD 环境变量注入，完美支持含特殊符号的强密码。

- [修复] 精准过滤 MariaDB 客户端自带的无密码 SSL 登录警告输出。