#!/bin/bash

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# -----------------------------
# 基础目录
# -----------------------------

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

CONFIG_MODE=""

# -----------------------------
# 颜色
# -----------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

info() {
    echo -e "${CYAN}$*${NC}"
}

success() {
    echo -e "${GREEN}$*${NC}"
}

warn() {
    echo -e "${YELLOW}$*${NC}"
}

error() {
    echo -e "${RED}$*${NC}"
}

pause() {
    echo
    read -r -p "按回车继续..." _
}

# 只有在没有被取消的情况下才 pause
pause_unless_cancelled() {
    if [ "${CANCELLED:-0}" = "1" ]; then
        CANCELLED=0
        return
    fi
    pause
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

base64_noline() {
    base64 -w0 2>/dev/null || base64 2>/dev/null | tr -d '\n'
}


# ============================================================
# Root 检查
# ============================================================

check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行此脚本。"
        exit 1
    fi
}


# ============================================================
# 系统检测
# ============================================================

detect_os() {
    OS="unknown"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID:-unknown}"
    fi

    if command_exists apk; then
        PKG="apk"
    elif command_exists apt-get; then
        PKG="apt"
    elif command_exists dnf; then
        PKG="dnf"
    elif command_exists yum; then
        PKG="yum"
    else
        PKG=""
    fi
}


# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    local missing=()

    command_exists curl || missing+=("curl")
    command_exists jq || missing+=("jq")
    command_exists tar || missing+=("tar")
    command_exists openssl || missing+=("openssl")
    command_exists shuf || missing+=("coreutils")
    command_exists ip || missing+=("ip")
    command_exists ss || missing+=("ss")

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    info "正在安装必要依赖..."

    case "$PKG" in

        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y

            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl \
                jq \
                tar \
                openssl \
                coreutils \
                ca-certificates \
                iproute2
            ;;

        apk)
            apk add \
                curl \
                jq \
                tar \
                openssl \
                coreutils \
                ca-certificates \
                iproute2
            ;;

        dnf)
            dnf install -y \
                curl \
                jq \
                tar \
                openssl \
                coreutils \
                ca-certificates \
                iproute
            ;;

        yum)
            yum install -y \
                curl \
                jq \
                tar \
                openssl \
                coreutils \
                ca-certificates \
                iproute
            ;;

        *)
            error "无法自动安装依赖。"
            return 1
            ;;
    esac
}


# ============================================================
# 初始化目录
# ============================================================

init_dirs() {

    mkdir -p \
        "$SB_DIR" \
        "$MANAGER_DIR" \
        "$PID_DIR" \
        "$LOG_DIR"

    chmod 700 "$MANAGER_DIR"
    chmod 700 "$PID_DIR"

    if [ ! -f "$STATE_FILE" ]; then

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

        chmod 600 "$STATE_FILE"

    else

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
    fi
}


# ============================================================
# 架构检测
# ============================================================

detect_arch() {

    local raw
    raw="$(uname -m)"

    case "$raw" in
        x86_64|amd64)
            ARCH="amd64"
            ;;

        i386|i686|x86)
            ARCH="386"
            ;;

        aarch64|arm64)
            ARCH="arm64"
            ;;

        armv7l|armv7)
            ARCH="armv7"
            ;;

        s390x)
            ARCH="s390x"
            ;;

        *)
            error "不支持的 CPU 架构：$raw"
            return 1
            ;;
    esac

    return 0
}


# ============================================================
# 获取 sing-box 最新版本
# ============================================================

get_latest_singbox_version() {

    local version

    version="$(
        curl -fsSL \
            --connect-timeout 10 \
            --max-time 30 \
            "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30" |
        jq -r '
            [
                .[]
                | select(.draft == false)
                | select(.prerelease == false)
                | .tag_name
            ][0]
        ' 2>/dev/null
    )"

    version="${version#v}"

    if [ -z "$version" ] || [ "$version" = "null" ]; then
        return 1
    fi

    echo "$version"
}


# ============================================================
# 下载 sing-box
# ============================================================

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

    if ! curl -fL \
        --connect-timeout 15 \
        --max-time 300 \
        --retry 3 \
        --retry-delay 2 \
        "$url" \
        -o "${tmp}/sing-box.tar.gz"; then

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

    binary="$(
        find "$tmp" \
            -type f \
            -name "sing-box" \
            -perm -u+x |
        head -n 1
    )"

    if [ -z "$binary" ]; then
        error "解压后没有找到 sing-box 二进制文件。"
        rm -rf "$tmp"
        return 1
    fi

    install -Dm755 "$binary" "$SB_BIN"

    rm -rf "$tmp"

    if ! "$SB_BIN" version >/dev/null 2>&1; then
        error "sing-box 安装后验证失败。"
        return 1
    fi

    success "sing-box v${version} 安装成功。"

    return 0
}


# ============================================================
# 下载 cloudflared
# ============================================================

download_cloudflared() {

    detect_arch || return 1

    local cf_arch

    case "$ARCH" in
        amd64)
            cf_arch="amd64"
            ;;

        arm64)
            cf_arch="arm64"
            ;;

        armv7)
            cf_arch="arm"
            ;;

        386)
            cf_arch="386"
            ;;

        s390x)
            cf_arch="s390x"
            ;;

        *)
            error "cloudflared 不支持当前架构：$ARCH"
            return 1
            ;;
    esac

    local url
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"

    info "正在下载 Cloudflare cloudflared..."

    if ! curl -fL \
        --connect-timeout 15 \
        --max-time 300 \
        --retry 3 \
        --retry-delay 2 \
        "$url" \
        -o "$ARGO_BIN"; then

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


# ============================================================
# 判断当前 sing-box 服务使用什么配置
# ============================================================

detect_config() {

    CONFIG_MODE=""

    if command_exists systemctl; then

        local exec_line

        exec_line="$(
            systemctl cat sing-box.service 2>/dev/null |
            grep -E '^[[:space:]]*ExecStart=' |
            tail -n 1
        )"

        if echo "$exec_line" | grep -q -- '-C '; then

            local cdir

            cdir="$(
                echo "$exec_line" |
                sed -n 's/.*-C[[:space:]]\+\([^[:space:]]\+\).*/\1/p'
            )"

            if [ -d "$cdir" ] && [ -f "$cdir/inbounds.json" ]; then

                CONFIG_MODE="directory"
                CONFIG_DIR="$cdir"
                INBOUNDS_FILE="$cdir/inbounds.json"

                return 0
            fi
        fi

        if echo "$exec_line" | grep -qE '(-c|--config)'; then

            local cfile

            cfile="$(
                echo "$exec_line" |
                sed -nE 's/.*(-c|--config)[[:space:]]+([^[:space:]]+).*/\2/p'
            )"

            if [ -f "$cfile" ]; then

                CONFIG_MODE="file"
                CONFIG_FILE="$cfile"

                return 0
            fi
        fi
    fi

    if [ -f "/etc/sing-box/conf/inbounds.json" ]; then

        CONFIG_MODE="directory"
        CONFIG_DIR="/etc/sing-box/conf"
        INBOUNDS_FILE="/etc/sing-box/conf/inbounds.json"

        return 0
    fi

    if [ -f "/etc/sing-box/config.json" ]; then

        CONFIG_MODE="file"
        CONFIG_FILE="/etc/sing-box/config.json"

        return 0
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


