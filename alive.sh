#!/bin/bash
# ==========================================
# 描述: 精确控制 Linux 系统 CPU 与内存占用 (保活)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

set -e

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：本脚本需要 root 权限执行。${PLAIN}"
    exit 1
fi

install_dependencies() {
    echo -e "${YELLOW}---> 正在安装编译依赖...${PLAIN}"
    apt-get update -y -qq
    apt-get install -y -qq curl build-essential tar
}

compile_lookbusy() {
    echo -e "${YELLOW}---> 正在下载并编译 lookbusy...${PLAIN}"
    WORK_DIR=$(mktemp -d)
    cd "$WORK_DIR"
    curl -sLO http://www.devin.com/lookbusy/download/lookbusy-1.4.tar.gz
    tar -zxf lookbusy-1.4.tar.gz
    cd lookbusy-1.4
    ./configure --quiet
    make --quiet
    make install --quiet
    cd /
    rm -rf "$WORK_DIR"
}

setup_service() {
    local cpu_args=$1
    local mem_args=$2
    local final_args=""

    [[ "$cpu_args" -gt 0 ]] && final_args="$final_args -c $cpu_args"
    [[ "$mem_args" -gt 0 ]] && final_args="$final_args -m ${mem_args}MB"

    cat > /etc/systemd/system/lookbusy.service <<EOF
[Unit]
Description=Precision Keep-Alive Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/lookbusy $final_args
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lookbusy --now --quiet
    
    if systemctl is-active --quiet lookbusy; then
        echo -e "${GREEN}=================================================${PLAIN}"
        echo -e "${GREEN} 部署成功！保活服务已在后台静默运行。${PLAIN}"
        echo -e "${GREEN}=================================================${PLAIN}"
    else
        echo -e "${RED}服务启动失败。${PLAIN}"
    fi
}

install_main() {
    echo ""
    read -p "请输入 CPU 占用百分比 (1-100，直接回车或填 0 则不占用): " cpu_pct
    read -p "请输入 内存 占用百分比 (1-100，直接回车或填 0 则不占用): " mem_pct

    # 如果用户直接按回车，自动赋值为 0
    cpu_pct=${cpu_pct:-0}
    mem_pct=${mem_pct:-0}

    if [[ ! "$cpu_pct" =~ ^[0-9]+$ ]] || [[ ! "$mem_pct" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：请输入纯数字。${PLAIN}"
        return
    fi

    if [[ "$cpu_pct" -eq 0 && "$mem_pct" -eq 0 ]]; then
        echo -e "${RED}均为 0，无操作退出。${PLAIN}"
        return
    fi

    local mem_val=0
    if [[ "$mem_pct" -gt 0 ]]; then
        local total_mem=$(free -m | awk '/^Mem:/{print $2}')
        mem_val=$(( total_mem * mem_pct / 100 ))
        
        # 安全限制：防止超过 2000MB 导致底层 malloc 报错
        if [[ "$mem_val" -gt 2000 ]]; then
            echo -e "${YELLOW}警告: 算出的内存 (${mem_val}MB) 超出 lookbusy 单次分配上限(2GB)。${PLAIN}"
            echo -e "${YELLOW}已自动将内存限制在安全值 1900MB。${PLAIN}"
            mem_val=1900
        else
            echo -e "${GREEN}-> 内存百分比 ${mem_pct}% 折算为 ${mem_val}MB。${PLAIN}"
        fi
    fi

    install_dependencies
    compile_lookbusy
    setup_service "$cpu_pct" "$mem_val"
}

uninstall_main() {
    echo ""
    systemctl stop lookbusy 2>/dev/null || true
    systemctl disable lookbusy 2>/dev/null || true
    rm -f /etc/systemd/system/lookbusy.service
    systemctl daemon-reload
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
