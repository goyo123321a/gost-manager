#!/usr/bin/env bash

# GOST Manager for Serv00 (官方版优先，旧版备用)

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
        *) echo "amd64" ;;
    esac
}

# 检测操作系统
detect_os() {
    case $(uname -s) in
        Linux) echo "linux" ;;
        Darwin) echo "darwin" ;;
        *) echo "linux" ;;
    esac
}

# 安装 GOST（官方版优先，旧版备用）
install_gost() {
    local os=$(detect_os)
    local arch=$(detect_arch)
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}        GOST 一键安装${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    echo -e "${YELLOW}[1/5] 创建目录...${NC}"
    mkdir -p "$GOST_DIR"
    cd "$GOST_DIR" || return 1
    
    echo -e "${YELLOW}[2/5] 系统: ${os}/${arch}${NC}"
    
    local success=0
    
    # ========== 方法1: go-gost/gost 官方最新版 ==========
    echo -e "${YELLOW}[3/5] 尝试官方版 (go-gost/gost)...${NC}"
    local url1="https://github.com/go-gost/gost/releases/latest/download/gost_${os}_${arch}.tar.gz"
    echo -e "      地址: ${url1}"
    
    if curl -fsSL -o gost.tar.gz "$url1" 2>/dev/null || wget -q "$url1" -O gost.tar.gz 2>/dev/null; then
        tar -xzf gost.tar.gz 2>/dev/null
        chmod +x gost 2>/dev/null
        rm -f gost.tar.gz
        if [ -f "$GOST_BIN" ]; then
            echo -e "${GREEN}✓ 官方版安装成功！${NC}"
            "$GOST_BIN" -V 2>/dev/null | head -1 || echo -e "${GREEN}GOST (go-gost) 已就绪${NC}"
            success=1
        fi
    else
        echo -e "${YELLOW}⚠ 官方版下载失败，尝试备用源...${NC}"
    fi
    
    # ========== 方法2: ginuerzh/gost 旧版（备用） ==========
    if [ $success -eq 0 ]; then
        echo -e "${YELLOW}[4/5] 尝试备用版 (ginuerzh/gost)...${NC}"
        local url2="https://github.com/ginuerzh/gost/releases/latest/download/gost-${os}-${arch}.gz"
        echo -e "      地址: ${url2}"
        
        if curl -fsSL -o gost.gz "$url2" 2>/dev/null || wget -q "$url2" -O gost.gz 2>/dev/null; then
            gunzip -f gost.gz 2>/dev/null
            chmod +x gost
            rm -f gost.gz
            if [ -f "$GOST_BIN" ]; then
                echo -e "${GREEN}✓ 备用版安装成功！${NC}"
                "$GOST_BIN" -V 2>/dev/null | head -1 || echo -e "${GREEN}GOST (ginuerzh) 已就绪${NC}"
                success=1
            fi
        else
            echo -e "${RED}✗ 备用版也下载失败${NC}"
        fi
    fi
    
    # ========== 方法3: 指定版本 v2.11.5（最后备用） ==========
    if [ $success -eq 0 ]; then
        echo -e "${YELLOW}[5/5] 尝试稳定版 v2.11.5...${NC}"
        local url3="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-${os}-${arch}-2.11.5.gz"
        echo -e "      地址: ${url3}"
        
        if curl -fsSL -o gost.gz "$url3" 2>/dev/null || wget -q "$url3" -O gost.gz 2>/dev/null; then
            gunzip -f gost.gz 2>/dev/null
            chmod +x gost
            rm -f gost.gz
            if [ -f "$GOST_BIN" ]; then
                echo -e "${GREEN}✓ 稳定版 v2.11.5 安装成功！${NC}"
                success=1
            fi
        else
            echo -e "${RED}✗ 所有下载源均失败${NC}"
        fi
    fi
    
    # 清理临时文件
    rm -f gost.gz gost.tar.gz 2>/dev/null
    
    if [ $success -eq 1 ]; then
        echo -e "${GREEN}✓ GOST 安装成功！${NC}"
        return 0
    else
        echo -e "${RED}✗ 安装失败，请检查网络连接${NC}"
        return 1
    fi
}

