#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.3 - ProxySQL Initialization (Hash Injection Mode)
# ==============================================================================
# 终极方案: 计算 MySQL Native Hash -> SQLite 注入
# 核心逻辑:
#   1. 优先读取 .secrets.env 中的预计算 Hash
#   2. 若无预计算，调用 Docker 现场计算 Hash
#   3. 将 Hash 值直接注入 ProxySQL 底层配置
# 解决痛点: 彻底解决以 * 开头密码被误判的问题，同时提升安全性
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"
SECRETS_FILE="${BASE_DIR}/.secrets.env"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${RED}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "----------------------------------------------------------"
echo ">>> ProxySQL 初始化配置 (v3.3 哈希注入版)"
echo "----------------------------------------------------------"

# ==============================================================================
# 1. 获取密码与哈希
# ==============================================================================
PROXY_ADMIN_HASH=""

# 尝试从 .secrets.env 加载 (优先)
if [ -f "${SECRETS_FILE}" ]; then
    log "检测到凭据文件 .secrets.env，正在加载..."
    # 临时 source 文件以获取变量
    set +u # 允许部分变量为空
    source "${SECRETS_FILE}"
    set -u
    
    # 赋值
    if [ -n "${AUTO_DB_ROOT_PASS:-}" ]; then DB_ROOT_PASS="${AUTO_DB_ROOT_PASS}"; fi
    if [ -n "${AUTO_PROXY_ADMIN_PASS:-}" ]; then PROXY_ADMIN_PASS="${AUTO_PROXY_ADMIN_PASS}"; fi
    if [ -n "${AUTO_PROXY_ADMIN_HASH:-}" ]; then PROXY_ADMIN_HASH="${AUTO_PROXY_ADMIN_HASH}"; fi
fi

# 如果还是没密码 (手动运行模式)，则交互输入
if [ -z "${DB_ROOT_PASS:-}" ]; then
    read -r -s -p "1. 请输入 DB Root 密码: " DB_ROOT_PASS < /dev/tty
    echo ""
fi
if [ -z "${PROXY_ADMIN_PASS:-}" ]; then
    read -r -s -p "2. 请输入 ProxySQL Admin 密码 (支持任意特殊字符): " PROXY_ADMIN_PASS < /dev/tty
    echo ""
fi

# 如果 Hash 为空 (说明是手动输入或旧版 secrets)，现场计算
if [ -z "${PROXY_ADMIN_HASH:-}" ]; then
    log "未找到预计算哈希，正在使用 Docker 现场计算..."
    # 使用 mariadb 容器计算 PASSWORD()，确保算法一致
    PROXY_ADMIN_HASH=$(docker run --rm mariadb:latest mariadb -N -e "SELECT PASSWORD('${PROXY_ADMIN_PASS}')" 2>/dev/null)
    log "哈希计算完成。"
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

# 探测当前密码 (尝试 admin)
CURRENT_PASS="admin"
if docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
fi

# 配置基础项 (不含 Admin 密码)
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
# 4. 哈希物理注入 (核心修复)
# ==============================================================================
log "正在停止 ProxySQL 以进行哈希注入..."
docker stop proxysql >/dev/null

log "目标哈希指纹: ${PROXY_ADMIN_HASH:0:8}..."

# 生成 SQL 文件
# 直接写入哈希值。格式: admin:*HASH
# 由于 Hash 仅包含 * 和 Hex 字符，这里是绝对安全的
SQL_FILE="/tmp/proxysql_hash_fix.sql"

cat <<EOF > "${SQL_FILE}"
UPDATE global_variables 
SET variable_value = 'admin:${PROXY_ADMIN_HASH}' 
WHERE variable_name = 'admin-admin_credentials';
.quit
EOF
chmod 644 "${SQL_FILE}"

log "启动工兵容器，执行注入..."
docker run --rm \
    -v mariadb-ha-3node_proxysql_data:/var/lib/proxysql \
    -v "${SQL_FILE}":/hash_fix.sql \
    proxysql/proxysql:latest \
    /bin/bash -c "apt-get update -qq && \
                  apt-get install -y -qq sqlite3 && \
                  sqlite3 /var/lib/proxysql/proxysql.db < /hash_fix.sql && \
                  chown -R proxysql:proxysql /var/lib/proxysql"

rm -f "${SQL_FILE}"

log "注入完成，正在重启 ProxySQL..."
docker start proxysql >/dev/null

log "等待服务就绪 (5s)..."
sleep 5

# ==============================================================================
# 5. 显式验证
# ==============================================================================
echo "----------------------------------------------------------"
log "正在验证新密码..."

# 验证时使用【明文】去连接，ProxySQL 内部会自动将明文转哈希并比对
OUTPUT=$(docker exec -e MYSQL_PWD="${PROXY_ADMIN_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 'OK' as status" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ 验证成功！ProxySQL 已接受复杂密码 (Hash Mode)。${NC}"
else
    echo -e "${RED}❌ 验证失败！MySQL 客户端报错如下：${NC}"
    echo "----------------------------------------------------------"
    echo "${OUTPUT}"
    echo "----------------------------------------------------------"
    exit 1
fi
echo "----------------------------------------------------------"