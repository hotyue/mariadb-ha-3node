#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.2 - ProxySQL Initialization (Hex-Encoded Safe Mode)
# ==============================================================================
# 修复 1: 使用 Hex 编码注入密码，无视所有特殊字符 (*, #, @, ', ", \)
# 修复 2: 使用 MYSQL_PWD 环境变量，避免 Shell 参数解析干扰
# 修复 3: 适配 MariaDB 11+ 客户端指令
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${RED}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "----------------------------------------------------------"
echo ">>> ProxySQL 初始化配置 (v3.2 Hex 强力修复版)"
echo "----------------------------------------------------------"

# 1. 获取密码 (使用 -r 防止反斜杠转义)
if [ -z "$DB_ROOT_PASS" ]; then
    read -r -s -p "1. 请输入 DB Root 密码: " DB_ROOT_PASS
    echo ""
fi
if [ -z "$PROXY_ADMIN_PASS" ]; then
    read -r -s -p "2. 请输入 ProxySQL Admin 密码 (支持任意特殊字符): " PROXY_ADMIN_PASS
    echo ""
fi
echo "----------------------------------------------------------"

# ==============================================================================
# 辅助函数: 字符串转 Hex (在宿主机完成，确保安全)
# ==============================================================================
str_to_hex() {
    # 使用 od 将字符串转换为 hex，tr 删除换行和空格
    # 例如: "admin:pass#word" -> "61646d696e3a7061737323776f7264"
    printf "%s" "$1" | od -An -tx1 | tr -d ' \n'
}

# ==============================================================================
# 2. 后端账号创建 (MariaDB 11 兼容)
# ==============================================================================
LOCAL_IPS=$(hostname -I)
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    log "Master: 检查/创建后端数据库账号..."
    # 使用 mariadb 客户端指令 + MYSQL_PWD 环境变量
    docker exec -i -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot <<-SQL 2>/dev/null || true
        -- 创建监控用户
        CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor_pass';
        GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';
        -- 创建业务用户
        CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'app_pass';
        GRANT ALL PRIVILEGES ON *.* TO 'app'@'%';
        FLUSH PRIVILEGES;
SQL
    log "后端账号准备就绪。"
else
    log "Slave: 跳过后端账号创建。"
fi

# ==============================================================================
# 3. 智能探测 ProxySQL 连接
# ==============================================================================
log "正在探测 ProxySQL 连接状态..."

CURRENT_PASS=""
check_proxysql() {
    local pass=$1
    # 使用 MYSQL_PWD + mariadb/mysql 客户端测试连接
    if docker exec -e MYSQL_PWD="${pass}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 尝试新密码
if check_proxysql "${PROXY_ADMIN_PASS}"; then
    CURRENT_PASS="${PROXY_ADMIN_PASS}"
    log "连接成功 (使用自定义密码)。"
# 尝试默认密码
elif check_proxysql "admin"; then
    CURRENT_PASS="admin"
    warn "ProxySQL 正在使用默认密码 (admin)。准备进行安全加固..."
else
    err "无法连接 ProxySQL！请检查容器是否启动 (docker ps)。"
fi

# ==============================================================================
# 4. 下发配置 (使用 Hex 注入)
# ==============================================================================
log "正在下发路由配置与权限..."

# 步骤 A: 计算 Admin 凭据的 Hex 值
# 格式要求: "admin:password"
ADMIN_CRED_STR="admin:${PROXY_ADMIN_PASS}"
ADMIN_CRED_HEX=$(str_to_hex "${ADMIN_CRED_STR}")

log "生成的凭据 Hex 签名: ${ADMIN_CRED_HEX:0:10}..."

# 步骤 B: 执行 SQL (分为两部分，确保稳定性)

# B1. 基础路由配置 (IP 地址等无特殊字符，直接传)
docker exec -i -e MYSQL_PWD="${CURRENT_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL
    -- 清理旧配置
    DELETE FROM mysql_servers;
    DELETE FROM mysql_users;
    DELETE FROM mysql_query_rules;

    -- 添加服务器
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$NODE_1_IP', 3306);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$NODE_1_IP', 3306);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$NODE_2_IP', 3306);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$NODE_3_IP', 3306);

    -- 添加用户 (Monitor & App)
    UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
    UPDATE global_variables SET variable_value='monitor_pass' WHERE variable_name='mysql-monitor_password';
    UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_connect_interval';
    
    INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('app', 'app_pass', 10);

    -- 路由规则
    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply) VALUES (1, 1, '^SELECT.*FOR UPDATE$', 10, 1);
    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply) VALUES (2, 1, '^SELECT', 20, 1);
    
    LOAD MYSQL SERVERS TO RUNTIME; 
    LOAD MYSQL USERS TO RUNTIME; 
    LOAD MYSQL QUERY RULES TO RUNTIME;
SQL

# B2. Admin 密码更新 (使用 Hex 注入)
# 这是解决 # 号问题的核心: SQL 解析器看到的只是 hex 字符串，绝对不会把它当注释
docker exec -i -e MYSQL_PWD="${CURRENT_PASS}" proxysql mysql -u admin -h 127.0.0.1 -P 6032 <<-SQL
    -- 使用 X'...' 语法注入 Hex 字符串
    UPDATE global_variables SET variable_value=X'${ADMIN_CRED_HEX}' WHERE variable_name='admin-admin_credentials';
    
    -- 加载并保存所有配置到磁盘
    LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;
    SAVE MYSQL SERVERS TO DISK;
    SAVE MYSQL USERS TO DISK;
    SAVE MYSQL QUERY RULES TO DISK;
SQL

# ==============================================================================
# 5. 最终验证
# ==============================================================================
echo "----------------------------------------------------------"
log "正在验证新密码生效情况..."

# 稍等片刻让 ProxySQL reload
sleep 1

if check_proxysql "${PROXY_ADMIN_PASS}"; then
    log "✅ 验证成功！ProxySQL 已接受新的复杂密码。"
    echo -e "   [验证命令] mysql -u app -papp_pass -h 127.0.0.1 -P 6033 -e 'SELECT @@hostname'"
else
    err "❌ 验证失败！新密码似乎未生效。请检查日志。"
fi
echo "----------------------------------------------------------"
