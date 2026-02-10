#!/bin/bash
set -e
# 定义版本
BRANCH="dev-v3"
REPO="mariadb-ha-3node"

echo ">>> 正在下载安装包 ($BRANCH)..."
curl -L -k "https://github.com/hotyue/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o ha.tar.gz
tar -xzf ha.tar.gz
# GitHub 压缩包解压后目录名通常带分支名
DIR_NAME="$REPO-$BRANCH"
cd "$DIR_NAME"

echo ">>> 初始化配置向导..."
echo "请输入集群节点的 IP 地址 (公网 IP):"
read -p "Node-1 (Master): " N1
read -p "Node-2 (Slave): " N2
read -p "Node-3 (Slave): " N3

# 生成配置文件
cat <<EOF > topology.env
NODE_1_IP="$N1"
NODE_2_IP="$N2"
NODE_3_IP="$N3"
DB_PORT=3306
PROXY_ADMIN_PORT=6032
PROXY_QUERY_PORT=6033
ADMINER_PORT=8080
MARIADB_IMAGE="mariadb:latest"
PROXYSQL_IMAGE="proxysql/proxysql:latest"
ADMINER_IMAGE="adminer:latest"
REPL_USER="repl_user"
EOF

echo ">>> 配置生成完毕，启动安装程序..."
chmod +x install_node.sh scripts/*.sh
./install_node.sh