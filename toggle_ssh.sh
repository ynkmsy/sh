#!/bin/bash

# ============================================================
# SSH 配置管理工具
#
# 支持：
#   Debian / Ubuntu / Armbian
#   RHEL / CentOS / Rocky / AlmaLinux
#
# 功能：
#   1. 允许 / 禁止 Root SSH 登录
#   2. 允许 / 禁止 SSH 密码登录
#   3. 查看 SSH 实际生效配置
#   4. 测试 SSH 配置
#   5. 恢复最近一次备份
#   6. 查看备份列表
#
# 核心设计：
#   - 不直接删除系统原有 SSH 配置
#   - 使用独立 00-ssh-manager.conf 管理配置
#   - 修改前自动完整备份
#   - sshd -t 语法检查
#   - sshd -T 实际配置检查
#   - SSH 重启失败自动恢复
#   - 恢复失败自动尝试回滚
#   - 禁止 Root 前检查普通管理用户
#   - 禁止密码前检查公钥登录
#
# 注意：
#   修改 SSH 配置时，请不要关闭当前 SSH 会话。
# ============================================================

# ============================================================
# 颜色
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================================
# 基础配置
# ============================================================

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"

# SSH Manager 专用配置
MANAGER_CONFIG="${SSHD_CONFIG_DIR}/00-ssh-manager.conf"

# 备份目录
BACKUP_DIR="/etc/ssh/ssh-manager-backups"

# 当前操作产生的备份
CURRENT_BACKUP=""

# SSH 服务
SSHD_BIN=""
SSH_SERVICE=""

# 当前用户
CURRENT_USER=""

# ============================================================
# 输出函数
# ============================================================

msg() {
    echo -e "$1"
}

info() {
    msg "${CYAN}$1${NC}"
}

success() {
    msg "${GREEN}$1${NC}"
}

warning() {
    msg "${YELLOW}$1${NC}"
}

error() {
    msg "${RED}$1${NC}"
}

# ============================================================
# 暂停
# ============================================================

pause_screen() {
    echo
    read -r -n 1 -s -p "$(echo -e "${YELLOW}按任意键继续...${NC}")"
    echo
}

# ============================================================
# Root 检查
# ============================================================

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "需要 root 权限，请使用 root 用户运行！"
        exit 1
    fi
}

# ============================================================
# 检查 SSH 配置文件
# ============================================================

check_ssh_config() {
    if [ ! -f "$SSHD_CONFIG" ]; then
        error "未找到 SSH 配置文件："
        error "$SSHD_CONFIG"
        exit 1
    fi

    if [ ! -d "$SSHD_CONFIG_DIR" ]; then
        info "未找到 sshd_config.d，正在创建..."

        mkdir -p "$SSHD_CONFIG_DIR" 2>/dev/null || {
            error "无法创建：$SSHD_CONFIG_DIR"
            exit 1
        }
    fi
}

# ============================================================
# 获取 sshd
# ============================================================

get_sshd_bin() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return 0
    fi

    if [ -x "/usr/sbin/sshd" ]; then
        echo "/usr/sbin/sshd"
        return 0
    fi

    error "未找到 sshd 命令！"
    error "请确认 OpenSSH Server 已安装。"

    return 1
}

# ============================================================
# 初始化 sshd
# ============================================================

init_sshd() {
    SSHD_BIN="$(get_sshd_bin)" || exit 1
}

# ============================================================
# 获取 SSH 服务名称
# ============================================================

get_ssh_service() {
    # Debian / Ubuntu / Armbian
    if systemctl list-unit-files 2>/dev/null |
        grep -q '^ssh\.service'; then

        echo "ssh"
        return 0
    fi

    # RHEL / CentOS / Rocky / AlmaLinux
    if systemctl list-unit-files 2>/dev/null |
        grep -q '^sshd\.service'; then

        echo "sshd"
        return 0
    fi

    # 后备
    if systemctl is-active --quiet ssh 2>/dev/null; then
        echo "ssh"
        return 0
    fi

    if systemctl is-active --quiet sshd 2>/dev/null; then
        echo "sshd"
        return 0
    fi

    # 再检查 unit 是否存在
    if systemctl cat ssh.service >/dev/null 2>&1; then
        echo "ssh"
        return 0
    fi

    if systemctl cat sshd.service >/dev/null 2>&1; then
        echo "sshd"
        return 0
    fi

    echo ""
    return 1
}

# ============================================================
# 初始化 SSH 服务
# ============================================================

init_ssh_service() {
    SSH_SERVICE="$(get_ssh_service)"

    if [ -z "$SSH_SERVICE" ]; then
        warning "暂时无法确定 SSH 服务名称。"
        warning "可能不是 systemd 系统。"
    fi
}

# ============================================================
# 当前用户
# ============================================================

get_current_user() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
        return 0
    fi

    if [ -n "$USER" ]; then
        echo "$USER"
        return 0
    fi

    whoami 2>/dev/null
}

# ============================================================
# 初始化当前用户
# ============================================================

init_current_user() {
    CURRENT_USER="$(get_current_user)"

    if [ -z "$CURRENT_USER" ]; then
        CURRENT_USER="root"
    fi
}

# ============================================================
# 检查 sshd 配置语法
# ============================================================

test_ssh_config() {
    info "正在检查 SSH 配置语法..."

    local error_file

    error_file="/tmp/ssh_manager_error.log"

    rm -f "$error_file"

    if "$SSHD_BIN" -t 2>"$error_file"; then
        success "SSH 配置语法检查通过！"

        rm -f "$error_file"

        return 0
    else
        error "SSH 配置语法检查失败！"

        if [ -s "$error_file" ]; then
            echo
            cat "$error_file"
            echo
        fi

        rm -f "$error_file"

        return 1
    fi
}

