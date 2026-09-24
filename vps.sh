#!/bin/bash

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

SB_DIR="/etc/sing-box"
SB_BIN="${SB_DIR}/sing-box"
MANAGER_DIR="${SB_DIR}/manager"
STATE_FILE="${MANAGER_DIR}/state.json"
PID_DIR="${SB_DIR}/pids"
LOG_DIR="${SB_DIR}/logs"
ARGO_BIN="${SB_DIR}/cloudflared"
ARGO_LOG="${SB_DIR}/cloudflared.log"
ARGO_ENV="${SB_DIR}/cloudflared.env"
CONFIG_FILE="${SB_DIR}/config.json"
CONFIG_DIR="${SB_DIR}/conf"
INBOUNDS_FILE="${CONFIG_DIR}/inbounds.json"
SUB_FILE="${SB_DIR}/sub.txt"
SUB_NGINX_CONF="/etc/nginx/conf.d/sing-box-subscription.conf"
SUB_PORT=""
SUB_TOKEN=""
CONFIG_MODE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

info() { echo -e "${CYAN}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
error() { echo -e "${RED}$*${NC}"; }

pause() { echo; read -r -p "按回车继续..." _; }
pause_unless_cancelled() {
    if [ "${CANCELLED:-0}" = "1" ]; then CANCELLED=0; return; fi
    pause
}
command_exists() { command -v "$1" >/dev/null 2>&1; }
base64_noline() { base64 -w0 2>/dev/null || base64 2>/dev/null | tr -d '\n'; }

check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

detect_os() {
    OS="unknown"
    if [ -f /etc/os-release ]; then . /etc/os-release; OS="${ID:-unknown}"; fi
    if command_exists apk; then PKG="apk"
    elif command_exists apt-get; then PKG="apt"
    elif command_exists dnf; then PKG="dnf"
    elif command_exists yum; then PKG="yum"
    else PKG=""; fi
}

install_dependencies() {
    local missing=()
    command_exists curl || missing+=("curl")
    command_exists jq || missing+=("jq")
    command_exists tar || missing+=("tar")
    command_exists openssl || missing+=("openssl")
    command_exists shuf || missing+=("coreutils")
    command_exists ip || missing+=("ip")
    command_exists ss || missing+=("ss")
    [ "${#missing[@]}" -eq 0 ] && return 0

    info "正在安装必要依赖..."
    case "$PKG" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl jq tar openssl coreutils ca-certificates iproute2
            ;;
        apk) apk add curl jq tar openssl coreutils ca-certificates iproute2 ;;
        dnf) dnf install -y curl jq tar openssl coreutils ca-certificates iproute ;;
        yum) yum install -y curl jq tar openssl coreutils ca-certificates iproute ;;
        *) error "无法自动安装依赖。"; return 1 ;;
    esac
}

# ============================================================
# 确保 state.json 存在（写盘前统一调用）
# ============================================================

ensure_state_file() {
    [ -f "$STATE_FILE" ] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    cat > "$STATE_FILE" <<'EOF'
{
  "preferred_domain": "",
  "fixed_vmess": {
    "tag": "",
    "domain": "",
    "key": "",
    "port": 0,
    "uuid": ""
  },
  "vless_nodes": {}
}
EOF
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    return 0
}

# ============================================================
# 确保运行时目录存在（写 PID / LOG 前统一调用）
# ============================================================

ensure_runtime_dirs() {
    mkdir -p \
        "$SB_DIR" \
        "$MANAGER_DIR" \
        "$PID_DIR" \
        "$LOG_DIR" \
        "$CONFIG_DIR" 2>/dev/null || true

    ensure_state_file
}

init_dirs() {
    ensure_runtime_dirs
    chmod 700 "$MANAGER_DIR" 2>/dev/null || true
    chmod 700 "$PID_DIR"     2>/dev/null || true

    if ! jq -e '.vless_nodes' "$STATE_FILE" >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        if jq '.vless_nodes = {}' "$STATE_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$STATE_FILE"
            chmod 600 "$STATE_FILE"
        else
            rm -f "$tmp"
            warn "旧版 state.json 无法自动添加 vless_nodes。"
        fi
    fi
}

detect_arch() {
    local raw
    raw="$(uname -m)"
    case "$raw" in
        x86_64|amd64) ARCH="amd64" ;;
        i386|i686|x86) ARCH="386" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7) ARCH="armv7" ;;
        s390x) ARCH="s390x" ;;
        *) error "不支持的 CPU 架构：$raw"; return 1 ;;
    esac
    return 0
}

get_latest_singbox_version() {
    local version
    version="$(
        curl -fsSL --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30" |
        jq -r '[.[] | select(.draft == false) | select(.prerelease == false) | .tag_name][0]' 2>/dev/null
    )"
    version="${version#v}"
    if [ -z "$version" ] || [ "$version" = "null" ]; then return 1; fi
    echo "$version"
}

download_singbox() {
    detect_arch || return 1
    info "正在获取 sing-box 官方最新正式版..."
    local version
    version="$(get_latest_singbox_version)"
    if [ -z "$version" ]; then
        error "无法从 GitHub 获取 sing-box 最新正式版。"
        return 1
    fi
    local url
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    info "版本：v${version}"
    info "架构：${ARCH}"
    local tmp
    tmp="$(mktemp -d)"
    if ! curl -fL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 \
        "$url" -o "${tmp}/sing-box.tar.gz"; then
        error "sing-box 下载失败。"
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "${tmp}/sing-box.tar.gz" -C "$tmp"; then
        error "sing-box 解压失败。"
        rm -rf "$tmp"
        return 1
    fi
    local binary
    binary="$(find "$tmp" -type f -name "sing-box" -perm -u+x | head -n 1)"
    if [ -z "$binary" ]; then
        error "解压后没有找到 sing-box 二进制文件。"
        rm -rf "$tmp"
        return 1
    fi
    ensure_runtime_dirs
    install -Dm755 "$binary" "$SB_BIN"
    rm -rf "$tmp"
    if ! "$SB_BIN" version >/dev/null 2>&1; then
        error "sing-box 安装后验证失败。"
        return 1
    fi
    success "sing-box v${version} 安装成功。"
    return 0
}

ensure_singbox_installed() {
    if [ -x "$SB_BIN" ] && "$SB_BIN" version >/dev/null 2>&1; then
        local ver
        ver="$("$SB_BIN" version 2>/dev/null | head -n 1)"
        info "已检测到 sing-box：${ver:-unknown}（跳过安装）"
        return 0
    fi
    if [ -x "$SB_BIN" ]; then
        warn "检测到 sing-box 二进制存在但无法运行，正在重新安装..."
    else
        info "未检测到 sing-box，正在安装..."
    fi
    download_singbox || return 1
    return 0
}

download_cloudflared() {
    detect_arch || return 1
    local cf_arch
    case "$ARCH" in
        amd64) cf_arch="amd64" ;;
        arm64) cf_arch="arm64" ;;
        armv7) cf_arch="arm" ;;
        386)   cf_arch="386" ;;
        s390x) cf_arch="s390x" ;;
        *) error "cloudflared 不支持当前架构：$ARCH"; return 1 ;;
    esac
    local url
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    info "正在下载 Cloudflare cloudflared..."
    if ! curl -fL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 \
        "$url" -o "$ARGO_BIN"; then
        error "cloudflared 下载失败。"
        return 1
    fi
    chmod 755 "$ARGO_BIN"
    if ! "$ARGO_BIN" --version >/dev/null 2>&1; then
        error "cloudflared 安装后验证失败。"
        return 1
    fi
    success "cloudflared 安装成功。"
}

detect_config() {
    CONFIG_MODE=""
    if command_exists systemctl; then
        local exec_line
        exec_line="$(systemctl cat sing-box.service 2>/dev/null | grep -E '^[[:space:]]*ExecStart=' | tail -n 1)"
        if echo "$exec_line" | grep -q -- '-C '; then
            local cdir
            cdir="$(echo "$exec_line" | sed -n 's/.*-C[[:space:]]\+\([^[:space:]]\+\).*/\1/p')"
            if [ -d "$cdir" ] && [ -f "$cdir/inbounds.json" ]; then
                CONFIG_MODE="directory"; CONFIG_DIR="$cdir"; INBOUNDS_FILE="$cdir/inbounds.json"; return 0
            fi
        fi
        if echo "$exec_line" | grep -qE '(-c|--config)'; then
            local cfile
            cfile="$(echo "$exec_line" | sed -nE 's/.*(-c|--config)[[:space:]]+([^[:space:]]+).*/\2/p')"
            if [ -f "$cfile" ]; then
                CONFIG_MODE="file"; CONFIG_FILE="$cfile"; return 0
            fi
        fi
    fi
    if [ -f "/etc/sing-box/conf/inbounds.json" ]; then
        CONFIG_MODE="directory"; CONFIG_DIR="/etc/sing-box/conf"; INBOUNDS_FILE="/etc/sing-box/conf/inbounds.json"; return 0
    fi
    if [ -f "/etc/sing-box/config.json" ]; then
        CONFIG_MODE="file"; CONFIG_FILE="/etc/sing-box/config.json"; return 0
    fi
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$INBOUNDS_FILE" ]; then
        cat > "$INBOUNDS_FILE" <<'EOF'
{
  "inbounds": []
}
EOF
    fi
    CONFIG_MODE="directory"
}

get_exec_args() {
    if [ "$CONFIG_MODE" = "directory" ]; then
        echo "run -C ${CONFIG_DIR}"
    else
        echo "run -c ${CONFIG_FILE}"
    fi
}

ensure_config() {
    detect_config
    if [ "$CONFIG_MODE" = "directory" ]; then
        mkdir -p "$CONFIG_DIR"
        [ -f "$INBOUNDS_FILE" ] || echo '{"inbounds":[]}' > "$INBOUNDS_FILE"
        if ! jq empty "$INBOUNDS_FILE" >/dev/null 2>&1; then
            error "当前 inbounds.json 不是有效 JSON："; error "$INBOUNDS_FILE"; return 1
        fi
        if ! jq -e '.inbounds and (.inbounds | type == "array")' "$INBOUNDS_FILE" >/dev/null 2>&1; then
            error "当前 inbounds.json 没有有效的 inbounds 数组。"; return 1
        fi
    elif [ "$CONFIG_MODE" = "file" ]; then
        if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
            error "当前 config.json 不是有效 JSON："; error "$CONFIG_FILE"; return 1
        fi
        if ! jq -e '.inbounds and (.inbounds | type == "array")' "$CONFIG_FILE" >/dev/null 2>&1; then
            error "当前 config.json 没有有效的 inbounds 数组。"; return 1
        fi
    fi
    return 0
}