# ============================================================
# 获取 sing-box 执行参数
# ============================================================

get_exec_args() {

    if [ "$CONFIG_MODE" = "directory" ]; then
        echo "run -C ${CONFIG_DIR}"
    else
        echo "run -c ${CONFIG_FILE}"
    fi
}


# ============================================================
# 确保配置存在
# ============================================================

ensure_config() {

    detect_config

    if [ "$CONFIG_MODE" = "directory" ]; then

        mkdir -p "$CONFIG_DIR"

        if [ ! -f "$INBOUNDS_FILE" ]; then
            echo '{"inbounds":[]}' > "$INBOUNDS_FILE"
        fi

        if ! jq empty "$INBOUNDS_FILE" >/dev/null 2>&1; then
            error "当前 inbounds.json 不是有效 JSON："
            error "$INBOUNDS_FILE"
            return 1
        fi

        if ! jq -e '.inbounds and (.inbounds | type == "array")' \
            "$INBOUNDS_FILE" >/dev/null 2>&1; then

            error "当前 inbounds.json 没有有效的 inbounds 数组。"
            return 1
        fi

    elif [ "$CONFIG_MODE" = "file" ]; then

        if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
            error "当前 config.json 不是有效 JSON："
            error "$CONFIG_FILE"
            return 1
        fi

        if ! jq -e '.inbounds and (.inbounds | type == "array")' \
            "$CONFIG_FILE" >/dev/null 2>&1; then

            error "当前 config.json 没有有效的 inbounds 数组。"
            return 1
        fi
    fi

    return 0
}


# ============================================================
# 更新 inbounds
# ============================================================

update_inbounds() {

    local expression="$1"

    ensure_config || return 1

    local tmp
    tmp="$(mktemp)"

    if [ "$CONFIG_MODE" = "directory" ]; then

        if ! jq "$expression" "$INBOUNDS_FILE" > "$tmp"; then
            rm -f "$tmp"
            error "修改 inbounds 失败。"
            return 1
        fi

        mv "$tmp" "$INBOUNDS_FILE"

    else

        if ! jq "$expression" "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            error "修改 config.json 失败。"
            return 1
        fi

        mv "$tmp" "$CONFIG_FILE"
    fi

    return 0
}


# ============================================================
# 备份配置
# ============================================================

