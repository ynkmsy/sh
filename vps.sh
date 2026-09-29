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

update_singbox() {
    clear
    echo -e "${GREEN}========== sing-box 更新 ==========${NC}"
    echo

    detect_arch || return 1

    local old_version="未安装"
    if [ -x "$SB_BIN" ]; then
        old_version="$("$SB_BIN" version 2>/dev/null | head -n 1)"
        [ -z "$old_version" ] && old_version="未知版本"
    fi
    info "当前版本：$old_version"
    info "当前架构：$ARCH"
    echo

    local latest_version
    latest_version="$(get_latest_singbox_version)"
    if [ -z "$latest_version" ]; then
        error "无法从 GitHub 获取 sing-box 最新正式版。"
        return 1
    fi

    info "最新正式版：v${latest_version}"

    local old_num=""
    old_num="$(echo "$old_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [ -n "$old_num" ] && [ "$old_num" = "$latest_version" ]; then
        success "当前已经是最新正式版，无需更新。"
        return 0
    fi

    local url
    url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz"

    local tmp backup_dir backup_bin binary
    tmp="$(mktemp -d)"
    backup_dir="${SB_DIR}/backup"
    backup_bin="${backup_dir}/sing-box-$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$backup_dir" "$SB_DIR"

    info "正在下载 sing-box v${latest_version}..."
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

    binary="$(find "$tmp" -type f -name "sing-box" -perm -u+x | head -n 1)"
    if [ -z "$binary" ]; then
        error "解压后没有找到 sing-box 二进制文件。"
        rm -rf "$tmp"
        return 1
    fi

    if ! "$binary" version >/dev/null 2>&1; then
        error "新 sing-box 二进制验证失败，已取消更新。"
        rm -rf "$tmp"
        return 1
    fi

    local new_version
    new_version="$("$binary" version 2>/dev/null | head -n 1)"
    info "下载文件验证通过：${new_version:-未知版本}"

    local service_mode_before service_was_active=0
    service_mode_before="$(service_mode)"
    case "$service_mode_before" in
        systemd)
            systemctl is-active --quiet sing-box 2>/dev/null && service_was_active=1
            ;;
        openrc)
            rc-service sing-box status >/dev/null 2>&1 && service_was_active=1
            ;;
        manual)
            if [ -f "${PID_DIR}/sing-box.pid" ]; then
                local pid
                pid="$(cat "${PID_DIR}/sing-box.pid" 2>/dev/null)"
                [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && service_was_active=1
            fi
            ;;
    esac

    if [ -x "$SB_BIN" ]; then
        cp -a "$SB_BIN" "$backup_bin" || {
            error "无法备份当前 sing-box，已取消更新。"
            rm -rf "$tmp"
            return 1
        }
        chmod 755 "$backup_bin"
        info "已备份旧版本：$backup_bin"
    fi

    if ! install -Dm755 "$binary" "$SB_BIN"; then
        error "安装新 sing-box 失败。"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"

    if ! "$SB_BIN" version >/dev/null 2>&1; then
        error "更新后的 sing-box 验证失败，正在回滚..."
        if [ -x "$backup_bin" ]; then
            if install -Dm755 "$backup_bin" "$SB_BIN"; then
                success "旧版本 sing-box 已恢复。"
            else
                error "旧版本 sing-box 恢复失败：$backup_bin"
            fi
        else
            error "找不到旧版本 sing-box 备份文件：$backup_bin"
        fi
        return 1
    fi

    if ! check_config >/dev/null 2>&1; then
        error "更新后的 sing-box 配置检查失败，正在回滚旧版本..."
        if [ -x "$backup_bin" ]; then
            if install -Dm755 "$backup_bin" "$SB_BIN"; then
                success "旧版本 sing-box 已恢复。"
            else
                error "旧版本 sing-box 恢复失败：$backup_bin"
            fi
        else
            error "找不到旧版本 sing-box 备份文件：$backup_bin"
        fi
        return 1
    fi

    local final_version
    final_version="$("$SB_BIN" version 2>/dev/null | head -n 1)"

    if [ "$service_was_active" = "1" ]; then
        info "检测到 sing-box 正在运行，正在重启以应用新版本..."

        if ! restart_singbox; then
            error "新版本启动失败，正在回滚旧版本..."

            if [ -x "$backup_bin" ]; then
                if install -Dm755 "$backup_bin" "$SB_BIN"; then
                    success "旧版本 sing-box 已恢复。"

                    if ! restart_singbox >/dev/null 2>&1; then
                        error "旧版本 sing-box 恢复后启动失败。"
                        error "请检查 sing-box 服务状态和日志。"
                    else
                        success "旧版本 sing-box 已重新启动。"
                    fi
                else
                    error "旧版本 sing-box 恢复失败：$backup_bin"
                fi
            else
                error "找不到旧版本 sing-box 备份文件：$backup_bin"
            fi
            return 1
        fi
    else
        info "更新前 sing-box 未运行，不主动启动服务。"
    fi

    echo
    success "sing-box 更新成功。"
    echo "更新前：${old_version}"
    echo "更新后：${final_version:-v${latest_version}}"
    echo "旧版本备份：${backup_bin}"
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

update_cloudflared() {
    clear
    echo -e "${GREEN}========== Cloudflare 更新 ==========${NC}"
    echo

    detect_arch || return 1

    local cf_arch
    case "$ARCH" in
        amd64) cf_arch="amd64" ;;
        arm64) cf_arch="arm64" ;;
        armv7) cf_arch="arm" ;;
        386)   cf_arch="386" ;;
        s390x) cf_arch="s390x" ;;
        *)
            error "cloudflared 不支持当前架构：$ARCH"
            return 1
            ;;
    esac

    if [ ! -x "$ARGO_BIN" ]; then
        error "未检测到 cloudflared。"
        warn "请先安装 VMess Argo。"
        return 1
    fi

    local current_raw current_version

    current_raw="$(
        "$ARGO_BIN" --version 2>/dev/null |
        head -n 1
    )"

    current_version="$(
        printf '%s\n' "$current_raw" |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1
    )"

    if [ -z "$current_version" ]; then
        error "无法读取当前 cloudflared 版本。"
        echo "当前版本信息：${current_raw:-unknown}"
        return 1
    fi

    echo "当前版本：v${current_version}"

    info "正在检查 Cloudflare 最新版本..."

    local release_json latest_version

    release_json="$(
        curl -fsSL \
            --connect-timeout 15 \
            --max-time 30 \
            --retry 3 \
            --retry-delay 2 \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: sing-box-manager" \
            "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
            2>/dev/null
    )"

    if [ -z "$release_json" ]; then
        error "无法获取 Cloudflare 最新版本信息。"
        warn "本次未执行更新，现有 cloudflared 保持不变。"
        return 1
    fi

    latest_version="$(
        printf '%s\n' "$release_json" |
        jq -r '.tag_name // empty' 2>/dev/null |
        sed 's/^v//'
    )"

    if [ -z "$latest_version" ]; then
        error "无法解析 Cloudflare 最新版本号。"
        warn "本次未执行更新，现有 cloudflared 保持不变。"
        return 1
    fi

    if ! [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "GitHub 返回的版本号格式异常：$latest_version"
        warn "本次未执行更新。"
        return 1
    fi

    echo "最新版本：v${latest_version}"
    echo

    local cur_major cur_minor cur_patch
    local new_major new_minor new_patch

    IFS='.' read -r cur_major cur_minor cur_patch <<< "$current_version"
    IFS='.' read -r new_major new_minor new_patch <<< "$latest_version"

    cur_major=${cur_major:-0}
    cur_minor=${cur_minor:-0}
    cur_patch=${cur_patch:-0}

    new_major=${new_major:-0}
    new_minor=${new_minor:-0}
    new_patch=${new_patch:-0}

    if [ "$cur_major" -eq "$new_major" ] &&
       [ "$cur_minor" -eq "$new_minor" ] &&
       [ "$cur_patch" -eq "$new_patch" ]; then

        success "cloudflared 已经是最新版本，无需更新。"
        echo
        echo "当前版本：v${current_version}"
        echo "最新版本：v${latest_version}"
        return 0
    fi

    if [ "$cur_major" -gt "$new_major" ] ||
       { [ "$cur_major" -eq "$new_major" ] &&
         [ "$cur_minor" -gt "$new_minor" ]; } ||
       { [ "$cur_major" -eq "$new_major" ] &&
         [ "$cur_minor" -eq "$new_minor" ] &&
         [ "$cur_patch" -gt "$new_patch" ]; }; then

        warn "当前 cloudflared 版本高于 GitHub 最新 Release。"
        echo "当前版本：v${current_version}"
        echo "最新版本：v${latest_version}"
        warn "为避免意外降级，本次不执行更新。"
        return 0
    fi

    echo "当前版本：v${current_version}"
    echo "最新版本：v${latest_version}"
    echo

    info "发现新版本，正在下载 cloudflared v${latest_version}..."

    local url
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"

    local tmp_bin

    tmp_bin="$(mktemp)"

    if ! curl -fL \
        --connect-timeout 15 \
        --max-time 300 \
        --retry 3 \
        --retry-delay 2 \
        -H "User-Agent: sing-box-manager" \
        "$url" \
        -o "$tmp_bin"; then

        error "cloudflared 新版本下载失败。"
        rm -f "$tmp_bin"
        return 1
    fi

    chmod 755 "$tmp_bin"

    local downloaded_raw downloaded_version

    downloaded_raw="$(
        "$tmp_bin" --version 2>/dev/null |
        head -n 1
    )"

    downloaded_version="$(
        printf '%s\n' "$downloaded_raw" |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1
    )"

    if [ -z "$downloaded_version" ]; then
        error "下载后的 cloudflared 无法正常运行。"
        rm -f "$tmp_bin"
        return 1
    fi

    if [ "$downloaded_version" != "$latest_version" ]; then
        error "下载后的 cloudflared 版本与 GitHub 最新版本不一致。"
        echo "GitHub 最新版本：v${latest_version}"
        echo "实际下载版本：v${downloaded_version}"
        rm -f "$tmp_bin"
        return 1
    fi

    success "新版本验证通过：v${downloaded_version}"

    local backup_bin
    backup_bin="${ARGO_BIN}.bak"

    if [ -x "$ARGO_BIN" ]; then
        if ! cp -a "$ARGO_BIN" "$backup_bin"; then
            error "无法备份当前 cloudflared，已取消更新。"
            rm -f "$tmp_bin"
            return 1
        fi

        chmod 755 "$backup_bin"

        info "旧版本已备份：$backup_bin"
    fi

    local fixed_argo_active=0
    local mode

    mode="$(service_mode)"

    case "$mode" in
        systemd)
            if systemctl is-active --quiet cloudflared-singbox 2>/dev/null; then
                fixed_argo_active=1
            fi
            ;;

        openrc)
            if rc-service cloudflared-singbox status >/dev/null 2>&1; then
                fixed_argo_active=1
            fi
            ;;

        manual)
            if [ -f "${PID_DIR}/fixed-argo.pid" ]; then
                local fixed_pid
                fixed_pid="$(cat "${PID_DIR}/fixed-argo.pid" 2>/dev/null)"

                if [ -n "$fixed_pid" ] &&
                   kill -0 "$fixed_pid" 2>/dev/null; then
                    fixed_argo_active=1
                fi
            fi
            ;;

        *)
            warn "无法识别 cloudflared 服务模式：$mode"
            ;;
    esac

    info "正在安装 cloudflared v${latest_version}..."

    if ! install -m 755 "$tmp_bin" "$ARGO_BIN"; then
        error "安装 cloudflared 新版本失败。"
        rm -f "$tmp_bin"

        if [ -x "$backup_bin" ]; then
            install -m 755 "$backup_bin" "$ARGO_BIN"
            success "旧版本 cloudflared 已恢复。"
        fi

        return 1
    fi

    rm -f "$tmp_bin"

    local final_raw final_version

    final_raw="$(
        "$ARGO_BIN" --version 2>/dev/null |
        head -n 1
    )"

    final_version="$(
        printf '%s\n' "$final_raw" |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1
    )"

    if [ "$final_version" != "$latest_version" ]; then
        error "更新后的 cloudflared 验证失败。"
        warn "正在恢复旧版本..."

        if [ -x "$backup_bin" ]; then
            install -m 755 "$backup_bin" "$ARGO_BIN"
            success "旧版本 cloudflared 已恢复。"
        else
            error "找不到旧版本备份文件：$backup_bin"
        fi

        return 1
    fi

    success "cloudflared 新版本安装成功：v${final_version}"

    if [ "$fixed_argo_active" != "1" ]; then
        echo
        info "固定 Argo 当前未运行，不主动启动服务。"
        echo
        success "Cloudflare cloudflared 更新成功！"
        echo "更新前：v${current_version}"
        echo "更新后：v${final_version}"

        if [ -x "$backup_bin" ]; then
            echo "旧版本备份：$backup_bin"
        fi

        return 0
    fi

    echo
    info "检测到固定 Argo 正在运行。"
    info "正在重启固定 Argo 以应用新版本..."

    stop_fixed_argo

    local restart_ok=0

    case "$mode" in
        systemd)
            if systemctl start cloudflared-singbox >/dev/null 2>&1; then
                sleep 2

                if systemctl is-active --quiet cloudflared-singbox 2>/dev/null; then
                    restart_ok=1
                fi
            fi
            ;;

        openrc)
            if rc-service cloudflared-singbox start >/dev/null 2>&1; then
                sleep 2

                if rc-service cloudflared-singbox status >/dev/null 2>&1; then
                    restart_ok=1
                fi
            fi
            ;;

        manual)
            local fixed_domain fixed_token fixed_port

            fixed_domain="$(
                jq -r '.fixed_vmess.domain // empty' \
                    "$STATE_FILE" 2>/dev/null
            )"

            fixed_token="$(
                jq -r '.fixed_vmess.key // empty' \
                    "$STATE_FILE" 2>/dev/null
            )"

            fixed_port="$(
                jq -r '.fixed_vmess.port // empty' \
                    "$STATE_FILE" 2>/dev/null
            )"

            if [ -n "$fixed_domain" ] &&
               [ -n "$fixed_token" ] &&
               [ -n "$fixed_port" ]; then

                if configure_fixed_argo \
                    "$fixed_domain" \
                    "$fixed_port" \
                    "$fixed_token" >/dev/null 2>&1; then

                    sleep 2

                    if [ -f "${PID_DIR}/fixed-argo.pid" ]; then
                        local new_fixed_pid
                        new_fixed_pid="$(
                            cat "${PID_DIR}/fixed-argo.pid" 2>/dev/null
                        )"

                        if [ -n "$new_fixed_pid" ] &&
                           kill -0 "$new_fixed_pid" 2>/dev/null; then
                            restart_ok=1
                        fi
                    fi
                fi
            fi
            ;;
    esac

    if [ "$restart_ok" != "1" ]; then
        error "新版本 cloudflared 启动失败。"
        warn "正在恢复旧版本 cloudflared..."

        stop_fixed_argo

        if [ -x "$backup_bin" ]; then
            install -m 755 "$backup_bin" "$ARGO_BIN"
        else
            error "找不到旧版本备份文件：$backup_bin"
            return 1
        fi

        local old_domain old_token old_port

        old_domain="$(
            jq -r '.fixed_vmess.domain // empty' \
                "$STATE_FILE" 2>/dev/null
        )"

        old_token="$(
            jq -r '.fixed_vmess.key // empty' \
                "$STATE_FILE" 2>/dev/null
        )"

        old_port="$(
            jq -r '.fixed_vmess.port // empty' \
                "$STATE_FILE" 2>/dev/null
        )"

        if [ -n "$old_domain" ] &&
           [ -n "$old_token" ] &&
           [ -n "$old_port" ]; then

            if configure_fixed_argo \
                "$old_domain" \
                "$old_port" \
                "$old_token" >/dev/null 2>&1; then

                success "旧版本 cloudflared 已恢复。"
                warn "本次更新已取消，固定 Argo 已恢复运行。"
            else
                error "旧版本已恢复，但固定 Argo 启动失败。"
                error "请检查：$ARGO_LOG"
            fi
        else
            error "无法读取固定 Argo 配置，无法自动恢复服务。"
        fi

        return 1
    fi

    echo
    success "Cloudflare cloudflared 更新成功！"
    echo "更新前：v${current_version}"
    echo "更新后：v${final_version}"
    echo "固定 Argo：已重新启动"

    if [ -x "$backup_bin" ]; then
        echo "旧版本备份：$backup_bin"
    fi

    return 0
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