update_inbounds() {
    local expression="$1"
    ensure_config || return 1
    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq "$expression" "$INBOUNDS_FILE" > "$tmp" || { rm -f "$tmp"; error "修改 inbounds 失败。"; return 1; }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq "$expression" "$CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; error "修改 config.json 失败。"; return 1; }
        mv "$tmp" "$CONFIG_FILE"
    fi
    return 0
}

backup_config_once() {
    ensure_config >/dev/null 2>&1 || return 0
    local backup_dir="${SB_DIR}/backup"
    mkdir -p "$backup_dir"
    local stamp
    stamp="$(date '+%Y%m%d-%H%M%S')"
    if [ "$CONFIG_MODE" = "directory" ]; then
        [ -f "$INBOUNDS_FILE" ] && cp -a "$INBOUNDS_FILE" "${backup_dir}/inbounds-${stamp}.json"
    elif [ "$CONFIG_MODE" = "file" ]; then
        [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "${backup_dir}/config-${stamp}.json"
    fi
    ls -1t "$backup_dir"/* 2>/dev/null | tail -n +6 | xargs -r rm -f
}

service_mode() {
    if command_exists systemctl && [ -d /run/systemd/system ]; then echo "systemd"; return; fi
    if command_exists rc-service; then echo "openrc"; return; fi
    echo "manual"
}

create_systemd_service() {
    ensure_config >/dev/null 2>&1 || true
    local exec_args
    exec_args="$(get_exec_args)"
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${SB_DIR}
ExecStart=${SB_BIN} ${exec_args}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
}

create_openrc_service() {
    ensure_config >/dev/null 2>&1 || true
    local exec_args
    exec_args="$(get_exec_args)"
    mkdir -p /etc/init.d
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box"

command="${SB_BIN}"
command_args="${exec_args#run }"

command_background="yes"
pidfile="/run/sing-box.pid"

depend() {
    need net
}
EOF
    chmod +x /etc/init.d/sing-box
    if command_exists rc-update; then
        rc-update add sing-box default >/dev/null 2>&1 || true
    fi
}

start_singbox() {
    ensure_config >/dev/null 2>&1 || return 1
    local mode
    mode="$(service_mode)"
    case "$mode" in
        systemd)
            create_systemd_service
            systemctl restart sing-box
            sleep 1
            if systemctl is-active --quiet sing-box; then success "sing-box 已启动。"; return 0; fi
            error "sing-box 启动失败。"
            systemctl --no-pager --full status sing-box 2>/dev/null | tail -n 20
            return 1
            ;;
        openrc)
            create_openrc_service
            rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1
            sleep 1
            if rc-service sing-box status >/dev/null 2>&1; then success "sing-box 已启动。"; return 0; fi
            error "sing-box 启动失败。"
            return 1
            ;;
        manual)
            stop_manual_singbox
            ensure_runtime_dirs
            if [ "$CONFIG_MODE" = "directory" ]; then
                nohup "$SB_BIN" run -C "$CONFIG_DIR" > "${LOG_DIR}/sing-box.log" 2>&1 &
            else
                nohup "$SB_BIN" run -c "$CONFIG_FILE" > "${LOG_DIR}/sing-box.log" 2>&1 &
            fi
            echo $! > "${PID_DIR}/sing-box.pid"
            sleep 1
            if kill -0 "$(cat "${PID_DIR}/sing-box.pid")" 2>/dev/null; then success "sing-box 已启动。"; return 0; fi
            error "sing-box 启动失败。"
            tail -n 30 "${LOG_DIR}/sing-box.log" 2>/dev/null
            return 1
            ;;
    esac
}

stop_manual_singbox() {
    if [ -f "${PID_DIR}/sing-box.pid" ]; then
        local pid
        pid="$(cat "${PID_DIR}/sing-box.pid" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "${PID_DIR}/sing-box.pid"
    fi
}

restart_singbox() {
    ensure_config >/dev/null 2>&1 || return 1
    local mode
    mode="$(service_mode)"
    case "$mode" in
        systemd)
            create_systemd_service
            systemctl restart sing-box
            ;;
        openrc)
            create_openrc_service
            rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1
            ;;
        manual)
            stop_manual_singbox
            ensure_runtime_dirs
            if [ "$CONFIG_MODE" = "directory" ]; then
                nohup "$SB_BIN" run -C "$CONFIG_DIR" > "${LOG_DIR}/sing-box.log" 2>&1 &
            else
                nohup "$SB_BIN" run -c "$CONFIG_FILE" > "${LOG_DIR}/sing-box.log" 2>&1 &
            fi
            echo $! > "${PID_DIR}/sing-box.pid"
            ;;
    esac
    sleep 1
}

stop_singbox() {
    local mode
    mode="$(service_mode)"
    case "$mode" in
        systemd) systemctl stop sing-box >/dev/null 2>&1 || true ;;
        openrc)  rc-service sing-box stop >/dev/null 2>&1 || true ;;
        manual)  stop_manual_singbox ;;
    esac
}

check_config() {
    ensure_config || return 1
    if [ "$CONFIG_MODE" = "directory" ]; then
        "$SB_BIN" check -C "$CONFIG_DIR"
    else
        "$SB_BIN" check -c "$CONFIG_FILE"
    fi
}

port_menu() {
    while true; do
        clear
        echo
        echo -e "${CYAN}---请选择端口方式---${NC}"
        echo "1. 随机端口"
        echo "2. 指定端口"
        echo "0. 返回"
        echo
        read -r -p "请选择 [1-3]: " choice
        case "$choice" in
            1)
                PORT="$(shuf -i 10000-65000 -n 1)"
                success "随机端口：$PORT"
                return 0
                ;;
            2)
                read -r -p "请输入端口： " PORT
                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    printf "${RED} 端口范围必须是 1-65535,按任意键重新输入...${NC}"
                    read -n 1 -s -r
                    continue
                fi
                if ss -lntup 2>/dev/null | grep -Eq "[:.]${PORT}[[:space:]]"; then
                    printf "${RED} 端口 $PORT 已经被占用,按任意键重新输入...${NC}"
                    read -n 1 -s -r
                    continue
                fi
                success "指定端口：$PORT"
                return 0
                ;;
            0) CANCELLED=1; return 1 ;;
            *)
                printf "${RED} 无效选项,按任意键重新输入...${NC}"
                read -n 1 -s -r
                ;;
        esac
    done
}

random_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        "$SB_BIN" generate uuid
    fi
}

_NODE_ALIAS_COUNTRY=""
_NODE_ALIAS_ISP=""
_NODE_ALIAS_LOADED=0

load_node_geo() {
    [ "$_NODE_ALIAS_LOADED" = "1" ] && return 0
    local geo country isp
    geo=$(curl -4 -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null)
    if [ -z "$geo" ] || ! echo "$geo" | grep -q '"country_code"'; then
        geo=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null)
    fi
    country=$(echo "$geo" | jq -r '.country_code // empty' 2>/dev/null)
    isp=$(echo "$geo" | jq -r '.isp // empty' 2>/dev/null)
    if [ -z "$country" ] || [ -z "$isp" ]; then
        geo=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json/" 2>/dev/null)
        [ -z "$country" ] && country=$(echo "$geo" | jq -r '.country_code // empty' 2>/dev/null)
        [ -z "$isp" ] && isp=$(echo "$geo" | jq -r '.org // empty' 2>/dev/null)
    fi
    [ -z "$country" ] && country="Unknown"
    [ -z "$isp" ] && isp="$(hostname 2>/dev/null || echo Unknown)"
    isp=$(echo "$isp" |
        sed -E \
        -e 's/[[:space:]]+/_/g' \
        -e 's/_+(Inc\.?|LLC|Ltd\.?|Limited|Corporation|Corp\.?|Co\.?)$//I' \
        -e 's/Amazon(_Technologies)?(_Inc)?/Amazon/I' \
        -e 's/Google(_LLC)?/Google/I' \
        -e 's/Microsoft(_Corporation)?/Microsoft/I' \
        -e 's/DigitalOcean(_LLC)?/DigitalOcean/I' \
        -e 's/OVH(_SAS)?/OVH/I' \
        -e 's/Vultr(_Holdings)?/Vultr/I' \
        -e 's/Akamai_Technologies/Akamai/I' \
        -e 's/Cloudflare.*/Cloudflare/I' \
        -e 's/[^A-Za-z0-9._-]//g')
    [ -z "$isp" ] && isp="Unknown"
    _NODE_ALIAS_COUNTRY="$country"
    _NODE_ALIAS_ISP="$isp"
    _NODE_ALIAS_LOADED=1
    return 0
}

get_node_alias() {
    local protocol="$1"
    load_node_geo
    echo "${_NODE_ALIAS_COUNTRY}-${_NODE_ALIAS_ISP}_${protocol}"
}

get_iface_ipv4_list() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1
}

get_iface_ipv6_list() {
    ip -6 addr show scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d'/' -f1 | grep -v '^fe80'
}

is_private_ipv4() {
    case "$1" in
        10.*) return 0 ;;
        100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|\
        100.70.*|100.71.*|100.72.*|100.73.*|100.74.*|100.75.*|\
        100.76.*|100.77.*|100.78.*|100.79.*|100.80.*|100.81.*|\
        100.82.*|100.83.*|100.84.*|100.85.*|100.86.*|100.87.*|\
        100.88.*|100.89.*|100.90.*|100.91.*|100.92.*|100.93.*|\
        100.94.*|100.95.*|100.96.*|100.97.*|100.98.*|100.99.*|\
        100.100.*|100.101.*|100.102.*|100.103.*|100.104.*|\
        100.105.*|100.106.*|100.107.*|100.108.*|100.109.*|\
        100.110.*|100.111.*|100.112.*|100.113.*|100.114.*|\
        100.115.*|100.116.*|100.117.*|100.118.*|100.119.*|\
        100.120.*|100.121.*|100.122.*|100.123.*|100.124.*|\
        100.125.*|100.126.*|100.127.*) return 0 ;;
        127.*) return 0 ;;
        169.254.*) return 0 ;;
        172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|\
        172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
        192.168.*) return 0 ;;
        0.*) return 0 ;;
        224.*|225.*|226.*|227.*|228.*|229.*|230.*|231.*|232.*|233.*|234.*|235.*|\
        236.*|237.*|238.*|239.*) return 0 ;;
        240.*|241.*|242.*|243.*|244.*|245.*|246.*|247.*|248.*|249.*|250.*|251.*|\
        252.*|253.*|254.*|255.*) return 0 ;;
    esac
    return 1
}

