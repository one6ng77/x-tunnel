#!/usr/bin/env bash
# ==========================================
# Suoha X-Tunnel [ULTIMATE EDITION]
# Author: Gemini Optimized
# Features: BBR, QUIC/HTTP2 Switch, UX Enhanced
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

# 动态旋转等待动画
spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

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

# 1. 智能系统优化 (带环境检测)
optimize_system() {
    echo -e "${YELLOW}正在检查系统环境并尝试优化...${PLAIN}"
    
    # 检测是否为容器环境 (Docker/LXC)
    if systemd-detect-virt | grep -qE "lxc|docker|wsl"; then
        log warn "检测到虚拟化容器环境，跳过内核参数修改 (BBR)，仅优化进程限制。"
    else
        # 物理机或 KVM/Xen 虚拟机，执行全量优化
        if ! grep -q "tcp_congestion_control = bbr" /etc/sysctl.conf; then
            echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        fi
        
        # 写入优化参数
        cat > /etc/sysctl.d/99-suoha.conf <<EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
fs.file-max = 1000000
EOF
        sysctl -p /etc/sysctl.d/99-suoha.conf >/dev/null 2>&1 || true
        log success "BBR 及内核参数优化已应用"
    fi

    # 通用优化：文件描述符
    ulimit -n 512000
    echo "* soft nofile 512000" > /etc/security/limits.d/suoha.conf
    echo "* hard nofile 512000" >> /etc/security/limits.d/suoha.conf
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
    
    # 这一步后台运行，显示动画
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

    log info "开始下载组件 (Cloudflared + X-Tunnel + Opera)..."
    
    # 定义下载函数
    dl() {
        local url="$1"
        local path="$2"
        if [[ ! -f "$path" ]]; then
            # 使用 curl 显示进度条但只有关键信息
            if ! curl -L --progress-bar --connect-timeout 10 --retry 3 "$url" -o "$path"; then
                echo "" # 换行
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
    log success "所有组件准备就绪"
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

# 6. 启动服务 (核心逻辑)
start_services() {
    local opera_on="$1"
    local opera_region="$2"
    local proto="$3"
    local port="$4"
    local ip_ver="$5"
    local xt_tk="$6"
    local bind_on="$7"
    local cf_tk="$8"

    # 准备端口
    local ws_port="${port:-$(get_random_port)}"
    local metrics_port=$(get_random_port)
    
    # --- 启动 Opera ---
    local proxy_chain=""
    if [[ "$opera_on" == "1" ]]; then
        local op_port=$(get_random_port)
        log info "正在启动 Opera 前置代理 (地区: $opera_region)..."
        screen -dmS suoha_opera "$BIN_DIR/opera-linux" -country "$opera_region" -socks-mode -bind-address "127.0.0.1:${op_port}"
        proxy_chain="-f socks5://127.0.0.1:${op_port}"
        sleep 1
    fi

    # --- 启动 X-Tunnel ---
    log info "正在启动 X-Tunnel 核心..."
    local xt_cmd="$BIN_DIR/x-tunnel-linux -l ws://127.0.0.1:${ws_port}"
    [[ -n "$xt_tk" ]] && xt_cmd+=" -token $xt_tk"
    [[ -n "$proxy_chain" ]] && xt_cmd+=" $proxy_chain"
    screen -dmS suoha_core bash -c "$xt_cmd"

    # --- 启动 Cloudflared (Argo) ---
    local proto_flag="--protocol http2"
    [[ "$proto" == "quic" ]] && proto_flag="--protocol quic"

    log info "正在启动 Cloudflare 隧道 (协议: ${YELLOW}${proto^^}${PLAIN})..."
    
    # Quick Tunnel
    screen -dmS suoha_argo "$BIN_DIR/cloudflared-linux" tunnel --edge-ip-version "$ip_ver" \
        $proto_flag --no-autoupdate \
        --url "127.0.0.1:${ws_port}" --metrics "127.0.0.1:${metrics_port}"

    # Named Tunnel (Bind Domain)
    if [[ "$bind_on" == "1" ]]; then
        screen -dmS suoha_bind "$BIN_DIR/cloudflared-linux" tunnel --edge-ip-version "$ip_ver" \
            $proto_flag run --token "$cf_tk"
    fi

    # --- 获取域名 ---
    log info "正在向 Cloudflare 请求分配临时域名..."
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
EOF
    
    display_result "$domain_found" "$ws_port" "$bind_on" "$proto"
}

# 7. 显示结果面板
display_result() {
    local domain="$1"
    local port="$2"
    local bind="$3"
    local proto="$4"

    clear
    echo -e "=================================================="
    echo -e "           🎉 梭哈 X-Tunnel 部署完成 🎉           "
    echo -e "=================================================="
    echo -e "传输协议 : ${GREEN}${proto^^}${PLAIN} (QUIC=UDP / HTTP2=TCP)"
    echo -e "本地端口 : ${YELLOW}${port}${PLAIN}"
    echo -e "--------------------------------------------------"
    
    if [[ -n "$domain" ]]; then
        echo -e "临时域名 : ${GREEN}${domain}${PLAIN}"
        echo -e "完整链接 : https://${domain}"
    else
        echo -e "临时域名 : ${RED}获取超时${PLAIN} (请等待几分钟后在菜单选4查看)"
    fi

    if [[ "$bind" == "1" ]]; then
        echo -e "绑定域名 : ${GREEN}${bind_domain:-已在后台运行}${PLAIN}"
    else
        echo -e "绑定域名 : 未启用"
    fi
    echo -e "--------------------------------------------------"
    echo -e "客户端配置提示:"
    echo -e "1. 地址(Address) -> 优选IP 或 脚本生成的域名"
    echo -e "2. 端口(Port)    -> 443"
    echo -e "3. 伪装域名(SNI) -> 上面的域名"
    echo -e "4. 路径(Path)    -> / (默认)"
    echo -e "=================================================="
}

# --- 主菜单逻辑 ---

wizard() {
    clear
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "${BLUE}#            Suoha X-Tunnel 增强脚本           #${PLAIN}"
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "1. ${GREEN}安装并启动${PLAIN} (Wizard Mode)"
    echo -e "2. ${RED}停止所有服务${PLAIN}"
    echo -e "3. ${YELLOW}卸载并清理${PLAIN}"
    echo -e "4. 查看运行状态"
    echo -e "0. 退出"
    echo ""
    read -r -p "请选择操作 [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1)
            check_root
            install_deps
            download_binaries
            optimize_system

            echo -e "\n${YELLOW}--- 配置向导 (直接回车使用默认值) ---${PLAIN}"
            
            # 1. 协议选择 (关键优化)
            echo -e "\n[1/6] 请选择传输协议:"
            echo -e "  1. QUIC  (UDP, 速度极快, 抗丢包, 但可能被运营商限速)"
            echo -e "  2. HTTP2 (TCP, 稳定性高, 兼容性好, 速度一般)"
            read -r -p "选择协议 [默认 1]: " proto_choice
            local proto="quic"
            [[ "$proto_choice" == "2" ]] && proto="http2"

            # 2. IP版本
            echo -e "\n[2/6] Cloudflare 连接 IP 版本:"
            read -r -p "选择 (4=IPv4, 6=IPv6) [默认 4]: " ip_ver
            ip_ver=${ip_ver:-4}

            # 3. Opera 前置
            echo -e "\n[3/6] 是否启用 Opera 免费 VPN 链式代理? (用于解锁流媒体/更换IP)"
            read -r -p "启用? (y/n) [默认 n]: " use_opera
            local opera_on=0
            local opera_region="AM"
            if [[ "$use_opera" == "y" ]]; then
                opera_on=1
                read -r -p "选择地区 (AM=美洲, EU=欧洲, AS=亚洲) [默认 AM]: " opera_region
                opera_region=${opera_region:-AM}
            fi

            # 4. 端口固定
            echo -e "\n[4/6] WS 端口设置:"
            read -r -p "输入固定端口 (留空则随机): " fixed_port

            # 5. X-Tunnel Token
            echo -e "\n[5/6] X-Tunnel 访问 Token (防止被扫, 可留空):"
            read -r -p "输入 Token: " xt_token

            # 6. 绑定域名
            echo -e "\n[6/6] 是否绑定自定义域名 (Named Tunnel)?"
            read -r -p "启用? (y/n) [默认 n]: " use_bind
            local bind_on=0
            local cf_token=""
            global_bind_domain=""
            if [[ "$use_bind" == "y" ]]; then
                bind_on=1
                echo -e "${YELLOW}请前往 Cloudflare Zero Trust 面板获取 Tunnel Token${PLAIN}"
                read -r -p "粘贴 Tunnel Token: " cf_token
                read -r -p "输入绑定的域名 (仅做记录显示用): " global_bind_domain
                if [[ -z "$cf_token" ]]; then
                    log error "未提供 Token，跳过绑定域名。"
                    bind_on=0
                fi
            fi

            # 清理旧环境并启动
            stop_all
            # 将绑定域名存入变量以便 display 使用
            bind_domain="$global_bind_domain" 
            
            start_services "$opera_on" "$opera_region" "$proto" "$fixed_port" "$ip_ver" "$xt_token" "$bind_on" "$cf_token"
            ;;
        2)
            stop_all
            log success "所有服务已停止。"
            ;;
        3)
            stop_all
            rm -rf "$BIN_DIR" "$CONFIG_FILE"
            log success "程序和配置已彻底清除。"
            ;;
        4)
            if [[ -f "$CONFIG_FILE" ]]; then
                source "$CONFIG_FILE"
                display_result "$temp_domain" "$ws_port" "$bind_enable" "$cf_proto"
            else
                log warn "未检测到运行配置。"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            log error "无效输入"
            ;;
    esac
}

# --- 入口 ---
wizard