# ============================================================
# sing-box 1.14 DNS 配置自动迁移
# ============================================================

migrate_dns_in_file() {
    local f="$1"
    [ -f "$f" ] || return 0

    jq empty "$f" >/dev/null 2>&1 || return 0

    local need_cache=0 need_rules=0
    jq -e '.dns.independent_cache' "$f" >/dev/null 2>&1 && need_cache=1
    jq -e '
        [ .dns.rules[]?
          | select( (has("ip_cidr") or has("ip_is_private")
                     or has("ip_accept_any")
                     or has("response_rcode") or has("response_answer")
                     or has("response_ns") or has("response_extra"))
                    and (has("match_response") | not) )
        ] | length > 0
    ' "$f" >/dev/null 2>&1 && need_rules=1

    if [ "$need_cache" = "0" ] && [ "$need_rules" = "0" ]; then
        return 0
    fi

    info "检测到 $(basename "$f") 使用旧版 DNS 配置，正在自动迁移..."

    local tmp
    tmp="$(mktemp)"
    if ! jq '
        ( if (.dns | type) == "object" and (.dns | has("independent_cache"))
          then .dns |= del(.independent_cache)
          else .
          end )
        |
        ( if (.dns | type) == "object" and (.dns | has("rules")) and ((.dns.rules | type) == "array")
          then
            .dns.rules = (
                [ .dns.rules[]
                  | select( (has("ip_cidr") or has("ip_is_private")
                             or has("ip_accept_any")
                             or has("response_rcode") or has("response_answer")
                             or has("response_ns") or has("response_extra"))
                            and (has("match_response") | not) )
                  | ( { action: "evaluate" }
                      + (if has("server") then { server: .server } else {} end)
                      + (if has("client_subnet") then { client_subnet: .client_subnet } else {} end)
                      + (if has("disable_cache") then { disable_cache: .disable_cache } else {} end) )
                ]
                +
                [ .dns.rules[]
                  | if ( (has("ip_cidr") or has("ip_is_private")
                          or has("ip_accept_any")
                          or has("response_rcode") or has("response_answer")
                          or has("response_ns") or has("response_extra"))
                         and (has("match_response") | not) )
                    then . + { match_response: true }
                    else .
                    end
                ]
            )
          else .
          end )
    ' "$f" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        warn "自动迁移 $(basename "$f") 失败（jq 表达式报错）。"
        return 1
    fi

    if ! jq empty "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "自动迁移 $(basename "$f") 失败（生成的 JSON 无效）。"
        return 1
    fi

    cp -a "$f" "${f}.bak.dns-migration-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    mv "$tmp" "$f"
    success "已自动迁移 DNS 配置：$(basename "$f")"
    return 0
}