is_public_ipv6() {
    local ip="$1"
    case "$ip" in
        "") return 1 ;;
        ::|::1) return 1 ;;
        fe80:*|FE80:*) return 1 ;;
        fc*|fd*|FC*|FD*) return 1 ;;
    esac
    return 0
}

is_cloudflare_ip() {
    case "$1" in
        104.28.*|104.29.*|104.30.*|104.31.*) return 0 ;;
        162.158.*|162.159.*) return 0 ;;
        172.64.*|172.65.*|172.66.*|172.67.*|172.68.*|172.69.*|172.70.*|172.71.*) return 0 ;;
        188.114.*|190.93.*|197.234.*|198.41.*) return 0 ;;
    esac
    return 1
}

is_valid_ipv4() {
    local ip="$1"
    [ -z "$ip" ] && return 1
    local count
    count="$(
        echo "$ip" | awk -F. '
            NF != 4 { print 0; exit }
            {
                for (i = 1; i <= 4; i++) {
                    if ($i !~ /^[0-9]+$/) { print 0; exit }
                    if ($i < 0 || $i > 255) { print 0; exit }
                }
                print 1
            }
        '
    )"
    [ "$count" = "1" ]
}

get_public_ipv4() {
    local ip
    while read -r ip; do
        [ -z "$ip" ] && continue
        if ! is_private_ipv4 "$ip"; then echo "$ip"; return 0; fi
    done < <(get_iface_ipv4_list)
    return 1
}

get_public_ipv6() {
    local ip
    while read -r ip; do
        [ -z "$ip" ] && continue
        if is_public_ipv6 "$ip"; then echo "$ip"; return 0; fi
    done < <(get_iface_ipv6_list)
    return 1
}

get_server_ip() {
    local ip4="" ip4_curl="" ip6="" iface=""
    ip4="$(get_public_ipv4 2>/dev/null)"
    [ -n "$ip4" ] && { echo "$ip4"; return 0; }
    ip4_curl="$(curl -4 -fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null)"
    if ! is_valid_ipv4 "$ip4_curl"; then
        ip4_curl="$(curl -4 -fsS --connect-timeout 5 --max-time 8 https://ipv4.icanhazip.com 2>/dev/null)"
    fi
    if ! is_valid_ipv4 "$ip4_curl"; then
        ip4_curl="$(curl -4 -fsS --connect-timeout 5 --max-time 8 https://ifconfig.me 2>/dev/null)"
    fi
    if is_valid_ipv4 "$ip4_curl" && ! is_cloudflare_ip "$ip4_curl"; then
        echo "$ip4_curl"
        return 0
    fi
    ip6="$(get_public_ipv6 2>/dev/null)"
    [ -n "$ip6" ] && { echo "$ip6"; return 0; }
    ip6="$(curl -6 -fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null)"
    if ! echo "$ip6" | grep -q ':'; then
        ip6="$(curl -6 -fsS --connect-timeout 5 --max-time 8 https://ipv6.icanhazip.com 2>/dev/null)"
    fi
    case "$ip6" in *:*) echo "$ip6"; return 0 ;; esac
    iface="$(get_iface_ipv4_list | head -n 1)"
    [ -n "$iface" ] && { echo "$iface"; return 0; }
    echo ""
    return 1
}

SERVER_IP=""
SERVER_IP_VERSION=""

load_server_ip() {
    SERVER_IP="$(get_server_ip 2>/dev/null)"
    [ -z "$SERVER_IP" ] && SERVER_IP="你的服务器IP"
    case "$SERVER_IP" in
        *:*)
            SERVER_IP_VERSION="ipv6"
            case "$SERVER_IP" in
                \[*\]) ;;
                *) SERVER_IP="[${SERVER_IP}]" ;;
            esac
            ;;
        你的服务器IP) SERVER_IP_VERSION="unknown" ;;
        *) SERVER_IP_VERSION="ipv4" ;;
    esac
}

tag_exists() {
    local tag="$1"
    ensure_config >/dev/null 2>&1 || return 1
    local source
    source="$(get_config_source)"
    jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$source" >/dev/null 2>&1
}

unique_tag() {
    local base="$1"
    local tag="$base"
    local i=1
    while tag_exists "$tag"; do
        tag="${base}-${i}"
        i=$((i + 1))
    done
    echo "$tag"
}

warn_existing_protocol() {
    local proto_type="$1"
    local proto_name="$2"
    ensure_config >/dev/null 2>&1 || return 0
    local source
    source="$(get_config_source)"
    local count
    count="$(jq --arg t "$proto_type" '[.inbounds[]? | select(.type == $t)] | length' "$source" 2>/dev/null)"
    [ -z "$count" ] && return 0
    [ "$count" = "0" ] && return 0

    echo
    warn "检测到当前已存在 ${count} 个 ${proto_name} 节点："
    echo
    jq -r --arg t "$proto_type" \
      '.inbounds[]? | select(.type == $t) | " - tag: (.tag // "?") | 端口: (.listen_port // "?")"' \
      "$source" 2>/dev/null
    echo
    warn "请按任意键返回..."
    read -n 1 -s -r
    return 1
}

allow_port() {
    local port="$1"
    local proto="$2"
    if [ -f /.dockerenv ] || grep -qaE 'docker|lxc' /proc/1/cgroup 2>/dev/null; then
        warn "检测到容器环境，跳过容器内部防火墙配置。"
        warn "Docker 请在创建容器时使用 -p ${port}:${port}/${proto}。"
        return 0
    fi
    if command_exists ufw; then ufw allow "${port}/${proto}" >/dev/null 2>&1 || true; fi
    if command_exists firewall-cmd && command_exists systemctl && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command_exists iptables; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 ||
        iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    fi
    if command_exists ip6tables; then
        ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 ||
        ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    fi
}

save_vless_state() {
    local tag="$1" uuid="$2" public_key="$3" sni="$4" port="$5" short_id="$6"
    ensure_state_file
    local tmp
    tmp="$(mktemp)"
    if ! jq \
        --arg tag "$tag" \
        --arg uuid "$uuid" \
        --arg public_key "$public_key" \
        --arg sni "$sni" \
        --arg port "$port" \
        --arg short_id "$short_id" \
        '
        .vless_nodes = (.vless_nodes // {}) |
        .vless_nodes[$tag] = {
            uuid: $uuid,
            public_key: $public_key,
            sni: $sni,
            port: ($port | tonumber),
            short_id: $short_id
        }
        ' \
        "$STATE_FILE" > "$tmp"; then
        rm -f "$tmp"
        error "保存 VLESS Reality 状态失败。"
        return 1
    fi
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    return 0
}

remove_vless_state() {
    local tag="$1"
    [ -f "$STATE_FILE" ] || return 0
    local tmp
    tmp="$(mktemp)"
    if jq --arg tag "$tag" 'del(.vless_nodes[$tag])' "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    else
        rm -f "$tmp"
    fi
}

# ============================================================
# 从 Reality 私钥推导公钥（X25519 / PKCS#8 DER）
# ============================================================

derive_reality_public_key() {
    local private_key="$1"
    [ -n "$private_key" ] || return 1
    command_exists openssl || return 1

    local pk8
    pk8="$(mktemp)" || return 1
    printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040' > "$pk8"

    if ! printf '%s' "$private_key" | base64 -d >> "$pk8" 2>/dev/null; then
        rm -f "$pk8"
        return 1
    fi

    if [ "$(wc -c < "$pk8")" != "48" ]; then
        rm -f "$pk8"
        return 1
    fi

    local pub
    pub="$(openssl pkey -in "$pk8" -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)"
    rm -f "$pk8"

    [ -n "$pub" ] || return 1
    printf '%s' "$pub"
}

get_hysteria_pin_encoded() {
    local cert="$1"
    [ -f "$cert" ] || return 1
    local pin
    pin="$(
        openssl x509 -in "$cert" -noout -pubkey 2>/dev/null |
        openssl pkey -pubin -outform der 2>/dev/null |
        openssl dgst -sha256 -binary 2>/dev/null |
        openssl enc -base64 2>/dev/null |
        tr -d '\n'
    )"
    [ -z "$pin" ] && return 1
    if command_exists jq; then
        printf '%s' "$pin" | jq -sRr @uri
    else
        printf '%s' "$pin" | sed -e 's/+/%2B/g' -e 's|/|%2F|g' -e 's/=/%3D/g'
    fi
}

random_short_id() { openssl rand -hex 8; }

# ============================================================
# VLESS Reality
# ============================================================

install_vless() {
    clear
    echo -e "${GREEN}========== VLESS Reality 安装 ==========${NC}"
    echo
    warn_existing_protocol "vless" "VLESS Reality" || return 1
    echo
    port_menu || return

    local port="$PORT"
    local uuid keys private_key public_key short_id
    local sni="www.microsoft.com"
    local tag

    uuid="$(random_uuid)"
    tag="$(unique_tag "vless-reality")"
    short_id="$(random_short_id)"

    info "正在生成 Reality 密钥..."
    keys="$("$SB_BIN" generate reality-keypair 2>/dev/null)"
    private_key="$(echo "$keys" | awk '/PrivateKey:/ {print $2}')"
    public_key="$(echo "$keys" | awk '/PublicKey:/ {print $2}')"

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        error "Reality 密钥生成失败。"
        return 1
    fi

    backup_config_once

    local listen_addr=""
    if [ -n "$(get_public_ipv4 2>/dev/null)" ]; then
        listen_addr="0.0.0.0"
    else
        listen_addr="::"
    fi

    info "服务器地址类型：$(if [ "$listen_addr" = "0.0.0.0" ]; then echo "IPv4"; else echo "IPv6"; fi)"

    local inbound
    inbound="$(
        jq -n \
            --arg tag "$tag" \
            --arg port "$port" \
            --arg uuid "$uuid" \
            --arg sni "$sni" \
            --arg private_key "$private_key" \
            --arg short_id "$short_id" \
            --arg listen "$listen_addr" \
        '{
            type: "vless",
            tag: $tag,
            listen: $listen,
            listen_port: ($port | tonumber),
            users: [{ uuid: $uuid, flow: "xtls-rprx-vision" }],
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: { server: $sni, server_port: 443 },
                    private_key: $private_key,
                    short_id: [$short_id]
                }
            }
        }'
    )"

    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$INBOUNDS_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 VLESS 失败。"; return 1
        }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 VLESS 失败。"; return 1
        }
        mv "$tmp" "$CONFIG_FILE"
    fi

    allow_port "$port" tcp

    if ! check_config >/dev/null 2>&1; then
        error "sing-box 配置检查失败。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    restart_singbox

    if ! save_vless_state "$tag" "$uuid" "$public_key" "$sni" "$port" "$short_id"; then
        warn "VLESS 已安装，但状态保存失败。"
    fi

    load_server_ip

    echo
    success "VLESS Reality 安装成功。"
    echo
    echo "SNI：$sni"
    echo "Short ID：$short_id"
    echo "服务器地址：$SERVER_IP"
    echo "地址类型：$SERVER_IP_VERSION"
    echo
    echo -e "${GREEN}节点链接：${NC}"
    echo

    local alias
    alias="$(get_node_alias "VLESS")"

    echo "vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${alias}"

    echo
    refresh_subscription
    echo
}

