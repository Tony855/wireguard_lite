#!/bin/bash

# ========================================
# WireGuard Lite 离线一键安装脚本 v5.6
# 用于没有网络连接的环境
# ========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 安装目录
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="/etc/wireguard/backups"

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                        ║"
    echo "║            WireGuard Lite 离线安装脚本                  ║"
    echo "║                    版本 5.6                            ║"
    echo "║                                                        ║"
    echo "║         注意：此脚本用于离线环境安装                    ║"
    echo "║                                                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# 检查文件完整性
check_files() {
    echo -e "${BLUE}[i] 检查安装文件...${NC}"
    
    local required_files=(
        "wireguard-lite.sh"
        "install.sh"
        "restore-wg-snat.sh"
        "wg-snat-restore.service"
        "modules/firewall.sh"
        "modules/ipam.sh"
        "modules/wireguard.sh"
        "modules/validation.sh"
    )
    
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$INSTALL_DIR/$file" ]; then
            missing_files+=("$file")
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        echo -e "${RED}[✗] 以下文件缺失:${NC}"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        echo ""
        echo "请确保所有文件都在当前目录中:"
        echo "  $INSTALL_DIR"
        exit 1
    fi
    
    echo -e "${GREEN}[✓] 所有必需文件都存在${NC}"
}

# 离线安装依赖
install_dependencies_offline() {
    echo -e "${BLUE}[i] 检查系统依赖...${NC}"
    
    # 检查是否已安装必要工具
    local missing_deps=()
    
    if ! command -v wg >/dev/null 2>&1; then
        missing_deps+=("wireguard-tools")
    fi
    
    if ! command -v iptables >/dev/null 2>&1; then
        missing_deps+=("iptables")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}[!] 以下依赖未安装:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "在离线环境中，请手动安装这些依赖:"
        echo ""
        
        if [ -f /etc/debian_version ]; then
            echo "Debian/Ubuntu:"
            echo "  apt-get update"
            echo "  apt-get install wireguard-tools iptables jq curl"
        elif [ -f /etc/redhat-release ]; then
            echo "RHEL/CentOS/Fedora:"
            echo "  yum install epel-release"
            echo "  yum install wireguard-tools iptables jq curl"
        fi
        
        echo ""
        read -p "请手动安装上述依赖，然后按回车键继续安装..." -r
        echo ""
    else
        echo -e "${GREEN}[✓] 所有依赖都已安装${NC}"
    fi
}

# 安装WireGuard Lite
install_wireguard_lite_offline() {
    echo -e "${BLUE}[i] 安装 WireGuard Lite...${NC}"
    
    # 创建配置目录
    mkdir -p /etc/wireguard/{clients,backups,modules}
    
    # 复制主脚本
    cp "$INSTALL_DIR/wireguard-lite.sh" /usr/local/bin/wireguard-lite
    chmod +x /usr/local/bin/wireguard-lite
    
    # 复制模块
    cp "$INSTALL_DIR/modules"/*.sh /etc/wireguard/modules/
    chmod +x /etc/wireguard/modules/*.sh
    
    # 复制恢复脚本
    cp "$INSTALL_DIR/restore-wg-snat.sh" /usr/local/bin/
    chmod +x /usr/local/bin/restore-wg-snat.sh
    
    # 复制服务文件
    cp "$INSTALL_DIR/wg-snat-restore.service" /etc/systemd/system/
    
    # 创建日志文件
    touch /var/log/wireguard-lite.log
    chmod 644 /var/log/wireguard-lite.log
    
    echo -e "${GREEN}[✓] 文件复制完成${NC}"
}

# 配置系统
configure_system_offline() {
    echo -e "${BLUE}[i] 配置系统...${NC}"
    
    # 启用IP转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null 2>&1 || true
    
    # 配置systemd服务
    systemctl daemon-reload
    systemctl enable wg-snat-restore.service
    
    echo -e "${GREEN}[✓] 系统配置完成${NC}"
}

# 创建示例配置
create_example_config() {
    echo -e "${BLUE}[i] 创建示例配置...${NC}"
    
    # 创建示例公网IP文件
    cat > /etc/wireguard/public_ips.txt << 'EOF'
# 公网IP列表
# 每行一个IP地址
# 第一个IP将被保留，不分配给下游设备

203.0.113.1
203.0.113.2
203.0.113.3
EOF
    
    # 创建示例配置文件
    cat > /etc/wireguard/README.md << 'EOF'
# WireGuard Lite 配置文件说明

## 目录结构
- /etc/wireguard/                # 主配置目录
  ├── clients/                   # 客户端配置文件
  ├── backups/                   # 备份文件
  ├── modules/                   # 功能模块
  ├── public_ips.txt            # 公网IP列表
  ├── used_ips.txt              # 已使用的IP（自动生成）
  └── *.conf                    # WireGuard接口配置文件

## 使用步骤

1. 编辑公网IP文件
   - 修改 /etc/wireguard/public_ips.txt
   - 添加你的公网IP地址

2. 创建第一个接口
   $ wireguard-lite
   → 选择 "接口管理"
   → 选择 "创建新接口"

3. 添加客户端
   → 选择 "客户端管理"
   → 选择 "添加路由型客户端"

4. 添加下游设备
   → 选择 "下游设备管理"
   → 选择 "添加下游设备"

## 注意事项
- 确保防火墙允许 WireGuard 端口 (51820-52000/udp)
- 云服务器需要在安全组开放相应端口
- 定期备份重要配置
EOF
    
    echo -e "${GREEN}[✓] 示例配置创建完成${NC}"
}

# 显示完成信息
show_completion_offline() {
    clear
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                        ║"
    echo "║           WireGuard Lite 离线安装完成！                 ║"
    echo "║                                                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    echo -e "${CYAN}✅ 安装完成！${NC}"
    echo ""
    
    echo -e "${YELLOW}📋 安装摘要:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "• 主脚本: /usr/local/bin/wireguard-lite"
    echo "• 配置目录: /etc/wireguard/"
    echo "• 日志文件: /var/log/wireguard-lite.log"
    echo "• 服务: wg-snat-restore.service"
    echo ""
    
    echo -e "${YELLOW}🚀 下一步:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "1. 编辑公网IP文件:"
    echo "   $ nano /etc/wireguard/public_ips.txt"
    echo ""
    echo "2. 启动管理界面:"
    echo "   $ wireguard-lite"
    echo ""
    echo "3. 按照向导创建接口和客户端"
    echo ""
    
    echo -e "${YELLOW}🔧 重要提示:${NC}"
    echo "──────────────────────────────────────────────────────"
    echo "1. 确保你有可用的公网IP地址"
    echo "2. 确保防火墙允许 WireGuard 端口"
    echo "3. 首次使用建议查看 README.md"
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
        echo "  $ wireguard-lite"
        echo ""
    fi
}

# 主函数
main() {
    show_banner
    
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[✗] 请使用 root 权限运行此脚本${NC}"
        echo ""
        echo "请使用以下命令重新运行:"
        echo "  sudo bash $0"
        echo ""
        exit 1
    fi
    
    echo -e "${YELLOW}开始 WireGuard Lite 离线安装${NC}"
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
    
    # 执行安装步骤
    check_files
    install_dependencies_offline
    install_wireguard_lite_offline
    configure_system_offline
    create_example_config
    
    show_completion_offline
}

# 运行主函数
main "$@"