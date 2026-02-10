#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.2 - ProxySQL Initialization (Offline Repair Mode)
# ==============================================================================
# 终极方案: 停机 -> 挂载数据卷 -> 修改 DB -> 开机
# 解决痛点: 彻底避开 ProxySQL "关机回写" 覆盖配置的问题，同时无视 SQL 解析器 bug
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${RED}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "----------------------------------------------------------"
echo ">>> ProxySQL 初始化配置 (v3.2 停机冷改版)"
echo "----------------------------------------------------------"

# 1. 获取密码
if [ -z "${DB_ROOT_PASS:-}" ]; then
    read -r -s -p "1. 请输入 DB Root 密码: " DB_ROOT_PASS < /dev/tty
    echo ""
fi
if [ -z "${PROXY_ADMIN_PASS:-}" ]; then
    read -r -s -p "2. 请输入 ProxySQL Admin 密码 (支持任意特殊字符): " PROXY_ADMIN_PASS < /dev/tty
    echo ""
fi
echo "----------------------------------------------------------"

# ==============================================================================
# 2. 后端账号创建 (Master 节点执行)
# ==============================================================================
LOCAL_IPS=$(hostname -I)
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    log "Master: 检查/创建后端数据库账号..."
    docker exec -i -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot <<-SQL 2>/dev/null || true
        CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor_pass';
        GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';
        CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'app_pass';
        GRANT ALL PRIVILEGES ON *.* TO 'app'@'%';
        FLUSH PRIVILEGES;
SQL
else
    log "Slave: 跳过后端账号创建。"
fi

# ==============================================================================
# 3. 基础路由配置 (在线模式)
# ==============================================================================
# 先把不需要重启就能生效的路由规则配好
log "正在下发基础路由配置..."

# 探测当前密码 (默认为 admin)
CURRENT_PASS="admin"
if docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
fi

docker exec -i -e MYSQL_PWD="${CURRENT_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL 2>/dev/null || true
    DELETE FROM mysql_servers;
    DELETE FROM mysql_users;
    DELETE FROM mysql_query_rules;

    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$NODE_1_IP', 3306);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$NODE_1_IP', 3306);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$NODE_2_IP', 3306);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$NODE_3_IP', 3306);

    UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
    UPDATE global_variables SET variable_value='monitor_pass' WHERE variable_name='mysql-monitor_password';
    UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_connect_interval';
    
    INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('app', 'app_pass', 10);

    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply) VALUES (1, 1, '^SELECT.*FOR UPDATE$', 10, 1);
    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply) VALUES (2, 1, '^SELECT', 20, 1);

    -- 保存到磁盘，为停机修改做准备
    LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
    LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
    LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;
    LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
SQL

# ==============================================================================
# 4. 核弹级修复: 停机冷修改 Admin 密码
# ==============================================================================
log "正在停止 ProxySQL 以进行冷修改..."
docker stop proxysql >/dev/null

log "启动临时工兵容器修改数据库文件..."
# 转义 SQLite 单引号
SQLITE_PASS="${PROXY_ADMIN_PASS//\'/\'\'}"

# 
# 核心逻辑：
# 1. 挂载原有数据卷
# 2. 安装 sqlite3
# 3. 传入环境变量 (避免 Shell 解析 # 号)
# 4. 修改 DB 并修正文件权限
docker run --rm \
    -v mariadb-ha-3node_proxysql_data:/var/lib/proxysql \
    -e ADMIN_PASS="${SQLITE_PASS}" \
    --entrypoint /bin/bash \
    proxysql/proxysql:latest \
    -c "apt-get update -qq && \
        apt-get install -y -qq sqlite3 && \
        sqlite3 /var/lib/proxysql/proxysql.db \"UPDATE global_variables SET variable_value='admin:' || '\$ADMIN_PASS' WHERE variable_name='admin-admin_credentials';\" && \
        chown -R proxysql:proxysql /var/lib/proxysql"

log "冷修改完成，正在重启 ProxySQL..."
docker start proxysql >/dev/null

log "等待服务就绪 (5s)..."
sleep 5

# ==============================================================================
# 5. 最终验证
# ==============================================================================
echo "----------------------------------------------------------"
log "正在验证新密码..."

if docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 'OK' as status" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ 验证成功！ProxySQL 已接受复杂密码。${NC}"
else
    echo -e "${RED}❌ 验证失败！${NC}"
    echo "调试建议: docker logs proxysql"
    exit 1
fi
echo "----------------------------------------------------------"