# ============================================================
# 临时 Argo
# ============================================================

temp_argo_log() { echo "${LOG_DIR}/argo-$1.log"; }
temp_argo_pid() { echo "${PID_DIR}/argo-$1.pid"; }

get_temp_argo_domain() {
    local tag="$1"
    local log
    log="$(temp_argo_log "$tag")"
    [ -f "$log" ] || return 1
    sed -nE 's/.*https:\/\/([^/]+\.trycloudflare\.com).*/\1/p' "$log" 2>/dev/null | tail -n 1
}

start_temp_argo() {
    local tag="$1" port="$2"
    local log pidfile

    ensure_runtime_dirs

    log="$(temp_argo_log "$tag")"
    pidfile="$(temp_argo_pid "$tag")"

    stop_temp_argo "$tag"
    : > "$log"

    nohup "$ARGO_BIN" tunnel \
        --url "http://127.0.0.1:${port}" \
        --no-autoupdate \
        --edge-ip-version auto \
        --protocol http2 \
        > "$log" 2>&1 &

    echo $! > "$pidfile"
    sleep 3
}

stop_temp_argo() {
    local tag="$1"
    local pidfile
    pidfile="$(temp_argo_pid "$tag")"
    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
        rm -f "$pidfile"
    fi
}

stop_fixed_argo() {
    if command_exists systemctl; then systemctl stop cloudflared-singbox >/dev/null 2>&1 || true; fi
    if command_exists rc-service; then rc-service cloudflared-singbox stop >/dev/null 2>&1 || true; fi
    if [ -f "${PID_DIR}/fixed-argo.pid" ]; then
        local pid
        pid="$(cat "${PID_DIR}/fixed-argo.pid" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
        rm -f "${PID_DIR}/fixed-argo.pid"
    fi
}

stop_argo() {
    stop_fixed_argo
    local f
    for f in "${PID_DIR}"/argo-*.pid; do
        [ -f "$f" ] || continue
        local pid
        pid="$(cat "$f" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
        rm -f "$f"
    done
}

# ============================================================
# VMess 临时 Argo
# ============================================================

install_vmess_temp() {
    clear
    echo -e "${GREEN}========== VMess 临时 Argo ==========${NC}"
    echo
    warn_existing_protocol "vmess" "VMess" || return 1
    echo
    port_menu || return

    local port="$PORT" uuid tag
    uuid="$(random_uuid)"
    tag="$(unique_tag "vmess-argo")"

    ensure_runtime_dirs

    if [ ! -x "$ARGO_BIN" ]; then download_cloudflared || return 1; fi
    backup_config_once

    local inbound
    inbound="$(
        jq -n \
            --arg tag "$tag" \
            --arg port "$port" \
            --arg uuid "$uuid" \
        '{
            type: "vmess",
            tag: $tag,
            listen: "127.0.0.1",
            listen_port: ($port | tonumber),
            users: [{ uuid: $uuid }],
            transport: {
                type: "ws",
                path: "/vmess-argo",
                early_data_header_name: "Sec-WebSocket-Protocol"
            }
        }'
    )"

    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$INBOUNDS_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 VMess 失败。"; return 1
        }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 VMess 失败。"; return 1
        }
        mv "$tmp" "$CONFIG_FILE"
    fi

    if ! check_config >/dev/null 2>&1; then
        error "sing-box 配置检查失败。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    restart_singbox
    start_temp_argo "$tag" "$port"

    local domain="" log
    log="$(temp_argo_log "$tag")"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        domain="$(sed -nE 's/.*https:\/\/([^/]+\.trycloudflare\.com).*/\1/p' "$log" 2>/dev/null | tail -n 1)"
        [ -n "$domain" ] && break
        sleep 2
    done

    if [ -z "$domain" ]; then
        error "没有获取到 Cloudflare 临时 Argo 域名。"
        warn "正在回滚临时 Argo 节点..."
        stop_temp_argo "$tag"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        if check_config >/dev/null 2>&1; then restart_singbox; fi
        warn "请查看日志：$log"
        return 1
    fi

    local preferred
    preferred="$(get_preferred_domain)"
    local client_domain="$domain"
    [ -n "$preferred" ] && client_domain="$preferred"

    echo
    success "VMess 临时 Argo 安装成功。"
    echo
    echo "节点标签：$tag"
    echo "Argo 域名：$domain"
    [ -n "$preferred" ] && echo "优选域名：$preferred"
    echo

    local alias
    alias="$(get_node_alias "VMess")"

    local vmess_json
    vmess_json="$(
        jq -n \
            --arg add "$client_domain" \
            --arg host "$domain" \
            --arg sni "$domain" \
            --arg id "$uuid" \
            --arg ps "$alias" \
        '{
            v: "2",
            ps: $ps,
            add: $add,
            port: "443",
            id: $id,
            aid: "0",
            scy: "none",
            net: "ws",
            type: "none",
            host: $host,
            path: "/vmess-argo?ed=2560",
            tls: "tls",
            sni: $sni,
            alpn: "",
            fp: "firefox",
            allowInsecure: "false"
        }'
    )"

    echo "vmess://$(printf '%s' "$vmess_json" | base64_noline)"
    echo
    refresh_subscription
    echo
}

# ============================================================
# 优选域名
# ============================================================

get_preferred_domain() {
    if [ -f "$STATE_FILE" ]; then
        jq -r '.preferred_domain // empty' "$STATE_FILE" 2>/dev/null
    fi
}

show_all_vmess_links() {
    ensure_config >/dev/null 2>&1 || return 0
    local config_source
    config_source="$(get_config_source)"
    local count
    count="$(jq '.inbounds | length' "$config_source" 2>/dev/null)"
    if [ -z "$count" ] || [ "$count" = "0" ] || [ "$count" = "null" ]; then
        return 0
    fi
    local found=0 i=0
    while [ "$i" -lt "$count" ]; do
        local type
        type="$(jq -r ".inbounds[$i].type // \"\"" "$config_source" 2>/dev/null)"
        if [ "$type" = "vmess" ]; then
            if [ "$found" = "0" ]; then
                echo
                echo -e "${GREEN}========== 当前 VMess 节点链接 ==========${NC}"
                echo
                found=1
            fi
            local tag
            tag="$(jq -r ".inbounds[$i].tag // \"\"" "$config_source" 2>/dev/null)"
            echo -e "${YELLOW}[$tag]${NC}"
            generate_node_link "$i"
            echo
        fi
        i=$((i + 1))
    done
    if [ "$found" = "1" ]; then
        echo -e "${GREEN}==========================================${NC}"
    else
        echo
        warn "当前没有 VMess 节点。"
    fi
}

set_preferred_domain() {
    clear
    echo -e "${GREEN}========== 修改优选域名 ==========${NC}"
    echo
    echo "优选域名用于 VMess 客户端连接地址。"
    echo
    local old
    old="$(get_preferred_domain)"
    [ -n "$old" ] && echo "当前优选域名：$old"
    echo
    read -r -p "请输入新的优选域名（留空则清除）： " domain
    if [ -z "$domain" ]; then
        ensure_state_file
        local tmp
        tmp="$(mktemp)"
        jq '.preferred_domain = ""' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
        success "优选域名已清除。"
        refresh_subscription
        show_all_vmess_links
        return
    fi
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"
    ensure_state_file
    local tmp
    tmp="$(mktemp)"
    jq --arg domain "$domain" '.preferred_domain = $domain' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    success "优选域名已修改为：$domain"
    refresh_subscription
    show_all_vmess_links
}

# ============================================================
# 固定 Argo
# ============================================================

install_vmess_fixed() {
    clear
    echo -e "${GREEN}========== VMess 固定 Argo ==========${NC}"
    echo
    warn_existing_protocol "vmess" "VMess" || return 1
    echo

    ensure_runtime_dirs

    if [ ! -x "$ARGO_BIN" ]; then download_cloudflared || return 1; fi

    local existing_tag
    existing_tag="$(jq -r '.fixed_vmess.tag // empty' "$STATE_FILE" 2>/dev/null)"
    if [ -n "$existing_tag" ] && tag_exists "$existing_tag"; then
        error "已经存在固定 Argo 节点：$existing_tag"
        warn "请先卸载它，或使用“修改固定隧道”功能。"
        return 1
    fi

    echo
    read -r -p "请输入 Cloudflare Tunnel 域名： " domain
    [ -z "$domain" ] && { error "域名不能为空。"; return; }
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    echo
    echo "请输入 Cloudflare Tunnel Token。"
    echo "Token 会以 600 权限保存到：$ARGO_ENV"
    echo
    read -r -s -p "请输入 KEY / Token： " token
    echo
    [ -z "$token" ] && { error "KEY / Token 不能为空。"; return; }

    port_menu || return

    local port="$PORT" uuid tag
    uuid="$(random_uuid)"
    tag="$(unique_tag "vmess-fixed-argo")"

    backup_config_once

    local inbound
    inbound="$(
        jq -n \
            --arg tag "$tag" \
            --arg port "$port" \
            --arg uuid "$uuid" \
        '{
            type: "vmess",
            tag: $tag,
            listen: "127.0.0.1",
            listen_port: ($port | tonumber),
            users: [{ uuid: $uuid }],
            transport: {
                type: "ws",
                path: "/vmess-argo",
                early_data_header_name: "Sec-WebSocket-Protocol"
            }
        }'
    )"

    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$INBOUNDS_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加固定 VMess 失败。"; return 1
        }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加固定 VMess 失败。"; return 1
        }
        mv "$tmp" "$CONFIG_FILE"
    fi

    if ! check_config >/dev/null 2>&1; then
        error "sing-box 配置检查失败。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    restart_singbox
    write_fixed_argo_env "$token"
    configure_fixed_argo "$domain" "$port" "$token"
    save_fixed_vmess_state "$tag" "$domain" "$token" "$port" "$uuid"

    echo
    success "VMess 固定 Argo 已配置。"
    echo
    echo "Tunnel 域名：$domain"
    echo "本地端口：$port"
    echo "VMess UUID：$uuid"
    echo
    show_fixed_vmess_link "$domain" "$uuid"
    refresh_subscription
    echo
}

