#!/usr/bin/env bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 获取本机 IP（兼容 BusyBox，不使用 -P）
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

# 自动检测并设置工作目录（root / 普通用户均可）
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
            echo -e "${YELLOW}检测到 root 用户，使用: ${WORK_HOME}${NC}"
        else
            WORK_HOME="$PWD"
        fi
    else
        WORK_HOME="$HOME"
    fi
    
    GOST_DIR="$WORK_HOME/GOST"
    
    if [[ ! -d "$GOST_DIR" ]]; then
        echo -e "${YELLOW}创建目录: ${GOST_DIR}${NC}"
        mkdir -p "$GOST_DIR" 2>/dev/null || {
            GOST_DIR="/tmp/GOST_${CURRENT_USER}"
            mkdir -p "$GOST_DIR"
            echo -e "${YELLOW}使用备用目录: ${GOST_DIR}${NC}"
        }
    fi
    
    GOST_BIN="$GOST_DIR/gost"
    GOST_LOG="$GOST_DIR/gost.log"
    GOST_PID_FILE="$GOST_DIR/gost.pid"
    
    echo -e "${GREEN}工作目录: ${GOST_DIR}${NC}"
}

setup_workspace

# 检测系统架构
detect_os_arch() {
    if [[ "$(uname)" == "Linux" ]]; then
        os="linux"
    elif [[ "$(uname)" == "Darwin" ]]; then
        os="darwin"
    else
        os="linux"
    fi

    arch=$(uname -m)
    case $arch in
        x86_64|amd64) cpu_arch="amd64" ;;
        aarch64|arm64) cpu_arch="arm64" ;;
        armv7l|armv7) cpu_arch="armv7" ;;
        i686|i386) cpu_arch="386" ;;
        *) cpu_arch="amd64" ;;
    esac
}

# 安装 GOST v2（支持 v2.12.0）
install_gost_v2() {
    local version=$1
    
    mkdir -p "$GOST_DIR"
    echo -e "${YELLOW}[安装] GOST v2 ${version}...${NC}"
    
    cd "$GOST_DIR" || { 
        echo -e "${RED}无法进入目录: $GOST_DIR${NC}"
        return 1
    }
    
    rm -f gost gost.gz
    
    # v2 官方可能的文件名列表（包含 armv8 等常见命名）
    local download_urls=(
        "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz"
        "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz"
        "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-${cpu_arch}-${version}.gz"
        "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-${os}-${cpu_arch}-${version}.gz"
    )
    
    # 针对 arm64 再补充一个常见命名
    if [[ "$cpu_arch" == "arm64" ]]; then
        download_urls=(
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-armv8-${version}.gz"
            "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-arm64-${version}.gz"
            "${download_urls[@]}"
        )
    fi
    
    local downloaded=0
    for url in "${download_urls[@]}"; do
        echo -e "      尝试: ${url}"
        if wget -q --timeout=15 -O gost.gz "$url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$url" -o gost.gz 2>/dev/null; then
            if [ -f "gost.gz" ] && [ -s "gost.gz" ] && gunzip -t gost.gz 2>/dev/null; then
                echo -e "${GREEN}      下载成功！${NC}"
                gunzip -f gost.gz
                downloaded=1
                break
            fi
        fi
    done
    
    if [ $downloaded -eq 0 ]; then
        echo -e "${RED}下载失败，请手动安装${NC}"
        return 1
    fi
    
    chmod +x gost
    if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
        echo -e "${GREEN}✓ GOST v2 ${version} 安装成功！${NC}"
        return 0
    else
        echo -e "${RED}安装失败${NC}"
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
    if wget -q --timeout=15 -O gost.tar.gz "$download_url" 2>/dev/null || curl -fsSL --connect-timeout 15 "$download_url" -o gost.tar.gz 2>/dev/null; then
        tar -xzf gost.tar.gz gost 2>/dev/null || tar -xzf gost.tar.gz
        chmod +x gost
        rm -f gost.tar.gz
        if [ -f "$GOST_BIN" ] && [ -x "$GOST_BIN" ]; then
            echo -e "${GREEN}✓ GOST v3 ${version} 安装成功！${NC}"
            return 0
        fi
    fi
    
    echo -e "${RED}安装失败${NC}"
    return 1
}

# 获取 v2 版本列表（包含最新 v2.12.0）
get_v2_versions() {
    echo -e "${BLUE}获取 GOST v2 版本列表...${NC}"
    
    # 尝试从 GitHub API 获取最新的 10 个版本
    local versions=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ginuerzh/gost/releases" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -10)
    
    # 如果 API 获取失败，使用备用硬编码列表（已更新 v2.12.0 为最新）
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}注意：无法从 GitHub API 获取版本列表，正在加载备用列表...${NC}"
        versions="2.12.0 2.11.5 2.11.4 2.11.3 2.11.2 2.11.1 2.11.0"
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

# 获取 v3 版本列表
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

# 选择版本
select_version_to_install() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}       选择 GOST 版本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "  ${GREEN}1${NC}) GOST v2 (稳定版)"
    echo -e "  ${GREEN}2${NC}) GOST v3 (最新版)"
    echo -e "  ${GREEN}0${NC}) 返回主菜单"
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

# 停止 GOST
stop_gost() {
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}停止现有 GOST 进程...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
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
    
    nohup $cmd > "$GOST_LOG" 2>&1 &
    local pid=$!
    echo $pid > "$GOST_PID_FILE"
    
    sleep 2
    
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 代理运行中 (PID: $pid)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}代理链接:${NC}"
        echo -e "${YELLOW}${proxy_url}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        echo -e "${RED}启动失败，请检查日志: ${GOST_LOG}${NC}"
        return 1
    fi
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
        nohup \$cmd > gost.log 2>&1 &
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

# 配置代理流程
configure_proxy() {
    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${RED}请先安装 GOST${NC}"
        return 1
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}          配置代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
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
    echo -e "  ${GREEN}4${NC}) 无加密自适应"
    echo -n -e "${YELLOW}请输入 [1-4]: ${NC}"
    read protocol
    [[ ! "$protocol" =~ ^[1-4]$ ]] && protocol=3
    
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
    
    start_gost "$protocol" "$port" "$username" "$password"
    
    echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
    read auto_start
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        enable_autostart
    fi
    
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
}

# 显示状态
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
    echo -e "${BLUE}║  ${GREEN}2${BLUE}) 配置代理                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}3${BLUE}) 查看状态                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}4${BLUE}) 卸载 GOST                       ║${NC}"
    echo -e "${BLUE}║  ${GREEN}0${BLUE}) 退出                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -n -e "${YELLOW}请输入 [0-4]: ${NC}"
}

# 主程序
main() {
    detect_os_arch
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                if select_version_to_install; then
                    if [ -f "$GOST_BIN" ]; then
                        echo
                        echo -n -e "${GREEN}是否配置代理？[y/N]: ${NC}"
                        read config_now
                        if [[ "$config_now" =~ ^[Yy]$ ]]; then
                            configure_proxy
                        fi
                    fi
                fi
                ;;
            2)
                configure_proxy
                ;;
            3)
                show_status
                ;;
            4)
                uninstall_gost
                echo -n -e "${GREEN}按任意键返回菜单...${NC}"
                read -n 1
                ;;
            0)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

main
