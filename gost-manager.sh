#!/usr/bin/env bash

#===========================================
# GOST 一键管理脚本 (v2 & v3 通用)
#===========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SUBFILE="$HOME/sub.txt"

# ---------- 前置检查 ----------
check_required_tools() {
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}错误: 需要 wget 或 curl，请安装后重试。${NC}"
        exit 1
    fi
}
check_required_tools

# ---------- 本机 IP ----------
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

# ---------- 工作目录 ----------
setup_workspace() {
    CURRENT_USER=$(whoami)
    if [[ "$CURRENT_USER" == "root" ]]; then
        if [[ -n "$SUDO_USER" ]]; then NORMAL_USER="$SUDO_USER"
        elif [[ -n "$USER" ]] && [[ "$USER" != "root" ]]; then NORMAL_USER="$USER"
        else NORMAL_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null)
        fi
        WORK_HOME="/home/$NORMAL_USER"
        [[ -z "$NORMAL_USER" ]] && WORK_HOME="$PWD"
    else
        WORK_HOME="$HOME"
    fi
    GOST_DIR="$WORK_HOME/GOST"
    mkdir -p "$GOST_DIR" 2>/dev/null || { GOST_DIR="/tmp/GOST_${CURRENT_USER}"; mkdir -p "$GOST_DIR"; }
    GOST_BIN="$GOST_DIR/gost"
    GOST_LOG="$GOST_DIR/gost.log"
    GOST_PID_FILE="$GOST_DIR/gost.pid"
    GOST_CMD_FILE="$GOST_DIR/start_cmd.txt"
    echo -e "${GREEN}工作目录: ${GOST_DIR}${NC}"
}
setup_workspace

# ---------- 系统/架构 ----------
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