backup_config_once() {

    ensure_config >/dev/null 2>&1 || return 0

    local backup_dir="${SB_DIR}/backup"

    mkdir -p "$backup_dir"

    local stamp
    stamp="$(date '+%Y%m%d-%H%M%S')"

    if [ "$CONFIG_MODE" = "directory" ]; then

        if [ -f "$INBOUNDS_FILE" ]; then
            cp -a "$INBOUNDS_FILE" \
                "${backup_dir}/inbounds-${stamp}.json"
        fi

    elif [ "$CONFIG_MODE" = "file" ]; then

        if [ -f "$CONFIG_FILE" ]; then
            cp -a "$CONFIG_FILE" \
                "${backup_dir}/config-${stamp}.json"
        fi
    fi

    ls -1t "$backup_dir"/* 2>/dev/null |
        tail -n +6 |
        xargs -r rm -f
}


# ============================================================
# 服务模式
# ============================================================

service_mode() {

    if command_exists systemctl &&
       [ -d /run/systemd/system ]; then

        echo "systemd"
        return
    fi

    if command_exists rc-service; then
        echo "openrc"
        return
    fi

    echo "manual"
}


# ============================================================
# 创建 systemd 服务
# ============================================================

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


# ============================================================
# 创建 OpenRC 服务
# ============================================================

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


# ============================================================
# 启动 sing-box
# ============================================================

start_singbox() {

    ensure_config >/dev/null 2>&1 || return 1

    local mode
    mode="$(service_mode)"

    case "$mode" in

        systemd)

            create_systemd_service

            systemctl restart sing-box

            sleep 1

            if systemctl is-active --quiet sing-box; then
                success "sing-box 已启动。"
                return 0
            fi

            error "sing-box 启动失败。"

            systemctl --no-pager --full status sing-box 2>/dev/null |
                tail -n 20

            return 1
            ;;

        openrc)

            create_openrc_service

            rc-service sing-box restart >/dev/null 2>&1 ||
                rc-service sing-box start >/dev/null 2>&1

            sleep 1

            if rc-service sing-box status >/dev/null 2>&1; then
                success "sing-box 已启动。"
                return 0
            fi

            error "sing-box 启动失败。"
            return 1
            ;;

        manual)

            stop_manual_singbox

            if [ "$CONFIG_MODE" = "directory" ]; then

                nohup "$SB_BIN" run -C "$CONFIG_DIR" \
                    > "${LOG_DIR}/sing-box.log" 2>&1 &

            else

                nohup "$SB_BIN" run -c "$CONFIG_FILE" \
                    > "${LOG_DIR}/sing-box.log" 2>&1 &
            fi

            echo $! > "${PID_DIR}/sing-box.pid"

            sleep 1

            if kill -0 "$(cat "${PID_DIR}/sing-box.pid")" 2>/dev/null; then
                success "sing-box 已启动。"
                return 0
            fi

            error "sing-box 启动失败。"

            tail -n 30 "${LOG_DIR}/sing-box.log" 2>/dev/null

            return 1
            ;;
    esac
}


# ============================================================
# 停止手动 sing-box
# ============================================================

stop_manual_singbox() {

    if [ -f "${PID_DIR}/sing-box.pid" ]; then

        local pid
        pid="$(cat "${PID_DIR}/sing-box.pid" 2>/dev/null)"

        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi

        rm -f "${PID_DIR}/sing-box.pid"
    fi
}


# ============================================================
# 重启 sing-box
# ============================================================

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

            rc-service sing-box restart >/dev/null 2>&1 ||
                rc-service sing-box start >/dev/null 2>&1
            ;;

        manual)

            stop_manual_singbox

            if [ "$CONFIG_MODE" = "directory" ]; then

                nohup "$SB_BIN" run -C "$CONFIG_DIR" \
                    > "${LOG_DIR}/sing-box.log" 2>&1 &

            else

                nohup "$SB_BIN" run -c "$CONFIG_FILE" \
                    > "${LOG_DIR}/sing-box.log" 2>&1 &
            fi

            echo $! > "${PID_DIR}/sing-box.pid"
            ;;
    esac

    sleep 1
}


# ============================================================
# 停止 sing-box
# ============================================================

stop_singbox() {

    local mode
    mode="$(service_mode)"

    case "$mode" in
        systemd)
            systemctl stop sing-box >/dev/null 2>&1 || true
            ;;

        openrc)
            rc-service sing-box stop >/dev/null 2>&1 || true
            ;;

        manual)
            stop_manual_singbox
            ;;
    esac
}


# ============================================================
# 检查配置
# ============================================================

check_config() {

    ensure_config || return 1

    if [ "$CONFIG_MODE" = "directory" ]; then
        "$SB_BIN" check -C "$CONFIG_DIR"
    else
        "$SB_BIN" check -c "$CONFIG_FILE"
    fi
}


# ============================================================
# 端口输入
# ============================================================

port_menu() {

    while true; do

        clear

        echo
        echo -e "${CYAN}---请选择端口方式---${NC}"
        echo "1. 随机端口"
        echo "2. 指定端口"
        echo "3. 返回"
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

                if ! [[ "$PORT" =~ ^[0-9]+$ ]] ||
                   [ "$PORT" -lt 1 ] ||
                   [ "$PORT" -gt 65535 ]; then

                    printf "${RED} 端口范围必须是 1-65535,按任意键重新输入...${NC}"
                    read -n 1 -s -r
                    continue
                fi

                if ss -lntup 2>/dev/null |
                    grep -Eq "[:.]${PORT}[[:space:]]"; then

                    printf "${RED} 端口 $PORT 已经被占用,按任意键重新输入...${NC}"
                    read -n 1 -s -r
                    continue
                fi

                success "指定端口：$PORT"

                return 0
                ;;

            3)
                CANCELLED=1
                return 1
                ;;

            *)
                printf "${RED} 无效选项,按任意键重新输入...${NC}"
                read -n 1 -s -r
                ;;
        esac
    done
}


# ============================================================
# UUID
# ============================================================

random_uuid() {

    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        "$SB_BIN" generate uuid
    fi
}


# ============================================================
# 网络地址检测
# ============================================================

get_iface_ipv4_list() {

    ip -4 addr show scope global 2>/dev/null |
        awk '/inet / {print $2}' |
        cut -d'/' -f1
}


get_iface_ipv6_list() {

    ip -6 addr show scope global 2>/dev/null |
        awk '/inet6 / {print $2}' |
        cut -d'/' -f1 |
        grep -v '^fe80'
}


# ============================================================
# 判断 IPv4 是否为私有 / 保留地址
# ============================================================

is_private_ipv4() {

    case "$1" in

        10.*)
            return 0
            ;;

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
        100.125.*|100.126.*|100.127.*)
            return 0
            ;;

        127.*)
            return 0
            ;;

        169.254.*)
            return 0
            ;;

        172.16.*|172.17.*|172.18.*|172.19.*|\
        172.20.*|172.21.*|172.22.*|172.23.*|\
        172.24.*|172.25.*|172.26.*|172.27.*|\
        172.28.*|172.29.*|172.30.*|172.31.*)
            return 0
            ;;

        192.168.*)
            return 0
            ;;

        0.*)
            return 0
            ;;

        224.*|225.*|226.*|227.*|228.*|229.*|\
        230.*|231.*|232.*|233.*|234.*|235.*|\
        236.*|237.*|238.*|239.*)
            return 0
            ;;

        240.*|241.*|242.*|243.*|244.*|245.*|\
        246.*|247.*|248.*|249.*|250.*|251.*|\
        252.*|253.*|254.*|255.*)
            return 0
            ;;
    esac

    return 1
}


# ============================================================
# 判断 IPv6 是否可作为公网地址
# ============================================================

is_public_ipv6() {

    local ip="$1"

    case "$ip" in

        "")
            return 1
            ;;

        ::|::1)
            return 1
            ;;

        fe80:*|FE80:*)
            return 1
            ;;

        fc*|fd*|FC*|FD*)
            return 1
            ;;
    esac

    return 0
}


# ============================================================
# 判断是否 Cloudflare WARP / CDN 出口段
# ============================================================

is_cloudflare_ip() {

    case "$1" in

        104.28.*|104.29.*|104.30.*|104.31.*)
            return 0
            ;;

        162.158.*|162.159.*)
            return 0
            ;;

        172.64.*|172.65.*|172.66.*|172.67.*|\
        172.68.*|172.69.*|172.70.*|172.71.*)
            return 0
            ;;

        188.114.*|190.93.*|197.234.*|198.41.*)
            return 0
            ;;
    esac

    return 1
}


# ============================================================
# 校验 IPv4 格式
# ============================================================

is_valid_ipv4() {

    local ip="$1"

    [ -z "$ip" ] && return 1

    local count

    count="$(

        echo "$ip" | awk -F. '

            NF != 4 { print 0; exit }

            {
                for (i = 1; i <= 4; i++) {

                    if ($i !~ /^[0-9]+$/) {
                        print 0
                        exit
                    }

                    if ($i < 0 || $i > 255) {
                        print 0
                        exit
                    }
                }

                print 1
            }
        '
    )"

    [ "$count" = "1" ]
}


# ============================================================
# 获取真实公网 IPv4
# ============================================================

get_public_ipv4() {

    local ip

    while read -r ip; do

        [ -z "$ip" ] && continue

        if ! is_private_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

    done < <(get_iface_ipv4_list)

    return 1
}


# ============================================================
# 获取真实公网 IPv6
# ============================================================

get_public_ipv6() {

    local ip

    while read -r ip; do

        [ -z "$ip" ] && continue

        if is_public_ipv6 "$ip"; then
            echo "$ip"
            return 0
        fi

    done < <(get_iface_ipv6_list)

    return 1
}


# ============================================================
# 判断服务器实际地址
# ============================================================

get_server_ip() {

    local ip4=""
    local ip4_curl=""
    local ip6=""
    local iface=""

    # 1. 网卡真实公网 IPv4

    ip4="$(get_public_ipv4 2>/dev/null)"

    if [ -n "$ip4" ]; then
        echo "$ip4"
        return 0
    fi

    # 2. curl -4 探测公网 IPv4（NAT 后的情况）

    ip4_curl="$(
        curl -4 -fsS \
            --connect-timeout 5 \
            --max-time 8 \
            https://api.ipify.org \
            2>/dev/null
    )"

    if ! is_valid_ipv4 "$ip4_curl"; then

        ip4_curl="$(
            curl -4 -fsS \
                --connect-timeout 5 \
                --max-time 8 \
                https://ipv4.icanhazip.com \
                2>/dev/null
        )"
    fi

    if ! is_valid_ipv4 "$ip4_curl"; then

        ip4_curl="$(
            curl -4 -fsS \
                --connect-timeout 5 \
                --max-time 8 \
                https://ifconfig.me \
                2>/dev/null
        )"
    fi

    if is_valid_ipv4 "$ip4_curl" &&
       ! is_cloudflare_ip "$ip4_curl"; then

        echo "$ip4_curl"
        return 0
    fi

    # 3. 网卡真实公网 IPv6

    ip6="$(get_public_ipv6 2>/dev/null)"

    if [ -n "$ip6" ]; then
        echo "$ip6"
        return 0
    fi

    # 4. curl -6 兜底

    ip6="$(
        curl -6 -fsS \
            --connect-timeout 5 \
            --max-time 8 \
            https://api64.ipify.org \
            2>/dev/null
    )"

    if ! echo "$ip6" | grep -q ':'; then

        ip6="$(
            curl -6 -fsS \
                --connect-timeout 5 \
                --max-time 8 \
                https://ipv6.icanhazip.com \
                2>/dev/null
        )"
    fi

    case "$ip6" in
        *:*)
            echo "$ip6"
            return 0
            ;;
    esac

    # 5. 最后兜底：任意网卡 IPv4（私有）

    iface="$(get_iface_ipv4_list | head -n 1)"

    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi

    echo ""
    return 1
}


# ============================================================
# 服务器地址加载
# ============================================================

SERVER_IP=""
SERVER_IP_VERSION=""

load_server_ip() {

    SERVER_IP="$(get_server_ip 2>/dev/null)"

    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="你的服务器IP"
    fi

    case "$SERVER_IP" in

        *:*)

            SERVER_IP_VERSION="ipv6"

            case "$SERVER_IP" in
                \[*\])
                    ;;
                *)
                    SERVER_IP="[${SERVER_IP}]"
                    ;;
            esac

            ;;

        你的服务器IP)

            SERVER_IP_VERSION="unknown"
            ;;

        *)

            SERVER_IP_VERSION="ipv4"
            ;;
    esac
}


# ============================================================
# 判断 tag
# ============================================================

tag_exists() {

    local tag="$1"

    ensure_config >/dev/null 2>&1 || return 1

    local source
    source="$(get_config_source)"

    jq -e --arg tag "$tag" \
        '.inbounds[]? | select(.tag == $tag)' \
        "$source" >/dev/null 2>&1
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


# ============================================================
# 防火墙
# ============================================================

allow_port() {

    local port="$1"
    local proto="$2"

    if [ -f /.dockerenv ] ||
       grep -qaE 'docker|lxc' /proc/1/cgroup 2>/dev/null; then

        warn "检测到容器环境，跳过容器内部防火墙配置。"
        warn "Docker 请在创建容器时使用 -p ${port}:${port}/${proto}。"

        return 0
    fi

    if command_exists ufw; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi

    if command_exists firewall-cmd &&
       command_exists systemctl &&
       systemctl is-active --quiet firewalld 2>/dev/null; then

        firewall-cmd --permanent \
            --add-port="${port}/${proto}" >/dev/null 2>&1 || true

        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if command_exists iptables; then

        iptables -C INPUT \
            -p "$proto" \
            --dport "$port" \
            -j ACCEPT >/dev/null 2>&1 ||

        iptables -I INPUT \
            -p "$proto" \
            --dport "$port" \
            -j ACCEPT >/dev/null 2>&1 || true
    fi

    if command_exists ip6tables; then

        ip6tables -C INPUT \
            -p "$proto" \
            --dport "$port" \
            -j ACCEPT >/dev/null 2>&1 ||

        ip6tables -I INPUT \
            -p "$proto" \
            --dport "$port" \
            -j ACCEPT >/dev/null 2>&1 || true
    fi
}


# ============================================================
# 保存 VLESS Reality 状态
# ============================================================

save_vless_state() {

    local tag="$1"
    local uuid="$2"
    local public_key="$3"
    local sni="$4"
    local port="$5"
    local short_id="$6"

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

    if jq --arg tag "$tag" \
        'del(.vless_nodes[$tag])' \
        "$STATE_FILE" > "$tmp" 2>/dev/null; then

        mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE"

    else

        rm -f "$tmp"
    fi
}


# ============================================================
# Hysteria2 pinSHA256
# ============================================================

get_hysteria_pin_encoded() {

    local cert="$1"

    [ -f "$cert" ] || return 1

    local pin

    pin="$(
        openssl x509 \
            -in "$cert" \
            -noout \
            -pubkey 2>/dev/null |
        openssl pkey \
            -pubin \
            -outform der 2>/dev/null |
        openssl dgst \
            -sha256 \
            -binary 2>/dev/null |
        openssl enc \
            -base64 2>/dev/null |
        tr -d '\n'
    )"

    [ -z "$pin" ] && return 1

    if command_exists jq; then
        printf '%s' "$pin" | jq -sRr @uri
    else
        printf '%s' "$pin" |
            sed \
                -e 's/+/%2B/g' \
                -e 's|/|%2F|g' \
                -e 's/=/%3D/g'
    fi
}


random_short_id() {
    openssl rand -hex 8
}


# ============================================================
# VLESS Reality
# ============================================================

install_vless() {

    clear

    echo -e "${GREEN}========== VLESS Reality 安装 ==========${NC}"

    port_menu || return

    local port="$PORT"
    local uuid
    local keys
    local private_key
    local public_key
    local short_id
    local sni="www.microsoft.com"
    local tag

    uuid="$(random_uuid)"

    tag="$(unique_tag "vless-reality")"

    short_id="$(random_short_id)"

    info "正在生成 Reality 密钥..."

    keys="$(
        "$SB_BIN" generate reality-keypair 2>/dev/null
    )"

    private_key="$(
        echo "$keys" |
        awk '/PrivateKey:/ {print $2}'
    )"

    public_key="$(
        echo "$keys" |
        awk '/PublicKey:/ {print $2}'
    )"

    if [ -z "$private_key" ] ||
       [ -z "$public_key" ]; then

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

    info "服务器地址类型：$(
        if [ "$listen_addr" = "0.0.0.0" ]; then
            echo "IPv4"
        else
            echo "IPv6"
        fi
    )"

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
            users: [
                {
                    uuid: $uuid,
                    flow: "xtls-rprx-vision"
                }
            ],
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: {
                        server: $sni,
                        server_port: 443
                    },
                    private_key: $private_key,
                    short_id: [$short_id]
                }
            }
        }'
    )"

    local tmp
    tmp="$(mktemp)"

    if [ "$CONFIG_MODE" = "directory" ]; then

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 VLESS 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 VLESS 失败。"

            return 1
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

    if ! save_vless_state \
        "$tag" \
        "$uuid" \
        "$public_key" \
        "$sni" \
        "$port" \
        "$short_id"; then

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

    echo "vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-Reality"

    echo
}


# ============================================================
# 临时 Argo
# ============================================================

temp_argo_log() {
    echo "${LOG_DIR}/argo-$1.log"
}

temp_argo_pid() {
    echo "${PID_DIR}/argo-$1.pid"
}


get_temp_argo_domain() {

    local tag="$1"

    local log
    log="$(temp_argo_log "$tag")"

    [ -f "$log" ] || return 1

    sed -nE \
        's/.*https:\/\/([^/]+\.trycloudflare\.com).*/\1/p' \
        "$log" 2>/dev/null |
        tail -n 1
}


