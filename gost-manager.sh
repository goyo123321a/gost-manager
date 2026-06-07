#!/usr/bin/env bash

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
GOST_PID_FILE="$GOST_DIR/gost.pid"
repo="go-gost/gost"
base_url="https://api.github.com/repos/$repo/releases"

# 获取本机IP
get_local_ip() {
    local ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n 1)
    [ -z "$ip" ] && ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="$(hostname)"
    echo "$ip"
}

# 检测系统架构（优化版）
detect_os_arch() {
    # 检测操作系统
    if [[ "$(uname)" == "Linux" ]]; then
        os="linux"
    elif [[ "$(uname)" == "Darwin" ]]; then
        os="darwin"
    elif [[ "$(uname)" == "MINGW"* ]] || [[ "$(uname)" == "CYGWIN"* ]]; then
        os="windows"
    else
        echo -e "${RED}Unsupported operating system.${NC}"
        exit 1
    fi

    # 检测CPU架构
    arch=$(uname -m)
    case $arch in
        x86_64|amd64) cpu_arch="amd64" ;;
        armv5*) cpu_arch="armv5" ;;
        armv6*) cpu_arch="armv6" ;;
        armv7*) cpu_arch="armv7" ;;
        aarch64|arm64) cpu_arch="arm64" ;;
        i686|i386) cpu_arch="386" ;;
        mips64*) cpu_arch="mips64" ;;
        mips*) cpu_arch="mips" ;;
        mipsel*) cpu_arch="mipsle" ;;
        riscv64) cpu_arch="riscv64" ;;
        *)
            echo -e "${RED}Unsupported CPU architecture: $arch${NC}"
            exit 1
            ;;
    esac
}

# 获取并安装 GOST（优化版）
install_gost() {
    version=$1
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}        GOST 一键安装脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    # 创建目录
    echo -e "${YELLOW}[1/5] 创建安装目录...${NC}"
    mkdir -p "$GOST_DIR"
    cd "$GOST_DIR" || return 1
    
    # 检测系统和架构
    echo -e "${YELLOW}[2/5] 检测系统环境...${NC}"
    detect_os_arch
    echo -e "      系统: ${os}, 架构: ${cpu_arch}"
    
    # 获取下载地址
    echo -e "${YELLOW}[3/5] 获取下载地址...${NC}"
    get_download_url="$base_url/tags/$version"
    download_url=$(curl -s "$get_download_url" | awk -F'"' -v re=".*${os}.*${cpu_arch}.*" '/"browser_download_url":/ && $4 ~ re { print $4 }' | head -n 1)
    
    if [[ -z "$download_url" ]]; then
        echo -e "${RED}获取下载地址失败，尝试备用方法...${NC}"
        # 备用：使用 releases/latest
        get_download_url="$base_url/latest"
        download_url=$(curl -s "$get_download_url" | awk -F'"' -v re=".*${os}.*${cpu_arch}.*" '/"browser_download_url":/ && $4 ~ re { print $4 }' | head -n 1)
    fi
    
    if [[ -z "$download_url" ]]; then
        echo -e "${RED}无法获取下载地址，请检查网络或版本号${NC}"
        return 1
    fi
    
    echo -e "      下载地址: ${download_url}"
    
    # 下载并解压
    echo -e "${YELLOW}[4/5] 下载并安装 GOST ${version}...${NC}"
    
    if [[ "$download_url" == *.tar.gz ]]; then
        curl -fsSL "$download_url" | tar -xzC "$GOST_DIR" gost 2>/dev/null || {
            # 如果解压失败，尝试下载到临时文件
            temp_file=$(mktemp)
            curl -fsSL "$download_url" -o "$temp_file"
            tar -xzf "$temp_file" -C "$GOST_DIR" gost 2>/dev/null
            rm -f "$temp_file"
        }
    else
        # 直接下载二进制文件
        curl -fsSL "$download_url" -o gost
    fi
    
    chmod +x "$GOST_BIN"
    
    # 验证安装
    echo -e "${YELLOW}[5/5] 验证安装...${NC}"
    if [[ -f "$GOST_BIN" ]] && [[ -x "$GOST_BIN" ]]; then
        echo -e "${GREEN}✓ GOST ${version} 安装成功！${NC}"
        "$GOST_BIN" -V 2>/dev/null || echo -e "${YELLOW}GOST 可执行文件准备就绪${NC}"
        return 0
    else
        echo -e "${RED}安装失败，请手动检查${NC}"
        return 1
    fi
}

