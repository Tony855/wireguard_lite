#!/bin/bash

# ========================
# WireGuard接口管理模块
# ========================

WG_CONFIG_DIR="/etc/wireguard"
WG_CLIENT_DIR="$WG_CONFIG_DIR/clients"

# ========================
# 创建WireGuard接口
# ========================
create_interface() {
    log "开始创建WireGuard接口"
    
    # 输入验证
    read -p "请输入接口名称（例如wg0, wg1）: " iface
    validate_interface_name "$iface" || return 1
    
    # 检查是否已存在
    if [ -f "$WG_CONFIG_DIR/$iface.conf" ]; then
        echo "错误: 接口 $iface 已存在" >&2
        return 1
    fi
    
    # 获取服务器IP
    read -p "请输入服务器隧道IP（例如10.0.0.1/24）: " server_ip
    validate_ip_address "${server_ip%/*}" || {
        echo "错误: 无效的IP地址格式" >&2
        return 1
    }
    
    # 确保有子网掩码
    [[ "$server_ip" =~ /[0-9]+$ ]] || server_ip="$server_ip/24"
    
    # 生成随机端口
    local port=$(shuf -i 51820-52000 -n 1)
    
    # 生成密钥
    local server_private=$(wg genkey)
    local server_public=$(echo "$server_private" | wg pubkey)
    
    # 创建配置文件
    cat > "$WG_CONFIG_DIR/$iface.conf" <<EOF
# WireGuard 接口配置
# 生成时间: $(date)
# 接口: $iface

[Interface]
Address = $server_ip
PrivateKey = $server_private
ListenPort = $port
SaveConfig = false
MTU = 1420

# 允许转发
PostUp = sysctl -q -w net.ipv4.ip_forward=1
PostUp = sysctl -q -w net.ipv6.conf.all.forwarding=1

# 防火墙规则
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF
    
    chmod 600 "$WG_CONFIG_DIR/$iface.conf"
    
    # 创建客户端目录
    mkdir -p "$WG_CLIENT_DIR/$iface"
    
    # 启动接口
    if start_wireguard_interface "$iface"; then
        echo "接口 $iface 创建成功！"
        echo "服务器公钥: $server_public"
        echo "监听端口: $port"
        echo "隧道网络: $server_ip"
        
        log "接口 $iface 创建成功"
        return 0
    else
        echo "错误: 接口启动失败" >&2
        # 清理配置文件
        rm -f "$WG_CONFIG_DIR/$iface.conf"
        return 1
    fi
}

# ========================
# 启动WireGuard接口
# ========================
start_wireguard_interface() {
    local iface="$1"
    local max_retries=3
    local retry_count=0
    
    log "启动接口 $iface"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "尝试启动接口 $iface (第 $((retry_count+1)) 次)..."
        
        # 方法1: 使用systemd
        if systemctl start "wg-quick@$iface" 2>&1; then
            sleep 2
            
            if systemctl is-active "wg-quick@$iface" >/dev/null 2>&1; then
                log "接口 $iface 启动成功 (systemd)"
                
                # 启用开机启动
                systemctl enable "wg-quick@$iface" >/dev/null 2>&1
                
                # 添加防火墙规则允许端口
                add_firewall_port "$iface"
                
                return 0
            fi
        fi
        
        # 方法2: 直接使用wg-quick
        echo "systemd启动失败，尝试wg-quick..."
        if wg-quick up "$iface" 2>&1; then
            log "接口 $iface 启动成功 (wg-quick)"
            
            # 创建systemd服务
            systemctl enable "wg-quick@$iface" >/dev/null 2>&1
            
            # 添加防火墙规则允许端口
            add_firewall_port "$iface"
            
            return 0
        fi
        
        # 方法3: 使用wg命令手动配置
        echo "wg-quick启动失败，尝试手动配置..."
        if start_interface_manually "$iface"; then
            log "接口 $iface 启动成功 (手动)"
            return 0
        fi
        
        ((retry_count++))
        if [ $retry_count -lt $max_retries ]; then
            echo "启动失败，5秒后重试..."
            sleep 5
        fi
    done
    
    log "接口 $iface 启动失败，所有方法都尝试过了"
    echo "错误: 无法启动接口 $iface" >&2
    return 1
}