start_temp_argo() {

    local tag="$1"
    local port="$2"

    local log
    local pidfile

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

        if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi

        rm -f "$pidfile"
    fi
}


stop_fixed_argo() {

    if command_exists systemctl; then
        systemctl stop cloudflared-singbox >/dev/null 2>&1 || true
    fi

    if command_exists rc-service; then
        rc-service cloudflared-singbox stop >/dev/null 2>&1 || true
    fi

    if [ -f "${PID_DIR}/fixed-argo.pid" ]; then

        local pid
        pid="$(cat "${PID_DIR}/fixed-argo.pid" 2>/dev/null)"

        if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi

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

        if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi

        rm -f "$f"
    done
}


# ============================================================
# VMess 临时 Argo
# ============================================================

install_vmess_temp() {

    clear

    echo -e "${GREEN}========== VMess 临时 Argo ==========${NC}"

    port_menu || return

    local port="$PORT"
    local uuid
    local tag

    uuid="$(random_uuid)"

    tag="$(unique_tag "vmess-argo")"

    if [ ! -x "$ARGO_BIN" ]; then
        download_cloudflared || return 1
    fi

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

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 VMess 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 VMess 失败。"

            return 1
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

    local domain=""
    local log

    log="$(temp_argo_log "$tag")"

    for _ in 1 2 3 4 5 6 7 8 9 10; do

        domain="$(
            sed -nE \
                's/.*https:\/\/([^/]+\.trycloudflare\.com).*/\1/p' \
                "$log" 2>/dev/null |
            tail -n 1
        )"

        [ -n "$domain" ] && break

        sleep 2
    done

    if [ -z "$domain" ]; then

        error "没有获取到 Cloudflare 临时 Argo 域名。"

        warn "正在回滚临时 Argo 节点..."

        stop_temp_argo "$tag"

        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true

        if check_config >/dev/null 2>&1; then
            restart_singbox
        fi

        warn "请查看日志：$log"

        return 1
    fi

    local preferred
    preferred="$(get_preferred_domain)"

    local client_domain="$domain"

    if [ -n "$preferred" ]; then
        client_domain="$preferred"
    fi

    echo

    success "VMess 临时 Argo 安装成功。"

    echo

    echo "节点标签：$tag"
    echo "Argo 域名：$domain"

    [ -n "$preferred" ] &&
        echo "优选域名：$preferred"

    echo

    local vmess_json

    vmess_json="$(
        jq -n \
            --arg add "$client_domain" \
            --arg host "$domain" \
            --arg sni "$domain" \
            --arg id "$uuid" \
        '{
            v: "2",
            ps: "VMess-Argo",
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
}


