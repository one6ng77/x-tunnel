#!/usr/bin/env bash
# ==========================================
# Suoha X-Tunnel [TURBO SPEED FINAL]
# Features: Parallel DL, FQ_CODEL, Result Display
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

# 1. 深度系统优化 (Turbo TCP 模式)
optimize_system() {
    echo -e "${YELLOW}正在应用网络优化 (fq_codel + BBR + LowLatency)...${PLAIN}"
    
    if systemd-detect-virt | grep -qE "lxc|docker|wsl"; then
        log warn "容器环境：跳过内核参数修改，仅优化连接数限制。"
    else
        local cc_algo="bbr"
        if grep -q "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            cc_algo="bbr2"
        else
            modprobe tcp_bbr 2>/dev/null
        fi

        local qdisc_algo="fq_codel"
        if tc qdisc add dev lo root fq >/dev/null 2>&1; then
            tc qdisc del dev lo root >/dev/null 2>&1 || true
            qdisc_algo="fq"
        fi

        cat > /etc/sysctl.d/99-suoha-speed.conf <<EOF
# --- 拥塞控制 ---
net.core.default_qdisc = ${qdisc_algo}
net.ipv4.tcp_congestion_control = ${cc_algo}

# --- 降低延迟关键参数 ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1

# --- 连接性能 ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
EOF
        sysctl -p /etc/sysctl.d/99-suoha-speed.conf >/dev/null 2>&1 || true
        log success "内核优化完成 (${qdisc_algo} + ${cc_algo})"
    fi

    ulimit -n 1000000
    echo "* soft nofile 1000000" > /etc/security/limits.d/suoha.conf
    echo "* hard nofile 1000000" >> /etc/security/limits.d/suoha.conf
}

# 2. 依赖安装 (快速检查)
install_deps() {
    if command -v curl >/dev/null 2>&1 && command -v screen >/dev/null 2>&1; then
        log info "依赖已存在，跳过安装。"
        return
    fi
    log info "安装必要依赖..."
    local pm_cmd="apt install -y"
    [[ -f /etc/redhat-release ]] && pm_cmd="yum install -y"
    [[ -f /etc/alpine-release ]] && pm_cmd="apk add"
    $pm_cmd curl screen lsof tar grep >/dev/null 2>&1
}

