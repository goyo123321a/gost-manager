#!/usr/bin/env bash
#===============================================================================
# 脚本名称: wpcf46.sh
# 功能描述: 
#   - root 模式: WireGuard + 路由策略 (IPv4 only / IPv6 only / 双栈)
#   - 非 root 模式: SOCKS5 代理 (wireproxy)，无需 root，支持 Termux
# 使用方法: bash wpcf46.sh
# 项目参考: https://gitlab.com/fscarmen/warp
#===============================================================================

set -e
set -o pipefail

# 颜色输出
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
info()   { echo -e "\033[36m$*\033[0m"; }

# 检测是否为 Termux 环境 (用于非 root 模式)
is_termux() {
    [[ -d /data/data/com.termux ]] || [[ -n "$PREFIX" && "$PREFIX" != "/usr" ]]
}

# 获取系统架构 (用于下载 wireproxy)
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        i686)    echo "386" ;;
        *)       echo "amd64" ;; # fallback
    esac
}

# 获取操作系统 (用于下载 wireproxy)
get_os() {
    if is_termux; then
        echo "android"  # Termux 使用 android 版本
    elif [[ "$(uname)" == "Linux" ]]; then
        echo "linux"
    elif [[ "$(uname)" == "FreeBSD" ]]; then
        echo "freebsd"
    else
        echo "linux"
    fi
}

# ==================== 非 root 模式 (SOCKS5 代理) ====================
setup_socks5_proxy() {
    local HOME_DIR="${HOME:-/home/user}"
    local BIN_DIR="$HOME_DIR/.wpcf46/bin"
    local CONF_DIR="$HOME_DIR/.wpcf46"
    mkdir -p "$BIN_DIR" "$CONF_DIR"
    
    # 下载 wireproxy (如果不存在)
    if [[ ! -f "$BIN_DIR/wireproxy" ]]; then
        info "下载 wireproxy..."
        local OS=$(get_os)
        local ARCH=$(get_arch)
        local URL="https://github.com/octeep/wireproxy/releases/latest/download/wireproxy_${OS}_${ARCH}"
        curl -L -o "$BIN_DIR/wireproxy" "$URL"
        chmod +x "$BIN_DIR/wireproxy"
    fi
    export PATH="$BIN_DIR:$PATH"
    
    # 生成 wgcf 配置 (如果没有)
    cd "$CONF_DIR"
    if [[ ! -f "wgcf-profile.conf" ]]; then
        info "注册 WARP 并生成配置..."
        # 安装 wgcf (如果缺失)
        if ! command -v wgcf >/dev/null; then
            if is_termux; then
                pkg install -y wgcf curl
            else
                # 普通 Linux 用户，尝试下载 wgcf 二进制
                curl -L -o "$BIN_DIR/wgcf" "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_$(uname -s)_$(uname -m)"
                chmod +x "$BIN_DIR/wgcf"
                export PATH="$BIN_DIR:$PATH"
            fi
        fi
        wgcf register >/dev/null 2>&1 || { red "wgcf 注册失败"; exit 1; }
        wgcf generate >/dev/null 2>&1
    fi
    
    # 创建 wireproxy 配置文件
    cat > "$CONF_DIR/wireproxy.conf" <<EOF
[Interface]
Address = $(grep '^Address' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
PrivateKey = $(grep '^PrivateKey' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $(grep '^PublicKey' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
Endpoint = $(grep '^Endpoint' wgcf-profile.conf | cut -d= -f2 | tr -d ' ')
KeepAlive = 25

[Socks5]
BindAddress = 127.0.0.1:1080
EOF
    
    # 启动代理 (后台)
    pkill wireproxy 2>/dev/null || true
    wireproxy -c "$CONF_DIR/wireproxy.conf" &
    local proxy_pid=$!
    echo "$proxy_pid" > "$CONF_DIR/proxy.pid"
    sleep 2
    
    if kill -0 "$proxy_pid" 2>/dev/null; then
        green "SOCKS5 代理已启动，PID: $proxy_pid"
        echo "代理地址: socks5://127.0.0.1:1080"
        echo ""
        echo "使用方法:"
        echo "  export ALL_PROXY=socks5://127.0.0.1:1080"
        echo "  curl ip.sb"
        echo ""
        echo "停止代理: $0 stop"
    else
        red "代理启动失败"
        exit 1
    fi
}

stop_socks5_proxy() {
    local CONF_DIR="$HOME/.wpcf46"
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

socks5_menu() {
    clear
    echo "=========================================="
    info "   WARP SOCKS5 代理模式 (非 root 用户)"
    echo "=========================================="
    echo "1) 启动 SOCKS5 代理 (后台运行)"
    echo "2) 停止代理"
    echo "3) 查看代理状态"
    echo "0) 退出"
    echo ""
    read -p "请选择 [0-3]: " choice
    case "$choice" in
        1) setup_socks5_proxy ;;
        2) stop_socks5_proxy ;;
        3) 
            if [[ -f "$HOME/.wpcf46/proxy.pid" ]] && kill -0 "$(cat "$HOME/.wpcf46/proxy.pid")" 2>/dev/null; then
                green "代理正在运行，PID: $(cat "$HOME/.wpcf46/proxy.pid")"
            else
                yellow "代理未运行"
            fi
            ;;
        0) exit 0 ;;
        *) red "无效选择"; sleep 1; socks5_menu ;;
    esac
}

