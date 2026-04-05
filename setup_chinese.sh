#!/bin/bash

# ============================================================
# Debian/Ubuntu 语言环境管理脚本 
# 中文环境一键配置 与 系统环境一键还原,增强型系统识别、强制重置 LC_ALL
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

# --- 增强型系统检测逻辑 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    # 统一转为小写进行模糊匹配
    OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    OS_LIKE=$(echo "$ID_LIKE" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$OS_ID" == *"ubuntu"* || "$OS_LIKE" == *"ubuntu"* ]]; then
        OS="ubuntu"
    else
        OS="debian"
    fi
elif [ -f /etc/debian_version ] || command -v apt-get >/dev/null 2>&1; then
    OS="debian"
else
    echo -e "${RED}错误：未检测到 Debian/Ubuntu 系列系统，脚本停止。${NC}"
    exit 1
fi

# --- 函数：等待任意键继续 ---
pause_ret() {
    echo -e "\n${YELLOW}操作完成。按任意键返回主菜单...${NC}"
    read -n 1 -s -r
}

# --- 函数：设置中文环境 ---
setup_chinese() {
    echo -e "${GREEN}>>> 正在开启中文环境配置 (系统类型: $OS)...${NC}"
    
    # 1. 安装基础包
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y fonts-noto-cjk fonts-wqy-microhei fonts-wqy-zenhei manpages-zh locales

    # 2. 修复翻译文件缺失
    if [ "$OS" == "ubuntu" ]; then
        apt install -y language-pack-zh-hans
        apt install --reinstall -y locales
    else
        echo "正在重装核心组件以恢复翻译文件 (.mo)..."
        apt install --reinstall -y locales bash coreutils grep sed
    fi

    # 3. 生成 Locale
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/g' /etc/locale.gen
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
    locale-gen zh_CN.UTF-8 en_US.UTF-8

    # 4. 写入底层系统配置
    cat > /etc/default/locale <<EOF
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
LC_ALL=zh_CN.UTF-8
EOF

    # 5. 写入全局 profile (强制覆盖当前及后续会话)
    cat > /etc/profile.d/chinese.sh <<EOF
# 强制清除可能存在的英文变量残留
unset LC_ALL
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
alias cman='man -L zh_CN'
EOF
    chmod +x /etc/profile.d/chinese.sh

    # 6. 屏蔽 SSH 客户端语言注入
    if [ -f /etc/ssh/sshd_config ]; then
        echo "正在优化 SSH 服务配置..."
        sed -i 's/^\s*AcceptEnv LANG LC_*/#AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi

    echo -e "${GREEN}√ 中文环境已配置成功！${NC}"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}由于当前进程已被锁定，请执行以下命令使中文生效：${NC}"
    echo -e "      ${GREEN}exec bash --login${NC}"
    echo -e "      (或断开重新连接 SSH)${NC}"
    echo -e "------------------------------------------------"
    pause_ret
}

# --- 函数：还原英文环境 ---
restore_english() {
    echo -e "${YELLOW}>>> 正在还原系统默认语言 (en_US.UTF-8)...${NC}"

    # 1. 还原 Locale 配置文件
    cat > /etc/default/locale <<EOF
LANG=en_US.UTF-8
EOF

    # 2. 删除自定义脚本和清理残留
    rm -f /etc/profile.d/chinese.sh
    sed -i '/zh_CN.UTF-8/d' ~/.bashrc
    sed -i '/alias cman=/d' ~/.bashrc

    # 3. 恢复 SSH 默认行为
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#AcceptEnv LANG LC_*/AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi

    # 4. 强制刷新当前会话变量
    export LANG=en_US.UTF-8
    unset LANGUAGE
    unset LC_ALL

    echo -e "${GREEN}√ 系统已还原为英文环境！${NC}"
    echo -e "提示：建议断开重新连接 SSH 以恢复英文界面。"
    pause_ret
}

# --- 交互主菜单循环 ---
while true; do
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}    Debian/Ubuntu 语言环境管理脚本           ${NC}"
    echo -e "${GREEN}    系统识别: $OS                             ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e " 1. 一键设置中文环境 (zh_CN.UTF-8)"
    echo -e " 2. 还原系统默认环境 (en_US.UTF-8)"
    echo -e " 3. 退出"
    echo -e "${GREEN}==============================================${NC}"
    read -p "请输入选项 : " choice

    case $choice in
        1)
            setup_chinese
            ;;
        2)
            restore_english
            ;;
        3)
            echo -e "${YELLOW}退出脚本。${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新选择。${NC}"
            sleep 1
            ;;
    esac
done
