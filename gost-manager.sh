#!/usr/bin/env bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SUBFILE="$HOME/sub.txt"

# 获取本机 IP
get_local_ip() {
    local ip=$(ip -4 addr show 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    if [ -z "$ip" ]; then
        ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip="$(hostname)"
    fi
    echo "$ip"
}

# 工作目录设置（自动适配 root/普通用户）
setup_workspace() {
    CURRENT_USER=$(whoami)
    if [[ "$CURRENT_USER" == "root" ]]; then
        if [[ -n "$SUDO_USER" ]]; then
            NORMAL_USER="$SUDO_USER"
        elif [[ -n "$USER" ]] && [[ "$USER" != "root" ]]; then
            NORMAL_USER="$USER"
        else
            NORMAL_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null)
        fi
        if [[ -n "$NORMAL_USER" ]]; then
            WORK_HOME="/home/$NORMAL_USER"
        else
            WORK_HOME="$PWD"
        fi
    else
        WORK_HOME="$HOME"
    fi
    GOST_DIR="$WORK_HOME/GOST"
    mkdir -p "$GOST_DIR" 2>/dev/null || {
        GOST_DIR="/tmp/GOST_${CURRENT_USER}"
        mkdir -p "$GOST_DIR"
    }
    GOST_BIN="$GOST_DIR/gost"
    GOST_LOG="$GOST_DIR/gost.log"
    GOST_PID_FILE="$GOST_DIR/gost.pid"
    echo -e "${GREEN}工作目录: ${GOST_DIR}${NC}"
}
setup_workspace

# 检测系统和架构
detect_os_arch() {
    case "$(uname -s)" in
        Linux)     os="linux" ;;
        FreeBSD)   os="freebsd" ;;
        Darwin)    os="darwin" ;;
        *)         os="linux" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)      cpu_arch="amd64" ;;
        aarch64|arm64)     cpu_arch="arm64" ;;
        armv7l|armv7)      cpu_arch="armv7" ;;
        i686|i386)         cpu_arch="386" ;;
        *)                 cpu_arch="amd64" ;;
    esac
}

# 获取已安装的 GOST 版本（如果存在）
get_installed_gost_version() {
    if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
        local ver=$("$GOST_BIN" -V 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$ver" ]; then
            echo "$ver"
        else
            echo "未知版本"
        fi
    else
        echo "未安装"
    fi
}

# 检查是否存在已安装的 GOST（无论是否运行）
check_existing_gost() {
    local installed_ver=$(get_installed_gost_version)
    if [ "$installed_ver" != "未安装" ]; then
        echo -e "${GREEN}当前已安装版本: ${installed_ver}${NC}"
        if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
            local pid=$(pgrep -f "$GOST_BIN" | head -1)
            echo -e "${YELLOW}检测到运行中的进程 (PID: ${pid})${NC}"
        else
            echo -e "${YELLOW}没有运行中的 GOST 进程${NC}"
        fi
        echo -n -e "${YELLOW}是否覆盖安装新版本？[y/N]: ${NC}"
        read ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
                stop_gost
            fi
            return 0
        else
            echo -e "${RED}取消安装。${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}未检测到已安装的 GOST。${NC}"
        return 0
    fi
}

# 停止 GOST（清理进程和 PID 文件）
stop_gost() {
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}正在停止 GOST 进程...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
        sleep 1
        if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
            echo -e "${RED}强制停止...${NC}"
            pkill -9 -f "$GOST_BIN" 2>/dev/null
        fi
        echo -e "${GREEN}✓ GOST 进程已停止${NC}"
    else
        echo -e "${YELLOW}没有找到运行中的 GOST 进程${NC}"
    fi
    [ -f "$GOST_PID_FILE" ] && rm -f "$GOST_PID_FILE"
}

# 版本比较：是否 >= 2.12（新格式从此版本开始）
version_ge_2_12() {
    local v=$1
    local major=$(echo "$v" | cut -d. -f1)
    local minor=$(echo "$v" | cut -d. -f2)
    if [ "$major" -gt 2 ]; then return 0; fi
    if [ "$major" -lt 2 ]; then return 1; fi
    [ "$minor" -ge 12 ]
}