# ---------- 版本相关 ----------
get_installed_gost_version() {
    if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
        local ver=$("$GOST_BIN" -V 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        [ -n "$ver" ] && echo "$ver" || echo "未知版本"
    else
        echo "未安装"
    fi
}

is_v3() {
    local ver=$(get_installed_gost_version)
    [[ "$ver" =~ ^[3-9]\. ]] && return 0
    [[ "$ver" =~ ^v?[3-9]\. ]] && return 0
    return 1
}

# v1 >= v2 纯数值比较
version_ge() {
    local v1=${1#v}; local v2=${2#v}
    local IFS=.; local arr1=($v1) arr2=($v2)
    while [ ${#arr1[@]} -lt 3 ]; do arr1+=(0); done
    while [ ${#arr2[@]} -lt 3 ]; do arr2+=(0); done
    for i in 0 1 2; do
        [ "${arr1[$i]}" -gt "${arr2[$i]}" ] && return 0
        [ "${arr1[$i]}" -lt "${arr2[$i]}" ] && return 1
    done
    return 0
}

# DNS 参数适配: v3 → -resolver, v2 → ?dns=
gost_resolver_arg() {
    local dns="$1"
    [ -z "$dns" ] && return
    is_v3 && echo "-resolver $dns" || echo "?dns=${dns}"
}

# ---------- 停止与检查 ----------
stop_gost() {
    if pgrep -f "$GOST_BIN" >/dev/null 2>&1; then
        echo -e "${YELLOW}正在停止 GOST...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
        sleep 1
        pkill -9 -f "$GOST_BIN" 2>/dev/null
        echo -e "${GREEN}✓ 已停止${NC}"
    fi
    [ -f "$GOST_PID_FILE" ] && rm -f "$GOST_PID_FILE"
}

check_existing_gost() {
    local ver=$(get_installed_gost_version)
    if [ "$ver" != "未安装" ]; then
        echo -e "${GREEN}当前版本: ${ver}${NC}"
        if pgrep -f "$GOST_BIN" >/dev/null 2>&1; then
            echo -e "${YELLOW}运行中 PID: $(pgrep -f "$GOST_BIN" | head -1)${NC}"
        fi
        echo -n -e "${YELLOW}是否覆盖安装？[y/N]: ${NC}"
        read ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            pgrep -f "$GOST_BIN" >/dev/null 2>&1 && stop_gost
            return 0
        else
            echo -e "${RED}取消安装。${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}未检测到 GOST。${NC}"
        return 0
    fi
}

# ---------- 安装 ----------
install_gost_v2() {
    local version=$1
    check_existing_gost || return 1
    mkdir -p "$GOST_DIR"; cd "$GOST_DIR" || return 1
    rm -f gost gost.tar.gz gost.gz
    local downloaded=0
    if version_ge "$version" "2.12"; then
        local url="https://github.com/ginuerzh/gost/releases/download/v${version}/gost_${version}_${os}_${cpu_arch}.tar.gz"
        echo -e "      尝试: ${url}"
        wget -q --timeout=15 -O gost.tar.gz "$url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$url" -o gost.tar.gz 2>/dev/null
        if [ -f gost.tar.gz ] && [ -s gost.tar.gz ]; then
            tar -xzf gost.tar.gz gost 2>/dev/null || tar -xzf gost.tar.gz 2>/dev/null
            [ -f gost ] && downloaded=1
        fi
    fi
    if [ $downloaded -eq 0 ]; then
        echo -e "${YELLOW}      尝试旧格式 .gz...${NC}"
        local gz_urls=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-${os}-${cpu_arch}-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
        )
        [[ "$os" == "linux" ]] && case "$cpu_arch" in
            amd64) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz") ;;
            arm64) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz"
                            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-arm64-${version}.gz") ;;
            armv7) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv7-${version}.gz") ;;
            386)   gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-386-${version}.gz") ;;
        esac
        for url in "${gz_urls[@]}"; do
            echo -e "      尝试: ${url}"
            if wget -q --timeout=15 -O - "$url" 2>/dev/null | gunzip > gost 2>/dev/null; then
                [ -f gost ] && [ -s gost ] && { downloaded=1; echo -e "${GREEN}      下载成功${NC}"; break; }
            fi
            curl -fsSL --connect-timeout 15 "$url" | gunzip > gost 2>/dev/null
            [ -f gost ] && [ -s gost ] && { downloaded=1; echo -e "${GREEN}      下载成功${NC}"; break; }
        done
    fi
    if [ $downloaded -eq 0 ]; then
        echo -e "${RED}下载失败。${NC}"; read -n 1 -p "按任意键退出..."; return 1
    fi
    chmod +x gost
    [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ] && echo -e "${GREEN}✓ 安装成功${NC}" && "$GOST_BIN" -V 2>&1 | head -1 && return 0
    echo -e "${RED}安装失败。${NC}"; read -n 1 -p "按任意键退出..."; return 1
}

install_gost_v3() {
    local version=$1
    check_existing_gost || return 1
    mkdir -p "$GOST_DIR"; cd "$GOST_DIR" || return 1
    rm -f gost gost.tar.gz
    local clean="${version#v}"
    local url="https://github.com/go-gost/gost/releases/download/${version}/gost_${clean}_${os}_${cpu_arch}.tar.gz"
    echo -e "      下载: ${url}"
    wget -q --timeout=15 -O gost.tar.gz "$url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$url" -o gost.tar.gz 2>/dev/null
    if [ -f gost.tar.gz ] && [ -s gost.tar.gz ]; then
        tar -xzf gost.tar.gz gost 2>/dev/null || tar -xzf gost.tar.gz
        chmod +x gost; rm -f gost.tar.gz
        [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ] && echo -e "${GREEN}✓ 安装成功${NC}" && return 0
    fi
    echo -e "${RED}下载失败。${NC}"; read -n 1 -p "按任意键退出..."; return 1
}

get_v2_versions() {
    local versions=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ginuerzh/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -10)
    [ -z "$versions" ] && versions="2.12.0 2.11.5 2.11.4 2.11.3 2.11.2 2.11.1 2.11.0 2.10.0 2.9.2"
    local arr=($versions); local cnt=${#arr[@]}
    echo -e "${GREEN}可用的 v2 版本:${NC}"
    for i in "${!arr[@]}"; do echo "  $((i+1))) ${arr[$i]}"; done
    echo "  $((cnt+1))) 返回"
    read -p "请选择 (默认 1): " choice
    [[ -z "$choice" ]] && choice=1
    [ "$choice" -eq $((cnt+1)) ] && return 1
    [ "$choice" -ge 1 ] && [ "$choice" -le "$cnt" ] && install_gost_v2 "${arr[$((choice-1))]}"
}

get_v3_versions() {
    local all=$(curl -s "https://api.github.com/repos/go-gost/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"(v[^"]+)".*/\1/')
    local versions=""
    [ -z "$all" ] && versions="v3.2.6 v3.2.5 v3.2.4 v3.2.3 v3.2.2 v3.2.1 v3.2.0" || versions=$(echo "$all" | grep -viE 'nightly|rc|alpha|beta' | head -10)
    local arr=($versions); local cnt=${#arr[@]}
    [ $cnt -eq 0 ] && arr=(v3.2.6 v3.2.5 v3.2.4 v3.2.3 v3.2.2) && cnt=${#arr[@]}
    echo -e "${GREEN}可用的 v3 稳定版:${NC}"
    for i in "${!arr[@]}"; do echo "  $((i+1))) ${arr[$i]}"; done
    echo "  $((cnt+1))) 返回"
    read -p "请选择 (默认 1): " choice
    [[ -z "$choice" ]] && choice=1
    [ "$choice" -eq $((cnt+1)) ] && return 1
    [ "$choice" -ge 1 ] && [ "$choice" -le "$cnt" ] && install_gost_v3 "${arr[$((choice-1))]}"
}

select_version_to_install() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "        选择 GOST 版本"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  1) GOST v2"
    echo -e "  2) GOST v3"
    echo -e "  0) 返回"
    read -p "请选择 [0-2]: " choice
    case $choice in
        1) get_v2_versions ;;
        2) get_v3_versions ;;
        0) return 1 ;;
        *) echo -e "${RED}无效${NC}"; return 1 ;;
    esac
}