# ============================================================
# 获取 SSH 实际生效配置
#
# sshd -T 会读取：
#   sshd_config
#   Include
#   sshd_config.d
#
# 返回最终生效配置。
# ============================================================

get_config_value() {
    local key
    local value

    key="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

    value="$(
        "$SSHD_BIN" -T 2>/dev/null |
        awk -v key="$key" '
            $1 == key {
                print tolower($2)
                exit
            }
        '
    )"

    echo "$value"
}

# ============================================================
# 检查配置是否已经加载 Manager 配置
# ============================================================

check_manager_config() {
    if [ ! -f "$MANAGER_CONFIG" ]; then
        return 1
    fi

    return 0
}

# ============================================================
# 判断 sshd_config 是否存在 Include
#
# 只检查全局配置。
# ============================================================

has_global_include() {
    awk '
    BEGIN {
        found=0
    }

    /^[[:space:]]*#/ {
        next
    }

    /^[[:space:]]*Match([[:space:]]|$)/ {
        exit
    }

    /^[[:space:]]*Include[[:space:]]+.*sshd_config\.d/ {
        found=1
        exit
    }

    END {
        if (found)
            exit 0
        else
            exit 1
    }
    ' "$SSHD_CONFIG"
}

# ============================================================
# 确保 sshd_config 最前面加载 sshd_config.d
#
# 设计原因：
#
# OpenSSH 配置不是简单的“最后一行覆盖前面”。
# 很多参数实际上是“首次取得的值生效”。
#
# 因此我们让 sshd_config.d 在主配置最前面被 Include，
# 再使用 00-ssh-manager.conf。
#
# 这样 Manager 配置可以可靠优先于系统后续配置。
# ============================================================

ensure_global_include() {
    if has_global_include; then
        return 0
    fi

    info "未检测到 sshd_config.d 的 Include。"
    info "正在在 sshd_config 最前面添加 Include..."

    local temp_file

    temp_file="${SSHD_CONFIG}.ssh-manager.tmp"

    {
        echo "#"
        echo "# SSH Manager - sshd_config.d include"
        echo "# Added automatically by SSH Manager"
        echo "Include ${SSHD_CONFIG_DIR}/*.conf"
        echo
        cat "$SSHD_CONFIG"
    } > "$temp_file" || {
        rm -f "$temp_file"

        error "无法创建临时 SSH 配置文件！"

        return 1
    }

    chmod --reference="$SSHD_CONFIG" "$temp_file" 2>/dev/null || true
    chown --reference="$SSHD_CONFIG" "$temp_file" 2>/dev/null || true

    if ! mv -f "$temp_file" "$SSHD_CONFIG"; then
        rm -f "$temp_file"

        error "无法更新 sshd_config！"

        return 1
    fi

    success "Include 已添加到 sshd_config 最前面。"

    return 0
}

# ============================================================
# 创建 SSH Manager 配置
# ============================================================

write_manager_config() {
    local root_value="$1"
    local password_value="$2"

    if [ -z "$root_value" ] || [ -z "$password_value" ]; then
        error "Manager 配置参数错误！"
        return 1
    fi

    info "正在写入 SSH Manager 配置..."

    local temp_file

    temp_file="${MANAGER_CONFIG}.tmp"

    cat > "$temp_file" <<EOF
# ============================================================
# SSH Manager configuration
#
# 此文件由 SSH 配置管理工具自动生成。
#
# 请勿手动删除或修改。
# 如需修改，请使用 SSH Manager。
# ============================================================

PermitRootLogin ${root_value}
PasswordAuthentication ${password_value}
EOF

    if [ $? -ne 0 ]; then
        rm -f "$temp_file"

        error "写入 SSH Manager 配置失败！"

        return 1
    fi

    chmod 0644 "$temp_file" 2>/dev/null || true

    if ! mv -f "$temp_file" "$MANAGER_CONFIG"; then
        rm -f "$temp_file"

        error "无法安装 SSH Manager 配置！"

        return 1
    fi

    success "SSH Manager 配置已更新："
    echo "$MANAGER_CONFIG"

    return 0
}

# ============================================================
# 删除 SSH Manager 配置
#
# 恢复时使用。
# ============================================================

remove_manager_config() {
    if [ -f "$MANAGER_CONFIG" ]; then
        rm -f "$MANAGER_CONFIG" || {
            error "删除 Manager 配置失败！"
            return 1
        }
    fi

    return 0
}

# ============================================================
# 创建完整备份
#
# 备份：
#   sshd_config
#   sshd_config.d
#
# 另外记录目录是否原本存在。
# ============================================================