# 安装 v2（兼容新旧格式）
install_gost_v2() {
    local version=$1
    if ! check_existing_gost; then
        return 1
    fi
    mkdir -p "$GOST_DIR"
    echo -e "${YELLOW}[安装] GOST v2 ${version}...${NC}"
    cd "$GOST_DIR" || return 1
    rm -f gost gost.tar.gz gost.gz

    local downloaded=0
    if version_ge_2_12 "$version"; then
        local tar_url="https://github.com/ginuerzh/gost/releases/download/v${version}/gost_${version}_${os}_${cpu_arch}.tar.gz"
        echo -e "      尝试: ${tar_url}"
        if wget -q --timeout=15 -O gost.tar.gz "$tar_url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$tar_url" -o gost.tar.gz 2>/dev/null; then
            if [ -f "gost.tar.gz" ] && [ -s "gost.tar.gz" ]; then
                tar -xzf gost.tar.gz gost 2>/dev/null || tar -xzf gost.tar.gz 2>/dev/null
                [ -f "gost" ] && downloaded=1
            fi
        fi
    fi

    # 旧格式 .gz（多种备选URL）
    if [ $downloaded -eq 0 ]; then
        echo -e "${YELLOW}      尝试旧格式 .gz...${NC}"
        local gz_urls=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-${os}-${cpu_arch}-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
        )
        if [[ "$os" == "linux" ]]; then
            case "$cpu_arch" in
                amd64)
                    gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz")
                    ;;
                arm64)
                    gz_urls+=(
                        "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz"
                        "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-arm64-${version}.gz"
                    )
                    ;;
                armv7)
                    gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv7-${version}.gz")
                    ;;
                386)
                    gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-386-${version}.gz")
                    ;;
            esac
        elif [[ "$os" == "freebsd" ]]; then
            gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-freebsd-${cpu_arch}-${version}.gz")
        elif [[ "$os" == "darwin" ]]; then
            gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-darwin-${cpu_arch}-${version}.gz")
        fi
        for url in "${gz_urls[@]}"; do
            echo -e "      尝试: ${url}"
            if wget -q --timeout=15 -O gost.gz "$url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$url" -o gost.gz 2>/dev/null; then
                if [ -f "gost.gz" ] && [ -s "gost.gz" ] && gunzip -t gost.gz 2>/dev/null; then
                    gunzip -f gost.gz
                    downloaded=1
                    echo -e "${GREEN}      下载成功${NC}"
                    break
                fi
            fi
        done
    fi

    if [ $downloaded -eq 0 ]; then
        echo -e "${RED}下载失败，安装终止。${NC}"
        echo -n -e "${GREEN}按任意键退出...${NC}"
        read -n 1
        exit 1
    fi

    chmod +x gost
    if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
        echo -e "${GREEN}✓ 安装成功${NC}"
        "$GOST_BIN" -V 2>&1 | head -1
        return 0
    else
        echo -e "${RED}安装失败，请手动检查。${NC}"
        echo -n -e "${GREEN}按任意键退出...${NC}"
        read -n 1
        exit 1
    fi
}

# 安装 v3
install_gost_v3() {
    local version=$1
    if ! check_existing_gost; then
        return 1
    fi
    mkdir -p "$GOST_DIR"
    echo -e "${YELLOW}[安装] GOST v3 ${version}...${NC}"
    cd "$GOST_DIR" || return 1
    rm -f gost gost.tar.gz
    local clean_version="${version#v}"
    local download_url="https://github.com/go-gost/gost/releases/download/${version}/gost_${clean_version}_${os}_${cpu_arch}.tar.gz"
    echo -e "      下载: ${download_url}"
    if wget -q --timeout=15 -O gost.tar.gz "$download_url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$download_url" -o gost.tar.gz 2>/dev/null; then
        tar -xzf gost.tar.gz gost 2>/dev/null || tar -xzf gost.tar.gz
        chmod +x gost
        rm -f gost.tar.gz
        if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
            echo -e "${GREEN}✓ 安装成功${NC}"
            return 0
        fi
    fi
    echo -e "${RED}下载失败，安装终止。${NC}"
    echo -n -e "${GREEN}按任意键退出...${NC}"
    read -n 1
    exit 1
}

