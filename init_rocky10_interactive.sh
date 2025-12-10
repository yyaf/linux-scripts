#!/bin/bash

# 脚本名称: init_rocky10_interactive.sh
# 描述: Rocky Linux 10 服务器安全初始化脚本（交互式版本，基于 2025 年最佳实践）
# 作者: Yafeng Yue
# 版本: 1.4 (密码策略已关闭)
# 使用: ./init_rocky10_interactive.sh
# 注意: 以 root 或 sudo 执行。脚本会提示输入自定义值。

# ---------------- 辅助函数 ----------------
# 函数: 检查命令是否成功
check_status() {
    if [ $? -ne 0 ]; then
        echo "错误: $1 失败！脚本退出。"
        exit 1
    fi
}

# 函数: 验证端口号（1024-65535）
validate_port() {
    if ! [[ $1 =~ ^[0-9]+$ ]] || [ $1 -lt 1024 ] || [ $1 -gt 65535 ]; then
        echo "无效端口: 必须是 1024-65535 的数字。"
        exit 1
    fi
}

# ---------------- 交互式输入配置 ----------------
# 理由: 允许用户自定义，避免硬编码，提高可复用性。
echo "欢迎使用 Rocky Linux 10 初始化脚本！请按提示输入值（Enter 使用默认）。"

read -p "新用户名 (默认: user): " USERNAME
USERNAME=${USERNAME:-user}

read -s -p "新用户密码 (隐藏输入，必填): " USER_PASSWORD
echo ""  # 新行
if [ -z "$USER_PASSWORD" ]; then
    echo "密码不能为空！退出。"
    exit 1
fi

read -p "SSH 端口 (默认: 2222): " SSH_PORT
SSH_PORT=${SSH_PORT:-2222}
validate_port $SSH_PORT

read -p "是否启用 SSH 密码登录 (y/n，默认 n)? " ENABLE_PASSWORD
ENABLE_PASSWORD=${ENABLE_PASSWORD:-n}

read -p "时区 (默认: Asia/Shanghai): " TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Shanghai}

read -p "主机名 (默认: web-server-01): " HOSTNAME
HOSTNAME=${HOSTNAME:-web-server-01}

read -p "Swap 大小 (默认: 2G，如果 RAM <4GB): " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-2G}

read -p "Logwatch 报告邮箱 (默认: admin@example.com): " EMAIL_FOR_LOGWATCH
EMAIL_FOR_LOGWATCH=${EMAIL_FOR_LOGWATCH:-admin@example.com}

# ---------------- 步骤 0: 前置检查 ----------------
# 理由: 确保系统是 Rocky Linux 10，避免在旧版运行导致兼容问题。最小化安装减少攻击面。
# 命令作用: 显示版本并检查仓库。
echo "步骤 0: 前置检查系统版本和仓库..."
cat /etc/rocky-release
check_status "版本检查"
sudo dnf repolist
check_status "仓库列表"

# ---------------- 步骤 1: 系统全量更新 + 自动更新 ----------------
# 理由: 修补已知漏洞（如 CVE），自动化防止零日攻击。Rocky 10 使用 upgrade 更彻底。
# 命令作用: 更新所有包，安装自动更新工具，并启用定时器。
echo "步骤 1: 系统全量更新..."
sudo dnf upgrade -y
check_status "系统更新"
sudo dnf install dnf-automatic -y
check_status "安装 dnf-automatic"
sudo systemctl enable --now dnf-automatic-install.timer
check_status "启用自动更新"

# ---------------- 步骤 2: 创建普通用户并配置 Sudo ----------------
# 理由: 最小权限原则，防 root 暴露。密码策略已关闭，不应用任何过期规则。
# 命令作用: 创建用户、设置密码、加入 wheel 组（无密码策略）。
echo "步骤 2: 创建普通用户..."
sudo adduser $USERNAME
check_status "创建用户"
echo "$USERNAME:$USER_PASSWORD" | sudo chpasswd
check_status "设置密码"
sudo usermod -aG wheel $USERNAME
check_status "加入 wheel 组"
# 密码策略已关闭：不应用 -n -x -w -i

# ---------------- 步骤 3: SSH 安全加固 ----------------
# 理由: SSH 是首要攻击向量。密钥登录防爆破，端口改动避扫描，限制尝试减少风险。
# 命令作用: 配置 sshd_config，重启服务。注意: 先在本地生成密钥并 copy-id（如果禁用密码）。
echo "步骤 3: SSH 安全加固..."
echo "提醒: 如果禁用密码，请先在本地执行: ssh-keygen -t ed25519 && ssh-copy-id $USERNAME@your_server_ip"
read -p "按 Enter 继续（确认已准备）..."

sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/#PermitEmptyPasswords no/PermitEmptyPasswords no/' /etc/ssh/sshd_config
echo "Port $SSH_PORT" | sudo tee -a /etc/ssh/sshd_config
if [ "$ENABLE_PASSWORD" = "y" ]; then
    echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config
else
    echo "PasswordAuthentication no" | sudo tee -a /etc/ssh/sshd_config
    echo "警告: 已禁用密码登录，确保密钥已配置！"
