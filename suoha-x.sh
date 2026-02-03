#!/usr/bin/env bash
set -uo pipefail

# =========================
# Suoha X-Tunnel [SPEED EDITION]
# 核心优化: BBR + QUIC协议 + Sysctl调优
# =========================

# --- 全局配置 ---
CONFIG_FILE="${HOME}/.suoha_tunnel_config"
BIN_DIR="${HOME}/.suoha_bin"
mkdir -p "$BIN_DIR"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 基础函数 ---
log() {
    case $1 in
        "info") echo -e "${BLUE}[INFO]${PLAIN} $2" ;;
        "success") echo -e "${GREEN}[OK]${PLAIN} $2" ;;
        "warn") echo -e "${YELLOW}[WARN]${PLAIN} $2" ;;
        "error") echo -e "${RED}[ERROR]${PLAIN} $2" ;;
        *) echo "$1" ;;
    esac
}

check_root() {
    [[ $EUID -ne 0 ]] && log error "请使用 root 用户运行: sudo bash $0" && exit 1
}

# --- 系统调优 (提速核心) ---
optimize_system() {
    log info "正在应用系统网络优化 (BBR + Sysctl)..."
    
    # 1. 开启 BBR
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        log success "已添加 BBR 配置"
    fi

    # 2. 优化 TCP 窗口和连接数 (针对高并发代理)
    cat > /etc/sysctl.d/99-suoha-speed.conf <<EOF
fs.file-max = 1000000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
EOF

    # 3. 提高 ulimit 限制
    if ! grep -q "soft nofile 512000" /etc/security/limits.conf; then
        echo "* soft nofile 512000" >> /etc/security/limits.conf
        echo "* hard nofile 512000" >> /etc/security/limits.conf
        echo "root soft nofile 512000" >> /etc/security/limits.conf
        echo "root hard nofile 512000" >> /etc/security/limits.conf
    fi
    
    sysctl -p >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1
    ulimit -n 512000
    log success "网络内核参数优化完成！"
}

install_base_deps() {
    # 简化版依赖安装，自动检测
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|kali) CMD="apt install -y" ;;
            alpine) CMD="apk add" ;;
            centos|fedora|rhel) CMD="yum install -y" ;;
            *) CMD="apt install -y" ;; # 默认尝试 apt
        esac
    else
        CMD="apt install -y"
    fi

    local deps=("curl" "screen" "lsof" "tar" "sed" "grep")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            $CMD "$dep" >/dev/null 2>&1
        fi
    done
}

get_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) log error "不支持的架构"; exit 1 ;;
    esac
}

download_file() {
    local url="$1"
    local out="$2"
    if [[ -f "$out" ]]; then return 0; fi
    log info "下载: $(basename "$out")"
    if ! curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"; then
        log error "下载失败，请检查网络。"
        rm -f "$out"
        exit 1
    fi
    chmod +x "$out"
}

get_free_port() {
    local port
    while true; do
        port=$((RANDOM % 64512 + 1024))
        if ! lsof -i TCP:"$port" -s TCP:LISTEN >/dev/null 2>&1; then
            echo "$port"
            return
        fi
    done
}

stop_services() {
    screen -ls | grep -E "x-tunnel|opera|argo|cfbind" | awk '{print $1}' | xargs -r -I{} screen -X -S {} quit
}

download_assets() {
    local arch=$(get_arch)
    # 使用 Cloudflare 官方源保证最新版以支持 QUIC
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    local xt_url="https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-${arch}"
    local opera_url="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-${arch}"

    download_file "$xt_url" "$BIN_DIR/x-tunnel-linux"
    download_file "$opera_url" "$BIN_DIR/opera-linux"
    download_file "$cf_url" "$BIN_DIR/cloudflared-linux"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
wsport=${wsport:-}
metricsport=${metricsport:-}
TRY_DOMAIN=${TRY_DOMAIN:-}
token=${token:-}
bind_enable=${bind_enable:-}
bind_domain=${bind_domain:-}
EOF
}

