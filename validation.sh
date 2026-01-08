#!/bin/bash

# ========================
# 输入验证模块
# ========================

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 验证接口名称
validate_interface_name() {
    local iface="$1"
    
    # 检查长度
    if [ -z "$iface" ] || [ ${#iface} -gt 15 ]; then
        echo "错误: 接口名称必须为1-15个字符" >&2
        return 1
    fi
    
    # 检查格式（只允许字母数字和下划线）
    if [[ ! "$iface" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "错误: 接口名称只能包含字母、数字和下划线" >&2
        return 1
    fi
    
    # 检查是否以字母开头
    if [[ ! "$iface" =~ ^[a-zA-Z] ]]; then
        echo "错误: 接口名称必须以字母开头" >&2
        return 1
    fi
    
    # 检查保留名称
    local reserved_names="lo eth[0-9]+ enp[0-9]+s[0-9]+ wlan[0-9]+ vlan[0-9]+ br[0-9]+ docker virbr"
    for reserved in $reserved_names; do
        if [[ "$iface" =~ ^$reserved$ ]]; then
            echo "错误: 接口名称 '$iface' 是保留名称" >&2
            return 1
        fi
    done
    
    return 0
}

# 验证IP地址
validate_ip_address() {
    local ip="$1"
    
    # 基本格式检查
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "错误: IP地址格式无效" >&2
        return 1
    fi
    
    # 检查每个段
    local IFS=.
    local -a octets=($ip)
    
    for octet in "${octets[@]}"; do
        # 检查是否为数字且在范围内
        if [[ ! "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo "错误: IP地址段 '$octet' 无效 (0-255)" >&2
            return 1
        fi
    done
    
    # 检查特殊地址
    local first_octet="${octets[0]}"
    
    # 0.0.0.0/8 (当前网络)
    if [ "$first_octet" -eq 0 ]; then
        echo "错误: IP地址 '$ip' 是保留地址 (0.0.0.0/8)" >&2
        return 1
    fi
    
    # 127.0.0.0/8 (回环地址)
    if [ "$first_octet" -eq 127 ]; then
        echo "错误: IP地址 '$ip' 是回环地址" >&2
        return 1
    fi
    
    # 224.0.0.0/4 (组播地址)
    if [ "$first_octet" -ge 224 ] && [ "$first_octet" -le 239 ]; then
        echo "错误: IP地址 '$ip' 是组播地址" >&2
        return 1
    fi
    
    # 240.0.0.0/4 (保留地址)
    if [ "$first_octet" -ge 240 ]; then
        echo "错误: IP地址 '$ip' 是保留地址" >&2
        return 1
    fi
    
    # 255.255.255.255 (广播地址)
    if [ "$ip" = "255.255.255.255" ]; then
        echo "错误: IP地址 '$ip' 是广播地址" >&2
        return 1
    fi
    
    return 0
}

# 验证子网
validate_subnet() {
    local subnet="$1"
    
    # 检查格式
    if [[ ! "$subnet" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "错误: 子网格式无效 (示例: 192.168.1.0/24)" >&2
        return 1
    fi
    
    # 提取IP和掩码
    local ip=$(echo "$subnet" | cut -d'/' -f1)
    local mask=$(echo "$subnet" | cut -d'/' -f2)
    
    # 验证IP部分
    validate_ip_address "$ip" || return 1
    
    # 验证掩码
    if [[ ! "$mask" =~ ^[0-9]+$ ]] || [ "$mask" -lt 1 ] || [ "$mask" -gt 32 ]; then
        echo "错误: 子网掩码无效 (1-32)" >&2
        return 1
    fi
    
    # 检查是否为网络地址
    if ! is_network_address "$ip" "$mask"; then
        echo "警告: IP '$ip' 可能不是网络地址 (掩码: /$mask)" >&2
        read -p "是否继续？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi
    
    return 0
}

# 验证端口
validate_port() {
    local port="$1"
    
    # 检查是否为数字
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 端口号必须是数字" >&2
        return 1
    fi
    
    # 检查范围
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "错误: 端口号必须在1-65535之间" >&2
        return 1
    fi
    
    # 检查保留端口
    if [ "$port" -le 1024 ]; then
        echo "警告: 端口 $port 是系统保留端口，需要root权限" >&2
    fi
    
    return 0
}

# 验证端口列表
validate_port_list() {
    local port_list="$1"
    
    # 空值检查
    if [ -z "$port_list" ]; then
        echo "错误: 端口列表不能为空" >&2
        return 1
    fi
    
    # 分割端口
    IFS=',' read -ra ports <<< "$port_list"
    
    for port in "${ports[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        
        # 检查范围格式
        if [[ "$port" =~ ^[0-9]+-[0-9]+$ ]]; then
            local start_port=$(echo "$port" | cut -d'-' -f1)
            local end_port=$(echo "$port" | cut -d'-' -f2)
            
            validate_port "$start_port" || return 1
            validate_port "$end_port" || return 1
            
            if [ "$start_port" -gt "$end_port" ]; then
                echo "错误: 端口范围 $port 起始端口大于结束端口" >&2
                return 1
            fi
        else
            validate_port "$port" || return 1
        fi
    done
    
    return 0
}

# 验证CIDR掩码
validate_cidr() {
    local cidr="$1"
    
    if [[ ! "$cidr" =~ ^[0-9]+$ ]] || [ "$cidr" -lt 1 ] || [ "$cidr" -gt 32 ]; then
        echo "错误: CIDR掩码必须在1-32之间" >&2
        return 1
    fi
    
    return 0
}

# 验证MAC地址
validate_mac_address() {
    local mac="$1"
    
    # 标准格式: xx:xx:xx:xx:xx:xx
    if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        return 0
    fi
    
    # 其他格式
    if [[ "$mac" =~ ^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$ ]] || \
       [[ "$mac" =~ ^([0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}$ ]] || \
       [[ "$mac" =~ ^[0-9A-Fa-f]{12}$ ]]; then
        return 0
    fi
    
    echo "错误: MAC地址格式无效" >&2
    return 1
}

# 验证文件名
validate_filename() {
    local filename="$1"
    
    if [ -z "$filename" ]; then
        echo "错误: 文件名不能为空" >&2
        return 1
    fi
    
    # 检查长度
    if [ ${#filename} -gt 255 ]; then
        echo "错误: 文件名过长" >&2
        return 1
    fi
    
    # 检查非法字符
    if [[ "$filename" =~ [/\\:*?\"<>|] ]]; then
        echo "错误: 文件名包含非法字符" >&2
        return 1
    fi
    
    # 检查保留名称
    local reserved_names=". .."
    for reserved in $reserved_names; do
        if [ "$filename" = "$reserved" ]; then
            echo "错误: 文件名 '$filename' 是保留名称" >&2
            return 1
        fi
    done
    
    return 0
}

# 验证JSON文件
validate_json_file() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        echo "错误: JSON文件不存在" >&2
        return 1
    fi
    
    if [ ! -s "$json_file" ]; then
        echo "错误: JSON文件为空" >&2
        return 1
    fi
    
    # 使用jq验证语法
    if ! jq empty "$json_file" 2>/dev/null; then
        echo "错误: JSON文件语法无效" >&2
        return 1
    fi
    
    return 0
}

# 验证整数范围
validate_integer_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local description="${4:-值}"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "错误: $description 必须是整数" >&2
        return 1
    fi
    
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "错误: $description 必须在 $min 到 $max 之间" >&2
        return 1
    fi
    
    return 0
}

# 验证布尔值
validate_boolean() {
    local value="$1"
    local description="${2:-选项}"
    
    case "$value" in
        true|false|yes|no|on|off|1|0)
            return 0
            ;;
        *)
            echo "错误: $description 必须是布尔值 (true/false)" >&2
            return 1
            ;;
    esac
}

# 验证密码强度
validate_password() {
    local password="$1"
    local min_length="${2:-8}"
    
    if [ ${#password} -lt "$min_length" ]; then
        echo "错误: 密码长度至少需要 $min_length 个字符" >&2
        return 1
    fi
    
    # 检查复杂性（可选）
    if [[ ! "$password" =~ [A-Z] ]]; then
        echo "警告: 密码建议包含大写字母" >&2
    fi
    
    if [[ ! "$password" =~ [a-z] ]]; then
        echo "警告: 密码建议包含小写字母" >&2
    fi
    
    if [[ ! "$password" =~ [0-9] ]]; then
        echo "警告: 密码建议包含数字" >&2
    fi
    
    if [[ ! "$password" =~ [^A-Za-z0-9] ]]; then
        echo "警告: 密码建议包含特殊字符" >&2
    fi
    
    return 0
}

# 检查是否为网络地址
is_network_address() {
    local ip="$1"
    local mask="$2"
    
    # 计算网络地址
    local network=$(ipcalc -n "$ip/$mask" 2>/dev/null | grep 'NETWORK=' | cut -d'=' -f2)
    
    if [ "$ip" = "$network" ]; then
        return 0
    else
        return 1
    fi
}

# 检查IP是否在子网内
ip_in_subnet() {
    local ip="$1"
    local subnet="$2"
    
    # 使用ipcalc检查
    if ipcalc -c "$ip" "$subnet" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取IP地址类型
get_ip_type() {
    local ip="$1"
    IFS=. read -r a b c d <<< "$ip"
    
    # A类地址
    if [ $a -le 126 ]; then
        echo "A类公网"
    # B类地址
    elif [ $a -le 191 ]; then
        echo "B类公网"
    # C类地址
    elif [ $a -le 223 ]; then
        echo "C类公网"
    # D类地址（组播）
    elif [ $a -le 239 ]; then
        echo "D类组播"
    # E类地址（保留）
    else
        echo "E类保留"
    fi
}