#!/bin/bash

# ========================
# WireGuard Lite 安装脚本
# ========================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        error "请使用 root 权限运行此脚本"
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        
        case "$OS" in
            ubuntu|debian)
                log "检测到 $OS $VERSION"
                ;;
            centos|rhel|fedora|rocky|almalinux)
                log "检测到 $OS $VERSION"
                ;;
            *)
                warn "未完全支持的操作系统: $OS"
                read -p "是否继续？(y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
                ;;
        esac
    else
        warn "无法检测操作系统，可能不受支持"
    fi
}

# 安装依赖
install_dependencies() {
    log "正在安装系统依赖..."
    
    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y wireguard-tools iptables nftables \
                iproute2 curl jq qrencode net-tools conntrack \
                iptables-persistent nftables-persistent \
                lsb-release software-properties-common
            ;;
        centos|rhel|rocky|almalinux)
            yum install -y epel-release
            yum install -y wireguard-tools iptables nftables \
                iproute curl jq qrencode net-tools conntrack-tools \
                iptables-services nftables
            ;;
        fedora)
            dnf install -y wireguard-tools iptables nftables \
                iproute curl jq qrencode net-tools conntrack-tools \
                iptables-services nftables
            ;;
    esac
    
    # 检查安装结果
    for cmd in wg wg-quick iptables; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "$cmd 未安装，尝试重新安装..."
            case "$OS" in
                ubuntu|debian) apt-get install -y "$cmd" ;;
                *) yum install -y "$cmd" ;;
            esac
        fi
    done
}

# 配置系统
configure_system() {
    log "配置系统参数..."
    
    # 启用IP转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
    
    # WireGuard优化参数
    cat >> /etc/sysctl.d/99-wireguard.conf <<EOF
# WireGuard 优化
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    
    sysctl -p /etc/sysctl.d/99-wireguard.conf
    
    # 创建配置目录
    mkdir -p /etc/wireguard/{clients,backups,modules}
    
    # 创建日志文件
    touch /var/log/wireguard-lite.log
    chmod 644 /var/log/wireguard-lite.log
}

# 安装脚本文件
install_scripts() {
    log "安装脚本文件..."
    
    # 主脚本
    cp wireguard-lite.sh /usr/local/bin/wireguard-lite
    chmod +x /usr/local/bin/wireguard-lite
    
    # 模块
    cp -r modules/* /etc/wireguard/modules/
    chmod +x /etc/wireguard/modules/*.sh
    
    # 配置文件模板
    cp -r config /etc/wireguard/
    
    # 持久化脚本
    cp restore-wg-snat.sh /usr/local/bin/
    chmod +x /usr/local/bin/restore-wg-snat.sh
    
    # Systemd服务
    cp wg-snat-restore.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable wg-snat-restore.service
}

# 配置定时任务
setup_cron() {
    log "配置定时任务..."
    
    # 清理旧的定时任务
    crontab -l 2>/dev/null | grep -v "wireguard-lite\|restore-wg-snat" | crontab -
    
    # 添加新的定时任务
    (
        echo "# WireGuard Lite 维护任务"
        echo "# 每5分钟检查NAT规则"
        echo "*/5 * * * * /usr/local/bin/restore-wg-snat.sh >/dev/null 2>&1"
        echo "# 每天凌晨3点清理日志"
        echo "0 3 * * * find /var/log -name 'wireguard*.log' -mtime +7 -delete"
        echo "# 每周日凌晨2点备份配置"
        echo "0 2 * * 0 /usr/local/bin/wireguard-lite backup"
    ) | crontab -
}

# 设置防火墙
setup_firewall() {
    log "配置防火墙..."
    
    # 检测防火墙后端
    if command -v nft >/dev/null 2>&1; then
        log "使用 nftables 作为防火墙后端"
    elif command -v iptables >/dev/null 2>&1; then
        log "使用 iptables 作为防火墙后端"
    fi
    
    # 允许WireGuard端口（51820-52000）
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 51820:52000/udp
        ufw allow 22/tcp
        log "配置UFW防火墙规则"
    fi
}

# 显示完成信息
show_completion() {
    clear
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│           WireGuard Lite 安装完成！                      │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  🎉 安装已完成！                                        │"
    echo "│                                                        │"
    echo "│  使用方法:                                              │"
    echo "│    $ sudo wireguard-lite                                │"
    echo "│                                                        │"
    echo "│  重要文件位置:                                          │"
    echo "│    - 主脚本: /usr/local/bin/wireguard-lite              │"
    echo "│    - 配置文件: /etc/wireguard/                          │"
    echo "│    - 日志文件: /var/log/wireguard-lite.log              │"
    echo "│    - 模块文件: /etc/wireguard/modules/                  │"
    echo "│                                                        │"
    echo "│  系统服务:                                              │"
    echo "│    $ systemctl status wg-snat-restore                   │"
    echo "│                                                        │"
    echo "│  首次运行建议:                                          │"
    echo "│    1. 运行 wireguard-lite                               │"
    echo "│    2. 选择 '安装依赖'（如果未自动安装）                  │"
    echo "│    3. 创建第一个WireGuard接口                          │"
    echo "│                                                        │"
    echo "└─────────────────────────────────────────────────────────┘"
    
    echo ""
    read -p "是否现在启动WireGuard Lite管理界面？(Y/n): " start_now
    if [[ "$start_now" =~ ^[Yy]$ ]] || [ -z "$start_now" ]; then
        wireguard-lite
    fi
}

# 主安装流程
main() {
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│           WireGuard Lite 安装程序                        │"
    echo "│                   版本 5.6                              │"
    echo "└─────────────────────────────────────────────────────────┘"
    
    check_root
    detect_os
    
    log "开始安装 WireGuard Lite..."
    
    # 步骤1: 安装依赖
    install_dependencies
    
    # 步骤2: 配置系统
    configure_system
    
    # 步骤3: 安装脚本
    install_scripts
    
    # 步骤4: 配置定时任务
    setup_cron
    
    # 步骤5: 设置防火墙
    setup_firewall
    
    # 步骤6: 显示完成信息
    show_completion
}

# 运行安装
main "$@"