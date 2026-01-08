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
REPO_URL="https://raw.githubusercontent.com/Tony855/wireguard_lite/main"
INSTALL_DIR="/tmp/wireguard-lite-install"
BACKUP_DIR="/etc/wireguard/backups"

# 版本信息
VERSION="5.6"
RELEASE_DATE="2026-01-10"

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
    echo "║                                                          ║"
    echo "║              WireGuard Lite 一键安装脚本                 ║"
    echo "║                    版本 ${VERSION}                       ║"
    echo "║                                                          ║"
    echo "║ https://raw.githubusercontent.com/Tony855/wireguard_lite ║"
    echo "║                                                          ║"
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
        VERSION_ID=$VERSION_ID
        CODENAME=$VERSION_CODENAME
        
        case "$OS" in
            ubuntu)
                if [[ "$VERSION_ID" =~ ^(18|20|22|24) ]]; then
                    log "检测到 Ubuntu $VERSION_ID ($CODENAME)"
                else
                    warn "Ubuntu $VERSION_ID 可能不完全支持"
                fi
                ;;
            debian)
                if [[ "$VERSION_ID" =~ ^(10|11|12) ]]; then
                    log "检测到 Debian $VERSION_ID ($CODENAME)"
                else
                    warn "Debian $VERSION_ID 可能不完全支持"
                fi
                ;;
            centos|rhel)
                if [[ "$VERSION_ID" =~ ^(7|8|9) ]]; then
                    log "检测到 $OS $VERSION_ID"
                else
                    warn "$OS $VERSION_ID 可能不完全支持"
                fi
                ;;
            fedora)
                log "检测到 Fedora $VERSION_ID"
                ;;
            rocky|almalinux)
                log "检测到 $OS $VERSION_ID"
                ;;
            *)
                warn "检测到 $OS $VERSION_ID，可能不完全支持"
                ;;
        esac
    else
        warn "无法检测操作系统类型"
        # 默认使用debian系
        OS="ubuntu"
        VERSION_ID="22.04"
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
    if command -v free >/dev/null 2>&1; then
        MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
        if [ "$MEM_TOTAL" -lt 512 ]; then
            warn "内存较低 (${MEM_TOTAL}MB)，建议至少512MB"
        else
            log "内存: ${MEM_TOTAL}MB"
        fi
    fi
    
    # 检查磁盘空间
    if command -v df >/dev/null 2>&1; then
        DISK_SPACE=$(df -m / | tail -1 | awk '{print $4}')
        if [ "$DISK_SPACE" -lt 1024 ]; then
            warn "磁盘空间较低 (${DISK_SPACE}MB)，建议至少1GB"
        else
            log "磁盘空间: ${DISK_SPACE}MB"
        fi
    fi
}

# 智能网络检查
check_network() {
    info "检查网络连接..."
    
    # 方法1: 尝试直接访问GitHub（使用curl，不依赖ping）
    if command -v curl >/dev/null 2>&1; then
        info "使用curl检查GitHub连接..."
        if curl -s --max-time 5 "$REPO_URL/README.md" >/dev/null 2>&1; then
            log "GitHub连接正常"
            return 0
        fi
    fi
    
    # 方法2: 尝试使用wget
    if command -v wget >/dev/null 2>&1; then
        info "使用wget检查GitHub连接..."
        if wget --timeout=5 --tries=1 -q "$REPO_URL/README.md" -O /dev/null 2>&1; then
            log "GitHub连接正常"
            return 0
        fi
    fi
    
    # 方法3: 检查本地网络接口
    info "检查本地网络..."
    if ip route show default 2>/dev/null | grep -q .; then
        log "检测到默认路由，网络可能正常"
        warn "无法直接访问GitHub，将尝试继续安装..."
        return 0
    fi
    
    error "网络连接失败，请检查网络设置后重试"
}

