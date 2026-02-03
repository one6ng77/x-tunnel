#!/usr/bin/env bash
set -uo pipefail

# =========================
# Suoha X-Tunnel FINAL (Optimized)
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
    [[ $EUID -ne 0 ]] && log error "请使用 root 用户运行此脚本: sudo bash $0" && exit 1
}

# 优化包管理器检测逻辑
install_base_deps() {
    local cmd_install=""
    local cmd_update=""
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|kali)
                cmd_update="apt update"
                cmd_install="apt install -y"
                ;;
            centos|fedora|rhel|almalinux|rocky)
                cmd_update="yum makecache"
                cmd_install="yum install -y"
                ;;
            alpine)
                cmd_update="apk update"
                cmd_install="apk add"
                ;;
            arch|manjaro)
                cmd_update="pacman -Sy"
                cmd_install="pacman -S --noconfirm"
                ;;
            *)
                log warn "未识别的发行版，尝试使用 apt..."
                cmd_update="apt update"
                cmd_install="apt install -y"
                ;;
        esac
    else
        cmd_update="apt update"
        cmd_install="apt install -y"
    fi

    local deps=("curl" "screen" "lsof" "grep" "sed" "awk" "tar")
    # 尝试安装 net-tools 用于 netstat，或者 iproute2 用于 ss，这里优先保证基础工具
    if ! command -v ss >/dev/null; then deps+=("iproute2"); fi
    if ! command -v nc >/dev/null; then deps+=("netcat"); fi # 不同发行版包名可能不同，暂试 netcat

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            log info "正在安装依赖: $dep ..."
            $cmd_update >/dev/null 2>&1
            $cmd_install "$dep" >/dev/null 2>&1
        fi
    done
}

get_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64) echo "amd64" ;;
        i386|i686) echo "386" ;;
        armv8|arm64|aarch64) echo "arm64" ;;
        *) log error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

# 带重试的下载函数
download_file() {
    local url="$1"
    local out="$2"
    local retries=3
    
    if [[ -f "$out" ]]; then return 0; fi

    for ((i=1; i<=retries; i++)); do
        log info "下载 $(basename "$out") (尝试 $i/$retries)..."
        if curl -fsSL --connect-timeout 10 --retry 2 "$url" -o "$out"; then
            chmod +x "$out"
            return 0
        fi
        sleep 2
    done
    log error "下载失败: $url"
    return 1
}

