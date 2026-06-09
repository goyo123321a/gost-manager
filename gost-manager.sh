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

# 工作目录设置
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

get_gost_version() {
    if [ ! -f "$GOST_BIN" ]; then
        echo "0.0.0"
        return
    fi
    local ver=$("$GOST_BIN" -V 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$ver" ] && echo "0.0.0" || echo "$ver"
}

version_ge() {
    local v1=$1 v2=$2
    [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" != "$v1" ]
}

version_ge_2_12() {
    local v=$1
    local major=$(echo "$v" | cut -d. -f1)
    local minor=$(echo "$v" | cut -d. -f2)
    if [ "$major" -gt 2 ]; then return 0; fi
    if [ "$major" -lt 2 ]; then return 1; fi
    [ "$minor" -ge 12 ]
}

# 安装 v2
install_gost_v2() {
    local version=$1
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
        echo -e "${YELLOW}      尝试旧格式 .gz...${NC}"
        local gz_urls=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-${os}-${cpu_arch}-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
        )
        if [[ "$os" == "linux" ]]; then
            case "$cpu_arch" in
                amd64) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz") ;;
                arm64) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz" "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-arm64-${version}.gz") ;;
                armv7) gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv7-${version}.gz") ;;
                386)   gz_urls+=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-386-${version}.gz") ;;
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

# 安装 v3
install_gost_v3() {
    local version=$1
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
    echo -e "${BLUE}获取 GOST v2 版本列表...${NC}"
    local versions=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ginuerzh/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -10)
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}无法获取远程列表，使用本地列表${NC}"
        versions="2.12.0 2.11.5 2.11.4 2.11.3 2.11.2 2.11.1 2.11.0 2.10.0 2.9.2"
    fi
    local version_array=($versions)
    local version_count=${#version_array[@]}
    echo -e "${GREEN}可用的 GOST v2 版本:${NC}"
    for i in "${!version_array[@]}"; do echo "  $((i+1))) ${version_array[$i]}"; done
    echo "  $((version_count+1))) 返回上级"
    echo -n -e "${YELLOW}请输入版本数字 (默认 1): ${NC}"
    read choice
    [[ -z "$choice" ]] && choice=1
    if [[ "$choice" -eq $((version_count+1)) ]]; then return 1
    elif [[ "$choice" -ge 1 && "$choice" -le "$version_count" ]]; then
        install_gost_v2 "${version_array[$((choice-1))]}"
        return $?
    else echo -e "${RED}无效选择${NC}"; return 1; fi
}

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
    for i in "${!version_array[@]}"; do echo "  $((i+1))) ${version_array[$i]}"; done
    echo "  $((version_count+1))) 返回上级"
    echo -n -e "${YELLOW}请输入版本数字 (默认 1): ${NC}"
    read choice
    [[ -z "$choice" ]] && choice=1
    if [[ "$choice" -eq $((version_count+1)) ]]; then return 1
    elif [[ "$choice" -ge 1 && "$choice" -le "$version_count" ]]; then
        install_gost_v3 "${version_array[$((choice-1))]}"
        return $?
    else echo -e "${RED}无效选择${NC}"; return 1; fi
}

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

stop_gost() {
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}停止现有 GOST 进程...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
        sleep 1
        echo -e "${GREEN}✓ 已停止${NC}"
    fi
    [ -f "$GOST_PID_FILE" ] && rm -f "$GOST_PID_FILE"
}

save_node_info() {
    local info="$1"
    echo "$info" > "$SUBFILE"
    echo -e "${GREEN}节点信息已保存到: ${SUBFILE}${NC}"
}

