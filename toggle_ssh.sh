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
#   8. 设置 SSH 账户密码
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
        read -r -n 1 -s -p "$(echo -e "${RED}请使用 root 用户运行！按任意键继续....  ${NC}")"
        echo
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
# 保留最近 2 个
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
        awk 'NR > 2 {sub(/^[^ ]+ /, ""); print}'
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
    local shell
    local users=""

    while IFS=: read -r user _ uid _ _ _ shell; do
        # UID >= 1000，排除 nobody
        if [ "$uid" -ge 1000 ] 2>/dev/null &&
            [ "$user" != "nobody" ]; then

            # 必须具有正常登录 Shell
            if is_login_shell "$shell"; then
                found=$((found + 1))

                if [ -z "$users" ]; then
                    users="$user"
                else
                    users="$users、$user"
                fi
            fi
        fi
    done < /etc/passwd

    if [ "$found" -eq 0 ]; then
        error "未找到普通登录用户！"
        warning "如果禁止 Root SSH 登录，可能导致无法登录服务器。"
        return 1
    fi

    success "检测到 $found 个普通登录用户：$users"
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

    echo -e "${YELLOW}========== SSH 当前状态 ==========${NC}"

    # --------------------------------------------------------
    # Root
    # --------------------------------------------------------

    case "$PRL" in
        yes)
            if [ "$PA" = "yes" ] && [ "$PUBKEY" = "yes" ]; then
                echo -e "Root 登录             : ${GREEN}允许（密码/密钥）${NC}"
            elif [ "$PA" = "yes" ]; then
                echo -e "Root 登录             : ${GREEN}允许（仅密码）${NC}"
            elif [ "$PUBKEY" = "yes" ]; then
                echo -e "Root 登录             : ${GREEN}允许（仅密钥）${NC}"
            else
                echo -e "Root 登录             : ${YELLOW}允许，但无可用认证方式${NC}"
            fi
            ;;
        prohibit-password)
            if [ "$PUBKEY" = "yes" ]; then
                echo -e "Root 登录             : ${YELLOW}仅允许密钥${NC}"
            else
                echo -e "Root 登录             : ${YELLOW}仅允许非密码认证${NC}"
            fi
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

    echo -e "${YELLOW}========== SSH 实际生效配置 ==========${NC}"

    echo

    echo -e "${CYAN}PermitRootLogin:${NC} $(get_config_value PermitRootLogin)"

    echo

    echo -e "${CYAN}PasswordAuthentication:${NC} $(get_config_value PasswordAuthentication)"

    echo

    echo -e "${CYAN}PubkeyAuthentication:${NC} $(get_config_value PubkeyAuthentication)"

    echo

    echo -e "${CYAN}KbdInteractiveAuthentication:${NC} $(get_config_value KbdInteractiveAuthentication)"

    echo

    echo -e "${CYAN}PermitEmptyPasswords:${NC} $(get_config_value PermitEmptyPasswords)"

    echo

    echo -e "${CYAN}MaxAuthTries:${NC} $(get_config_value MaxAuthTries)"

    echo

    echo -e "${CYAN}LoginGraceTime:${NC} $(get_config_value LoginGraceTime)"

    echo

    echo -e "${CYAN}X11Forwarding:${NC} $(get_config_value X11Forwarding)"

    echo

    echo -e "${CYAN}UsePAM:${NC} $(get_config_value UsePAM)"

    echo

    echo -e "${CYAN}Port:${NC} $(get_config_value Port)"

    echo

    echo -e "${CYAN}AddressFamily:${NC} $(get_config_value AddressFamily)"

    echo

    echo -e "${CYAN}当前 Manager 配置:${NC}"

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

    echo -e "${YELLOW}========== SSH 配置测试 ==========${NC}"

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

    echo -e "${YELLOW}========== 恢复 SSH 配置 ==========${NC}"

    echo

    local latest

    latest="$(get_latest_backup)"

    if [ -z "$latest" ]; then
        warning "没有找到 SSH 配置备份。"

        pause_screen

        return
    fi

    echo -e "${CYAN}最近一次备份：${NC}"

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
    # 当前 Root SSH 已允许
    # --------------------------------------------------------

    if [ "$current" = "yes" ]; then

        echo

        warning "准备禁止 Root SSH 登录。"

        echo

        # 禁止 Root 前检查普通管理用户
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
    # 当前 Root 仅允许密钥
    #
    # 不再先改成 no。
    # 直接恢复为 yes，使 Root 可以使用密码登录。
    # --------------------------------------------------------

    elif [ "$current" = "prohibit-password" ]; then

        echo

        warning "当前 Root SSH 仅允许密钥登录。"
        info "将允许 Root 使用密码登录。"

        new_value="yes"

    # --------------------------------------------------------
    # 当前 Root 仅允许强制命令
    # --------------------------------------------------------

    elif [ "$current" = "forced-commands-only" ]; then

        echo

        warning "当前 Root SSH 为仅允许强制命令模式。"
        info "将允许 Root 正常 SSH 登录。"

        new_value="yes"

    # --------------------------------------------------------
    # 当前 Root 已禁止
    # --------------------------------------------------------

    else

        echo

        warning "当前 Root SSH 登录已禁止。"
        info "将允许 Root SSH 登录。"

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

            if [ "$(get_config_value PasswordAuthentication)" = "yes" ]; then
                info "当前 SSH 密码登录已允许，Root 现在可以使用密码登录。"
            else
                warning "当前 SSH 密码登录仍然禁止，Root 目前只能使用其他允许的认证方式。"
            fi
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
# 设置 SSH 账户密码
#
# 注意：
#  - 不要求存在普通 sudo/wheel 用户。
#  - 默认设置 root 密码。
#  - 也可以输入其他已存在的登录用户。
#  - passwd 会在终端中隐藏密码输入。
#  - 设置密码不会自动修改 SSH 配置。
#
# 如果希望 Root 通过 SSH 使用密码登录，还需要同时满足：
#  - PermitRootLogin yes
#  - PasswordAuthentication yes
#  - root 账户具有有效密码
# ============================================================