# ==================== root 模式 (WireGuard + 路由策略) ====================
# 检测操作系统 (root 模式)
detect_os() {
    if grep -qi freebsd /etc/rc.conf 2>/dev/null; then
        OS="freebsd"
        PKG_INSTALL="pkg install -y"
        PKG_UPDATE="pkg update -q"
        WG_CONF_DIR="/usr/local/etc/wireguard"
        WG_QUICK="wg-quick"
        ROUTE_CMD="route"
        IP_CMD="ifconfig"
        SYS_RC="/etc/rc.conf"
        NEED_FIB=1
    elif [ -f /etc/os-release ]; then
        OS="linux"
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                PKG_UPDATE="apt update -qq"
                PKG_INSTALL="apt install -y -qq"
                ;;
            centos|rhel|rocky|almalinux)
                PKG_UPDATE="yum makecache -q"
                PKG_INSTALL="yum install -y -q"
                ;;
            alpine)
                PKG_UPDATE="apk update -q"
                PKG_INSTALL="apk add -q"
                ;;
            *)
                PKG_UPDATE=""
                PKG_INSTALL=""
                if command -v apt >/dev/null; then
                    PKG_UPDATE="apt update -qq"
                    PKG_INSTALL="apt install -y -qq"
                elif command -v yum >/dev/null; then
                    PKG_UPDATE="yum makecache -q"
                    PKG_INSTALL="yum install -y -q"
                elif command -v apk >/dev/null; then
                    PKG_UPDATE="apk update -q"
                    PKG_INSTALL="apk add -q"
                else
                    red "无法确定包管理器"
                    exit 1
                fi
                ;;
        esac
        WG_CONF_DIR="/etc/wireguard"
        WG_QUICK="wg-quick"
        ROUTE_CMD="ip"
        IP_CMD="ip"
        SYS_RC=""
        NEED_FIB=0
    else
        red "不支持的操作系统"
        exit 1
    fi
    green "检测到操作系统: $OS"
}

has_ipv4_default() {
    if [ "$OS" = "freebsd" ]; then
        netstat -rn -f inet | grep -q '^default'
    else
        ip route show default | grep -q '^default' 2>/dev/null
    fi
}

has_ipv6_default() {
    if [ "$OS" = "freebsd" ]; then
        netstat -rn -f inet6 | grep -q '^default'
    else
        ip -6 route show default | grep -q '^default' 2>/dev/null
    fi
}

TMP_DIR="/tmp/wpcf46"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

