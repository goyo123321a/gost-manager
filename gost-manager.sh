#!/usr/bin/env bash

# ============================================
# GOST 一键管理脚本（跨平台优化版）
# 支持 Linux / FreeBSD / macOS / Alpine
# ============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检测是否为 Alpine Linux
is_alpine() {
    [ -f /etc/alpine-release ] || command -v apk >/dev/null 2>&1
}

# 获取本机 IP（兼容多种网络工具）
get_local_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 addr show 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    fi
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep -E 'inet (addr:)?([0-9]+\.){3}[0-9]+' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d: -f2)
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    fi
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

# 检测系统类型和架构（增强 FreeBSD 支持）
detect_os_arch() {
    local kernel=$(uname -s)
    case "$kernel" in
        Linux)     os="linux" ;;
        FreeBSD)   os="freebsd" ;;
        Darwin)    os="darwin" ;;
        *)         os="linux" ;;
    esac

    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)           cpu_arch="amd64" ;;
        aarch64|arm64)          cpu_arch="arm64" ;;
        armv7l|armv7)           cpu_arch="armv7" ;;
        i386|i686)              cpu_arch="386" ;;
        *)                      cpu_arch="amd64" ;;
    esac

    echo -e "${GREEN}检测到系统: ${os} (${kernel}), 架构: ${cpu_arch}${NC}"
    if is_alpine; then
        echo -e "${YELLOW}提示: Alpine 系统请确保已安装 gcompat (apk add gcompat)${NC}"
    fi
}

# 工作目录设置（支持 root 和普通用户）
setup_workspace() {
    local CURRENT_USER=$(whoami)
    if [[ "$CURRENT_USER" == "root" ]]; then
        if [[ -n "$SUDO_USER" ]]; then
            WORK_HOME="/home/$SUDO_USER"
        elif [[ -n "$USER" ]] && [[ "$USER" != "root" ]]; then
            WORK_HOME="/home/$USER"
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
        echo -e "${YELLOW}使用备用目录: ${GOST_DIR}${NC}"
    }
    GOST_BIN="$GOST_DIR/gost"
    GOST_LOG="$GOST_DIR/gost.log"
    GOST_PID_FILE="$GOST_DIR/gost.pid"
    echo -e "${GREEN}工作目录: ${GOST_DIR}${NC}"
}

# 版本比较（>=2.12）
version_ge_2_12() {
    local v=$1
    local major=$(echo "$v" | cut -d. -f1)
    local minor=$(echo "$v" | cut -d. -f2)
    [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 12 ]; }
}

# 下载工具自动选择
download_file() {
    local url=$1
    local output=$2
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 -O "$output" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 "$url" -o "$output"
    else
        echo -e "${RED}错误: 未找到 wget 或 curl，请安装其中一个${NC}"
        return 1
    fi
}

# pgrep 兼容函数
my_pgrep() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$1"
    else
        ps aux | grep -E "$1" | grep -v grep | awk '{print $2}'
    fi
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q ":$port "
    elif command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":$port "
    else
        return 1
    fi
}

# 安装 GOST v2
install_gost_v2() {
    local version=$1
    mkdir -p "$GOST_DIR"
    echo -e "${YELLOW}[安装] GOST v2 ${version}...${NC}"
    cd "$GOST_DIR" || return 1
    rm -f gost gost.tar.gz gost.gz

    local downloaded=0

    # 新格式（>=2.12.0）
    if version_ge_2_12 "$version"; then
        local tar_url="https://github.com/ginuerzh/gost/releases/download/v${version}/gost_${version}_${os}_${cpu_arch}.tar.gz"
        echo -e "      尝试新格式: ${tar_url}"
        if download_file "$tar_url" "gost.tar.gz"; then
            if tar -xzf gost.tar.gz gost 2>/dev/null; then
                downloaded=1
                echo -e "${GREEN}      下载成功（新格式 .tar.gz）${NC}"
            fi
        fi
    fi

    # 旧格式 .gz
    if [ $downloaded -eq 0 ]; then
        echo -e "${YELLOW}      尝试旧格式 .gz...${NC}"
        local gz_urls=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-${os}-${cpu_arch}-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
        )
        [[ "$os" == "freebsd" ]] && gz_urls=("https://github.com/ginuerzh/gost/releases/download/v${version}/gost-freebsd-${cpu_arch}-${version}.gz" "${gz_urls[@]}")
        [[ "$cpu_arch" =~ ^armv[5-8]$ || "$cpu_arch" == "arm64" ]] && gz_urls+=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz"
        )
        for url in "${gz_urls[@]}"; do
            echo -e "      尝试: ${url}"
            if download_file "$url" "gost.gz" && gunzip -t gost.gz 2>/dev/null; then
                gunzip -f gost.gz
                downloaded=1
                echo -e "${GREEN}      下载成功（旧格式 .gz）${NC}"
                break
            fi
        done
    fi

    if [ $downloaded -eq 0 ]; then
        echo -e "${RED}所有下载方式均失败，请手动安装${NC}"
        return 1
    fi

    chmod +x gost
    if [ -x "$GOST_BIN" ]; then
        echo -e "${GREEN}✓ GOST v2 ${version} 安装成功！${NC}"
        "$GOST_BIN" -V 2>&1 | head -1
        return 0
    else
        echo -e "${RED}安装失败，可执行文件无效${NC}"
        return 1
    fi
}