write_fixed_argo_env() {
    local token="$1"
    ensure_runtime_dirs
    {
        printf "CLOUDFLARE_TUNNEL_TOKEN='"
        printf '%s' "$token" | sed "s/'/'\\\\''/g"
        printf "'\n"
    } > "$ARGO_ENV"
    chmod 600 "$ARGO_ENV"
}

configure_fixed_argo() {
    local domain="$1" port="$2" token="$3"

    ensure_runtime_dirs

    stop_fixed_argo
    : > "$ARGO_LOG"

    if [ "$(service_mode)" = "systemd" ]; then
        cat > /etc/systemd/system/cloudflared-singbox.service <<EOF
[Unit]
Description=Cloudflare Tunnel for sing-box
After=network.target

[Service]
Type=simple
EnvironmentFile=${ARGO_ENV}
ExecStart=${ARGO_BIN} tunnel --no-autoupdate run --token \${CLOUDFLARE_TUNNEL_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable cloudflared-singbox >/dev/null 2>&1
        systemctl restart cloudflared-singbox
        success "固定 Argo 已启动。"
    elif [ "$(service_mode)" = "openrc" ]; then
        cat > /etc/init.d/cloudflared-singbox <<EOF
#!/sbin/openrc-run

description="Cloudflare Tunnel for sing-box"

if [ -f "${ARGO_ENV}" ]; then
    . "${ARGO_ENV}"
fi

command="${ARGO_BIN}"
command_args="tunnel --no-autoupdate run --token \${CLOUDFLARE_TUNNEL_TOKEN}"

command_background="yes"
pidfile="/run/cloudflared-singbox.pid"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/cloudflared-singbox
        rc-update add cloudflared-singbox default >/dev/null 2>&1 || true
        rc-service cloudflared-singbox restart >/dev/null 2>&1 ||
            rc-service cloudflared-singbox start >/dev/null 2>&1
        success "固定 Argo 已启动。"
    else
        nohup "$ARGO_BIN" tunnel \
            --no-autoupdate \
            run \
            --token "$token" \
            > "$ARGO_LOG" 2>&1 &
        echo $! > "${PID_DIR}/fixed-argo.pid"
        success "固定 Argo 已启动。"
    fi

    sleep 2
    warn "Cloudflare Tunnel Token 模式下，Tunnel 的 Public Hostname → Service"
    warn "需要在 Cloudflare Zero Trust 中指向：http://127.0.0.1:${port}"
}

save_fixed_vmess_state() {
    local tag="$1" domain="$2" token="$3" port="$4" uuid="$5"
    ensure_state_file
    local tmp
    tmp="$(mktemp)"
    jq \
        --arg tag "$tag" \
        --arg domain "$domain" \
        --arg key "$token" \
        --arg port "$port" \
        --arg uuid "$uuid" \
        '
        .fixed_vmess = {
            tag: $tag,
            domain: $domain,
            key: $key,
            port: ($port | tonumber),
            uuid: $uuid
        }
        ' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

show_fixed_vmess_link() {
    local domain="$1" uuid="$2"
    local preferred
    preferred="$(get_preferred_domain)"
    local add="$domain"
    [ -n "$preferred" ] && add="$preferred"
    local alias
    alias="$(get_node_alias "VMess")"
    local json
    json="$(
        jq -n \
            --arg add "$add" \
            --arg host "$domain" \
            --arg sni "$domain" \
            --arg uuid "$uuid" \
            --arg ps "$alias" \
        '{
            v: "2",
            ps: $ps,
            add: $add,
            port: "443",
            id: $uuid,
            aid: "0",
            scy: "none",
            net: "ws",
            type: "none",
            host: $host,
            path: "/vmess-argo?ed=2560",
            tls: "tls",
            sni: $sni,
            alpn: "",
            fp: "firefox",
            allowInsecure: "false"
        }'
    )"
    echo "vmess://$(printf '%s' "$json" | base64_noline)"
    echo
}

modify_fixed_vmess() {
    clear
    echo -e "${GREEN}========== 修改固定隧道 ==========${NC}"
    local old_tag
    old_tag="$(jq -r '.fixed_vmess.tag // empty' "$STATE_FILE" 2>/dev/null)"
    if [ -z "$old_tag" ]; then
        error "没有找到本脚本创建的固定 Argo。"
        warn "请先使用“固定 Argo”安装。"
        return
    fi
    if ! tag_exists "$old_tag"; then
        error "配置中的固定 VMess 节点已经不存在。"
        warn "请重新安装固定 Argo。"
        return
    fi
    local old_port old_uuid
    if [ "$CONFIG_MODE" = "directory" ]; then
        old_port="$(jq -r --arg tag "$old_tag" '.inbounds[] | select(.tag == $tag) | .listen_port' "$INBOUNDS_FILE" 2>/dev/null)"
        old_uuid="$(jq -r --arg tag "$old_tag" '.inbounds[] | select(.tag == $tag) | .users[0].uuid' "$INBOUNDS_FILE" 2>/dev/null)"
    else
        old_port="$(jq -r --arg tag "$old_tag" '.inbounds[] | select(.tag == $tag) | .listen_port' "$CONFIG_FILE" 2>/dev/null)"
        old_uuid="$(jq -r --arg tag "$old_tag" '.inbounds[] | select(.tag == $tag) | .users[0].uuid' "$CONFIG_FILE" 2>/dev/null)"
    fi
    echo "当前固定隧道："
    echo "域名：$(jq -r '.fixed_vmess.domain // empty' "$STATE_FILE")"
    echo "端口：$old_port"
    echo
    read -r -p "请输入新的 Cloudflare Tunnel 域名： " new_domain
    [ -z "$new_domain" ] && { error "域名不能为空。"; return; }
    new_domain="${new_domain#http://}"
    new_domain="${new_domain#https://}"
    new_domain="${new_domain%%/*}"
    echo
    read -r -s -p "请输入新的 KEY / Token： " new_token
    echo
    [ -z "$new_token" ] && { error "KEY / Token 不能为空。"; return; }
    write_fixed_argo_env "$new_token"
    configure_fixed_argo "$new_domain" "$old_port" "$new_token"
    save_fixed_vmess_state "$old_tag" "$new_domain" "$new_token" "$old_port" "$old_uuid"
    refresh_subscription
    echo
    success "固定隧道已经替换。"
    echo
    show_fixed_vmess_link "$new_domain" "$old_uuid"
}

vmess_menu() {
    while true; do
        clear
        echo -e "${CYAN}========== VMess 安装 ==========${NC}"
        echo
        echo "1. 临时 Argo"
        echo "2. 固定 Argo"
        echo "3. 修改固定隧道"
        echo "4. 修改优选域名"
        echo "0. 返回"
        echo
        read -r -p "请选择 [0-4]: " choice
        case "$choice" in
            1) install_vmess_temp; pause_unless_cancelled ;;
            2) install_vmess_fixed; pause_unless_cancelled ;;
            3) modify_fixed_vmess; pause_unless_cancelled ;;
            4) set_preferred_domain; pause_unless_cancelled ;;
            0) return ;;
            *) printf "${RED} 无效选项,按任意键重新输入...${NC}"; read -n 1 -s -r ;;
        esac
    done
}

# ============================================================
# TUIC
# ============================================================

install_tuic() {
    clear
    echo -e "${GREEN}========== TUIC 安装 ==========${NC}"
    echo
    warn_existing_protocol "tuic" "TUIC" || return 1
    echo
    port_menu || return

    local port="$PORT" uuid password tag
    uuid="$(random_uuid)"
    password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    tag="$(unique_tag "tuic")"

    ensure_runtime_dirs

    local cert="${SB_DIR}/tuic-cert.pem"
    local key="${SB_DIR}/tuic-key.pem"
    openssl ecparam -genkey -name prime256v1 -out "$key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$key" -out "$cert" -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 600 "$key"

    backup_config_once

    local inbound
    inbound="$(
        jq -n \
            --arg tag "$tag" \
            --arg port "$port" \
            --arg uuid "$uuid" \
            --arg password "$password" \
            --arg cert "$cert" \
            --arg key "$key" \
        '{
            type: "tuic",
            tag: $tag,
            listen: "::",
            listen_port: ($port | tonumber),
            users: [{ uuid: $uuid, password: $password }],
            congestion_control: "bbr",
            tls: {
                enabled: true,
                alpn: ["h3"],
                certificate_path: $cert,
                key_path: $key
            }
        }'
    )"

    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$INBOUNDS_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 TUIC 失败。"; return 1
        }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 TUIC 失败。"; return 1
        }
        mv "$tmp" "$CONFIG_FILE"
    fi

    allow_port "$port" udp

    if ! check_config >/dev/null 2>&1; then
        error "sing-box 配置检查失败。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    restart_singbox
    load_server_ip

    echo
    success "TUIC 安装成功。"
    echo

    local alias
    alias="$(get_node_alias "TUIC")"

    echo "tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${alias}"

    echo
    refresh_subscription
    echo
}

# ============================================================
# Hysteria2
# ============================================================

install_hysteria2() {
    clear
    echo -e "${GREEN}========== Hysteria2 安装 ==========${NC}"
    echo
    warn_existing_protocol "hysteria2" "Hysteria2" || return 1
    echo
    port_menu || return

    local port="$PORT" password tag
    password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    tag="$(unique_tag "hysteria2")"

    ensure_runtime_dirs

    local cert="${SB_DIR}/hy2-cert.pem"
    local key="${SB_DIR}/hy2-key.pem"
    openssl ecparam -genkey -name prime256v1 -out "$key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$key" -out "$cert" -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 600 "$key"

    local fingerprint
    fingerprint="$(get_hysteria_pin_encoded "$cert")"

    backup_config_once

    local inbound
    inbound="$(
        jq -n \
            --arg tag "$tag" \
            --arg port "$port" \
            --arg password "$password" \
            --arg cert "$cert" \
            --arg key "$key" \
        '{
            type: "hysteria2",
            tag: $tag,
            listen: "::",
            listen_port: ($port | tonumber),
            users: [{ password: $password }],
            ignore_client_bandwidth: false,
            masquerade: "https://bing.com",
            tls: {
                enabled: true,
                alpn: ["h3"],
                certificate_path: $cert,
                key_path: $key
            }
        }'
    )"

    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$INBOUNDS_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 Hysteria2 失败。"; return 1
        }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 Hysteria2 失败。"; return 1
        }
        mv "$tmp" "$CONFIG_FILE"
    fi

    allow_port "$port" udp

    if ! check_config >/dev/null 2>&1; then
        error "sing-box 配置检查失败。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    restart_singbox
    load_server_ip

    echo
    success "Hysteria2 安装成功。"
    echo

    local alias
    alias="$(get_node_alias "Hysteria2")"

    if [ -n "$fingerprint" ]; then
        echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3#${alias}"
    else
        echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&alpn=h3#${alias}"
    fi

    echo
    refresh_subscription
    echo
}