install_packages_root() {
    info "安装必要软件包: wireguard-tools, wgcf, curl ..."
    if [ "$OS" = "freebsd" ]; then
        export ASSUME_ALWAYS_YES=yes
        $PKG_UPDATE
        $PKG_INSTALL wireguard-tools wgcf curl
        unset ASSUME_ALWAYS_YES
    else
        $PKG_UPDATE
        $PKG_INSTALL wireguard-tools wgcf curl
        if ! command -v wgcf >/dev/null; then
            curl -fsSL https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_$(uname -s)_$(uname -m) -o /usr/local/bin/wgcf
            chmod +x /usr/local/bin/wgcf
        fi
    fi
}

generate_base_config_root() {
    mkdir -p "$TMP_DIR" "$WG_CONF_DIR"
    cd "$TMP_DIR"
    [ -f "wgcf-account.toml" ] && mv wgcf-account.toml wgcf-account.toml.bak
    wgcf register >/dev/null 2>&1 || { red "wgcf 注册失败"; exit 1; }
    wgcf generate >/dev/null 2>&1
    cp wgcf-profile.conf "$WG_CONF_DIR/wg1.conf"
}

modify_config_root() {
    local mode="$1"
    local conf="$WG_CONF_DIR/wg1.conf"
    info "根据模式 [$mode] 调整 WireGuard 配置..."
    sed -i 's/engage.cloudflareclient.com/162.159.192.1/g' "$conf"
    sed -i '/^Table =/d' "$conf"
    sed -i '/^\[Interface\]/a\
Table = off
' "$conf"
    case "$mode" in
        ipv4)
            sed -i 's/^AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0/' "$conf"
            ;;
        ipv6)
            sed -i 's/^AllowedIPs = .*/AllowedIPs = ::\/0/' "$conf"
            ;;
        dual)
            sed -i 's/^AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0, ::\/0/' "$conf"
            ;;
    esac
    local postup=""
    local predown=""
    if [ "$OS" = "freebsd" ]; then
        case "$mode" in
            ipv4)
                postup="route add -net 0.0.0.0/0 -interface wg1"
                predown="route delete -net 0.0.0.0/0 -interface wg1"
                ;;
            ipv6)
                postup="route add -inet6 ::/0 -interface wg1"
                predown="route delete -inet6 ::/0 -interface wg1"
                ;;
            dual)
                postup="route add -net 0.0.0.0/0 -interface wg1 ; route add -inet6 ::/0 -interface wg1"
                predown="route delete -net 0.0.0.0/0 -interface wg1 ; route delete -inet6 ::/0 -interface wg1"
                ;;
        esac
    else
        case "$mode" in
            ipv4)
                postup="ip route add default dev wg1"
                predown="ip route del default dev wg1"
                ;;
            ipv6)
                postup="ip -6 route add default dev wg1"
                predown="ip -6 route del default dev wg1"
                ;;
            dual)
                postup="ip route add default dev wg1 ; ip -6 route add default dev wg1"
                predown="ip route del default dev wg1 ; ip -6 route del default dev wg1"
                ;;
        esac
    fi
    sed -i "/^Table = off/a\\
PostUp = $postup\\
PreDown = $predown
" "$conf"
    green "配置文件修改完成"
}

setup_fib_freebsd() {
    if [ "$(sysctl -n net.fibs 2>/dev/null || echo 1)" -lt 2 ]; then
        yellow "启用多路由表 (net.fibs=2)..."
        if ! grep -q "^net.fibs=" /boot/loader.conf 2>/dev/null; then
            echo "net.fibs=2" >> /boot/loader.conf
        else
            sed -i '' 's/^net.fibs=.*/net.fibs=2/' /boot/loader.conf
        fi
        green "需要重启生效"
        return 1
    fi
    return 0
}

