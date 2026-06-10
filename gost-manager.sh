#!/usr/bin/env bash

# ============================================
# GOST 一键管理脚本（修复版）
# 支持单进程多服务 / 多进程，含开机自启、安全加固
# ============================================

# 错误时退出并显示行号
set -euo pipefail
trap 'echo "错误发生在第 $LINENO 行，命令: $BASH_COMMAND"' ERR

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
SUBFILE="$HOME/sub.txt"
GOST_DIR=""
GOST_BIN=""
GOST_LOG=""
GOST_PID_FILE=""
START_CMD_FILE=""
PID_DIR=""

# ========== 安全函数：转义参数供 eval 使用 ==========
quote() {
    printf '%s\n' "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

# ========== 基础函数 ==========
get_local_ip() {
    local ip
    ip=$(ip -4 addr show 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    if [ -z "$ip" ]; then
        ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip="$(hostname)"
    fi
    echo "$ip"
}

setup_workspace() {
    local CURRENT_USER WORK_HOME NORMAL_USER
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
    START_CMD_FILE="$GOST_DIR/start_cmd.txt"
    PID_DIR="$GOST_DIR/pids"
    mkdir -p "$PID_DIR"
    echo -e "${GREEN}工作目录: ${GOST_DIR}${NC}"
}
setup_workspace

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

get_installed_gost_version() {
    if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
        local ver
        ver=$("$GOST_BIN" -V 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "${ver:-未知版本}"
    else
        echo "未安装"
    fi
}

# ========== 安装函数（保持不变，仅添加停止旧进程的提示） ==========
version_ge_2_12() {
    local v=$1
    local major=$(echo "$v" | cut -d. -f1)
    local minor=$(echo "$v" | cut -d. -f2)
    if [ "$major" -gt 2 ]; then return 0; fi
    if [ "$major" -lt 2 ]; then return 1; fi
    [ "$minor" -ge 12 ]
}

install_gost_v2() {
    local version=$1
    # 安装前询问是否停止现有进程
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}检测到运行的 GOST 进程，是否停止后再安装？[y/N]${NC}"
        read -r stop_ans
        if [[ "$stop_ans" =~ ^[Yy]$ ]]; then
            stop_all_gost
        fi
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
    if [ $downloaded -eq 0 ]; then
        local gz_urls=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-${os}-${cpu_arch}-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
        )
        if [[ "$os" == "linux" ]]; then
            case "$cpu_arch" in
                amd64) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz") ;;
                arm64) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz") ;;
                armv7) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv7-${version}.gz") ;;
                386)   gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-386-${version}.gz") ;;
            esac
        elif [[ "$os" == "freebsd" ]]; then
            gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-freebsd-${cpu_arch}-${version}.gz")
        elif [[ "$os" == "darwin" ]]; then
            gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-darwin-${cpu_arch}-${version}.gz")
        fi
        for url in "${gz_urls[@]}"; do
            if wget -q --timeout=15 -O gost.gz "$url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$url" -o gost.gz 2>/dev/null; then
                if [ -f "gost.gz" ] && [ -s "gost.gz" ] && gunzip -t gost.gz 2>/dev/null; then
                    gunzip -f gost.gz
                    downloaded=1
                    break
                fi
            fi
        done
    fi
    if [ $downloaded -eq 0 ]; then
        echo -e "${RED}下载失败${NC}"
        return 1
    fi
    chmod +x gost
    if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
        echo -e "${GREEN}✓ 安装成功${NC}"
        "$GOST_BIN" -V 2>&1 | head -1
        return 0
    else
        echo -e "${RED}安装失败${NC}"
        return 1
    fi
}

install_gost_v3() {
    local version=$1
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}检测到运行的 GOST 进程，是否停止后再安装？[y/N]${NC}"
        read -r stop_ans
        if [[ "$stop_ans" =~ ^[Yy]$ ]]; then
            stop_all_gost
        fi
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
    echo -e "${RED}安装失败${NC}"
    return 1
}