# 测试代理连接
test_proxy_connection() {
    local proto=$1
    local port=$2
    local auth=$3
    echo -e "${BLUE}正在测试代理连接...${NC}"
    sleep 2
    local test_url="https://ip.sb"
    local curl_cmd="curl -s --connect-timeout 10 --max-time 15"
    case $proto in
        http)
            if [ -n "$auth" ]; then
                curl_cmd="$curl_cmd --proxy http://$auth@127.0.0.1:$port"
            else
                curl_cmd="$curl_cmd --proxy http://127.0.0.1:$port"
            fi
            ;;
        socks5)
            if [ -n "$auth" ]; then
                curl_cmd="$curl_cmd --socks5 127.0.0.1:$port --proxy-user $auth"
            else
                curl_cmd="$curl_cmd --socks5 127.0.0.1:$port"
            fi
            ;;
        *)
            echo -e "${YELLOW}不支持自动测试该协议${NC}"
            return
            ;;
    esac
    echo -e "${YELLOW}测试请求中...${NC}"
    local result=$($curl_cmd "$test_url" 2>/dev/null)
    if [ -n "$result" ]; then
        echo -e "${GREEN}✓ 代理工作正常，出口 IP: ${result}${NC}"
    else
        echo -e "${RED}✗ 代理连接测试失败，请检查日志: ${GOST_LOG}${NC}"
    fi
}

# 启动代理（支持服务端和客户端，支持路径）
start_gost() {
    local mode=$1 port=$2 proto=$3 auth1=$4 auth2=$5 forward=$6 ws_path=$7
    cd "$GOST_DIR" || return 1
    stop_gost
    local cmd=""
    local proxy_url=""
    local ip=$(get_local_ip)

    if [ "$mode" = "server" ]; then
        case $proto in
            1) cmd="$GOST_BIN -L http://${auth1}:${auth2}@:${port}"
               proxy_url="http://${auth1}:${auth2}@${ip}:${port}"
               echo -e "${GREEN}启动 HTTP 代理...${NC}" ;;
            2) cmd="$GOST_BIN -L socks5://${auth1}:${auth2}@:${port}"
               proxy_url="socks5://${auth1}:${auth2}@${ip}:${port}"
               echo -e "${GREEN}启动 SOCKS5 代理...${NC}" ;;
            3) cmd="$GOST_BIN -L ${auth1}:${auth2}@:${port}"
               proxy_url="http://${auth1}:${auth2}@${ip}:${port} / socks5://${auth1}:${auth2}@${ip}:${port}"
               echo -e "${GREEN}启动自适应代理...${NC}" ;;
            4) cmd="$GOST_BIN -L ss://${auth1}:${auth2}@:${port}"
               ss_link="${auth1}:${auth2}@${ip}:${port}"
               if command -v base64 >/dev/null 2>&1; then
                   ss_base64=$(echo -n "$ss_link" | base64 -w 0 2>/dev/null || echo -n "$ss_link" | base64)
               else
                   ss_base64=$(echo -n "$ss_link" | openssl base64 -A 2>/dev/null)
               fi
               proxy_url="ss://${auth1}:${auth2}@${ip}:${port}"
               proxy_url_extra="ss://${ss_base64}"
               echo -e "${GREEN}启动 Shadowsocks 代理...${NC}" ;;
            5) local listen_addr="ws://:${port}"
               [ -n "$ws_path" ] && listen_addr="ws://:${port}?path=${ws_path}"
               cmd="$GOST_BIN -L ${listen_addr}"
               proxy_url="ws://${ip}:${port}"
               [ -n "$ws_path" ] && proxy_url="${proxy_url}?path=${ws_path}"
               echo -e "${GREEN}启动 WebSocket 代理（无认证）...${NC}" ;;
            6) local listen_addr="relay+ws://${auth1}:${auth2}@:${port}"
               [ -n "$ws_path" ] && listen_addr="relay+ws://${auth1}:${auth2}@:${port}?path=${ws_path}"
               cmd="$GOST_BIN -L ${listen_addr}"
               proxy_url="relay+ws://${auth1}:${auth2}@${ip}:${port}"
               [ -n "$ws_path" ] && proxy_url="${proxy_url}?path=${ws_path}"
               echo -e "${GREEN}启动 Relay+WebSocket 代理（带认证）...${NC}" ;;
            7) cmd="$GOST_BIN -L relay://${auth1}:${auth2}@:${port}"
               proxy_url="relay://${auth1}:${auth2}@${ip}:${port}"
               echo -e "${GREEN}启动 Relay 代理（纯转发，带认证）...${NC}" ;;
        esac
        save_node_info "$proxy_url"
        [ -n "$proxy_url_extra" ] && proxy_url="$proxy_url_extra"
    else
        local local_proto="$proto"
        local local_auth="$auth1"
        local forward_addr="$forward"
        if [ -n "$local_auth" ]; then
            cmd="$GOST_BIN -L ${local_proto}://${local_auth}@:${port} -F ${forward_addr}"
            proxy_url="${local_proto}://${local_auth}@${ip}:${port} -> ${forward_addr}"
        else
            cmd="$GOST_BIN -L ${local_proto}://:${port} -F ${forward_addr}"
            proxy_url="${local_proto}://${ip}:${port} -> ${forward_addr}"
        fi
        echo -e "${GREEN}启动客户端链式代理 (${local_proto} -> ${forward_addr})${NC}"
        save_node_info "$proxy_url"
    fi

    nohup $cmd > "$GOST_LOG" 2>&1 &
    local pid=$!
    echo $pid > "$GOST_PID_FILE"
    sleep 2
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 代理运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}"
        echo -e "${YELLOW}${proxy_url}${NC}"
        [ -n "$proxy_url_extra" ] && echo -e "${GREEN}Base64 编码:${NC}\n${YELLOW}${proxy_url_extra}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        echo -e "${RED}启动失败，请检查日志: ${GOST_LOG}${NC}"
        return 1
    fi
}

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
        nohup \$cmd > gost.log 2>&1 &
        echo \$! > gost.pid
    fi
