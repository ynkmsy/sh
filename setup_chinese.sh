#!/bin/bash

# ============================================================
# Debian/Ubuntu 语言环境管理脚本 
# 支持：中文环境一键配置 与 系统环境一键还原
# ============================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行此脚本 (sudo bash $0)${NC}"
  exit 1
fi

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    # 统一转为小写，并检查 ID 或 ID_LIKE 是否包含 ubuntu
    OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    OS_LIKE=$(echo "$ID_LIKE" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$OS_ID" == *"ubuntu"* || "$OS_LIKE" == *"ubuntu"* ]]; then
        OS="ubuntu"
    else
        OS="debian"
    fi
elif [ -f /etc/debian_version ]; then
    # 如果没有 os-release 但有 debian_version，肯定是 Debian 系
    OS="debian"
elif command -v apt-get >/dev/null 2>&1; then
    # 最后的保底方案：只要有 apt 命令，就按 Debian 逻辑走
    OS="debian"
else
    echo -e "${RED}错误：未检测到 Debian/Ubuntu 系列系统，脚本停止。${NC}"
    exit 1
fi

# --- 函数：等待任意键继续 ---
pause_ret() {
    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
}

# --- 函数：设置中文环境 ---
setup_chinese() {
    echo -e "${GREEN}>>> 正在开启中文环境配置...${NC}"
    
    # 1. 安装基础包
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y fonts-noto-cjk fonts-wqy-microhei fonts-wqy-zenhei manpages-zh locales

    # 2. 修复精简版系统翻译
    if [ "$OS" == "ubuntu" ]; then
        apt install -y language-pack-zh-hans
        apt install --reinstall -y locales
    else
        apt install --reinstall -y locales bash coreutils grep sed
    fi

    # 3. 生成 Locale
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/g' /etc/locale.gen
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
    locale-gen zh_CN.UTF-8 en_US.UTF-8

    # 4. 强制设置全局变量 (解决 LC_ALL 锁死问题)
    cat > /etc/default/locale <<EOF
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
LC_ALL=zh_CN.UTF-8
EOF

    # 5. 写入 Profile
    cat > /etc/profile.d/chinese.sh <<EOF
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
alias cman='man -L zh_CN'
EOF
    chmod +x /etc/profile.d/chinese.sh

    # 6. 修改 SSH 配置
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^\s*AcceptEnv LANG LC_*/#AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi

    echo -e "${GREEN}√ 中文环境配置完成！${NC}"
    echo -e "提示：请执行 'source /etc/profile.d/chinese.sh' 或重新连接 SSH 生效。"
    pause_ret
}

# --- 函数：还原英文环境 ---
restore_english() {
    echo -e "${YELLOW}>>> 正在还原系统默认语言 (en_US.UTF-8)...${NC}"

    # 1. 还原 Locale 配置文件
    cat > /etc/default/locale <<EOF
LANG=en_US.UTF-8
EOF

    # 2. 删除自定义脚本
    rm -f /etc/profile.d/chinese.sh

    # 3. 清理 .bashrc 中的残留
    sed -i '/zh_CN.UTF-8/d' ~/.bashrc
    sed -i '/alias cman=/d' ~/.bashrc

    # 4. 恢复 SSH AcceptEnv 设置
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#AcceptEnv LANG LC_*/AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi

    # 5. 立即清理当前会话变量
    export LANG=en_US.UTF-8
    unset LANGUAGE
    unset LC_ALL

    echo -e "${GREEN}√ 系统已还原为英文环境！${NC}"
    echo -e "提示：请重新连接 SSH 生效。"
    pause_ret
}

# --- 交互主菜单循环 ---
while true; do
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}    Debian/Ubuntu 语言环境管理脚本           ${NC}"
    echo -e "${GREEN}    系统检测: $OS                             ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e " 1. 一键设置中文环境 (zh_CN.UTF-8)"
    echo -e " 2. 还原系统默认环境 (en_US.UTF-8)"
    echo -e " 3. 退出脚本"
    echo -e "${GREEN}==============================================${NC}"
    read -p "请输入选项 [1-3]: " choice

    case $choice in
        1)
            setup_chinese
            ;;
        2)
            restore_english
            ;;
        3)
            echo -e "${YELLOW}退出。${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新选择。${NC}"
            sleep 1
            ;;
    esac
done