# ============================================================
# 优选域名
# ============================================================

get_preferred_domain() {

    if [ -f "$STATE_FILE" ]; then

        jq -r \
            '.preferred_domain // empty' \
            "$STATE_FILE" 2>/dev/null
    fi
}


# ============================================================
# 打印所有 VMess 节点
# ============================================================

show_all_vmess_links() {

    ensure_config >/dev/null 2>&1 || return 0

    local config_source
    config_source="$(get_config_source)"

    local count
    count="$(
        jq '.inbounds | length' \
            "$config_source" 2>/dev/null
    )"

    if [ -z "$count" ] ||
       [ "$count" = "0" ] ||
       [ "$count" = "null" ]; then

        return 0
    fi

    local found=0
    local i=0

    while [ "$i" -lt "$count" ]; do

        local type

        type="$(
            jq -r \
                ".inbounds[$i].type // \"\"" \
                "$config_source" 2>/dev/null
        )"

        if [ "$type" = "vmess" ]; then

            if [ "$found" = "0" ]; then

                echo
                echo -e "${GREEN}========== 当前 VMess 节点链接 ==========${NC}"
                echo

                found=1
            fi

            local tag

            tag="$(
                jq -r \
                    ".inbounds[$i].tag // \"\"" \
                    "$config_source" 2>/dev/null
            )"

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


# ============================================================
# 修改优选域名
# ============================================================

set_preferred_domain() {

    clear

    echo -e "${GREEN}========== 修改优选域名 ==========${NC}"

    echo
    echo "优选域名用于 VMess 客户端连接地址。"
    echo

    local old
    old="$(get_preferred_domain)"

    [ -n "$old" ] &&
        echo "当前优选域名：$old"

    echo

    read -r -p "请输入新的优选域名（留空则清除）： " domain

    if [ -z "$domain" ]; then

        local tmp
        tmp="$(mktemp)"

        jq '.preferred_domain = ""' \
            "$STATE_FILE" > "$tmp" &&
        mv "$tmp" "$STATE_FILE"

        chmod 600 "$STATE_FILE"

        success "优选域名已清除。"

        show_all_vmess_links

        return
    fi

    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    local tmp
    tmp="$(mktemp)"

    jq --arg domain "$domain" \
        '.preferred_domain = $domain' \
        "$STATE_FILE" > "$tmp" &&
    mv "$tmp" "$STATE_FILE"

    chmod 600 "$STATE_FILE"

    success "优选域名已修改为：$domain"

    show_all_vmess_links
}


# ============================================================
# 固定 Argo
# ============================================================

install_vmess_fixed() {

    clear

    echo -e "${GREEN}========== VMess 固定 Argo ==========${NC}"

    if [ ! -x "$ARGO_BIN" ]; then
        download_cloudflared || return 1
    fi

    local existing_tag

    existing_tag="$(
        jq -r \
            '.fixed_vmess.tag // empty' \
            "$STATE_FILE" 2>/dev/null
    )"

    if [ -n "$existing_tag" ] &&
       tag_exists "$existing_tag"; then

        error "已经存在固定 Argo 节点：$existing_tag"

        warn "请先卸载它，或使用“修改固定隧道”功能。"

        return 1
    fi

    echo

    read -r -p "请输入 Cloudflare Tunnel 域名： " domain

    [ -z "$domain" ] && {
        error "域名不能为空。"
        return
    }

    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    echo

    echo "请输入 Cloudflare Tunnel Token。"
    echo "Token 会以 600 权限保存到：$ARGO_ENV"

    echo

    read -r -s -p "请输入 KEY / Token： " token

    echo

    [ -z "$token" ] && {
        error "KEY / Token 不能为空。"
        return
    }

    port_menu || return

    local port="$PORT"
    local uuid
    local tag

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

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加固定 VMess 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加固定 VMess 失败。"

            return 1
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

    configure_fixed_argo \
        "$domain" \
        "$port" \
        "$token"

    save_fixed_vmess_state \
        "$tag" \
        "$domain" \
        "$token" \
        "$port" \
        "$uuid"

    echo

    success "VMess 固定 Argo 已配置。"

    echo

    echo "Tunnel 域名：$domain"
    echo "本地端口：$port"
    echo "VMess UUID：$uuid"

    echo

    show_fixed_vmess_link "$domain" "$uuid"
}


# ============================================================
# 固定 Argo Token
# ============================================================

write_fixed_argo_env() {

    local token="$1"

    {
        printf "CLOUDFLARE_TUNNEL_TOKEN='"
        printf '%s' "$token" |
            sed "s/'/'\\\\''/g"
        printf "'\n"
    } > "$ARGO_ENV"

    chmod 600 "$ARGO_ENV"
}


# ============================================================
# 配置固定 Argo
# ============================================================