# ========================
# 手动启动接口
# ========================
start_interface_manually() {
    local iface="$1"
    local config_file="$WG_CONFIG_DIR/$iface.conf"
    
    [ ! -f "$config_file" ] && return 1
    
    # 解析配置
    local server_ip=$(grep '^Address =' "$config_file" | head -1 | cut -d'=' -f2 | tr -d ' ')
    local private_key=$(grep '^PrivateKey =' "$config_file" | head -1 | cut -d'=' -f2 | tr -d ' ')
    local port=$(grep '^ListenPort =' "$config_file" | head -1 | cut -d'=' -f2 | tr -d ' ')
    
    # 创建接口
    ip link add "$iface" type wireguard 2>/dev/null || return 1
    
    # 配置接口
    wg set "$iface" private-key <(echo "$private_key") listen-port "$port" 2>/dev/null || {
        ip link delete "$iface" 2>/dev/null
        return 1
    }
    
    # 设置IP地址
    ip address add "$server_ip" dev "$iface" 2>/dev/null || {
        ip link delete "$iface" 2>/dev/null
        return 1
    }
    
    # 启用接口
    ip link set "$iface" up 2>/dev/null || {
        ip link delete "$iface" 2>/dev/null
        return 1
    }
    
    return 0
}

# ========================
# 添加防火墙端口规则
# ========================
add_firewall_port() {
    local iface="$1"
    local config_file="$WG_CONFIG_DIR/$iface.conf"
    
    [ ! -f "$config_file" ] && return
    
    local port=$(grep '^ListenPort =' "$config_file" | head -1 | cut -d'=' -f2 | tr -d ' ')
    [ -z "$port" ] && return
    
    # 添加UDP端口规则
    case "$FIREWALL_TYPE" in
        nftables)
            nft add rule ip filter input udp dport "$port" accept 2>/dev/null || true
            ;;
        iptables*)
            firewall_cmd -A INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
            ;;
    esac
    
    log "添加防火墙规则允许端口: $port"
}

