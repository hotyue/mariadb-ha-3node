#!/bin/bash
set -euo pipefail

# ==============================================================================
# MariaDB HA v3.2 - ProxySQL Initialization (Admin Reload Fix)
# ==============================================================================
# 关键修复: 增加 LOAD ADMIN VARIABLES 指令
# 原因: 修改 admin 接口密码后，必须显式重载 admin 变量才能生效
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
echo ">>> ProxySQL 初始化配置 (v3.2 Admin重载修复版)"
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
# 2. 后端账号创建 (适配 MariaDB 11)
# ==============================================================================
LOCAL_IPS=$(hostname -I)
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    log "Master: 检查/创建后端数据库账号..."
    # 使用 mariadb 客户端
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
fi

# ==============================================================================
# 3. 智能探测与重置检查
# ==============================================================================
log "正在探测 ProxySQL 连接状态..."

CURRENT_PASS=""
check_proxysql() {
    local pass=$1
    if docker exec -e MYSQL_PWD="${pass}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

if check_proxysql "${PROXY_ADMIN_PASS}"; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
    log "连接成功 (使用自定义密码)。"
elif check_proxysql "admin"; then
    CURRENT_PASS="admin"
    warn "ProxySQL 正在使用默认密码 (admin)。"
else
    warn "无法连接 ProxySQL！"
    err "环境状态异常，请务必先重置容器: docker rm -f proxysql && ./install_node.sh"
fi

# ==============================================================================
# 辅助函数: SQL 字符串转义
# ==============================================================================
escape_sql_str() {
    local input="$1"
    local output="${input//\\/\\\\}" # 转义反斜杠
    output="${output//\'/\\\'}"     # 转义单引号
    echo "$output"
}

# ==============================================================================
# 4. 下发配置
# ==============================================================================
log "正在下发路由配置与权限..."

# 转义密码
SAFE_ADMIN_PASS=$(escape_sql_str "${PROXY_ADMIN_PASS}")

# 构建 SQL
# 注意: 'admin:...' 被单引号包裹，# 号是安全的
docker exec -i -e MYSQL_PWD="${CURRENT_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL
    -- 清空旧配置
    DELETE FROM mysql_servers;
    DELETE FROM mysql_users;
    DELETE FROM mysql_query_rules;

    -- 写入新配置
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
    
    -- 更新 Admin 密码
    UPDATE global_variables SET variable_value='admin:${SAFE_ADMIN_PASS}' WHERE variable_name='admin-admin_credentials';

    -- [关键修复] 必须显式重载 ADMIN 变量，否则密码修改不生效！
    LOAD ADMIN VARIABLES TO RUNTIME; SAVE ADMIN VARIABLES TO DISK;
    
    -- 重载 MySQL 模块
    LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
    LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
    LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;
    LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
SQL

# ==============================================================================
# 5. 最终验证
# ==============================================================================
echo "----------------------------------------------------------"
log "正在验证新密码生效情况..."
sleep 2

if check_proxysql "${PROXY_ADMIN_PASS}"; then
    echo -e "${GREEN}✅ 验证成功！ProxySQL 已完美适配复杂密码。${NC}"
else
    echo -e "${RED}❌ 验证失败！${NC}"
    echo "请尝试手动调试: mysql -u admin -p'${PROXY_ADMIN_PASS}' -h 127.0.0.1 -P 6032"
    exit 1
fi
echo "----------------------------------------------------------"