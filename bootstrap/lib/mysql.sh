#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# MySQL/MariaDB Helper Library
# 
# 设计说明：
# 1. 专门用于 bootstrap 阶段对容器内数据库进行初始化配置。
# 2. mysql_exec_local: 通过 Unix Socket 连接，无需密码，规避 Access Denied 风险。
# 3. mysql_query_value: 获取单行结果，用于提取 Binlog 坐标或 GTID。
###############################################################################

# 执行 SQL 指令（无返回值输出，适用于 DDL/DML）
mysql_exec_local() {
    local node="$1"
    local sql="$2"
    
    # -i: 保持交互模式以便传递标准输入
    # -uroot: 不指定 -h 和 -p，强制使用本地 Socket 认证
    docker exec -i "${node}" mariadb -uroot -e "${sql}"
}

# 执行查询并返回原始结果（去除表格边框和标题，适用于获取变量值）
mysql_query_value() {
    local node="$1"
    local sql="$2"
    
    # -N: 不输出列名
    # -s: 静默模式，去除表格线
    docker exec -i "${node}" mariadb -uroot -Nse "${sql}"
}

# 检查节点是否接受 SQL 查询
check_mysql_connection() {
    local node="$1"
    if mysql_exec_local "${node}" "SELECT 1;" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}