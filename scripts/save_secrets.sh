cat << 'EOF' > scripts/save_secrets.sh
#!/bin/bash
set -e

# ==============================================================================
# MariaDB HA v3.0 - Secret Manager
# ==============================================================================
# 作用: 生成 .secrets.env 文件，供全自动 Monitor 脚本读取密码
# 安全性: 生成的文件权限将被强制设为 600 (仅 root 可读写)
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
echo -e "${BLUE}   MariaDB HA v3.0 - 自动化凭据配置向导${NC}"
echo -e "${BLUE}==========================================================${NC}"
echo "此脚本将生成 .secrets.env 文件，用于全自动故障转移。"
echo "请确保您输入的是正确的安装密码。"
echo ""

# 1. 获取 DB Root 密码
while true; do
    read -s -p "请输入 DB Root 密码: " DB_ROOT_1
    echo ""
    read -s -p "请再次输入 DB Root 密码: " DB_ROOT_2
    echo ""
    if [ "$DB_ROOT_1" == "$DB_ROOT_2" ] && [ -n "$DB_ROOT_1" ]; then
        DB_ROOT_PASS="$DB_ROOT_1"
        break
    else
        echo -e "${RED}密码不匹配或为空，请重试。${NC}"
    fi
done

# 2. 获取 ProxySQL Admin 密码
echo ""
while true; do
    read -s -p "请输入 ProxySQL Admin 密码: " PROXY_ADMIN_1
    echo ""
    read -s -p "请再次输入 ProxySQL Admin 密码: " PROXY_ADMIN_2
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

cat <<SECRET > "$SECRET_FILE"
# ========================================================
# MariaDB HA Automation Secrets
# Generated at: $(date)
# WARNING: DO NOT COMMIT THIS FILE TO GIT!
# ========================================================
export AUTO_DB_ROOT_PASS='${DB_ROOT_PASS}'
export AUTO_PROXY_ADMIN_PASS='${PROXY_ADMIN_PASS}'
SECRET

# 4. 设置安全权限 (关键步骤)
chmod 600 "$SECRET_FILE"

if [ -f "$SECRET_FILE" ]; then
    echo -e "${GREEN}>>> 成功！凭据已保存至: $SECRET_FILE${NC}"
    echo "文件权限已设置为 600 (仅 root 可读)。"
    echo "现在您可以启动 monitor.sh 进行全自动监控了。"
else
    echo -e "${RED}>>> 错误：文件生成失败。${NC}"
    exit 1
fi
EOF