fi
echo "PubkeyAuthentication yes" | sudo tee -a /etc/ssh/sshd_config
echo "ChallengeResponseAuthentication no" | sudo tee -a /etc/ssh/sshd_config
echo "UsePAM yes" | sudo tee -a /etc/ssh/sshd_config
echo "MaxAuthTries 3" | sudo tee -a /etc/ssh/sshd_config
echo "LoginGraceTime 30" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart sshd
check_status "重启 SSH"
echo "警告: 新终端测试登录: ssh -p $SSH_PORT $USERNAME@your_ip"
read -p "按 Enter 继续（确认登录成功）..."

# ---------------- 步骤 4: 配置防火墙 ----------------
# 理由: 双重防护（云 + 内部）防端口暴露。nftables 后端更高效。
# 命令作用: 安装 firewalld，添加规则，重载。
echo "步骤 4: 配置防火墙..."
sudo dnf install firewalld -y
check_status "安装 firewalld"
sudo systemctl enable --now firewalld
check_status "启用 firewalld"
sudo firewall-cmd --permanent --add-port=$SSH_PORT/tcp
check_status "放行 SSH 端口"
read -p "是否放行 HTTP/HTTPS (y/n，默认 n)? " ADD_WEB
if [ "$ADD_WEB" = "y" ]; then
    sudo firewall-cmd --permanent --add-service=http --add-service=https
    check_status "放行 Web 端口"
fi
sudo firewall-cmd --reload
check_status "重载防火墙"
sudo firewall-cmd --list-all

# ---------------- 步骤 5: 设置时区和主机名 ----------------
# 理由: 准确时间对日志/证书重要。NTP 防漂移。
# 命令作用: 设置时区/主机名，安装 chrony。
echo "步骤 5: 设置时区和主机名..."
sudo timedatectl set-timezone $TIMEZONE
check_status "设置时区"
sudo hostnamectl set-hostname $HOSTNAME
check_status "设置主机名"
sudo dnf install chrony -y
check_status "安装 chrony"
sudo systemctl enable --now chronyd
check_status "启用 chronyd"
timedatectl

# ---------------- 步骤 6: 安装常用工具和 EPEL 源 ----------------
# 理由: EPEL/CRB 提供额外包。最小安装防系统膨胀。
# 命令作用: 启用仓库，安装工具，移除多余。
echo "步骤 6: 安装 EPEL 和工具..."
sudo dnf install epel-release -y
check_status "安装 EPEL"
sudo dnf config-manager --set-enabled crb
check_status "启用 CRB"
sudo dnf install vim wget curl git htop net-tools unzip -y
check_status "安装工具"
sudo dnf autoremove -y
check_status "移除多余包"

# ---------------- 步骤 7: 安装并配置 Fail2Ban ----------------
# 理由: 动态封禁 IP 防爆破。自定义参数更严格。
# 命令作用: 安装，复制配置，编辑 jail，启用。
echo "步骤 7: 安装 Fail2Ban..."
sudo dnf install fail2ban -y
check_status "安装 Fail2Ban"
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
check_status "复制配置"
sudo sed -i "/\[sshd\]/a enabled = true\nport = $SSH_PORT\nbantime = 1h\nfindtime = 10m\nmaxretry = 3" /etc/fail2ban/jail.local
check_status "配置 jail"
sudo systemctl enable --now fail2ban
check_status "启用 Fail2Ban"
sudo fail2ban-client status sshd

# ---------------- 步骤 8: 配置 Swap 分区 ----------------
# 理由: 防低内存 OOM。swappiness 优化性能。
# 命令作用: 创建 Swap 文件，挂载，调整参数。
echo "步骤 8: 配置 Swap..."
free -h
sudo fallocate -l $SWAP_SIZE /swapfile
check_status "创建 Swap 文件"
sudo chmod 600 /swapfile
check_status "设置权限"
sudo mkswap /swapfile
check_status "格式化 Swap"
sudo swapon /swapfile
check_status "激活 Swap"
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
check_status "应用 swappiness"

# ---------------- 步骤 9: 启用 SELinux 和最小化服务 ----------------
# 理由: SELinux 防权限越界。最小服务减少漏洞。
# 命令作用: 检查 SELinux，禁用不需服务。
echo "步骤 9: SELinux 和最小化服务..."
sudo sestatus
check_status "SELinux 状态"
sudo dnf install policycoreutils-python-utils -y
check_status "安装 SELinux 工具"
sudo systemctl disable --now cups postfix  # 示例，根据需要调整
check_status "禁用服务"

# ---------------- 步骤 10: 自动安全更新和日志监控 ----------------
# 理由: 持续监控防入侵。Logwatch 每日报告。
# 命令作用: 安装 logwatch，配置 cron。
echo "步骤 10: 日志监控..."
sudo dnf install logwatch -y
check_status "安装 logwatch"
echo "logwatch --detail Low --mailto $EMAIL_FOR_LOGWATCH --service all --range yesterday" | sudo tee /etc/cron.daily/logwatch
check_status "配置 cron"

# ---------------- 完成 ----------------
echo "初始化完成！请检查日志，并重启服务器: sudo reboot"
echo "最终验证: SSH 登录、防火墙列表、Fail2Ban 状态。"
