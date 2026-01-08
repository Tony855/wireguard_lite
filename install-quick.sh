#!/bin/bash

# ========================================
# WireGuard Lite 快速安装脚本
# 最小化版本，适合快速部署
# ========================================

set -e

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# 快速检查
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 sudo 运行此脚本${NC}"
    exit 1
fi

echo -e "${GREEN}开始快速安装 WireGuard Lite...${NC}"
echo ""

# 安装依赖
echo "安装系统依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq wireguard-tools iptables jq curl qrencode
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q epel-release
    yum install -y -q wireguard-tools iptables jq curl qrencode
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q wireguard-tools iptables jq curl qrencode
fi

# 创建目录
echo "创建配置目录..."
mkdir -p /etc/wireguard/{clients,backups,modules}

# 下载最新版本
echo "下载最新版本..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL https://raw.githubusercontent.com/your-username/wireguard-lite/main/wireguard-lite.sh -o /usr/local/bin/wireguard-lite
    curl -sSL https://raw.githubusercontent.com/your-username/wireguard-lite/main/restore-wg-snat.sh -o /usr/local/bin/restore-wg-snat.sh
    curl -sSL https://raw.githubusercontent.com/your-username/wireguard-lite/main/wg-snat-restore.service -o /etc/systemd/system/wg-snat-restore.service
else
    wget -q https://raw.githubusercontent.com/your-username/wireguard-lite/main/wireguard-lite.sh -O /usr/local/bin/wireguard-lite
    wget -q https://raw.githubusercontent.com/your-username/wireguard-lite/main/restore-wg-snat.sh -O /usr/local/bin/restore-wg-snat.sh
    wget -q https://raw.githubusercontent.com/your-username/wireguard-lite/main/wg-snat-restore.service -O /etc/systemd/system/wg-snat-restore.service
fi

# 设置权限
chmod +x /usr/local/bin/wireguard-lite
chmod +x /usr/local/bin/restore-wg-snat.sh

# 配置系统
echo "配置系统..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null 2>&1 || true

# 启动服务
systemctl daemon-reload
systemctl enable wg-snat-restore.service
systemctl start wg-snat-restore.service

# 创建日志文件
touch /var/log/wireguard-lite.log
chmod 644 /var/log/wireguard-lite.log

echo ""
echo -e "${GREEN}✅ WireGuard Lite 快速安装完成！${NC}"
echo ""
echo "使用方法:"
echo "  $ wireguard-lite"
echo ""