#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
GOST_DIR="$HOME/GOST"
GOST_BIN="$GOST_DIR/gost"
GOST_LOG="$GOST_DIR/gost.log"

# 获取本机IP
get_local_ip() {
    local ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n 1)
    [ -z "$ip" ] && ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="$(hostname)"
    echo "$ip"
}

# 检测系统架构
detect_arch() {
    case $(uname -m) in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        *) echo "amd64" ;;
    esac
}

# 获取最新版本
get_latest_version() {
    local version=$(curl -fsSL https://api.github.com/repos/ginuerzh/gost/releases/latest | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    echo "${version:-2.11.5}"
}

# 安装 GOST
install_gost() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}        GOST 一键安装脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    echo -e "${YELLOW}[1/5] 创建安装目录...${NC}"
    mkdir -p "$GOST_DIR"
    cd "$GOST_DIR" || return 1
    
    local arch=$(detect_arch)
    local version=$(get_latest_version)
    echo -e "${YELLOW}[2/5] 系统架构: ${arch}, 版本: ${version}${NC}"
    
    echo -e "${YELLOW}[3/5] 下载 GOST...${NC}"
    local url="https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${arch}-${version}.gz"
    wget -O gost.gz "$url" 2>/dev/null || {
        echo -e "${RED}下载失败${NC}"
        return 1
    }
    
    echo -e "${YELLOW}[4/5] 解压...${NC}"
    gunzip -f gost.gz
    chmod +x gost
    
    echo -e "${YELLOW}[5/5] 清理临时文件...${NC}"
    rm -f gost.gz
    
    if [ -f "$GOST_BIN" ]; then
        echo -e "${GREEN}✓ 安装成功！${NC}"
        return 0
    else
        echo -e "${RED}✗ 安装失败${NC}"
        return 1
    fi
}

# 停止 GOST
stop_gost() {
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}停止现有 GOST 进程...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
        sleep 1
        echo -e "${GREEN}✓ 已停止${NC}"
    fi
}

# 启动 GOST
start_gost() {
    local auth=""
    local proxy_url=""
    local ip=$(get_local_ip)
    
    cd "$GOST_DIR" || return 1
    stop_gost
    
    # 构建启动参数
    if [ "$1" = "4" ]; then
        # 无加密自适应
        auth=":${2}"
        proxy_url="${ip}:${2} (无加密自适应 HTTP/SOCKS5/ProxyIP)"
        echo -e "${GREEN}启动无加密自适应代理...${NC}"
    else
        # 带认证
        auth="${3}:${4}@:${2}"
        if [ "$1" = "1" ]; then
            proxy_url="http://${3}:${4}@${ip}:${2}"
            echo -e "${GREEN}启动 HTTP 代理...${NC}"
        elif [ "$1" = "2" ]; then
            proxy_url="socks5://${3}:${4}@${ip}:${2}"
            echo -e "${GREEN}启动 SOCKS5 代理...${NC}"
        else
            # 协议3：自适应（HTTP/SOCKS5 共用端口）
            proxy_url="http://${3}:${4}@${ip}:${2} 或 socks5://${3}:${4}@${ip}:${2} (自适应)"
            echo -e "${GREEN}启动自适应代理 (HTTP + SOCKS5 自动识别)...${NC}"
        fi
    fi
    
    # 后台运行
    nohup ./gost -L ${auth}${2} > gost.log 2>&1 &
    local pid=$!
    sleep 2
    
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 代理运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}"
        echo -e "${YELLOW}${proxy_url}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}日志: ${GOST_LOG}${NC}"
        return 0
    else
        echo -e "${RED}启动失败，查看日志: cat ${GOST_LOG}${NC}"
        return 1
    fi
}

# 开启自启
enable_autostart() {
    local port=$1
    local protocol=$2
    local user=$3
    local pass=$4
    
    # 构建自启命令
    local start_cmd="cd $GOST_DIR && nohup ./gost -L "
    if [ "$protocol" = "4" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L :${port} > gost.log 2>&1 &"
    else
        start_cmd="cd $GOST_DIR && nohup ./gost -L ${user}:${pass}@:${port} > gost.log 2>&1 &"
    fi
    
    # 写入 crontab
    (crontab -l 2>/dev/null | grep -v "$GOST_DIR/gost"; echo "@reboot $start_cmd") | crontab -
    
    echo -e "${GREEN}✓ 已配置开机自启${NC}"
    echo -e "${YELLOW}提示: Serv00 环境若进程被杀，可配合定时任务保活${NC}"
}

# 卸载
uninstall_gost() {
    echo -e "${YELLOW}卸载 GOST...${NC}"
    stop_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab -
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 配置代理
configure_proxy() {
    [ ! -f "$GOST_BIN" ] && { echo -e "${RED}请先安装 GOST${NC}"; return 1; }
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          配置代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    # 输入端口
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    
    # 选择协议
    echo -e "${BLUE}请选择协议:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应 (HTTP/SOCKS5 自动识别)"
    echo -e "  ${GREEN}4${NC}) 无加密自适应"
    echo -n -e "${YELLOW}请输入 [1-4]: ${NC}"
    read protocol
    [[ ! "$protocol" =~ ^[1-4]$ ]] && protocol=3
    
    # 账号密码（协议4除外）
    local username="admin"
    local password="123456"
    
    if [ "$protocol" -ne 4 ]; then
        echo -e "${BLUE}账号密码 (默认 admin/123456)${NC}"
        echo -n -e "${YELLOW}账号 [admin]: ${NC}"
        read input_user
        [ -n "$input_user" ] && username="$input_user"
        echo -n -e "${YELLOW}密码 [123456]: ${NC}"
        read input_pass
        [ -n "$input_pass" ] && password="$input_pass"
    fi
    
    # 启动
    start_gost "$protocol" "$port" "$username" "$password"
    
    # 自启
    echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
    read auto_start
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        enable_autostart "$port" "$protocol" "$username" "$password"
    fi
    
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
}

# 主菜单
show_menu() {
    echo
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        GOST 一键管理脚本            ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${GREEN}1${BLUE}) 安装 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}2${BLUE}) 卸载 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-2]: ${NC}"
}

# 主程序
while true; do
    show_menu
    read choice
    case $choice in
        1) install_gost && configure_proxy ;;
        2) uninstall_gost ;;
        0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效${NC}"; sleep 1 ;;
    esac
done
