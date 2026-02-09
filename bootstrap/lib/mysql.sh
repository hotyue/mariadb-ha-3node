#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# MySQL/MariaDB Helper Library
# 
# 设计说明：
# 1. 专门用于 bootstrap 阶段对容器内数据库进行初始化配置。
# 2. 由于 MariaDB 镜像在设置 MARIADB_ROOT_PASSWORD 后会禁用无密码 Socket 登录，
#    因此此处必须显式配合密码使用。
###############################################################################

# 此处密码必须与 steps/20-mariadb-init.sh 中的 ROOT_PASSWORD 保持一致
BOOTSTRAP_ROOT_PW="rootpass"

# 执行 SQL 指令（无返回值输出，适用于 DDL/DML）
mysql_exec_local() {
    local node="$1"
    local sql="$2"
    
    # -i: 保持交互模式以便传递标准输入
    # 使用 -p 传递初始化时设定的 root 密码
    docker exec -i "${node}" mariadb -uroot -p"${BOOTSTRAP_ROOT_PW}" -e "${sql}"
}

# 执行查询并返回原始结果（去除表格边框和标题，适用于获取变量值）
mysql_query_value() {
    local node="$1"
    local sql="$2"
    
    # -N: 不输出列名
    # -s: 静默模式，去除表格线
    docker exec -i "${node}" mariadb -uroot -p"${BOOTSTRAP_ROOT_PW}" -Nse "${sql}"
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