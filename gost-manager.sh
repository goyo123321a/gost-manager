#!/usr/bin/env bash

# GOST Manager for Serv00 (no root required)
# GitHub: goyo123321a/gost-manager

set -e

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
repo="ginuerzh/gost"  # 使用 ginuerzh 版本，稳定性更好
base_url="https://api.github.com/repos/$repo/releases"

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "386" ;;
        armv5*) echo "armv5" ;;
        armv6*) echo "armv6" ;;
        armv7*) echo "armv7" ;;
        aarch64|arm64) echo "arm64" ;;
        mips64*) echo "mips64" ;;
        mips*) echo "mips" ;;
        mipsel*) echo "mipsle" ;;
        riscv64) echo "riscv64" ;;
        *) echo "amd64" ;;
    esac
}

# 检测操作系统
detect_os() {
    case $(uname -s) in
        Linux) echo "linux" ;;
        Darwin) echo "darwin" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        FreeBSD) echo "freebsd" ;;
        *) echo "linux" ;;
    esac
}

# 获取可用版本
get_versions() {
    curl -fsSL "$base_url" 2>/dev/null | awk -F'"' '/"tag_name":/ {print $4}' | head -10
}

# 获取最新版本
get_latest_version() {
    curl -fsSL "$base_url/latest" 2>/dev/null | awk -F'"' '/"tag_name":/ {print $4}' | head -1
}

# 安装 GOST
install_gost() {
    local version=$1
    local os=$(detect_os)
    local arch=$(detect_arch)
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}        GOST 一键安装脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    echo -e "${YELLOW}[1/5] 创建安装目录...${NC}"
    mkdir -p "$GOST_DIR"
    cd "$GOST_DIR" || return 1
    
    echo -e "${YELLOW}[2/5] 系统信息: ${os}/${arch}${NC}"
    echo -e "${YELLOW}[3/5] 版本: ${version}${NC}"
    
    # 构建下载 URL
    local download_url=""
    if [[ "$repo" == "ginuerzh/gost" ]]; then
        download_url="https://github.com/ginuerzh/gost/releases/download/${version}/gost-${os}-${arch}-${version}.gz"
    else
        download_url=$(curl -fsSL "$base_url/tags/${version}" 2>/dev/null | awk -F'"' -v re=".*${os}.*${arch}.*" '/"browser_download_url":/ && $4 ~ re { print $4 }' | head -1)
    fi
    
    echo -e "${YELLOW}[4/5] 下载中...${NC}"
    if curl -fsSL -o gost.gz "$download_url"; then
        gunzip -f gost.gz 2>/dev/null || true
        chmod +x gost
    else
        echo -e "${RED}下载失败，尝试备用地址...${NC}"
        download_url="https://github.com/go-gost/gost/releases/latest/download/gost_${os}_${arch}.tar.gz"
        curl -fsSL -o gost.tar.gz "$download_url" && tar -xzf gost.tar.gz && chmod +x gost
        rm -f gost.tar.gz
    fi
    
    echo -e "${YELLOW}[5/5] 清理临时文件...${NC}"
    rm -f gost.gz gost.tar.gz 2>/dev/null
    
    if [ -f "$GOST_BIN" ]; then
        echo -e "${GREEN}✓ 安装成功！${NC}"
        "$GOST_BIN" -V 2>/dev/null || echo -e "${YELLOW}GOST 已就绪${NC}"
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
    rm -f "$GOST_DIR/gost.pid"
}

# 获取本机 IP
get_local_ip() {
    local ip=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
    [ -z "$ip" ] && ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="localhost"
    echo "$ip"
}

# 启动 GOST
start_gost() {
    local port=$1
    local protocol=$2
    local username=$3
    local password=$4
    local ip=$(get_local_ip)
    
    cd "$GOST_DIR" || return 1
    stop_gost
    
    local cmd=""
    local proxy_url=""
    
    case $protocol in
        1)  # HTTP
            cmd="./gost -L http://${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 HTTP 代理...${NC}"
            ;;
        2)  # SOCKS5
            cmd="./gost -L socks5://${username}:${password}@:${port}"
            proxy_url="socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 SOCKS5 代理...${NC}"
            ;;
        3)  # 自适应 (HTTP/SOCKS5 自动识别)
            cmd="./gost -L ${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port} / socks5://${username}:${password}@${ip}:${port} (自适应)"
            echo -e "${GREEN}启动自适应代理 (HTTP + SOCKS5)...${NC}"
            ;;
        4)  # 无加密自适应
            cmd="./gost -L :${port}"
            proxy_url="${ip}:${port} (无加密，HTTP/SOCKS5 自适应)"
            echo -e "${GREEN}启动无加密自适应代理...${NC}"
            ;;
    esac
    
    nohup $cmd > "$GOST_LOG" 2>&1 &
    local pid=$!
    echo $pid > "$GOST_DIR/gost.pid"
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