# ============================================================
# Socks5
# ============================================================

install_socks5() {
    clear
    echo -e "${GREEN}========== Socks5 安装 ==========${NC}"
    echo
    warn_existing_protocol "socks" "Socks5" || return 1
    echo
    port_menu || return

    local port="$PORT" username password tag
    read -r -p "请输入 Socks5 用户名（回车随机）： " username
    if [ -z "$username" ]; then
        username="user$(shuf -i 10000-99999 -n 1)"
    fi
    read -r -s -p "请输入 Socks5 密码（回车随机）： " password
    echo
    if [ -z "$password" ]; then
        password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    fi

    tag="$(unique_tag "socks5")"
    backup_config_once

    local inbound
    inbound="$(
        jq -n \
            --arg tag "$tag" \
            --arg port "$port" \
            --arg username "$username" \
            --arg password "$password" \
        '{
            type: "socks",
            tag: $tag,
            listen: "::",
            listen_port: ($port | tonumber),
            users: [{ username: $username, password: $password }]
        }'
    )"

    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$INBOUNDS_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 Socks5 失败。"; return 1
        }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"; error "添加 Socks5 失败。"; return 1
        }
        mv "$tmp" "$CONFIG_FILE"
    fi

    allow_port "$port" tcp

    if ! check_config >/dev/null 2>&1; then
        error "sing-box 配置检查失败。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    restart_singbox
    load_server_ip

    echo
    success "Socks5 安装成功。"
    echo
    echo "地址：${SERVER_IP}:${port}"
    echo "用户名：${username}"
    echo "密码：${password}"
    echo

    local alias
    alias="$(get_node_alias "Socks5")"

    echo "socks5://${username}:${password}@${SERVER_IP}:${port}#${alias}"

    echo
    refresh_subscription
    echo
}

# ============================================================
# 删除 inbound
# ============================================================

remove_inbound_by_tag() {
    local tag="$1"
    ensure_config || return 1
    local tmp
    tmp="$(mktemp)"
    if [ "$CONFIG_MODE" = "directory" ]; then
        jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))' "$INBOUNDS_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
        mv "$tmp" "$INBOUNDS_FILE"
    else
        jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))' "$CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
        mv "$tmp" "$CONFIG_FILE"
    fi
    return 0
}

get_config_source() {
    if [ "$CONFIG_MODE" = "directory" ]; then
        echo "$INBOUNDS_FILE"
    else
        echo "$CONFIG_FILE"
    fi
}

# ============================================================
# 一键订阅服务
# ============================================================

url_encode() { printf '%s' "$1" | jq -sRr @uri; }

get_subscription_port() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.subscription.port // empty' "$STATE_FILE" 2>/dev/null
}

get_subscription_token() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.subscription.token // empty' "$STATE_FILE" 2>/dev/null
}

save_subscription_state() {
    local port="$1" token="$2"
    ensure_state_file
    local tmp
    tmp="$(mktemp)"
    if jq \
        --arg port "$port" \
        --arg token "$token" \
        '.subscription = {port: ($port | tonumber), token: $token}' \
        "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

pick_subscription_port() {
    local port
    while true; do
        port="$(shuf -i 20000-60000 -n 1)"
        if ! ss -lnt 2>/dev/null | grep -Eq ":${port}[[:space:]]|:${port}$"; then
            echo "$port"
            return 0
        fi
    done
}

install_nginx_for_subscription() {
    command_exists nginx && return 0
    info "未检测到 nginx，正在安装订阅服务所需的 nginx..."
    case "$PKG" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || return 1
            DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >/dev/null 2>&1 || return 1
            ;;
        apk) apk add nginx >/dev/null 2>&1 || return 1 ;;
        dnf) dnf install -y nginx >/dev/null 2>&1 || return 1 ;;
        yum) yum install -y nginx >/dev/null 2>&1 || return 1 ;;
        *) error "无法自动安装 nginx，请手动安装后重新进入“查看节点”。"; return 1 ;;
    esac
    success "nginx 安装成功。"
}

ensure_nginx_installed() {
    if command_exists nginx; then return 0; fi
    info "未检测到 nginx，正在为订阅服务安装 nginx..."
    install_nginx_for_subscription || {
        error "nginx 安装失败，无法继续。"
        return 1
    }
    return 0
}

configure_subscription_nginx() {
    local port="$1" token="$2"
    install_nginx_for_subscription || {
        error "nginx 安装失败，无法开启订阅服务。"
        return 1
    }
    mkdir -p /etc/nginx/conf.d
    if [ -f "$SUB_NGINX_CONF" ]; then
        cp -a "$SUB_NGINX_CONF" "${SUB_NGINX_CONF}.bak.sb" 2>/dev/null || true
    fi
    cat > "$SUB_NGINX_CONF" <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /${token} {
        alias ${SUB_FILE};
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / { return 404; }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
    if ! nginx -t >/dev/null 2>&1; then
        error "nginx 配置检查失败。"
        nginx -t 2>&1 | tail -n 20
        return 1
    fi
    case "$(service_mode)" in
        systemd)
            systemctl enable nginx >/dev/null 2>&1 || true
            systemctl restart nginx >/dev/null 2>&1 ||
                systemctl start nginx >/dev/null 2>&1 || return 1
            ;;
        openrc)
            rc-update add nginx default >/dev/null 2>&1 || true
            rc-service nginx restart >/dev/null 2>&1 ||
                rc-service nginx start >/dev/null 2>&1 || return 1
            ;;
        manual)
            nginx -s reload >/dev/null 2>&1 || nginx >/dev/null 2>&1 || return 1
            ;;
    esac
    allow_port "$port" tcp
    return 0
}

generate_subscription_file() {
    ensure_config >/dev/null 2>&1 || return 1

    ensure_runtime_dirs

    local config_source
    config_source="$(get_config_source)"

    local count
    count="$(jq '.inbounds | length' "$config_source" 2>/dev/null)"

    if [ -z "$count" ] || [ "$count" = "null" ]; then
        return 1
    fi

    : > "$SUB_FILE"

    local i=0
    local link
    local status

    while [ "$i" -lt "$count" ]; do
        link="$(generate_node_link "$i" 2>/dev/null)"
        status=$?

        if [ "$status" -eq 0 ] && [ -n "$link" ]; then
            printf '%s\n' "$link" |
                grep -E '^(vless|vmess|hysteria2|tuic|socks5)://' >> "$SUB_FILE" 2>/dev/null || true
        fi

        i=$((i + 1))
    done

    if [ ! -s "$SUB_FILE" ]; then
        rm -f "$SUB_FILE"
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    if ! base64_noline < "$SUB_FILE" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$SUB_FILE"
    chmod 644 "$SUB_FILE"
    return 0
}

# ============================================================
# 打印订阅信息（供多个入口复用）
# ============================================================

print_subscription_info() {
    load_server_ip

    local sub_port sub_token
    sub_port="$(get_subscription_port)"
    sub_token="$(get_subscription_token)"

    if [ -z "$sub_port" ] || [ -z "$sub_token" ]; then
        warn "订阅信息尚未初始化，请先进入“查看节点”创建订阅。"
        return 1
    fi

    local sub_url="http://${SERVER_IP}:${sub_port}/${sub_token}"
    local singbox_url="https://sublink.eooce.com/singbox?config=$(url_encode "$sub_url")"

    echo
    echo -e "${GREEN}========== 一键订阅 ==========${NC}"
    echo
    echo -e "${CYAN}通用订阅链接：${NC}${sub_url}"
    echo
    echo -e "${CYAN}Sing-box 订阅链接：${NC}${singbox_url}"
    echo
    echo -e "${YELLOW}订阅文件：${NC}${SUB_FILE}"
    echo -e "${YELLOW}订阅端口：${NC}${sub_port}"
    echo
}

setup_subscription_service() {
    load_server_ip

    if [ "$SERVER_IP_VERSION" = "unknown" ] || [ "$SERVER_IP" = "你的服务器IP" ]; then
        warn "无法获取公网 IP，暂时无法生成一键订阅链接。"
        return 1
    fi

    SUB_PORT="$(get_subscription_port)"
    SUB_TOKEN="$(get_subscription_token)"

    if ! [[ "$SUB_PORT" =~ ^[0-9]+$ ]] || [ "$SUB_PORT" -lt 1 ] || [ "$SUB_PORT" -gt 65535 ]; then
        SUB_PORT=""
    fi

    if [ -z "$SUB_TOKEN" ] || ! [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
        SUB_TOKEN="$(openssl rand -hex 16)"
    fi

    [ -n "$SUB_PORT" ] || SUB_PORT="$(pick_subscription_port)"

    save_subscription_state "$SUB_PORT" "$SUB_TOKEN" >/dev/null 2>&1 || true

    if ! generate_subscription_file; then
        warn "没有生成有效的订阅内容（可能是所有节点的 public_key 尚未就绪）。"
    fi

    configure_subscription_nginx "$SUB_PORT" "$SUB_TOKEN" || return 1

    print_subscription_info
}

refresh_subscription() {
    local sub_port sub_token
    sub_port="$(get_subscription_port)"
    sub_token="$(get_subscription_token)"

    if [ -z "$sub_port" ] || [ -z "$sub_token" ] || [ ! -f "$SUB_NGINX_CONF" ]; then
        setup_subscription_service || {
            warn "订阅服务尚未创建，无法自动刷新。可进入“查看节点”手动创建。"
            return 1
        }
    else
        if ! generate_subscription_file; then
            warn "订阅文件刷新失败，请检查节点配置。"
        fi

        if command_exists nginx && nginx -t >/dev/null 2>&1; then
            case "$(service_mode)" in
                systemd) systemctl reload nginx >/dev/null 2>&1 || true ;;
                openrc) rc-service nginx reload >/dev/null 2>&1 || true ;;
                manual) nginx -s reload >/dev/null 2>&1 || true ;;
            esac
        fi

        print_subscription_info
    fi
}

# ============================================================
# 生成单个节点链接
# ============================================================

