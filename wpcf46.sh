#!/usr/bin/env bash
#===============================================================================
# 脚本名称: wpcf46.sh
# 功能描述: 自适应 Linux/FreeBSD 的 WARP 网络栈补充工具 (IPv4/IPv6/双栈)
#           自动检测权限，非 root 时通过 sudo 提权
# 项目参考: https://gitlab.com/fscarmen/warp
# 使用方法: bash wpcf46.sh  (自动提权，无需手动 sudo)
# 支持系统: Debian/Ubuntu/CentOS/RHEL/Alpine/FreeBSD
#===============================================================================

set -e
set -o pipefail

# 自动提权：如果不是 root，尝试用 sudo 重新执行
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "当前非 root 用户，正在通过 sudo 提权..."
        exec sudo "$0" "$@"
    else
        echo "错误: 需要 root 权限，但未找到 sudo 命令。请手动切换为 root 用户后执行。" >&2
        exit 1
    fi
fi

# 颜色输出
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
info()   { echo -e "\033[36m$*\033[0m"; }

# 检测操作系统
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
        NEED_FIB=1   # FreeBSD 建议开启多路由表
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
                yellow "未知 Linux 发行版，尝试使用通用包管理器"
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
                    red "无法确定包管理器，请手动安装 wireguard-tools wgcf curl"
                    exit 1
                fi
                ;;
        esac
        WG_CONF_DIR="/etc/wireguard"
        WG_QUICK="wg-quick"
        ROUTE_CMD="ip"
        IP_CMD="ip"
        SYS_RC=""   # Linux 使用 systemd 或 rc.local，开机自启由 wg-quick 的 systemd 服务处理
        NEED_FIB=0
    else
        red "不支持的操作系统"
        exit 1
    fi
    green "检测到操作系统: $OS"
}

# 检查 root (已提权，此处一定是 root，但保留二次确认)
if [ "$EUID" -ne 0 ]; then
    red "内部错误: 提权失败，请手动以 root 执行。"
    exit 1
fi

detect_os

# 路径定义
WG_CONF="$WG_CONF_DIR/wg1.conf"
TMP_DIR="/tmp/wpcf46"

# 检测当前默认路由
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

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# 安装依赖
install_packages() {
    info "安装必要软件包: wireguard-tools, wgcf, curl ..."
    if [ "$OS" = "freebsd" ]; then
        export ASSUME_ALWAYS_YES=yes
        $PKG_UPDATE
        $PKG_INSTALL wireguard-tools wgcf curl
        unset ASSUME_ALWAYS_YES
    else
        $PKG_UPDATE
        $PKG_INSTALL wireguard-tools wgcf curl
        # 某些发行版 wgcf 可能不在官方源，尝试下载二进制
        if ! command -v wgcf >/dev/null; then
            yellow "wgcf 未安装，尝试从 GitHub 下载..."
            curl -fsSL https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_$(uname -s)_$(uname -m) -o /usr/local/bin/wgcf
            chmod +x /usr/local/bin/wgcf
        fi
    fi
}

# 生成基础配置 (wgcf)
generate_base_config() {
    mkdir -p "$TMP_DIR" "$WG_CONF_DIR"
    cd "$TMP_DIR"
    [ -f "wgcf-account.toml" ] && mv wgcf-account.toml wgcf-account.toml.bak
    wgcf register >/dev/null 2>&1 || { red "wgcf 注册失败"; exit 1; }
    wgcf generate >/dev/null 2>&1  || { red "wgcf 生成配置失败"; exit 1; }
    cp wgcf-profile.conf "$WG_CONF"
}

# 根据模式修改配置
# $1: mode = ipv4 / ipv6 / dual
modify_config() {
    local mode="$1"
    info "根据模式 [$mode] 调整 WireGuard 配置..."

    # 替换 Endpoint 域名为 IP（避免 DNS 问题）
    sed -i 's/engage.cloudflareclient.com/162.159.192.1/g' "$WG_CONF"

    # 删除已有的 Table 行
    sed -i '/^Table =/d' "$WG_CONF"

    # 在 [Interface] 段添加 Table = off（禁止自动创建路由）
    sed -i '/^\[Interface\]/a\
Table = off
' "$WG_CONF"

    # 设置 AllowedIPs
    case "$mode" in
        ipv4)
            sed -i 's/^AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0/' "$WG_CONF"
            ;;
        ipv6)
            sed -i 's/^AllowedIPs = .*/AllowedIPs = ::\/0/' "$WG_CONF"
            ;;
        dual)
            sed -i 's/^AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0, ::\/0/' "$WG_CONF"
            ;;
    esac

    # 手动添加/删除默认路由的 PostUp/PreDown
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
" "$WG_CONF"

    green "配置文件修改完成"
}

