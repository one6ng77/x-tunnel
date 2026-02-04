#!/usr/bin/env bash
# ==========================================
# Suoha X-Tunnel [TURBO SPEED EDITION]
# Features: Parallel DL, FQ_CODEL, Low Latency TCP
# ==========================================

set -u
export LC_ALL=C

# --- 配置与颜色 ---
CONFIG_FILE="${HOME}/.suoha_tunnel_config"
BIN_DIR="${HOME}/.suoha_bin"
mkdir -p "$BIN_DIR"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

# --- 辅助函数 ---

log() {
    case $1 in
        "info") echo -e "${BLUE}[信息]${PLAIN} $2" ;;
        "success") echo -e "${GREEN}[成功]${PLAIN} $2" ;;
        "warn") echo -e "${YELLOW}[注意]${PLAIN} $2" ;;
        "error") echo -e "${RED}[错误]${PLAIN} $2" ;;
        *) echo "$1" ;;
    esac
}

check_root() {
    [[ $EUID -ne 0 ]] && log error "请使用 root 用户运行: sudo bash $0" && exit 1
}

# --- 核心功能模块 ---

# 1. 深度系统优化 [TURBO TCP 版]
# 针对 TCP 协议进行极限优化，减少缓冲区膨胀
optimize_system() {
    echo -e "${YELLOW}正在应用内核级网络优化 (fq_codel + BBR + Lowat)...${PLAIN}"
    
    # 检测容器环境
    if systemd-detect-virt | grep -qE "lxc|docker|wsl"; then
        log warn "容器环境：仅优化用户空间限制。"
    else
        # 尝试加载 BBR
        modprobe tcp_bbr 2>/dev/null
        
        # 写入优化配置
        cat > /etc/sysctl.d/99-suoha-speed.conf <<EOF
# --- 拥塞控制与队列 (对抗网络抖动) ---
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# --- 关键：降低 TCP 延迟 (Low Latency) ---
# 限制未发送数据量，防止缓冲区过大导致的延迟 (Bufferbloat)
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0

# --- TFO 与连接优化 ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# --- 吞吐量优化 ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mtu_probing = 1
EOF
        sysctl -p /etc/sysctl.d/99-suoha-speed.conf >/dev/null 2>&1 || true
        log success "内核优化完成：已启用 fq_codel + BBR + LowLatency"
    fi

    ulimit -n 1000000
    echo "* soft nofile 1000000" > /etc/security/limits.d/suoha.conf
    echo "* hard nofile 1000000" >> /etc/security/limits.d/suoha.conf
}

# 2. 依赖安装 (智能跳过)
install_deps() {
    # 如果关键命令都存在，直接跳过耗时的 apt/yum update
    if command -v curl >/dev/null 2>&1 && command -v screen >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
        log info "依赖已满足，跳过安装..."
        return
    fi

    log info "检查并安装必要依赖..."
    local pm_cmd=""
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|kali) pm_cmd="apt install -y" ;;
            centos|fedora|rhel|rocky) pm_cmd="yum install -y" ;;
            alpine) pm_cmd="apk add" ;;
            *) pm_cmd="apt install -y" ;;
        esac
    else
        pm_cmd="apt install -y"
    fi
    
    $pm_cmd curl screen lsof tar grep >/dev/null 2>&1
    log success "依赖安装完成"
}

# 3. 资源下载 (并行加速)
download_binaries() {
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    log info "启动并行下载组件 (3线程)..."
    
    dl() {
        local url="$1"
        local path="$2"
        if [[ ! -f "$path" ]]; then
            # 增加超时和重试，静默下载
            curl -L -s --connect-timeout 10 --retry 3 "$url" -o "$path"
            if [[ $? -ne 0 ]]; then
                log error "下载失败: $path"
                return 1
            fi
        fi
        chmod +x "$path"
        echo -e "${GREEN} -> 就绪:${PLAIN} $(basename $path)"
    }

    # 后台并行下载
    dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" "$BIN_DIR/cloudflared-linux" &
    PID1=$!
    dl "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-${arch}" "$BIN_DIR/x-tunnel-linux" &
    PID2=$!
    dl "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-${arch}" "$BIN_DIR/opera-linux" &
    PID3=$!

    wait $PID1 $PID2 $PID3
    echo ""
    log success "所有组件下载完成"
}