# 列出可用版本
list_versions() {
    echo -e "${BLUE}正在获取可用版本列表...${NC}"
    versions=$(curl -s "$base_url" | awk -F'"' '/"tag_name":/ {print $4}' | head -20)
    
    if [[ -z "$versions" ]]; then
        echo -e "${RED}获取版本列表失败，将安装最新版${NC}"
        install_gost "latest"
        return $?
    fi
    
    echo -e "${GREEN}可用的 GOST 版本:${NC}"
    select version in $versions "退出"; do
        if [[ "$version" == "退出" ]]; then
            return 1
        elif [[ -n "$version" ]]; then
            install_gost "$version"
            return $?
        else
            echo -e "${RED}无效选择，请重新选择${NC}"
        fi
    done
}

# 停止 GOST
stop_gost() {
    if pgrep -f "$GOST_BIN" > /dev/null 2>&1; then
        echo -e "${YELLOW}正在停止现有 GOST 进程...${NC}"
        pkill -f "$GOST_BIN" 2>/dev/null
        sleep 2
        echo -e "${GREEN}✓ 已停止${NC}"
    fi
    [ -f "$GOST_PID_FILE" ] && rm -f "$GOST_PID_FILE"
}

# 启动 GOST 代理
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
        1)  # HTTP
            cmd="$GOST_BIN -L http://${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 HTTP 代理...${NC}"
            ;;
        2)  # SOCKS5
            cmd="$GOST_BIN -L socks5://${username}:${password}@:${port}"
            proxy_url="socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动 SOCKS5 代理...${NC}"
            ;;
        3)  # 自适应（HTTP/SOCKS5）
            cmd="$GOST_BIN -L ${username}:${password}@:${port}"
            proxy_url="http://${username}:${password}@${ip}:${port} / socks5://${username}:${password}@${ip}:${port}"
            echo -e "${GREEN}启动自适应代理 (HTTP + SOCKS5)...${NC}"
            ;;
        4)  # 无加密自适应
            cmd="$GOST_BIN -L :${port}"
            proxy_url="${ip}:${port} (无加密)"
            echo -e "${GREEN}启动无加密代理...${NC}"
            ;;
    esac
    
    # 后台启动
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

# 配置开机自启
enable_autostart() {
    local current_cron=$(crontab -l 2>/dev/null | grep -v "$GOST_DIR/gost")
    
    # 创建保活脚本
    cat > "$GOST_DIR/keepalive.sh" << 'EOF'
#!/usr/bin/env bash
GOST_DIR="$HOME/GOST"
cd "$GOST_DIR"
if [ -f "gost.pid" ] && kill -0 "$(cat gost.pid)" 2>/dev/null; then
    exit 0
fi
if ! pgrep -f "$GOST_DIR/gost" > /dev/null; then
    if [ -f "start_cmd.txt" ]; then
        cmd=$(cat start_cmd.txt)
        nohup $cmd > gost.log 2>&1 &
        echo $! > gost.pid
    fi
fi
EOF
    chmod +x "$GOST_DIR/keepalive.sh"
    
    # 保存当前启动命令
    local running_cmd=$(ps -ef | grep "$GOST_BIN" | grep -v grep | head -1 | sed 's/.*\.\/gost/\.\/gost/')
    if [ -n "$running_cmd" ]; then
        echo "$running_cmd" > "$GOST_DIR/start_cmd.txt"
    fi
    
    # 写入 crontab
    (echo "$current_cron"; echo "@reboot $GOST_DIR/keepalive.sh"; echo "*/5 * * * * $GOST_DIR/keepalive.sh") | crontab -
    
    echo -e "${GREEN}✓ 已配置开机自启和进程保活（每5分钟检查）${NC}"
}

# 卸载 GOST
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
    
    # 输入端口
    while true; do
        echo -n -e "${YELLOW}请输入端口: ${NC}"
        read port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口无效，请输入1-65535之间的数字${NC}"
        fi
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
    
    # 启动代理
    start_gost "$protocol" "$port" "$username" "$password"
    
    # 询问开机自启
    echo -n -e "${YELLOW}是否开启开机自启？[y/N]: ${NC}"
    read auto_start
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        enable_autostart
    fi
    
    echo -n -e "${GREEN}按任意键返回菜单...${NC}"
    read -n 1
}

# 显示当前状态
show_status() {
    echo -e "${BLUE}========================================${NC}"
    if [ -f "$GOST_BIN" ]; then
        echo -e "${GREEN}GOST 状态: 已安装${NC}"
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
    # 注意：移除了 root 检查，Serv00 无 root 权限
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                list_versions
                if [ $? -eq 0 ] && [ -f "$GOST_BIN" ]; then
                    echo -n -e "${GREEN}是否配置代理？[y/N]: ${NC}"
                    read config_now
                    if [[ "$config_now" =~ ^[Yy]$ ]]; then
                        configure_proxy
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
                echo -e "${RED}无效选择，请输入 0-4${NC}"
                sleep 1
                ;;
        esac
    done
}

# 检查是否直接运行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