# 获取 v2 版本列表（默认选择第一个）
get_v2_versions() {
    echo -e "${BLUE}获取 GOST v2 版本列表...${NC}"
    local versions=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ginuerzh/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -10)
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}无法获取远程列表，使用本地列表${NC}"
        versions="2.12.0 2.11.5 2.11.4 2.11.3 2.11.2 2.11.1 2.11.0 2.10.0 2.9.2"
    fi
    local version_array=($versions)
    local version_count=${#version_array[@]}
    echo -e "${GREEN}可用的 GOST v2 版本:${NC}"
    for i in "${!version_array[@]}"; do
        echo "  $((i+1))) ${version_array[$i]}"
    done
    echo "  $((version_count+1))) 返回上级"
    echo -n -e "${YELLOW}请输入版本数字 (默认 1): ${NC}"
    read choice
    if [[ -z "$choice" ]]; then
        choice=1
    fi
    if [[ "$choice" -eq $((version_count+1)) ]]; then
        return 1
    elif [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$version_count" ]]; then
        local selected_version="${version_array[$((choice-1))]}"
        install_gost_v2 "$selected_version"
        return $?
    else
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
}

# 获取 v3 版本列表（过滤预发布版本，默认选择第一个稳定版）
get_v3_versions() {
    echo -e "${BLUE}获取 GOST v3 版本列表...${NC}"
    local all_versions=$(curl -s "https://api.github.com/repos/go-gost/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"(v[^"]+)".*/\1/')
    local versions=""
    if [[ -z "$all_versions" ]]; then
        versions="v3.2.6 v3.2.5 v3.2.4 v3.2.3 v3.2.2 v3.2.1 v3.2.0"
    else
        versions=$(echo "$all_versions" | grep -viE 'nightly|rc|alpha|beta' | head -10)
    fi
    
    local version_array=($versions)
    local version_count=${#version_array[@]}
    
    if [ $version_count -eq 0 ]; then
        echo -e "${RED}未找到稳定版本，使用备用列表${NC}"
        version_array=(v3.2.6 v3.2.5 v3.2.4 v3.2.3 v3.2.2)
        version_count=${#version_array[@]}
    fi
    
    echo -e "${GREEN}可用的 GOST v3 稳定版本:${NC}"
    for i in "${!version_array[@]}"; do
        echo "  $((i+1))) ${version_array[$i]}"
    done
    echo "  $((version_count+1))) 返回上级"
    
    echo -n -e "${YELLOW}请输入版本数字 (默认 1): ${NC}"
    read choice
    if [[ -z "$choice" ]]; then
        choice=1
    fi
    
    if [[ "$choice" -eq $((version_count+1)) ]]; then
        return 1
    elif [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$version_count" ]]; then
        local selected_version="${version_array[$((choice-1))]}"
        install_gost_v3 "$selected_version"
        return $?
    else
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
}

# 选择版本
select_version_to_install() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       选择 GOST 版本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  ${GREEN}1${NC}) GOST v2"
    echo -e "  ${GREEN}2${NC}) GOST v3"
    echo -e "  ${GREEN}0${NC}) 返回"
    echo -e "${BLUE}========================================${NC}"
    echo -n -e "${YELLOW}请选择 [0-2]: ${NC}"
    read choice
    case $choice in
        1) get_v2_versions ;;
        2) get_v3_versions ;;
        0) return 1 ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
}

# 保存节点信息到文件
save_node_info() {
    local info="$1"
    echo "$info" > "$SUBFILE"
    echo -e "${GREEN}节点信息已保存到: ${SUBFILE}${NC}"
}

# 通用启动函数（使用 eval 确保参数正确）
start_gost_generic() {
    local cmd="$1"
    local info="$2"
    cd "$GOST_DIR" || return 1
    stop_gost
    echo -e "${GREEN}启动代理...${NC}"
    eval "nohup $cmd > \"$GOST_LOG\" 2>&1 &"
    local pid=$!
    echo $pid > "$GOST_PID_FILE"
    sleep 2
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 代理运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理信息:${NC}"
        echo -e "${YELLOW}${info}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        save_node_info "$info"
        return 0
    else
        echo -e "${RED}启动失败，请检查日志: ${GOST_LOG}${NC}"
        return 1
    fi
}

# WebSocket 配置函数（仅 ws，无认证）
configure_websocket() {
    local port
    while true; do
        echo -n -e "${YELLOW}请输入监听端口: ${NC}"
        read port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口无效${NC}"
        fi
    done
    echo -n -e "${YELLOW}请输入 WebSocket 路径 (默认 /ws): ${NC}"
    read path
    [ -z "$path" ] && path="/ws"
    local scheme="ws"
    local listen_addr=":${port}"
    local cmd="$GOST_BIN -L ${scheme}://${listen_addr}?path=${path}"
    local ip=$(get_local_ip)
    local info="WebSocket 代理: ws://${ip}:${port}${path} (无认证)"
    start_gost_generic "$cmd" "$info"
}

# SSH 端口转发配置函数（新增）
configure_ssh() {
    echo -e "${BLUE}--- SSH 端口转发配置 ---${NC}"
    local ssh_host
    echo -n -e "${YELLOW}请输入 SSH 服务器地址: ${NC}"
    read ssh_host
    if [ -z "$ssh_host" ]; then
        echo -e "${RED}SSH 地址不能为空${NC}"
        return 1
    fi
    local ssh_port
    echo -n -e "${YELLOW}请输入 SSH 端口 (默认 22): ${NC}"
    read ssh_port
    [ -z "$ssh_port" ] && ssh_port="22"
    local ssh_user
    echo -n -e "${YELLOW}请输入 SSH 用户名: ${NC}"
    read ssh_user
    if [ -z "$ssh_user" ]; then
        echo -e "${RED}SSH 用户名不能为空${NC}"
        return 1
    fi
    echo -e "${YELLOW}SSH 认证方式:${NC}"
    echo -e "  ${GREEN}1${NC}) 密码认证"
    echo -e "  ${GREEN}2${NC}) 密钥认证 (需已配置密钥，无需密码)"
    echo -n -e "${YELLOW}请输入 [1-2] (默认 1): ${NC}"
    read auth_type
    if [[ -z "$auth_type" ]]; then
        auth_type=1
    fi
    local remote_auth_part=""
    if [[ "$auth_type" == "1" ]]; then
        echo -n -e "${YELLOW}请输入 SSH 密码: ${NC}"
        read -s ssh_pass
        echo
        if [ -z "$ssh_pass" ]; then
            echo -e "${RED}密码不能为空${NC}"
            return 1
        fi
        remote_auth_part="${ssh_user}:${ssh_pass}@${ssh_host}:${ssh_port}"
    else
        remote_auth_part="${ssh_user}@${ssh_host}:${ssh_port}"
    fi
    local remote_url="ssh://${remote_auth_part}"
    echo "$remote_url"
    # 返回远程 URL
    echo "$remote_url"
}

# 链式代理配置函数（本地代理可选认证，远程支持 WS/WSS 和 SSH）
configure_chain() {
    echo -e "${BLUE}请选择本地代理类型:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read local_type
    local local_proto=""
    case $local_type in
        1) local_proto="http" ;;
        2) local_proto="socks5" ;;
        *) echo -e "${RED}无效选择，使用 HTTP${NC}"; local_proto="http" ;;
    esac
    local local_port
    while true; do
        echo -n -e "${YELLOW}请输入本地监听端口: ${NC}"
        read local_port
        if [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口无效${NC}"
        fi
    done
    # 本地认证选项
    echo -n -e "${YELLOW}本地代理是否需要认证？[y/N]: ${NC}"
    read local_auth
    local local_user=""
    local local_pass=""
    if [[ "$local_auth" =~ ^[Yy]$ ]]; then
        echo -n -e "${YELLOW}本地用户名 (默认 admin): ${NC}"
        read local_user
        [ -z "$local_user" ] && local_user="admin"
        echo -n -e "${YELLOW}本地密码 (默认 123456): ${NC}"
        read local_pass
        [ -z "$local_pass" ] && local_pass="123456"
    fi

    echo -e "${BLUE}请选择远程转发模式:${NC}"
    echo -e "  ${GREEN}1${NC}) WebSocket (ws/wss)"
    echo -e "  ${GREEN}2${NC}) SSH 端口转发"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read remote_mode
    if [[ -z "$remote_mode" ]]; then
        remote_mode=1
    fi

    local remote_url=""
    if [[ "$remote_mode" == "1" ]]; then
        echo -e "${YELLOW}请输入远程 WebSocket 地址:${NC}"
        echo -e "  格式: ws://host:port/path 或 wss://host:port/path (无认证)"
        echo -n -e "${YELLOW}远程地址: ${NC}"
        read remote_url
        if [[ -z "$remote_url" ]]; then
            echo -e "${RED}远程地址不能为空${NC}"
            return 1
        fi
    else
        remote_url=$(configure_ssh)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi

    # 构建本地监听参数
    local local_listen=""
    if [ -n "$local_user" ]; then
        local_listen="-L ${local_proto}://${local_user}:${local_pass}@:${local_port}"
    else
        local_listen="-L ${local_proto}://:${local_port}"
    fi

    # 远程转发
    local cmd="$GOST_BIN $local_listen -F $remote_url"
    local info="链式代理: 本地 ${local_proto}://"
    if [ -n "$local_user" ]; then
        info+="${local_user}:${local_pass}@"
    fi
    info+=":${local_port} -> 远程 ${remote_url}"
    start_gost_generic "$cmd" "$info"
}