auto_migrate_dns_config() {
    ensure_config >/dev/null 2>&1 || true

    if [ "$CONFIG_MODE" = "file" ]; then
        migrate_dns_in_file "$CONFIG_FILE" || true
    else
        local f
        for f in "$CONFIG_DIR"/*.json; do
            [ -f "$f" ] || continue
            migrate_dns_in_file "$f" || true
        done
    fi

    if [ "$CONFIG_MODE" = "directory" ] && [ -f "$CONFIG_FILE" ]; then
        migrate_dns_in_file "$CONFIG_FILE" || true
    fi
    return 0
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
    auto_migrate_dns_config >/dev/null 2>&1 || true
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
    auto_migrate_dns_config >/dev/null 2>&1 || true
    local mode
    mode="$(service_mode)"
    case "$mode" in
        systemd)
            create_systemd_service
            systemctl restart sing-box
            sleep 1
            if ! systemctl is-active --quiet sing-box; then
                error "sing-box 重启失败。"
                systemctl --no-pager --full status sing-box 2>/dev/null | tail -n 20
                return 1
            fi
            ;;
        openrc)
            create_openrc_service
            rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1
            sleep 1
            if ! rc-service sing-box status >/dev/null 2>&1; then
                error "sing-box 重启失败。"
                return 1
            fi
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
            if ! kill -0 "$(cat "${PID_DIR}/sing-box.pid")" 2>/dev/null; then
                error "sing-box 重启失败。"
                tail -n 30 "${LOG_DIR}/sing-box.log" 2>/dev/null
                return 1
            fi
            ;;
    esac
    return 0
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
    auto_migrate_dns_config >/dev/null 2>&1 || true
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

# ============================================================
# 节点别名（带磁盘缓存）
#
# 改动：
#   - 首次拉取后把 country / isp 缓存到
#     ${MANAGER_DIR}/.geo.cache
#   - 缓存有效期 24 小时
#   - 缓存有效期内，load_node_geo 直接读文件，不再发外网请求
# ============================================================

_NODE_ALIAS_COUNTRY=""
_NODE_ALIAS_ISP=""
_NODE_ALIAS_LOADED=0

GEO_CACHE_FILE="${MANAGER_DIR}/.geo.cache"
GEO_CACHE_TTL=86400

load_node_geo() {
    [ "$_NODE_ALIAS_LOADED" = "1" ] && return 0

    # --------------------------------------------------------
    # 1) 尝试读缓存
    # --------------------------------------------------------
    if [ -f "$GEO_CACHE_FILE" ]; then
        local cache_mtime now
        cache_mtime="$(stat -c %Y "$GEO_CACHE_FILE" 2>/dev/null || echo 0)"
        now="$(date +%s)"

        if [ -n "$cache_mtime" ] && [ "$cache_mtime" -gt 0 ] &&
           [ $((now - cache_mtime)) -lt "$GEO_CACHE_TTL" ]; then

            local cached_country cached_isp
            cached_country="$(sed -n '1p' "$GEO_CACHE_FILE" 2>/dev/null)"
            cached_isp="$(sed -n '2p' "$GEO_CACHE_FILE" 2>/dev/null)"

            if [ -n "$cached_country" ] && [ -n "$cached_isp" ]; then
                _NODE_ALIAS_COUNTRY="$cached_country"
                _NODE_ALIAS_ISP="$cached_isp"
                _NODE_ALIAS_LOADED=1
                return 0
            fi
        fi
    fi

    # --------------------------------------------------------
    # 2) 缓存无效：重新拉取
    # --------------------------------------------------------
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

    # --------------------------------------------------------
    # 3) 写入缓存
    # --------------------------------------------------------
    if [ -d "$MANAGER_DIR" ]; then
        {
            printf '%s\n' "$_NODE_ALIAS_COUNTRY"
            printf '%s\n' "$_NODE_ALIAS_ISP"
        } > "$GEO_CACHE_FILE" 2>/dev/null || true
        chmod 600 "$GEO_CACHE_FILE" 2>/dev/null || true
    fi

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

# ============================================================
# 服务器 IP（带磁盘缓存）
#
# 改动：
#   - 结果缓存到 ${MANAGER_DIR}/.ip.cache
#   - 有效期 10 分钟
#   - 缓存格式：第一行 IP，第二行 ipv4/ipv6/unknown
# ============================================================

IP_CACHE_FILE="${MANAGER_DIR}/.ip.cache"
IP_CACHE_TTL=600

load_server_ip() {
    # --------------------------------------------------------
    # 1) 尝试读缓存
    # --------------------------------------------------------
    if [ -f "$IP_CACHE_FILE" ]; then
        local cache_mtime now
        cache_mtime="$(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0)"
        now="$(date +%s)"

        if [ -n "$cache_mtime" ] && [ "$cache_mtime" -gt 0 ] &&
           [ $((now - cache_mtime)) -lt "$IP_CACHE_TTL" ]; then

            local cached_ip cached_ver
            cached_ip="$(sed -n '1p' "$IP_CACHE_FILE" 2>/dev/null)"
            cached_ver="$(sed -n '2p' "$IP_CACHE_FILE" 2>/dev/null)"

            if [ -n "$cached_ip" ] && [ "$cached_ip" != "你的服务器IP" ]; then
                SERVER_IP="$cached_ip"
                SERVER_IP_VERSION="$cached_ver"
                return 0
            fi
        fi
    fi

    # --------------------------------------------------------
    # 2) 缓存无效：重新探测
    # --------------------------------------------------------
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

    # --------------------------------------------------------
    # 3) 写入缓存
    # --------------------------------------------------------
    if [ -d "$MANAGER_DIR" ] && [ "$SERVER_IP" != "你的服务器IP" ]; then
        {
            printf '%s\n' "$SERVER_IP"
            printf '%s\n' "$SERVER_IP_VERSION"
        } > "$IP_CACHE_FILE" 2>/dev/null || true
        chmod 600 "$IP_CACHE_FILE" 2>/dev/null || true
    fi
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
    CANCELLED=1
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
# VMess Argo 运行时文件
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

is_pid_running() {
    local pid="$1"

    [ -n "$pid" ] || return 1

    kill -0 "$pid" >/dev/null 2>&1
}

start_temp_argo() {
    local tag="$1"
    local port="$2"

    local log
    local pidfile
    local pid

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

    pid=$!

    echo "$pid" > "$pidfile"

    sleep 3

    if ! is_pid_running "$pid"; then
        warn "Cloudflare 临时 Argo 启动失败。"
        warn "日志：$log"

        if [ -f "$log" ]; then
            tail -n 20 "$log" 2>/dev/null || true
        fi

        rm -f "$pidfile"

        return 1
    fi

    return 0
}

stop_temp_argo() {
    local tag="$1"

    local pidfile
    local pid

    pidfile="$(temp_argo_pid "$tag")"

    if [ ! -f "$pidfile" ]; then
        return 0
    fi

    pid="$(cat "$pidfile" 2>/dev/null)"

    if [ -n "$pid" ]; then

        if is_pid_running "$pid"; then
            kill "$pid" >/dev/null 2>&1 || true
        fi

        local i

        for i in 1 2 3 4 5 6; do
            if ! is_pid_running "$pid"; then
                break
            fi

            sleep 0.5
        done

        if is_pid_running "$pid"; then
            kill -9 "$pid" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "$pidfile"

    return 0
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

            if is_pid_running "$pid"; then
                kill "$pid" >/dev/null 2>&1 || true
            fi

            local i

            for i in 1 2 3 4 5 6; do
                if ! is_pid_running "$pid"; then
                    break
                fi

                sleep 0.5
            done

            if is_pid_running "$pid"; then
                kill -9 "$pid" >/dev/null 2>&1 || true
            fi
        fi

        rm -f "${PID_DIR}/fixed-argo.pid"
    fi
}

stop_argo() {

    stop_fixed_argo

    local f
    local pid

    for f in "${PID_DIR}"/argo-*.pid; do

        [ -f "$f" ] || continue

        pid="$(cat "$f" 2>/dev/null)"

        if [ -n "$pid" ]; then

            if is_pid_running "$pid"; then
                kill "$pid" >/dev/null 2>&1 || true
            fi

            local i

            for i in 1 2 3 4 5 6; do
                if ! is_pid_running "$pid"; then
                    break
                fi

                sleep 0.5
            done

            if is_pid_running "$pid"; then
                kill -9 "$pid" >/dev/null 2>&1 || true
            fi
        fi

        rm -f "$f"
    done
}

get_random_vmess_port() {

    local port

    while true; do

        port="$(shuf -i 10000-65000 -n 1)"

        if ! ss -lntup 2>/dev/null |
            grep -Eq "[:.]${port}[[:space:]]"; then

            echo "$port"
            return 0
        fi

    done
}

get_vmess_tag() {

    ensure_config >/dev/null 2>&1 || return 1

    local source

    source="$(get_config_source)"

    jq -r \
        '.inbounds[]? |
         select(.type == "vmess") |
         .tag' \
        "$source" 2>/dev/null |
        head -n 1
}

get_vmess_uuid_by_tag() {

    local tag="$1"

    ensure_config >/dev/null 2>&1 || return 1

    local source

    source="$(get_config_source)"

    jq -r \
        --arg tag "$tag" \
        '.inbounds[]? |
         select(.tag == $tag) |
         .users[0].uuid // empty' \
        "$source" 2>/dev/null
}

get_vmess_port_by_tag() {

    local tag="$1"

    ensure_config >/dev/null 2>&1 || return 1

    local source

    source="$(get_config_source)"

    jq -r \
        --arg tag "$tag" \
        '.inbounds[]? |
         select(.tag == $tag) |
         .listen_port // empty' \
        "$source" 2>/dev/null
}

update_vmess_port() {

    local tag="$1"
    local port="$2"

    ensure_config || return 1

    local tmp

    tmp="$(mktemp)"

    if [ "$CONFIG_MODE" = "directory" ]; then

        jq \
            --arg tag "$tag" \
            --argjson port "$port" \
            '(.inbounds[] |
              select(.tag == $tag) |
              .listen_port) = $port' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "修改 VMess 端口失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq \
            --arg tag "$tag" \
            --argjson port "$port" \
            '(.inbounds[] |
              select(.tag == $tag) |
              .listen_port) = $port' \
            "$CONFIG_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "修改 VMess 端口失败。"

            return 1
        }

        mv "$tmp" "$CONFIG_FILE"
    fi

    return 0
}

clear_fixed_vmess_state() {

    ensure_state_file

    local tmp

    tmp="$(mktemp)"

    if jq \
        '.fixed_vmess = {
            tag:"",
            domain:"",
            key:"",
            port:0,
            uuid:""
        }' \
        "$STATE_FILE" > "$tmp" 2>/dev/null; then

        mv "$tmp" "$STATE_FILE"

        chmod 600 "$STATE_FILE"

        return 0
    fi

    rm -f "$tmp"

    return 1
}

install_vmess_temp() {

    clear

    echo -e "${GREEN}========== VMess 临时 Argo ==========${NC}"

    echo

    warn_existing_protocol "vmess" "VMess" || return 1

    echo

    local port
    local uuid
    local tag

    port="$(get_random_vmess_port)"
    uuid="$(random_uuid)"
    tag="$(unique_tag "vmess-argo")"

    ensure_runtime_dirs

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
            users: [
                {
                    uuid: $uuid
                }
            ],
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

        jq \
            --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加 VMess 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq \
            --argjson inbound "$inbound" \
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

    if ! restart_singbox; then

        error "sing-box 启动失败，VMess 未启用。"

        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true

        restart_singbox >/dev/null 2>&1 || true

        return 1
    fi

    if ! start_temp_argo "$tag" "$port"; then

        error "Cloudflare 临时 Argo 启动失败。"

        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true

        restart_singbox >/dev/null 2>&1 || true

        return 1
    fi

    local domain=""
    local log

    log="$(temp_argo_log "$tag")"

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do

        domain="$(get_temp_argo_domain "$tag" 2>/dev/null || true)"

        [ -n "$domain" ] && break

        if [ -f "$log" ]; then

            if grep -qiE \
                'failed|error|fatal|unable' \
                "$log" 2>/dev/null; then

                break
            fi
        fi

        sleep 2
    done

    if [ -z "$domain" ]; then

        error "没有获取到 Cloudflare 临时 Argo 域名。"

        warn "正在回滚临时 Argo 节点..."

        stop_temp_argo "$tag"

        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true

        if check_config >/dev/null 2>&1; then
            restart_singbox >/dev/null 2>&1 || true
        fi

        warn "请查看日志：$log"

        if [ -f "$log" ]; then
            echo
            tail -n 30 "$log" 2>/dev/null || true
        fi

        return 1
    fi

    local preferred

    preferred="$(get_preferred_domain 2>/dev/null || true)"

    local client_domain="$domain"

    if [ -n "$preferred" ]; then
        client_domain="$preferred"
    fi

    echo

    success "VMess 临时 Argo 安装成功。"

    echo

    echo "节点标签：$tag"
    echo "Argo 域名：$domain"

    if [ -n "$preferred" ]; then
        echo "优选地址：$preferred"
    fi

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

get_preferred_domain() {

    if [ -f "$STATE_FILE" ]; then

        jq -r \
            '.preferred_domain // empty' \
            "$STATE_FILE" 2>/dev/null
    fi
}

get_current_temp_vmess_argo_domain() {

    local tag
    local domain

    tag="$(get_vmess_tag 2>/dev/null || true)"

    [ -n "$tag" ] || return 1

    domain="$(get_temp_argo_domain "$tag" 2>/dev/null || true)"

    if printf '%s' "$domain" |
        grep -Eq \
        '^[A-Za-z0-9.-]+\.trycloudflare\.com$'; then

        echo "$domain"

        return 0
    fi

    return 1
}

get_current_argo_test_host() {

    local fixed_domain=""
    local temp_domain=""

    if [ -f "$STATE_FILE" ]; then

        fixed_domain="$(
            jq -r \
                '.fixed_vmess.domain // empty' \
                "$STATE_FILE" 2>/dev/null
        )"

        fixed_domain="${fixed_domain#http://}"
        fixed_domain="${fixed_domain#https://}"
        fixed_domain="${fixed_domain%%/*}"

        if printf '%s' "$fixed_domain" |
            grep -Eq '^[A-Za-z0-9.-]+$'; then

            echo "${fixed_domain}|fixed"

            return 0
        fi
    fi

    temp_domain="$(
        get_current_temp_vmess_argo_domain \
        2>/dev/null || true
    )"

    if [ -n "$temp_domain" ]; then

        echo "${temp_domain}|temp"

        return 0
    fi

    echo "speed.cloudflare.com|generic"

    return 0
}

# ============================================================
# 显示所有 VMess 节点链接
#
# 改动：
#   - jq 读 inbounds.json 失败时自动重试一次
#   - 失败时不再完全静默，会打印一条提示
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

    # 首次读取失败（可能写盘竞态），短暂等待后重试一次
    if [ -z "$count" ] || [ "$count" = "null" ]; then
        sleep 0.3
        count="$(
            jq '.inbounds | length' \
                "$config_source" 2>/dev/null
        )"
    fi

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

                echo -e \
                    "${GREEN}========== 当前 VMess 节点链接 ==========${NC}"

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

        echo -e \
            "${GREEN}==========================================${NC}"

    else

        echo

        warn "当前没有 VMess 节点。"
    fi
}

detect_dns64_nat64_prefix() {

    local dns64_addr="$1"

    python3 - "$dns64_addr" <<'PY'
import sys
import ipaddress

try:
    addr = ipaddress.IPv6Address(sys.argv[1])

    low32 = int(addr) & 0xffffffff

    valid_values = {
        int(ipaddress.IPv4Address("192.0.0.170")),
        int(ipaddress.IPv4Address("192.0.0.171")),
    }

    if low32 not in valid_values:
        sys.exit(1)

    base = int(addr) & ~0xffffffff

    print(ipaddress.IPv6Address(base))

except Exception:
    sys.exit(1)
PY
}

get_dns64_test_address() {

    local addr=""

    if command -v getent >/dev/null 2>&1; then

        addr="$(
            getent ahostsv6 ipv4only.arpa 2>/dev/null |
            awk '
                $1 ~ /^[0-9a-fA-F:]+$/ {
                    print $1
                }
            ' |
            while IFS= read -r candidate; do

                if detect_dns64_nat64_prefix "$candidate" \
                    >/dev/null 2>&1; then

                    echo "$candidate"
                    break
                fi

            done
        )"
    fi

    [ -n "$addr" ] && {
        echo "$addr"
        return 0
    }

    if command -v dig >/dev/null 2>&1; then

        addr="$(
            dig +short AAAA ipv4only.arpa 2>/dev/null |
            while IFS= read -r candidate; do

                if printf '%s' "$candidate" |
                    grep -Eq '^[0-9a-fA-F:]+$'; then

                    if detect_dns64_nat64_prefix "$candidate" \
                        >/dev/null 2>&1; then

                        echo "$candidate"
                        break
                    fi
                fi

            done
        )"
    fi

    [ -n "$addr" ] && {
        echo "$addr"
        return 0
    }

    if command -v host >/dev/null 2>&1; then

        addr="$(
            host -t AAAA ipv4only.arpa 2>/dev/null |
            awk '/has IPv6 address/ {
                print $NF
            }' |
            while IFS= read -r candidate; do

                if detect_dns64_nat64_prefix "$candidate" \
                    >/dev/null 2>&1; then

                    echo "$candidate"
                    break
                fi

            done
        )"
    fi

    [ -n "$addr" ] && {
        echo "$addr"
        return 0
    }

    return 1
}

generate_nat64_ip() {

    local base="$1"
    local ipv4="$2"

    python3 - "$base" "$ipv4" <<'PY'
import sys
import ipaddress

try:
    base = ipaddress.IPv6Address(sys.argv[1])
    ipv4 = ipaddress.IPv4Address(sys.argv[2])

    result = ipaddress.IPv6Address(
        (int(base) & ~0xffffffff) | int(ipv4)
    )

    print(result)

except Exception:
    sys.exit(1)
PY
}

test_one_ip() {

    local ip="$1"
    local result_file="$2"

    local nat64_ip=""
    local result=""
    local tcp_time=""
    local tcp_tls_time=""
    local total_time=""

    if [ "$curl_family" = "ipv4" ]; then

        result="$(
            curl \
                -4 \
                -sS \
                -k \
                -o /dev/null \
                -w '%{time_connect}|%{time_appconnect}|%{time_total}' \
                --connect-timeout "$connect_timeout" \
                --max-time "$max_timeout" \
                --resolve "${test_host}:443:${ip}" \
                "$test_url" \
                2>/dev/null
        )"

    else

        nat64_ip="$(
            generate_nat64_ip \
                "$nat64_base" \
                "$ip"
        )"

        if [ -z "$nat64_ip" ]; then
            return 0
        fi

        result="$(
            curl \
                -6 \
                -sS \
                -k \
                -o /dev/null \
                -w '%{time_connect}|%{time_appconnect}|%{time_total}' \
                --connect-timeout "$connect_timeout" \
                --max-time "$max_timeout" \
                --resolve "${test_host}:443:[${nat64_ip}]" \
                "$test_url" \
                2>/dev/null
        )"
    fi

    if [ -z "$result" ]; then
        return 0
    fi

    tcp_time="$(printf '%s' "$result" | cut -d'|' -f1)"
    tcp_tls_time="$(printf '%s' "$result" | cut -d'|' -f2)"
    total_time="$(printf '%s' "$result" | cut -d'|' -f3)"

    if ! printf '%s' "$tcp_time" |
        grep -Eq '^[0-9]+([.][0-9]+)?$'; then

        return 0
    fi

    if ! awk "BEGIN {exit !($tcp_time > 0)}"; then
        return 0
    fi

    if ! printf '%s' "$tcp_tls_time" |
        grep -Eq '^[0-9]+([.][0-9]+)?$'; then

        return 0
    fi

    if ! awk "BEGIN {exit !($tcp_tls_time > 0)}"; then
        return 0
    fi

    if ! printf '%s' "$total_time" |
        grep -Eq '^[0-9]+([.][0-9]+)?$'; then

        return 0
    fi

    printf '%s|%s|%s|%s|%s\n' \
        "$tcp_time" \
        "$tcp_tls_time" \
        "$total_time" \
        "$ip" \
        "$nat64_ip" \
        > "$result_file"
}

# ============================================================
# 优选域名 / IP
#
# 改动（选项 1 结尾）：
#   - 去掉了 refresh_subscription 和 show_all_vmess_links
#     后面的 2>/dev/null，让错误信息可见
# ============================================================

set_preferred_domain() {

    ensure_state_file

    while true; do

        clear

        echo "============================================================"
        echo "              优选域名 / IP 设置"
        echo "============================================================"
        echo

        local current_domain=""

        current_domain="$(
            get_preferred_domain \
                2>/dev/null || true
        )"

        if [ -n "$current_domain" ]; then
            echo "当前优选地址：${current_domain}"
        else
            echo "当前优选地址：未设置"
        fi

        echo
        echo "1. 自动测速并选择最快 Cloudflare IP"
        echo "2. 手动设置优选域名 / IP"
        echo "3. 设置 WebDAV IP 列表地址"
        echo "4. 设置 WebDAV 用户名密码"
        echo "5. 清除优选地址"
        echo "0. 返回"
        echo

        read -r -p "请选择 [0-5]: " choice

        case "$choice" in

            # =================================================
            # 1. 自动测速
            # =================================================
            1)

                clear

                echo "============================================================"
                echo "              Cloudflare 优选 IP 自动测速"
                echo "============================================================"
                echo

                local optimizer_url=""
                local optimizer_auth=""

                optimizer_url="$(
                    jq -r \
                        '.optimizer_url // empty' \
                        "$STATE_FILE" 2>/dev/null
                )"

                optimizer_auth="$(
                    jq -r \
                        '.optimizer_auth // empty' \
                        "$STATE_FILE" 2>/dev/null
                )"

                echo "当前 IP 列表地址："

                if [ -n "$optimizer_url" ]; then
                    echo "  $optimizer_url"
                else
                    echo "  未设置"
                fi

                echo

                if [ -z "$optimizer_url" ]; then

                    read -r -p \
                        "请输入 WebDAV / IP 列表 URL: " \
                        optimizer_url

                    if [ -z "$optimizer_url" ]; then

                        warn "未输入 URL"

                        read -r -p \
                            "按回车继续..." _

                        continue
                    fi

                    local tmp_state=""

                    tmp_state="$(mktemp)"

                    if jq \
                        --arg url "$optimizer_url" \
                        '.optimizer_url = $url' \
                        "$STATE_FILE" > "$tmp_state"; then

                        mv "$tmp_state" "$STATE_FILE"

                        chmod 600 "$STATE_FILE"

                    else

                        rm -f "$tmp_state"

                        error "保存 WebDAV URL 失败。"

                        read -r -p \
                            "按回车继续..." _

                        continue
                    fi
                fi

                echo
                echo "正在获取 Cloudflare IPv4 候选列表..."
                echo

                local raw_content=""

                if [ -n "$optimizer_auth" ]; then

                    raw_content="$(
                        curl \
                            -sS \
                            -L \
                            -k \
                            --connect-timeout 10 \
                            --max-time 30 \
                            -u "$optimizer_auth" \
                            "$optimizer_url" \
                            2>/dev/null
                    )"

                else

                    raw_content="$(
                        curl \
                            -sS \
                            -L \
                            -k \
                            --connect-timeout 10 \
                            --max-time 30 \
                            "$optimizer_url" \
                            2>/dev/null
                    )"
                fi

                if [ -z "$raw_content" ]; then

                    error "无法从 IP 列表 URL 获取内容！"

                    echo
                    echo "请检查："
                    echo "  1. WebDAV URL 是否正确"
                    echo "  2. 用户名密码是否正确"
                    echo "  3. 当前 VPS 是否能够访问该 URL"
                    echo

                    read -r -p \
                        "按回车继续..." _

                    continue
                fi

                local ip_list=""

                ip_list="$(
                    printf '%s\n' "$raw_content" |
                    grep -oE \
                        '([0-9]{1,3}\.){3}[0-9]{1,3}' |
                    awk -F. '
                        $1 <= 255 &&
                        $2 <= 255 &&
                        $3 <= 255 &&
                        $4 <= 255 {
                            print
                        }
                    ' |
                    sort -u
                )"

                local ip_count=""

                ip_count="$(
                    printf '%s\n' "$ip_list" |
                    sed '/^[[:space:]]*$/d' |
                    wc -l
                )"

                if [ "${ip_count:-0}" -eq 0 ]; then

                    error "没有从 IP 列表中提取到有效 IPv4 地址！"

                    echo

                    read -r -p \
                        "按回车继续..." _

                    continue
                fi

                echo "成功获取 ${ip_count} 个候选 IPv4 地址。"
                echo

                local has_ipv4=0
                local has_ipv6=0

                if ip -4 route get 1.1.1.1 \
                    >/dev/null 2>&1; then

                    has_ipv4=1
                fi

                if ip -6 route get 2606:4700:4700::1111 \
                    >/dev/null 2>&1; then

                    has_ipv6=1
                fi

                local curl_family=""
                local dns64_test=""
                local nat64_base=""

                if [ "$has_ipv4" -eq 1 ]; then

                    curl_family="ipv4"

                    echo \
                        "检测到 IPv4 出口：使用 IPv4 → Cloudflare IPv4"

                elif [ "$has_ipv6" -eq 1 ]; then

                    curl_family="nat64"

                    echo \
                        "未检测到 IPv4 出口：当前 VPS 为纯 IPv6"

                    echo "正在检测 DNS64 / NAT64..."
                    echo

                    dns64_test="$(
                        get_dns64_test_address \
                            2>/dev/null || true
                    )"

                    if [ -z "$dns64_test" ]; then

                        error "未检测到有效 DNS64 合成地址！"

                        echo
                        echo "当前 VPS 是纯 IPv6，"
                        echo "但 DNS 没有返回有效的 DNS64 地址。"
                        echo
                        echo "检测目标：ipv4only.arpa"
                        echo
                        echo "正常 DNS64 应该把："
                        echo "  192.0.0.170"
                        echo "  192.0.0.171"
                        echo
                        echo "合成为 IPv6 地址。"
                        echo

                        read -r -p \
                            "按回车继续..." _

                        continue
                    fi

                    echo \
                        "检测到有效 DNS64 合成地址：${dns64_test}"

                    nat64_base="$(
                        detect_dns64_nat64_prefix \
                            "$dns64_test" \
                            2>/dev/null
                    )"

                    if [ -z "$nat64_base" ]; then

                        error "无法计算 NAT64 /96 基址！"

                        echo
                        echo "DNS64 地址：${dns64_test}"
                        echo

                        read -r -p \
                            "按回车继续..." _

                        continue
                    fi

                    echo "NAT64 基址：${nat64_base}/96"
                    echo
                    echo \
                        "测速通道：IPv6 → NAT64 → Cloudflare IPv4"

                else

                    error \
                        "当前 VPS 没有可用的 IPv4 或 IPv6 出口！"

                    echo

                    read -r -p \
                        "按回车继续..." _

                    continue
                fi

                local argo_test_info=""
                local test_host=""
                local test_source=""

                argo_test_info="$(
                    get_current_argo_test_host \
                        2>/dev/null
                )"

                test_host="$(
                    printf '%s' "$argo_test_info" |
                    cut -d'|' -f1
                )"

                test_source="$(
                    printf '%s' "$argo_test_info" |
                    cut -d'|' -f2
                )"

                if [ -z "$test_host" ]; then

                    test_host="speed.cloudflare.com"
                    test_source="generic"
                fi

                local test_url="https://${test_host}/cdn-cgi/trace"

                local concurrency=10
                local connect_timeout=5
                local max_timeout=10
                local max_candidates=100

                if [ "$ip_count" -gt "$max_candidates" ]; then

                    ip_list="$(
                        printf '%s\n' "$ip_list" |
                        head -n "$max_candidates"
                    )"

                    ip_count="$max_candidates"
                fi

                echo
                echo "============================================================"
                echo "             Cloudflare 真实 HTTPS/TLS 测速"
                echo "============================================================"
                echo

                if [ "$test_source" = "temp" ]; then

                    echo "测试模式：当前 VMess 临时 Argo"

                elif [ "$test_source" = "fixed" ]; then

                    echo "测试模式：当前 VMess 固定 Argo"

                else

                    echo "测试模式：Cloudflare 通用测试"

                fi

                echo
                echo "测试 Host/SNI：${test_host}"
                echo "测试 URL：${test_url}"
                echo "测试数量：${ip_count}"
                echo "并发数量：${concurrency}"
                echo

                echo "测试链路："

                if [ "$curl_family" = "ipv4" ]; then

                    echo \
                        "  VPS IPv4 → Cloudflare IPv4:443"

                else

                    echo \
                        "  VPS IPv6 → NAT64 → Cloudflare IPv4:443"
                fi

                echo
                echo "测试内容："
                echo "  TCP 建连"
                echo "  TLS 握手"
                echo "  HTTPS 请求"
                echo
                echo "注意："
                echo "  不使用你的 VMess 数据"
                echo "  不使用 Google"
                echo "  HTTP 状态码不参与排名"
                echo "  排名主要依据 TCP + TLS 完成时间"
                echo

                local tmp_dir=""

                tmp_dir="$(
                    mktemp -d /tmp/cf_optimizer.XXXXXX
                )"

                if [ ! -d "$tmp_dir" ]; then

                    error "无法创建临时测速目录！"

                    read -r -p \
                        "按回车继续..." _

                    continue
                fi

                local batch_count=0
                local batch_no=0
                local running_pids=""

                while IFS= read -r ip; do

                    [ -z "$ip" ] && continue

                    batch_no=$((batch_no + 1))
                    batch_count=$((batch_count + 1))

                    local result_file=""

                    result_file="${tmp_dir}/result_${batch_no}"

                    test_one_ip \
                        "$ip" \
                        "$result_file" &

                    running_pids="${running_pids} $!"

                    if [ "$batch_count" -ge "$concurrency" ]; then

                        for pid in $running_pids; do
                            wait "$pid" 2>/dev/null || true
                        done

                        running_pids=""

                        batch_count=0
                    fi

                done <<< "$ip_list"

                if [ -n "$running_pids" ]; then

                    for pid in $running_pids; do
                        wait "$pid" 2>/dev/null || true
                    done
                fi

                local best_result=""

                if compgen -G \
                    "$tmp_dir/result_*" \
                    >/dev/null 2>&1; then

                    best_result="$(
                        cat "$tmp_dir"/result_* 2>/dev/null |
                        awk -F'|' '
                            NF >= 4 &&
                            $1 ~ /^[0-9]+([.][0-9]+)?$/ &&
                            $2 ~ /^[0-9]+([.][0-9]+)?$/ &&
                            $3 ~ /^[0-9]+([.][0-9]+)?$/ &&
                            $2 > 0
                        ' |
                        sort -t'|' \
                            -k2,2n \
                            -k3,3n |
                        head -n 1
                    )"
                fi

                if [ -z "$best_result" ]; then

                    rm -rf "$tmp_dir"

                    error \
                        "测速失败：所有 Cloudflare IPv4 均无法完成 TLS 握手！"

                    echo
                    echo "测试 Host/SNI：${test_host}"
                    echo "测试地址：${test_url}"
                    echo

                    if [ "$curl_family" = "nat64" ]; then

                        echo \
                            "测速通道：IPv6 → NAT64 → Cloudflare IPv4"

                        echo \
                            "DNS64：${dns64_test}"

                        echo \
                            "NAT64 基址：${nat64_base}"

                    else

                        echo \
                            "测速通道：IPv4 → Cloudflare IPv4"
                    fi

                    echo
                    echo "HTTP 状态码不参与测速结果判断。"
                    echo "只要 TCP + TLS 成功，就可以参与排名。"
                    echo

                    read -r -p \
                        "按回车继续..." _

                    continue
                fi

                local best_connect=""
                local best_tls=""
                local best_total=""
                local best_ip=""
                local best_nat64_ip=""

                best_connect="$(
                    printf '%s' "$best_result" |
                    cut -d'|' -f1
                )"

                best_tls="$(
                    printf '%s' "$best_result" |
                    cut -d'|' -f2
                )"

                best_total="$(
                    printf '%s' "$best_result" |
                    cut -d'|' -f3
                )"

                best_ip="$(
                    printf '%s' "$best_result" |
                    cut -d'|' -f4
                )"

                best_nat64_ip="$(
                    printf '%s' "$best_result" |
                    cut -d'|' -f5
                )"

                local best_connect_ms=""
                local best_tls_ms=""
                local best_total_ms=""

                best_connect_ms="$(
                    awk \
                        "BEGIN {printf \"%.0f\", $best_connect * 1000}"
                )"

                best_tls_ms="$(
                    awk \
                        "BEGIN {printf \"%.0f\", $best_tls * 1000}"
                )"

                best_total_ms="$(
                    awk \
                        "BEGIN {printf \"%.0f\", $best_total * 1000}"
                )"

                echo
                echo "============================================================"
                echo "             Cloudflare HTTPS/TLS 最快 IP"
                echo "============================================================"
                echo

                echo "Cloudflare IPv4：${best_ip}"
                echo "TCP 建连：        ${best_connect_ms}ms"
                echo "TCP + TLS：       ${best_tls_ms}ms"
                echo "HTTPS 总耗时：    ${best_total_ms}ms"
                echo

                if [ "$curl_family" = "nat64" ]; then

                    echo \
                        "NAT64 IPv6：      ${best_nat64_ip}"

                    echo
                fi

                echo "测试 Host/SNI：   ${test_host}"
                echo "测试 URL：        ${test_url}"
                echo

                echo \
                    "VPS → Cloudflare TCP+TLS：${best_tls_ms}ms"

                echo

                local tmp_state=""

                tmp_state="$(mktemp)"

                if jq \
                    --arg domain "$best_ip" \
                    '.preferred_domain = $domain' \
                    "$STATE_FILE" > "$tmp_state"; then

                    mv "$tmp_state" "$STATE_FILE"

                    chmod 600 "$STATE_FILE"

                else

                    rm -f "$tmp_state"
                    rm -rf "$tmp_dir"

                    error "保存优选 IP 失败。"

                    read -r -p \
                        "按回车继续..." _

                    continue
                fi

                rm -rf "$tmp_dir"

                success \
                    "最快 Cloudflare IP 已设置：${best_ip}"

                success \
                    "VPS → Cloudflare TCP+TLS：${best_tls_ms}ms"

                echo

                echo "正在刷新 VMess 节点..."
                echo

                refresh_subscription

                echo

                echo "正在重新显示 VMess 节点..."
                echo

                show_all_vmess_links

                echo

                read -r -p \
                    "按回车返回..." _

                ;;

            # =================================================
            # 2. 手动设置
            # =================================================
            2)

                clear

                echo "============================================================"
                echo "              手动设置优选域名 / IP"
                echo "============================================================"
                echo

                current_domain="$(
                    get_preferred_domain \
                        2>/dev/null || true
                )"

                echo \
                    "当前优选地址：${current_domain:-未设置}"

                echo

                local manual_domain=""

                read -r -p \
                    "请输入优选域名或 IPv4 地址（留空取消）: " \
                    manual_domain

                if [ -n "$manual_domain" ]; then

                    local tmp_state=""

                    tmp_state="$(mktemp)"

                    if jq \
                        --arg domain "$manual_domain" \
                        '.preferred_domain = $domain' \
                        "$STATE_FILE" > "$tmp_state"; then

                        mv "$tmp_state" "$STATE_FILE"

                        chmod 600 "$STATE_FILE"

                        success \
                            "优选地址已设置：${manual_domain}"

                        echo
                        echo "正在刷新 VMess 节点..."

                        refresh_subscription 2>/dev/null || true

                        echo

                        show_all_vmess_links

                    else

                        rm -f "$tmp_state"

                        error "保存优选地址失败。"
                    fi
                fi

                echo

                read -r -p \
                    "按回车返回..." _

                ;;

            # =================================================
            # 3. WebDAV URL
            # =================================================
            3)

                clear

                echo "============================================================"
                echo "              设置 WebDAV IP 列表地址"
                echo "============================================================"
                echo

                local optimizer_url=""

                optimizer_url="$(
                    jq -r \
                        '.optimizer_url // empty' \
                        "$STATE_FILE" 2>/dev/null
                )"

                echo \
                    "当前地址：${optimizer_url:-未设置}"

                echo

                local new_url=""

                read -r -p \
                    "请输入新的 WebDAV / IP 列表 URL（留空取消）: " \
                    new_url

                if [ -n "$new_url" ]; then

                    local tmp_state=""

                    tmp_state="$(mktemp)"

                    if jq \
                        --arg url "$new_url" \
                        '.optimizer_url = $url' \
                        "$STATE_FILE" > "$tmp_state"; then

                        mv "$tmp_state" "$STATE_FILE"

                        chmod 600 "$STATE_FILE"

                        success \
                            "WebDAV IP 列表地址已保存。"

                    else

                        rm -f "$tmp_state"

                        error "保存 WebDAV URL 失败。"
                    fi
                fi

                echo

                read -r -p \
                    "按回车返回..." _

                ;;

            # =================================================
            # 4. WebDAV 认证
            # =================================================
            4)

                clear

                echo "============================================================"
                echo "              设置 WebDAV 用户名密码"
                echo "============================================================"
                echo

                echo "如果 WebDAV 不需要认证，可以直接清空。"
                echo

                local webdav_user=""
                local webdav_pass=""
                local new_auth=""

                read -r -p \
                    "用户名: " \
                    webdav_user

                if [ -n "$webdav_user" ]; then

                    read -r -s -p \
                        "密码: " \
                        webdav_pass

                    echo

                    new_auth="${webdav_user}:${webdav_pass}"

                else

                    new_auth=""
                fi

                local tmp_state=""

                tmp_state="$(mktemp)"

                if jq \
                    --arg auth "$new_auth" \
                    '.optimizer_auth = $auth' \
                    "$STATE_FILE" > "$tmp_state"; then

                    mv "$tmp_state" "$STATE_FILE"

                    chmod 600 "$STATE_FILE"

                    if [ -n "$new_auth" ]; then

                        success \
                            "WebDAV 用户名密码已保存。"

                    else

                        success \
                            "WebDAV 认证已清除。"
                    fi

                else

                    rm -f "$tmp_state"

                    error "保存 WebDAV 认证失败。"
                fi

                echo

                read -r -p \
                    "按回车返回..." _

                ;;

            # =================================================
            # 5. 清除
            # =================================================
            5)

                clear

                echo "============================================================"
                echo "                  清除优选地址"
                echo "============================================================"
                echo

                current_domain="$(
                    get_preferred_domain \
                        2>/dev/null || true
                )"

                if [ -z "$current_domain" ]; then

                    info "当前没有设置优选地址。"

                else

                    echo \
                        "当前优选地址：${current_domain}"

                    echo

                    local confirm=""

                    read -r -p \
                        "确定清除吗？[y/N]: " \
                        confirm

                    case "$confirm" in

                        y|Y)

                            local tmp_state=""

                            tmp_state="$(mktemp)"

                            if jq \
                                '.preferred_domain = "" |
                                 .optimizer_url = "" |
                                 .optimizer_auth = ""' \
                                "$STATE_FILE" > "$tmp_state"; then

                                mv "$tmp_state" "$STATE_FILE"

                                chmod 600 "$STATE_FILE"

                                success \
                                    "优选地址、WebDAV URL 和认证信息已全部清除。"

                                echo
                                echo "正在刷新 VMess 节点..."

                                refresh_subscription \
                                    2>/dev/null || true

                            else

                                rm -f "$tmp_state"

                                error "清除优选配置失败。"
                            fi

                            ;;

                        *)

                            info "已取消。"

                            ;;
                    esac
                fi

                echo

                read -r -p \
                    "按回车返回..." _

                ;;

            # =================================================
            # 0. 返回
            # =================================================
            0)

                return

                ;;

            *)

                warn "无效选择。"

                sleep 1

                ;;
        esac
    done
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

        error \
            "已经存在固定 Argo 节点：$existing_tag"

        warn \
            "请先卸载它，或使用“修改固定隧道”功能。"

        return 1
    fi

    echo

    local domain

    read -r -p \
        "请输入 Cloudflare Tunnel 域名： " \
        domain

    [ -z "$domain" ] && {
        error "域名不能为空。"
        return 1
    }

    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    echo

    local token

    read -r -p \
        "请输入 Cloudflare Tunnel Token： " \
        token

    echo

    [ -z "$token" ] && {
        error "Cloudflare Tunnel Token 不能为空。"
        return 1
    }

    local port="8001"
    local uuid
    local tag

    info "固定 VMess 本地端口：8001（固定）"

    if ss -lntup 2>/dev/null |
        grep -Eq "[:.]8001[[:space:]]"; then

        error \
            "固定 VMess 端口 8001 已被占用，请先释放 8001 端口。"

        return 1
    fi

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
            users: [
                {
                    uuid: $uuid
                }
            ],
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

        jq \
            --argjson inbound "$inbound" \
            '.inbounds += [$inbound]' \
            "$INBOUNDS_FILE" > "$tmp" || {

            rm -f "$tmp"

            error "添加固定 VMess 失败。"

            return 1
        }

        mv "$tmp" "$INBOUNDS_FILE"

    else

        jq \
            --argjson inbound "$inbound" \
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

        remove_inbound_by_tag "$tag" \
            >/dev/null 2>&1 || true

        return 1
    fi

    if ! restart_singbox; then

        error \
            "sing-box 启动失败，固定 VMess 未启用。"

        remove_inbound_by_tag "$tag" \
            >/dev/null 2>&1 || true

        restart_singbox >/dev/null 2>&1 || true

        return 1
    fi

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

    show_fixed_vmess_link \
        "$domain" \
        "$uuid"

    refresh_subscription

    echo
}

write_fixed_argo_env() {

    local token="$1"

    ensure_runtime_dirs

    {
        printf "CLOUDFLARE_TUNNEL_TOKEN='"

        printf '%s' "$token" |
            sed "s/'/'\\\\''/g"

        printf "'\n"

    } > "$ARGO_ENV"

    chmod 600 "$ARGO_ENV"
}

configure_fixed_argo() {

    local domain="$1"
    local port="$2"
    local token="$3"

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
ExecStart=${ARGO_BIN} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token \${CLOUDFLARE_TUNNEL_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload

        systemctl enable \
            cloudflared-singbox \
            >/dev/null 2>&1

        if ! systemctl restart \
            cloudflared-singbox; then

            error "固定 Argo systemd 启动失败。"

            return 1
        fi

        success "固定 Argo 已启动。"

    elif [ "$(service_mode)" = "openrc" ]; then

        cat > /etc/init.d/cloudflared-singbox <<EOF
#!/sbin/openrc-run

description="Cloudflare Tunnel for sing-box"

if [ -f "${ARGO_ENV}" ]; then
    . "${ARGO_ENV}"
fi

command="${ARGO_BIN}"

command_args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token \${CLOUDFLARE_TUNNEL_TOKEN}"

command_background="yes"

pidfile="/run/cloudflared-singbox.pid"

depend() {
    need net
}
EOF

        chmod +x /etc/init.d/cloudflared-singbox

        rc-update add \
            cloudflared-singbox \
            default >/dev/null 2>&1 || true

        if ! rc-service \
            cloudflared-singbox restart \
            >/dev/null 2>&1; then

            if ! rc-service \
                cloudflared-singbox start \
                >/dev/null 2>&1; then

                error "固定 Argo OpenRC 启动失败。"

                return 1
            fi
        fi

        success "固定 Argo 已启动。"

    else

        nohup "$ARGO_BIN" tunnel \
            --no-autoupdate \
            --edge-ip-version auto \
            --protocol http2 \
            run \
            --token "$token" \
            > "$ARGO_LOG" 2>&1 &

        local pid=$!

        echo "$pid" > \
            "${PID_DIR}/fixed-argo.pid"

        sleep 2

        if ! is_pid_running "$pid"; then

            error "固定 Argo 启动失败。"

            if [ -f "$ARGO_LOG" ]; then
                tail -n 30 "$ARGO_LOG" \
                    2>/dev/null || true
            fi

            rm -f \
                "${PID_DIR}/fixed-argo.pid"

            return 1
        fi

        success "固定 Argo 已启动。"
    fi

    sleep 2

    warn \
        "Cloudflare Tunnel Token 模式下，需要在 Cloudflare Zero Trust 中配置："

    warn \
        "Public Hostname → Service → http://127.0.0.1:${port}"

    return 0
}

save_fixed_vmess_state() {

    local tag="$1"
    local domain="$2"
    local token="$3"
    local port="$4"
    local uuid="$5"

    ensure_state_file

    local tmp

    tmp="$(mktemp)"

    if jq \
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
        "$STATE_FILE" > "$tmp"; then

        mv "$tmp" "$STATE_FILE"

        chmod 600 "$STATE_FILE"

        return 0

    else

        rm -f "$tmp"

        return 1
    fi
}

show_fixed_vmess_link() {

    local domain="$1"
    local uuid="$2"

    local preferred

    preferred="$(
        get_preferred_domain \
            2>/dev/null || true
    )"

    local add="$domain"

    if [ -n "$preferred" ]; then
        add="$preferred"
    fi

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

    echo \
        "vmess://$(printf '%s' "$json" | base64_noline)"

    echo
}

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

        error \
            "没有找到本脚本创建的固定 Argo。"

        warn \
            "请先使用“固定 Argo”安装。"

        return
    fi

    if ! tag_exists "$old_tag"; then

        error \
            "配置中的固定 VMess 节点已经不存在。"

        warn \
            "请重新安装固定 Argo。"

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

    echo \
        "域名：$(jq -r '.fixed_vmess.domain // empty' "$STATE_FILE")"

    echo "端口：$old_port"

    echo

    local new_domain

    read -r -p \
        "请输入新的 Cloudflare Tunnel 域名： " \
        new_domain

    [ -z "$new_domain" ] && {
        error "域名不能为空。"
        return
    }

    new_domain="${new_domain#http://}"
    new_domain="${new_domain#https://}"
    new_domain="${new_domain%%/*}"

    echo

    local new_token

    read -r -p \
        "请输入新的 Cloudflare Tunnel Token： " \
        new_token

    echo

    [ -z "$new_token" ] && {
        error "Cloudflare Tunnel Token 不能为空。"
        return
    }

    local fixed_port="8001"

    if ss -lntup 2>/dev/null |
        grep -Eq "[:.]8001[[:space:]]" &&
        [ "$old_port" != "8001" ]; then

        error \
            "固定 VMess 端口 8001 已被占用，请先释放 8001 端口。"

        return 1
    fi

    if [ "$old_port" != "$fixed_port" ]; then

        if ! update_vmess_port \
            "$old_tag" \
            "$fixed_port"; then

            return 1
        fi

        if ! check_config >/dev/null 2>&1; then

            error \
                "切换到固定端口 8001 后配置检查失败。"

            update_vmess_port \
                "$old_tag" \
                "$old_port" >/dev/null 2>&1 || true

            return 1
        fi

        if ! restart_singbox; then

            error \
                "sing-box 重启失败，正在恢复原端口。"

            update_vmess_port \
                "$old_tag" \
                "$old_port" >/dev/null 2>&1 || true

            check_config >/dev/null 2>&1 || true

            restart_singbox >/dev/null 2>&1 || true

            return 1
        fi
    fi

    write_fixed_argo_env "$new_token"

    if ! configure_fixed_argo \
        "$new_domain" \
        "$fixed_port" \
        "$new_token"; then

        error "新的固定 Argo 启动失败。"

        return 1
    fi

    save_fixed_vmess_state \
        "$old_tag" \
        "$new_domain" \
        "$new_token" \
        "$fixed_port" \
        "$old_uuid"

    refresh_subscription

    echo

    success "固定隧道已经替换。"

    echo

    show_fixed_vmess_link \
        "$new_domain" \
        "$old_uuid"
}

switch_vmess_argo_mode() {

    clear

    echo -e \
        "${GREEN}========== VMess 临时 / 固定隧道切换 ==========${NC}"

    echo

    ensure_config || return 1

    local source

    source="$(get_config_source)"

    local count

    count="$(
        jq \
            '[.inbounds[]? |
              select(.type == "vmess")] |
             length' \
            "$source" 2>/dev/null
    )"

    if [ -z "$count" ] ||
       [ "$count" = "0" ]; then

        error \
            "当前没有 VMess 节点，请先安装 VMess。"

        return 1
    fi

    local tag
    local uuid
    local old_port
    local fixed_tag

    tag="$(get_vmess_tag)"
    uuid="$(get_vmess_uuid_by_tag "$tag")"
    old_port="$(get_vmess_port_by_tag "$tag")"

    fixed_tag="$(
        jq -r \
            '.fixed_vmess.tag // empty' \
            "$STATE_FILE" 2>/dev/null
    )"

    if [ -z "$tag" ] ||
       [ -z "$uuid" ] ||
       [ -z "$old_port" ]; then

        error \
            "无法读取当前 VMess 节点信息。"

        return 1
    fi

    echo "当前节点：$tag"
    echo "当前本地端口：$old_port"

    echo

    if [ "$tag" = "$fixed_tag" ]; then

        echo "当前模式：固定 Argo"
        echo "目标模式：临时 Argo"

        echo

        if [ ! -x "$ARGO_BIN" ]; then

            download_cloudflared || return 1
        fi

        local new_port
        local old_domain
        local old_token

        new_port="$(get_random_vmess_port)"

        info \
            "正在切换临时 Argo ...（随机本地端口：$new_port）"

        old_domain="$(
            jq -r \
                '.fixed_vmess.domain // empty' \
                "$STATE_FILE" 2>/dev/null
        )"

        old_token="$(
            jq -r \
                '.fixed_vmess.key // empty' \
                "$STATE_FILE" 2>/dev/null
        )"

        local fixed_port="8001"

        backup_config_once

        stop_fixed_argo

        if ! update_vmess_port \
            "$tag" \
            "$new_port"; then

            warn \
                "切换失败，正在恢复固定 Argo..."

            [ -n "$old_domain" ] &&
            [ -n "$old_token" ] &&
                configure_fixed_argo \
                    "$old_domain" \
                    "$fixed_port" \
                    "$old_token" \
                    >/dev/null 2>&1 || true

            return 1
        fi

        if ! check_config >/dev/null 2>&1; then

            error \
                "切换后的 sing-box 配置检查失败。"

            update_vmess_port \
                "$tag" \
                "$fixed_port" >/dev/null 2>&1 || true

            restart_singbox \
                >/dev/null 2>&1 || true

            [ -n "$old_domain" ] &&
            [ -n "$old_token" ] &&
                configure_fixed_argo \
                    "$old_domain" \
                    "$fixed_port" \
                    "$old_token" \
                    >/dev/null 2>&1 || true

            return 1
        fi

        if ! restart_singbox; then

            error \
                "sing-box 重启失败，正在恢复固定 Argo。"

            update_vmess_port \
                "$tag" \
                "$fixed_port" >/dev/null 2>&1 || true

            check_config >/dev/null 2>&1 || true

            restart_singbox \
                >/dev/null 2>&1 || true

            [ -n "$old_domain" ] &&
            [ -n "$old_token" ] &&
                configure_fixed_argo \
                    "$old_domain" \
                    "$fixed_port" \
                    "$old_token" \
                    >/dev/null 2>&1 || true

            return 1
        fi

        clear_fixed_vmess_state

        if ! start_temp_argo \
            "$tag" \
            "$new_port"; then

            error \
                "临时 Argo 启动失败，正在恢复固定 Argo。"

            stop_temp_argo "$tag"

            update_vmess_port \
                "$tag" \
                "$fixed_port" >/dev/null 2>&1 || true

            restart_singbox \
                >/dev/null 2>&1 || true

            if [ -n "$old_domain" ] &&
               [ -n "$old_token" ]; then

                configure_fixed_argo \
                    "$old_domain" \
                    "$fixed_port" \
                    "$old_token" \
                    >/dev/null 2>&1 || true

                save_fixed_vmess_state \
                    "$tag" \
                    "$old_domain" \
                    "$old_token" \
                    "$fixed_port" \
                    "$uuid" \
                    >/dev/null 2>&1 || true
            fi

            return 1
        fi

        local domain=""
        local log

        log="$(temp_argo_log "$tag")"

        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do

            domain="$(
                get_temp_argo_domain \
                    "$tag" \
                    2>/dev/null || true
            )"

            [ -n "$domain" ] && break

            sleep 2
        done

        if [ -z "$domain" ]; then

            error \
                "没有获取到 Cloudflare 临时 Argo 域名。"

            warn \
                "正在回滚到固定 Argo..."

            stop_temp_argo "$tag"

            update_vmess_port \
                "$tag" \
                "$fixed_port" >/dev/null 2>&1 || true

            restart_singbox \
                >/dev/null 2>&1 || true

            if [ -n "$old_domain" ] &&
               [ -n "$old_token" ]; then

                configure_fixed_argo \
                    "$old_domain" \
                    "$fixed_port" \
                    "$old_token" \
                    >/dev/null 2>&1 || true

                save_fixed_vmess_state \
                    "$tag" \
                    "$old_domain" \
                    "$old_token" \
                    "$fixed_port" \
                    "$uuid" \
                    >/dev/null 2>&1 || true
            fi

            warn "临时 Argo 日志：$log"

            return 1
        fi

        if ! check_config >/dev/null 2>&1; then

            error \
                "切换完成后 sing-box 配置检查失败。"

            stop_temp_argo "$tag"

            update_vmess_port \
                "$tag" \
                "$fixed_port" >/dev/null 2>&1 || true

            restart_singbox \
                >/dev/null 2>&1 || true

            if [ -n "$old_domain" ] &&
               [ -n "$old_token" ]; then

                configure_fixed_argo \
                    "$old_domain" \
                    "$fixed_port" \
                    "$old_token" \
                    >/dev/null 2>&1 || true

                save_fixed_vmess_state \
                    "$tag" \
                    "$old_domain" \
                    "$old_token" \
                    "$fixed_port" \
                    "$uuid" \
                    >/dev/null 2>&1 || true
            fi

            return 1
        fi

        refresh_subscription

        echo

        success \
            "VMess 已从固定 Argo 切换为临时 Argo。"

        echo "本地端口：$new_port"
        echo "临时 Argo 域名：$domain"
        echo "UUID：$uuid"

        echo

        show_all_vmess_links

        return 0
    fi

    echo "当前模式：临时 Argo"
    echo "目标模式：固定 Argo"

    echo

    warn \
        "正在切换固定 Argo 使用本地 8001 端口。"

    echo

    if [ ! -x "$ARGO_BIN" ]; then

        download_cloudflared || return 1
    fi

    if ss -lntup 2>/dev/null |
        grep -Eq "[:.]8001[[:space:]]" &&
        [ "$old_port" != "8001" ]; then

        error \
            "固定 VMess 端口 8001 已被占用，请先释放 8001 端口。"

        return 1
    fi

    local new_domain
    local new_token

    read -r -p \
        "请输入 Cloudflare Tunnel 域名： " \
        new_domain

    [ -z "$new_domain" ] && {
        error "域名不能为空。"
        return 1
    }

    new_domain="${new_domain#http://}"
    new_domain="${new_domain#https://}"
    new_domain="${new_domain%%/*}"

    echo

    read -r -p \
        "请输入 Cloudflare Tunnel Token： " \
        new_token

    echo

    [ -z "$new_token" ] && {
        error "Cloudflare Tunnel Token 不能为空。"
        return 1
    }

    local fixed_port="8001"

    backup_config_once

    stop_temp_argo "$tag"

    if ! update_vmess_port \
        "$tag" \
        "$fixed_port"; then

        error \
            "无法将 VMess 本地端口切换到 8001。"

        start_temp_argo \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        return 1
    fi

    if ! check_config >/dev/null 2>&1; then

        error \
            "切换后的 sing-box 配置检查失败。"

        update_vmess_port \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        start_temp_argo \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        return 1
    fi

    if ! restart_singbox; then

        error \
            "sing-box 重启失败，正在恢复临时 Argo。"

        update_vmess_port \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        check_config >/dev/null 2>&1 || true

        restart_singbox \
            >/dev/null 2>&1 || true

        start_temp_argo \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        return 1
    fi

    write_fixed_argo_env "$new_token"

    if ! configure_fixed_argo \
        "$new_domain" \
        "$fixed_port" \
        "$new_token"; then

        error \
            "固定 Argo 启动失败，正在恢复临时 Argo。"

        update_vmess_port \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        restart_singbox \
            >/dev/null 2>&1 || true

        start_temp_argo \
            "$tag" \
            "$old_port" >/dev/null 2>&1 || true

        return 1
    fi

    save_fixed_vmess_state \
        "$tag" \
        "$new_domain" \
        "$new_token" \
        "$fixed_port" \
        "$uuid"

    refresh_subscription

    echo

    success \
        "VMess 已从临时 Argo 切换为固定 Argo。"

    echo "Tunnel 域名：$new_domain"
    echo "本地端口：8001"
    echo "UUID：$uuid"

    echo

    show_fixed_vmess_link \
        "$new_domain" \
        "$uuid"
}

vmess_menu() {

    while true; do

        clear

        echo -e \
            "${CYAN}========== VMess 安装管理 ==========${NC}"

        echo

        echo "1. 安装临时 Argo 节点"
        echo "2. 安装固定 Argo 节点"
        echo "3. 修改优选域名或 IP"
        echo "4. 修改固定隧道"
        echo "5. 临时 / 固定隧道切换"
        echo "6. Cloudflare 更新"
        echo "0. 返回"

        echo

        read -r -p \
            "请选择 [0-6]: " \
            choice

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
                set_preferred_domain
                pause_unless_cancelled
                ;;

            4)
                modify_fixed_vmess
                pause_unless_cancelled
                ;;

            5)
                switch_vmess_argo_mode
                pause_unless_cancelled
                ;;

            6)
                update_cloudflared
                pause_unless_cancelled
                ;;

            0)
                return
                ;;

            *)
                printf \
                    "${RED} 无效选项,按任意键重新输入...${NC}"

                read -n 1 -s -r
                ;;
        esac
    done
}

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
    command_exists openssl || return 1

    local fingerprint
    fingerprint="$(
        openssl x509 \
            -noout \
            -fingerprint \
            -sha256 \
            -in "$cert" 2>/dev/null |
        cut -d'=' -f2 |
        tr -d '\r\n' |
        sed 's/:/%3A/g'
    )"

    [ -n "$fingerprint" ] || return 1
    printf '%s' "$fingerprint"
}

random_short_id() { openssl rand -hex 8; }

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

    if ! restart_singbox; then
        error "sing-box 启动失败，VLESS 未启用。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

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

    local listen_addr=""
    if [ -n "$(get_public_ipv4 2>/dev/null)" ]; then
        listen_addr="0.0.0.0"
    elif [ -n "$(get_public_ipv6 2>/dev/null)" ]; then
        listen_addr="::"
    else
        listen_addr="::"
    fi

    local cert="${SB_DIR}/tuic-cert.pem"
    local key="${SB_DIR}/tuic-key.pem"

    if ! openssl ecparam -genkey -name prime256v1 -out "$key" >/dev/null 2>&1; then
        error "TUIC TLS 私钥生成失败。"
        return 1
    fi
    if ! openssl req -new -x509 -days 3650 -key "$key" -out "$cert" \
        -subj "/CN=www.bing.com" >/dev/null 2>&1; then
        error "TUIC TLS 证书生成失败。"
        rm -f "$key" "$cert"
        return 1
    fi
    chmod 600 "$key"
    chmod 644 "$cert"

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
            --arg listen "$listen_addr" \
        '{
            type: "tuic",
            tag: $tag,
            listen: $listen,
            listen_port: ($port | tonumber),
            users: [
                {
                    uuid: $uuid,
                    password: $password
                }
            ],
            congestion_control: "bbr",
            auth_timeout: "3s",
            zero_rtt_handshake: false,
            heartbeat: "10s",
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
        check_config 2>&1 | tail -n 30
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        return 1
    fi

    if ! restart_singbox; then
        error "sing-box 重启失败，TUIC 未启用。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

    local listening=0
    for _ in 1 2 3 4 5; do
        if ss -lunH 2>/dev/null | awk -v p=":${port}" '
            index($5, p) || index($4, p) { found=1 }
            END { exit(found ? 0 : 1) }
        '; then
            listening=1
            break
        fi
        sleep 1
    done

    if [ "$listening" != "1" ]; then
        error "TUIC UDP ${port} 未成功监听。"
        warn "sing-box 最近日志："
        case "$(service_mode)" in
            systemd)
                journalctl -u sing-box --no-pager -n 50 2>/dev/null || true
                ;;
            openrc)
                tail -n 50 "${LOG_DIR}/sing-box.log" 2>/dev/null || true
                ;;
            manual)
                tail -n 50 "${LOG_DIR}/sing-box.log" 2>/dev/null || true
                ;;
        esac
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        if check_config >/dev/null 2>&1; then restart_singbox >/dev/null 2>&1 || true; fi
        return 1
    fi

    load_server_ip

    echo
    success "TUIC 安装成功。"
    echo
    echo "监听地址：$listen_addr"
    echo "服务器地址：$SERVER_IP"
    echo "UDP 端口：$port"
    echo "SNI：www.bing.com"
    echo

    local alias
    alias="$(get_node_alias "TUIC")"

    echo "tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${alias}"

    echo
    refresh_subscription
    echo
}

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

    if ! restart_singbox; then
        error "sing-box 重启失败，Hysteria2 未启用。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

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

    if ! restart_singbox; then
        error "sing-box 重启失败，Socks5 未启用。"
        remove_inbound_by_tag "$tag" >/dev/null 2>&1 || true
        restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

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

# ============================================================
# 订阅服务初始化
#
# 改动：
#   - 首次进入（未配置过）时，明确提示"首次初始化可能需要几十秒"
# ============================================================

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

    if [ ! -f "$SUB_NGINX_CONF" ] && ! command_exists nginx; then
        info "首次初始化订阅服务，可能需要安装 nginx 并配置，请稍候..."
    fi

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
#
# 改动：
#   - VLESS / VMess 分支的关键报错不再走 stderr，
#     这样外层 2>/dev/null 不会把它吞掉
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

            if [ -z "$public_key" ] || [ "$public_key" = "null" ]; then
                local _pk_inbound
                _pk_inbound="$(jq -r ".inbounds[$index].tls.reality.private_key // empty" "$config_source" 2>/dev/null)"
                if [ -n "$_pk_inbound" ]; then
                    warn "检测到 $tag 缺失 public_key，正在自动推导..."
                    public_key="$(derive_reality_public_key "$_pk_inbound")"
                    if [ -n "$public_key" ]; then
                        if save_vless_state "$tag" "$uuid" "$public_key" "$sni" "$port" "$short_id" >/dev/null 2>&1; then
                            success "已自动补全 state.json：$tag"
                        fi
                    fi
                fi
            fi

            if [ -z "$public_key" ] || [ "$public_key" = "null" ]; then
                echo -e "${RED}无法生成 VLESS Reality 链接。${NC}"
                echo "原因：state.json 缺失 public_key，且无法从 inbound 反推。"
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
                echo -e "${RED}无法获取 VMess Argo 域名。${NC}"
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
            echo "暂不支持自动生成 ${type} 客户端链接。"
            ;;
    esac
}

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
        local type
        type="$(jq -r ".inbounds[$i].type // \"unknown\"" "$config_source")"

        echo -e "${YELLOW}[$((i + 1))]${NC}"
        echo -e "${GREEN}${type} 客户端链接：${NC}"

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
            success "所选节点已成功卸载。"
        else
            warn "部分节点卸载失败，请检查配置。"
        fi
    else
        error "删除后配置检查失败，请检查 sing-box 配置。"
    fi
    pause
}

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

node_install_menu() {
    while true; do
        clear
        echo -e "${CYAN}========== sing-box 节点管理 ==========${NC}"
        echo
        echo -e " 1.${YELLOW} VMess 安装管理${NC}"
        echo -e " 2.${YELLOW} VLESS 安装${NC}"
        echo -e " 3.${YELLOW} TUIC 安装${NC}"
        echo -e " 4.${YELLOW} Hysteria2 安装${NC}"
        echo -e " 5.${YELLOW} Socks5 安装${NC}"
        echo -e " 6.${YELLOW} 节点卸载${NC}"
        echo -e " 7.${YELLOW} 查看节点${NC}"
        echo -e " 0.${YELLOW} 返回${NC}"
        echo
        read -p "$(echo -e "${BLUE}*  ${CYAN}请选择 [0-7]: ${NC}: ")" choice
        case "$choice" in
            1) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; vmess_menu ;;
            2) ensure_singbox_installed || { pause; continue; }; ensure_nginx_installed || { pause; continue; }; install_vless; pause_unless_cancelled ;;
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

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${NC}"
        echo -e "${CYAN}       sing-box 安装管理${NC}"
        echo -e "${BLUE}======================================${NC}"
        echo
        echo -e "1.${YELLOW} sing-box 节点管理${NC}"
        echo -e "2.${YELLOW} BBR + FQ 加速${NC}"
        echo -e "3.${YELLOW} sing-box 更新${NC}"
        echo -e "4.${YELLOW} sing-box 卸载${NC}"
        echo -e "0.${YELLOW} 退出${NC}"
        echo
        read -p "$(echo -e "${BLUE}*  ${CYAN}请选择 [0-4]: ${NC}: ")" choice
        case "$choice" in
            1) node_install_menu ;;
            2) bbr_fq ;;
            3) update_singbox; pause_unless_cancelled ;;
            4) uninstall_singbox ;;
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
    auto_migrate_dns_config >/dev/null 2>&1 || true
fi
main_menu