configure_fixed_argo() {

    local domain="$1"
    local port="$2"
    local token="$3"

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


# ============================================================
# 保存固定 VMess 状态
# ============================================================

save_fixed_vmess_state() {

    local tag="$1"
    local domain="$2"
    local token="$3"
    local port="$4"
    local uuid="$5"

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
        "$STATE_FILE" > "$tmp" &&
    mv "$tmp" "$STATE_FILE"

    chmod 600 "$STATE_FILE"
}


# ============================================================
# 固定 VMess 链接
# ============================================================

show_fixed_vmess_link() {

    local domain="$1"
    local uuid="$2"

    local preferred
    preferred="$(get_preferred_domain)"

    local add="$domain"

    [ -n "$preferred" ] &&
        add="$preferred"

    local json

    json="$(
        jq -n \
            --arg add "$add" \
            --arg host "$domain" \
            --arg sni "$domain" \
            --arg uuid "$uuid" \
        '{
            v: "2",
            ps: "VMess-Fixed-Argo",
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


# ============================================================
# 修改固定隧道
# ============================================================

modify_fixed_vmess() {

    clear

    echo -e "${GREEN}========== 修改固定隧道 ==========${NC}"

    local old_tag

    old_tag="$(
        jq -r \
            '.fixed_vmess.tag // empty' \
            "$STATE_FILE" 2>/dev/null
    )"

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

    local old_port
    local old_uuid

    if [ "$CONFIG_MODE" = "directory" ]; then

        old_port="$(
            jq -r \
                --arg tag "$old_tag" \
                '.inbounds[] |
                 select(.tag == $tag) |
                 .listen_port' \
                "$INBOUNDS_FILE" 2>/dev/null
        )"

        old_uuid="$(
            jq -r \
                --arg tag "$old_tag" \
                '.inbounds[] |
                 select(.tag == $tag) |
                 .users[0].uuid' \
                "$INBOUNDS_FILE" 2>/dev/null
        )"

    else

        old_port="$(
            jq -r \
                --arg tag "$old_tag" \
                '.inbounds[] |
                 select(.tag == $tag) |
                 .listen_port' \
                "$CONFIG_FILE" 2>/dev/null
        )"

        old_uuid="$(
            jq -r \
                --arg tag "$old_tag" \
                '.inbounds[] |
                 select(.tag == $tag) |
                 .users[0].uuid' \
                "$CONFIG_FILE" 2>/dev/null
        )"
    fi

    echo "当前固定隧道："

    echo "域名：$(
        jq -r \
            '.fixed_vmess.domain // empty' \
            "$STATE_FILE"
    )"

    echo "端口：$old_port"

    echo

    read -r -p "请输入新的 Cloudflare Tunnel 域名： " new_domain

    [ -z "$new_domain" ] && {
        error "域名不能为空。"
        return
    }

    new_domain="${new_domain#http://}"
    new_domain="${new_domain#https://}"
    new_domain="${new_domain%%/*}"

    echo

    read -r -s -p "请输入新的 KEY / Token： " new_token

    echo

    [ -z "$new_token" ] && {
        error "KEY / Token 不能为空。"
        return
    }

    write_fixed_argo_env "$new_token"

    configure_fixed_argo \
        "$new_domain" \
        "$old_port" \
        "$new_token"

    save_fixed_vmess_state \
        "$old_tag" \
        "$new_domain" \
        "$new_token" \
        "$old_port" \
        "$old_uuid"

    echo

    success "固定隧道已经替换。"

    echo

    show_fixed_vmess_link \
        "$new_domain" \
        "$old_uuid"
}


# ============================================================
# VMess 菜单
# ============================================================

vmess_menu() {

    while true; do

        clear

        echo -e "${CYAN}========== VMess 安装 ==========${NC}"

        echo

        echo "1. 临时 Argo"
        echo "2. 固定 Argo"
        echo "3. 修改固定隧道"
        echo "4. 修改优选域名"
        echo "5. 返回"

        echo

        read -r -p "请选择 [1-5]: " choice

        case "$choice" in

            1)
                install_vmess_temp
                pause_unless_cancelled
                ;;

            2)
                install_vmess_fixed
                pause_unless_cancelled
                ;;

            3)
                modify_fixed_vmess
                pause_unless_cancelled
                ;;

            4)
                set_preferred_domain
                pause_unless_cancelled
                ;;

            5)
                return
                ;;

            *)
                printf "${RED} 无效选项,按任意键重新输入...${NC}"
                read -n 1 -s -r
                ;;
        esac
    done
}


# ============================================================
# TUIC
# ============================================================

install_tuic() {

    clear

    echo -e "${GREEN}========== TUIC 安装 ==========${NC}"

    port_menu || return

    local port="$PORT"
    local uuid
    local password
    local tag

    uuid="$(random_uuid)"

    password="$(
        tr -dc 'A-Za-z0-9' </dev/urandom |
        head -c 24
    )"

    tag="$(unique_tag "tuic")"

    local cert="${SB_DIR}/tuic-cert.pem"
    local key="${SB_DIR}/tuic-key.pem"

    openssl ecparam \
        -genkey \
        -name prime256v1 \
        -out "$key" >/dev/null 2>&1

    openssl req \
        -new \
        -x509 \
        -days 3650 \
        -key "$key" \
        -out "$cert" \
        -subj "/CN=www.bing.com" >/dev/null 2>&1

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
            users: [
                {
                    uuid: $uuid,
                    password: $password
                }
            ],
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

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 TUIC 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 TUIC 失败。"

            return 1
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

    echo "tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUIC"

    echo
}


# ============================================================
# Hysteria2
# ============================================================

install_hysteria2() {

    clear

    echo -e "${GREEN}========== Hysteria2 安装 ==========${NC}"

    port_menu || return

    local port="$PORT"
    local password
    local tag

    password="$(
        tr -dc 'A-Za-z0-9' </dev/urandom |
        head -c 32
    )"

    tag="$(unique_tag "hysteria2")"

    local cert="${SB_DIR}/hy2-cert.pem"
    local key="${SB_DIR}/hy2-key.pem"

    openssl ecparam \
        -genkey \
        -name prime256v1 \
        -out "$key" >/dev/null 2>&1

    openssl req \
        -new \
        -x509 \
        -days 3650 \
        -key "$key" \
        -out "$cert" \
        -subj "/CN=www.bing.com" >/dev/null 2>&1

    chmod 600 "$key"

    local fingerprint

    fingerprint="$(
        get_hysteria_pin_encoded "$cert"
    )"

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
            users: [
                {
                    password: $password
                }
            ],
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

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 Hysteria2 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 Hysteria2 失败。"

            return 1
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

    if [ -n "$fingerprint" ]; then

        echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3#Hysteria2"

    else

        echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&alpn=h3#Hysteria2"
    fi

    echo
}


# ============================================================
# Socks5
# ============================================================