# 原有协议启动函数（HTTP/SOCKS5/自适应/Shadowsocks）
start_gost_legacy() {
    local protocol=$1
    local port=$2
    local auth1=$3
    local auth2=$4
    local name=$5
    cd "$GOST_DIR" || return 1
    stop_gost
    local cmd=""
    local proxy_url=""
    local ip=$(get_local_ip)
    case $protocol in
        1)
            cmd="$GOST_BIN -L http://${auth1}:${auth2}@:${port}"
            proxy_url="http://${auth1}:${auth2}@${ip}:${port}"
            echo -e "${GREEN}启动 HTTP 代理...${NC}"
            save_node_info "$proxy_url"
            ;;
        2)
            cmd="$GOST_BIN -L socks5://${auth1}:${auth2}@:${port}"
            proxy_url="socks5://${auth1}:${auth2}@${ip}:${port}"
            echo -e "${GREEN}启动 SOCKS5 代理...${NC}"
            save_node_info "$proxy_url"
            ;;
        3)
            cmd="$GOST_BIN -L ${auth1}:${auth2}@:${port}"
            proxy_url="http://${auth1}:${auth2}@${ip}:${port} / socks5://${auth1}:${auth2}@${ip}:${port}"
            echo -e "${GREEN}启动自适应代理...${NC}"
            save_node_info "$proxy_url"
            ;;
        4)
            cmd="$GOST_BIN -L ss://${auth1}:${auth2}@:${port}"
            ss_link="${auth1}:${auth2}@${ip}:${port}"
            if command -v base64 >/dev/null 2>&1; then
                ss_base64=$(echo -n "$ss_link" | base64 -w 0 2>/dev/null || echo -n "$ss_link" | base64)
            else
                ss_base64=$(echo -n "$ss_link" | openssl base64 -A 2>/dev/null)
            fi
            if [ -n "$name" ]; then
                proxy_url="ss://${auth1}:${auth2}@${ip}:${port}#${name}"
                proxy_url_extra="ss://${ss_base64}#${name}"
            else
                proxy_url="ss://${auth1}:${auth2}@${ip}:${port}"
                proxy_url_extra="ss://${ss_base64}"
            fi
            echo -e "${GREEN}启动 Shadowsocks 代理...${NC}"
            save_node_info "${proxy_url}\nBase64: ${proxy_url_extra}"
            ;;
    esac
    nohup $cmd > "$GOST_LOG" 2>&1 &
    local pid=$!
    echo $pid > "$GOST_PID_FILE"
    sleep 2
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 代理运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}"
        echo -e "${YELLOW}${proxy_url}${NC}"
        if [ -n "$proxy_url_extra" ]; then
            echo -e "${GREEN}Base64 编码 (用于 v2ray 等):${NC}"
            echo -e "${YELLOW}${proxy_url_extra}${NC}"
        fi
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        echo -e "${RED}启动失败，请检查日志: ${GOST_LOG}${NC}"
        return 1
    fi
}