# ---------- 节点信息 ----------
save_node_info() {
    printf "%s\n" "$1" > "$SUBFILE"
    echo -e "${GREEN}节点信息已保存到: ${SUBFILE}${NC}"
}

# ---------- 通用启动 ----------
start_gost_generic() {
    local cmd="$1" info="$2"
    cd "$GOST_DIR" || return 1
    stop_gost
    echo -e "${GREEN}启动代理...${NC}"
    echo "$cmd" > "$GOST_CMD_FILE"
    echo "=== GOST 启动于 $(date) ===" > "$GOST_LOG"
    echo "命令: $cmd" >> "$GOST_LOG"
    echo "信息: $info" >> "$GOST_LOG"
    eval "nohup $cmd >> \"$GOST_LOG\" 2>&1 &"
    local pid=$!
    echo $pid > "$GOST_PID_FILE"
    sleep 2
    if pgrep -f "$GOST_BIN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理信息:${NC}\n${YELLOW}${info}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        save_node_info "$info"
        echo "进程 PID: $pid, 启动成功" >> "$GOST_LOG"
        return 0
    else
        echo -e "${RED}启动失败，查看日志: ${GOST_LOG}${NC}"
        return 1
    fi
}

build_query_string() {
    local q=""; local sep=""
    for p in "$@"; do
        [ -n "$p" ] && q="${q}${sep}${p}" && sep="&"
    done
    [ -n "$q" ] && echo "?${q}"
}

