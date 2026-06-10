#!/data/data/com.termux/files/usr/bin/bash
#===============================================================================
# Termux 专用 WARP SOCKS5 代理一键脚本
# 用法: bash wpcf46.sh
#===============================================================================

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
info()   { echo -e "\033[36m$*\033[0m"; }

# 检查 Termux 环境
if [[ ! -d /data/data/com.termux ]]; then
    echo "错误：此脚本仅支持 Termux"
    exit 1
fi

BIN_DIR="$HOME/.wpcf46/bin"
CONF_DIR="$HOME/.wpcf46"
mkdir -p "$BIN_DIR" "$CONF_DIR"
export PATH="$BIN_DIR:$PATH"

# 下载工具函数
download_tool() {
    local url="$1"
    local output="$2"
    if [[ -f "$output" ]]; then
        return 0
    fi
    info "下载 $(basename "$output") ..."
    curl -L -o "$output" "$url" || {
        red "下载失败: $url"
        return 1
    }
    chmod +x "$output"
}

# 安装 wgcf
install_wgcf() {
    if command -v wgcf >/dev/null; then
        return 0
    fi
    info "安装 wgcf..."
    local arch=$(uname -m)
    local suffix=""
    case "$arch" in
        aarch64) suffix="arm64" ;;
        armv7l)  suffix="armv7" ;;
        x86_64)  suffix="amd64" ;;
        i686)    suffix="386" ;;
        *)       suffix="amd64" ;;
    esac
    local url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${suffix}"
    download_tool "$url" "$BIN_DIR/wgcf" || return 1
}

# 安装 wireproxy
install_wireproxy() {
    if command -v wireproxy >/dev/null; then
        return 0
    fi
    info "安装 wireproxy..."
    local os="android"
    local arch=$(uname -m)
    local suffix=""
    case "$arch" in
        aarch64) suffix="arm64" ;;
        armv7l)  suffix="armv7" ;;
        x86_64)  suffix="amd64" ;;
        i686)    suffix="386" ;;
        *)       suffix="arm64" ;;
    esac
    local url="https://github.com/octeep/wireproxy/releases/latest/download/wireproxy_${os}_${suffix}"
    download_tool "$url" "$BIN_DIR/wireproxy" || return 1
}

# 生成 wgcf 配置
generate_wgcf_config() {
    cd "$CONF_DIR"
    if [[ -f "wgcf-profile.conf" ]]; then
        return 0
    fi
    info "注册 WARP 账户..."
    wgcf register 2>/dev/null || {
        red "注册失败，请检查网络后重试"
        return 1
    }
    info "生成配置文件..."
    wgcf generate 2>/dev/null || {
        red "生成配置失败"
        return 1
    }
    green "配置文件已生成"
}

# 创建 wireproxy 配置
create_wireproxy_conf() {
    cd "$CONF_DIR"
    if [[ ! -f "wgcf-profile.conf" ]]; then
        red "缺少 wgcf-profile.conf"
        return 1
    fi
    local address=$(grep '^Address' wgcf-profile.conf | head -1 | cut -d= -f2 | tr -d ' ')
    local private_key=$(grep '^PrivateKey' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
    local public_key=$(grep '^PublicKey' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
    local endpoint=$(grep '^Endpoint' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
    
    cat > "$CONF_DIR/wireproxy.conf" <<EOF
[Interface]
Address = $address
PrivateKey = $private_key
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $public_key
Endpoint = $endpoint
KeepAlive = 25

[Socks5]
BindAddress = 127.0.0.1:1080
EOF
    green "wireproxy 配置文件已创建"
}

# 启动代理
start_proxy() {
    if [[ -f "$CONF_DIR/proxy.pid" ]] && kill -0 "$(cat "$CONF_DIR/proxy.pid")" 2>/dev/null; then
        yellow "代理已在运行中 (PID: $(cat "$CONF_DIR/proxy.pid"))"
        return 0
    fi
    # 清理旧进程
    pkill wireproxy 2>/dev/null
    rm -f "$CONF_DIR/proxy.pid"
    
    # 确保所有组件就绪
    install_wgcf || return 1
    install_wireproxy || return 1
    generate_wgcf_config || return 1
    create_wireproxy_conf || return 1
    
    info "启动 SOCKS5 代理..."
    wireproxy -c "$CONF_DIR/wireproxy.conf" > /dev/null 2>&1 &
    local pid=$!
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid" > "$CONF_DIR/proxy.pid"
        green "✅ 代理启动成功"
        echo "代理地址: socks5://127.0.0.1:1080"
        echo ""
        echo "使用方法:"
        echo "  export ALL_PROXY=socks5://127.0.0.1:1080"
        echo "  curl ip.sb"
        echo ""
        echo "停止代理: bash $0 stop"
    else
        red "代理启动失败"
        return 1
    fi
}

# 停止代理
stop_proxy() {
    if [[ -f "$CONF_DIR/proxy.pid" ]]; then
        local pid=$(cat "$CONF_DIR/proxy.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            green "代理已停止"
        fi
        rm -f "$CONF_DIR/proxy.pid"
    else
        yellow "代理未运行"
    fi
}

# 查看状态
status_proxy() {
    if [[ -f "$CONF_DIR/proxy.pid" ]] && kill -0 "$(cat "$CONF_DIR/proxy.pid")" 2>/dev/null; then
        green "代理正在运行，PID: $(cat "$CONF_DIR/proxy.pid")"
    else
        yellow "代理未运行"
    fi
}

# 菜单循环
menu() {
    while true; do
        clear
        echo "=========================================="
        info "   Termux WARP SOCKS5 代理工具"
        echo "=========================================="
        echo "1) 启动 SOCKS5 代理 (后台)"
        echo "2) 停止代理"
        echo "3) 查看代理状态"
        echo "0) 退出"
        echo ""
        read -p "请选择 [0-3]: " choice
        case "$choice" in
            1) 
                start_proxy
                echo ""
                read -p "按 Enter 返回菜单..."
                ;;
            2)
                stop_proxy
                read -p "按 Enter 返回菜单..."
                ;;
            3)
                status_proxy
                read -p "按 Enter 返回菜单..."
                ;;
            0)
                exit 0
                ;;
            *)
                red "无效输入"
                sleep 1
                ;;
        esac
    done
}

# 主入口
if [[ "$1" == "stop" ]]; then
    stop_proxy
else
    menu
fi
