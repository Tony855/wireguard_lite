#!/bin/bash

# ========================
# 防火墙管理模块
# ========================

FIREWALL_TYPE=""
WIREGUARD_CHAIN_PREFIX="WG_"
NFT_TABLE="wireguard"
LAST_SAVE_TIME=0
SAVE_INTERVAL=10  # 秒

# ========================
# 防火墙检测
# ========================
detect_firewall_type() {
    log "正在检测防火墙后端..."
    
    # 优先检测nftables
    if command -v nft >/dev/null 2>&1 && nft list ruleset &>/dev/null; then
        FIREWALL_TYPE="nftables"
        log "检测到 nftables"
        
    # 检测iptables-nft（nftables兼容层）
    elif command -v iptables-nft >/dev/null 2>&1 && iptables-nft -L &>/dev/null; then
        FIREWALL_TYPE="iptables-nft"
        log "检测到 iptables-nft"
        
    # 检测iptables-legacy
    elif command -v iptables-legacy >/dev/null 2>&1 && iptables-legacy -L &>/dev/null; then
        FIREWALL_TYPE="iptables-legacy"
        log "检测到 iptables-legacy"
        
    # 默认使用iptables
    elif command -v iptables >/dev/null 2>&1 && iptables -L &>/dev/null; then
        FIREWALL_TYPE="iptables"
        log "检测到 iptables"
        
    else
        log "错误: 未检测到可用的防火墙后端"
        echo "错误: 未检测到可用的防火墙后端" >&2
        exit 1
    fi
}

# ========================
# 统一的防火墙命令
# ========================
firewall_cmd() {
    local cmd="$1"
    shift
    
    case "$FIREWALL_TYPE" in
        nftables)
            nft "$cmd" "$@"
            ;;
        iptables-nft)
            iptables-nft "$cmd" "$@"
            ;;
        iptables-legacy)
            iptables-legacy "$cmd" "$@"
            ;;
        iptables)
            iptables "$cmd" "$@"
            ;;
        *)
            echo "未知防火墙类型: $FIREWALL_TYPE" >&2
            return 1
            ;;
    esac
}

# ========================
# 创建WireGuard专用链
# ========================
create_wireguard_chains() {
    log "创建WireGuard专用链..."
    
    case "$FIREWALL_TYPE" in
        nftables)
            create_nftables_chains
            ;;
        iptables*)
            create_iptables_chains
            ;;
    esac
}

# ========================
# iptables专用链
# ========================
create_iptables_chains() {
    # SNAT链
    if ! firewall_cmd -t nat -L "${WIREGUARD_CHAIN_PREFIX}POSTROUTING" &>/dev/null; then
        firewall_cmd -t nat -N "${WIREGUARD_CHAIN_PREFIX}POSTROUTING"
        log "创建iptables SNAT专用链"
    fi
    
    # DNAT链
    if ! firewall_cmd -t nat -L "${WIREGUARD_CHAIN_PREFIX}PREROUTING" &>/dev/null; then
        firewall_cmd -t nat -N "${WIREGUARD_CHAIN_PREFIX}PREROUTING"
        log "创建iptables DNAT专用链"
    fi
    
    # 插入到主链
    if ! firewall_cmd -t nat -C POSTROUTING -j "${WIREGUARD_CHAIN_PREFIX}POSTROUTING" &>/dev/null; then
        firewall_cmd -t nat -I POSTROUTING 1 -j "${WIREGUARD_CHAIN_PREFIX}POSTROUTING"
    fi
    
    if ! firewall_cmd -t nat -C PREROUTING -j "${WIREGUARD_CHAIN_PREFIX}PREROUTING" &>/dev/null; then
        firewall_cmd -t nat -I PREROUTING 1 -j "${WIREGUARD_CHAIN_PREFIX}PREROUTING"
    fi
}

# ========================
# nftables专用链
# ========================
create_nftables_chains() {
    # 创建wireguard表
    if ! nft list table ip "$NFT_TABLE" &>/dev/null; then
        nft add table ip "$NFT_TABLE"
        log "创建nftables表: $NFT_TABLE"
    fi
    
    # 创建SNAT链
    if ! nft list chain ip "$NFT_TABLE" postrouting &>/dev/null; then
        nft add chain ip "$NFT_TABLE" postrouting \
            "{ type nat hook postrouting priority 100; policy accept; }"
        log "创建nftables SNAT链"
    fi
    
    # 创建DNAT链
    if ! nft list chain ip "$NFT_TABLE" prerouting &>/dev/null; then
        nft add chain ip "$NFT_TABLE" prerouting \
            "{ type nat hook prerouting priority -100; policy accept; }"
        log "创建nftables DNAT链"
    fi
}