backup_config() {
    mkdir -p "$BACKUP_DIR" || {
        error "无法创建备份目录：$BACKUP_DIR"

        return 1
    }

    local backup_name

    backup_name="ssh_backup_$(date +%Y%m%d_%H%M%S)_$$"

    CURRENT_BACKUP="${BACKUP_DIR}/${backup_name}"

    mkdir -p "$CURRENT_BACKUP" || {
        error "无法创建备份目录：$CURRENT_BACKUP"

        CURRENT_BACKUP=""

        return 1
    }

    # --------------------------------------------------------
    # 记录 sshd_config
    # --------------------------------------------------------

    if ! cp -a "$SSHD_CONFIG" "$CURRENT_BACKUP/sshd_config"; then
        error "备份 sshd_config 失败！"

        rm -rf "$CURRENT_BACKUP"

        CURRENT_BACKUP=""

        return 1
    fi

    # --------------------------------------------------------
    # 记录 sshd_config.d 是否存在
    # --------------------------------------------------------

    if [ -d "$SSHD_CONFIG_DIR" ]; then
        echo "yes" > "$CURRENT_BACKUP/sshd_config.d.exists"

        if ! cp -a "$SSHD_CONFIG_DIR" "$CURRENT_BACKUP/sshd_config.d"; then
            error "备份 sshd_config.d 失败！"

            rm -rf "$CURRENT_BACKUP"

            CURRENT_BACKUP=""

            return 1
        fi
    else
        echo "no" > "$CURRENT_BACKUP/sshd_config.d.exists"
    fi

    # --------------------------------------------------------
    # 记录备份时间
    # --------------------------------------------------------

    date '+%Y-%m-%d %H:%M:%S' > "$CURRENT_BACKUP/backup_time"

    success "SSH 配置备份成功："

    echo "$CURRENT_BACKUP"

    return 0
}

# ============================================================
# 恢复备份
# ============================================================

restore_backup() {
    local backup="$1"

    if [ -z "$backup" ]; then
        error "未指定备份目录！"

        return 1
    fi

    if [ ! -d "$backup" ]; then
        error "备份不存在：$backup"

        return 1
    fi

    if [ ! -f "$backup/sshd_config" ]; then
        error "备份中的 sshd_config 不存在！"

        return 1
    fi

    warning "正在恢复 SSH 配置..."

    # --------------------------------------------------------
    # 恢复主配置
    # --------------------------------------------------------

    if ! cp -a "$backup/sshd_config" "$SSHD_CONFIG"; then
        error "恢复 sshd_config 失败！"

        return 1
    fi

    # --------------------------------------------------------
    # 恢复 sshd_config.d
    #
    # 如果备份时不存在：
    #   删除当前目录
    #
    # 如果备份时存在：
    #   删除当前目录
    #   再恢复备份
    # --------------------------------------------------------

    if [ -f "$backup/sshd_config.d.exists" ]; then
        local existed

        existed="$(cat "$backup/sshd_config.d.exists" 2>/dev/null)"

        rm -rf "$SSHD_CONFIG_DIR"

        if [ "$existed" = "yes" ]; then
            if [ ! -d "$backup/sshd_config.d" ]; then
                error "备份标记为存在 sshd_config.d，但备份目录不存在！"

                return 1
            fi

            if ! cp -a "$backup/sshd_config.d" "$SSHD_CONFIG_DIR"; then
                error "恢复 sshd_config.d 失败！"

                return 1
            fi
        else
            # 原来不存在，保持不存在
            :
        fi
    else
        # 兼容旧版本备份
        if [ -d "$backup/sshd_config.d" ]; then
            rm -rf "$SSHD_CONFIG_DIR"

            if ! cp -a "$backup/sshd_config.d" "$SSHD_CONFIG_DIR"; then
                error "恢复 sshd_config.d 失败！"

                return 1
            fi
        fi
    fi

    success "SSH 配置文件恢复完成！"

    return 0
}

# ============================================================
# 获取最近备份
# ============================================================

get_latest_backup() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 1
    fi

    find "$BACKUP_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'ssh_backup_*' \
        -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        head -n 1 |
        cut -d' ' -f2-
}

# ============================================================
# 清理旧备份
#
# 保留最近 10 个
# ============================================================

cleanup_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    local backups

    backups="$(
        find "$BACKUP_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'ssh_backup_*' \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        tail -n +11 |
        cut -d' ' -f2-
    )"

    if [ -n "$backups" ]; then
        while IFS= read -r dir; do
            [ -z "$dir" ] && continue

            rm -rf -- "$dir"
        done <<< "$backups"
    fi
}

# ============================================================
# 判断用户是否属于 sudo / wheel
# ============================================================

is_sudo_user() {
    local user="$1"
    local groups

    groups="$(id -nG "$user" 2>/dev/null)"

    echo " $groups " |
        grep -qE ' (sudo|wheel) '
}

# ============================================================
# 检查普通管理用户
# ============================================================

check_sudo_user() {
    local found=0
    local user
    local uid

    info "正在检查普通 sudo/wheel 管理用户..."

    while IFS=: read -r user _ uid _ _ _ _; do
        # UID >= 1000
        if [ "$uid" -ge 1000 ] 2>/dev/null &&
            [ "$user" != "nobody" ]; then

            if is_sudo_user "$user"; then
                success "找到管理用户：$user"

                found=$((found + 1))
            fi
        fi
    done < /etc/passwd

    if [ "$found" -eq 0 ]; then
        error "未找到普通 sudo/wheel 管理用户！"

        warning "如果禁止 Root SSH 登录，可能导致无法登录服务器。"

        return 1
    fi

    success "检测到 $found 个普通管理用户。"

    return 0
}

# ============================================================
# 获取用户 Shell
# ============================================================

get_user_shell() {
    local user="$1"

    getent passwd "$user" |
        awk -F: '{print $7}'
}

# ============================================================
# 判断 Shell 是否可用于登录
# ============================================================

is_login_shell() {
    local shell="$1"

    if [ -z "$shell" ]; then
        return 1
    fi

    case "$shell" in
        */nologin)
            return 1
            ;;
        */false)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ============================================================
# 检查 authorized_keys
# ============================================================

