#!/bin/bash

# ============================================================
# Debian/Ubuntu 中文环境全能优化脚本 (增强版)
# 兼容：Debian 10/11/12, Ubuntu 20.04/22.04/24.04/26.04
# ============================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== 开始配置中文环境 (兼容 Debian & Ubuntu) ===${NC}"

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行此脚本 (sudo bash $0)${NC}"
  exit 1
fi

# 2. 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="debian"
fi
echo -e "${GREEN}检测到系统: $OS${NC}"

# 3. 更新软件源并安装基础包
echo -e "${GREEN}[1/7] 更新软件源并安装必要工具...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y fonts-noto-cjk fonts-wqy-microhei fonts-wqy-zenhei manpages-zh locales

# 4. 修复系统翻译缺失 (针对 Cloud/Lite 精简版)
echo -e "${GREEN}[2/7] 修复精简版系统翻译文件...${NC}"
if [ "$OS" == "ubuntu" ]; then
    apt install -y language-pack-zh-hans
    apt install --reinstall -y locales
else
    echo "正在强制重装核心组件以恢复翻译文件 (.mo)..."
    apt install --reinstall -y locales bash coreutils grep sed
fi

# 5. 生成 Locale
echo -e "${GREEN}[3/7] 生成中文 Locale...${NC}"
[ -f /etc/locale.gen ] || touch /etc/locale.gen
sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/g' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
locale-gen zh_CN.UTF-8 en_US.UTF-8

# 6. 设置系统全局语言
echo -e "${GREEN}[4/7] 配置系统默认语言...${NC}"
update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

# 7. 写入全局环境变量 (对所有用户生效)
echo -e "${GREEN}[5/7] 配置全局环境变量...${NC}"
cat > /etc/profile.d/chinese.sh <<EOF
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
alias cman='man -L zh_CN'
EOF
chmod +x /etc/profile.d/chinese.sh

# 8. 修改 SSH 配置 (防止客户端语言污染)
echo -e "${GREEN}[6/7] 优化 SSH 服务端设置...${NC}"
if [ -f /etc/ssh/sshd_config ]; then
    # 备份原配置
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%T)"
    # 注释掉 AcceptEnv
    sed -i 's/^\s*AcceptEnv LANG LC_*/#AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config
    
    # 检查语法并重启
    if sshd -t > /dev/null 2>&1; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        echo "SSH 配置已更新并重启。"
    else
        echo -e "${RED}警告: SSH 配置语法检查失败，已跳过重启。${NC}"
    fi
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}配置完成！请执行以下操作：${NC}"
echo -e "1. 立即生效: ${YELLOW}source /etc/profile.d/chinese.sh${NC}"
echo -e "2. 建议：${YELLOW}断开并重新连接 SSH${NC}"
echo -e "3. 验证：输入 ${YELLOW}date${NC} 查看是否显示为中文"
echo -e "4. 验证：输入 ${YELLOW}cman ls${NC} 查看中文帮助手册"
echo -e "${GREEN}========================================${NC}"