# 3. 资源下载 (并行加速)
download_binaries() {
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    log info "开始并行下载组件..."
    dl() {
        local url="$1"
        local path="$2"
        if [[ ! -f "$path" ]]; then
            curl -L -s --connect-timeout 10 --retry 3 "$url" -o "$path"
            chmod +x "$path"
            echo -e "${GREEN}-> 就绪:${PLAIN} $(basename $path)"
        else
            echo -e "${GREEN}-> 已存在:${PLAIN} $(basename $path)"
        fi
    }

    dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" "$BIN_DIR/cloudflared-linux" &
    PID1=$!
    dl "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-${arch}" "$BIN_DIR/x-tunnel-linux" &
    PID2=$!
    dl "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-${arch}" "$BIN_DIR/opera-linux" &
    PID3=$!
    
    wait $PID1 $PID2 $PID3
    echo ""
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

# 6. 显示结果 (您要求的端口信息在这里)
display_result() {
    local domain="$1"
    local port="$2"
    local bind="$3"
    local proto="$4"
    local pm="$5"
    local cf_count="${6:-1}"

    clear
    echo -e "=================================================="
    echo -e "       🚀 梭哈 X-Tunnel [TURBO EDITION] 🚀        "
    echo -e "=================================================="
    echo -e "系统内核 : ${GREEN}fq_codel + BBR + LowLatency${PLAIN}"
    echo -e "传输协议 : ${YELLOW}${proto^^}${PLAIN} (无压缩)"
    echo -e "隧道数量 : ${GREEN}${cf_count}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "🔑 本地端口 : ${GREEN}${port}${PLAIN}  <--- 请复制这个端口"
    echo -e "--------------------------------------------------"
    
    if [[ "$pm" == "0" ]]; then
        echo -e "落地策略 : ${BLUE}直连 (Direct)${PLAIN}"
    elif [[ "$pm" == "1" ]]; then
        echo -e "落地策略 : ${GREEN}Opera VPN${PLAIN}"
    else
        echo -e "落地策略 : ${YELLOW}自定义 SOCKS5${PLAIN}"
    fi

    echo -e "--------------------------------------------------"
    
    if [[ -n "$domain" ]]; then
        echo -e "🌐 临时域名 : ${GREEN}${domain}${PLAIN}"
        echo -e "🔗 完整链接 : https://${domain}"
    else
        echo -e "临时域名 : ${RED}获取超时 (请检查网络)${PLAIN}"
    fi

    [[ "$bind" == "1" ]] && echo -e "绑定域名 : ${GREEN}后台运行中${PLAIN}"
    echo -e "=================================================="
}

# 7. 启动服务
start_services() {
    local proxy_mode="$1"
    local proxy_val="$2"
    local proto="$3"
    local port="$4"
    local ip_ver="$5"
    local xt_tk="$6"
    local bind_on="$7"
    local cf_tk="$8"
    local cf_count="${9:-1}"

    local ws_port="${port:-$(get_random_port)}"
    local metrics_port=$(get_random_port)
    
    # 落地代理
    local proxy_chain=""
    if [[ "$proxy_mode" == "1" ]]; then
        local op_port=$(get_random_port)
        log info "启动 Opera Proxy..."
        screen -dmS suoha_opera "$BIN_DIR/opera-linux" -country "$proxy_val" -socks-mode -bind-address "127.0.0.1:${op_port}"
        proxy_chain="-f socks5://127.0.0.1:${op_port}"
        sleep 1
    elif [[ "$proxy_mode" == "2" ]]; then
        proxy_chain="-f socks5://${proxy_val}"
    fi

    # 启动 X-Tunnel (静默)
    log info "启动 X-Tunnel..."
    local xt_cmd="$BIN_DIR/x-tunnel-linux -l ws://127.0.0.1:${ws_port}"
    [[ -n "$xt_tk" ]] && xt_cmd+=" -token $xt_tk"
    [[ -n "$proxy_chain" ]] && xt_cmd+=" $proxy_chain"
    screen -dmS suoha_core bash -c "exec $xt_cmd >/dev/null 2>&1"

    # 启动 Cloudflared (无压缩)
    local cf_args="tunnel --edge-ip-version $ip_ver --no-autoupdate --compression-quality 0 --protocol $proto"
    log info "启动 Cloudflare 隧道 (x${cf_count})..."
    for i in $(seq 1 "${cf_count}"); do
        local cf_metrics_port="${metrics_port}"
        if [[ "$i" -ne 1 ]]; then
            cf_metrics_port=$(get_random_port)
        fi
        screen -dmS "suoha_argo_${i}" "$BIN_DIR/cloudflared-linux" $cf_args --url "127.0.0.1:${ws_port}" --metrics "127.0.0.1:${cf_metrics_port}"
    done

    if [[ "$bind_on" == "1" ]]; then
        screen -dmS suoha_bind "$BIN_DIR/cloudflared-linux" $cf_args run --token "$cf_tk"
    fi

    # 获取域名
    log info "正在请求域名，请稍候..."
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
cf_count=${cf_count}
EOF
    
    # === 这里调用显示结果 ===
    display_result "$domain_found" "$ws_port" "$bind_on" "$proto" "$proxy_mode" "$cf_count"
}

# --- 主菜单 ---

wizard() {
    clear
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "${BLUE}#         Suoha X-Tunnel 极速优化版            #${PLAIN}"
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
            
            # 协议选择
            echo -e "\n[1/6] 选择协议:"
            echo -e "  1. HTTP2 (TCP, 推荐)"
            echo -e "  2. QUIC  (UDP)"
            read -r -p "选择 [1]: " pc; local proto="http2"; [[ "$pc" == "2" ]] && proto="quic"

            # IP版本
            echo -e "\n[2/6] 连接 IP 版本:"
            read -r -p "选择 (4/6) [4]: " ip_ver; ip_ver=${ip_ver:-4}

            # 落地策略
            echo -e "\n[3/6] 落地策略:"
            echo -e "  1. 直连"
            echo -e "  2. Opera VPN"
            echo -e "  3. 自定义 SOCKS5"
            read -r -p "选择 [1]: " pm; pm=${pm:-1}
            local p_mode=0; local p_val=""
            if [[ "$pm" == "2" ]]; then p_mode=1; read -r -p "地区 (AM/EU/AS) [AM]: " p_val; p_val=${p_val:-AM}
            elif [[ "$pm" == "3" ]]; then p_mode=2; read -r -p "SOCKS5 链接: " p_val; fi

            # 端口
            echo -e "\n[4/6] WS 端口 (留空随机):"; read -r -p "端口: " fixed_port
            echo -e "\n[5/6] X-Tunnel Token (留空无):"; read -r -p "Token: " xt_tk
            
            # 并发隧道数量
            echo -e "\n[6/7] 并发隧道数量 (建议 1-4):"
            read -r -p "数量 [1]: " cf_count
            cf_count=${cf_count:-1}
            if ! [[ "$cf_count" =~ ^[0-9]+$ ]] || [[ "$cf_count" -lt 1 ]]; then
                log warn "隧道数量无效，已回退为 1"
                cf_count=1
            fi

            # 绑定
            echo -e "\n[7/7] 绑定域名 (Named Tunnel)?"
            read -r -p "启用? (y/n) [n]: " bd_c
            local bind_on=0; local cf_tk=""
            if [[ "$bd_c" == "y" ]]; then bind_on=1; read -r -p "Token: " cf_tk; [[ -z "$cf_tk" ]] && bind_on=0; fi

            stop_all 
            start_services "$p_mode" "$p_val" "$proto" "$fixed_port" "$ip_ver" "$xt_tk" "$bind_on" "$cf_tk" "$cf_count"
            ;;
        2) stop_all; log success "已停止"; ;;
        3) stop_all; rm -rf "$BIN_DIR" "$CONFIG_FILE"; log success "已卸载"; ;;
        4) if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; local pm=${proxy_mode:-0}; display_result "$temp_domain" "$ws_port" "$bind_enable" "$cf_proto" "$pm" "${cf_count:-1}"; else log warn "未运行"; fi ;;
        0) exit 0 ;;
        *) log error "无效输入" ;;
    esac
}

wizard