# 停止 GOST
stop_gost() {
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}停止 GOST...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
        sleep 1
        echo -e "${GREEN}✓ 已停止${NC}"
    fi
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
        1)
            cmd="./gost -L http://${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 HTTP 代理...${NC}"
            ;;
        2)
            cmd="./gost -L socks5://${username}:${password}@:${port}"
            proxy_url="socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 SOCKS5 代理...${NC}"
            ;;
        3)
            cmd="./gost -L ${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port} / socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动自适应代理...${NC}"
            ;;
        4)
            cmd="./gost -L :${port}"
            proxy_url="${ip}:${port} (无加密)"
            echo -e "${GREEN}启动无加密代理...${NC}"
            ;;
    esac
    
    nohup $cmd > "$GOST_LOG" 2>&1 &
    local pid=$!
    sleep 2
    
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}"
        echo -e "${YELLOW}${proxy_url}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}日志: ${GOST_LOG}${NC}"
        return 0
    else
        echo -e "${RED}启动失败，查看: cat ${GOST_LOG}${NC}"
        return 1
    fi
}

# 配置开机自启
enable_autostart() {
    local port=$1
    local protocol=$2
    local username=$3
    local password=$4
    
    local start_cmd=""
    if [ "$protocol" = "4" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L :${port} > gost.log 2>&1 &"
    elif [ "$protocol" = "3" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L ${username}:${password}@:${port} > gost.log 2>&1 &"
    elif [ "$protocol" = "2" ]; then
        start_cmd="cd $GOST_DIR && nohup ./gost -L socks5://${username}:${password}@:${port} > gost.log 2>&1 &"
    else
        start_cmd="cd $GOST_DIR && nohup ./gost -L http://${username}:${password}@:${port} > gost.log 2>&1 &"
    fi
    
    local current_cron=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR" || true)
    (echo "$current_cron"; echo "@reboot $start_cmd") | crontab -
    echo -e "${GREEN}✓ 已配置开机自启${NC}"
}

# 配置代理
configure_proxy() {
    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${RED}请先安装 GOST (选项 1)${NC}"
        return 1
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          配置代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    while true; do
        echo -n -e "${YELLOW}端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}无效${NC}"
    done
    
    echo -e "${BLUE}协议:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应 (推荐)"
    echo -e "  ${GREEN}4${NC}) 无加密"
    echo -n -e "${YELLOW}选择 [1-4] (默认3): ${NC}"
    read -r protocol
    [[ ! "$protocol" =~ ^[1-4]$ ]] && protocol=3
    
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
    
    if start_gost "$port" "$protocol" "$username" "$password"; then
        echo -n -e "${YELLOW}开机自启？[y/N]: ${NC}"
        read -r auto_start
        if [[ "$auto_start" =~ ^[Yy]$ ]]; then
            enable_autostart "$port" "$protocol" "$username" "$password"
        fi
    fi
    
    echo -n -e "${GREEN}按任意键返回...${NC}"
    read -n 1
    echo
}

# 卸载
uninstall_gost() {
    echo -e "${YELLOW}卸载 GOST...${NC}"
    stop_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab - 2>/dev/null || true
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 状态
show_status() {
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$GOST_BIN" ]; then
        echo -e "${GREEN}GOST: 已安装${NC}"
        local version=$("$GOST_BIN" -V 2>/dev/null | head -1 | cut -d' ' -f2 | tr -d '()')
        [ -n "$version" ] && echo -e "${GREEN}版本: ${version}${NC}"
        if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
            local pid=$(pgrep -f "$GOST_BIN" | head -1)
            echo -e "${GREEN}状态: 运行中 (PID: $pid)${NC}"
        else
            echo -e "${RED}状态: 未运行${NC}"
        fi
    else
        echo -e "${RED}GOST: 未安装${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
}

# 主菜单
show_menu() {
    echo
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     GOST Manager for Serv00         ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${GREEN}1${BLUE}) 安装 GOST (官方版/备用)        ║${NC}"
    echo -e "${BLUE}║  ${GREEN}3${BLUE}) 配置代理                      ║${NC}"
    echo -e "${BLUE}║  ${GREEN}4${BLUE}) 查看状态                      ║${NC}"
    echo -e "${BLUE}║  ${GREEN}5${BLUE}) 停止 GOST                     ║${NC}"
    echo -e "${BLUE}║  ${GREEN}6${BLUE}) 卸载 GOST                     ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-6]: ${NC}"
}

# 主程序
main() {
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) 
                if install_gost; then
                    echo -n -e "${GREEN}按任意键配置代理...${NC}"
                    read -n 1
                    configure_proxy
                else
                    echo -n -e "${RED}安装失败，按任意键返回...${NC}"
                    read -n 1
                fi
                ;;
            3) configure_proxy ;;
            4) show_status; echo -n -e "${GREEN}按任意键...${NC}"; read -n 1 ;;
            5) stop_gost; echo -n -e "${GREEN}按任意键...${NC}"; read -n 1 ;;
            6) uninstall_gost; echo -n -e "${GREEN}按任意键...${NC}"; read -n 1 ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main