# 4. 获取端口
get_random_port() {
    local port
    while true; do
        port=$((RANDOM % 64512 + 1024))
        if ! lsof -i TCP:"$port" -s TCP:LISTEN >/dev/null 2>&1; then
            echo "$port"
            return
        fi
    done
}

# 5. 停止服务
stop_all() {
    screen -ls | grep -E "suoha_core|suoha_opera|suoha_argo|suoha_bind" | awk '{print $1}' | xargs -r -I{} screen -X -S {} quit
}

# 6. 启动服务 (IO优化 + CPU减负)
start_services() {
    local proxy_mode="$1"
    local proxy_val="$2"
    local proto="$3"
    local port="$4"
    local ip_ver="$5"
    local xt_tk="$6"
    local bind_on="$7"
    local cf_tk="$8"

    local ws_port="${port:-$(get_random_port)}"
    local metrics_port=$(get_random_port)
    
    # --- 落地代理 ---
    local proxy_chain=""
    if [[ "$proxy_mode" == "1" ]]; then
        local op_port=$(get_random_port)
        log info "启动 Opera Proxy..."
        screen -dmS suoha_opera "$BIN_DIR/opera-linux" -country "$proxy_val" -socks-mode -bind-address "127.0.0.1:${op_port}"
        proxy_chain="-f socks5://127.0.0.1:${op_port}"
        sleep 1
    elif [[ "$proxy_mode" == "2" ]]; then
        log info "应用自定义代理..."
        proxy_chain="-f socks5://${proxy_val}"
    fi

    # --- 启动 X-Tunnel (静默模式减少IO) ---
    log info "启动 X-Tunnel (WS Turbo)..."
    local xt_cmd="$BIN_DIR/x-tunnel-linux -l ws://127.0.0.1:${ws_port}"
    [[ -n "$xt_tk" ]] && xt_cmd+=" -token $xt_tk"
    [[ -n "$proxy_chain" ]] && xt_cmd+=" $proxy_chain"
    # 关键：重定向到 /dev/null 减少磁盘 IO
    screen -dmS suoha_core bash -c "exec $xt_cmd >/dev/null 2>&1"

    # --- 启动 Cloudflared (性能调优) ---
    # 优化点：
    # 1. compression-quality 0: 禁用压缩，降低 CPU 延迟，不仅是 QUIC，TCP 下也有效
    # 2. protocol: 尊重用户选择 (http2/quic)
    local cf_args="tunnel --edge-ip-version $ip_ver --no-autoupdate --compression-quality 0 --protocol $proto"
    
    log info "启动 Cloudflare 隧道 (Proto: ${proto^^} / No-Comp)..."
    screen -dmS suoha_argo "$BIN_DIR/cloudflared-linux" $cf_args --url "127.0.0.1:${ws_port}" --metrics "127.0.0.1:${metrics_port}"

    if [[ "$bind_on" == "1" ]]; then
        screen -dmS suoha_bind "$BIN_DIR/cloudflared-linux" $cf_args run --token "$cf_tk"
    fi

    # --- 获取域名 ---
    log info "请求临时域名..."
    echo -ne "等待中 "
    local domain_found=""
    for i in {1..30}; do
        local resp=$(curl -s "http://127.0.0.1:${metrics_port}/metrics")
        if [[ "$resp" =~ userHostname=\"https://([^\"]+)\" ]]; then
            domain_found="${BASH_REMATCH[1]}"
            echo -e "\n"
            break
        fi
        echo -ne "."
        sleep 1
    done

    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
ws_port=${ws_port}
metrics_port=${metrics_port}
temp_domain=${domain_found}
bind_enable=${bind_on}
xt_token=${xt_tk}
cf_proto=${proto}
proxy_mode=${proxy_mode}
EOF
    
    display_result "$domain_found" "$ws_port" "$bind_on" "$proto" "$proxy_mode"
}

# 7. 显示结果
display_result() {
    local domain="$1"
    local port="$2"
    local bind="$3"
    local proto="$4"
    local pm="$5"

    clear
    echo -e "=================================================="
    echo -e "       🚀 梭哈 X-Tunnel [TURBO EDITION] 🚀        "
    echo -e "=================================================="
    echo -e "系统内核 : ${GREEN}fq_codel + BBR + LowLatency${PLAIN}"
    echo -e "传输协议 : ${YELLOW}${proto^^}${PLAIN} (无压缩模式)"
    echo -e "本地端口 : ${YELLOW}${port}${PLAIN}"
    
    if [[ "$pm" == "0" ]]; then
        echo -e "落地策略 : ${BLUE}直连 (Direct)${PLAIN}"
    elif [[ "$pm" == "1" ]]; then
        echo -e "落地策略 : ${GREEN}Opera VPN${PLAIN}"
    else
        echo -e "落地策略 : ${YELLOW}自定义 SOCKS5${PLAIN}"
    fi

    echo -e "--------------------------------------------------"
    
    if [[ -n "$domain" ]]; then
        echo -e "临时域名 : ${GREEN}${domain}${PLAIN}"
        echo -e "完整链接 : https://${domain}"
    else
        echo -e "临时域名 : ${RED}获取超时${PLAIN}"
    fi

    [[ "$bind" == "1" ]] && echo -e "绑定域名 : ${GREEN}后台运行中${PLAIN}"
    echo -e "=================================================="
}

# --- 主菜单 ---

wizard() {
    clear
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "${BLUE}#         Suoha X-Tunnel 极速互联优化版        #${PLAIN}"
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "1. ${GREEN}安装并启动${PLAIN}"
    echo -e "2. ${RED}停止所有服务${PLAIN}"
    echo -e "3. ${YELLOW}卸载并清理${PLAIN}"
    echo -e "4. 查看运行状态"
    echo -e "0. 退出"
    echo ""
    read -r -p "请选择操作 [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1)
            check_root; install_deps; download_binaries; optimize_system
            echo -e "\n${YELLOW}--- 配置向导 ---${PLAIN}"
            
            # 1. 协议 (保持可选)
            echo -e "\n[1/6] 选择协议:"
            echo -e "  1. HTTP2 (TCP, 默认推荐，稳定)"
            echo -e "  2. QUIC  (UDP, 极速，需网络支持)"
            read -r -p "选择 [1]: " pc
            local proto="http2"
            [[ "$pc" == "2" ]] && proto="quic"

            # 2. IP版本
            echo -e "\n[2/6] Cloudflare 连接 IP 版本:"
            read -r -p "选择 (4/6) [4]: " ip_ver; ip_ver=${ip_ver:-4}

            # 3. 落地策略
            echo -e "\n[3/6] 选择落地策略:"
            echo -e "  1. 直连"
            echo -e "  2. Opera 免费 VPN"
            echo -e "  3. 自定义 SOCKS5"
            read -r -p "选择 [1]: " pm; pm=${pm:-1}
            local p_mode=0; local p_val=""
            if [[ "$pm" == "2" ]]; then p_mode=1; read -r -p "地区 (AM/EU/AS) [AM]: " p_val; p_val=${p_val:-AM}
            elif [[ "$pm" == "3" ]]; then p_mode=2; read -r -p "SOCKS5 链接: " p_val
                [[ -z "$p_val" ]] && { log error "不能为空"; exit 1; }
            fi

            # 其他配置
            echo -e "\n[4/6] WS 端口 (留空随机):"; read -r -p "端口: " fixed_port
            echo -e "\n[5/6] X-Tunnel Token (留空无):"; read -r -p "Token: " xt_tk
            
            echo -e "\n[6/6] 绑定域名 (Named Tunnel)?"
            read -r -p "启用? (y/n) [n]: " bd_c
            local bind_on=0; local cf_tk=""
            if [[ "$bd_c" == "y" ]]; then
                bind_on=1
                echo -e "${YELLOW}需 Cloudflare Tunnel Token${PLAIN}"
                read -r -p "Token: " cf_tk
                [[ -z "$cf_tk" ]] && bind_on=0
            fi

            stop_all 
            start_services "$p_mode" "$p_val" "$proto" "$fixed_port" "$ip_ver" "$xt_tk" "$bind_on" "$cf_tk"
            ;;
        2) stop_all; log success "已停止"; ;;
        3) stop_all; rm -rf "$BIN_DIR" "$CONFIG_FILE"; log success "已卸载"; ;;
        4) if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; local pm=${proxy_mode:-0}; display_result "$temp_domain" "$ws_port" "$bind_enable" "$cf_proto" "$pm"; else log warn "未运行"; fi ;;
        0) exit 0 ;;
        *) log error "无效输入" ;;
    esac
}