# ========================
# 添加SNAT规则
# ========================
add_snat_rule() {
    local dip="$1"
    local pub="$2"
    local iface="${3:-global}"
    local comment="${4:-WireGuard SNAT}"
    
    validate_ip_address "$dip" || return 1
    validate_ip_address "$pub" || return 1
    
    case "$FIREWALL_TYPE" in
        nftables)
            if ! nft list chain ip "$NFT_TABLE" postrouting | grep -q "$dip.*$pub"; then
                nft add rule ip "$NFT_TABLE" postrouting \
                    ip saddr "$dip" snat to "$pub" comment "\"$comment\""
                log "添加nftables SNAT: $dip -> $pub"
                return 0
            fi
            ;;
        iptables*)
            if ! firewall_cmd -t nat -C "${WIREGUARD_CHAIN_PREFIX}POSTROUTING" \
                -s "$dip" -j SNAT --to-source "$pub" &>/dev/null; then
                firewall_cmd -t nat -A "${WIREGUARD_CHAIN_PREFIX}POSTROUTING" \
                    -s "$dip" -j SNAT --to-source "$pub" \
                    -m comment --comment "$comment"
                log "添加iptables SNAT: $dip -> $pub"
                return 0
            fi
            ;;
    esac
    
    log "SNAT规则已存在: $dip -> $pub"
    return 1
}

# ========================
# 添加DNAT规则（安全的端口限制）
# ========================
add_dnat_rule() {
    local pub="$1"
    local dip="$2"
    local ports="${3:-80,443}"
    local iface="${4:-global}"
    local protocol="${5:-tcp}"
    
    validate_ip_address "$pub" || return 1
    validate_ip_address "$dip" || return 1
    
    local added=false
    IFS=',' read -ra port_array <<< "$ports"
    
    for port in "${port_array[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        
        case "$FIREWALL_TYPE" in
            nftables)
                if ! nft list chain ip "$NFT_TABLE" prerouting | grep -q "$pub.*$dip.*$port"; then
                    nft add rule ip "$NFT_TABLE" prerouting \
                        ip daddr "$pub" $protocol dport "$port" dnat to "$dip:$port" \
                        comment "\"WireGuard DNAT: $pub:$port -> $dip\""
                    added=true
                    log "添加nftables DNAT: $pub:$port -> $dip:$port"
                fi
                ;;
            iptables*)
                if ! firewall_cmd -t nat -C "${WIREGUARD_CHAIN_PREFIX}PREROUTING" \
                    -d "$pub" -p "$protocol" --dport "$port" \
                    -j DNAT --to-destination "$dip:$port" &>/dev/null; then
                    firewall_cmd -t nat -A "${WIREGUARD_CHAIN_PREFIX}PREROUTING" \
                        -d "$pub" -p "$protocol" --dport "$port" \
                        -j DNAT --to-destination "$dip:$port" \
                        -m comment --comment "WireGuard DNAT: $pub:$port -> $dip"
                    added=true
                    log "添加iptables DNAT: $pub:$port -> $dip:$port"
                fi
                ;;
        esac
    done
    
    if $added; then
        delayed_save_rules
        return 0
    fi
    
    log "所有DNAT规则已存在"
    return 1
}

# ========================
# 延迟保存规则（性能优化）
# ========================
delayed_save_rules() {
    local now=$(date +%s)
    
    # 每SAVE_INTERVAL秒保存一次
    if [ $((now - LAST_SAVE_TIME)) -ge $SAVE_INTERVAL ]; then
        save_firewall_rules
        LAST_SAVE_TIME=$now
    fi
}

# ========================
# 保存防火墙规则
# ========================
save_firewall_rules() {
    log "正在保存防火墙规则..."
    
    case "$FIREWALL_TYPE" in
        nftables)
            mkdir -p /etc/nftables
            nft list ruleset > "/etc/nftables/wireguard-rules.nft"
            log "保存nftables规则"
            ;;
        iptables*)
            if command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > "/etc/iptables/rules.v4"
                
                # 同时保存IPv6规则
                if command -v ip6tables-save >/dev/null 2>&1; then
                    ip6tables-save > "/etc/iptables/rules.v6"
                fi
                log "保存iptables规则"
            fi
            ;;
    esac
}

