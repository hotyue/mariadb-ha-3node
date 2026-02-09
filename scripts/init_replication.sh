#!/usr/bin/env bash
set -euo pipefail

# 0. 加载配置
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/topology.env"

# 1. 身份识别
LOCAL_IPS=$(hostname -I)
MY_ROLE="UNKNOWN"

if [[ "$LOCAL_IPS" == *"$NODE_1_IP"* ]]; then
    MY_ROLE="MASTER"
elif [[ "$LOCAL_IPS" == *"$NODE_2_IP"* ]] || [[ "$LOCAL_IPS" == *"$NODE_3_IP"* ]]; then
    MY_ROLE="SLAVE"
else
    echo "Error: IP not found in topology.env"
    exit 1
fi

echo "=========================================================="
echo " 正在初始化复制关系..."
echo " 本机角色: ${MY_ROLE}"
echo " Master IP: ${NODE_1_IP}"
echo "=========================================================="

# 2. 安全交互：获取密码
echo ">>> 请输入密码以配置复制 (输入不显示)"
read -s -p "1. 输入 Root 密码: " ROOT_PASS
echo ""
read -s -p "2. 输入 复制用户(repl) 密码: " REPL_PASS
echo ""

# 函数：执行 SQL
exec_sql() {
    docker exec -i mariadb mariadb -uroot -p"${ROOT_PASS}" -e "$1"
}

# 3. Master 逻辑：创建复制用户
if [ "${MY_ROLE}" == "MASTER" ]; then
    echo ">>> [Master] 创建复制用户 '${REPL_USER}'..."
    exec_sql "CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASS}';"
    exec_sql "GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';"
    exec_sql "FLUSH PRIVILEGES;"
    echo ">>> [Master] 复制用户准备就绪。"

# 4. Slave 逻辑：连接 Master
else
    echo ">>> [Slave] 正在连接 Master (${NODE_1_IP})..."
    
    # 停止同步（防止报错）
    exec_sql "STOP SLAVE; RESET SLAVE ALL;" || true
    
    # 配置 GTID 复制 (MariaDB 10.x 特性，比 MySQL 简单)
    # 使用 MASTER_USE_GTID = slave_pos 自动寻找同步点
    exec_sql "CHANGE MASTER TO \
        MASTER_HOST='${NODE_1_IP}', \
        MASTER_PORT=${DB_PORT}, \
        MASTER_USER='${REPL_USER}', \
        MASTER_PASSWORD='${REPL_PASS}', \
        MASTER_USE_GTID=slave_pos;"
        
    exec_sql "START SLAVE;"
    
    echo ">>> [Slave] 复制已启动，正在检查状态..."
    sleep 3
    
    # 简单检查
    STATUS=$(exec_sql "SHOW SLAVE STATUS\G")
    IO=$(echo "${STATUS}" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL=$(echo "${STATUS}" | grep "Slave_SQL_Running:" | awk '{print $2}')
    
    if [[ "${IO}" == "Yes" && "${SQL}" == "Yes" ]]; then
        echo -e "\033[0;32m>>> 成功！复制正在运行 (IO: Yes, SQL: Yes)\033[0m"
    else
        echo -e "\033[0;31m>>> 警告！复制状态异常 (IO: ${IO}, SQL: ${SQL})\033[0m"
        echo "请检查防火墙端口 ${DB_PORT} 是否开放，或密码是否正确。"
    fi
fi