fi
EOF
    chmod +x "$GOST_DIR/keepalive.sh"
    local running_cmd=$(ps -ef | grep "$GOST_BIN" | grep -v grep | head -1 | sed 's/.*\.\/gost/\.\/gost/')
    [ -n "$running_cmd" ] && echo "$running_cmd" > "$GOST_DIR/start_cmd.txt"
    (echo "$current_cron"; echo "@reboot $GOST_DIR/keepalive.sh"; echo "*/5 * * * * $GOST_DIR/keepalive.sh") | crontab -
    echo -e "${GREEN}✓ 已配置开机自启和进程保活${NC}"
}

uninstall_gost() {
    echo -e "${YELLOW}正在卸载 GOST...${NC}"
    stop_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab -
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 配置服务端
configure_server() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       配置服务端（本地代理）${NC}"
    echo -e "${BLUE}========================================${NC}"
    while true; do
        echo -n -e "${YELLOW}请输入监听端口: ${NC}"
        read port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口无效${NC}"
        fi
    done
    echo -e "${BLUE}请选择协议:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应 (HTTP/SOCKS5 自动识别)"
    echo -e "  ${GREEN}4${NC}) Shadowsocks"
    echo -e "  ${GREEN}5${NC}) WebSocket (WS，无认证)"
    echo -e "  ${GREEN}6${NC}) Relay+WebSocket (relay+ws，带认证)"
    echo -e "  ${GREEN}7${NC}) Relay (纯转发，带认证)"
    echo -n -e "${YELLOW}请输入 [1-7]: ${NC}"
    read protocol
    [[ ! "$protocol" =~ ^[1-7]$ ]] && protocol=3

    local username="admin" password="123456" method="aes-256-gcm" node_name="" ws_path=""
    if [ "$protocol" -eq 5 ] || [ "$protocol" -eq 6 ]; then
        echo -n -e "${YELLOW}是否设置 WebSocket 路径？[y/N]: ${NC}"
        read set_path
        if [[ "$set_path" =~ ^[Yy]$ ]]; then
            echo -n -e "${YELLOW}请输入路径 (默认 /ws): ${NC}"
            read input_path
            ws_path="${input_path:-/ws}"
        fi
    fi

    if [ "$protocol" -eq 4 ]; then
        echo -e "${BLUE}Shadowsocks 配置${NC}"
        local gost_ver=$(get_gost_version)
        local ss_methods=() ss_method_names=()
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
            echo -e "${RED}❌ 当前版本低于 2.8.0，不支持 Shadowsocks 协议。${NC}"
            echo -n -e "${GREEN}按任意键返回...${NC}"; read -n 1; return 1
        fi
        echo -e "${YELLOW}请选择加密方式:${NC}"
        for i in "${!ss_method_names[@]}"; do echo "  $((i+1))) ${ss_method_names[$i]}"; done
        echo -n -e "${YELLOW}请输入 [1-${#ss_method_names[@]}] (默认 1): ${NC}"
        read method_choice
        method_choice="${method_choice:-1}"
        if [[ "$method_choice" -ge 1 && "$method_choice" -le ${#ss_methods[@]} ]]; then
            method="${ss_methods[$((method_choice-1))]}"
        else
            method="aes-256-gcm"
        fi
        echo -e "${GREEN}已选择加密方式: ${method}${NC}"
        echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"
        read input_pass; [ -n "$input_pass" ] && password="$input_pass"
        echo -n -e "${YELLOW}节点名称 (默认 GOST-SS): ${NC}"
        read input_name; node_name="${input_name:-GOST-SS}"
        start_gost "server" "$port" "$protocol" "$method" "$password" "" "$ws_path"
    elif [ "$protocol" -eq 5 ]; then
        start_gost "server" "$port" "$protocol" "" "" "" "$ws_path"
    elif [ "$protocol" -eq 6 ]; then
        echo -e "${BLUE}Relay+WebSocket 需要认证${NC}"
        echo -n -e "${YELLOW}用户名 (默认 admin): ${NC}"; read input_user; [ -n "$input_user" ] && username="$input_user"
        echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"; read input_pass; [ -n "$input_pass" ] && password="$input_pass"
        start_gost "server" "$port" "$protocol" "$username" "$password" "" "$ws_path"
    elif [ "$protocol" -eq 7 ]; then
        echo -e "${BLUE}Relay 协议需要认证${NC}"
        echo -n -e "${YELLOW}用户名 (默认 admin): ${NC}"; read input_user; [ -n "$input_user" ] && username="$input_user"
        echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"; read input_pass; [ -n "$input_pass" ] && password="$input_pass"
        start_gost "server" "$port" "$protocol" "$username" "$password"
    else
        echo -e "${BLUE}账号密码 (默认 admin/123456)${NC}"
        echo -n -e "${YELLOW}账号 [admin]: ${NC}"; read input_user; [ -n "$input_user" ] && username="$input_user"
        echo -n -e "${YELLOW}密码 [123456]: ${NC}"; read input_pass; [ -n "$input_pass" ] && password="$input_pass"
        start_gost "server" "$port" "$protocol" "$username" "$password"
    fi
}

# 客户端配置（支持 wss 和 relay+wss）
configure_client() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       配置客户端（链式代理）${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    echo -e "${BLUE}请选择本地监听协议:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read local_proto_choice
    local_proto="$([ "$local_proto_choice" = "1" ] && echo "http" || echo "socks5")"
    
    while true; do
        echo -n -e "${YELLOW}请输入本地监听端口: ${NC}"
        read port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then break
        else echo -e "${RED}端口无效${NC}"; fi
    done
    
    echo -n -e "${YELLOW}是否为本地代理添加认证？[y/N]: ${NC}"
    read need_auth
    local auth_str=""
    if [[ "$need_auth" =~ ^[Yy]$ ]]; then
        echo -n -e "${YELLOW}用户名 (默认 admin): ${NC}"; read user; user="${user:-admin}"
        echo -n -e "${YELLOW}密码 (默认 123456): ${NC}"; read pass; pass="${pass:-123456}"
        auth_str="${user}:${pass}"
    fi
    
    echo -e "${BLUE}请选择上级代理协议:${NC}"
    echo -e "  ${GREEN}1${NC}) WebSocket (ws，无认证)"
    echo -e "  ${GREEN}2${NC}) Relay+WebSocket (relay+ws，带认证)"
    echo -e "  ${GREEN}3${NC}) Relay (纯转发，带认证)"
    echo -e "  ${GREEN}4${NC}) WebSocket Secure (wss，无认证)"
    echo -e "  ${GREEN}5${NC}) Relay+WebSocket Secure (relay+wss，带认证)"
    echo -n -e "${YELLOW}请输入 [1-5]: ${NC}"
    read remote_proto_choice
    case $remote_proto_choice in
        1) remote_proto="ws"; need_remote_auth_hint=0 ;;
        2) remote_proto="relay+ws"; need_remote_auth_hint=1 ;;
        3) remote_proto="relay"; need_remote_auth_hint=1 ;;
        4) remote_proto="wss"; need_remote_auth_hint=0 ;;
        5) remote_proto="relay+wss"; need_remote_auth_hint=1 ;;
        *) echo -e "${RED}无效选择，默认使用 ws${NC}"; remote_proto="ws"; need_remote_auth_hint=0 ;;
    esac
    
    echo -n -e "${YELLOW}请输入远程服务器地址 (IP或域名): ${NC}"
    read raw_host
    raw_host=$(echo "$raw_host" | tr -d ' ')  # 去除空格
    remote_host="$raw_host"
    remote_port=""
    if [[ "$raw_host" =~ :[0-9]+$ ]]; then
        remote_host="${raw_host%:*}"
        remote_port="${raw_host##*:}"
    fi
    if [ -z "$remote_port" ]; then
        if [ "$remote_proto" = "wss" ] || [ "$remote_proto" = "relay+wss" ]; then
            echo -n -e "${YELLOW}请输入远程端口 (默认 443): ${NC}"
            read remote_port
            remote_port="${remote_port:-443}"
        else
            echo -n -e "${YELLOW}请输入远程端口: ${NC}"
            read remote_port
        fi
        if [[ -z "$remote_port" ]]; then echo -e "${RED}端口不能为空${NC}"; return 1; fi
    fi
    if [[ -z "$remote_host" ]]; then echo -e "${RED}地址不能为空${NC}"; return 1; fi
    
    # 远程路径
    local remote_path=""
    if [[ "$remote_proto" =~ ^(ws|relay\+ws|wss|relay\+wss)$ ]]; then
        echo -n -e "${YELLOW}是否设置远程 WebSocket 路径？[y/N]: ${NC}"
        read set_remote_path
        if [[ "$set_remote_path" =~ ^[Yy]$ ]]; then
            echo -n -e "${YELLOW}请输入路径 (默认 /ws): ${NC}"
            read input_path
            remote_path="${input_path:-/ws}"
        fi
    fi
    
    # 构建转发地址
    remote_addr="${remote_proto}://${remote_host}:${remote_port}"
    [ -n "$remote_path" ] && remote_addr="${remote_addr}?path=${remote_path}"
    
    if [ $need_remote_auth_hint -eq 1 ]; then
        echo -e "${BLUE}远程协议 ${remote_proto} 需要认证${NC}"
        echo -n -e "${YELLOW}远程认证用户名: ${NC}"; read remote_user
        echo -n -e "${YELLOW}远程认证密码: ${NC}"; read -s remote_pass; echo
        remote_addr="${remote_proto}://${remote_user}:${remote_pass}@${remote_host}:${remote_port}"
        [ -n "$remote_path" ] && remote_addr="${remote_addr}?path=${remote_path}"
    fi
    
    echo -e "${GREEN}最终转发地址: ${remote_addr}${NC}"
    start_gost "client" "$port" "$local_proto" "$auth_str" "" "$remote_addr"
    
    # 测试连接（仅当本地协议为 http 或 socks5 时）
    if [[ "$local_proto" == "http" || "$local_proto" == "socks5" ]]; then
        echo -n -e "${YELLOW}是否测试代理连接？[y/N]: ${NC}"
        read test_choice
        if [[ "$test_choice" =~ ^[Yy]$ ]]; then
            test_proxy_connection "$local_proto" "$port" "$auth_str"
        fi
    else
        echo -e "${YELLOW}当前协议不支持自动测试，请手动验证。${NC}"
    fi
}