generate_node_link() {
    local index="$1"
    ensure_config >/dev/null 2>&1 || return 1

    local config_source
    config_source="$(get_config_source)"

    load_node_geo

    local type tag port uuid flow sni public_key password username short_id

    type="$(jq -r ".inbounds[$index].type // \"\"" "$config_source" 2>/dev/null)"
    tag="$(jq -r ".inbounds[$index].tag // \"\"" "$config_source" 2>/dev/null)"
    port="$(jq -r ".inbounds[$index].listen_port // \"\"" "$config_source" 2>/dev/null)"

    load_server_ip

    case "$type" in
        vless)
            uuid="$(jq -r ".inbounds[$index].users[0].uuid // empty" "$config_source" 2>/dev/null)"
            flow="$(jq -r ".inbounds[$index].users[0].flow // empty" "$config_source" 2>/dev/null)"
            sni="$(jq -r ".inbounds[$index].tls.server_name // empty" "$config_source" 2>/dev/null)"

            public_key="$(jq -r --arg tag "$tag" '.vless_nodes[$tag].public_key // empty' "$STATE_FILE" 2>/dev/null)"
            short_id="$(jq -r --arg tag "$tag" '.vless_nodes[$tag].short_id // empty' "$STATE_FILE" 2>/dev/null)"

            # 自愈：state.json 缺 public_key 时从 inbound 反推
            if [ -z "$public_key" ] || [ "$public_key" = "null" ]; then
                local _pk_inbound
                _pk_inbound="$(jq -r ".inbounds[$index].tls.reality.private_key // empty" "$config_source" 2>/dev/null)"
                if [ -n "$_pk_inbound" ]; then
                    warn "检测到 $tag 缺失 public_key，正在自动推导..." >&2
                    public_key="$(derive_reality_public_key "$_pk_inbound")"
                    if [ -n "$public_key" ]; then
                        if save_vless_state "$tag" "$uuid" "$public_key" "$sni" "$port" "$short_id" >/dev/null 2>&1; then
                            success "已自动补全 state.json：$tag" >&2
                        fi
                    fi
                fi
            fi

            if [ -z "$public_key" ] || [ "$public_key" = "null" ]; then
                echo -e "${RED}无法生成 VLESS Reality 链接。${NC}" >&2
                echo "原因：state.json 缺失 public_key，且无法从 inbound 反推。" >&2
                return 2
            fi

            [ -z "$flow" ] && flow="xtls-rprx-vision"
            [ -z "$sni" ] && sni="www.microsoft.com"

            local vless_alias
            vless_alias="${_NODE_ALIAS_COUNTRY}-${_NODE_ALIAS_ISP}_VLESS"

            echo "vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${vless_alias}"
            ;;

        vmess)
            uuid="$(jq -r ".inbounds[$index].users[0].uuid // empty" "$config_source" 2>/dev/null)"

            local path
            path="$(jq -r ".inbounds[$index].transport.path // \"/vmess-argo\"" "$config_source" 2>/dev/null)"

            local fixed_tag
            fixed_tag="$(jq -r '.fixed_vmess.tag // empty' "$STATE_FILE" 2>/dev/null)"

            local domain="" client_domain="" preferred
            if [ "$tag" = "$fixed_tag" ]; then
                domain="$(jq -r '.fixed_vmess.domain // empty' "$STATE_FILE" 2>/dev/null)"
                client_domain="$domain"
                preferred="$(get_preferred_domain)"
                [ -n "$preferred" ] && client_domain="$preferred"
            else
                domain="$(get_temp_argo_domain "$tag")"
                client_domain="$domain"
                preferred="$(get_preferred_domain)"
                [ -n "$preferred" ] && client_domain="$preferred"
            fi

            if [ -z "$domain" ]; then
                echo -e "${RED}无法获取 VMess Argo 域名。${NC}" >&2
                return 1
            fi

            [ -z "$client_domain" ] && client_domain="$domain"

            case "$path" in
                *\?*) ;;
                *) path="${path}?ed=2560" ;;
            esac

            local vmess_alias
            vmess_alias="${_NODE_ALIAS_COUNTRY}-${_NODE_ALIAS_ISP}_VMess"

            local vmess_json
            vmess_json="$(
                jq -n \
                    --arg add "$client_domain" \
                    --arg host "$domain" \
                    --arg sni "$domain" \
                    --arg uuid "$uuid" \
                    --arg path "$path" \
                    --arg ps "$vmess_alias" \
                '{
                    v: "2",
                    ps: $ps,
                    add: $add,
                    port: "443",
                    id: $uuid,
                    aid: "0",
                    scy: "none",
                    net: "ws",
                    type: "none",
                    host: $host,
                    path: $path,
                    tls: "tls",
                    sni: $sni,
                    alpn: "",
                    fp: "firefox",
                    allowInsecure: "false"
                }'
            )"

            echo "vmess://$(printf '%s' "$vmess_json" | base64_noline)"
            ;;

        tuic)
            uuid="$(jq -r ".inbounds[$index].users[0].uuid // empty" "$config_source" 2>/dev/null)"
            password="$(jq -r ".inbounds[$index].users[0].password // empty" "$config_source" 2>/dev/null)"

            local tuic_alias
            tuic_alias="${_NODE_ALIAS_COUNTRY}-${_NODE_ALIAS_ISP}_TUIC"

            echo "tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${tuic_alias}"
            ;;

        hysteria2)
            password="$(jq -r ".inbounds[$index].users[0].password // empty" "$config_source" 2>/dev/null)"

            local cert
            cert="$(jq -r ".inbounds[$index].tls.certificate_path // empty" "$config_source" 2>/dev/null)"

            local fingerprint=""
            if [ -n "$cert" ] && [ -f "$cert" ]; then
                fingerprint="$(get_hysteria_pin_encoded "$cert")"
            fi

            local hy2_alias
            hy2_alias="${_NODE_ALIAS_COUNTRY}-${_NODE_ALIAS_ISP}_Hysteria2"

            if [ -n "$fingerprint" ]; then
                echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3#${hy2_alias}"
            else
                echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&alpn=h3#${hy2_alias}"
            fi
            ;;

        socks)
            username="$(jq -r ".inbounds[$index].users[0].username // empty" "$config_source" 2>/dev/null)"
            password="$(jq -r ".inbounds[$index].users[0].password // empty" "$config_source" 2>/dev/null)"

            local socks_alias
            socks_alias="${_NODE_ALIAS_COUNTRY}-${_NODE_ALIAS_ISP}_Socks5"

            echo "socks5://${username}:${password}@${SERVER_IP}:${port}#${socks_alias}"
            ;;

        *)
            echo "暂不支持自动生成 ${type} 客户端链接。" >&2
            ;;
    esac
}

# ============================================================
# 查看所有节点
# ============================================================

show_nodes() {
    clear
    echo -e "${GREEN}========== 当前 sing-box 节点 ==========${NC}"
    echo
    ensure_config || { pause; return; }
    echo -e "${CYAN}配置来源：${NC}"
    if [ "$CONFIG_MODE" = "directory" ]; then echo "$INBOUNDS_FILE"; else echo "$CONFIG_FILE"; fi
    echo
    local config_source
    config_source="$(get_config_source)"
    local count
    count="$(jq '.inbounds | length' "$config_source" 2>/dev/null)"
    if [ -z "$count" ] || [ "$count" = "0" ] || [ "$count" = "null" ]; then
        warn "当前没有检测到 inbound 节点。"
        pause
        return
    fi
    load_server_ip
    echo -e "${CYAN}服务器地址：${NC}${SERVER_IP} (${SERVER_IP_VERSION})"
    echo
    local i=0
    while [ "$i" -lt "$count" ]; do
        local type tag listen port user_count
        type="$(jq -r ".inbounds[$i].type // \"unknown\"" "$config_source")"
        tag="$(jq -r ".inbounds[$i].tag // \"\"" "$config_source")"
        listen="$(jq -r ".inbounds[$i].listen // \"\"" "$config_source")"
        port="$(jq -r ".inbounds[$i].listen_port // \"\"" "$config_source")"
        user_count="$(jq -r ".inbounds[$i].users // [] | length" "$config_source")"
        echo -e "${YELLOW}[$((i + 1))]${NC}"
        echo "类型：${type}"
        echo "标签：${tag}"
        echo "监听：${listen}"
        echo "端口：${port}"
        echo "用户数：${user_count}"
        echo
        echo -e "${GREEN}客户端链接：${NC}"
        local link_output
        link_output="$(generate_node_link "$i" 2>&1)"
        local link_status=$?
        if [ "$link_status" -eq 0 ] || [ "$link_status" -eq 2 ]; then
            echo "$link_output"
        else
            echo -e "${RED}${link_output}${NC}"
        fi
        echo
        echo "========================================"
        i=$((i + 1))
    done
    echo
    setup_subscription_service || true
    echo -e "${GREEN}检测结果：${count} 个 inbound${NC}"
    echo
    pause
}

# ============================================================
# 节点卸载
# ============================================================

