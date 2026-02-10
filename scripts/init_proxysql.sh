#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.2 - ProxySQL Initialization (File Injection Mode)
# ==============================================================================
# 绝杀方案: 宿主机生成 SQL 文件 -> 挂载入容器 -> sqlite3 读取文件执行
# 核心优势: 彻底绕过 Bash/Shell 参数解析，无视任何特殊字符 (#, ', ", \, $)
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
echo ">>> ProxySQL 初始化配置 (v3.2 文件注入绝杀版)"
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
# 2. 后端账号创建 (仅 Master)
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
log "正在下发基础路由配置..."

# 探测当前密码 (尝试 admin)
CURRENT_PASS="admin"
if docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
fi

# 先配置不涉及 Admin 密码的部分
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

    -- 关键：保存配置到磁盘，确保后续冷修改是在此基础上进行
    LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
    LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
    LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;
    LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
SQL

# ==============================================================================
# 4. 绝杀修复: 停机 -> 挂载 SQL 文件 -> 执行
# ==============================================================================
log "正在停止 ProxySQL 以进行文件注入修复..."
docker stop proxysql >/dev/null

# A. 在宿主机生成 SQL 文件
# 使用 printf 确保特殊字符原样写入文件，不经过 Shell 解析
# SQLite 中单引号需要转义为 ''
SQLITE_PASS="${PROXY_ADMIN_PASS//\'/\'\'}"
SQL_FILE="/tmp/proxysql_reset_admin.sql"

# 写入 SQL 文件 (这是在宿主机上，绝对安全)
printf "UPDATE global_variables SET variable_value='admin:%s' WHERE variable_name='admin-admin_credentials';\n" "${SQLITE_PASS}" > "${SQL_FILE}"
chmod 644 "${SQL_FILE}"

log "启动临时工兵容器，挂载 SQL 文件直接执行..."

# B. 启动临时容器，挂载 volumes 和 SQL 文件
# 注意：容器内命令不再包含密码变量，只引用文件路径
docker run --rm \
    -v mariadb-ha-3node_proxysql_data:/var/lib/proxysql \
    -v "${SQL_FILE}":/update_admin.sql \
    proxysql/proxysql:latest \
    /bin/bash -c "apt-get update -qq && \
                  apt-get install -y -qq sqlite3 && \
                  sqlite3 /var/lib/proxysql/proxysql.db < /update_admin.sql && \
                  chown -R proxysql:proxysql /var/lib/proxysql"

# 清理宿主机临时文件
rm -f "${SQL_FILE}"

log "文件注入完成，正在重启 ProxySQL..."
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
    # 触发一个成功的流程图示意
    
else
    echo -e "${RED}❌ 验证失败！${NC}"
    echo "调试建议: docker logs proxysql"
    # 尝试输出一下当前的变量值 (需要默认密码)
    # docker exec -e MYSQL_PWD="admin" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT * FROM global_variables WHERE variable_name='admin-admin_credentials'"
    exit 1
fi
echo "----------------------------------------------------------"