# ---------- WebSocket ----------
configure_websocket() {
    local port
    while true; do
        read -p "监听端口: " port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}无效端口${NC}"
    done

    echo -e "${YELLOW}WebSocket 路径 (默认 /ws, 0=无路径): ${NC}"
    read -p "路径: " path_input
    local path=""
    [ -z "$path_input" ] && path="/ws"
    [ "$path_input" = "0" ] && path="" || path="$path_input"

    # v3 组合
    local proto_combo="" proto_label=""
    local combo_user="" combo_pass="" ss_method="" ss_pass="" ss_name=""
    if is_v3; then
        echo -e "${YELLOW}v3 支持组合协议:${NC}"
        echo -e " 1) HTTP over WS"
        echo -e " 2) SOCKS5 over WS"
        echo -e " 3) Shadowsocks over WS"
        echo -e " 4) 纯隧道"
        read -p "请选择 [1-4] (默认 4): " combo
        case $combo in
            1) proto_combo="http+ws"; proto_label="HTTP" ;;
            2) proto_combo="socks5+ws"; proto_label="SOCKS5" ;;
            3) proto_combo="ss+ws"; proto_label="Shadowsocks" ;;
            *) proto_combo="" ;;
        esac
        if [[ "$proto_combo" == "http+ws" || "$proto_combo" == "socks5+ws" ]]; then
            read -p "是否需要认证？[y/N]: " need_auth
            if [[ "$need_auth" =~ ^[Yy]$ ]]; then
                while true; do
                    read -p "用户名: " combo_user; read -p "密码: " combo_pass
                    [[ "$combo_user" =~ [:@/] || "$combo_pass" =~ [:@/] ]] && echo -e "${RED}不能包含 :@/${NC}" || break
                done
            fi
        elif [[ "$proto_combo" == "ss+ws" ]]; then
            local methods=("aes-256-gcm" "aes-128-gcm" "chacha20-ietf-poly1305")
            echo -e "选择加密: 1) aes-256-gcm 2) aes-128-gcm 3) chacha20-ietf-poly1305"
            read -p "默认 1: " mch; [ -z "$mch" ] && mch=1
            ss_method="${methods[$((mch-1))]}" 2>/dev/null || ss_method="aes-256-gcm"
            while true; do
                read -p "密码: " ss_pass; [ -z "$ss_pass" ] && ss_pass="123456"
                [[ "$ss_pass" =~ [:@/] ]] && echo -e "${RED}密码含特殊字符${NC}" || break
            done
            read -p "节点名称 (默认 GOST-SS-WS): " ss_name; [ -z "$ss_name" ] && ss_name="GOST-SS-WS"
        fi
    fi

    # DNS
    local dns_input=""
    read -p "自定义 DNS？[y/N]: " use_dns
    if [[ "$use_dns" =~ ^[Yy]$ ]]; then
        echo -e "格式: udp://8.8.8.8:53  tcp://8.8.8.8:53  tls://1.1.1.1:853  https://1.1.1.1/dns-query"
        read -p "DNS 地址 (默认 https://1.1.1.1/dns-query): " dns_input
        [ -z "$dns_input" ] && dns_input="https://1.1.1.1/dns-query"
    fi
    local resolver_arg=$(gost_resolver_arg "$dns_input")

    # 构建监听 URL
    local listen_addr=""
    if [ -n "$proto_combo" ]; then
        listen_addr="${proto_combo}://"
        if [[ "$proto_combo" == "ss+ws" ]]; then
            listen_addr="${listen_addr}${ss_method}:${ss_pass}@:${port}"
        else
            [ -n "$combo_user" ] && listen_addr="${listen_addr}${combo_user}:${combo_pass}@"
            listen_addr="${listen_addr}:${port}"
        fi
    else
        listen_addr="ws://:${port}"
    fi

    local params=(); [ -n "$path" ] && params+=("path=${path}")
    local query=$(build_query_string "${params[@]}")

    local cmd=""
    if is_v3; then
        cmd="$GOST_BIN $resolver_arg -L ${listen_addr}${query}"
    else
        local full_query="${query}"
        if [[ "$resolver_arg" == \?* ]]; then
            [ -n "$query" ] && full_query="${query}&${resolver_arg#\?}" || full_query="${resolver_arg}"
        fi
        cmd="$GOST_BIN -L ${listen_addr}${full_query}"
    fi

    local ip=$(get_local_ip)
    local info=""
    [ -n "$proto_combo" ] && info="${proto_label} over WebSocket: ${proto_combo}://${ip}:${port}" || info="WebSocket: ws://${ip}:${port}"
    [ -n "$path" ] && info="${info}${path}"
    [ -n "$dns_input" ] && info="${info} (DNS: ${dns_input})"
    start_gost_generic "$cmd" "$info"
}

# ---------- SSH 转发 ----------
configure_ssh() {
    local local_listen="$1" local_proto="$2" local_listen_arg="$3"
    read -p "SSH 服务器地址: " ssh_host; [ -z "$ssh_host" ] && { echo -e "${RED}地址不能为空${NC}"; return 1; }
    read -p "SSH 端口 (默认 22): " ssh_port; [ -z "$ssh_port" ] && ssh_port=22
    read -p "SSH 用户名: " ssh_user; [ -z "$ssh_user" ] && { echo -e "${RED}用户名不能为空${NC}"; return 1; }
    echo -e "认证方式: 1) 密码  2) 密钥"
    read -p "选择: " auth_type
    local ssh_auth=""
    if [ "$auth_type" = "1" ]; then
        read -s -p "密码: " ssh_pass; echo
        [[ "$ssh_user" =~ [:@/] || "$ssh_pass" =~ [:@/] ]] && { echo -e "${RED}用户名/密码含特殊字符${NC}"; return 1; }
        ssh_auth="${ssh_user}:${ssh_pass}"
    else
        ssh_auth="${ssh_user}"
    fi
    local forward_url="ssh://${ssh_auth}@${ssh_host}:${ssh_port}"
    local cmd="$GOST_BIN $local_listen -F $forward_url"
    local info="链式代理: ${local_proto}://${local_listen_arg} -> ssh://${ssh_user}@${ssh_host}:${ssh_port}"
    start_gost_generic "$cmd" "$info"
}

