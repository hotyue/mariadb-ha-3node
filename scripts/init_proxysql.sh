#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.0 - ProxySQL Sidecar Initialization
# ==============================================================================

BASE_DIR="/opt/docker/mariadb-ha-3node"
source "${BASE_DIR}/topology.env"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }

# 1. 确认本机身份
LOCAL_IPS=$(hostname -I)
AM_I_MASTER=0
if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    AM_I_MASTER=1
fi

# ==============================================================================
# 第一步：在后端数据库创建必要账号 (只在 Master 执行)
# ==============================================================================
if [ "$AM_I_MASTER" -eq 1 ]; then
    log "本机是 Master，正在创建后端数据库账号 (monitor & app)..."
    
    # 创建 monitor 用户 (用于 ProxySQL 心跳检测)
    docker exec -i mariadb mariadb -uroot -p"${DB_ROOT_PASS}" <<-SQL
        -- 创建监控用户
        CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor_pass';
        GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';
        
        -- 创建应用用户 (业务账号)
        CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'app_pass';
        GRANT ALL PRIVILEGES ON *.* TO 'app'@'%';
        
        FLUSH PRIVILEGES;
SQL
    log "后端账号创建成功！(将自动同步到 Slave)"
else
    log "本机是 Slave，跳过后端账号创建 (等待 Master 同步)..."
    # 给一点时间让账号同步过来
    sleep 2
fi

# ==============================================================================
# 第二步：配置本地 ProxySQL (所有节点都要执行)
# ==============================================================================
log "正在配置本地 ProxySQL Sidecar..."

# 等待 ProxySQL 启动
until docker exec -i proxysql mysql -u admin -p"${PROXY_ADMIN_PASS}" -h 127.0.0.1 -P 6032 -e "SELECT 1" >/dev/null 2>&1; do
    echo "等待 ProxySQL 启动..."
    sleep 2
done

# 生成 SQL 配置
# HG 10 = Writer (Master)
# HG 20 = Reader (Slaves + Master)
# 注意：我们使用公网 IP 连接后端
docker exec -i proxysql mysql -u admin -p"${PROXY_ADMIN_PASS}" -h 127.0.0.1 -P 6032 <<-SQL
    -- 1. 清理旧配置
    DELETE FROM mysql_servers;
    DELETE FROM mysql_users;
    DELETE FROM mysql_query_rules;

    -- 2. 添加后端节点
    -- Writer (Node-1) -> HG 10
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (10, '$NODE_1_IP', 3306, 20);
    
    -- Readers (Node-1, Node-2, Node-3) -> HG 20
    -- 设置权重：本地优先原则 (可选优化，这里先设为平均)
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (20, '$NODE_1_IP', 3306, 20);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (20, '$NODE_2_IP', 3306, 20);
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (20, '$NODE_3_IP', 3306, 20);

    -- 3. 添加用户
    -- 监控用户
    UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
    UPDATE global_variables SET variable_value='monitor_pass' WHERE variable_name='mysql-monitor_password';
    UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_connect_interval';
    UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_ping_interval';
    
    -- 应用用户 (app) - 必须与后端数据库一致
    INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('app', 'app_pass', 10);

    -- 4. 配置读写分离规则
    -- 所有 SELECT 发往 Reader Group (HG 20)
    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply)
    VALUES (1, 1, '^SELECT.*FOR UPDATE$', 10, 1); -- SELECT FOR UPDATE 必须走主库

    INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply)
    VALUES (2, 1, '^SELECT', 20, 1); -- 普通 SELECT 走从库

    -- 剩下的默认走 Writer Group (HG 10) - 由 mysql_users.default_hostgroup 决定

    -- 5. 保存配置到磁盘
    LOAD MYSQL VARIABLES TO RUNTIME;
    SAVE MYSQL VARIABLES TO DISK;
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
    LOAD MYSQL USERS TO RUNTIME;
    SAVE MYSQL USERS TO DISK;
    LOAD MYSQL QUERY RULES TO RUNTIME;
    SAVE MYSQL QUERY RULES TO DISK;
SQL

log "ProxySQL 配置完成！"
echo "----------------------------------------------------------"
echo -e " [测试连接] mysql -u app -papp_pass -h 127.0.0.1 -P 6033 -e 'SELECT @@hostname'"
echo "----------------------------------------------------------"
