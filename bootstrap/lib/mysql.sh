#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# MySQL/MariaDB Helper Library
# 
# 设计说明：
# 1. 专门用于 bootstrap 阶段对容器内数据库进行初始化配置。
# 2. 增加 Socket 检查逻辑，解决 MariaDB 启动时 Socket 文件延迟生成的竞态问题。
###############################################################################

# 此处密码必须与 steps/20-mariadb-init.sh 中的 ROOT_PASSWORD 保持一致
BOOTSTRAP_ROOT_PW="rootpass"
SOCKET_PATH="/run/mysqld/mysqld.sock"

# 内部函数：等待容器内的 Socket 文件就绪
_wait_for_socket() {
    local node="$1"
    for i in {1..15}; do
        if docker exec "${node}" ls "${SOCKET_PATH}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 执行 SQL 指令（无返回值输出，适用于 DDL/DML）
mysql_exec_local() {
    local node="$1"
    local sql="$2"
    
    if ! _wait_for_socket "${node}"; then
        echo "[ERROR] MariaDB socket not found in ${node} at ${SOCKET_PATH}" >&2
        return 1
    fi

    # --protocol=socket 强制使用本地通信，规避 TCP 认证限制
    # -i: 保持交互模式
    docker exec -i "${node}" mariadb -uroot -p"${BOOTSTRAP_ROOT_PW}" \
        --protocol=socket --socket="${SOCKET_PATH}" -e "${sql}"
}

# 执行查询并返回原始结果（去除表格边框和标题，适用于获取变量值）
mysql_query_value() {
    local node="$1"
    local sql="$2"
    
    if ! _wait_for_socket "${node}"; then
        return 1
    fi

    # -N: 不输出列名, -s: 静默模式
    docker exec -i "${node}" mariadb -uroot -p"${BOOTSTRAP_ROOT_PW}" \
        --protocol=socket --socket="${SOCKET_PATH}" -Nse "${sql}"
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