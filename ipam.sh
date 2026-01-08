#!/bin/bash

# ========================
# IP地址管理模块
# ========================

PUBLIC_IP_FILE="$CONFIG_DIR/public_ips.txt"
USED_IP_FILE="$CONFIG_DIR/used_ips.txt"
IP_LOCK_FILE="/tmp/wireguard_ip.lock"

# ========================
# 公网IP检测
# ========================
detect_public_ips() {
    log "开始公网IP检测"
    
    local public_ips=()
    local detected=false
    
    # 尝试多个外部服务
    local services=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.me/ip"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
    )
    
    for service in "${services[@]}"; do
        local ip=$(curl -s --max-time 3 --retry 1 "$service" 2>/dev/null | tr -d '\n\r')
        
        if validate_ip_address "$ip" && ! is_private_ip "$ip"; then
            if ! contains_ip "$ip" "${public_ips[@]}"; then
                public_ips+=("$ip")
                detected=true
                log "从 $service 检测到公网IP: $ip"
                
                # 获取一个即可，避免太多请求
                [ ${#public_ips[@]} -ge 2 ] && break
            fi
        fi
    done
    
    # 如果外部服务失败，尝试本地检测
    if ! $detected; then
        log "外部服务失败，尝试本地检测"
        
        # 检测物理接口
        while IFS= read -r line; do
            local ip=$(echo "$line" | awk '{print $2}' | cut -d'/' -f1)
            
            if validate_ip_address "$ip" && ! is_private_ip "$ip"; then
                if ! contains_ip "$ip" "${public_ips[@]}"; then
                    public_ips+=("$ip")
                    detected=true
                    log "从本地接口检测到IP: $ip"
                fi
            fi
        done < <(ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.')
    fi
    
    # 云厂商元数据服务
    if ! $detected; then
        log "尝试云厂商元数据"
        
        local metadata_services=(
            "http://169.254.169.254/latest/meta-data/public-ipv4"      # AWS
            "http://169.254.169.254/metadata/v1/public-ipv4"           # DigitalOcean
            "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip"  # GCP
            "http://100.100.100.200/latest/meta-data/eipv4"            # Alibaba Cloud
        )
        
        for service in "${metadata_services[@]}"; do
            local headers=""
            
            # 设置适当的请求头
            if [[ "$service" == *"metadata/v1"* ]]; then
                headers="-H \"Metadata-Flavor: DigitalOcean\""
            elif [[ "$service" == *"computeMetadata"* ]]; then
                headers="-H \"Metadata-Flavor: Google\""
            fi
            
            local ip=$(eval "curl -s --max-time 2 $headers '$service' 2>/dev/null" | tr -d '\n\r')
            
            if validate_ip_address "$ip" && ! is_private_ip "$ip"; then
                if ! contains_ip "$ip" "${public_ips[@]}"; then
                    public_ips+=("$ip")
                    detected=true
                    log "从云厂商元数据检测到IP: $ip"
                    break
                fi
            fi
        done
    fi
    
    if $detected && [ ${#public_ips[@]} -gt 0 ]; then
        # 保存到文件
        printf "%s\n" "${public_ips[@]}" | sort -u > "$PUBLIC_IP_FILE"
        chmod 600 "$PUBLIC_IP_FILE"
        
        echo "检测到公网IP:"
        printf "  %s\n" "${public_ips[@]}"
        log "公网IP检测完成，保存到: $PUBLIC_IP_FILE"
        return 0
    else
        log "公网IP检测失败"
        echo "警告: 无法自动检测公网IP" >&2
        echo "请手动创建 $PUBLIC_IP_FILE 文件" >&2
        return 1
    fi
}

# ========================
# IP地址验证
# ========================
validate_ip_address() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    
    local IFS=.
    local -a ip=($1)
    
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]] || return 1
    
    # 排除特殊地址
    [[ ${ip[0]} -eq 0 ]] && return 1
    [[ ${ip[0]} -eq 127 ]] && return 1
    [[ ${ip[0]} -eq 255 && ${ip[1]} -eq 255 && ${ip[2]} -eq 255 && ${ip[3]} -eq 255 ]] && return 1
    
    return 0
}

# ========================
# 私有IP检测
# ========================
is_private_ip() {
    local ip="$1"
    IFS=. read -r a b c d <<< "$ip"
    
    # RFC 1918 私有地址
    [[ $a -eq 10 ]] && return 0
    [[ $a -eq 172 && $b -ge 16 && $b -le 31 ]] && return 0
    [[ $a -eq 192 && $b -eq 168 ]] && return 0
    
    # 链路本地地址
    [[ $a -eq 169 && $b -eq 254 ]] && return 0
    
    # 测试网络
    [[ $a -eq 192 && $b -eq 0 && $c -eq 2 ]] && return 0
    [[ $a -eq 198 && $b -eq 51 && $c -eq 100 ]] && return 0
    [[ $a -eq 203 && $b -eq 0 && $c -eq 113 ]] && return 0
    
    # 运营商级NAT
    [[ $a -eq 100 && $b -ge 64 && $b -le 127 ]] && return 0
    
    return 1
}

# ========================
# 安全的IP分配
# ========================
allocate_public_ips() {
    local count="$1"
    [ "$count" -le 0 ] && return 1
    
    log "分配 $count 个公网IP"
    
    # 获取文件锁
    acquire_ip_lock || return 1
    
    # 读取公网IP文件
    if [ ! -f "$PUBLIC_IP_FILE" ] || [ ! -s "$PUBLIC_IP_FILE" ]; then
        log "公网IP文件不存在或为空"
        detect_public_ips || {
            release_ip_lock
            return 1
        }
    fi
    
    # 获取保留IP（第一个）
    local first_public_ip=$(head -n 1 "$PUBLIC_IP_FILE" 2>/dev/null || echo "")
    
    # 获取所有可用IP
    local all_ips=()
    mapfile -t all_ips < "$PUBLIC_IP_FILE" 2>/dev/null
    
    # 获取已使用IP
    local used_ips=()
    if [ -f "$USED_IP_FILE" ] && [ -s "$USED_IP_FILE" ]; then
        mapfile -t used_ips < "$USED_IP_FILE" 2>/dev/null
    fi
    
    # 计算可用IP
    local available_ips=()
    for ip in "${all_ips[@]}"; do
        # 跳过保留IP
        [[ -n "$first_public_ip" && "$ip" == "$first_public_ip" ]] && continue
        
        # 检查是否已使用
        if ! contains_ip "$ip" "${used_ips[@]}"; then
            available_ips+=("$ip")
        fi
    done
    
    # 检查可用数量
    if [ ${#available_ips[@]} -lt "$count" ]; then
        log "公网IP不足: 需要 $count, 可用 ${#available_ips[@]}"
        release_ip_lock
        return 1
    fi
    
    # 选择IP（使用确定性算法，避免RANDOM）
    local selected_ips=()
    local total=${#available_ips[@]}
    
    # 使用系统时间作为种子
    local seed=$(date +%s%N)
    local index=0
    
    for ((i=0; i<count; i++)); do
        # 计算下一个索引
        index=$(( (seed + i * 997) % total ))
        
        # 确保不重复
        while contains_ip "${available_ips[$index]}" "${selected_ips[@]}"; do
            index=$(( (index + 1) % total ))
        done
        
        selected_ips+=("${available_ips[$index]}")
        echo "${available_ips[$index]}" >> "$USED_IP_FILE"
    done
    
    # 释放锁
    release_ip_lock
    
    log "分配完成: ${selected_ips[*]}"
    echo "${selected_ips[@]}"
    return 0
}

# ========================
# IP锁管理
# ========================
acquire_ip_lock() {
    local timeout=30
    local start_time=$(date +%s)
    
    while [ -f "$IP_LOCK_FILE" ]; do
        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -ge $timeout ]; then
            log "获取IP锁超时"
            return 1
        fi
        sleep 0.5
    done
    
    echo "$$" > "$IP_LOCK_FILE"
    trap 'release_ip_lock' EXIT
    return 0
}

release_ip_lock() {
    if [ -f "$IP_LOCK_FILE" ] && [ "$(cat "$IP_LOCK_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$IP_LOCK_FILE"
    fi
}

# ========================
# 辅助函数
# ========================
contains_ip() {
    local target="$1"
    shift
    local ips=("$@")
    
    for ip in "${ips[@]}"; do
        [[ "$ip" == "$target" ]] && return 0
    done
    return 1
}

# ========================
# 显示剩余IP
# ========================
show_remaining_public_ips() {
    if [ ! -f "$PUBLIC_IP_FILE" ]; then
        echo "公网IP文件不存在"
        return 1
    fi
    
    local first_ip=$(head -n 1 "$PUBLIC_IP_FILE" 2>/dev/null)
    local total_ips=($(sort -u "$PUBLIC_IP_FILE" 2>/dev/null))
    local used_ips=($(sort -u "$USED_IP_FILE" 2>/dev/null 2>/dev/null))
    
    # 计算可用IP（排除第一个）
    local available_count=0
    for ip in "${total_ips[@]}"; do
        [[ -n "$first_ip" && "$ip" == "$first_ip" ]] && continue
        
        if ! contains_ip "$ip" "${used_ips[@]}"; then
            ((available_count++))
        fi
    done
    
    echo "公网IP统计:"
    echo "  总IP数: ${#total_ips[@]}"
    echo "  已使用: ${#used_ips[@]}"
    echo "  可用数: $available_count"
    
    if [ -n "$first_ip" ]; then
        echo "  保留IP: $first_ip (不分配给下游)"
    fi
    
    if [ $available_count -eq 0 ]; then
        echo "警告: 没有可用的公网IP"
    fi
}