# ========================
# 清理和重载规则（安全的）
# ========================
clean_and_reload_rules() {
    log "开始安全清理和重载规则"
    
    # 备份当前规则
    local backup_file="$BACKUP_DIR/firewall_backup_$(date +%Y%m%d_%H%M%S).rules"
    
    case "$FIREWALL_TYPE" in
        nftables)
            nft list ruleset > "$backup_file"
            ;;
        iptables*)
            iptables-save > "$backup_file" 2>/dev/null || true
            ;;
    esac
    
    echo "当前规则已备份到: $backup_file"
    
    # 只清理WireGuard专用链
    case "$FIREWALL_TYPE" in
        nftables)
            nft flush chain ip "$NFT_TABLE" postrouting 2>/dev/null || true
            nft flush chain ip "$NFT_TABLE" prerouting 2>/dev/null || true
            ;;
        iptables*)
            firewall_cmd -t nat -F "${WIREGUARD_CHAIN_PREFIX}POSTROUTING" 2>/dev/null || true
            firewall_cmd -t nat -F "${WIREGUARD_CHAIN_PREFIX}PREROUTING" 2>/dev/null || true
            ;;
    esac
    
    # 从映射文件重新加载规则
    reload_all_mappings
    
    # 保存规则
    save_firewall_rules
    
    log "规则清理和重载完成"
}

# ========================
# 查看防火墙状态
# ========================
show_firewall_status() {
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│                   防火墙状态                             │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  后端类型: $FIREWALL_TYPE                                │"
    
    case "$FIREWALL_TYPE" in
        nftables)
            echo "│  NFTables规则:                                       │"
            echo "├─────────────────────────────────────────────────────────┤"
            nft list table ip "$NFT_TABLE" 2>/dev/null | head -30
            ;;
        iptables*)
            echo "│  NAT规则统计:                                        │"
            echo "├─────────────────────────────────────────────────────────┤"
            echo "│  SNAT规则:                                            │"
            firewall_cmd -t nat -L "${WIREGUARD_CHAIN_PREFIX}POSTROUTING" -n -v 2>/dev/null | head -20
            echo "│  DNAT规则:                                            │"
            firewall_cmd -t nat -L "${WIREGUARD_CHAIN_PREFIX}PREROUTING" -n -v 2>/dev/null | head -20
            ;;
    esac
    
    echo "└─────────────────────────────────────────────────────────┘"
}

# ========================
# 安全性能测试
# ========================
run_performance_test() {
    echo "正在执行安全性能测试..."
    
    # 使用完全隔离的测试范围
    local test_src_base="172.31.255"
    local test_dst_base="198.51.100"
    local test_ports="8080,8081"
    
    echo "测试范围: ${test_src_base}.0/24 -> ${test_dst_base}.0/24"
    echo "测试端口: $test_ports"
    
    local start_time=$(date +%s%N)
    local added_count=0
    
    # 创建测试专用链
    case "$FIREWALL_TYPE" in
        nftables)
            if ! nft list table ip test_wg &>/dev/null; then
                nft add table ip test_wg
                nft add chain ip test_wg test_chain \
                    "{ type nat hook prerouting priority -150; policy accept; }"
            fi
            ;;
        iptables*)
            if ! firewall_cmd -t nat -L TEST_WG_CHAIN &>/dev/null; then
                firewall_cmd -t nat -N TEST_WG_CHAIN
                firewall_cmd -t nat -I PREROUTING 2 -j TEST_WG_CHAIN
            fi
            ;;
    esac
    
    # 添加测试规则
    for i in {1..100}; do
        local src_ip="${test_src_base}.$i"
        local dst_ip="${test_dst_base}.$i"
        
        case "$FIREWALL_TYPE" in
            nftables)
                nft add rule ip test_wg test_chain \
                    ip saddr "$src_ip" snat to "$dst_ip" comment "\"性能测试\"" 2>/dev/null && \
                    ((added_count++))
                ;;
            iptables*)
                firewall_cmd -t nat -A TEST_WG_CHAIN \
                    -s "$src_ip" -j SNAT --to-source "$dst_ip" \
                    -m comment --comment "性能测试" 2>/dev/null && \
                    ((added_count++))
                ;;
        esac
    done
    
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    echo "性能测试结果:"
    echo "  添加 $added_count 条规则耗时: ${duration}ms"
    if [ $added_count -gt 0 ]; then
        echo "  平均每条规则: $((duration / added_count))ms"
    fi
    
    # 清理测试环境
    echo "清理测试环境..."
    case "$FIREWALL_TYPE" in
        nftables)
            nft delete table ip test_wg 2>/dev/null || true
            ;;
        iptables*)
            firewall_cmd -t nat -D PREROUTING -j TEST_WG_CHAIN 2>/dev/null || true
            firewall_cmd -t nat -F TEST_WG_CHAIN 2>/dev/null || true
            firewall_cmd -t nat -X TEST_WG_CHAIN 2>/dev/null || true
            ;;
    esac
    
    echo "测试完成，生产环境未受影响"
}