# ---------- 链式代理 ----------
configure_chain() {
    echo -e "${BLUE}本地代理类型:${NC} 1) HTTP  2) SOCKS5"
    read -p "选择 [1-2]: " local_type
    local local_proto="http"
    case $local_type in
        1) local_proto="http" ;;
        2) local_proto="socks5" ;;
        *) echo -e "${RED}无效，使用 HTTP${NC}" ;;
    esac

    local local_port
    while true; do
        read -p "本地监听端口: " local_port
        [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] && break
        echo -e "${RED}无效端口${NC}"
    done

    read -p "本地是否需要认证？[y/N]: " local_auth
    local local_user="" local_pass=""
    if [[ "$local_auth" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "本地用户名 (默认 admin): " local_user; [ -z "$local_user" ] && local_user="admin"
            read -p "本地密码 (默认 123456): " local_pass; [ -z "$local_pass" ] && local_pass="123456"
            [[ "$local_user" =~ [:@/] || "$local_pass" =~ [:@/] ]] && echo -e "${RED}含特殊字符，重输${NC}" || break
        done
    fi

    local local_listen=""
    if [ -n "$local_user" ]; then
        local_listen="-L ${local_proto}://${local_user}:${local_pass}@:${local_port}"
        local_listen_arg="${local_user}:${local_pass}@:${local_port}"
    else
        local_listen="-L ${local_proto}://:${local_port}"
        local_listen_arg=":${local_port}"
    fi

    echo -e "${YELLOW}远程转发模式:${NC} 1) WebSocket  2) SSH"
    read -p "选择 [1-2]: " remote_mode

    case $remote_mode in
        1)
            # v3 远程 WS 组合
            local remote_proto="ws" remote_user="" remote_pass="" remote_ss_method="" remote_ss_pass=""
            if is_v3; then
                echo -e "${YELLOW}远程 WS 协议组合:${NC} 1) 纯隧道  2) HTTP over WS  3) SOCKS5 over WS  4) SS over WS"
                read -p "选择 [1-4] (默认 1): " remote_combo
                case $remote_combo in
                    2) remote_proto="http+ws" ;;
                    3) remote_proto="socks5+ws" ;;
                    4) remote_proto="ss+ws" ;;
                    *) remote_proto="ws" ;;
                esac
                if [[ "$remote_proto" == "http+ws" || "$remote_proto" == "socks5+ws" ]]; then
                    read -p "远程需要认证？[y/N]: " need_auth
                    if [[ "$need_auth" =~ ^[Yy]$ ]]; then
                        while true; do
                            read -p "用户名: " remote_user; read -p "密码: " remote_pass
                            [[ "$remote_user" =~ [:@/] || "$remote_pass" =~ [:@/] ]] && echo -e "${RED}含特殊字符${NC}" || break
                        done
                    fi
                elif [ "$remote_proto" = "ss+ws" ]; then
                    local methods=("aes-256-gcm" "aes-128-gcm" "chacha20-ietf-poly1305")
                    echo -e "加密: 1) aes-256-gcm 2) aes-128-gcm 3) chacha20-ietf-poly1305"
                    read -p "选择 (默认 1): " mch; [ -z "$mch" ] && mch=1
                    remote_ss_method="${methods[$((mch-1))]}" 2>/dev/null || remote_ss_method="aes-256-gcm"
                    while true; do
                        read -p "密码: " remote_ss_pass; [ -z "$remote_ss_pass" ] && remote_ss_pass="123456"
                        [[ "$remote_ss_pass" =~ [:@/] ]] && echo -e "${RED}含特殊字符${NC}" || break
                    done
                fi
            fi

            read -p "远程服务器地址: " remote_host; [ -z "$remote_host" ] && { echo -e "${RED}不能为空${NC}"; return 1; }
            read -p "远程端口: " remote_port
            [[ ! "$remote_port" =~ ^[0-9]+$ || "$remote_port" -lt 1 || "$remote_port" -gt 65535 ]] && { echo -e "${RED}端口无效${NC}"; return 1; }

            read -p "WebSocket 路径 (默认 /ws, 0=无): " path_input
            local path=""
            [ -z "$path_input" ] && path="/ws"
            [ "$path_input" = "0" ] && path="" || path="$path_input"

            local dns_input=""
            read -p "自定义 DNS？[y/N]: " use_dns
            if [[ "$use_dns" =~ ^[Yy]$ ]]; then
                echo -e "格式: udp://8.8.8.8:53 tcp://8.8.8.8:53 tls://1.1.1.1:853 https://1.1.1.1/dns-query"
                read -p "DNS 地址: " dns_input; [ -z "$dns_input" ] && dns_input="https://1.1.1.1/dns-query"
            fi
            local resolver_arg=$(gost_resolver_arg "$dns_input")

            # 构建远程 URL
            local remote_url=""
            case "$remote_proto" in
                ws) remote_url="ws://${remote_host}:${remote_port}" ;;
                http+ws|socks5+ws)
                    remote_url="${remote_proto}://"
                    [ -n "$remote_user" ] && remote_url="${remote_url}${remote_user}:${remote_pass}@"
                    remote_url="${remote_url}${remote_host}:${remote_port}"
                    ;;
                ss+ws)
                    remote_url="ss+ws://${remote_ss_method}:${remote_ss_pass}@${remote_host}:${remote_port}"
                    ;;
            esac
            local params=(); [ -n "$path" ] && params+=("path=${path}")
            local query=$(build_query_string "${params[@]}")
            remote_url="${remote_url}${query}"

            local cmd=""
            is_v3 && cmd="$GOST_BIN $resolver_arg $local_listen -F \"$remote_url\"" || cmd="$GOST_BIN $local_listen -F \"$remote_url\""
            local info="链式代理: ${local_proto}://${local_listen_arg} -> ${remote_url}"
            start_gost_generic "$cmd" "$info"
            ;;
        2)
            configure_ssh "$local_listen" "$local_proto" "$local_listen_arg"
            ;;
        *)
            echo -e "${RED}无效${NC}"; return 1
            ;;
    esac
}