# 安装依赖
install_dependencies() {
    info "安装系统依赖..."
    
    # 根据操作系统安装依赖
    case "$OS" in
        ubuntu|debian)
            info "更新包列表..."
            apt-get update -qq
            
            # 基础依赖
            info "安装基础工具..."
            apt-get install -y -qq curl wget jq gnupg lsb-release ca-certificates
            
            # 网络工具
            info "安装网络工具..."
            apt-get install -y -qq iproute2 net-tools iputils-ping dnsutils
            
            # WireGuard
            if ! command -v wg >/dev/null 2>&1; then
                info "安装 WireGuard..."
                apt-get install -y -qq wireguard-tools
            fi
            
            # 防火墙工具
            info "安装防火墙工具..."
            apt-get install -y -qq iptables iptables-persistent
            
            # 其他工具
            info "安装其他工具..."
            apt-get install -y -qq qrencode
            apt-get install -y -qq netfilter-persistent 2>/dev/null || true
            
            # 尝试安装nftables（可选）
            apt-get install -y -qq nftables 2>/dev/null || true
            ;;
            
        centos|rhel|rocky|almalinux)
            info "安装EPEL仓库..."
            yum install -y -q epel-release 2>/dev/null || true
            
            # 基础依赖
            info "安装基础工具..."
            yum install -y -q curl wget jq redhat-lsb-core
            
            # 网络工具
            info "安装网络工具..."
            yum install -y -q iproute net-tools iputils bind-utils
            
            # WireGuard
            if ! command -v wg >/dev/null 2>&1; then
                info "安装 WireGuard..."
                if [ "$VERSION_ID" -ge 8 ]; then
                    yum install -y -q wireguard-tools
                else
                    yum install -y -q kmod-wireguard wireguard-tools
                fi
            fi
            
            # 防火墙工具
            info "安装防火墙工具..."
            yum install -y -q iptables iptables-services
            
            # 其他工具
            info "安装其他工具..."
            yum install -y -q qrencode
            yum install -y -q nftables 2>/dev/null || true
            ;;
            
        fedora)
            # 基础依赖
            info "安装基础工具..."
            dnf install -y -q curl wget jq redhat-lsb-core
            
            # 网络工具
            info "安装网络工具..."
            dnf install -y -q iproute net-tools iputils bind-utils
            
            # WireGuard
            if ! command -v wg >/dev/null 2>&1; then
                info "安装 WireGuard..."
                dnf install -y -q wireguard-tools
            fi
            
            # 防火墙工具
            info "安装防火墙工具..."
            dnf install -y -q iptables iptables-services
            
            # 其他工具
            info "安装其他工具..."
            dnf install -y -q qrencode
            dnf install -y -q nftables 2>/dev/null || true
            ;;
    esac
    
    # 验证核心依赖
    info "验证安装结果..."
    local missing_deps=()
    for dep in wg wg-quick iptables; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        warn "以下核心依赖未安装: ${missing_deps[*]}"
        warn "将尝试继续安装，但某些功能可能受限"
    else
        log "系统依赖安装完成"
    fi
}