start_wireguard_root() {
    info "启动 WireGuard 接口 wg1 ..."
    wg show wg1 >/dev/null 2>&1 && wg-quick down wg1 2>/dev/null
    if ! wg-quick up "$WG_CONF_DIR/wg1.conf"; then
        red "启动失败"
        exit 1
    fi
    if [ "$OS" = "freebsd" ]; then
        if ! grep -q "wireguard_enable" /etc/rc.conf; then
            echo 'wireguard_enable="YES"' >> /etc/rc.conf
        fi
        if ! grep -q 'wireguard_interfaces="wg1"' /etc/rc.conf; then
            sed -i '' '/wireguard_enable="YES"/a\
wireguard_interfaces="wg1"
' /etc/rc.conf
        fi
    else
        systemctl enable wg-quick@wg1 2>/dev/null || true
    fi
    green "WireGuard 已启动"
}

test_connectivity_root() {
    local mode="$1"
    info "测试连通性..."
    case "$mode" in
        ipv4)
            if ping -c 2 1.1.1.1 >/dev/null 2>&1; then
                green "IPv4 成功"
                local ip=$(curl -s4 --interface wg1 ifconfig.me 2>/dev/null)
                [ -n "$ip" ] && green "出口 IPv4: $ip"
            else
                red "IPv4 失败"
            fi
            ;;
        ipv6)
            if ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1; then
                green "IPv6 成功"
                local ip6=$(curl -s6 --interface wg1 ifconfig.me 2>/dev/null)
                [ -n "$ip6" ] && green "出口 IPv6: $ip6"
            else
                red "IPv6 失败"
            fi
            ;;
        dual)
            ping -c 2 1.1.1.1 >/dev/null 2>&1 && green "IPv4 通过 WARP" || red "IPv4 失败"
            ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1 && green "IPv6 通过 WARP" || red "IPv6 失败"
            ;;
    esac
}

root_menu() {
    detect_os
    clear
    echo "=========================================="
    info "   WARP 网络栈补充工具 (root 模式) - $OS"
    echo "=========================================="
    echo "当前网络状态:"
    has_ipv4_default && green "  ✓ IPv4 默认路由存在" || yellow "  ✗ IPv4 默认路由缺失"
    has_ipv6_default && green "  ✓ IPv6 默认路由存在" || yellow "  ✗ IPv6 默认路由缺失"
    echo ""
    echo "请选择需要补充的能力:"
    echo "  1) IPv4 only   (为纯IPv6 VPS 添加 IPv4 访问能力)"
    echo "  2) IPv6 only   (为纯IPv4 VPS 添加 IPv6 访问能力)"
    echo "  3) 双栈        (所有流量走 WARP，可能覆盖现有路由)"
    echo "  0) 退出"
    echo ""
    read -p "请输入选择 [0-3]: " choice
    case "$choice" in
        1) mode="ipv4" ;;
        2) mode="ipv6" ;;
        3) mode="dual" ;;
        0) exit 0 ;;
        *) red "无效选择"; sleep 1; root_menu; return ;;
    esac
    if [ "$mode" = "dual" ]; then
        echo ""
        red "警告: 双栈模式会覆盖现有默认路由，可能导致 SSH 断开"
        read -p "是否继续？ [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy] ]] && root_menu
    fi
    install_packages_root
    generate_base_config_root
    modify_config_root "$mode"
    if [ "$OS" = "freebsd" ] && [ "$NEED_FIB" -eq 1 ]; then
        if ! setup_fib_freebsd; then
            yellow "需要重启以启用多路由表，重启后再次运行脚本"
            read -p "现在重启？ [y/N]: " reboot_ans
            [[ "$reboot_ans" =~ ^[Yy] ]] && reboot
            exit 0
        fi
    fi
    start_wireguard_root
    test_connectivity_root "$mode"
    green "配置完成！"
    echo "提示: 卸载请执行 'wg-quick down wg1' 并删除配置文件"
}

# ==================== 主入口 ====================
if [ "$EUID" -eq 0 ]; then
    root_menu
else
    # 非 root 用户，检查是否传入 stop 参数
    if [[ "$1" == "stop" ]]; then
        stop_socks5_proxy
    else
        socks5_menu
    fi
fi