# ---------- 传统协议 ----------
start_gost_legacy() {
    local protocol=$1 port=$2 auth1=$3 auth2=$4 name=$5 dns_input=$6
    cd "$GOST_DIR" || return 1
    stop_gost

    local resolver_arg=$(gost_resolver_arg "$dns_input")
    local cmd="" proxy_url="" ip=$(get_local_ip)

    case $protocol in
        1) cmd="$GOST_BIN $resolver_arg -L http://${auth1}:${auth2}@:${port}"
           proxy_url="http://${auth1}:${auth2}@${ip}:${port}" ;;
        2) cmd="$GOST_BIN $resolver_arg -L socks5://${auth1}:${auth2}@:${port}"
           proxy_url="socks5://${auth1}:${auth2}@${ip}:${port}" ;;
        3) cmd="$GOST_BIN $resolver_arg -L ${auth1}:${auth2}@:${port}"
           proxy_url="http://${auth1}:${auth2}@${ip}:${port} / socks5://${auth1}:${auth2}@${ip}:${port}" ;;
        4) cmd="$GOST_BIN $resolver_arg -L ss://${auth1}:${auth2}@:${port}"
           local ss_link="${auth1}:${auth2}@${ip}:${port}"
           local ss64=""
           command -v base64 >/dev/null && ss64=$(echo -n "$ss_link" | base64 -w 0 2>/dev/null || echo -n "$ss_link" | base64) || ss64=$(echo -n "$ss_link" | openssl base64 -A)
           proxy_url="ss://${auth1}:${auth2}@${ip}:${port}"
           [ -n "$name" ] && proxy_url="${proxy_url}#${name}"
           local extra="ss://${ss64}"; [ -n "$name" ] && extra="${extra}#${name}"
           ;;
    esac
    [ -n "$dns_input" ] && proxy_url="${proxy_url} (DNS: ${dns_input})"

    echo "$cmd" > "$GOST_CMD_FILE"
    echo "=== GOST 启动于 $(date) ===" > "$GOST_LOG"
    echo "命令: $cmd" >> "$GOST_LOG"
    echo "信息: $proxy_url" >> "$GOST_LOG"
    eval "nohup $cmd >> \"$GOST_LOG\" 2>&1 &"
    local pid=$!
    echo $pid > "$GOST_PID_FILE"
    sleep 2
    if pgrep -f "$GOST_BIN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}\n${YELLOW}${proxy_url}${NC}"
        if [ "$protocol" -eq 4 ] && [ -n "$extra" ]; then
            echo -e "${GREEN}Base64:${NC}\n${YELLOW}${extra}${NC}"
            save_node_info "${proxy_url}"$'\n'"Base64: ${extra}"
        else
            save_node_info "$proxy_url"
        fi
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "PID: $pid 启动成功" >> "$GOST_LOG"
        return 0
    else
        echo -e "${RED}启动失败，查看日志: ${GOST_LOG}${NC}"
        return 1
    fi
}