# FreeBSD: 启用 FIB（多路由表）
setup_fib_freebsd() {
    if [ "$(sysctl -n net.fibs 2>/dev/null || echo 1)" -lt 2 ]; then
        yellow "启用多路由表 (net.fibs=2) 以增强稳定性..."
        if ! grep -q "^net.fibs=" /boot/loader.conf 2>/dev/null; then
            echo "net.fibs=2" >> /boot/loader.conf
        else
            sed -i '' 's/^net.fibs=.*/net.fibs=2/' /boot/loader.conf
        fi
        green "已写入 /boot/loader.conf，需要重启生效。"
        return 1   # 需要重启
    fi
    return 0
}

# 启动 WireGuard 并设置开机自启
start_wireguard() {
    info "启动 WireGuard 接口 wg1 ..."
    if command -v wg-quick >/dev/null; then
        wg show wg1 >/dev/null 2>&1 && wg-quick down wg1 2>/dev/null
        if ! wg-quick up "$WG_CONF"; then
            red "WireGuard 启动失败"
            exit 1
        fi
    else
        red "wg-quick 未找到"
        exit 1
    fi

    # 设置开机自启
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
    green "WireGuard 已启动并设置开机自启"
}

# 测试连通性
test_connectivity() {
    local mode="$1"
    info "测试网络连通性..."
    case "$mode" in
        ipv4)
            if ping -c 2 1.1.1.1 >/dev/null 2>&1; then
                green "IPv4 访问成功 (通过 WARP)"
                local ip=$(curl -s4 --interface wg1 ifconfig.me 2>/dev/null)
                [ -n "$ip" ] && green "WARP IPv4 出口: $ip"
            else
                red "IPv4 测试失败"
            fi
            ;;
        ipv6)
            if ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1; then
                green "IPv6 访问成功 (通过 WARP)"
                local ip6=$(curl -s6 --interface wg1 ifconfig.me 2>/dev/null)
                [ -n "$ip6" ] && green "WARP IPv6 出口: $ip6"
            else
                red "IPv6 测试失败"
            fi
            ;;
        dual)
            ping -c 2 1.1.1.1 >/dev/null 2>&1 && green "IPv4 通过 WARP" || red "IPv4 测试失败"
            ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1 && green "IPv6 通过 WARP" || red "IPv6 测试失败"
            ;;
    esac
}

# 显示菜单
show_menu() {
    clear
    echo "=========================================="
    info "   WARP 网络栈补充工具 (wpcf46) - 支持 $OS"
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
}

# 主逻辑
main() {
    show_menu
    read -p "请输入选择 [0-3]: " choice
    case "$choice" in
        1) mode="ipv4" ;;
        2) mode="ipv6" ;;
        3) mode="dual" ;;
        0) exit 0 ;;
        *) red "无效选择"; sleep 1; main; return ;;
    esac

    # 双栈警告
    if [ "$mode" = "dual" ]; then
        echo ""
        red "警告: 双栈模式将所有 IPv4 和 IPv6 流量强制通过 WARP。"
        yellow "如果 SSH 连接依赖于现有默认路由，可能会断开连接。"
        read -p "是否继续？ [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy] ]] && main
    fi

    install_packages
    generate_base_config
    modify_config "$mode"

    # FreeBSD 特殊处理 FIB
    if [ "$OS" = "freebsd" ] && [ "$NEED_FIB" -eq 1 ]; then
        if ! setup_fib_freebsd; then
            yellow "需要重启系统以启用多路由表。重启后请再次运行本脚本并选择相同模式。"
            read -p "现在重启？ [y/N]: " reboot_ans
            if [[ "$reboot_ans" =~ ^[Yy] ]]; then
                reboot
            else
                yellow "请稍后手动重启，重启后再次运行 $0 完成配置。"
                exit 0
            fi
        fi
    fi

    start_wireguard
    test_connectivity "$mode"
    green "配置完成！"
    echo "提示: 卸载请执行 'wg-quick down wg1' 并删除 $WG_CONF"
}

main
