#!/bin/bash

# ========================
# WireGuard Lite 主脚本 v5.6
# ========================

# 版本信息
VERSION="5.6-security"
RELEASE_DATE="2024-01-01"
AUTHOR="WireGuard Lite Team"

# 配置参数
CONFIG_DIR="/etc/wireguard"
CLIENT_DIR="$CONFIG_DIR/clients"
BACKUP_DIR="$CONFIG_DIR/backups"
LOG_FILE="/var/log/wireguard-lite.log"
LOCK_FILE="/tmp/wireguard-lite.lock"

# 加载模块
MODULE_DIR="/etc/wireguard/modules"
source "${MODULE_DIR}/validation.sh" 2>/dev/null || {
    echo "错误: 无法加载验证模块" >&2
    exit 1
}
source "${MODULE_DIR}/firewall.sh" 2>/dev/null || {
    echo "错误: 无法加载防火墙模块" >&2
    exit 1
}
source "${MODULE_DIR}/wireguard.sh" 2>/dev/null || {
    echo "错误: 无法加载WireGuard模块" >&2
    exit 1
}
source "${MODULE_DIR}/ipam.sh" 2>/dev/null || {
    echo "错误: 无法加载IP管理模块" >&2
    exit 1
}

# ========================
# 初始化函数
# ========================
init_system() {
    echo "正在初始化系统..."
    
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 需要root权限运行此脚本" >&2
        exit 1
    fi
    
    # 创建必要目录
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR" "$BACKUP_DIR"
    
    # 设置信号处理
    trap cleanup_and_exit INT TERM EXIT
    
    # 检测防火墙类型
    detect_firewall_type
    
    # 创建WireGuard专用链
    create_wireguard_chains
    
    # 检查依赖
    check_dependencies
    
    # 设置日志
    setup_logging
    
    log "系统初始化完成"
    log "版本: $VERSION, 防火墙: $FIREWALL_TYPE"
}

# ========================
# 清理函数
# ========================
cleanup_and_exit() {
    local exit_code=$?
    log "脚本退出，代码: $exit_code"
    
    # 释放文件锁
    release_lock
    
    # 保存防火墙规则
    save_firewall_rules
    
    exit $exit_code
}

# ========================
# 主菜单
# ========================
show_main_menu() {
    clear
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│               WireGuard Lite 管理控制台 v$VERSION            │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  系统信息:                                              │"
    echo "│    - CPU: $(nproc)核心 | 内存: $(free -h | grep Mem | awk '{print $2}')      │"
    echo "│    - 防火墙: $FIREWALL_TYPE                                    │"
    echo "│    - 运行时间: $(uptime -p | sed 's/up //')                        │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  1. 安装依赖                                           │"
    echo "│  2. 接口管理                                           │"
    echo "│  3. 客户端管理                                         │"
    echo "│  4. 下游设备管理                                       │"
    echo "│  5. 防火墙规则管理                                     │"
    echo "│  6. 系统优化                                           │"
    echo "│  7. 监控与诊断                                         │"
    echo "│  8. 备份与恢复                                         │"
    echo "│  9. 安全卸载                                           │"
    echo "│  0. 退出                                               │"
    echo "└─────────────────────────────────────────────────────────┘"
}

# ========================
# 接口管理子菜单
# ========================
interface_menu() {
    while true; do
        clear
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│                   接口管理                              │"
        echo "├─────────────────────────────────────────────────────────┤"
        echo "│  1. 创建新接口                                        │"
        echo "│  2. 查看接口状态                                      │"
        echo "│  3. 重启接口                                          │"
        echo "│  4. 停止接口                                          │"
        echo "│  5. 删除接口                                          │"
        echo "│  6. 列出所有接口                                      │"
        echo "│  7. 返回主菜单                                        │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        read -p "请选择操作 (1-7): " choice
        
        case $choice in
            1) create_interface ;;
            2) show_interface_status ;;
            3) restart_interface ;;
            4) stop_interface ;;
            5) delete_interface ;;
            6) list_interfaces ;;
            7) return ;;
            *) echo "无效选择" ;;
        esac
        
        read -p "按回车键继续..." -r
    done
}

# ========================
# 客户端管理子菜单
# ========================
client_menu() {
    while true; do
        clear
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│                   客户端管理                            │"
        echo "├─────────────────────────────────────────────────────────┤"
        echo "│  1. 添加路由型客户端                                  │"
        echo "│  2. 查看客户端列表                                    │"
        echo "│  3. 删除客户端                                        │"
        echo "│  4. 生成客户端配置二维码                              │"
        echo "│  5. 查看客户端流量统计                                │"
        echo "│  6. 返回主菜单                                        │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        read -p "请选择操作 (1-6): " choice
        
        case $choice in
            1) add_client ;;
            2) list_clients ;;
            3) delete_client ;;
            4) generate_qrcode ;;
            5) show_client_stats ;;
            6) return ;;
            *) echo "无效选择" ;;
        esac
        
        read -p "按回车键继续..." -r
    done
}

# ========================
# 下游设备管理子菜单
# ========================
downstream_menu() {
    while true; do
        clear
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│                 下游设备管理                            │"
        echo "├─────────────────────────────────────────────────────────┤"
        echo "│  1. 添加下游设备（SNAT+DNAT）                         │"
        echo "│  2. 删除下游设备                                      │"
        echo "│  3. 查看当前映射                                      │"
        echo "│  4. 批量添加下游设备                                  │"
        echo "│  5. 清理过期映射                                      │"
        echo "│  6. 返回主菜单                                        │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        read -p "请选择操作 (1-6): " choice
        
        case $choice in
            1) add_downstream ;;
            2) delete_downstream ;;
            3) show_mappings ;;
            4) batch_add_downstream ;;
            5) clean_expired_mappings ;;
            6) return ;;
            *) echo "无效选择" ;;
        esac
        
        read -p "按回车键继续..." -r
    done
}

# ========================
# 防火墙规则管理子菜单
# ========================
firewall_menu() {
    while true; do
        clear
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│                 防火墙规则管理                          │"
        echo "├─────────────────────────────────────────────────────────┤"
        echo "│  1. 查看当前规则                                      │"
        echo "│  2. 清理并重载规则                                    │"
        echo "│  3. 备份防火墙规则                                    │"
        echo "│  4. 恢复防火墙规则                                    │"
        echo "│  5. 查看连接跟踪                                      │"
        echo "│  6. 性能测试                                          │"
        echo "│  7. 返回主菜单                                        │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        read -p "请选择操作 (1-7): " choice
        
        case $choice in
            1) show_firewall_status ;;
            2) clean_and_reload_rules ;;
            3) backup_firewall_rules ;;
            4) restore_firewall_rules ;;
            5) show_conntrack ;;
            6) run_performance_test ;;
            7) return ;;
            *) echo "无效选择" ;;
        esac
        
        read -p "按回车键继续..." -r
    done
}

# ========================
# 主循环
# ========================
main_loop() {
    init_system
    
    while true; do
        show_main_menu
        
        read -p "请选择操作 (0-9): " choice
        
        case $choice in
            1) install_dependencies ;;
            2) interface_menu ;;
            3) client_menu ;;
            4) downstream_menu ;;
            5) firewall_menu ;;
            6) optimize_system ;;
            7) monitoring_menu ;;
            8) backup_menu ;;
            9) uninstall_all ;;
            0) 
                echo "再见！"
                exit 0
                ;;
            *) 
                echo "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# ========================
# 脚本入口
# ========================
if [ "$(basename "$0")" = "wireguard-lite.sh" ]; then
    main_loop
fi