# 配置代理主入口
configure_proxy() {
    local skip_confirm=$1
    if [ ! -f "$GOST_BIN" ] || [ ! -x "$GOST_BIN" ]; then
        echo -e "${RED}未检测到 GOST，请先安装。${NC}"
        echo -n -e "${YELLOW}是否现在安装？[y/N]: ${NC}"
        read ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if select_version_to_install; then
                if [ -f "$GOST_BIN" ]; then
                    echo -e "${GREEN}安装完成，继续配置代理。${NC}"
                else
                    echo -e "${RED}安装失败，无法配置代理。${NC}"
                    echo -n -e "${GREEN}按任意键返回...${NC}"
                    read -n 1
                    return 1
                fi
            else
                echo -e "${RED}安装取消。${NC}"
                echo -n -e "${GREEN}按任意键返回...${NC}"
                read -n 1
                return 1
            fi
        else
            echo -e "${RED}配置取消。${NC}"
            echo -n -e "${GREEN}按任意键返回...${NC}"
            read -n 1
            return 1
        fi
    fi

    if [ "$skip_confirm" != "auto" ]; then
        local installed_ver=$(get_installed_gost_version)
        echo -e "${GREEN}当前已安装版本: ${installed_ver}${NC}"
        if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
            local pid=$(pgrep -f "$GOST_BIN" | head -1)
            echo -e "${YELLOW}当前有运行中的进程 (PID: ${pid})，更改配置会先停止进程。${NC}"
        fi
        echo -n -e "${YELLOW}是否重新配置代理？[y/N]: ${NC}"
        read ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            echo -e "${RED}配置取消。${NC}"
            echo -n -e "${GREEN}按任意键返回...${NC}"
            read -n 1
            return 1
        fi
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          配置代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}请选择代理类型:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应 (HTTP/SOCKS5 自动识别)"
    echo -e "  ${GREEN}4${NC}) Shadowsocks"
    echo -e "  ${GREEN}5${NC}) WebSocket (ws)"
    echo -e "  ${GREEN}6${NC}) 链式代理 (本地 HTTP/SOCKS5 -> 远程 WS/WSS/SSH)"
    echo -n -e "${YELLOW}请输入 [1-6]: ${NC}"
    read protocol
    [[ ! "$protocol" =~ ^[1-6]$ ]] && protocol=3

    case $protocol in
        1|2|3|4)
            # 原有协议配置
            while true; do
                echo -n -e "${YELLOW}请输入端口: ${NC}"
                read port
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    break
                else
                    echo -e "${RED}端口无效${NC}"
                fi
            done
            local username="admin"
            local password="123456"
            local method="aes-256-gcm"
            local node_name=""
            if [ "$protocol" -eq 4 ]; then
                echo -e "${BLUE}Shadowsocks 配置${NC}"
                local gost_ver=$(get_gost_version)
                local ss_methods=()
                local ss_method_names=()
                if version_ge "$gost_ver" "2.8.0"; then
                    if version_ge "$gost_ver" "3.1.0"; then
                        ss_methods=("aes-256-gcm" "aes-128-gcm" "chacha20-ietf-poly1305")
                        ss_method_names=("aes-256-gcm (推荐)" "aes-128-gcm" "chacha20-ietf-poly1305 (推荐)")
                        echo -e "${GREEN}✅ 当前版本支持 AEAD 加密 (推荐)${NC}"
                    else
                        ss_methods=("aes-256-gcm" "aes-128-gcm" "chacha20-ietf-poly1305" "aes-256-cfb" "chacha20-ietf" "rc4-md5")
                        ss_method_names=("aes-256-gcm (推荐AEAD)" "aes-128-gcm (AEAD)" "chacha20-ietf-poly1305 (推荐AEAD)" "aes-256-cfb (传统)" "chacha20-ietf (传统)" "rc4-md5 (传统)")
                        echo -e "${GREEN}✅ 当前版本支持所有加密方式 (AEAD + 传统流加密)${NC}"
                    fi
                else
                    echo -e "${RED}❌ 当前版本低于 2.8.0，不支持 Shadowsocks 协议。请升级到 v2.8+。${NC}"
                    echo -n -e "${GREEN}按任意键返回...${NC}"
                    read -n 1
                    return 1
                fi
                echo -e "${YELLOW}请选择加密方式:${NC}"
                for i in "${!ss_method_names[@]}"; do
                    echo "  $((i+1))) ${ss_method_names[$i]}"
                done
                echo -n -e "${YELLOW}请输入 [1-${#ss_method_names[@]}] (默认 1): ${NC}"
                read method_choice
                if [[ -z "$method_choice" ]]; then
                    method_choice=1
                fi
                if [[ "$method_choice" -ge 1 ]] && [[ "$method_choice" -le ${#ss_methods[@]} ]]; then
                    method="${ss_methods[$((method_choice-1))]}"
                else
                    echo -e "${RED}无效选择，使用默认 aes-256-gcm${NC}"
                    method="aes-256-gcm"
                fi
                echo -e "${GREEN}已选择加密方式: ${method}${NC}"
                echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"
                read input_pass
                [ -n "$input_pass" ] && password="$input_pass"
                echo -n -e "${YELLOW}节点名称 (默认 GOST-SS): ${NC}"
                read input_name
                [ -n "$input_name" ] && node_name="$input_name" || node_name="GOST-SS"
                start_gost_legacy "$protocol" "$port" "$method" "$password" "$node_name"
            else
                echo -e "${BLUE}账号密码 (默认 admin/123456)${NC}"
                echo -n -e "${YELLOW}账号 [admin]: ${NC}"
                read input_user
                [ -n "$input_user" ] && username="$input_user"
                echo -n -e "${YELLOW}密码 [123456]: ${NC}"
                read input_pass
                [ -n "$input_pass" ] && password="$input_pass"
                start_gost_legacy "$protocol" "$port" "$username" "$password"
            fi
            ;;
        5)
            configure_websocket
            ;;
        6)
            configure_chain
            ;;
    esac

    echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
    read auto_start
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        enable_autostart
    fi
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
}

