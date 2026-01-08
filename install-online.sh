#!/bin/bash

# ========================================
# WireGuard Lite 一键安装脚本 v5.6
# 支持在线安装，自动下载最新版本
# ========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置变量
REPO_URL="https://raw.githubusercontent.com/your-username/wireguard-lite/main"
INSTALL_DIR="/tmp/wireguard-lite-install"
BACKUP_DIR="/etc/wireguard/backups"

# 版本信息
VERSION="5.6"
RELEASE_DATE="2024-01-01"

# 日志函数
log() {
    echo -e "${GREEN}[✓]${NC} $1"
}

info() {
    echo -e "${BLUE}[i]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                        ║"
    echo "║              WireGuard Lite 一键安装脚本                ║"
    echo "║                    版本 ${VERSION}                        ║"
    echo "║                                                        ║"
    echo "║         https://github.com/your-username/wireguard-lite ║"
    echo "║                                                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        error "请使用 root 权限运行此脚本"
        echo ""
        echo "请使用以下命令重新运行:"
        echo "  sudo bash $0"
        echo ""
        exit 1
    fi
    log "检查root权限... 通过"
}

# 检查系统
check_system() {
    info "检查系统信息..."
    
    # 检查操作系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        CODENAME=$VERSION_CODENAME
        
        case "$OS" in
            ubuntu)
                if [[ "$VERSION" =~ ^(18|20|22|24) ]]; then
                    log "检测到 Ubuntu $VERSION ($CODENAME)"
                else
                    warn "Ubuntu $VERSION 可能不完全支持"
                fi
                ;;
            debian)
                if [[ "$VERSION" =~ ^(10|11|12) ]]; then
                    log "检测到 Debian $VERSION ($CODENAME)"
                else
                    warn "Debian $VERSION 可能不完全支持"
                fi
                ;;
            centos|rhel)
                if [[ "$VERSION" =~ ^(7|8|9) ]]; then
                    log "检测到 $OS $VERSION"
                else
                    warn "$OS $VERSION 可能不完全支持"
                fi
                ;;
            fedora)
                log "检测到 Fedora $VERSION"
                ;;
            rocky|almalinux)
                log "检测到 $OS $VERSION"
                ;;
            *)
                warn "检测到 $OS $VERSION，可能不完全支持"
                ;;
        esac
    else
        warn "无法检测操作系统类型"
    fi
    
    # 检查架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            log "架构: x86_64"
            ;;
        aarch64|arm64)
            log "架构: ARM64"
            ;;
        *)
            warn "架构 $ARCH 可能不完全支持"
            ;;
    esac
    
    # 检查内存
    MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
    if [ "$MEM_TOTAL" -lt 512 ]; then
        warn "内存较低 (${MEM_TOTAL}MB)，建议至少512MB"
    else
        log "内存: ${MEM_TOTAL}MB"
    fi
    
    # 检查磁盘空间
    DISK_SPACE=$(df -m / | tail -1 | awk '{print $4}')
    if [ "$DISK_SPACE" -lt 1024 ]; then
        warn "磁盘空间较低 (${DISK_SPACE}MB)，建议至少1GB"
    else
        log "磁盘空间: ${DISK_SPACE}MB"
    fi
}

# 检查网络连接
check_network() {
    info "检查网络连接..."
    
    # 尝试多个目标
    local targets=(
        "github.com"
        "raw.githubusercontent.com"
        "google.com"
        "cloudflare.com"
    )
    
    local connected=false
    for target in "${targets[@]}"; do
        if ping -c 1 -W 1 "$target" >/dev/null 2>&1; then
            log "网络连接正常 ($target)"
            connected=true
            break
        fi
    done
    
    if ! $connected; then
        error "网络连接失败，请检查网络设置"
    fi
}