set_ssh_account_password() {
    local account
    local user_shell
    local password_status

    echo

    echo -e "${YELLOW}========== 设置 SSH 账户密码 ==========${NC}"

    echo

    check_sudo_user || true

    echo

    read -r -p \
        "$(echo -e "${CYAN}请输入账户名称（直接回车默认 root）：${NC}")" \
        account

    # 默认 root
    account="${account:-root}"

    # 检查账户是否存在
    if ! getent passwd "$account" >/dev/null 2>&1; then
        error "账户不存在：$account"
        return 1
    fi

    # 检查账户 Shell
    user_shell="$(get_user_shell "$account")"

    if ! is_login_shell "$user_shell"; then
        warning "账户 $account 的 Shell 不适合 SSH 登录：${user_shell:-未知}"
        warning "如果这是一个专门禁止交互登录的系统账户，不建议为其设置 SSH 登录密码。"
        return 1
    fi

    echo
    info "当前账户：$account"
    info "当前 Shell：$user_shell"
    echo

    if [ "$account" = "root" ]; then
        warning "即将设置 root 账户密码。"
        warning "这不会自动开启 Root SSH 密码登录。"
    else
        warning "即将设置账户 $account 的登录密码。"
    fi

    echo
    info "密码输入时不会显示。"
    echo

    if ! passwd "$account"; then
        echo
        error "账户 $account 密码设置失败！"
        return 1
    fi

    echo

    # 检查密码状态
    password_status="$(passwd -S "$account" 2>/dev/null | awk '{print $2}')"

    case "$password_status" in
        P)
            success "账户 $account 的密码设置成功！"
            ;;
        L)
            warning "账户 $account 当前密码处于锁定状态。"
            warning "如果需要允许密码认证，请确认该账户没有被锁定。"
            ;;
        NP)
            warning "账户 $account 当前没有有效密码。"
            ;;
        *)
            success "账户 $account 密码设置完成。"
            ;;
    esac

    if [ "$account" = "root" ]; then
        echo
        info "Root 密码已经设置。"
        echo
        info "如果要通过 SSH 使用 Root 密码登录，还需要："
        echo "  PermitRootLogin yes"
        echo "  PasswordAuthentication yes"
        echo
        warning "设置密码不会自动开启 Root SSH 登录。"
    fi

    return 0
}

# ============================================================
# 选择 SSH 公钥账户
#
# 固定包含 root
# 普通账户：UID >= 1000 且 Shell 允许登录
# ============================================================