# 开启自启
enable_autostart() {
    local current_cron=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR/gost")
    cat > "$GOST_DIR/keepalive.sh" << EOF
#!/usr/bin/env bash
GOST_DIR="$GOST_DIR"
cd "\$GOST_DIR"
if [ -f "gost.pid" ] && kill -0 "\$(cat gost.pid)" 2>/dev/null; then
    exit 0
fi
if ! pgrep -f "\$GOST_DIR/gost" > /dev/null; then
    if [ -f "start_cmd.txt" ]; then
        cmd=\$(cat start_cmd.txt)
        eval "nohup \$cmd > gost.log 2>&1 &"
        echo \$! > gost.pid
    fi
fi
EOF
    chmod +x "$GOST_DIR/keepalive.sh"
    local running_cmd=$(ps -ef | grep "$GOST_BIN" | grep -v grep | head -1 | sed 's/.*\.\/gost/\.\/gost/')
    if [ -n "$running_cmd" ]; then
        echo "$running_cmd" > "$GOST_DIR/start_cmd.txt"
    fi
    (echo "$current_cron"; echo "@reboot $GOST_DIR/keepalive.sh"; echo "*/5 * * * * $GOST_DIR/keepalive.sh") | crontab -
    echo -e "${GREEN}✓ 已配置开机自启和进程保活${NC}"
}