uninstall_node() {
    clear
    echo -e "${GREEN}========== 节点卸载 ==========${NC}"
    echo
    ensure_config || { pause; return; }
    local config_source
    config_source="$(get_config_source)"
    local count
    count="$(jq '.inbounds | length' "$config_source")"
    if [ -z "$count" ] || [ "$count" = "0" ]; then
        warn "没有可卸载的节点。"
        pause
        return
    fi
    local i=0
    while [ "$i" -lt "$count" ]; do
        local type tag port
        type="$(jq -r ".inbounds[$i].type // \"unknown\"" "$config_source")"
        tag="$(jq -r ".inbounds[$i].tag // \"\"" "$config_source")"
        port="$(jq -r ".inbounds[$i].listen_port // \"\"" "$config_source")"
        echo "$((i + 1)). ${type} | ${tag} | ${port}"
        i=$((i + 1))
    done
    echo
    echo "提示：可一次删除多个节点，用空格分隔，例如：1 2 3"
    read -r -p "请输入要卸载的编号（输入 0 返回）： " choices
    [ -z "$choices" ] && return
    [ "$choices" = "0" ] && return

    local -a idx_list=()
    local -a tag_list=()
    local -a type_list=()
    local -a seen_idx=()

    local item
    for item in $choices; do
        if ! [[ "$item" =~ ^[0-9]+$ ]]; then
            error "无效编号：$item"
            pause
            return
        fi
        if [ "$item" -lt 1 ] || [ "$item" -gt "$count" ]; then
            error "编号超出范围：$item"
            pause
            return
        fi
        local idx=$((item - 1))
        local dup=0 s
        for s in "${seen_idx[@]}"; do
            if [ "$s" = "$idx" ]; then dup=1; break; fi
        done
        [ "$dup" = "1" ] && continue
        seen_idx+=("$idx")
        local tag type
        tag="$(jq -r ".inbounds[$idx].tag // empty" "$config_source")"
        type="$(jq -r ".inbounds[$idx].type // empty" "$config_source")"
        if [ -z "$tag" ]; then
            error "第 $item 个节点没有 tag，无法安全删除。"
            pause
            return
        fi
        idx_list+=("$idx")
        tag_list+=("$tag")
        type_list+=("$type")
    done

    if [ "${#tag_list[@]}" -eq 0 ]; then
        warn "没有有效的编号。"
        pause
        return
    fi

    echo
    warn "准备删除以下 ${#tag_list[@]} 个节点："
    local k
    for k in "${!tag_list[@]}"; do
        echo "  - ${type_list[$k]} | ${tag_list[$k]}"
    done
    echo
    read -r -p "确认删除？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "已取消。"; pause; return; }

    backup_config_once

    local fixed_tag
    fixed_tag="$(jq -r '.fixed_vmess.tag // empty' "$STATE_FILE" 2>/dev/null)"

    local fail=0
    for k in "${!tag_list[@]}"; do
        local t="${tag_list[$k]}"
        local ty="${type_list[$k]}"
        if ! remove_inbound_by_tag "$t"; then
            error "删除失败：$t"
            fail=1
            continue
        fi
        if [ "$ty" = "vless" ]; then
            remove_vless_state "$t"
        fi
        if [ "$ty" = "vmess" ]; then
            stop_temp_argo "$t"
            rm -f "$(temp_argo_log "$t")"
        fi
        if [ "$t" = "$fixed_tag" ]; then
            stop_fixed_argo
            ensure_state_file
            jq '
                .fixed_vmess = {
                    tag: "",
                    domain: "",
                    key: "",
                    port: 0,
                    uuid: ""
                }
            ' \
                "$STATE_FILE" > "${STATE_FILE}.tmp" &&
                mv "${STATE_FILE}.tmp" "$STATE_FILE"
            chmod 600 "$STATE_FILE"
        fi
        success "已删除节点：$t"
    done

    if check_config >/dev/null 2>&1; then
        restart_singbox
        refresh_subscription
        if [ "$fail" = "0" ]; then
            success "所选节点已全部卸载。"
        else
            warn "部分节点卸载失败，请检查配置。"
        fi
    else
        error "删除后配置检查失败，请检查 sing-box 配置。"
    fi
    pause
}

# ============================================================
# sing-box 完全卸载
# ============================================================

uninstall_singbox() {
    clear
    echo -e "${RED}========== sing-box 完全卸载 ==========${NC}"
    echo
    warn "此操作将删除："
    echo "  - sing-box 二进制及全部配置"
    echo "  - /etc/sing-box 目录（含证书、状态、日志、备份）"
    echo "  - systemd / OpenRC 服务文件"
    echo "  - cloudflared 固定 Argo 服务"
    echo "  - 所有手动启动的 sing-box / cloudflared 进程"
    echo
    warn "BBR + FQ 内核参数不会被删除。"
    echo
    read -r -p "确认完全卸载 sing-box？输入 yes 继续： " confirm
    if [ "$confirm" != "yes" ]; then
        warn "已取消。"
        pause
        return
    fi
    echo
    info "正在停止相关服务..."
    if command_exists systemctl; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        systemctl disable sing-box >/dev/null 2>&1 || true
        systemctl stop cloudflared-singbox >/dev/null 2>&1 || true
        systemctl disable cloudflared-singbox >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        rm -f /etc/systemd/system/cloudflared-singbox.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    fi
    if command_exists rc-service; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-service cloudflared-singbox stop >/dev/null 2>&1 || true
    fi
    if command_exists rc-update; then
        rc-update del sing-box default >/dev/null 2>&1 || true
        rc-update del cloudflared-singbox default >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/sing-box
    rm -f /etc/init.d/cloudflared-singbox

    info "正在结束残留进程..."
    local pidfile p
    for pidfile in \
        "${PID_DIR}/sing-box.pid" \
        "${PID_DIR}/fixed-argo.pid" \
        "${PID_DIR}"/argo-*.pid
    do
        [ -f "$pidfile" ] || continue
        p="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$p" ] && kill "$p" >/dev/null 2>&1 || true
    done
    pkill -f "${SB_BIN}" >/dev/null 2>&1 || true
    pkill -f "${SB_DIR}/cloudflared" >/dev/null 2>&1 || true
    rm -f /run/sing-box.pid
    rm -f /run/cloudflared-singbox.pid

    info "正在清理 nginx 订阅相关残留..."
    rm -f "$SUB_NGINX_CONF"
    rm -f "${SUB_NGINX_CONF}.bak.sb"
    if command_exists nginx; then
        nginx -t >/dev/null 2>&1 && {
            case "$(service_mode)" in
                systemd) systemctl reload nginx >/dev/null 2>&1 || true ;;
                openrc) rc-service nginx reload >/dev/null 2>&1 || true ;;
                manual) nginx -s reload >/dev/null 2>&1 || true ;;
            esac
        }
    fi

    info "正在删除 ${SB_DIR} ..."
    rm -rf "$SB_DIR"
    hash -r 2>/dev/null || true

    echo
    read -r -p "是否一并彻底卸载 nginx？（仅当本机 nginx 只用于本脚本订阅服务时）[y/N]: " uninstall_nginx_confirm
    if [[ "$uninstall_nginx_confirm" =~ ^[Yy]$ ]]; then
        info "正在彻底卸载 nginx..."
        if command_exists systemctl; then
            systemctl stop nginx >/dev/null 2>&1 || true
            systemctl disable nginx >/dev/null 2>&1 || true
        fi
        if command_exists rc-service; then
            rc-service nginx stop >/dev/null 2>&1 || true
        fi
        if command_exists rc-update; then
            rc-update del nginx default >/dev/null 2>&1 || true
        fi
        pkill -9 -f nginx >/dev/null 2>&1 || true
        case "$PKG" in
            apt)
                DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common nginx-core >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
                ;;
            apk) apk del nginx >/dev/null 2>&1 || true ;;
            dnf|yum) $PKG remove -y nginx >/dev/null 2>&1 || true ;;
        esac
        rm -rf /etc/nginx /var/log/nginx /var/lib/nginx /var/cache/nginx
        rm -f  /run/nginx.pid
        rm -f  /etc/logrotate.d/nginx
        rm -f  /etc/cron.d/nginx
        rm -f  /etc/init.d/nginx
        rm -f  /lib/systemd/system/nginx.service
        rm -f  /etc/systemd/system/nginx.service
        if command_exists systemctl; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        success "nginx 已彻底卸载。"
    else
        info "已保留 nginx 安装，仅删除本脚本订阅配置。"
    fi

    echo
    success "sing-box 已完全卸载。"
    echo
    echo "提示："
    echo "  - BBR + FQ 内核参数保留在 /etc/sysctl.d/99-bbr-fq.conf"
    echo "  - 如需删除请执行："
    echo "      rm -f /etc/sysctl.d/99-bbr-fq.conf && sysctl --system"
    echo
    pause
}

# ============================================================
# BBR + FQ
# ============================================================

bbr_fq() {
    clear
    echo -e "${GREEN}========== BBR + FQ 加速 ==========${NC}"
    echo
    cat > /etc/sysctl.d/99-bbr-fq.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    if ! sysctl --system >/dev/null 2>&1; then
        warn "sysctl --system 执行失败。"
        warn "当前环境可能是容器，无法修改宿主机内核参数。"
    fi
    local qdisc congestion
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo
    echo "当前队列算法：$qdisc"
    echo "当前 TCP 拥塞控制：$congestion"
    echo
    if [ "$qdisc" = "fq" ] && [ "$congestion" = "bbr" ]; then
        success "BBR + FQ 已生效。"
    else
        warn "当前环境没有成功应用 BBR + FQ。"
        warn "如果这是 Docker/LXC 容器，需要在宿主机内核启用 BBR + FQ。"
    fi
    pause
}

# ============================================================
# 节点安装菜单
# ============================================================

node_install_menu() {
    while true; do
        clear
        echo -e "${CYAN}========== sing-box 节点管理 ==========${NC}"
        echo
        echo -e " 1.${YELLOW} VLESS 安装${NC}"
        echo -e " 2.${YELLOW} VMess 安装${NC}"
        echo -e " 3.${YELLOW} TUIC 安装${NC}"
        echo -e " 4.${YELLOW} Hysteria2 安装${NC}"
        echo -e " 5.${YELLOW} Socks5 安装${NC}"
        echo -e " 6.${YELLOW} 节点卸载${NC}"
        echo -e " 7.${YELLOW} 查看节点${NC}"
        echo -e " 0.${YELLOW} 返回${NC}"
        echo
        read -p "$(echo -e "${BLUE}*  ${CYAN}请选择 [0-7]: ${NC}: ")" choice
        case "$choice" in
            1) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; install_vless; pause_unless_cancelled ;;
            2) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; vmess_menu ;;
            3) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; install_tuic; pause_unless_cancelled ;;
            4) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; install_hysteria2; pause_unless_cancelled ;;
            5) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; install_socks5; pause_unless_cancelled ;;
            6) uninstall_node ;;
            7) show_nodes ;;
            0) return ;;
            *) printf "${RED} 无效选项,按任意键重新输入...${NC}"; read -n 1 -s -r ;;
        esac
    done
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${NC}"
        echo -e "${CYAN}       sing-box 安装管理${NC}"
        echo -e "${BLUE}======================================${NC}"
        echo
        echo -e "1.${YELLOW} sing-box 节点管理${NC}"
        echo -e "2.${YELLOW} BBR + FQ 加速${NC}"
        echo -e "3.${YELLOW} sing-box 卸载${NC}"
        echo -e "0.${YELLOW} 退出${NC}"
        echo
        read -p "$(echo -e "${BLUE}*  ${CYAN}请选择 [0-3]: ${NC}: ")" choice
        case "$choice" in
            1) node_install_menu ;;
            2) bbr_fq ;;
            3) uninstall_singbox ;;
            0) clear; exit 0 ;;
            *) printf "${RED} 无效选项,按任意键重新输入...${NC}"; read -n 1 -s -r ;;
        esac
    done
}

# ============================================================
# 初始化
# ============================================================

check_root
detect_os
install_dependencies || exit 1
init_dirs
if [ -x "$SB_BIN" ]; then
    detect_config >/dev/null 2>&1 || true
fi
main_menu