select_ssh_public_key_account() {
    local users=()
    local user
    local uid
    local shell
    local choice
    local index

    echo
    echo -e "${YELLOW}========== 设置 SSH 账户公钥 ==========${NC}"
    echo
    echo "请选择要设置公钥的账户："
    echo

    # --------------------------------------------------------
    # root 固定为第一个账户
    # --------------------------------------------------------

    users+=("root")

    # --------------------------------------------------------
    # 获取普通登录用户
    # --------------------------------------------------------

    while IFS=: read -r user _ uid _ _ _ shell; do
        if [ "$uid" -ge 1000 ] 2>/dev/null &&
            [ "$user" != "nobody" ] &&
            is_login_shell "$shell"; then

            # 避免 root / 重复账户
            if [ "$user" != "root" ]; then
                users+=("$user")
            fi
        fi
    done < /etc/passwd

    # --------------------------------------------------------
    # 显示账户列表
    # --------------------------------------------------------

    for index in "${!users[@]}"; do
        echo "$((index + 1)). ${users[$index]}"
    done

    echo "0. 返回"
    echo

    while true; do
        read -r -p \
            "$(echo -e "${CYAN}请选择账户 [0-${#users[@]}]: ${NC}")" \
            choice

        case "$choice" in
            0)
                return 1
                ;;

            ''|*[!0-9]*)
                error "无效选项！"
                ;;

            *)
                if [ "$choice" -ge 1 ] 2>/dev/null &&
                    [ "$choice" -le "${#users[@]}" ]; then

                    SELECTED_SSH_ACCOUNT="${users[$((choice - 1))]}"

                    return 0
                fi

                error "无效选项！"
                ;;
        esac
    done
}


# ============================================================
# 设置 SSH 账户公钥
#
# 注意：
#   - 不追加公钥
#   - 直接覆盖 authorized_keys
#   - root 也可以设置
# ============================================================

set_ssh_account_public_key() {
    local account
    local home_dir
    local user_shell
    local user_group
    local ssh_dir
    local authorized_keys
    local public_key
    local confirm

    # --------------------------------------------------------
    # 选择账户
    # --------------------------------------------------------

    SELECTED_SSH_ACCOUNT=""

    if ! select_ssh_public_key_account; then
        return 0
    fi

    account="$SELECTED_SSH_ACCOUNT"

    # --------------------------------------------------------
    # 检查账户
    # --------------------------------------------------------

    if ! getent passwd "$account" >/dev/null 2>&1; then
        error "账户不存在：$account"
        return 1
    fi

    user_shell="$(get_user_shell "$account")"

    if ! is_login_shell "$user_shell"; then
        warning "账户 $account 的 Shell 不适合 SSH 登录：${user_shell:-未知}"
        return 1
    fi

    # --------------------------------------------------------
    # 获取 Home 目录和主组
    # --------------------------------------------------------

    home_dir="$(getent passwd "$account" | cut -d: -f6)"
    user_group="$(id -gn "$account" 2>/dev/null)"

    if [ -z "$home_dir" ]; then
        error "无法获取账户 $account 的 Home 目录！"
        return 1
    fi

    if [ -z "$user_group" ]; then
        error "无法获取账户 $account 的主组！"
        return 1
    fi

    ssh_dir="${home_dir}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"

    # --------------------------------------------------------
    # 显示当前账户
    # --------------------------------------------------------

    echo
    info "当前账户：$account"
    info "Home 目录：$home_dir"
    info "SSH 目录：$ssh_dir"
    echo

    # --------------------------------------------------------
    # 输入新的公钥
    # --------------------------------------------------------

    info "请输入新的 SSH 公钥："
    echo
    read -r -p "> " public_key

    if [ -z "$public_key" ]; then
        error "SSH 公钥不能为空！"
        return 1
    fi

    # --------------------------------------------------------
    # 基本公钥格式检查
    #
    # 支持：
    #   ssh-ed25519
    #   ssh-rsa
    #   ecdsa-sha2-*
    #   sk-ssh-ed25519-*
    #   sk-ecdsa-sha2-*
    # --------------------------------------------------------

    case "$public_key" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519-*\ *|sk-ecdsa-sha2-*\ *)
            ;;
        *)
            error "公钥格式无效！"
            warning "请输入完整的 SSH 公钥，例如：ssh-ed25519 AAAA..."
            return 1
            ;;
    esac

    # --------------------------------------------------------
    # 覆盖前确认
    # --------------------------------------------------------

    echo
    warning "设置新的 SSH 公钥将覆盖该账户现有的 authorized_keys。"
    warning "原有公钥将被删除，且不会追加保留。"
    echo

    if [ -f "$authorized_keys" ]; then
        warning "检测到现有公钥文件：$authorized_keys"
    else
        info "当前账户还没有 authorized_keys 文件。"
    fi

    echo

    read -r -p \
        "$(echo -e "${YELLOW}输入 yes 确认覆盖：${NC}")" \
        confirm

    if [ "$confirm" != "yes" ]; then
        warning "已取消设置公钥。"
        return 0
    fi

    # --------------------------------------------------------
    # 创建 .ssh
    # --------------------------------------------------------

    if [ ! -d "$ssh_dir" ]; then
        if ! mkdir -p "$ssh_dir"; then
            error "无法创建 SSH 目录：$ssh_dir"
            return 1
        fi
    fi

    # --------------------------------------------------------
    # 设置 .ssh 权限
    # --------------------------------------------------------

    chmod 700 "$ssh_dir" || {
        error "无法设置 $ssh_dir 权限！"
        return 1
    }

    # --------------------------------------------------------
    # 覆盖 authorized_keys
    #
    # 使用 >，绝对不是 >>
    # --------------------------------------------------------

    if ! printf '%s\n' "$public_key" > "$authorized_keys"; then
        error "写入 SSH 公钥失败！"
        return 1
    fi

    # --------------------------------------------------------
    # 设置 authorized_keys 权限
    # --------------------------------------------------------

    chmod 600 "$authorized_keys" || {
        error "无法设置 authorized_keys 权限！"
        return 1
    }

    # --------------------------------------------------------
    # 恢复账户属主
    # --------------------------------------------------------

    if ! chown "$account:$user_group" "$ssh_dir" "$authorized_keys"; then
        error "无法设置 SSH 公钥文件属主！"
        return 1
    fi

    # --------------------------------------------------------
    # 最终验证
    # --------------------------------------------------------

    if [ ! -s "$authorized_keys" ]; then
        error "SSH 公钥写入后验证失败！"
        return 1
    fi

    echo
    success "账户 $account 的 SSH 公钥设置成功！"
    echo
    info "authorized_keys：$authorized_keys"
    info "文件权限：$(stat -c '%a' "$authorized_keys" 2>/dev/null)"
    info "文件属主：$(stat -c '%U:%G' "$authorized_keys" 2>/dev/null)"
    echo

    return 0
}