# 卸载
uninstall_gost() {
    echo -e "${YELLOW}正在卸载 GOST...${NC}"
    stop_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab -
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 获取 GOST 版本号（用于兼容性检查）
get_gost_version() {
    if [ ! -f "$GOST_BIN" ]; then
        echo "0.0.0"
        return
    fi
    local ver=$("$GOST_BIN" -V 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$ver" ]; then
        echo "0.0.0"
    else
        echo "$ver"
    fi
}

# 版本比较函数
version_ge() {
    local v1=$1
    local v2=$2
    [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" != "$v1" ]
}

# 显示状态
show_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          系统状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    local local_ip=$(get_local_ip)
    echo -e "${GREEN}本机 IP: ${YELLOW}${local_ip}${NC}"
    if [ -f "$GOST_BIN" ]; then
        local version_info=$("$GOST_BIN" -V 2>&1 | head -1)
        echo -e "${GREEN}GOST 状态: 已安装${NC}"
        echo -e "${GREEN}版本信息: ${version_info}${NC}"
        echo -e "${GREEN}安装路径: ${GOST_BIN}${NC}"
        if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
            echo -e "${GREEN}代理状态: 运行中 ✓${NC}"
            local pid=$(pgrep -f "$GOST_BIN" | head -1)
            echo -e "${GREEN}进程 PID: ${pid}${NC}"
        else
            echo -e "${RED}代理状态: 未运行 ✗${NC}"
        fi
    else
        echo -e "${RED}GOST 状态: 未安装${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
}

# 查看节点信息
show_sub() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          节点信息${NC}"
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$SUBFILE" ] && [ -s "$SUBFILE" ]; then
        echo -e "${YELLOW}$(cat "$SUBFILE")${NC}"
    else
        echo -e "${RED}暂无节点信息，请先配置代理。${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
}

# 更新脚本
update_script() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          更新脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    local script_url="https://raw.githubusercontent.com/goyo123321a/gost-manager/refs/heads/main/gost-manager.sh"
    local temp_script="/tmp/gost-manager-update.sh"
    echo -e "${YELLOW}正在从远程仓库下载最新脚本...${NC}"
    
    if wget -q --timeout=30 --tries=2 -O "$temp_script" "$script_url" 2>/dev/null || \
       curl -fsSL --connect-timeout 30 --retry 2 "$script_url" -o "$temp_script" 2>/dev/null; then
        if [ -s "$temp_script" ]; then
            cp "$temp_script" "$0"
            chmod +x "$0"
            rm -f "$temp_script"
            echo -e "${GREEN}✓ 脚本更新成功！${NC}"
            echo -e "${YELLOW}请重新运行脚本以使用新版本。${NC}"
            echo -e "${YELLOW}快速命令: ${GREEN}~/gost-manager.sh${NC} 或 ${GREEN}bash ~/gost-manager.sh${NC}"
            echo -n -e "${GREEN}按任意键退出...${NC}"
            read -n 1
            exit 0
        else
            echo -e "${RED}下载的文件为空，更新失败${NC}"
        fi
    else
        echo -e "${RED}自动下载失败，可能是网络问题。${NC}"
        echo -e "${YELLOW}请手动执行以下命令更新脚本：${NC}"
        echo -e "${GREEN}curl -fsSL ${script_url} -o ~/gost-manager.sh && chmod +x ~/gost-manager.sh${NC}"
        echo -e "${YELLOW}然后重新运行 ~/gost-manager.sh${NC}"
        echo -n -e "${GREEN}按任意键退出...${NC}"
        read -n 1
        exit 1
    fi
    echo -n -e "${GREEN}按任意键退出...${NC}"
    read -n 1
    exit 1
}

# 主菜单
show_menu() {
    echo
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        GOST 一键管理脚本            ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${GREEN}1${BLUE}) 安装 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}2${BLUE}) 配置代理                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}3${BLUE}) 查看状态                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}4${BLUE}) 卸载 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}5${BLUE}) 更新脚本                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}6${BLUE}) 查看节点信息                   ║${NC}"
    echo -e "${BLUE}║  ${GREEN}7${BLUE}) 停止 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-7]: ${NC}"
}

# 主程序
main() {
    detect_os_arch
    while true; do
        show_menu
        read choice
        case $choice in
            1) if select_version_to_install; then
                   if [ -f "$GOST_BIN" ]; then
                       echo
                       echo -n -e "${GREEN}是否配置代理？[Y/n]: ${NC}"
                       read config_now
                       if [[ -z "$config_now" ]] || [[ "$config_now" =~ ^[Yy]$ ]]; then
                           configure_proxy "auto"
                       fi
                   fi
               fi ;;
            2) configure_proxy ;;
            3) show_status ;;
            4) uninstall_gost; echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1 ;;
            5) update_script ;;
            6) show_sub ;;
            7) stop_gost; echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1 ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main