check_authorized_keys() {
    local user="$1"
    local home_dir
    local key_file

    if [ -z "$user" ]; then
        return 1
    fi

    home_dir="$(getent passwd "$user" | cut -d: -f6)"

    if [ -z "$home_dir" ]; then
        return 1
    fi

    if [ ! -d "$home_dir" ]; then
        return 1
    fi

    key_file="${home_dir}/.ssh/authorized_keys"

    if [ -s "$key_file" ]; then
        # 至少存在非空内容
        if grep -q '^[[:space:]]*ssh-\|^[[:space:]]*ecdsa-\|^[[:space:]]*sk-\|^[[:space:]]*cert-' "$key_file" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# ============================================================
# 找到有 SSH 公钥的普通用户
# ============================================================

find_key_user() {
    local user
    local uid
    local shell

    while IFS=: read -r user _ uid _ _ _ shell; do
        if [ "$uid" -ge 1000 ] 2>/dev/null &&
            [ "$user" != "nobody" ]; then

            if ! is_login_shell "$shell"; then
                continue
            fi

            if check_authorized_keys "$user"; then
                echo "$user"

                return 0
            fi
        fi
    done < /etc/passwd

    return 1
}

# ============================================================
# 检查 Root authorized_keys
# ============================================================

check_root_authorized_keys() {
    check_authorized_keys root
}

# ============================================================
# 检查是否存在公钥登录方式
# ============================================================

check_key_login_available() {
    local key_user=""

    # 当前用户
    if [ "$CURRENT_USER" != "root" ]; then
        if check_authorized_keys "$CURRENT_USER"; then
            echo "$CURRENT_USER"

            return 0
        fi
    fi

    # Root
    if check_root_authorized_keys; then
        echo "root"

        return 0
    fi

    # 其他普通用户
    key_user="$(find_key_user)"

    if [ -n "$key_user" ]; then
        echo "$key_user"

        return 0
    fi

    return 1
}

# ============================================================
# 检查用户是否在 AllowUsers
#
# 返回：
#   0 = 没有限制
#   0 = 当前用户允许
#   1 = 当前用户明确不在 AllowUsers
# ============================================================

check_allow_users_for_user() {
    local user="$1"
    local found=0
    local allowed=0

    while IFS= read -r line; do
        # 去掉前后空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # 跳过注释
        case "$line" in
            \#*|"")
                continue
                ;;
        esac

        if echo "$line" |
            grep -qiE '^AllowUsers([[:space:]]|$)'; then

            found=1

            # 检查用户是否直接出现
            if echo "$line" |
                awk '{$1=""; print}' |
                tr ' ' '\n' |
                grep -Fxq "$user"; then

                allowed=1
            fi
        fi
    done < "$SSHD_CONFIG"

    # 没有 AllowUsers 限制
    if [ "$found" -eq 0 ]; then
        return 0
    fi

    if [ "$allowed" -eq 1 ]; then
        return 0
    fi

    return 1
}

# ============================================================
# 检查用户是否被 DenyUsers
# ============================================================

check_deny_users_for_user() {
    local user="$1"

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        case "$line" in
            \#*|"")
                continue
                ;;
        esac

        if echo "$line" |
            grep -qiE '^DenyUsers([[:space:]]|$)'; then

            if echo "$line" |
                awk '{$1=""; print}' |
                tr ' ' '\n' |
                grep -Fxq "$user"; then

                return 1
            fi
        fi
    done < "$SSHD_CONFIG"

    return 0
}

# ============================================================
# 检查普通用户 SSH 登录安全性
# ============================================================

check_user_login_safety() {
    local user="$1"
    local shell

    if [ -z "$user" ]; then
        return 1
    fi

    shell="$(get_user_shell "$user")"

    if ! is_login_shell "$shell"; then
        warning "用户 $user 的 Shell 不适合登录：$shell"

        return 1
    fi

    if ! check_allow_users_for_user "$user"; then
        warning "用户 $user 不符合 AllowUsers 限制。"

        return 1
    fi

    if ! check_deny_users_for_user "$user"; then
        warning "用户 $user 被 DenyUsers 禁止。"

        return 1
    fi

    return 0
}

# ============================================================
# 检查关闭密码后的安全登录方式
# ============================================================

check_key_login_safety() {
    local key_user

    key_user="$(check_key_login_available)"

    if [ -z "$key_user" ]; then
        error "没有检测到任何 authorized_keys！"

        error "关闭密码登录后可能无法 SSH 登录。"

        return 1
    fi

    success "检测到 SSH 公钥用户：$key_user"

    if check_user_login_safety "$key_user"; then
        success "用户 $key_user 的基本 SSH 登录条件正常。"
    else
        warning "用户 $key_user 存在 SSH 登录限制。"
        warning "请确认该用户确实可以通过 SSH 登录。"

        return 1
    fi

    return 0
}

# ============================================================
# 检查 Match 块
#
# 这里只做提示，不尝试自动修改 Match。
#
# 因为 Match 中的配置可能针对：
#   User
#   Group
#   Address
#   LocalAddress
# 等条件。
# ============================================================

check_match_rules() {
    local found=0

    if grep -qEi '^[[:space:]]*Match([[:space:]]|$)' "$SSHD_CONFIG" 2>/dev/null; then
        found=1
    fi

    if [ "$found" -eq 1 ]; then
        warning "检测到 sshd_config 中存在 Match 规则。"

        warning "某些用户的 SSH 参数可能被 Match 单独覆盖。"

        warning "脚本会使用 sshd -T 检查全局最终配置。"
    fi
}

# ============================================================
# 修改 SSH Manager 配置
#
# 不再删除系统原有配置。
# ============================================================

modify_config() {
    local key="$1"
    local value="$2"

    local current_root
    local current_password

    current_root="$(get_config_value PermitRootLogin)"
    current_password="$(get_config_value PasswordAuthentication)"

    case "$key" in
        PermitRootLogin)
            current_root="$value"
            ;;
        PasswordAuthentication)
            current_password="$value"
            ;;
        *)
            error "不支持修改的 SSH 参数：$key"

            return 1
            ;;
    esac

    # 如果 Manager 配置还不存在，
    # 需要先确保 Include。
    if ! ensure_global_include; then
        return 1
    fi

    write_manager_config \
        "$current_root" \
        "$current_password"
}