# 统一配置入口
configure_proxy() {
    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${RED}请先安装 GOST${NC}"
        return 1
    fi
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       选择运行模式${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  ${GREEN}1${NC}) 服务端（提供代理服务）"
    echo -e "  ${GREEN}2${NC}) 客户端（连接上级代理）"
    echo -n -e "${YELLOW}请输入 [1-2]: ${NC}"
    read mode_choice
    case $mode_choice in
        1) configure_server ;;
        2) configure_client ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
    echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
    read auto_start
    [[ "$auto_start" =~ ^[Yy]$ ]] && enable_autostart
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1
}

show_status() {
    echo -e "${BLUE}========================================${NC}"
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
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1
}

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
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1
}

update_script() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          更新脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    local script_url="https://raw.githubusercontent.com/goyo123321a/gost-manager/refs/heads/main/gost-manager.sh"
    local temp_script="/tmp/gost-manager-update.sh"
    echo -e "${YELLOW}正在从远程仓库下载最新脚本...${NC}"
    if wget -q --timeout=10 -O "$temp_script" "$script_url" 2>/dev/null || curl -fsSL --connect-timeout 10 "$script_url" -o "$temp_script" 2>/dev/null; then
        if [ -s "$temp_script" ]; then
            cp "$temp_script" "$0"
            chmod +x "$0"
            rm -f "$temp_script"
            echo -e "${GREEN}✓ 脚本更新成功！${NC}"
            echo -e "${YELLOW}请重新运行脚本以使用新版本。${NC}"
            echo -e "${YELLOW}快速命令: ${GREEN}~/gost-manager.sh${NC} 或 ${GREEN}bash ~/gost-manager.sh${NC}"
            echo -n -e "${GREEN}按任意键退出...${NC}"; read -n 1
            exit 0
        else
            echo -e "${RED}下载的文件为空，更新失败${NC}"
        fi
    else
        echo -e "${RED}下载失败，请检查网络连接${NC}"
    fi
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1
}

show_menu() {
    echo
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        GOST 一键管理脚本            ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${GREEN}1${BLUE}) 安装 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}2${BLUE}) 配置代理（服务端/客户端）        ║${NC}"
    echo -e "${BLUE}║  ${GREEN}3${BLUE}) 查看状态                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}4${BLUE}) 卸载 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}5${BLUE}) 更新脚本                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}6${BLUE}) 查看节点信息                   ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-6]: ${NC}"
}

main() {
    detect_os_arch
    while true; do
        show_menu
        read choice
        case $choice in
            1) if select_version_to_install && [ -f "$GOST_BIN" ]; then
                   echo -n -e "${GREEN}是否配置代理？[Y/n]: ${NC}"
                   read config_now
                   [[ -z "$config_now" || "$config_now" =~ ^[Yy]$ ]] && configure_proxy
               fi ;;
            2) configure_proxy ;;
            3) show_status ;;
            4) uninstall_gost; echo -n -e "${GREEN}按任意键返回菜单...${NC}"; read -n 1 ;;
            5) update_script ;;
            6) show_sub ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main