# 下载安装文件（改进版，带重试）
download_files() {
    info "下载 WireGuard Lite 文件..."
    
    # 创建临时目录
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 文件列表（按依赖顺序）
    local files=(
        "wireguard-lite.sh"
        "restore-wg-snat.sh"
        "wg-snat-restore.service"
    )
    
    # 模块目录
    local modules=(
        "firewall.sh"
        "ipam.sh"
        "wireguard.sh"
        "validation.sh"
    )
    
    # 下载函数（带重试）
    download_with_retry() {
        local url="$1"
        local output="$2"
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            info "下载 $output (尝试 $((retry_count+1))/$max_retries)..."
            
            # 尝试curl
            if command -v curl >/dev/null 2>&1; then
                if curl -sSL --connect-timeout 10 --retry 2 "$url" -o "$output"; then
                    return 0
                fi
            fi
            
            # 尝试wget
            if command -v wget >/dev/null 2>&1; then
                if wget --timeout=10 --tries=2 -q "$url" -O "$output"; then
                    return 0
                fi
            fi
            
            ((retry_count++))
            if [ $retry_count -lt $max_retries ]; then
                warn "下载失败，5秒后重试..."
                sleep 5
            fi
        done
        
        return 1
    }
    
    # 下载主文件
    for file in "${files[@]}"; do
        if ! download_with_retry "$REPO_URL/$file" "$file"; then
            warn "下载 $file 失败，尝试使用备用方法..."
            
            # 创建基础版本
            case "$file" in
                "wireguard-lite.sh")
                    create_basic_main_script
                    ;;
                "restore-wg-snat.sh")
                    create_basic_restore_script
                    ;;
                "wg-snat-restore.service")
                    create_basic_service_file
                    ;;
            esac
        fi
    done
    
    # 创建模块目录并下载
    mkdir -p modules
    for module in "${modules[@]}"; do
        if ! download_with_retry "$REPO_URL/modules/$module" "modules/$module"; then
            warn "下载模块 $module 失败，将使用简化版本"
            create_basic_module "$module"
        fi
    done
    
    # 设置权限
    chmod +x wireguard-lite.sh restore-wg-snat.sh
    chmod +x modules/*.sh 2>/dev/null || true
    
    log "文件下载完成"
}

# 创建基础主脚本（如果下载失败）
create_basic_main_script() {
    cat > wireguard-lite.sh << 'EOF'
#!/bin/bash
echo "WireGuard Lite 简化版"
echo "在线下载失败，请检查网络连接后重试"
echo "或从 GitHub 手动下载完整版本:"
echo "https://raw.githubusercontent.com/Tony855/wireguard_lite/main"
exit 1
EOF
}

# 创建基础恢复脚本
create_basic_restore_script() {
    cat > restore-wg-snat.sh << 'EOF'
#!/bin/bash
# 基础恢复脚本
echo "基础恢复脚本"
echo "请下载完整版本以获得完整功能"
EOF
}

# 创建基础服务文件
create_basic_service_file() {
    cat > wg-snat-restore.service << 'EOF'
[Unit]
Description=WireGuard SNAT Restore Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/echo "服务文件未完整下载"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

# 创建基础模块
create_basic_module() {
    local module="$1"
    cat > "modules/$module" << EOF
#!/bin/bash
# 基础模块: $module
echo "模块 $module 未完整下载"
EOF
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
        info "备份现有WireGuard配置..."
        cp -r /etc/wireguard/* "$backup_dir/" 2>/dev/null || true
    fi
    
    # 备份防火墙规则
    info "备份防火墙规则..."
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$backup_dir/iptables.rules" 2>/dev/null || true
    fi
    
    # 备份系统配置
    info "备份系统配置..."
    sysctl -a 2>/dev/null | grep -E '^(net\.|kernel\.)' > "$backup_dir/sysctl.conf" 2>/dev/null || true
    
    log "备份完成: $backup_dir"
}

# 安装WireGuard Lite
install_wireguard_lite() {
    info "安装 WireGuard Lite..."
    
    cd "$INSTALL_DIR"
    
    # 检查是否有可安装的文件
    if [ ! -f "wireguard-lite.sh" ]; then
        error "未找到安装文件，请检查网络连接"
    fi
    
    # 安装主脚本
    info "安装主脚本..."
    cp wireguard-lite.sh /usr/local/bin/wireguard-lite
    chmod +x /usr/local/bin/wireguard-lite
    
    # 安装恢复脚本
    if [ -f "restore-wg-snat.sh" ]; then
        info "安装恢复脚本..."
        cp restore-wg-snat.sh /usr/local/bin/
        chmod +x /usr/local/bin/restore-wg-snat.sh
    fi
    
    # 安装服务文件
    if [ -f "wg-snat-restore.service" ]; then
        info "安装服务文件..."
        cp wg-snat-restore.service /etc/systemd/system/
    fi
    
    # 安装模块
    if [ -d "modules" ]; then
        info "安装功能模块..."
        mkdir -p /etc/wireguard/modules
        cp modules/*.sh /etc/wireguard/modules/ 2>/dev/null || true
        chmod +x /etc/wireguard/modules/*.sh 2>/dev/null || true
    fi
    
    # 创建配置目录
    info "创建配置目录..."
    mkdir -p /etc/wireguard/{clients,backups}
    
    # 创建日志文件
    info "创建日志文件..."
    touch /var/log/wireguard-lite.log
    chmod 644 /var/log/wireguard-lite.log
    
    log "WireGuard Lite 安装成功"
}

# 配置防火墙
configure_firewall() {
    info "配置防火墙..."
    
    # 启用IP转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
    
    # 应用配置
    if sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null 2>&1; then
        log "IP转发已启用"
    else
        warn "无法应用sysctl配置，但将继续安装"
    fi
    
    # 根据系统配置防火墙
    case "$OS" in
        ubuntu|debian)
            # 允许WireGuard端口
            if command -v ufw >/dev/null 2>&1; then
                info "配置UFW防火墙..."
                ufw allow 51820:52000/udp 2>/dev/null || true
                ufw allow 22/tcp 2>/dev/null || true
                log "UFW防火墙规则已添加"
            fi
            ;;
        centos|rhel|fedora|rocky|almalinux)
            # 允许WireGuard端口
            if command -v firewall-cmd >/dev/null 2>&1; then
                info "配置firewalld..."
                firewall-cmd --permanent --add-port=51820-52000/udp 2>/dev/null || true
                firewall-cmd --permanent --add-port=22/tcp 2>/dev/null || true
                firewall-cmd --reload 2>/dev/null || true
                log "firewalld规则已添加"
            fi
            ;;
    esac
    
    # 添加iptables规则（通用）
    info "添加iptables规则..."
    if command -v iptables >/dev/null 2>&1; then
        # 允许WireGuard端口
        iptables -A INPUT -p udp --dport 51820:52000 -j ACCEPT 2>/dev/null || true
        # 允许已建立的连接
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        log "iptables规则已添加"
    fi
    
    log "防火墙配置完成"
}

# 启动服务
start_services() {
    info "启动服务..."
    
    # 配置systemd服务
    if [ -f "/etc/systemd/system/wg-snat-restore.service" ]; then
        info "配置systemd服务..."
        systemctl daemon-reload
        systemctl enable wg-snat-restore.service 2>/dev/null || true
        systemctl start wg-snat-restore.service 2>/dev/null || true
        log "系统服务已配置"
    fi
    
    # 添加定时任务（可选）
    info "配置定时任务..."
    if command -v crontab >/dev/null 2>&1; then
        # 清理旧任务
        crontab -l 2>/dev/null | grep -v "restore-wg-snat.sh" | crontab - 2>/dev/null || true
        
        # 添加新任务
        (crontab -l 2>/dev/null; echo "@reboot sleep 30 && /usr/local/bin/restore-wg-snat.sh >/dev/null 2>&1") | crontab - 2>/dev/null || true
        log "定时任务已配置"
    fi
    
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
    echo "• 系统: $OS $VERSION_ID"
    echo "• 架构: $ARCH"
    echo "• 备份: 已创建备份到 $BACKUP_DIR"
    echo "• 服务: wg-snat-restore 已启用"
    echo ""
    
    echo -e "${YELLOW}📁 重要文件位置:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "• 主脚本: /usr/local/bin/wireguard-lite"
    echo "• 配置文件: /etc/wireguard/"
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
        if command -v wireguard-lite >/dev/null 2>&1; then
            wireguard-lite
        else
            echo "无法找到 wireguard-lite 命令，请尝试重新安装"
        fi
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
        log "临时文件已清理"
    fi
}

# 主安装流程
main() {
    show_banner
    check_root
    check_system
    
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
    
    # 执行安装步骤
    install_dependencies
    check_network
    download_files
    create_backup
    install_wireguard_lite
    configure_firewall
    start_services
    cleanup
    
    show_completion
}

# 错误处理
trap 'echo -e "\n${RED}[✗] 安装过程中断${NC}"; exit 1' INT TERM

# 运行主函数
main "$@"