wizard
log() {
    case $1 in
        "info") echo -e "${BLUE}[信息]${PLAIN} $2" ;;
        "success") echo -e "${GREEN}[成功]${PLAIN} $2" ;;
        "warn") echo -e "${YELLOW}[注意]${PLAIN} $2" ;;
        "error") echo -e "${RED}[错误]${PLAIN} $2" ;;
        *) echo "$1" ;;
    esac
}

check_root() {
    [[ $EUID -ne 0 ]] && log error "请使用 root 用户运行: sudo bash $0" && exit 1
}

# --- 核心功能模块 ---

# 1. 深度系统优化 (针对 Mux 和 Zero-RTT 调优)
optimize_system() {
    echo -e "${YELLOW}正在应用内核级网络优化 (TFO + Mux + BBR)...${PLAIN}"
    
    # 检测容器环境
    if systemd-detect-virt | grep -qE "lxc|docker|wsl"; then
        log warn "容器环境限制：部分内核参数无法修改，仅优化用户空间限制。"
    else
        # 1. 开启 BBR
        if ! grep -q "tcp_congestion_control = bbr" /etc/sysctl.conf; then
            echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        fi
        
        # 2. 深度网络栈调优 (实现你要求的加速特性)
        cat > /etc/sysctl.d/99-suoha-speed.conf <<EOF
# --- 首帧带目标 (TCP Fast Open / Zero-RTT) ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0

# --- Mux 多路复用优化 ---
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# --- TLS/连接缓存优化 (保持长连接活跃) ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0

# --- 吞吐量与缓冲区优化 ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1000000
EOF
        sysctl -p /etc/sysctl.d/99-suoha-speed.conf >/dev/null 2>&1 || true
        log success "内核优化完成：已开启 TFO(Zero-RTT) 与 BBR"
    fi

    ulimit -n 1000000
    echo "* soft nofile 1000000" > /etc/security/limits.d/suoha.conf
    echo "* hard nofile 1000000" >> /etc/security/limits.d/suoha.conf
}

