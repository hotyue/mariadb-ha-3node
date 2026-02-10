#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.2 - Secret Manager (Special Char Hardened)
# ==============================================================================
# 作用: 生成 .secrets.env 文件，供全自动 Monitor 脚本读取密码
# 安全性: 
#   1. 生成的文件权限强制为 600 (仅 root 可读写)
#   2. 使用单引号强引用，支持 *, #, @, $, %, \ 等特殊字符
#   3. 使用 read -r 防止输入时反斜杠转义
# ==============================================================================

# 基础目录
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_FILE="${BASE_DIR}/.secrets.env"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}==========================================================${NC}"
echo -e "${BLUE}   MariaDB HA v3.2 - 自动化凭据配置向导 (加固版)${NC}"
echo -e "${BLUE}==========================================================${NC}"
echo "此脚本将生成 .secrets.env 文件，用于全自动故障转移。"
echo "请确保您输入的是正确的安装密码。"
echo ""

# 1. 获取 DB Root 密码 (使用 -r 防止反斜杠转义)
while true; do
    read -r -s -p "请输入 DB Root 密码: " DB_ROOT_1
    echo ""
    read -r -s -p "请再次输入 DB Root 密码: " DB_ROOT_2
    echo ""
    if [ "$DB_ROOT_1" == "$DB_ROOT_2" ] && [ -n "$DB_ROOT_1" ]; then
        DB_ROOT_PASS="$DB_ROOT_1"
        break
    else
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    fi
done

# 2. 获取 ProxySQL Admin 密码 (使用 -r 防止反斜杠转义)
echo ""
while true; do
    read -r -s -p "请输入 ProxySQL Admin 密码: " PROXY_ADMIN_1
    echo ""
    read -r -s -p "请再次输入 ProxySQL Admin 密码: " PROXY_ADMIN_2
    echo ""
    if [ "$PROXY_ADMIN_1" == "$PROXY_ADMIN_2" ] && [ -n "$PROXY_ADMIN_1" ]; then
        PROXY_ADMIN_PASS="$PROXY_ADMIN_1"
        break
    else
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    fi
done

# 3. 写入文件
echo -e "\n${BLUE}正在生成凭据文件...${NC}"

# 注意：这里使用不带引号的 SECRET 标识符，允许变量展开
# 但在变量外部加上单引号 ''，确保写入文件后是强引用格式
# 这样处理后，即使密码里有 # (井号)，source 时也不会被当做注释
cat <<SECRET > "$SECRET_FILE"
# ========================================================
# MariaDB HA Automation Secrets
# Generated at: $(date)
# WARNING: DO NOT COMMIT THIS FILE TO GIT!
# ========================================================
# 使用单引号包裹，防止 Shell 解析特殊字符 (*, $, @, # 等)
export AUTO_DB_ROOT_PASS='${DB_ROOT_PASS}'
export AUTO_PROXY_ADMIN_PASS='${PROXY_ADMIN_PASS}'
SECRET

# 4. 设置安全权限 (关键步骤)
chmod 600 "$SECRET_FILE"

if [ -f "$SECRET_FILE" ]; then
    echo -e "${GREEN}>>> 成功！凭据已保存至: $SECRET_FILE${NC}"
    echo "文件权限已设置为 600 (仅 root 可读)。"
    echo "内容已进行特殊字符保护，现在可以安全启动 monitor.sh 了。"
else
    echo -e "${RED}>>> 错误：文件生成失败。${NC}"
    exit 1
fi