# 安装依赖
install_dependencies() {
    info "安装系统依赖..."
    
    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            
            # 基础依赖
            apt-get install -y -qq curl wget git jq gnupg lsb-release ca-certificates
            
            # 网络工具
            apt-get install -y -qq iproute2 net-tools iputils-ping dnsutils
            
            # WireGuard
            if ! command -v wg >/dev/null 2>&1; then
                log "安装 WireGuard..."
                apt-get install -y -qq wireguard-tools
            fi
            
            # 防火墙工具
            apt-get install -y -qq iptables iptables-persistent nftables
            apt-get install -y -qq conntrack
            apt-get install -y -qq netfilter-persistent
            
            # 其他工具
            apt-get install -y -qq qrencode
            apt-get install -y -qq sysstat htop iftop
            ;;
            
        centos|rhel|rocky|almalinux)
            yum install -y -q epel-release
            
            # 基础依赖
            yum install -y -q curl wget git jq gnupg redhat-lsb-core
            
            # 网络工具
            yum install -y -q iproute net-tools iputils bind-utils
            
            # WireGuard
            if ! command -v wg >/dev/null 2>&1; then
                log "安装 WireGuard..."
                if [ "$VERSION" -ge 8 ]; then
                    yum install -y -q wireguard-tools
                else
                    yum install -y -q kmod-wireguard wireguard-tools
                fi
            fi
            
            # 防火墙工具
            yum install -y -q iptables iptables-services nftables
            yum install -y -q conntrack-tools
            
            # 其他工具
            yum install -y -q qrencode
            yum install -y -q sysstat htop iftop
            ;;
            
        fedora)
            # 基础依赖
            dnf install -y -q curl wget git jq gnupg redhat-lsb-core
            
            # 网络工具
            dnf install -y -q iproute net-tools iputils bind-utils
            
            # WireGuard
            if ! command -v wg >/dev/null 2>&1; then
                log "安装 WireGuard..."
                dnf install -y -q wireguard-tools
            fi
            
            # 防火墙工具
            dnf install -y -q iptables iptables-services nftables
            dnf install -y -q conntrack-tools
            
            # 其他工具
            dnf install -y -q qrencode
            dnf install -y -q sysstat htop iftop
            ;;
    esac
    
    log "系统依赖安装完成"
}

# 下载安装文件
download_files() {
    info "下载 WireGuard Lite 文件..."
    
    # 创建临时目录
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 文件列表
    local files=(
        "wireguard-lite.sh"
        "restore-wg-snat.sh"
        "install.sh"
        "wg-snat-restore.service"
    )
    
    # 模块目录
    local modules=(
        "firewall.sh"
        "ipam.sh"
        "wireguard.sh"
        "validation.sh"
    )
    
    log "从 GitHub 下载文件..."
    
    # 下载主文件
    for file in "${files[@]}"; do
        info "下载 $file..."
        if ! curl -sSL "$REPO_URL/$file" -o "$file"; then
            error "下载 $file 失败"
        fi
    done
    
    # 创建模块目录并下载
    mkdir -p modules
    for module in "${modules[@]}"; do
        info "下载模块 $module..."
        if ! curl -sSL "$REPO_URL/modules/$module" -o "modules/$module"; then
            error "下载模块 $module 失败"
        fi
    done
    
    # 创建配置目录
    mkdir -p config/templates
    
    log "文件下载完成"
}