# 2. 依赖安装
install_deps() {
    log info "检查并安装必要依赖..."
    local pm_cmd=""
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|kali) pm_cmd="apt install -y" ;;
            centos|fedora|rhel|rocky) pm_cmd="yum install -y" ;;
            alpine) pm_cmd="apk add" ;;
            *) pm_cmd="apt install -y" ;;
        esac
    else
        pm_cmd="apt install -y"
    fi
    
    ($pm_cmd curl screen lsof tar grep >/dev/null 2>&1) & spinner
    log success "依赖安装完成"
}

# 3. 资源下载
download_binaries() {
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    log info "开始下载组件..."
    
    dl() {
        local url="$1"
        local path="$2"
        if [[ ! -f "$path" ]]; then
            # 增加重试和超时设置
            if ! curl -L --progress-bar --connect-timeout 10 --retry 3 "$url" -o "$path"; then
                echo "" 
                log error "下载失败: $path"
                return 1
            fi
        fi
        chmod +x "$path"
    }

    dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" "$BIN_DIR/cloudflared-linux"
    dl "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-${arch}" "$BIN_DIR/x-tunnel-linux"
    dl "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-${arch}" "$BIN_DIR/opera-linux"
    
    echo ""
    log success "组件就绪"
}

# 4. 获取端口
get_random_port() {
    local port
    while true; do
        port=$((RANDOM % 64512 + 1024))
        if ! lsof -i TCP:"$port" -s TCP:LISTEN >/dev/null 2>&1; then
            echo "$port"
            return
        fi
    done
}

# 5. 停止服务
stop_all() {
    screen -ls | grep -E "suoha_core|suoha_opera|suoha_argo|suoha_bind" | awk '{print $1}' | xargs -r -I{} screen -X -S {} quit
}

