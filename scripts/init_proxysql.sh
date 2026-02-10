#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.2 - ProxySQL Initialization (Hex-SQLite Diagnostic Mode)
# ==============================================================================
# 绝杀方案: Hex 编码 -> SQLite 文件注入 -> 显式报错
# 核心逻辑:
#   1. 将密码转换为 Hex，使用 SQLite 的 X'...' 语法写入，物理隔绝字符干扰
#   2. 验证阶段输出详细的 MySQL Client 报错，定位到底是密码错还是连不上
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
echo ">>> ProxySQL 初始化配置 (v3.2 Hex-SQLite 诊断版)"
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
log "正在下发基础路由配置..."

# 探测当前密码 (尝试 admin，若失败则假设已是新密码)
CURRENT_PASS="admin"
if docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
fi

# 配置基础项
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

    -- 落地磁盘
    LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
    LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
    LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;
    LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
SQL

# ==============================================================================
# 4. Hex-SQLite 物理注入修复
# ==============================================================================
log "正在停止 ProxySQL 以进行 Hex 物理注入..."
docker stop proxysql >/dev/null

# A. 计算 Hex 值 (在宿主机完成，绝对安全)
# 使用 od 将字符串转换为纯 hex，tr 删除换行
ADMIN_PASS_HEX=$(printf "%s" "${PROXY_ADMIN_PASS}" | od -An -tx1 | tr -d ' \n')
# 目标格式: admin:PASSWORD (Hex)
# 我们将分别拼接 'admin:' 和 Hex密码，确保 SQLite 正确处理
log "密码 Hex 指纹: ${ADMIN_PASS_HEX:0:8}..."

# B. 生成 SQL 文件
SQL_FILE="/tmp/proxysql_hex_fix.sql"
# SQLite 语法: 'admin:' || CAST(x'HEXVALUE' AS TEXT)
# 这会将 hex 转换回 text 并拼接到 admin: 后面，彻底避开任何字符解析问题
cat <<EOF > "${SQL_FILE}"
UPDATE global_variables 
SET variable_value = 'admin:' || CAST(x'${ADMIN_PASS_HEX}' AS TEXT) 
WHERE variable_name = 'admin-admin_credentials';
.quit
EOF
chmod 644 "${SQL_FILE}"

log "启动工兵容器，执行 Hex 注入..."
docker run --rm \
    -v mariadb-ha-3node_proxysql_data:/var/lib/proxysql \
    -v "${SQL_FILE}":/hex_fix.sql \
    proxysql/proxysql:latest \
    /bin/bash -c "apt-get update -qq && \
                  apt-get install -y -qq sqlite3 && \
                  sqlite3 /var/lib/proxysql/proxysql.db < /hex_fix.sql && \
                  chown -R proxysql:proxysql /var/lib/proxysql"

rm -f "${SQL_FILE}"

log "注入完成，正在重启 ProxySQL..."
docker start proxysql >/dev/null

log "等待服务就绪 (5s)..."
sleep 5

# ==============================================================================
# 5. 显式验证 (带报错输出)
# ==============================================================================
echo "----------------------------------------------------------"
log "正在验证新密码..."

# 尝试连接，如果失败则捕获输出
OUTPUT=$(docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 'OK' as status" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ 验证成功！ProxySQL 已接受复杂密码。${NC}"
    
else
    echo -e "${RED}❌ 验证失败！MySQL 客户端报错如下：${NC}"
    echo "----------------------------------------------------------"
    echo "${OUTPUT}"
    echo "----------------------------------------------------------"
    echo "可能原因分析:"
    echo "1. 'Access denied': 密码已写入，但与输入不匹配 (特殊字符或编码问题)。"
    echo "2. 'Can't connect': ProxySQL 服务未启动。"
    echo "如果报错是 Access denied，说明密码中的 * 或 # 导致了特殊的 Hash 识别问题。"
    exit 1
fi
echo "----------------------------------------------------------"