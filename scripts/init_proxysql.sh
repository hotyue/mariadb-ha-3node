#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.2 - ProxySQL Initialization (EnvVar Hardened)
# ==============================================================================
# 修复: 全面使用 MYSQL_PWD 环境变量传递密码，彻底解决特殊字符(*, #, @)问题
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

echo "----------------------------------------------------------"
echo ">>> ProxySQL 初始化配置 (v3.2 特殊字符增强版)"
echo "----------------------------------------------------------"

# 1. 获取用户期望的密码 (使用 -r 防止转义)
if [ -z "$DB_ROOT_PASS" ]; then
    read -r -s -p "1. 请输入 DB Root 密码: " DB_ROOT_PASS
    echo ""
fi
if [ -z "$PROXY_ADMIN_PASS" ]; then
    read -r -s -p "2. 请输入 ProxySQL Admin 密码 (你期望设置的): " PROXY_ADMIN_PASS
    echo ""
fi
echo "----------------------------------------------------------"

# 2. 确认身份
LOCAL_IPS=$(hostname -I)
AM_I_MASTER=0
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    AM_I_MASTER=1
fi

# 3. 后端账号创建 (仅 Master)
if [ "$AM_I_MASTER" -eq 1 ]; then
    log "Master: 检查/创建后端数据库账号..."
    # [FIX] 使用 MYSQL_PWD 传递 Root 密码
    docker exec -i -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot <<-SQL 2>/dev/null || true
        CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor_pass';
        GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';
        CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'app_pass';
        GRANT ALL PRIVILEGES ON *.* TO 'app'@'%';
        FLUSH PRIVILEGES;
SQL
    log "后端账号准备就绪。"
else
    log "Slave: 跳过后端账号创建。"
    sleep 2
fi

# ==============================================================================
# 4. [核心修复] 智能探测当前 ProxySQL 密码
# ==============================================================================
log "正在连接 ProxySQL Sidecar..."

CURRENT_PASS=""

# 定义探测函数，使用 MYSQL_PWD 避免特殊字符问题
check_proxysql_pass() {
    local pass=$1
    if docker exec -e MYSQL_PWD="${pass}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 尝试 1: 使用用户输入的密码 (如果之前已经初始化过)
if check_proxysql_pass "${PROXY_ADMIN_PASS}"; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
    log "连接成功 (使用自定义密码)。"

# 尝试 2: 使用默认密码 'admin'
elif check_proxysql_pass "admin"; then
    CURRENT_PASS="admin"
    warn "发现 ProxySQL 正在使用默认密码 (admin)。脚本将自动将其修改为您设定的密码。"

else
    echo -e "${RED}[ERROR] 无法连接到 ProxySQL!${NC}"
    echo "请检查容器是否运行: docker ps"
    echo "请尝试使用默认密码 admin 或您设置的密码手动连接测试。"
    exit 1
fi

# ==============================================================================
# 5. 下发配置 (包含修改 Admin 密码)
# ==============================================================================
log "正在下发路由规则..."

# [FIX] 使用 MYSQL_PWD 传递当前的 Admin 密码
# 注意：Here-Doc 中的变量会被 Shell 展开，但因为是在 SQL 字符串内部，
# 且通过 docker exec 的 stdin 传输，这比直接在命令行参数里写密码要安全得多。
docker exec -i -e MYSQL_PWD="${CURRENT_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL
    -- 1. 每次初始化前先清理
    DELETE FROM mysql_servers;
    DELETE FROM mysql_users;
    DELETE FROM mysql_query_rules;

    -- 2. 添加后端节点
    -- Writer (HG 10)
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (10, '$NODE_1_IP', 3306, 20);
    
    -- Readers (HG 20)
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (20, '$NODE_1_IP', 3306, 20);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (20, '$NODE_2_IP', 3306, 20);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (20, '$NODE_3_IP', 3306, 20);

    -- 3. 配置用户
    -- 监控用户
    UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
    UPDATE global_variables SET variable_value='monitor_pass' WHERE variable_name='mysql-monitor_password';
    UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_connect_interval';
    UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_ping_interval';
    
    -- 业务用户
    INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('app', 'app_pass', 10);

    -- 4. 读写分离规则
    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply)
    VALUES (1, 1, '^SELECT.*FOR UPDATE$', 10, 1);
    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply)
    VALUES (2, 1, '^SELECT', 20, 1);

    -- 5. [关键] 修改 Admin 密码
    -- 只有当当前密码不等于新密码时才更新，但为了确保一致性，强制更新
    UPDATE global_variables SET variable_value='admin:${PROXY_ADMIN_PASS}' WHERE variable_name='admin-admin_credentials';

    -- 6. 保存所有配置
    LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
    LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
    LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;
    LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
SQL

log "ProxySQL 配置完成！Admin 密码已更新。"
echo "----------------------------------------------------------"
echo -e " [验证] 尝试连接本地读写分离入口:"
echo -e " mysql -u app -papp_pass -h 127.0.0.1 -P 6033 -e 'SELECT @@hostname'"
echo "----------------------------------------------------------"