# ============================================================
# 重启 SSH
# ============================================================

restart_ssh() {
    if [ -z "$SSH_SERVICE" ]; then
        init_ssh_service
    fi

    if [ -z "$SSH_SERVICE" ]; then
        error "无法确定 SSH 服务名称！"

        return 1
    fi

    info "正在重启 SSH 服务：$SSH_SERVICE"

    if systemctl restart "$SSH_SERVICE"; then
        sleep 1

        if systemctl is-active --quiet "$SSH_SERVICE"; then
            success "SSH 服务重启成功！"

            return 0
        else
            error "SSH 服务重启后没有正常运行！"
        fi
    else
        error "SSH 服务重启失败！"
    fi

    echo

    systemctl status "$SSH_SERVICE" \
        --no-pager \
        -l 2>/dev/null || true

    return 1
}

# ============================================================
# 安全修改
#
# 流程：
#
# 1. 备份
# 2. 修改
# 3. sshd -t
# 4. sshd -T
# 5. 重启 SSH
# 6. 再次 sshd -T
#
# 任意关键步骤失败：
#   自动恢复
# ============================================================

safe_modify() {
    local key="$1"
    local value="$2"
    local expected="$3"

    local actual

    # --------------------------------------------------------
    # 1. 备份
    # --------------------------------------------------------

    if ! backup_config; then
        error "备份失败，取消修改！"

        return 1
    fi

    # --------------------------------------------------------
    # 2. 修改
    # --------------------------------------------------------

    if ! modify_config "$key" "$value"; then
        error "修改配置失败！"

        warning "正在恢复备份..."

        restore_backup "$CURRENT_BACKUP"

        return 1
    fi

    # --------------------------------------------------------
    # 3. 语法检查
    # --------------------------------------------------------

    if ! test_ssh_config; then
        error "配置修改后语法检查失败！"

        warning "正在自动恢复备份..."

        restore_backup "$CURRENT_BACKUP"

        test_ssh_config >/dev/null 2>&1 || true

        return 1
    fi

    # --------------------------------------------------------
    # 4. 检查实际生效值
    # --------------------------------------------------------

    actual="$(get_config_value "$key")"

    if [ "$actual" != "$expected" ]; then
        error "配置没有按预期生效！"

        error "参数：$key"
        error "期望：$expected"
        error "实际：${actual:-未获取}"

        warning "正在自动恢复备份..."

        restore_backup "$CURRENT_BACKUP"

        return 1
    fi

    success "$key 当前已经生效：$actual"

    # --------------------------------------------------------
    # 5. 重启 SSH
    # --------------------------------------------------------

    if ! restart_ssh; then
        error "SSH 重启失败！"

        warning "正在自动恢复修改前的配置..."

        if restore_backup "$CURRENT_BACKUP"; then
            if test_ssh_config; then
                warning "正在重新启动恢复后的 SSH..."

                restart_ssh >/dev/null 2>&1 || true
            fi
        fi

        return 1
    fi

    # --------------------------------------------------------
    # 6. 重启后再次检查
    # --------------------------------------------------------

    actual="$(get_config_value "$key")"

    if [ "$actual" != "$expected" ]; then
        error "SSH 重启后配置未按预期生效！"

        error "参数：$key"
        error "期望：$expected"
        error "实际：${actual:-未获取}"

        warning "正在恢复备份..."

        if restore_backup "$CURRENT_BACKUP"; then
            if test_ssh_config; then
                restart_ssh >/dev/null 2>&1 || true
            fi
        fi

        return 1
    fi

    success "SSH 配置修改成功！"

    return 0
}

# ============================================================
# 显示 SSH 当前状态
# ============================================================