install_socks5() {

    clear

    echo -e "${GREEN}========== Socks5 安装 ==========${NC}"

    port_menu || return

    local port="$PORT"
    local username
    local password
    local tag

    read -r -p "请输入 Socks5 用户名（回车随机）： " username

    if [ -z "$username" ]; then

        username="user$(shuf -i 10000-99999 -n 1)"
    fi

    read -r -s -p "请输入 Socks5 密码（回车随机）： " password

    echo

    if [ -z "$password" ]; then

        password="$(
            tr -dc 'A-Za-z0-9' </dev/urandom |
            head -c 20
        )"
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
            users: [
                {
                    username: $username,
                    password: $password
                }
            ]
        }'
    )"

    local tmp
    tmp="$(mktemp)"

    if [ "$CONFIG_MODE" = "directory" ]; then

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 Socks5 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 Socks5 失败。"

            return 1
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

    echo "socks5://${username}:${password}@${SERVER_IP}:${port}#Socks5"

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

        jq --arg tag "$tag" \
            '.inbounds |= map(select(.tag != $tag))' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq --arg tag "$tag" \
            '.inbounds |= map(select(.tag != $tag))' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            return 1
        }

        mv "$tmp" "$CONFIG_FILE"
    fi

    return 0
}


# ============================================================
# 获取配置来源
# ============================================================