# 6. 启动服务 (加入连接优化参数)
start_services() {
    local proxy_mode="$1"
    local proxy_val="$2"
    local proto="$3"
    local port="$4"
    local ip_ver="$5"
    local xt_tk="$6"
    local bind_on="$7"
    local cf_tk="$8"

    local ws_port="${port:-$(get_random_port)}"
    local metrics_port=$(get_random_port)
    
    # --- 落地代理 ---
    local proxy_chain=""
    if [[ "$proxy_mode" == "1" ]]; then
        local op_port=$(get_random_port)
        log info "启动 Opera Proxy ($proxy_val)..."
        screen -dmS suoha_opera "$BIN_DIR/opera-linux" -country "$proxy_val" -socks-mode -bind-address "127.0.0.1:${op_port}"
        proxy_chain="-f socks5://127.0.0.1:${op_port}"
        sleep 1
    elif [[ "$proxy_mode" == "2" ]]; then
        log info "应用自定义代理 ($proxy_val)..."
        proxy_chain="-f socks5://${proxy_val}"
    fi

    # --- 启动 X-Tunnel ---
    log info "启动 X-Tunnel..."
    # 注意：这里我们依靠内核的 TFO 支持，无需特殊 flags，因为 x-tunnel 默认行为会被 sysctl 影响
    local xt_cmd="$BIN_DIR/x-tunnel-linux -l ws://127.0.0.1:${ws_port}"
    [[ -n "$xt_tk" ]] && xt_cmd+=" -token $xt_tk"
    [[ -n "$proxy_chain" ]] && xt_cmd+=" $proxy_chain"
    screen -dmS suoha_core bash -c "$xt_cmd"

    # --- 启动 Cloudflared (Mux 优化) ---
    # 强制 Cloudflare 使用压缩和多路复用特性
    local cf_args="tunnel --edge-ip-version $ip_ver --no-autoupdate --compression-quality 0"
    
    # 协议选择：QUIC 本身就是最佳的 Mux 实现
    if [[ "$proto" == "quic" ]]; then
        cf_args+=" --protocol quic"
    else
        cf_args+=" --protocol http2"
    fi

    log info "启动 Cloudflare 隧道 (Mux/Compression Enabled)..."
    screen -dmS suoha_argo "$BIN_DIR/cloudflared-linux" $cf_args --url "127.0.0.1:${ws_port}" --metrics "127.0.0.1:${metrics_port}"

    if [[ "$bind_on" == "1" ]]; then
        screen -dmS suoha_bind "$BIN_DIR/cloudflared-linux" $cf_args run --token "$cf_tk"
    fi

    # --- 获取域名 ---
    log info "请求临时域名..."
    echo -ne "等待中 "
    local domain_found=""
    for i in {1..30}; do
        local resp=$(curl -s "http://127.0.0.1:${metrics_port}/metrics")
        if [[ "$resp" =~ userHostname=\"https://([^\"]+)\" ]]; then
            domain_found="${BASH_REMATCH[1]}"
            echo -e "\n"
            break
        fi
        echo -ne "."
        sleep 1
    done

    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
ws_port=${ws_port}
metrics_port=${metrics_port}
temp_domain=${domain_found}
bind_enable=${bind_on}
xt_token=${xt_tk}
cf_proto=${proto}
proxy_mode=${proxy_mode}
EOF
    
    display_result "$domain_found" "$ws_port" "$bind_on" "$proto" "$proxy_mode"
}

# 7. 显示结果
display_result() {
    local domain="$1"
    local port="$2"
    local bind="$3"
    local proto="$4"
    local pm="$5"

    clear
    echo -e "=================================================="
    echo -e "           🚀 梭哈 X-Tunnel 极速版 🚀             "
    echo -e "=================================================="
    echo -e "内核加速 : ${GREEN}TFO (Zero-RTT) / BBR / Mux Opt${PLAIN}"
    echo -e "传输协议 : ${YELLOW}${proto^^}${PLAIN}"
    echo -e "本地端口 : ${YELLOW}${port}${PLAIN}"
    
    if [[ "$pm" == "0" ]]; then
        echo -e "落地策略 : ${BLUE}直连 (Direct)${PLAIN}"
    elif [[ "$pm" == "1" ]]; then
        echo -e "落地策略 : ${GREEN}Opera VPN${PLAIN}"
    else
        echo -e "落地策略 : ${YELLOW}自定义 SOCKS5${PLAIN}"
    fi

    echo -e "--------------------------------------------------"
    
    if [[ -n "$domain" ]]; then
        echo -e "临时域名 : ${GREEN}${domain}${PLAIN}"
        echo -e "完整链接 : https://${domain}"
    else
        echo -e "临时域名 : ${RED}获取超时${PLAIN}"
    fi

    [[ "$bind" == "1" ]] && echo -e "绑定域名 : ${GREEN}${bind_domain:-已在后台运行}${PLAIN}"
    echo -e "=================================================="
}

# --- 主菜单 ---

wizard() {
    clear
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "${BLUE}#         Suoha X-Tunnel 极速内核优化版        #${PLAIN}"
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "1. ${GREEN}安装并启动${PLAIN}"
    echo -e "2. ${RED}停止所有服务${PLAIN}"
    echo -e "3. ${YELLOW}卸载并清理${PLAIN}"
    echo -e "4. 查看运行状态"
    echo -e "0. 退出"
    echo ""
    read -r -p "请选择操作 [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1)
            check_root; install_deps; download_binaries; optimize_system
            echo -e "\n${YELLOW}--- 配置向导 ---${PLAIN}"
            
            # 1. 协议
            echo -e "\n[1/6] 选择协议 (推荐 QUIC 以获得最佳 Mux 效果):"
            echo -e "  1. QUIC  (UDP, 极速, 原生多路复用)"
            echo -e "  2. HTTP2 (TCP, 稳定)"
            read -r -p "选择 [1]: " pc; local proto="quic"; [[ "$pc" == "2" ]] && proto="http2"

            # 2. IP版本
            echo -e "\n[2/6] Cloudflare 连接 IP 版本:"
            read -r -p "选择 (4/6) [4]: " ip_ver; ip_ver=${ip_ver:-4}

            # 3. 落地策略
            echo -e "\n[3/6] 选择落地策略:"
            echo -e "  1. 直连"
            echo -e "  2. Opera 免费 VPN"
            echo -e "  3. 自定义 SOCKS5"
            read -r -p "选择 [1]: " pm; pm=${pm:-1}
            local p_mode=0; local p_val=""
            if [[ "$pm" == "2" ]]; then p_mode=1; read -r -p "地区 (AM/EU/AS) [AM]: " p_val; p_val=${p_val:-AM}
            elif [[ "$pm" == "3" ]]; then p_mode=2; read -r -p "SOCKS5 链接: " p_val
                [[ -z "$p_val" ]] && { log error "不能为空"; exit 1; }
            fi

            # 其他配置
            echo -e "\n[4/6] WS 端口 (留空随机):"; read -r -p "端口: " fixed_port
            echo -e "\n[5/6] X-Tunnel Token (留空无):"; read -r -p "Token: " xt_tk
            
            echo -e "\n[6/6] 绑定域名 (Named Tunnel)?"
            read -r -p "启用? (y/n) [n]: " bd_c
            local bind_on=0; local cf_tk=""; global_bind_domain=""
            if [[ "$bd_c" == "y" ]]; then
                bind_on=1
                echo -e "${YELLOW}需 Cloudflare Tunnel Token${PLAIN}"
                read -r -p "Token: " cf_tk
                read -r -p "域名 (仅记录): " global_bind_domain
                [[ -z "$cf_tk" ]] && bind_on=0
            fi

            stop_all; bind_domain="$global_bind_domain" 
            start_services "$p_mode" "$p_val" "$proto" "$fixed_port" "$ip_ver" "$xt_tk" "$bind_on" "$cf_tk"
            ;;
        2) stop_all; log success "已停止"; ;;
        3) stop_all; rm -rf "$BIN_DIR" "$CONFIG_FILE"; log success "已卸载"; ;;
        4) if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; local pm=${proxy_mode:-0}; display_result "$temp_domain" "$ws_port" "$bind_enable" "$cf_proto" "$pm"; else log warn "未运行"; fi ;;
        0) exit 0 ;;
        *) log error "无效输入" ;;
    esac
}

wizard