get_v2_versions() {
    local versions
    versions=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ginuerzh/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -10)
    if [[ -z "$versions" ]]; then
        versions="2.12.0 2.11.5 2.11.4 2.11.3 2.11.2 2.11.1 2.11.0 2.10.0 2.9.2"
    fi
    echo "$versions"
}

get_v3_versions() {
    local all_versions
    all_versions=$(curl -s "https://api.github.com/repos/go-gost/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"(v[^"]+)".*/\1/')
    if [[ -z "$all_versions" ]]; then
        all_versions="v3.2.6 v3.2.5 v3.2.4 v3.2.3 v3.2.2"
    else
        all_versions=$(echo "$all_versions" | grep -viE 'nightly|rc|alpha|beta' | head -10)
    fi
    echo "$all_versions"
}

select_version_to_install() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       选择 GOST 版本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  ${GREEN}1${NC}) GOST v2"
    echo -e "  ${GREEN}2${NC}) GOST v3"
    echo -e "  ${GREEN}0${NC}) 返回"
    echo -n -e "${YELLOW}请选择 [0-2]: ${NC}"
    read -r choice
    case $choice in
        1)
            local versions
            versions=$(get_v2_versions)
            local ver_array=($versions)
            echo -e "${GREEN}可用的 GOST v2 版本:${NC}"
            for i in "${!ver_array[@]}"; do echo "  $((i+1))) ${ver_array[$i]}"; done
            echo -n -e "${YELLOW}请输入版本数字 (默认 1): ${NC}"
            read -r v_choice
            [[ -z "$v_choice" ]] && v_choice=1
            if [[ "$v_choice" =~ ^[0-9]+$ ]] && [ "$v_choice" -ge 1 ] && [ "$v_choice" -le ${#ver_array[@]} ]; then
                install_gost_v2 "${ver_array[$((v_choice-1))]}"
                return $?
            fi
            ;;
        2)
            local versions
            versions=$(get_v3_versions)
            local ver_array=($versions)
            echo -e "${GREEN}可用的 GOST v3 版本:${NC}"
            for i in "${!ver_array[@]}"; do echo "  $((i+1))) ${ver_array[$i]}"; done
            echo -n -e "${YELLOW}请输入版本数字 (默认 1): ${NC}"
            read -r v_choice
            [[ -z "$v_choice" ]] && v_choice=1
            if [[ "$v_choice" =~ ^[0-9]+$ ]] && [ "$v_choice" -ge 1 ] && [ "$v_choice" -le ${#ver_array[@]} ]; then
                install_gost_v3 "${ver_array[$((v_choice-1))]}"
                return $?
            fi
            ;;
        0) return 1 ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
    return 1
}

# ========== 服务管理核心 ==========
stop_all_gost() {
    echo -e "${YELLOW}停止所有 GOST 进程...${NC}"
    pkill -f "$GOST_BIN" 2>/dev/null || true
    rm -f "$GOST_PID_FILE"
    rm -f "$PID_DIR"/*.pid
    echo -e "${GREEN}已停止所有 GOST 进程${NC}"
}

stop_single_gost() {
    if [ -f "$GOST_PID_FILE" ] && kill -0 "$(cat "$GOST_PID_FILE")" 2>/dev/null; then
        kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
        rm -f "$GOST_PID_FILE"
        echo -e "${GREEN}单进程已停止${NC}"
    else
        echo -e "${YELLOW}单进程未运行${NC}"
    fi
}

restart_gost_single() {
    if [ -f "$START_CMD_FILE" ] && [ -s "$START_CMD_FILE" ]; then
        local full_cmd
        full_cmd=$(cat "$START_CMD_FILE")
        stop_single_gost   # 仅停止单进程，不影响独立进程
        cd "$GOST_DIR"
        eval "nohup $full_cmd > \"$GOST_LOG\" 2>&1 &"
        local pid=$!
        echo $pid > "$GOST_PID_FILE"
        echo -e "${GREEN}单进程模式已启动，PID: $pid${NC}"
        return 0
    else
        echo -e "${RED}没有找到启动命令，请先配置代理或添加服务。${NC}"
        return 1
    fi
}

start_gost_independent() {
    local cmd="$1"
    local description="$2"
    cd "$GOST_DIR"
    local timestamp
    timestamp=$(date +%s%N 2>/dev/null || date +%s)$RANDOM
    local pidfile="$PID_DIR/service_${timestamp}.pid"
    local infofile="${pidfile%.pid}.info"
    eval "nohup $cmd > \"$GOST_LOG\" 2>&1 &"
    local pid=$!
    echo $pid > "$pidfile"
    echo "$description" > "$infofile"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${GREEN}独立进程已启动，PID: $pid${NC}"
        echo -e "${GREEN}服务描述: $description${NC}"
        return 0
    else
        echo -e "${RED}启动失败，请检查日志${NC}"
        rm -f "$pidfile" "$infofile"
        return 1
    fi
}

# 保存节点信息（追加模式）
append_node_info() {
    local info="$1"
    {
        echo "--- $(date) ---"
        echo "$info"
        echo ""
    } >> "$SUBFILE"
    echo -e "${GREEN}节点信息已追加到: ${SUBFILE}${NC}"
}

# 替换时保存节点信息（覆盖，但保留历史）
replace_node_info() {
    local info="$1"
    {
        echo "=== $(date) 替换配置 ==="
        echo "$info"
        echo ""
    } > "$SUBFILE" 2>/dev/null || true
    echo -e "${GREEN}节点信息已保存到: ${SUBFILE}${NC}"
}

# ========== 安全参数收集函数（使用 printf %q 转义） ==========
collect_http_params() {
    local port user pass
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    echo -n -e "${YELLOW}用户名 (默认 admin): ${NC}"
    read -r user; user=${user:-admin}
    echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"
    read -r pass; pass=${pass:-123456}
    local ip
    ip=$(get_local_ip)
    local cmd="-L http://${user}:${pass}@:${port}"
    local desc="HTTP 代理: http://${user}:${pass}@${ip}:${port}"
    echo "$cmd|||$desc"
}

collect_socks5_params() {
    local port user pass
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    echo -n -e "${YELLOW}用户名 (默认 admin): ${NC}"
    read -r user; user=${user:-admin}
    echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"
    read -r pass; pass=${pass:-123456}
    local ip
    ip=$(get_local_ip)
    local cmd="-L socks5://${user}:${pass}@:${port}"
    local desc="SOCKS5 代理: socks5://${user}:${pass}@${ip}:${port}"
    echo "$cmd|||$desc"
}

collect_adapt_params() {
    local port user pass
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    echo -n -e "${YELLOW}用户名 (默认 admin): ${NC}"
    read -r user; user=${user:-admin}
    echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"
    read -r pass; pass=${pass:-123456}
    local ip
    ip=$(get_local_ip)
    local cmd="-L ${user}:${pass}@:${port}"
    local desc="自适应代理: http://${user}:${pass}@${ip}:${port} / socks5://${user}:${pass}@${ip}:${port}"
    echo "$cmd|||$desc"
}

collect_ss_params() {
    local port method pass name
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    echo -n -e "${YELLOW}加密方式 (默认 aes-256-gcm): ${NC}"
    read -r method; method=${method:-aes-256-gcm}
    echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"
    read -r pass; pass=${pass:-123456}
    echo -n -e "${YELLOW}节点名称 (可选): ${NC}"
    read -r name
    local ip
    ip=$(get_local_ip)
    local cmd="-L ss://${method}:${pass}@:${port}"
    local desc="Shadowsocks 代理: ss://${method}:${pass}@${ip}:${port}"
    [ -n "$name" ] && desc="${desc}#${name}"
    echo "$cmd|||$desc"
}

collect_ws_params() {
    local port path
    while true; do
        echo -n -e "${YELLOW}请输入监听端口: ${NC}"
        read -r port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    echo -n -e "${YELLOW}WebSocket 路径 (默认 /ws): ${NC}"
    read -r path; path=${path:-/ws}
    local ip
    ip=$(get_local_ip)
    # 注意：路径不需要额外转义，GOST 接受原始字符串
    local cmd="-L ws://:${port}?path=${path}"
    local desc="WebSocket 代理: ws://${ip}:${port}${path} (无认证)"
    echo "$cmd|||$desc"
}

collect_chain_params() {
    echo -e "${BLUE}请选择本地代理类型:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read -r local_type
    local local_proto=""
    case $local_type in
        1) local_proto="http" ;;
        2) local_proto="socks5" ;;
        *) echo -e "${RED}无效，使用 HTTP${NC}"; local_proto="http" ;;
    esac
    local local_port
    while true; do
        echo -n -e "${YELLOW}请输入本地监听端口: ${NC}"
        read -r local_port
        [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    echo -n -e "${YELLOW}本地代理是否需要认证？[y/N]: ${NC}"
    read -r local_auth
    local local_listen=""
    local local_listen_arg=""
    if [[ "$local_auth" =~ ^[Yy]$ ]]; then
        echo -n -e "${YELLOW}本地用户名 (默认 admin): ${NC}"
        read -r local_user; local_user=${local_user:-admin}
        echo -n -e "${YELLOW}本地密码 (默认 123456): ${NC}"
        read -r local_pass; local_pass=${local_pass:-123456}
        local_listen="-L ${local_proto}://${local_user}:${local_pass}@:${local_port}"
        local_listen_arg="${local_user}:${local_pass}@:${local_port}"
    else
        local_listen="-L ${local_proto}://:${local_port}"
        local_listen_arg=":${local_port}"
    fi
    echo -e "${YELLOW}请选择远程转发模式:${NC}"
    echo -e "  ${GREEN}1${NC}) WebSocket (ws/wss)"
    echo -e "  ${GREEN}2${NC}) SSH 端口转发"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read -r remote_mode
    local remote_url=""
    if [ "$remote_mode" = "1" ]; then
        echo -e "${YELLOW}请输入远程 WebSocket 地址 (格式: ws://host:port/path 或 wss://...): ${NC}"
        read -r remote_url
        while [ -z "$remote_url" ]; do
            echo -e "${RED}地址不能为空${NC}"
            read -r remote_url
        done
        local cmd="$local_listen -F $remote_url"
        local desc="链式代理: 本地 ${local_proto}://${local_listen_arg} -> 远程 ${remote_url}"
        echo "$cmd|||$desc"
    elif [ "$remote_mode" = "2" ]; then
        echo -n -e "${YELLOW}请输入 SSH 服务器地址: ${NC}"
        read -r ssh_host
        [ -z "$ssh_host" ] && { echo -e "${RED}地址不能为空${NC}"; return 1; }
        echo -n -e "${YELLOW}请输入 SSH 端口 (默认 22): ${NC}"
        read -r ssh_port; ssh_port=${ssh_port:-22}
        echo -n -e "${YELLOW}请输入 SSH 用户名: ${NC}"
        read -r ssh_user
        [ -z "$ssh_user" ] && { echo -e "${RED}用户名不能为空${NC}"; return 1; }
        echo -e "${YELLOW}SSH 认证方式: 1) 密码认证  2) 密钥认证${NC}"
        echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
        read -r auth_type
        local ssh_auth=""
        if [ "$auth_type" = "1" ]; then
            echo -n -e "${YELLOW}请输入 SSH 密码: ${NC}"
            IFS= read -r -s ssh_pass
            echo
            # 密码转义（用于 URL，但 GOST 支持特殊字符）
            ssh_auth="${ssh_user}:${ssh_pass}"
        else
            ssh_auth="${ssh_user}"
        fi
        local forward_url="ssh://${ssh_auth}@${ssh_host}:${ssh_port}"
        local cmd="$local_listen -F $forward_url"
        local desc="链式代理: 本地 ${local_proto}://${local_listen_arg} -> 远程 SSH ssh://${ssh_user}@${ssh_host}:${ssh_port}"
        echo "$cmd|||$desc"
    else
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
}

# DNS 参数收集（对 hosts 进行 URL 编码）
url_encode() {
    local string="$1"
    local encoded=""
    local i
    for ((i=0; i<${#string}; i++)); do
        local c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

collect_dns_params() {
    local port
    while true; do
        echo -n -e "${YELLOW}请输入 DNS 监听端口 (默认 53): ${NC}"
        read -r port
        [ -z "$port" ] && port=53
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done
    if [ "$port" -eq 53 ] && [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}警告: 端口 53 需要 root 权限，可能无法启动${NC}"
    fi
    echo -n -e "${YELLOW}请输入上游 DNS 服务器 (默认 8.8.8.8, 多个用逗号分隔): ${NC}"
    read -r upstream; upstream=${upstream:-8.8.8.8}
    echo -n -e "${YELLOW}请输入缓存 TTL (秒，默认 60): ${NC}"
    read -r ttl; ttl=${ttl:-60}
    local hosts=""
    echo -n -e "${YELLOW}是否添加自定义 hosts 映射？[y/N]: ${NC}"
    read -r add_hosts
    if [[ "$add_hosts" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}请输入域名:IP，每行一条，空行结束:${NC}"
        while true; do
            read -r line
            [ -z "$line" ] && break
            if [[ "$line" =~ .+:.* ]]; then
                # 对每个 hosts 条目进行 URL 编码
                local encoded_line
                encoded_line=$(url_encode "$line")
                if [ -n "$hosts" ]; then
                    hosts="${hosts},${encoded_line}"
                else
                    hosts="$encoded_line"
                fi
            else
                echo -e "${RED}格式错误，应为 域名:IP${NC}"
            fi
        done
    fi
    local query="dns=${upstream}&ttl=${ttl}"
    [ -n "$hosts" ] && query="${query}&hosts=${hosts}"
    local cmd="-L \"dns://:${port}?${query}\""
    local desc="DNS 代理: udp://0.0.0.0:${port} (上游: ${upstream}, TTL: ${ttl})"
    echo "$cmd|||$desc"
}

# ========== 配置替换模式 ==========
configure_proxy() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       配置代理（替换模式）${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}请选择代理类型:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应"
    echo -e "  ${GREEN}4${NC}) Shadowsocks"
    echo -e "  ${GREEN}5${NC}) WebSocket (ws)"
    echo -e "  ${GREEN}6${NC}) 链式代理"
    echo -e "  ${GREEN}7${NC}) DNS 代理"
    echo -n -e "${YELLOW}请输入 [1-7]: ${NC}"
    read -r ptype
    local result=""
    case $ptype in
        1) result=$(collect_http_params) ;;
        2) result=$(collect_socks5_params) ;;
        3) result=$(collect_adapt_params) ;;
        4) result=$(collect_ss_params) ;;
        5) result=$(collect_ws_params) ;;
        6) result=$(collect_chain_params) ;;
        7) result=$(collect_dns_params) ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
    if [ -z "$result" ]; then
        echo -e "${RED}参数收集失败${NC}"
        return 1
    fi
    local cmd_part
    local desc
    cmd_part=$(echo "$result" | cut -d'|' -f1)
    desc=$(echo "$result" | cut -d'|' -f3-)
    # 清空旧配置
    echo "$GOST_BIN $cmd_part" > "$START_CMD_FILE"
    restart_gost_single
    replace_node_info "$desc"

    # 询问开机自启
    echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
    read -r auto_start
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        enable_autostart
    fi
}

# ========== 添加服务 ==========
add_service_to_single() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       添加服务（单进程模式）${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}请选择要添加的代理类型:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应"
    echo -e "  ${GREEN}4${NC}) Shadowsocks"
    echo -e "  ${GREEN}5${NC}) WebSocket (ws)"
    echo -e "  ${GREEN}6${NC}) 链式代理"
    echo -e "  ${GREEN}7${NC}) DNS 代理"
    echo -n -e "${YELLOW}请输入 [1-7]: ${NC}"
    read -r ptype
    local result=""
    case $ptype in
        1) result=$(collect_http_params) ;;
        2) result=$(collect_socks5_params) ;;
        3) result=$(collect_adapt_params) ;;
        4) result=$(collect_ss_params) ;;
        5) result=$(collect_ws_params) ;;
        6) result=$(collect_chain_params) ;;
        7) result=$(collect_dns_params) ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
    if [ -z "$result" ]; then
        echo -e "${RED}参数收集失败${NC}"
        return 1
    fi
    local cmd_part
    local desc
    cmd_part=$(echo "$result" | cut -d'|' -f1)
    desc=$(echo "$result" | cut -d'|' -f3-)
    if [ -f "$START_CMD_FILE" ] && [ -s "$START_CMD_FILE" ]; then
        local old_cmd
        old_cmd=$(cat "$START_CMD_FILE")
        echo "$old_cmd $cmd_part" > "$START_CMD_FILE"
    else
        echo "$GOST_BIN $cmd_part" > "$START_CMD_FILE"
    fi
    restart_gost_single
    append_node_info "$desc"
}

add_service_independent() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       添加服务（独立进程模式）${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}请选择要添加的代理类型:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应"
    echo -e "  ${GREEN}4${NC}) Shadowsocks"
    echo -e "  ${GREEN}5${NC}) WebSocket (ws)"
    echo -e "  ${GREEN}6${NC}) 链式代理"
    echo -e "  ${GREEN}7${NC}) DNS 代理"
    echo -n -e "${YELLOW}请输入 [1-7]: ${NC}"
    read -r ptype
    local result=""
    case $ptype in
        1) result=$(collect_http_params) ;;
        2) result=$(collect_socks5_params) ;;
        3) result=$(collect_adapt_params) ;;
        4) result=$(collect_ss_params) ;;
        5) result=$(collect_ws_params) ;;
        6) result=$(collect_chain_params) ;;
        7) result=$(collect_dns_params) ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
    if [ -z "$result" ]; then
        echo -e "${RED}参数收集失败${NC}"
        return 1
    fi
    local cmd_part
    local desc
    cmd_part=$(echo "$result" | cut -d'|' -f1)
    desc=$(echo "$result" | cut -d'|' -f3-)
    local full_cmd="$GOST_BIN $cmd_part"
    start_gost_independent "$full_cmd" "$desc"
    # 独立进程模式下不保存到 sub.txt（可选），但可以追加说明
    echo -e "${YELLOW}独立进程已启动，未记录到节点文件。${NC}"
}

add_service() {
    echo -e "${BLUE}请选择添加方式:${NC}"
    echo -e "  ${GREEN}1${NC}) 单进程多服务（追加服务并重启，所有服务共用一个进程）"
    echo -e "  ${GREEN}2${NC}) 独立进程（启动新进程，不影响现有服务）"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read -r mode
    case $mode in
        1) add_service_to_single ;;
        2) add_service_independent ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# ========== 开机自启 ==========
enable_autostart() {
    local current_cron
    current_cron=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR/gost" || true)
    # 生成保活脚本（仅用于单进程模式）
    local keepalive_script="$GOST_DIR/keepalive.sh"
    cat > "$keepalive_script" << EOF
#!/usr/bin/env bash
GOST_DIR="$GOST_DIR"
START_CMD_FILE="\$GOST_DIR/start_cmd.txt"
GOST_PID_FILE="\$GOST_DIR/gost.pid"
GOST_BIN="\$GOST_DIR/gost"
if [ -f "\$START_CMD_FILE" ] && [ -s "\$START_CMD_FILE" ]; then
    if ! pgrep -f "\$GOST_BIN" > /dev/null 2>&1; then
        cd "\$GOST_DIR"
        eval "nohup \$(cat "\$START_CMD_FILE") > \$GOST_DIR/gost.log 2>&1 &"
        echo \$! > "\$GOST_PID_FILE"
    fi
fi
EOF
    chmod +x "$keepalive_script"
    # 添加 cron 任务：每5分钟检查一次单进程
    (echo "$current_cron"; echo "@reboot $keepalive_script"; echo "*/5 * * * * $keepalive_script") | crontab -
    echo -e "${GREEN}✓ 已配置开机自启和进程保活（单进程模式）${NC}"
}

# ========== 查看状态 ==========
show_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          系统状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    local local_ip
    local_ip=$(get_local_ip)
    echo -e "${GREEN}本机 IP: ${YELLOW}${local_ip}${NC}"
    if [ -f "$GOST_BIN" ]; then
        echo -e "${GREEN}GOST 版本: $(get_installed_gost_version)${NC}"
        echo -e "${GREEN}安装路径: ${GOST_BIN}${NC}"
    else
        echo -e "${RED}GOST 未安装${NC}"
    fi
    echo -e "${BLUE}--- 单进程模式 ---${NC}"
    if [ -f "$START_CMD_FILE" ] && [ -s "$START_CMD_FILE" ]; then
        echo -e "${GREEN}启动命令: $(cat "$START_CMD_FILE")${NC}"
        if [ -f "$GOST_PID_FILE" ] && kill -0 "$(cat "$GOST_PID_FILE")" 2>/dev/null; then
            echo -e "${GREEN}进程 PID: $(cat "$GOST_PID_FILE") (运行中)${NC}"
        else
            echo -e "${RED}进程未运行${NC}"
        fi
    else
        echo -e "${YELLOW}无单进程配置${NC}"
    fi
    echo -e "${BLUE}--- 独立进程 ---${NC}"
    local found=0
    for pidfile in "$PID_DIR"/*.pid; do
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                local infofile="${pidfile%.pid}.info"
                local desc=""
                [ -f "$infofile" ] && desc=$(cat "$infofile")
                # 尝试获取命令行
                local cmdline=""
                if [ -f "/proc/$pid/cmdline" ]; then
                    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
                fi
                echo -e "${GREEN}PID: $pid${NC}"
                echo -e "  描述: $desc"
                [ -n "$cmdline" ] && echo -e "  命令: $cmdline"
                ((found++))
            else
                rm -f "$pidfile" "$infofile"
            fi
        fi
    done
    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}没有运行中的独立进程${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
    echo
}

# ========== 停止服务 ==========
stop_service() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          停止服务${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  ${GREEN}1${NC}) 停止单进程服务"
    echo -e "  ${GREEN}2${NC}) 停止指定独立进程"
    echo -e "  ${GREEN}3${NC}) 停止所有 GOST 进程"
    echo -e "  ${GREEN}0${NC}) 返回"
    echo -n -e "${YELLOW}请输入 [0-3]: ${NC}"
    read -r opt
    case $opt in
        1)
            stop_single_gost
            ;;
        2)
            local pids=()
            local descs=()
            for pidfile in "$PID_DIR"/*.pid; do
                if [ -f "$pidfile" ]; then
                    local pid
                    pid=$(cat "$pidfile")
                    if kill -0 "$pid" 2>/dev/null; then
                        local infofile="${pidfile%.pid}.info"
                        local desc=""
                        [ -f "$infofile" ] && desc=$(cat "$infofile")
                        pids+=("$pid")
                        descs+=("$desc")
                    else
                        rm -f "$pidfile" "$infofile"
                    fi
                fi
            done
            if [ ${#pids[@]} -eq 0 ]; then
                echo -e "${YELLOW}没有运行中的独立进程${NC}"
                echo -n -e "${GREEN}按任意键返回...${NC}"
                read -n 1
                echo
                return
            fi
            echo -e "${YELLOW}请选择要停止的进程:${NC}"
            for i in "${!pids[@]}"; do
                echo "  $((i+1))) PID ${pids[$i]} - ${descs[$i]}"
            done
            echo -n -e "${YELLOW}请输入数字: ${NC}"
            read -r idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#pids[@]} ]; then
                local target_pid=${pids[$((idx-1))]}
                kill "$target_pid" 2>/dev/null || true
                for pidfile in "$PID_DIR"/*.pid; do
                    if [ -f "$pidfile" ] && [ "$(cat "$pidfile")" -eq "$target_pid" ]; then
                        rm -f "$pidfile" "${pidfile%.pid}.info"
                        break
                    fi
                done
                echo -e "${GREEN}已停止 PID $target_pid${NC}"
            else
                echo -e "${RED}无效选择${NC}"
            fi
            ;;
        3)
            stop_all_gost
            ;;
        *)
            return
            ;;
    esac
    echo -n -e "${GREEN}按任意键返回...${NC}"
    read -n 1
    echo
}

# ========== 其他功能 ==========
uninstall_gost() {
    echo -e "${YELLOW}正在卸载 GOST...${NC}"
    stop_all_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab - 2>/dev/null || true
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
    echo -n -e "${GREEN}按任意键返回...${NC}"
    read -n 1
    echo
}

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

show_sub() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          节点信息${NC}"
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$SUBFILE" ] && [ -s "$SUBFILE" ]; then
        cat "$SUBFILE"
    else
        echo -e "${RED}暂无节点信息，请先配置代理。${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
    echo
}

# ========== 主菜单 ==========
show_menu() {
    echo
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        GOST 一键管理脚本            ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${GREEN}1${BLUE}) 安装 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}2${BLUE}) 配置代理（替换现有）           ║${NC}"
    echo -e "${BLUE}║  ${GREEN}3${BLUE}) 查看状态                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}4${BLUE}) 卸载 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}5${BLUE}) 更新脚本                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}6${BLUE}) 查看节点信息                   ║${NC}"
    echo -e "${BLUE}║  ${GREEN}7${BLUE}) 停止服务                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}8${BLUE}) 添加服务                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-8]: ${NC}"
}

# ========== 入口 ==========
main() {
    detect_os_arch
    # 如果已有单进程配置但未运行，尝试启动
    if [ -f "$START_CMD_FILE" ] && [ -s "$START_CMD_FILE" ] && [ ! -f "$GOST_PID_FILE" ]; then
        echo -e "${YELLOW}检测到已有配置但未运行，是否现在启动？[y/N]${NC}"
        read -r start_now
        if [[ "$start_now" =~ ^[Yy]$ ]]; then
            restart_gost_single
        fi
    fi
    while true; do
        show_menu
        read -r choice
        case $choice in
            1)
                if select_version_to_install; then
                    if [ -f "$GOST_BIN" ]; then
                        echo
                        echo -n -e "${GREEN}是否配置代理？[Y/n]: ${NC}"
                        read -r config_now
                        if [[ -z "$config_now" ]] || [[ "$config_now" =~ ^[Yy]$ ]]; then
                            configure_proxy
                        fi
                    fi
                fi
                ;;
            2) configure_proxy ;;
            3) show_status ;;
            4) uninstall_gost ;;
            5) update_script ;;
            6) show_sub ;;
            7) stop_service ;;
            8) add_service ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main