# ---------- 配置入口 ----------
configure_proxy() {
    local skip_confirm=$1
    if [ ! -f "$GOST_BIN" ] || [ ! -x "$GOST_BIN" ]; then
        echo -e "${RED}未检测到 GOST，请先安装。${NC}"
        read -p "是否现在安装？[y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            select_version_to_install || { read -n 1 -p "按任意键返回..."; return 1; }
            [ ! -f "$GOST_BIN" ] && { read -n 1 -p "安装失败..."; return 1; }
        else
            read -n 1 -p "按任意键返回..."; return 1
        fi
    fi

    if [ "$skip_confirm" != "auto" ]; then
        local ver=$(get_installed_gost_version)
        echo -e "${GREEN}当前版本: ${ver}${NC}"
        if pgrep -f "$GOST_BIN" >/dev/null 2>&1; then
            echo -e "${YELLOW}运行中 PID: $(pgrep -f "$GOST_BIN" | head -1)，重新配置将停止旧进程。${NC}"
        fi
        read -p "是否重新配置？[y/N]: " ans
        [[ ! "$ans" =~ ^[Yy]$ ]] && { read -n 1 -p "按任意键返回..."; return 1; }
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "          配置代理"
    echo -e "${BLUE}========================================${NC}"
    echo -e " 1) HTTP"
    echo -e " 2) SOCKS5"
    echo -e " 3) 自适应"
    echo -e " 4) Shadowsocks"
    echo -e " 5) WebSocket"
    echo -e " 6) 链式代理"
    read -p "请选择 [1-6]: " protocol
    [[ ! "$protocol" =~ ^[1-6]$ ]] && protocol=3

    case $protocol in
        1|2|3|4)
            local port
            while true; do
                read -p "端口: " port
                [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] && break
                echo -e "${RED}无效端口${NC}"
            done
            local username="admin" password="123456" method="aes-256-gcm" node_name=""
            local dns_input=""
            read -p "自定义 DNS？[y/N]: " use_dns
            if [[ "$use_dns" =~ ^[Yy]$ ]]; then
                echo -e "格式: udp://8.8.8.8:53  tcp://8.8.8.8:53  tls://1.1.1.1:853  https://1.1.1.1/dns-query"
                read -p "DNS 地址: " dns_input; [ -z "$dns_input" ] && dns_input="https://1.1.1.1/dns-query"
            fi

            if [ "$protocol" -eq 4 ]; then
                echo -e "${BLUE}Shadowsocks 配置${NC}"
                local gost_ver=$(get_installed_gost_version)
                local ss_methods=() ss_names=()
                if version_ge "$gost_ver" "2.8.0"; then
                    ss_methods=("aes-256-gcm" "aes-128-gcm" "chacha20-ietf-poly1305")
                    ss_names=("aes-256-gcm (推荐)" "aes-128-gcm" "chacha20-ietf-poly1305 (推荐)")
                    echo -e "${GREEN}支持 AEAD 加密${NC}"
                else
                    echo -e "${RED}版本低于 2.8，不支持 SS，请升级。${NC}"; read -n 1 -p "按任意键返回..."; return 1
                fi
                for i in "${!ss_names[@]}"; do echo "  $((i+1))) ${ss_names[$i]}"; done
                read -p "加密方式 (默认 1): " mch; [ -z "$mch" ] && mch=1
                [[ "$mch" -ge 1 && "$mch" -le 3 ]] && method="${ss_methods[$((mch-1))]}" || method="aes-256-gcm"
                while true; do
                    read -p "密码 (默认 123456): " password; [ -z "$password" ] && password="123456"
                    [[ "$password" =~ [:@/] ]] && echo -e "${RED}含特殊字符${NC}" || break
                done
                read -p "节点名称 (默认 GOST-SS): " node_name; [ -z "$node_name" ] && node_name="GOST-SS"
                start_gost_legacy "$protocol" "$port" "$method" "$password" "$node_name" "$dns_input"
            else
                while true; do
                    read -p "账号 [admin]: " username; [ -z "$username" ] && username="admin"
                    read -p "密码 [123456]: " password; [ -z "$password" ] && password="123456"
                    [[ "$username" =~ [:@/] || "$password" =~ [:@/] ]] && echo -e "${RED}含特殊字符${NC}" || break
                done
                start_gost_legacy "$protocol" "$port" "$username" "$password" "" "$dns_input"
            fi
            ;;
        5) configure_websocket ;;
        6) configure_chain ;;
    esac

    read -p "开启开机自启？[y/N]: " auto_start
    [[ "$auto_start" =~ ^[Yy]$ ]] && enable_autostart
    read -n 1 -p "按任意键返回菜单..."
}