show_status() {
    local PRL
    local PA
    local PKA
    local PUBKEY
    local SERVICE

    PRL="$(get_config_value PermitRootLogin)"
    PA="$(get_config_value PasswordAuthentication)"
    PKA="$(get_config_value KbdInteractiveAuthentication)"
    PUBKEY="$(get_config_value PubkeyAuthentication)"

    SERVICE="$SSH_SERVICE"

    echo -e "${CYAN}========== SSH 当前状态 ==========${NC}"

    # --------------------------------------------------------
    # Root
    # --------------------------------------------------------

    case "$PRL" in
        yes)
            echo -e "Root 登录             : ${GREEN}允许（密码/密钥）${NC}"
            ;;
        prohibit-password)
            echo -e "Root 登录             : ${YELLOW}仅允许密钥${NC}"
            ;;
        forced-commands-only)
            echo -e "Root 登录             : ${YELLOW}仅允许强制命令${NC}"
            ;;
        no)
            echo -e "Root 登录             : ${RED}禁止${NC}"
            ;;
        *)
            echo -e "Root 登录             : ${YELLOW}${PRL:-未知}${NC}"
            ;;
    esac

    # --------------------------------------------------------
    # Password
    # --------------------------------------------------------

    if [ "$PA" = "yes" ]; then
        echo -e "密码登录              : ${GREEN}允许${NC}"
    else
        echo -e "密码登录              : ${RED}禁止${NC}"
    fi

    # --------------------------------------------------------
    # 公钥
    # --------------------------------------------------------

    if [ "$PUBKEY" = "yes" ]; then
        echo -e "公钥登录              : ${GREEN}允许${NC}"
    else
        echo -e "公钥登录              : ${RED}禁止${NC}"
    fi

    # --------------------------------------------------------
    # Keyboard Interactive
    # --------------------------------------------------------

    if [ "$PKA" = "yes" ]; then
        echo -e "Keyboard-Interactive  : ${GREEN}允许${NC}"
    else
        echo -e "Keyboard-Interactive  : ${RED}禁止${NC}"
    fi

    # --------------------------------------------------------
    # Manager
    # --------------------------------------------------------

    if [ -f "$MANAGER_CONFIG" ]; then
        echo -e "Manager 配置          : ${GREEN}已启用${NC}"
    else
        echo -e "Manager 配置          : ${YELLOW}未创建${NC}"
    fi

    # --------------------------------------------------------
    # 服务
    # --------------------------------------------------------

    if [ -n "$SERVICE" ]; then
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            echo -e "SSH 服务              : ${GREEN}运行中 ($SERVICE)${NC}"
        else
            echo -e "SSH 服务              : ${RED}未运行 ($SERVICE)${NC}"
        fi
    else
        echo -e "SSH 服务              : ${RED}未检测到${NC}"
    fi
}

# ============================================================
# 显示详细 SSH 配置
# ============================================================

show_detailed_config() {
    clear

    echo -e "${CYAN}========== SSH 实际生效配置 ==========${NC}"

    echo

    echo -e "${YELLOW}PermitRootLogin:${NC} $(get_config_value PermitRootLogin)"

    echo

    echo -e "${YELLOW}PasswordAuthentication:${NC} $(get_config_value PasswordAuthentication)"

    echo

    echo -e "${YELLOW}PubkeyAuthentication:${NC} $(get_config_value PubkeyAuthentication)"

    echo

    echo -e "${YELLOW}KbdInteractiveAuthentication:${NC} $(get_config_value KbdInteractiveAuthentication)"

    echo

    echo -e "${YELLOW}PermitEmptyPasswords:${NC} $(get_config_value PermitEmptyPasswords)"

    echo

    echo -e "${YELLOW}MaxAuthTries:${NC} $(get_config_value MaxAuthTries)"

    echo

    echo -e "${YELLOW}LoginGraceTime:${NC} $(get_config_value LoginGraceTime)"

    echo

    echo -e "${YELLOW}X11Forwarding:${NC} $(get_config_value X11Forwarding)"

    echo

    echo -e "${YELLOW}UsePAM:${NC} $(get_config_value UsePAM)"

    echo

    echo -e "${YELLOW}Port:${NC} $(get_config_value Port)"

    echo

    echo -e "${YELLOW}AddressFamily:${NC} $(get_config_value AddressFamily)"

    echo

    echo -e "${YELLOW}当前 Manager 配置:${NC}"

    if [ -f "$MANAGER_CONFIG" ]; then
        cat "$MANAGER_CONFIG"
    else
        echo "未创建"
    fi

    echo

    check_match_rules

    pause_screen
}

# ============================================================
# 测试 SSH 配置
# ============================================================

menu_test_config() {
    clear

    echo -e "${CYAN}========== SSH 配置测试 ==========${NC}"

    echo

    if test_ssh_config; then
        echo

        success "语法测试：通过"
    else
        echo

        error "语法测试：失败"

        pause_screen

        return
    fi

    echo

    info "正在检查实际生效配置..."

    local root_value
    local password_value

    root_value="$(get_config_value PermitRootLogin)"
    password_value="$(get_config_value PasswordAuthentication)"

    if [ -n "$root_value" ]; then
        success "PermitRootLogin = $root_value"
    else
        error "无法获取 PermitRootLogin"
    fi

    if [ -n "$password_value" ]; then
        success "PasswordAuthentication = $password_value"
    else
        error "无法获取 PasswordAuthentication"
    fi

    echo

    check_match_rules

    echo

    success "SSH 配置测试完成。"

    pause_screen
}

# ============================================================
# 恢复最近备份
# ============================================================

menu_restore_backup() {
    clear

    echo -e "${CYAN}========== 恢复 SSH 配置 ==========${NC}"

    echo

    local latest

    latest="$(get_latest_backup)"

    if [ -z "$latest" ]; then
        warning "没有找到 SSH 配置备份。"

        pause_screen

        return
    fi

    echo -e "${YELLOW}最近一次备份：${NC}"

    echo "$latest"

    echo

    warning "恢复备份会覆盖当前 SSH 配置！"

    warning "恢复前会先再次备份当前状态。"

    echo

    read -r -p \
        "$(echo -e "${CYAN}确定恢复吗？输入 yes 确认：${NC}")" \
        confirm

    if [ "$confirm" != "yes" ]; then
        success "已取消恢复。"

        pause_screen

        return
    fi

    # --------------------------------------------------------
    # 恢复前备份
    # --------------------------------------------------------

    warning "正在备份当前 SSH 配置..."

    if ! backup_config; then
        error "备份当前配置失败，取消恢复！"

        pause_screen

        return
    fi

    local rollback_backup="$CURRENT_BACKUP"

    # --------------------------------------------------------
    # 执行恢复
    # --------------------------------------------------------

    if restore_backup "$latest"; then
        # 语法检查
        if test_ssh_config; then
            # 重启
            if restart_ssh; then
                success "SSH 配置恢复成功！"
            else
                error "恢复后 SSH 重启失败！"

                warning "正在恢复恢复前的配置..."

                restore_backup "$rollback_backup"

                if test_ssh_config; then
                    restart_ssh >/dev/null 2>&1 || true
                fi
            fi
        else
            error "恢复后的 SSH 配置语法检查失败！"

            warning "正在恢复恢复前的配置..."

            restore_backup "$rollback_backup"

            if test_ssh_config; then
                restart_ssh >/dev/null 2>&1 || true
            fi
        fi
    else
        error "恢复失败！"

        warning "正在尝试恢复恢复前的配置..."

        restore_backup "$rollback_backup" >/dev/null 2>&1 || true
    fi

    pause_screen
}