start_services() {
    local opera_en="$1"
    local opera_cc="$2"
    local ip_ver="$3"
    local u_port="$4"
    local u_token="$5"
    local bind_en="$6"
    local bind_tk="$7"

    # 1. 端口设置
    wsport="${u_port:-$(get_free_port)}"
    
    # 2. 启动 Opera (如果开启)
    local proxy_args=""
    if [[ "$opera_en" == "1" ]]; then
        local operaport=$(get_free_port)
        log info "启动 Opera Proxy (Region: $opera_cc)..."
        screen -dmS opera "$BIN_DIR/opera-linux" -country "$opera_cc" -socks-mode -bind-address "127.0.0.1:${operaport}"
        proxy_args="-f socks5://127.0.0.1:${operaport}"
        sleep 1
    fi

    # 3. 启动 X-Tunnel
    log info "启动 X-Tunnel..."
    local xt_cmd="$BIN_DIR/x-tunnel-linux -l ws://127.0.0.1:${wsport}"
    [[ -n "$u_token" ]] && xt_cmd+=" -token $u_token"
    [[ -n "$proxy_args" ]] && xt_cmd+=" $proxy_args"
    screen -dmS x-tunnel bash -c "$xt_cmd"

    # 4. 启动 Cloudflared (QUIC 协议优化)
    # 注意：这里强制指定 --protocol quic
    metricsport=$(get_free_port)
    log info "启动 Cloudflare Tunnel (QUIC Protocol)..."
    
    screen -dmS argo "$BIN_DIR/cloudflared-linux" tunnel --edge-ip-version "$ip_ver" \
        --protocol quic --no-autoupdate \
        --url "127.0.0.1:${wsport}" --metrics "127.0.0.1:${metricsport}"

    # 5. Named Tunnel
    if [[ "$bind_en" == "1" ]]; then
        screen -dmS cfbind "$BIN_DIR/cloudflared-linux" tunnel --edge-ip-version "$ip_ver" \
            --protocol quic run --token "$bind_tk"
    fi

    # 6. 获取域名
    log info "等待域名分配..."
    TRY_DOMAIN=""
    for i in {1..20}; do
        local resp=$(curl -s "http://127.0.0.1:${metricsport}/metrics")
        if [[ "$resp" =~ userHostname=\"https://([^\"]+)\" ]]; then
            TRY_DOMAIN="${BASH_REMATCH[1]}"
            break
        fi
        sleep 1
    done

    save_config
    display_info
}

display_info() {
    clear
    log success "=== ⚡ Suoha X-Tunnel [SPEED OPTIMIZED] ⚡ ==="
    echo -e "优化状态     : ${GREEN}BBR 已开启 / QUIC 协议已启用 / Kernel 已调优${PLAIN}"
    echo -e "本地 WS 端口 : ${YELLOW}${wsport}${PLAIN}"
    
    if [[ -n "$TRY_DOMAIN" ]]; then
        echo -e "临时域名     : ${GREEN}${TRY_DOMAIN}:443${PLAIN}"
    else
        echo -e "临时域名     : ${RED}获取超时 (请检查 metrics 或稍后重试)${PLAIN}"
    fi

    [[ "$bind_enable" == "1" ]] && echo -e "绑定域名     : ${GREEN}${bind_domain:-后台运行中}${PLAIN}"
    [[ -n "$token" ]] && echo -e "Token        : ${YELLOW}${token}${PLAIN}"
    
    echo -e "Metrics      : http://127.0.0.1:${metricsport}/metrics"
    echo -e "============================================"
    log info "提示: 客户端请确保使用支持 HTTP/2 或 QUIC 的最新版核心。"
}

# --- 菜单 ---
main_menu() {
    clear
    echo -e "${YELLOW}Suoha X-Tunnel 极速版${PLAIN}"
    echo "1. 🚀 启动极速模式 (BBR + QUIC)"
    echo "2. 🛑 停止服务"
    echo "3. 🗑️  删除并清理"
    echo "4. 📊 查看状态"
    echo "0. 退出"
    read -r -p "选择: " num
    case "$num" in
        1)
            check_root
            optimize_system  # 强制先优化系统
            install_base_deps
            download_assets
            
            # 交互部分简化
            read -r -p "启用 Opera? (0/1) [0]: " op; op=${op:-0}
            cc="AM"; [[ "$op" == "1" ]] && { read -r -p "地区 (AM/EU/AS) [AM]: " cc; cc=${cc:-AM}; }
            read -r -p "IP版本 (4/6) [4]: " ip; ip=${ip:-4}
            read -r -p "X-Tunnel Token (空): " tk
            read -r -p "固定 WS 端口? (空=随机): " pt
            read -r -p "绑定域名模式? (0/1) [0]: " bd; bd=${bd:-0}
            btk=""; bdm=""
            if [[ "$bd" == "1" ]]; then
                read -r -p "CF Tunnel Token: " btk
                read -r -p "绑定域名 (仅显示): " bdm
            fi
            
            bind_enable="$bd"; bind_domain="$bdm"; token="$tk"
            stop_services
            start_services "$op" "$cc" "$ip" "$pt" "$tk" "$bd" "$btk"
            ;;
        2) stop_services; log success "服务已停止"; ;;
        3) stop_services; rm -rf "$BIN_DIR" "$CONFIG_FILE"; log success "已卸载"; ;;
        4) source "$CONFIG_FILE" 2>/dev/null && display_info || log error "未运行"; ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

main_menu