# ---------- 自启 ----------
enable_autostart() {
    local cron_now=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR")
    cat > "$GOST_DIR/keepalive.sh" << 'EOF'
#!/usr/bin/env bash
GOST_DIR="%GOST_DIR%"
cd "$GOST_DIR"
if [ -f gost.pid ] && kill -0 $(cat gost.pid) 2>/dev/null; then exit 0; fi
if ! pgrep -f "$GOST_DIR/gost" >/dev/null; then
    if [ -f start_cmd.txt ]; then
        cmd=$(cat start_cmd.txt)
        eval "nohup $cmd >> gost.log 2>&1 &"
        echo $! > gost.pid
    fi
fi
EOF
    sed -i "s|%GOST_DIR%|$GOST_DIR|" "$GOST_DIR/keepalive.sh"
    chmod +x "$GOST_DIR/keepalive.sh"
    (echo "$cron_now"; echo "@reboot $GOST_DIR/keepalive.sh"; echo "*/5 * * * * $GOST_DIR/keepalive.sh") | crontab -
    echo -e "${GREEN}✓ 已配置自启和保活${NC}"
}

# ---------- 卸载 ----------
uninstall_gost() {
    echo -e "${YELLOW}卸载 GOST...${NC}"
    stop_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab -
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# ---------- 状态/节点/日志 ----------
show_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "          系统状态"
    echo -e "${BLUE}========================================${NC}"
    echo -e "本机 IP: ${YELLOW}$(get_local_ip)${NC}"
    if [ -f "$GOST_BIN" ]; then
        echo -e "GOST: 已安装"
        echo -e "版本: $("$GOST_BIN" -V 2>&1 | head -1)"
        if pgrep -f "$GOST_BIN" >/dev/null 2>&1; then
            echo -e "状态: ${GREEN}运行中 ✓${NC}  PID: $(pgrep -f "$GOST_BIN" | head -1)"
        else
            echo -e "状态: ${RED}未运行 ✗${NC}"
        fi
    else
        echo -e "${RED}GOST 未安装${NC}"
    fi
    read -n 1 -p "按任意键返回..."
}

show_sub() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "          节点信息"
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$SUBFILE" ] && [ -s "$SUBFILE" ]; then
        echo -e "${YELLOW}$(cat "$SUBFILE")${NC}"
    else
        echo -e "${RED}暂无节点信息${NC}"
    fi
    read -n 1 -p "按任意键返回..."
}

view_log() {
    [ ! -f "$GOST_LOG" ] && { echo -e "${RED}日志文件不存在${NC}"; read -n 1 -p "按任意键返回..."; return; }
    read -p "显示行数 (默认 50): " lines
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=50
    tail -n "$lines" "$GOST_LOG"
    read -p "实时跟踪？[y/N]: " follow
    [[ "$follow" =~ ^[Yy]$ ]] && tail -f "$GOST_LOG" || read -n 1 -p "按任意键返回..."
}

update_script() {
    local url="https://raw.githubusercontent.com/goyo123321a/gost-manager/refs/heads/main/gost-manager.sh"
    local tmp="/tmp/gost-manager-update.sh"
    echo -e "${YELLOW}下载最新脚本...${NC}"
    if wget -q --timeout=30 -O "$tmp" "$url" 2>/dev/null || curl -fsSL --connect-timeout 30 "$url" -o "$tmp" 2>/dev/null; then
        if [ -s "$tmp" ]; then
            cp "$tmp" "$0" && chmod +x "$0" && rm -f "$tmp"
            echo -e "${GREEN}✓ 更新成功，请重新运行脚本。${NC}"
            read -n 1 -p "按任意键退出..."; exit 0
        fi
    fi
    echo -e "${RED}更新失败。${NC}"; read -n 1 -p "按任意键退出..."; exit 1
}

# ---------- 主菜单 ----------
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
    echo -e "${BLUE}║  ${GREEN}8${BLUE}) 查看日志                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    read -p "请输入 [0-8]: " choice
}

main() {
    detect_os_arch
    while true; do
        show_menu
        read choice
        case $choice in
            1) select_version_to_install
               if [ -f "$GOST_BIN" ]; then
                   read -p "是否配置代理？[Y/n]: " config_now
                   [[ -z "$config_now" || "$config_now" =~ ^[Yy]$ ]] && configure_proxy "auto"
               fi ;;
            2) configure_proxy ;;
            3) show_status ;;
            4) uninstall_gost; read -n 1 -p "按任意键返回..." ;;
            5) update_script ;;
            6) show_sub ;;
            7) stop_gost; read -n 1 -p "按任意键返回..." ;;
            8) view_log ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main
