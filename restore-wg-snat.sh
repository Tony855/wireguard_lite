#!/bin/bash

# ========================
# WireGuard NAT规则恢复脚本
# ========================

set -e

CONFIG_DIR="/etc/wireguard"
LOG_FILE="/var/log/wireguard-lite.log"
LOCK_FILE="/tmp/wireguard-restore.lock"

# 加载模块
MODULE_DIR="/etc/wireguard/modules"
source "$MODULE_DIR/firewall.sh" 2>/dev/null || {
    echo "错误: 无法加载防火墙模块" >&2
    exit 1
}

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

# 获取文件锁
acquire_lock() {
    local timeout=30
    local start_time=$(date +%s)
    
    while [ -f "$LOCK_FILE" ]; do
        if [ $(($(date +%s) - start_time)) -ge $timeout ]; then
            log "获取锁超时"
            return 1
        fi
        sleep 1
    done
    
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    return 0
}

# 等待网络就绪
wait_for_network() {
    local timeout=60
    local start_time=$(date +%s)
    
    log "等待网络就绪..."
    
    while [ $(($(date +%s) - start_time)) -lt $timeout ]; do
        # 检查是否有默认路由
        if ip route show default 2>/dev/null | grep -q .; then
            # 检查是否能解析DNS
            if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
                log "网络就绪"
                return 0
            fi
        fi
        sleep 2
    done
    
    log "网络等待超时，继续执行..."
    return 0
}

# 恢复NAT规则
restore_nat_rules() {
    log "开始恢复NAT规则..."
    
    # 检测防火墙类型
    detect_firewall_type
    log "检测到防火墙后端: $FIREWALL_TYPE"
    
    # 创建专用链
    create_wireguard_chains
    
    # 从映射文件恢复规则
    local restored_count=0
    
    for mapping_file in "$CONFIG_DIR"/route_mappings_*.json; do
        [ ! -f "$mapping_file" ] && continue
        
        local iface=$(basename "$mapping_file" | sed 's/route_mappings_//; s/\.json//')
        log "恢复接口 $iface 的规则..."
        
        # 检查JSON文件是否有效
        if ! jq empty "$mapping_file" 2>/dev/null; then
            log "警告: $mapping_file JSON格式无效，跳过"
            continue
        fi
        
        # 读取映射规则
        jq -r 'to_entries[] | "\(.key) \(.value.ip) \(.value.ports // "80,443")"' "$mapping_file" 2>/dev/null | \
        while read -r dip pub ports; do
            if [ -n "$dip" ] && [ -n "$pub" ]; then
                # 恢复SNAT规则
                if add_snat_rule "$dip" "$pub" "$iface"; then
                    log "恢复SNAT: $dip -> $pub"
                    ((restored_count++))
                fi
                
                # 恢复DNAT规则
                if add_dnat_rule "$pub" "$dip" "$ports" "$iface"; then
                    log "恢复DNAT: $pub -> $dip (端口: $ports)"
                    ((restored_count++))
                fi
            fi
        done
    done
    
    log "NAT规则恢复完成，共恢复 $restored_count 条规则"
}

# 启动WireGuard接口
start_wireguard_interfaces() {
    log "启动WireGuard接口..."
    
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ ! -f "$config_file" ] && continue
        
        local iface=$(basename "$config_file" .conf)
        
        # 跳过系统文件
        [[ "$iface" == "wg-snat-restore" ]] && continue
        
        # 检查接口是否已运行
        if ! ip link show "$iface" >/dev/null 2>&1; then
            log "启动接口 $iface..."
            
            # 尝试systemd启动
            if systemctl start "wg-quick@$iface" 2>/dev/null; then
                sleep 2
                if systemctl is-active "wg-quick@$iface" >/dev/null 2>&1; then
                    log "接口 $iface 启动成功 (systemd)"
                else
                    # 尝试wg-quick启动
                    if wg-quick up "$iface" 2>/dev/null; then
                        log "接口 $iface 启动成功 (wg-quick)"
                    else
                        log "警告: 接口 $iface 启动失败"
                    fi
                fi
            fi
        else
            log "接口 $iface 已在运行"
        fi
    done
}

# 清理旧日志
cleanup_old_logs() {
    log "清理旧日志..."
    
    # 保留最近7天的日志
    find /var/log -name "wireguard*.log" -mtime +7 -delete 2>/dev/null || true
    
    # 限制日志文件大小（最大10MB）
    for logfile in /var/log/wireguard*.log; do
        [ -f "$logfile" ] || continue
        local size=$(stat -c%s "$logfile" 2>/dev/null || echo "0")
        if [ "$size" -gt 10485760 ]; then  # 10MB
            tail -c 5242880 "$logfile" > "${logfile}.tmp"  # 保留最后5MB
            mv "${logfile}.tmp" "$logfile"
            log "日志文件 $logfile 已截断"
        fi
    done
}

# 检查系统状态
check_system_status() {
    log "检查系统状态..."
    
    # 检查内核模块
    if ! lsmod | grep -q wireguard; then
        log "加载WireGuard内核模块..."
        modprobe wireguard 2>/dev/null || {
            log "错误: 无法加载WireGuard模块"
            return 1
        }
    fi
    
    # 检查防火墙服务
    case "$FIREWALL_TYPE" in
        nftables)
            if ! systemctl is-active nftables >/dev/null 2>&1; then
                systemctl start nftables 2>/dev/null || true
            fi
            ;;
        iptables*)
            if command -v netfilter-persistent >/dev/null 2>&1; then
                if ! systemctl is-active netfilter-persistent >/dev/null 2>&1; then
                    systemctl start netfilter-persistent 2>/dev/null || true
                fi
            fi
            ;;
    esac
    
    return 0
}

# 主函数
main() {
    log "开始执行WireGuard恢复脚本"
    
    # 获取锁
    acquire_lock || exit 1
    
    # 等待网络就绪
    wait_for_network
    
    # 检查系统状态
    check_system_status || exit 1
    
    # 恢复NAT规则
    restore_nat_rules
    
    # 启动WireGuard接口
    start_wireguard_interfaces
    
    # 保存防火墙规则
    save_firewall_rules
    
    # 清理旧日志
    cleanup_old_logs
    
    log "WireGuard恢复脚本执行完成"
}

# 运行主函数
main "$@"