get_config_source() {

    if [ "$CONFIG_MODE" = "directory" ]; then
        echo "$INBOUNDS_FILE"
    else
        echo "$CONFIG_FILE"
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

    local type
    local tag
    local port
    local uuid
    local flow
    local sni
    local public_key
    local password
    local username
    local short_id

    type="$(
        jq -r \
            ".inbounds[$index].type // \"\"" \
            "$config_source" 2>/dev/null
    )"

    tag="$(
        jq -r \
            ".inbounds[$index].tag // \"\"" \
            "$config_source" 2>/dev/null
    )"

    port="$(
        jq -r \
            ".inbounds[$index].listen_port // \"\"" \
            "$config_source" 2>/dev/null
    )"

    load_server_ip

    case "$type" in

        # VLESS Reality

        vless)

            uuid="$(
                jq -r \
                    ".inbounds[$index].users[0].uuid // empty" \
                    "$config_source" 2>/dev/null
            )"

            flow="$(
                jq -r \
                    ".inbounds[$index].users[0].flow // empty" \
                    "$config_source" 2>/dev/null
            )"

            sni="$(
                jq -r \
                    ".inbounds[$index].tls.server_name // empty" \
                    "$config_source" 2>/dev/null
            )"

            public_key="$(
                jq -r \
                    --arg tag "$tag" \
                    '.vless_nodes[$tag].public_key // empty' \
                    "$STATE_FILE" 2>/dev/null
            )"

            short_id="$(
                jq -r \
                    --arg tag "$tag" \
                    '.vless_nodes[$tag].short_id // empty' \
                    "$STATE_FILE" 2>/dev/null
            )"

            if [ -z "$public_key" ]; then

                echo -e "${RED}无法生成 VLESS Reality 链接。${NC}"
                echo "原因：state.json 没有保存此节点的 public_key。"

                return 2
            fi

            [ -z "$flow" ] &&
                flow="xtls-rprx-vision"

            [ -z "$sni" ] &&
                sni="www.microsoft.com"

            echo "vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-Reality"

            ;;

        # VMess

        vmess)

            uuid="$(
                jq -r \
                    ".inbounds[$index].users[0].uuid // empty" \
                    "$config_source" 2>/dev/null
            )"

            local path

            path="$(
                jq -r \
                    ".inbounds[$index].transport.path // \"/vmess-argo\"" \
                    "$config_source" 2>/dev/null
            )"

            local fixed_tag

            fixed_tag="$(
                jq -r \
                    '.fixed_vmess.tag // empty' \
                    "$STATE_FILE" 2>/dev/null
            )"

            local domain=""
            local client_domain=""
            local preferred

            if [ "$tag" = "$fixed_tag" ]; then

                domain="$(
                    jq -r \
                        '.fixed_vmess.domain // empty' \
                        "$STATE_FILE" 2>/dev/null
                )"

                client_domain="$domain"

                preferred="$(get_preferred_domain)"

                [ -n "$preferred" ] &&
                    client_domain="$preferred"

            else

                domain="$(get_temp_argo_domain "$tag")"

                client_domain="$domain"

                preferred="$(get_preferred_domain)"

                [ -n "$preferred" ] &&
                    client_domain="$preferred"
            fi

            if [ -z "$domain" ]; then

                echo -e "${RED}无法获取 VMess Argo 域名。${NC}"

                return 1
            fi

            [ -z "$client_domain" ] &&
                client_domain="$domain"

            case "$path" in
                *\?*)
                    ;;
                *)
                    path="${path}?ed=2560"
                    ;;
            esac

            local vmess_json

            vmess_json="$(
                jq -n \
                    --arg add "$client_domain" \
                    --arg host "$domain" \
                    --arg sni "$domain" \
                    --arg uuid "$uuid" \
                    --arg path "$path" \
                '{
                    v: "2",
                    ps: "VMess",
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

        # TUIC

        tuic)

            uuid="$(
                jq -r \
                    ".inbounds[$index].users[0].uuid // empty" \
                    "$config_source" 2>/dev/null
            )"

            password="$(
                jq -r \
                    ".inbounds[$index].users[0].password // empty" \
                    "$config_source" 2>/dev/null
            )"

            echo "tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUIC"

            ;;

        # Hysteria2

        hysteria2)

            password="$(
                jq -r \
                    ".inbounds[$index].users[0].password // empty" \
                    "$config_source" 2>/dev/null
            )"

            local cert

            cert="$(
                jq -r \
                    ".inbounds[$index].tls.certificate_path // empty" \
                    "$config_source" 2>/dev/null
            )"

            local fingerprint=""

            if [ -n "$cert" ] &&
               [ -f "$cert" ]; then

                fingerprint="$(
                    get_hysteria_pin_encoded "$cert"
                )"
            fi

            if [ -n "$fingerprint" ]; then

                echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3#Hysteria2"

            else

                echo "hysteria2://${password}@${SERVER_IP}:${port}/?sni=www.bing.com&insecure=1&alpn=h3#Hysteria2"
            fi

            ;;

        # Socks5

        socks)

            username="$(
                jq -r \
                    ".inbounds[$index].users[0].username // empty" \
                    "$config_source" 2>/dev/null
            )"

            password="$(
                jq -r \
                    ".inbounds[$index].users[0].password // empty" \
                    "$config_source" 2>/dev/null
            )"

            echo "socks5://${username}:${password}@${SERVER_IP}:${port}#Socks5"

            ;;

        *)

            echo "暂不支持自动生成 ${type} 客户端链接。"

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

    ensure_config || {
        pause
        return
    }

    echo -e "${CYAN}配置来源：${NC}"

    if [ "$CONFIG_MODE" = "directory" ]; then
        echo "$INBOUNDS_FILE"
    else
        echo "$CONFIG_FILE"
    fi

    echo

    local config_source
    config_source="$(get_config_source)"

    local count

    count="$(
        jq '.inbounds | length' \
            "$config_source" 2>/dev/null
    )"

    if [ -z "$count" ] ||
       [ "$count" = "0" ] ||
       [ "$count" = "null" ]; then

        warn "当前没有检测到 inbound 节点。"

        pause

        return
    fi

    load_server_ip

    echo -e "${CYAN}服务器地址：${NC}${SERVER_IP} (${SERVER_IP_VERSION})"

    echo

    local i=0

    while [ "$i" -lt "$count" ]; do

        local type
        local tag
        local listen
        local port
        local user_count

        type="$(
            jq -r \
                ".inbounds[$i].type // \"unknown\"" \
                "$config_source"
        )"

        tag="$(
            jq -r \
                ".inbounds[$i].tag // \"\"" \
                "$config_source"
        )"

        listen="$(
            jq -r \
                ".inbounds[$i].listen // \"\"" \
                "$config_source"
        )"

        port="$(
            jq -r \
                ".inbounds[$i].listen_port // \"\"" \
                "$config_source"
        )"

        user_count="$(
            jq -r \
                ".inbounds[$i].users // [] | length" \
                "$config_source"
        )"

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

        if [ "$link_status" -eq 0 ]; then

            echo "$link_output"

        elif [ "$link_status" -eq 2 ]; then

            echo "$link_output"

        else

            echo -e "${RED}${link_output}${NC}"
        fi

        echo

        echo "========================================"

        i=$((i + 1))
    done

    echo

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

    ensure_config || {
        pause
        return
    }

    local config_source
    config_source="$(get_config_source)"

    local count
    count="$(
        jq '.inbounds | length' \
            "$config_source"
    )"

    if [ -z "$count" ] ||
       [ "$count" = "0" ]; then

        warn "没有可卸载的节点。"

        pause

        return
    fi

    local i=0

    while [ "$i" -lt "$count" ]; do

        local type
        local tag
        local port

        type="$(
            jq -r \
                ".inbounds[$i].type // \"unknown\"" \
                "$config_source"
        )"

        tag="$(
            jq -r \
                ".inbounds[$i].tag // \"\"" \
                "$config_source"
        )"

        port="$(
            jq -r \
                ".inbounds[$i].listen_port // \"\"" \
                "$config_source"
        )"

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

        if [ "$item" -lt 1 ] ||
           [ "$item" -gt "$count" ]; then

            error "编号超出范围：$item"

            pause

            return
        fi

        local idx=$((item - 1))

        local dup=0
        local s

        for s in "${seen_idx[@]}"; do

            if [ "$s" = "$idx" ]; then
                dup=1
                break
            fi
        done

        [ "$dup" = "1" ] && continue

        seen_idx+=("$idx")

        local tag
        local type

        tag="$(
            jq -r \
                ".inbounds[$idx].tag // empty" \
                "$config_source"
        )"

        type="$(
            jq -r \
                ".inbounds[$idx].type // empty" \
                "$config_source"
        )"

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

    [[ "$confirm" =~ ^[Yy]$ ]] || {

        warn "已取消。"

        pause

        return
    }

    backup_config_once

    local fixed_tag

    fixed_tag="$(
        jq -r \
            '.fixed_vmess.tag // empty' \
            "$STATE_FILE" 2>/dev/null
    )"

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

    local pidfile
    local p

    for pidfile in \
        "${PID_DIR}/sing-box.pid" \
        "${PID_DIR}/fixed-argo.pid" \
        "${PID_DIR}"/argo-*.pid
    do

        [ -f "$pidfile" ] || continue

        p="$(cat "$pidfile" 2>/dev/null)"

        if [ -n "$p" ]; then
            kill "$p" >/dev/null 2>&1 || true
        fi
    done

    pkill -f "${SB_BIN}" >/dev/null 2>&1 || true
    pkill -f "${SB_DIR}/cloudflared" >/dev/null 2>&1 || true

    rm -f /run/sing-box.pid
    rm -f /run/cloudflared-singbox.pid

    info "正在删除 ${SB_DIR} ..."

    rm -rf "$SB_DIR"

    hash -r 2>/dev/null || true

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

    local qdisc
    local congestion

    qdisc="$(
        sysctl -n \
            net.core.default_qdisc \
            2>/dev/null
    )"

    congestion="$(
        sysctl -n \
            net.ipv4.tcp_congestion_control \
            2>/dev/null
    )"

    echo

    echo "当前队列算法：$qdisc"
    echo "当前 TCP 拥塞控制：$congestion"

    echo

    if [ "$qdisc" = "fq" ] &&
       [ "$congestion" = "bbr" ]; then

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
        echo -e "1. ${YELLOW}  VLESS 安装${NC}"
        echo -e "2. ${YELLOW}  VMess 安装${NC}"
        echo -e "3. ${YELLOW}  TUIC 安装${NC}"
        echo -e "4. ${YELLOW}  Hysteria2 安装${NC}"
        echo -e "5. ${YELLOW}  Socks5 安装${NC}"
        echo -e "6. ${YELLOW}  节点卸载${NC}"
        echo -e "7. ${YELLOW}  查看节点${NC}"
        echo -e "8. ${YELLOW}  返回${NC}"
        
        echo

        read -p "$(echo -e "${BLUE}*  ${CYAN}请选择 [1-8]: ${NC}: ")" choice

        case "$choice" in

            1)

                if [ ! -x "$SB_BIN" ]; then

                    download_singbox || {
                        pause
                        continue
                    }
                fi

                install_vless

                pause_unless_cancelled
                ;;

            2)

                if [ ! -x "$SB_BIN" ]; then

                    download_singbox || {
                        pause
                        continue
                    }
                fi

                vmess_menu
                ;;

            3)

                if [ ! -x "$SB_BIN" ]; then

                    download_singbox || {
                        pause
                        continue
                    }
                fi

                install_tuic

                pause_unless_cancelled
                ;;

            4)

                if [ ! -x "$SB_BIN" ]; then

                    download_singbox || {
                        pause
                        continue
                    }
                fi

                install_hysteria2

                pause_unless_cancelled
                ;;

            5)

                if [ ! -x "$SB_BIN" ]; then

                    download_singbox || {
                        pause
                        continue
                    }
                fi

                install_socks5

                pause_unless_cancelled
                ;;

            6)
                uninstall_node
                ;;

            7)
                show_nodes
                ;;

            8)
                return
                ;;

            *)
                printf "${RED} 无效选项,按任意键重新输入...${NC}"
                read -n 1 -s -r
                ;;
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

        echo -e "1. ${YELLOW} sing-box 节点管理${NC}"
        echo -e "1. ${YELLOW} BBR + FQ 加速${NC}"
        echo -e "1. ${YELLOW} sing-box 卸载${NC}"
        echo -e "1. ${YELLOW} 退出${NC}"

        echo

        read -p "$(echo -e "${BLUE}*  ${CYAN}请选择 [1-4]: ${NC}: ")" choice

        case "$choice" in

            1)
                node_install_menu
                ;;

            2)
                bbr_fq
                ;;

            3)
                uninstall_singbox
                ;;

            4)
                clear
                exit 0
                ;;

            *)
                printf "${RED} 无效选项,按任意键重新输入...${NC}"
                read -n 1 -s -r
                ;;
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