# 安装 GOST v3
install_gost_v3() {
    local version=$1
    mkdir -p "$GOST_DIR"
    echo -e "${YELLOW}[安装] GOST v3 ${version}...${NC}"
    cd "$GOST_DIR" || return 1
    rm -f gost gost.tar.gz
    local clean_version="${version#v}"
    local download_url="https://github.com/go-gost/gost/releases/download/${version}/gost_${clean_version}_${os}_${cpu_arch}.tar.gz"
    echo -e "      下载地址: ${download_url}"
    if download_file "$download_url" "gost.tar.gz"; then
        tar -xzf gost.tar.gz gost 2>/dev/null
        chmod +x gost
        rm -f gost.tar.gz
        if [ -x "$GOST_BIN" ]; then
            echo -e "${GREEN}✓ GOST v3 ${version} 安装成功！${NC}"
            return 0
        fi
    fi
    echo -e "${RED}安装失败${NC}"
    return 1
}

# 停止 GOST
stop_gost() {
    local pids=$(my_pgrep "$GOST_BIN")
    if [ -n "$pids" ]; then
        echo -e "${YELLOW}停止现有 GOST 进程...${NC}"
        kill $pids 2>/dev/null
        sleep 1
        echo -e "${GREEN}✓ 已停止${NC}"
    fi
    [ -f "$GOST_PID_FILE" ] && rm -f "$GOST_PID_FILE"
}

# 启动代理
start_gost() {
    local protocol=$1
    local port=$2
    local username=$3
    local password=$4

    cd "$GOST_DIR" || return 1

    # 检查端口是否被占用
    if check_port "$port"; then
        echo -e "${RED}端口 ${port} 已被占用，请更换端口${NC}"
        return 1
    fi

    stop_gost

    local cmd=""
    local proxy_url=""
    local ip=$(get_local_ip)

    case $protocol in
        1)
            cmd="$GOST_BIN -L http://${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 HTTP 代理...${NC}"
            ;;
        2)
            cmd="$GOST_BIN -L socks5://${username}:${password}@:${port}"
            proxy_url="socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 SOCKS5 代理...${NC}"
            ;;
        3)
            cmd="$GOST_BIN -L ${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port} / socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动自适应代理...${NC}"
            ;;
        4)
            cmd="$GOST_BIN -L :${port}"
            proxy_url="${ip}:${port} (无加密)"
            echo -e "${GREEN}启动无加密代理...${NC}"
            ;;
    esac

    echo -e "${YELLOW}执行命令: $cmd${NC}"
    nohup $cmd > "$GOST_LOG" 2>&1 &
    local pid=$!
    echo $pid > "$GOST_PID_FILE"

    sleep 2
    if kill -0 $pid 2>/dev/null && my_pgrep "$GOST_BIN" | grep -q "$pid"; then
        echo -e "${GREEN}✓ 代理运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}"
        echo -e "${YELLOW}${proxy_url}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        echo -e "${RED}启动失败，错误日志（最后5行）：${NC}"
        tail -5 "$GOST_LOG" 2>/dev/null || echo "无法读取日志文件"
        return 1
    fi
}

# 开启自启（crontab + 保活脚本）
enable_autostart() {
    local current_cron=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR/gost")
    cat > "$GOST_DIR/keepalive.sh" << EOF
#!/usr/bin/env bash
GOST_DIR="$GOST_DIR"
cd "\$GOST_DIR"
if [ -f "gost.pid" ] && kill -0 "\$(cat gost.pid)" 2>/dev/null; then
    exit 0
fi
if ! ps aux | grep -E "\$GOST_DIR/gost" | grep -v grep >/dev/null; then
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
    echo -e "${GREEN}✓ 已配置开机自启和进程保活（每5分钟检查）${NC}"
}

# 卸载
uninstall_gost() {
    echo -e "${YELLOW}正在卸载 GOST...${NC}"
    stop_gost
    crontab -l 2>/dev/null | grep -v "$GOST_DIR" | crontab -
    rm -rf "$GOST_DIR"
    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 配置代理流程
configure_proxy() {
    [ ! -f "$GOST_BIN" ] && echo -e "${RED}请先安装 GOST${NC}" && return 1

    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          配置代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    while true; do
        read -p "$(echo -e "${YELLOW}请输入端口: ${NC}")" port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done

    echo -e "${BLUE}请选择协议:${NC}"
    echo -e "  ${GREEN}1${NC}) HTTP"
    echo -e "  ${GREEN}2${NC}) SOCKS5"
    echo -e "  ${GREEN}3${NC}) 自适应 (HTTP/SOCKS5 自动识别)"
    echo -e "  ${GREEN}4${NC}) 无加密自适应"
    read -p "$(echo -e "${YELLOW}请输入 [1-4]: ${NC}")" protocol
    [[ ! "$protocol" =~ ^[1-4]$ ]] && protocol=3

    local username="admin"
    local password="123456"
    if [ "$protocol" -ne 4 ]; then
        echo -e "${BLUE}账号密码 (默认 admin/123456)${NC}"
        read -p "$(echo -e "${YELLOW}账号 [admin]: ${NC}")" input_user
        [ -n "$input_user" ] && username="$input_user"
        read -p "$(echo -e "${YELLOW}密码 [123456]: ${NC}")" input_pass
        [ -n "$input_pass" ] && password="$input_pass"
    fi

    start_gost "$protocol" "$port" "$username" "$password" || return 1

    read -p "$(echo -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}")" auto_start
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        enable_autostart
    fi

    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回菜单...${NC}")"
    echo
}

