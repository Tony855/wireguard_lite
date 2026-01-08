#!/bin/bash

# ========================================
# WireGuard Lite Docker 安装脚本
# 使用 Docker 容器运行 WireGuard Lite
# ========================================

set -e

CONTAINER_NAME="wireguard-lite"
IMAGE_NAME="wireguard-lite:latest"
HOST_CONFIG_DIR="/etc/wireguard"
HOST_LOG_DIR="/var/log/wireguard"

# 检查 Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "错误: Docker 未安装"
    echo "请先安装 Docker:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# 检查是否已运行
if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo "容器 ${CONTAINER_NAME} 已存在"
    read -p "是否重新创建？(y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    else
        echo "使用现有容器"
        docker start "$CONTAINER_NAME"
        exit 0
    fi
fi

# 创建主机目录
mkdir -p "$HOST_CONFIG_DIR" "$HOST_LOG_DIR"

# 检查镜像
if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
    echo "构建 Docker 镜像..."
    cat > Dockerfile << 'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wireguard-tools \
    iptables \
    nftables \
    iproute2 \
    curl \
    jq \
    qrencode \
    net-tools \
    conntrack \
    && rm -rf /var/lib/apt/lists/*

COPY wireguard-lite.sh /usr/local/bin/wireguard-lite
COPY restore-wg-snat.sh /usr/local/bin/restore-wg-snat.sh
COPY modules /etc/wireguard/modules

RUN chmod +x /usr/local/bin/wireguard-lite \
    /usr/local/bin/restore-wg-snat.sh \
    /etc/wireguard/modules/*.sh

# 启用内核模块
RUN modprobe wireguard || true

VOLUME ["/etc/wireguard", "/var/log/wireguard"]

ENTRYPOINT ["wireguard-lite"]
EOF
    
    docker build -t "$IMAGE_NAME" .
fi

# 运行容器
echo "启动 WireGuard Lite 容器..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart=unless-stopped \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_MODULE \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    -p 51820-52000:51820-52000/udp \
    -v "$HOST_CONFIG_DIR:/etc/wireguard" \
    -v "$HOST_LOG_DIR:/var/log/wireguard" \
    --privileged \
    "$IMAGE_NAME"

echo ""
echo "✅ WireGuard Lite Docker 容器已启动"
echo ""
echo "容器名称: $CONTAINER_NAME"
echo "配置目录: $HOST_CONFIG_DIR"
echo "日志目录: $HOST_LOG_DIR"
echo ""
echo "进入容器: docker exec -it $CONTAINER_NAME /bin/bash"
echo "查看日志: docker logs $CONTAINER_NAME"
echo "停止容器: docker stop $CONTAINER_NAME"
echo "启动容器: docker start $CONTAINER_NAME"