# 配置开机自启
enable_autostart() {
    local port=$1
    local protocol=$2
    local username=$3
    local password=$4
    
    local start_cmd="cd $GOST_DIR && nohup ./gost -L "
    if [ "$protocol" = "4" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L :${port} > gost.log 2>&1 &"
    elif [ "$protocol" = "3" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L ${username}:${password}@:${port} > gost.log 2>&1 &"
    elif [ "$protocol" = "2" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L socks5://${username}:${password}@:${port} > gost.log 2>&1 &"
    else
        start_cmd="cd $GOST_DIR && nohup ./gost -L http://${username}:${password}@:${port} > gost.log 2>&1 &"
    fi
    
    # 清除旧配置并添加新配置
    local current_cron=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR/gost" || true)
    (echo "$current_cron"; echo "@reboot $start_cmd") | crontab -
    
    echo -e "${GREEN}✓ 已配置开机自启${NC}"
    echo -e "${YELLOW}提示: Serv00 环境若进程被杀，可设置定时任务保活${NC}"
}

# 配置代理
configure_proxy() {
    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${RED}未安装 GOST，请先安装${NC}"
        return 1
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          配置代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    # 输入端口
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效，请输入 1-65535${NC}"
    done
    
    # 选择协议
    echo -e "${BLUE}请选择协议:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应 (HTTP/SOCKS5 自动识别，推荐)"
    echo -e "  ${GREEN}4${NC}) 无加密自适应"
    echo -n -e "${YELLOW}请输入 [1-4] (默认3): ${NC}"
    read -r protocol
    [[ ! "$protocol" =~ ^[1-4]$ ]] && protocol=3
    
    # 账号密码（协议4除外）
    local username="admin"
    local password="123456"
    
    if [ "$protocol" -ne 4 ]; then
        echo -e "${BLUE}账号密码 (默认 admin/123456)${NC}"
        echo -n -e "${YELLOW}账号 [admin]: ${NC}"
        read -r input_user
        [ -n "$input_user" ] && username="$input_user"
        echo -n -e "${YELLOW}密码 [123456]: ${NC}"
        read -r input_pass
        [ -n "$input_pass" ] && password="$input_pass"
    fi
    
    # 启动
    if start_gost "$port" "$protocol" "$username" "$password"; then
        # 询问开机自启
        echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
        read -r auto_start
        if [[ "$auto_start" =~ ^[Yy]$ ]]; then
            enable_autostart "$port" "$protocol" "$username" "$password"
        fi
    fi
    
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
    echo
}

# 卸载 GOST
uninstall_gost() {
    echo -e "${YELLOW}正在卸载 GOST...${NC}"
    stop_gost
    # 清除 crontab
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab - 2>/dev/null || true
    # 删除目录
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 显示状态
show_status() {
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$GOST_BIN" ]; then
        echo -e "${GREEN}GOST 状态: 已安装${NC}"
        if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
            echo -e "${GREEN}进程状态: 运行中${NC}"
            local pid=$(pgrep -f "$GOST_BIN" | head -1)
            echo -e "${GREEN}进程 PID: ${pid}${NC}"
        else
            echo -e "${RED}进程状态: 未运行${NC}"
        fi
    else
        echo -e "${RED}GOST 状态: 未安装${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
}

# 主菜单
show_menu() {
    echo
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     GOST Manager for Serv00         ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${GREEN}1${BLUE}) 安装 GOST (最新版)            ║${NC}"
    echo -e "${BLUE}║  ${GREEN}2${BLUE}) 安装 GOST (选择版本)          ║${NC}"
    echo -e "${BLUE}║  ${GREEN}3${BLUE}) 配置代理                      ║${NC}"
    echo -e "${BLUE}║  ${GREEN}4${BLUE}) 查看状态                      ║${NC}"
    echo -e "${BLUE}║  ${GREEN}5${BLUE}) 停止 GOST                     ║${NC}"
    echo -e "${BLUE}║  ${GREEN}6${BLUE}) 卸载 GOST                     ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-6]: ${NC}"
}

# 选择版本安装
install_version_select() {
    echo -e "${YELLOW}正在获取可用版本列表...${NC}"
    local versions=$(get_versions)
    if [ -z "$versions" ]; then
        echo -e "${RED}获取版本失败，使用最新版本${NC}"
        install_gost "$(get_latest_version)"
        return
    fi
    
    echo -e "${BLUE}可用版本:${NC}"
    select version in $versions "取消"; do
        if [ "$version" = "取消" ]; then
            return
        elif [ -n "$version" ]; then
            install_gost "$version"
            break
        else
            echo -e "${RED}无效选择${NC}"
        fi
    done
}

# 主程序
main() {
    # 移除 root 检查，Serv00 普通用户也可运行
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) install_gost "$(get_latest_version)" ;;
            2) install_version_select ;;
            3) configure_proxy ;;
            4) show_status; echo -n -e "${GREEN}按任意键返回...${NC}"; read -n 1 ;;
            5) stop_gost; echo -n -e "${GREEN}按任意键返回...${NC}"; read -n 1 ;;
            6) uninstall_gost; echo -n -e "${GREEN}按任意键返回...${NC}"; read -n 1 ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# 如果有参数传入
if [ "$1" = "--install" ]; then
    install_gost "$(get_latest_version)"
elif [ "$1" = "--version" ] && [ -n "$2" ]; then
    install_gost "$2"
else
    main
fi