# ============================================================
# SSH 账户认证设置
# ============================================================

ssh_account_auth_menu() {
    local choice

    while true; do
        clear

        echo -e "${YELLOW}========== SSH 账户认证设置 ==========${NC}"
        echo
        echo -e "1. ${BLUE}设置账户密码${NC}"
        echo -e "2. ${BLUE}设置账户公钥${NC}"
        echo -e "0. ${CYAN}返回上级菜单${NC}"
        echo
        echo -e "${YELLOW}----------------------------------------------${NC}"

        read -r -p \
            "$(echo -e "${CYAN}请输入选项 [0-2]: ${NC}")" \
            choice

        case "$choice" in
            1)
                clear

                set_ssh_account_password

                pause_screen
                ;;

            2)
                clear

                set_ssh_account_public_key

                pause_screen
                ;;

            0)
                return 0
                ;;

            *)
                error "无效选项！"

                pause_screen
                ;;
        esac
    done
}
# ============================================================
# 显示备份列表
# ============================================================

show_backups() {
    echo

    echo -e "${CYAN}SSH 配置备份：${NC}"

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

    echo -e "${YELLOW}========== SSH Manager 配置 ==========${NC}"

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

        echo -e "${YELLOW}----------------------------------------------${NC}"

        local PRL
        local PA

        PRL="$(get_config_value PermitRootLogin)"
        PA="$(get_config_value PasswordAuthentication)"

        # ----------------------------------------------------
        # Root 菜单
        # ----------------------------------------------------

        if [ "$PRL" = "yes" ]; then
            echo -e "1. ${RED}禁止 Root SSH 登录${NC}"
        elif [ "$PRL" = "prohibit-password" ] || [ "$PRL" = "without-password" ]; then
            echo -e "1. ${CYAN}允许 Root 密码登录${NC}"
        else
            echo -e "1. ${CYAN}允许 Root SSH 登录${NC}"
        fi

        # ----------------------------------------------------
        # Password 菜单
        # ----------------------------------------------------

        if [ "$PA" = "yes" ]; then
            echo -e "2. ${RED}禁止 SSH 密码登录${NC}"
        else
            echo -e "2. ${CYAN}允许 SSH 密码登录${NC}"
        fi

        echo -e "3. ${BLUE}查看详细 SSH 配置${NC}"

        echo -e "4. ${BLUE}测试 SSH 配置${NC}"

        echo -e "5. ${MAGENTA}恢复最近一次备份${NC}"

        echo -e "6. ${BLUE}查看备份列表${NC}"

        echo -e "7. ${BLUE}查看 Manager 配置${NC}"

        echo -e "8. ${BLUE}设置 SSH 账户密码${NC}"

        echo -e "0. ${CYAN}退出${NC}"

        echo -e "${YELLOW}----------------------------------------------${NC}"

        read -r -p \
            "$(echo -e "${CYAN}请输入选项 [0-8]: ${NC}")" \
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

                echo -e "${YELLOW}========== SSH 备份列表 ==========${NC}"

                show_backups

                echo

                pause_screen
                ;;
            7)
                clear

                show_manager_config

                pause_screen
                ;;
            8)
                clear

                ssh_account_auth_menu

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
