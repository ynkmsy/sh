#!/bin/bash
# ==========================================
# 描述: 精确控制 Linux 系统 CPU 与内存占用 (保活)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：本脚本需要 root 权限执行。${PLAIN}"
    exit 1
fi

install_dependencies() {
    echo -e "${YELLOW}---> 正在安装编译依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -qq || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl build-essential tar || return 1
    else
        echo -e "${RED}错误：仅支持 apt-get 的系统（Debian/Ubuntu）。${PLAIN}"
        return 1
    fi
    return 0
}

compile_lookbusy() {
    echo -e "${YELLOW}---> 正在下载并编译 lookbusy...${PLAIN}"
    local work_dir
    work_dir=$(mktemp -d) || return 1
    cd "$work_dir" || return 1

    curl -fSL --retry 3 -o lookbusy-1.4.tar.gz \
        "http://www.devin.com/lookbusy/download/lookbusy-1.4.tar.gz" || {
        echo -e "${RED}下载 lookbusy 失败。${PLAIN}"
        cd / && rm -rf "$work_dir"
        return 1
    }

    tar -zxf lookbusy-1.4.tar.gz || {
        echo -e "${RED}解压 lookbusy 失败。${PLAIN}"
        cd / && rm -rf "$work_dir"
        return 1
    }

    cd lookbusy-1.4 || {
        echo -e "${RED}进入 lookbusy 目录失败。${PLAIN}"
        cd / && rm -rf "$work_dir"
        return 1
    }

    ./configure --quiet || {
        echo -e "${RED}configure 失败。${PLAIN}"
        cd / && rm -rf "$work_dir"
        return 1
    }

    make --quiet || {
        echo -e "${RED}make 失败。${PLAIN}"
        cd / && rm -rf "$work_dir"
        return 1
    }

    make install --quiet || {
        echo -e "${RED}make install 失败。${PLAIN}"
        cd / && rm -rf "$work_dir"
        return 1
    }

    cd / || true
    rm -rf "$work_dir"
    return 0
}

setup_service() {
    local cpu_pct="$1"
    local mem_pct="$2"
    local mem_max_mb="$3"
    local final_args=""

    # lookbusy 参数说明：
    # -c CPU占用百分比
    # -m 内存占用百分比
    # -M 最大内存 MB
    if (( cpu_pct > 0 )); then
        final_args+=" -c $cpu_pct"
    fi

    if (( mem_pct > 0 )); then
        final_args+=" -m $mem_pct"
        if (( mem_max_mb > 0 )); then
            final_args+=" -M $mem_max_mb"
        fi
    fi

    cat > /etc/systemd/system/lookbusy.service <<EOF
[Unit]
Description=Precision Keep-Alive Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/lookbusy$final_args
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || return 1
    systemctl enable --quiet lookbusy || return 1
    systemctl restart lookbusy || return 1

    sleep 1
    if systemctl is-active --quiet lookbusy; then
        echo -e "${GREEN}=================================================${PLAIN}"
        echo -e "${GREEN} 部署成功！保活服务已在后台静默运行。${PLAIN}"
        echo -e "${GREEN} CPU: ${cpu_pct}%  内存: ${mem_pct}%  内存上限: ${mem_max_mb}MB${PLAIN}"
        echo -e "${GREEN}=================================================${PLAIN}"
        return 0
    else
        echo -e "${RED}服务启动失败，当前状态：${PLAIN}"
        systemctl status lookbusy --no-pager -l || true
        return 1
    fi
}

install_main() {
    echo ""
    read -p "请输入 CPU 占用百分比 (0-100，直接回车或填 0 则不占用): " cpu_pct
    read -p "请输入 内存 占用百分比 (0-100，直接回车或填 0 则不占用): " mem_pct

    cpu_pct=${cpu_pct:-0}
    mem_pct=${mem_pct:-0}

    # 去除空白字符
    cpu_pct=$(echo "$cpu_pct" | tr -d '[:space:]')
    mem_pct=$(echo "$mem_pct" | tr -d '[:space:]')

    if [[ ! "$cpu_pct" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：CPU 占用请输入纯数字。${PLAIN}"
        return
    fi

    if [[ ! "$mem_pct" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：内存占用请输入纯数字。${PLAIN}"
        return
    fi

    # 避免 08、09 被当作八进制
    cpu_pct=$((10#$cpu_pct))
    mem_pct=$((10#$mem_pct))

    if (( cpu_pct < 0 || cpu_pct > 100 )); then
        echo -e "${RED}错误：CPU 占用范围 0-100。${PLAIN}"
        return
    fi

    if (( mem_pct < 0 || mem_pct > 100 )); then
        echo -e "${RED}错误：内存占用范围 0-100。${PLAIN}"
        return
    fi

    if (( cpu_pct == 0 && mem_pct == 0 )); then
        echo -e "${RED}均为 0，无操作退出。${PLAIN}"
        return
    fi

    local mem_max_mb=0
    if (( mem_pct > 0 )); then
        local total_mem
        total_mem=$(free -m | awk '/^Mem:/{print $2}')

        if [[ ! "$total_mem" =~ ^[0-9]+$ ]] || (( total_mem <= 0 )); then
            echo -e "${RED}错误：无法获取系统内存总量。${PLAIN}"
            return
        fi

        local target_mem_mb=$(( total_mem * mem_pct / 100 ))

        # 安全上限：防止单次分配过大导致 lookbusy 或系统异常
        if (( target_mem_mb > 1900 )); then
            echo -e "${YELLOW}警告: 目标内存 ${target_mem_mb}MB 超过安全值 1900MB，已限制为 1900MB。${PLAIN}"
            mem_max_mb=1900
        else
            mem_max_mb=$target_mem_mb
        fi

        echo -e "${GREEN}-> 内存百分比 ${mem_pct}% 对应约 ${target_mem_mb}MB，实际上限设为 ${mem_max_mb}MB。${PLAIN}"
    fi

    install_dependencies || {
        echo -e "${RED}依赖安装失败，操作中止。${PLAIN}"
        return
    }

    compile_lookbusy || {
        echo -e "${RED}lookbusy 编译安装失败，操作中止。${PLAIN}"
        return
    }

    setup_service "$cpu_pct" "$mem_pct" "$mem_max_mb" || {
        echo -e "${RED}服务配置失败，操作中止。${PLAIN}"
        return
    }
}

uninstall_main() {
    echo ""
    systemctl stop lookbusy 2>/dev/null || true
    systemctl disable lookbusy 2>/dev/null || true
    rm -f /etc/systemd/system/lookbusy.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/bin/lookbusy
    echo -e "${GREEN}---> 保活服务已彻底卸载。${PLAIN}"
}

set +e
while true; do
    echo ""
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "      Linux 精确保活运维脚本 (Professional)"
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "  ${YELLOW}1.${PLAIN} 安装 / 重新配置保活服务"
    echo -e "  ${YELLOW}2.${PLAIN} 完全卸载保活服务"
    echo -e "  ${YELLOW}3.${PLAIN} 退出"
    echo -e "${GREEN}=================================================${PLAIN}"
    read -p "请输入操作选项 [1-3]: " choice

    case $choice in
        1) install_main ;;
        2) uninstall_main ;;
        3) echo "已退出。"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择。${PLAIN}" ;;
    esac
done