get_free_port() {
    local port
    while true; do
        port=$((RANDOM % 64512 + 1024))
        if ! lsof -i TCP:"$port" -s TCP:LISTEN >/dev/null 2>&1 && \
           ! ss -lnt | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

stop_screen_session() {
    local name="$1"
    screen -S "$name" -X quit >/dev/null 2>&1 || true
    # 双重确保
    screen -ls | awk -v n="$name" '$0~n {print $1}' | xargs -r -I{} screen -X -S {} quit >/dev/null 2>&1
}

# --- 业务逻辑 ---

download_assets() {
    local arch
    arch=$(get_arch)
    local xt_url="https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-${arch}"
    local opera_url="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-${arch}"
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

    download_file "$xt_url" "$BIN_DIR/x-tunnel-linux"
    download_file "$opera_url" "$BIN_DIR/opera-linux"
    download_file "$cf_url" "$BIN_DIR/cloudflared-linux"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
wsport=${wsport:-}
metricsport=${metricsport:-}
try_domain=${TRY_DOMAIN:-}
bind_enable=${bind_enable:-0}
bind_domain=${bind_domain:-}
token=${token:-}
EOF
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

cleanup_env() {
    log info "清理运行环境..."
    stop_screen_session "x-tunnel"
    stop_screen_session "opera"
    stop_screen_session "argo"
    stop_screen_session "cfbind"
    screen -wipe >/dev/null 2>&1
}

start_process() {
    local opera_enabled="${1:-0}"
    local opera_country="${2:-AM}"
    local ip_version="${3:-4}"
    local manual_wsport="${4:-}"
    local xt_token="${5:-}"
    local bind_enabled="${6:-0}"
    local cf_token="${7:-}"

    # 1. 端口处理
    if [[ -n "$manual_wsport" ]]; then
        if lsof -i TCP:"$manual_wsport" -s TCP:LISTEN >/dev/null 2>&1; then
            log error "端口 $manual_wsport 已被占用，请更换。"
            exit 1
        fi
        wsport="$manual_wsport"
    else
        wsport=$(get_free_port)
    fi

    # 2. 启动 Opera Proxy (可选)
    local proxy_flag=""
    if [[ "$opera_enabled" == "1" ]]; then
        local operaport
        operaport=$(get_free_port)
        log info "启动 Opera Proxy (端口: $operaport, 地区: $opera_country)..."
        screen -dmS opera "$BIN_DIR/opera-linux" -country "$opera_country" -socks-mode -bind-address "127.0.0.1:${operaport}"
        proxy_flag="-f socks5://127.0.0.1:${operaport}"
        sleep 2
    fi

    # 3. 启动 X-Tunnel
    log info "启动 X-Tunnel (WS端口: $wsport)..."
    local xt_cmd="$BIN_DIR/x-tunnel-linux -l ws://127.0.0.1:${wsport}"
    [[ -n "$xt_token" ]] && xt_cmd+=" -token $xt_token"
    [[ -n "$proxy_flag" ]] && xt_cmd+=" $proxy_flag"
    
    screen -dmS x-tunnel bash -c "$xt_cmd"
    sleep 1

    # 4. 启动 Cloudflared (Argo)
    metricsport=$(get_free_port)
    log info "启动 Cloudflared Quick Tunnel..."
    screen -dmS argo "$BIN_DIR/cloudflared-linux" --edge-ip-version "$ip_version" --protocol http2 tunnel \
        --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

    # 5. 启动 Cloudflared Bind (可选)
    if [[ "$bind_enabled" == "1" && -n "$cf_token" ]]; then
        log info "启动 Cloudflared Named Tunnel..."
        screen -dmS cfbind "$BIN_DIR/cloudflared-linux" --edge-ip-version "$ip_version" tunnel run --token "$cf_token"
    fi

    # 6. 获取临时域名
    log info "正在获取 Quick Tunnel 域名 (最长等待 60秒)..."
    TRY_DOMAIN=""
    for i in {1..60}; do
        local resp
        resp=$(curl -s "http://127.0.0.1:${metricsport}/metrics" || true)
        # 尝试匹配 userHostname="https://..."
        if [[ "$resp" == *"userHostname="* ]]; then
            TRY_DOMAIN=$(echo "$resp" | sed -n 's/.*userHostname="https:\/\/\([^"]*\)".*/\1/p')
            [[ -n "$TRY_DOMAIN" ]] && break
        fi
        echo -ne "."
        sleep 1
    done
    echo "" # 换行

    save_config
    display_info
}

display_info() {
    clear
    log success "=============================="
    log success "      梭哈模式 - 服务状态      "
    log success "=============================="
    echo -e "本地监听 WS 端口 : ${YELLOW}${wsport}${PLAIN}"
    
    if [[ -n "$TRY_DOMAIN" ]]; then
        echo -e "临时域名 (Quick) : ${GREEN}${TRY_DOMAIN}:443${PLAIN}"
    else
        echo -e "临时域名 (Quick) : ${RED}获取失败 (请检查 metrics 或网络)${PLAIN}"
    fi

    if [[ "${bind_enable:-0}" == "1" ]]; then
        echo -e "绑定域名 (Named) : ${GREEN}${bind_domain:-已启动后台服务}${PLAIN}"
        echo -e "Cloudflare 设置  : 请确保 Public Hostname 指向 ${YELLOW}http://127.0.0.1:${wsport}${PLAIN}"
    else
        echo -e "绑定域名 (Named) : ${BLUE}未启用${PLAIN}"
    fi

    if [[ -n "${token:-}" ]]; then
        echo -e "X-Tunnel Token   : ${YELLOW}${token}${PLAIN}"
    fi

    echo -e "Metrics 地址     : http://$(curl -s4 https://ip.sb):${metricsport}/metrics"
    echo -e "=============================="
    
    # 简单自检提示
    if [[ -n "$TRY_DOMAIN" ]]; then
        echo -e "\n正在进行连接测试..."
        if curl -I -s --connect-timeout 5 "https://${TRY_DOMAIN}" | grep -q "401 Unauthorized"; then
             log success "连接成功! (返回 401 说明 X-Tunnel 需要 Token，链路已通)"
        else
             log warn "连接测试返回非 401 状态，请手动验证。"
        fi
    fi
}

# --- 菜单逻辑 ---

main_menu() {
    clear
    echo -e "${YELLOW}Suoha X-Tunnel${PLAIN} - 自动隧道管理工具"
    echo "------------------------------"
    echo "1. 启动梭哈模式 (安装/启动)"
    echo "2. 停止所有服务"
    echo "3. 停止服务并清空缓存"
    echo "4. 查看当前状态"
    echo "0. 退出"
    echo "------------------------------"
    read -r -p "请选择 [1]: " mode
    mode="${mode:-1}"

    case "$mode" in
        1)
            install_base_deps
            download_assets
            
            # 收集参数
            echo ""
            read -r -p "启用 Opera 前置代理? (0:否, 1:是) [默认0]: " opera_opt
            opera_opt="${opera_opt:-0}"
            local country="AM"
            if [[ "$opera_opt" == "1" ]]; then
                read -r -p "代理地区 (AM/AS/EU) [默认AM]: " c_in
                country="${c_in:-AM}"
            fi

            read -r -p "Cloudflared IP模式 (4/6) [默认4]: " ip_ver
            ip_ver="${ip_ver:-4}"

            read -r -p "设置 X-Tunnel Token (留空则无): " tk
            
            read -r -p "是否固定 WS 端口? (0:随机, 1:固定) [默认0]: " fix_p
            local user_port=""
            if [[ "$fix_p" == "1" ]]; then
                read -r -p "输入端口号 [默认12345]: " user_port
                user_port="${user_port:-12345}"
            fi

            read -r -p "启用绑定域名 (Named Tunnel)? (0:否, 1:是) [默认0]: " bind_opt
            bind_opt="${bind_opt:-0}"
            local cf_tk=""
            local b_dom=""
            if [[ "$bind_opt" == "1" ]]; then
                read -r -p "输入 Cloudflare Tunnel Token: " cf_tk
                if [[ -z "$cf_tk" ]]; then
                    log error "必须提供 Token"
                    exit 1
                fi
                read -r -p "输入绑定的域名 (仅用于显示): " b_dom
                
                # 如果用户开启绑定域名但没有固定端口，强制建议固定
                if [[ -z "$user_port" ]]; then
                    log warn "绑定域名模式建议固定端口，否则重启后 CF 后台配置会失效。"
                    read -r -p "是否改为固定端口 12345? (y/n) [y]: " confirm_fix
                    confirm_fix="${confirm_fix:-y}"
                    if [[ "$confirm_fix" == "y" ]]; then
                        user_port="12345"
                    fi
                fi
            fi

            # 保存全局变量供 display_info 使用
            bind_enable="$bind_opt"
            bind_domain="$b_dom"
            token="$tk"
            
            cleanup_env
            start_process "$opera_opt" "$country" "$ip_ver" "$user_port" "$tk" "$bind_opt" "$cf_tk"
            ;;
        2)
            cleanup_env
            rm -f "$CONFIG_FILE"
            log success "服务已停止"
            ;;
        3)
            cleanup_env
            rm -f "$CONFIG_FILE"
            rm -rf "$BIN_DIR"
            log success "服务已停止，缓存已清空"
            ;;
        4)
            if load_config; then
                display_info
            else
                log error "未找到运行配置，请先启动服务。"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            log error "无效选项"
            ;;
    esac
}

# --- 入口 ---
check_root
main_menu