# ========================
# 添加路由型客户端
# ========================
add_client() {
    log "开始添加路由型客户端"
    
    # 选择接口
    local iface=$(select_interface)
    [ -z "$iface" ] && return 1
    
    # 输入客户端信息
    read -p "客户端名称（仅限字母数字）: " client_name
    [[ "$client_name" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        echo "错误: 无效的客户端名称" >&2
        return 1
    }
    
    # 检查是否已存在
    local client_file="$WG_CLIENT_DIR/$iface/$client_name.conf"
    if [ -f "$client_file" ]; then
        echo "错误: 客户端 $client_name 已存在" >&2
        return 1
    fi
    
    read -p "请输入客户端子网（例如192.168.1.0/24）: " client_subnet
    validate_subnet "$client_subnet" || return 1
    
    # 生成客户端密钥
    local client_private=$(wg genkey)
    local client_public=$(echo "$client_private" | wg pubkey)
    
    # 获取服务器信息
    local server_public=$(wg show "$iface" public-key 2>/dev/null)
    if [ -z "$server_public" ]; then
        server_public=$(grep '^PrivateKey =' "$WG_CONFIG_DIR/$iface.conf" | cut -d'=' -f2 | tr -d ' ' | wg pubkey)
    fi
    
    local server_port=$(grep '^ListenPort =' "$WG_CONFIG_DIR/$iface.conf" | cut -d'=' -f2 | tr -d ' ')
    local server_tunnel_ip=$(grep '^Address =' "$WG_CONFIG_DIR/$iface.conf" | head -1 | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f1)
    
    # 获取服务器公网IP
    local server_public_ip=$(head -n 1 "$PUBLIC_IP_FILE" 2>/dev/null)
    [ -z "$server_public_ip" ] && server_public_ip="[服务器公网IP]"
    
    # 为客户端分配隧道IP
    local client_tunnel_ip=$(allocate_client_ip "$iface")
    [ -z "$client_tunnel_ip" ] && return 1
    
    # 在服务器配置中添加Peer
    {
        echo ""
        echo "# 客户端: $client_name"
        echo "[Peer]"
        echo "PublicKey = $client_public"
        echo "AllowedIPs = $client_subnet, $client_tunnel_ip/32"
        echo "PersistentKeepalive = 25"
    } >> "$WG_CONFIG_DIR/$iface.conf"
    
    # 创建客户端配置
    cat > "$client_file" <<EOF
# WireGuard 客户端配置
# 客户端: $client_name
# 服务器接口: $iface
# 生成时间: $(date)

[Interface]
PrivateKey = $client_private
Address = $client_tunnel_ip/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $server_public
Endpoint = $server_public_ip:$server_port
# 允许访问服务器隧道网络和互联网
AllowedIPs = ${server_tunnel_ip%.*}.0/24, 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    chmod 600 "$client_file"
    
    # 重新加载服务器配置
    if wg syncconf "$iface" <(wg-quick strip "$iface") 2>/dev/null; then
        echo "客户端添加成功！"
        echo "客户端配置文件: $client_file"
        echo "客户端隧道IP: $client_tunnel_ip"
        echo "客户端子网: $client_subnet"
        
        # 显示二维码
        if command -v qrencode >/dev/null 2>&1; then
            echo "配置二维码:"
            qrencode -t ansiutf8 < "$client_file"
        fi
        
        log "客户端 $client_name 添加成功"
        return 0
    else
        echo "警告: 客户端配置已创建，但服务器重新加载失败" >&2
        log "客户端添加完成但服务器重新加载失败"
        return 1
    fi
}

# ========================
# 分配客户端隧道IP
# ========================
allocate_client_ip() {
    local iface="$1"
    local config_file="$WG_CONFIG_DIR/$iface.conf"
    
    [ ! -f "$config_file" ] && return
    
    # 获取服务器隧道网络
    local server_ip=$(grep '^Address =' "$config_file" | head -1 | cut -d'=' -f2 | tr -d ' ')
    local base_net=$(echo "$server_ip" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
    
    # 获取已使用的IP
    local used_ips=(
        $(echo "$server_ip" | cut -d'/' -f1)
        $(grep 'AllowedIPs' "$config_file" | cut -d'=' -f2 | tr ',' '\n' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '^0\.0\.0\.0$' || true)
    )
    
    # 从.2开始查找可用IP
    for i in {2..254}; do
        local candidate_ip="$base_net.$i"
        
        if ! contains_ip "$candidate_ip" "${used_ips[@]}"; then
            echo "$candidate_ip"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# ========================
# 接口状态查询
# ========================
show_interface_status() {
    local iface=$(select_interface)
    [ -z "$iface" ] && return
    
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│                   接口状态: $iface                           │"
    echo "├─────────────────────────────────────────────────────────┤"
    
    # 基本信息
    echo "│ 基本信息:                                                │"
    echo "│  - 配置文件: $WG_CONFIG_DIR/$iface.conf                 │"
    
    if ip link show "$iface" &>/dev/null; then
        echo "│  - 状态: 运行中                                        │"
        
        # IP地址
        local ip_info=$(ip addr show "$iface" 2>/dev/null | grep 'inet ' | head -1)
        if [ -n "$ip_info" ]; then
            echo "│  - IP地址: $(echo "$ip_info" | awk '{print $2}')            │"
        fi
        
        # MTU
        local mtu=$(ip link show "$iface" 2>/dev/null | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
        echo "│  - MTU: ${mtu:-未知}                                    │"
    else
        echo "│  - 状态: 未运行                                        │"
    fi
    
    # WireGuard信息
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│ WireGuard信息:                                          │"
    
    if command -v wg >/dev/null 2>&1; then
        local wg_info=$(wg show "$iface" 2>/dev/null)
        if [ -n "$wg_info" ]; then
            echo "$wg_info" | while IFS= read -r line; do
                echo "│  $line│"
            done
        else
            echo "│  - 无法获取WireGuard信息                              │"
        fi
    fi
    
    # 对等端数量
    local peer_count=$(grep -c '^\[Peer\]' "$WG_CONFIG_DIR/$iface.conf" 2>/dev/null || echo "0")
    echo "│  - 对等端数量: $peer_count                                  │"
    
    # 客户端数量
    local client_count=$(ls "$WG_CLIENT_DIR/$iface/"*.conf 2>/dev/null | wc -l)
    echo "│  - 客户端数量: $client_count                                │"
    
    # 流量统计
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│ 流量统计:                                              │"
    
    if ip link show "$iface" &>/dev/null; then
        local rx_bytes=$(ip -s link show "$iface" 2>/dev/null | awk 'NR==3{print $1}')
        local tx_bytes=$(ip -s link show "$iface" 2>/dev/null | awk 'NR==5{print $1}')
        
        echo "│  - 接收: $(format_bytes ${rx_bytes:-0})                          │"
        echo "│  - 发送: $(format_bytes ${tx_bytes:-0})                          │"
    fi
    
    echo "└─────────────────────────────────────────────────────────┘"
}

# ========================
# 辅助函数
# ========================
format_bytes() {
    local bytes=$1
    
    if [ $bytes -ge 1099511627776 ]; then
        printf "%.2f TB" $(echo "$bytes / 1099511627776" | bc -l)
    elif [ $bytes -ge 1073741824 ]; then
        printf "%.2f GB" $(echo "$bytes / 1073741824" | bc -l)
    elif [ $bytes -ge 1048576 ]; then
        printf "%.2f MB" $(echo "$bytes / 1048576" | bc -l)
    elif [ $bytes -ge 1024 ]; then
        printf "%.2f KB" $(echo "$bytes / 1024" | bc -l)
    else
        printf "%d B" $bytes
    fi
}