# ============================================================
# 切换 PermitRootLogin
# ============================================================

toggle_permit_root() {
    local current
    local new_value
    local confirm

    current="$(get_config_value PermitRootLogin)"

    echo

    info "当前 PermitRootLogin：${current:-未知}"

    # --------------------------------------------------------
    # 当前允许 Root
    # --------------------------------------------------------

    if [ "$current" = "yes" ] ||
        [ "$current" = "prohibit-password" ] ||
        [ "$current" = "forced-commands-only" ]; then

        echo

        warning "准备禁止 Root SSH 登录。"

        echo

        # 检查普通管理用户
        if ! check_sudo_user; then
            echo

            error "没有检测到可靠的普通管理用户！"

            echo

            read -r -p \
                "$(echo -e "${CYAN}仍然禁止 Root 登录吗？输入 yes 确认：${NC}")" \
                confirm

            if [ "$confirm" != "yes" ]; then
                success "操作已取消。"

                return 0
            fi
        fi

        new_value="no"

    # --------------------------------------------------------
    # 当前禁止 Root
    # --------------------------------------------------------

    else
        warning "准备允许 Root SSH 登录。"

        new_value="yes"
    fi

    echo

    warning "即将设置：PermitRootLogin $new_value"

    echo

    read -r -p \
        "$(echo -e "${CYAN}确定继续吗？输入 yes 确认：${NC}")" \
        confirm

    if [ "$confirm" != "yes" ]; then
        success "操作已取消。"

        return 0
    fi

    echo

    if safe_modify \
        "PermitRootLogin" \
        "$new_value" \
        "$new_value"; then

        echo

        if [ "$new_value" = "no" ]; then
            success "Root SSH 登录已禁止。"
        else
            success "Root SSH 登录已允许。"
        fi
    else
        error "Root SSH 配置修改失败！"
    fi
}

# ============================================================
# 切换 PasswordAuthentication
# ============================================================

toggle_password_auth() {
    local current
    local new_value
    local confirm
    local pubkey
    local key_user

    current="$(get_config_value PasswordAuthentication)"

    echo

    info "当前 PasswordAuthentication：${current:-未知}"

    # --------------------------------------------------------
    # 当前允许密码
    # --------------------------------------------------------

    if [ "$current" = "yes" ] || [ -z "$current" ]; then

        echo

        warning "准备关闭 SSH 密码登录。"

        echo

        # ----------------------------------------------------
        # 检查 PubkeyAuthentication
        # ----------------------------------------------------

        pubkey="$(get_config_value PubkeyAuthentication)"

        if [ "$pubkey" != "yes" ]; then
            error "当前 PubkeyAuthentication 不是 yes！"

            error "关闭密码登录后可能无法 SSH 登录。"

            echo

            read -r -p \
                "$(echo -e "${CYAN}仍然继续吗？输入 yes 确认：${NC}")" \
                confirm

            if [ "$confirm" != "yes" ]; then
                success "操作已取消。"

                return 0
            fi
        else
            # ------------------------------------------------
            # 检查公钥
            # ------------------------------------------------

            key_user="$(check_key_login_available)"

            if [ -n "$key_user" ]; then
                success "检测到 SSH 公钥用户：$key_user"

                # 检查用户登录条件
                if ! check_user_login_safety "$key_user"; then
                    warning "该用户可能受到 Allow/Deny/Shell 等限制。"

                    echo

                    read -r -p \
                        "$(echo -e "${CYAN}仍然关闭密码登录吗？输入 yes 确认：${NC}")" \
                        confirm

                    if [ "$confirm" != "yes" ]; then
                        success "操作已取消。"

                        return 0
                    fi
                fi
            else
                error "没有检测到任何 authorized_keys！"

                error "关闭密码登录后可能导致无法 SSH 登录。"

                echo

                read -r -p \
                    "$(echo -e "${CYAN}仍然关闭密码登录吗？输入 yes 确认：${NC}")" \
                    confirm

                if [ "$confirm" != "yes" ]; then
                    success "操作已取消。"

                    return 0
                fi
            fi
        fi

        new_value="no"

    # --------------------------------------------------------
    # 当前禁止密码
    # --------------------------------------------------------

    else
        warning "准备允许 SSH 密码登录。"

        new_value="yes"
    fi

    echo

    warning "即将设置：PasswordAuthentication $new_value"

    echo

    read -r -p \
        "$(echo -e "${CYAN}确定继续吗？输入 yes 确认：${NC}")" \
        confirm

    if [ "$confirm" != "yes" ]; then
        success "操作已取消。"

        return 0
    fi

    echo

    if safe_modify \
        "PasswordAuthentication" \
        "$new_value" \
        "$new_value"; then

        echo

        if [ "$new_value" = "no" ]; then
            success "SSH 密码登录已禁止。"
        else
            success "SSH 密码登录已允许。"
        fi
    else
        error "PasswordAuthentication 修改失败！"
    fi
}