# 显示状态
show_status() {
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$GOST_BIN" ]; then
        local version_info=$("$GOST_BIN" -V 2>&1 | head -1)
        echo -e "${GREEN}GOST 状态: 已安装${NC}"
        echo -e "${GREEN}版本信息: ${version_info}${NC}"
        echo -e "${GREEN}安装路径: ${GOST_BIN}${NC}"
        local pids=$(my_pgrep "$GOST_BIN")
        if [ -n "$pids" ]; then
            echo -e "${GREEN}代理状态: 运行中 ✓ (PID: $pids)${NC}"
        else
            echo -e "${RED}代理状态: 未运行 ✗${NC}"
        fi
    else
        echo -e "${RED}GOST 状态: 未安装${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回菜单...${NC}")"
    echo
}

# 更新脚本
update_script() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          更新脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    local script_url="https://raw.githubusercontent.com/goyo123321a/gost-manager/refs/heads/main/gost-manager.sh"
    local temp_script="/tmp/gost-manager-update.sh"
    echo -e "${YELLOW}正在下载最新脚本...${NC}"
    if download_file "$script_url" "$temp_script" && [ -s "$temp_script" ]; then
        cp "$temp_script" "$0"
        chmod +x "$0"
        rm -f "$temp_script"
        echo -e "${GREEN}✓ 脚本更新成功！请重新运行脚本。${NC}"
        exit 0
    else
        echo -e "${RED}更新失败，请检查网络${NC}"
    fi
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回菜单...${NC}")"
    echo
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
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    read -p "$(echo -e "${YELLOW}请输入 [0-5]: ${NC}")" choice
    echo "$choice"
}

# 获取版本列表的子菜单
get_v2_versions() {
    echo -e "${BLUE}获取 GOST v2 版本列表...${NC}"
    local versions=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ginuerzh/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -10)
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}无法获取远程列表，使用本地列表${NC}"
        versions="2.12.0 2.11.5 2.11.4 2.11.3 2.11.2 2.11.1 2.11.0 2.10.0 2.9.2"
    fi
    echo -e "${GREEN}可用的 GOST v2 版本:${NC}"
    select version in $versions "返回上级"; do
        if [[ "$version" == "返回上级" ]]; then
            return 1
        elif [[ -n "$version" ]]; then
            install_gost_v2 "$version"
            return $?
        else
            echo -e "${RED}无效选择${NC}"
        fi
    done
}

get_v3_versions() {
    echo -e "${BLUE}获取 GOST v3 版本列表...${NC}"
    local versions=$(curl -s "https://api.github.com/repos/go-gost/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"(v[^"]+)".*/\1/' | head -10)
    if [[ -z "$versions" ]]; then
        versions="v3.2.6 v3.2.5 v3.2.4 v3.2.3 v3.2.2"
    fi
    echo -e "${GREEN}可用的 GOST v3 版本:${NC}"
    select version in $versions "返回上级"; do
        if [[ "$version" == "返回上级" ]]; then
            return 1
        elif [[ -n "$version" ]]; then
            install_gost_v3 "$version"
            return $?
        else
            echo -e "${RED}无效选择${NC}"
        fi
    done
}

select_version_to_install() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       选择 GOST 版本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  ${GREEN}1${NC}) GOST v2 (稳定版)"
    echo -e "  ${GREEN}2${NC}) GOST v3 (最新版)"
    echo -e "  ${GREEN}0${NC}) 返回主菜单"
    echo -e "${BLUE}========================================${NC}"
    read -p "$(echo -e "${YELLOW}请选择 [0-2]: ${NC}")" choice
    case $choice in
        1) get_v2_versions ;;
        2) get_v3_versions ;;
        0) return 1 ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
}

# 主程序
main() {
    detect_os_arch
    setup_workspace
    while true; do
        choice=$(show_menu)
        case $choice in
            1) if select_version_to_install && [ -f "$GOST_BIN" ]; then
                   read -p "$(echo -e "${GREEN}是否配置代理？[y/N]: ${NC}")" config_now
                   [[ "$config_now" =~ ^[Yy]$ ]] && configure_proxy
               fi ;;
            2) configure_proxy ;;
            3) show_status ;;
            4) uninstall_gost; read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回菜单...${NC}")"; echo ;;
            5) update_script ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main