# 创建备份
create_backup() {
    info "创建系统备份..."
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_DIR/pre_install_$timestamp"
    mkdir -p "$backup_dir"
    
    # 备份现有WireGuard配置
    if [ -d "/etc/wireguard" ]; then
        log "备份现有WireGuard配置..."
        cp -r /etc/wireguard/* "$backup_dir/" 2>/dev/null || true
    fi
    
    # 备份防火墙规则
    log "备份防火墙规则..."
    iptables-save > "$backup_dir/iptables.rules" 2>/dev/null || true
    ip6tables-save > "$backup_dir/ip6tables.rules" 2>/dev/null || true
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset > "$backup_dir/nftables.rules" 2>/dev/null || true
    fi
    
    # 备份系统配置
    log "备份系统配置..."
    sysctl -a 2>/dev/null | grep -E '^(net\.|kernel\.)' > "$backup_dir/sysctl.conf" || true
    
    log "备份完成: $backup_dir"
}

# 安装WireGuard Lite
install_wireguard_lite() {
    info "安装 WireGuard Lite..."
    
    cd "$INSTALL_DIR"
    
    # 运行安装脚本
    chmod +x install.sh
    if ./install.sh; then
        log "WireGuard Lite 安装成功"
    else
        error "安装失败"
    fi
}

# 配置防火墙
configure_firewall() {
    info "配置防火墙..."
    
    # 启用IP转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null 2>&1
    
    # 根据系统配置防火墙
    case "$OS" in
        ubuntu)
            # 允许WireGuard端口
            if command -v ufw >/dev/null 2>&1; then
                ufw allow 51820:52000/udp
                ufw allow 22/tcp
                log "配置UFW防火墙规则"
            fi
            ;;
        centos|rhel|fedora|rocky|almalinux)
            # 允许WireGuard端口
            if command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port=51820-52000/udp
                firewall-cmd --permanent --add-port=22/tcp
                firewall-cmd --reload
                log "配置firewalld规则"
            fi
            ;;
    esac
    
    log "防火墙配置完成"
}

# 启动服务
start_services() {
    info "启动服务..."
    
    # 启动WireGuard恢复服务
    systemctl daemon-reload
    systemctl enable wg-snat-restore.service
    systemctl start wg-snat-restore.service
    
    log "服务启动完成"
}

# 显示完成信息
show_completion() {
    clear
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                        ║"
    echo "║              WireGuard Lite 安装完成！                  ║"
    echo "║                                                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    echo -e "${CYAN}🎉 恭喜！WireGuard Lite 已成功安装${NC}"
    echo ""
    
    echo -e "${YELLOW}📋 安装摘要:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "• 版本: WireGuard Lite v$VERSION"
    echo "• 系统: $OS $VERSION"
    echo "• 架构: $ARCH"
    echo "• 备份: 已创建备份到 $BACKUP_DIR"
    echo "• 服务: wg-snat-restore 已启用"
    echo ""
    
    echo -e "${YELLOW}📁 重要文件位置:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "• 主脚本: /usr/local/bin/wireguard-lite"
    echo "• 配置文件: /etc/wireguard/"
    echo "• 模块文件: /etc/wireguard/modules/"
    echo "• 日志文件: /var/log/wireguard-lite.log"
    echo "• 备份目录: $BACKUP_DIR"
    echo ""
    
    echo -e "${YELLOW}🚀 使用方法:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "1. 启动管理界面:"
    echo "   $ sudo wireguard-lite"
    echo ""
    echo "2. 创建第一个接口:"
    echo "   - 在主菜单中选择 '接口管理'"
    echo "   - 选择 '创建新接口'"
    echo "   - 按照提示配置"
    echo ""
    echo "3. 添加客户端:"
    echo "   - 在主菜单中选择 '客户端管理'"
    echo "   - 选择 '添加路由型客户端'"
    echo ""
    
    echo -e "${YELLOW}🔧 常用命令:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "• 查看服务状态: systemctl status wg-snat-restore"
    echo "• 查看日志: tail -f /var/log/wireguard-lite.log"
    echo "• 更新配置: wireguard-lite"
    echo ""
    
    echo -e "${YELLOW}⚠️  注意事项:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "1. 确保防火墙允许 WireGuard 端口 (51820-52000/udp)"
    echo "2. 云服务器需要在安全组开放相应端口"
    echo "3. 建议定期备份配置"
    echo "4. 查看详细文档请访问项目主页"
    echo ""
    
    echo -e "${GREEN}✅ 安装完成！现在可以开始使用 WireGuard Lite 了${NC}"
    echo ""
    
    # 询问是否启动管理界面
    read -p "是否现在启动 WireGuard Lite 管理界面？(Y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]] || [ -z "$REPLY" ]; then
        echo "启动 WireGuard Lite 管理界面..."
        echo ""
        wireguard-lite
    else
        echo ""
        echo "你可以随时运行以下命令启动管理界面:"
        echo "  $ sudo wireguard-lite"
        echo ""
    fi
}

# 清理安装文件
cleanup() {
    info "清理安装文件..."
    
    # 保留备份，只清理临时文件
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
    
    log "清理完成"
}

# 主安装流程
main() {
    show_banner
    check_root
    check_system
    check_network
    
    echo -e "${YELLOW}开始安装 WireGuard Lite v$VERSION${NC}"
    echo "──────────────────────────────────────────────────────"
    echo ""
    
    # 确认安装
    read -p "是否继续安装？(Y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "安装已取消"
        exit 0
    fi
    
    echo ""
    echo "开始安装过程..."
    echo ""
    
    # 安装步骤
    install_dependencies
    download_files
    create_backup
    install_wireguard_lite
    configure_firewall
    start_services
    cleanup
    
    show_completion
}

# 错误处理
trap 'error "安装过程中断"' INT TERM

# 运行主函数
main "$@"