# ============================================================
# 显示备份列表
# ============================================================

show_backups() {
    echo

    echo -e "${YELLOW}SSH 配置备份：${NC}"

    echo

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "暂无备份。"

        return
    fi

    local found=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        found=1

        local timestamp
        local path

        timestamp="$(echo "$line" | awk '{print $1}')"
        path="$(echo "$line" | cut -d' ' -f2-)"

        echo -e "${GREEN}${timestamp}${NC}"
        echo "  $path"
        echo
    done < <(
        find "$BACKUP_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'ssh_backup_*' \
            -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' 2>/dev/null |
        sort -r
    )

    if [ "$found" -eq 0 ]; then
        echo "暂无备份。"
    fi
}

# ============================================================
# 显示当前 Manager 配置
# ============================================================

show_manager_config() {
    echo

    echo -e "${CYAN}========== SSH Manager 配置 ==========${NC}"

    echo

    if [ -f "$MANAGER_CONFIG" ]; then
        cat "$MANAGER_CONFIG"
    else
        warning "SSH Manager 配置文件不存在："

        echo "$MANAGER_CONFIG"
    fi

    echo
}

# ============================================================
# 初始化 Manager
#
# 第一次运行不自动修改 SSH。
#
# 只有用户选择修改时才创建：
#   00-ssh-manager.conf
# ============================================================

initialize_manager() {
    if [ ! -d "$SSHD_CONFIG_DIR" ]; then
        mkdir -p "$SSHD_CONFIG_DIR" || {
            error "无法创建 $SSHD_CONFIG_DIR"

            exit 1
        }
    fi
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {
    while true; do
        clear

        show_status

        echo -e "${CYAN}----------------------------------------------${NC}"

        local PRL
        local PA

        PRL="$(get_config_value PermitRootLogin)"
        PA="$(get_config_value PasswordAuthentication)"

        # ----------------------------------------------------
        # Root 菜单
        # ----------------------------------------------------

        if [ "$PRL" = "yes" ] ||
            [ "$PRL" = "prohibit-password" ] ||
            [ "$PRL" = "forced-commands-only" ]; then

            echo -e "1. ${YELLOW}禁止 Root SSH 登录${NC}"
        else
            echo -e "1. ${YELLOW}允许 Root SSH 登录${NC}"
        fi

        # ----------------------------------------------------
        # Password 菜单
        # ----------------------------------------------------

        if [ "$PA" = "yes" ]; then
            echo -e "2. ${YELLOW}禁止 SSH 密码登录${NC}"
        else
            echo -e "2. ${YELLOW}允许 SSH 密码登录${NC}"
        fi

        echo -e "3. ${BLUE}查看详细 SSH 配置${NC}"

        echo -e "4. ${BLUE}测试 SSH 配置${NC}"

        echo -e "5. ${MAGENTA}恢复最近一次备份${NC}"

        echo -e "6. ${BLUE}查看备份列表${NC}"

        echo -e "7. ${BLUE}查看 Manager 配置${NC}"

        echo -e "0. ${YELLOW}退出${NC}"

        echo -e "${CYAN}----------------------------------------------${NC}"

        read -r -p \
            "$(echo -e "${CYAN}请输入选项 [0-7]: ${NC}")" \
            choice

        case "$choice" in
            1)
                toggle_permit_root

                pause_screen
                ;;
            2)
                toggle_password_auth

                pause_screen
                ;;
            3)
                show_detailed_config
                ;;
            4)
                menu_test_config
                ;;
            5)
                menu_restore_backup
                ;;
            6)
                clear

                echo -e "${CYAN}========== SSH 备份列表 ==========${NC}"

                show_backups

                echo

                pause_screen
                ;;
            7)
                clear

                show_manager_config

                pause_screen
                ;;
            0)
                clear;

                success "退出 SSH 配置管理工具。"

                exit 0
                ;;
            *)
                error "无效选项！"

                pause_screen
                ;;
        esac
    done
}

# ============================================================
# 主程序
# ============================================================

main() {
    # --------------------------------------------------------
    # 基础检查
    # --------------------------------------------------------

    check_root

    check_ssh_config

    init_sshd

    init_ssh_service

    init_current_user

    initialize_manager

    # --------------------------------------------------------
    # 当前配置必须先正常
    # --------------------------------------------------------

    if ! test_ssh_config; then
        echo

        error "当前 SSH 配置本身存在错误！"

        error "为了安全，不执行任何修改。"

        exit 1
    fi

    # --------------------------------------------------------
    # 提示当前用户
    # --------------------------------------------------------

    echo

    info "当前用户：$CURRENT_USER"

    if [ -n "$SSH_CONNECTION" ]; then
        info "当前连接：SSH"
    else
        info "当前连接：本地终端 / 非 SSH"
    fi

    # --------------------------------------------------------
    # 检查 Match
    # --------------------------------------------------------

    check_match_rules

    # --------------------------------------------------------
    # 清理旧备份
    # --------------------------------------------------------

    cleanup_backups

    # --------------------------------------------------------
    # 启动菜单
    # --------------------------------------------------------

    main_menu
}

# ============================================================
# 启动
# ============================================================

main "$@"
