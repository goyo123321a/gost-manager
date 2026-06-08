```markdown
# GOST 一键管理脚本

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![GOST](https://img.shields.io/badge/GOST-v2%20%7C%20v3-blue)](https://github.com/ginuerzh/gost)

> 一个跨平台的 GOST 代理一键安装、配置、管理脚本，支持 Linux / FreeBSD / macOS / Alpine，自动检测系统架构并下载匹配版本。

## ✨ 特性

- **一键安装**：自动检测系统（Linux、FreeBSD、Darwin）和 CPU 架构（amd64、arm64、armv7、386），从 GitHub 下载匹配的 GOST 二进制文件。
- **双版本支持**：
  - **GOST v2**：智能识别版本号，≥2.12.0 使用 `tar.gz` 新格式，≤2.11.5 使用 `gz` 旧格式（自动处理 armv8 等命名差异）。
  - **GOST v3**：仅显示稳定版（自动过滤 `nightly`、`rc`、`alpha`、`beta`），默认安装最新稳定版。
- **代理配置向导**：交互式设置端口、协议（HTTP / SOCKS5 / 自适应）、账号密码。
- **后台运行**：使用 `nohup` 将 GOST 放入后台，日志输出到 `~/GOST/gost.log`。
- **开机自启**：通过 `crontab @reboot` 实现开机自启，并内置进程保活（每 5 分钟检查一次，自动重启）。
- **状态查看**：显示已安装版本、运行状态、进程 PID。
- **一键卸载**：停止进程、删除文件、清除 crontab 任务。
- **在线更新**：脚本自身支持从远程仓库更新。
```
### GOSTV2[GitHub仓库](https://github.com/ginuerzh/gost)
### GOSTV3[GitHub仓库](https://github.com/go-gost/gost)
### GOST使用方法[GitHub仓库](https://v2.gost.run/getting-started/)

## 🚀 快速开始

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/goyo123321a/gost-manager/refs/heads/main/gost-manager.sh -o ~/gost-manager.sh && chmod +x ~/gost-manager.sh && bash ~/gost-manager.sh
```

或者使用 wget：

```bash
wget -q https://raw.githubusercontent.com/goyo123321a/gost-manager/refs/heads/main/gost-manager.sh -O ~/gost-manager.sh && chmod +x ~/gost-manager.sh && bash ~/gost-manager.sh
```

初次使用流程

1. 运行脚本后，会显示主菜单。
2. 选择 1) 安装 GOST → 选择版本（v2 / v3）→ 选择具体版本号（直接回车默认安装第一个版本）。
3. 安装完成后询问是否配置代理（直接回车默认 是）。
4. 按提示输入：
   · 端口：例如 1080
   · 协议：推荐 3) 自适应（同时支持 HTTP 和 SOCKS5）
   · 账号密码：默认 admin / 123456，可自定义
5. 询问是否开启开机自启（输入 y 开启，直接回车默认 不开启）。
6. 配置完成，代理即启动，并显示代理链接。

📖 使用说明

主菜单选项

选项 功能
1 安装 GOST（可选择 v2 或 v3，并从中选择版本）
2 配置代理（重新设置端口、协议、账号密码）
3 查看当前状态（已安装版本、进程 PID、运行状态）
4 卸载 GOST（停止进程、删除目录、清除自启任务）
5 更新脚本本身（从 GitHub 拉取最新版本）
0 退出脚本

代理协议说明

协议选项 说明 示例 URL
1) HTTP 标准 HTTP 代理 http://user:pass@ip:port
2) SOCKS5 标准 SOCKS5 代理 socks5://user:pass@ip:port
3) 自适应 同一端口同时支持 HTTP 和 SOCKS5（推荐） http://user:pass@ip:port 或 socks5://user:pass@ip:port

开机自启机制

· 在 ~/GOST/ 目录下生成 keepalive.sh 脚本。
· 通过 crontab 添加：
  · @reboot：系统启动时运行保活脚本。
  · */5 * * * *：每 5 分钟检查一次进程，若未运行则自动启动。
· 保活脚本会记录最后一次的启动命令（保存在 start_cmd.txt），重启后自动恢复。

🛠️ 手动管理

手动启动代理

```bash
cd ~/GOST
nohup ./gost -L admin:123456@:1080 > gost.log 2>&1 &
```

手动停止代理

```bash
pkill -f "~/GOST/gost"
```

查看日志

```bash
tail -f ~/GOST/gost.log
```

查看运行状态

```bash
ps aux | grep gost
```

🌍 支持的系统与环境

系统 版本 架构
Linux glibc / musl (Alpine) amd64, arm64, armv7, 386
FreeBSD 12+ amd64, 386
macOS (Darwin) 10.15+ amd64, arm64
Windows (WSL/原生) 理论支持（未测试） amd64, 386

注：Alpine Linux 使用 musl libc，但官方 GOST v2.12.0 及以上版本为 glibc 动态链接。若在 Alpine 上运行 v2.12.0 需要安装 gcompat（apk add gcompat）。更推荐使用 v2.11.5 静态编译版，脚本已自动处理。

❓ 常见问题

Q1: 安装时提示“下载失败”怎么办？

· 检查网络是否能够访问 GitHub（raw.githubusercontent.com 和 api.github.com）。
· 如果身处中国大陆，可尝试更换网络或使用代理。
· 脚本内置了多个备选 URL，如果全部失败，可手动下载二进制文件放入 ~/GOST/ 目录并命名为 gost，然后运行脚本的配置代理步骤。

Q2: 代理启动失败，日志显示“Exec format error”？

· 表示下载的二进制与系统架构不匹配。请运行 uname -m 查看架构，并确保脚本正确识别（通常在安装时会显示“检测到系统: linux, 架构: arm64”等）。如果不匹配，请手动下载对应架构的版本。

Q3: 开机自启不生效？

· 确认 crontab 是否支持 @reboot（Serv00 等部分环境可能限制）。如果不支持，可以改用 ~/.profile 或 ~/.bashrc 中添加启动命令。
· 检查 ~/GOST/keepalive.sh 是否有执行权限（chmod +x ~/GOST/keepalive.sh）。
· 查看 crontab 日志：grep CRON /var/log/syslog（需要 root 权限）。

Q4: 如何卸载脚本和所有文件？

· 在主菜单中选择 4) 卸载 GOST，会删除 ~/GOST/ 目录并清除 crontab 任务。
· 如需删除脚本本身，直接删除 ~/gost-manager.sh 即可。

Q5: 脚本更新后如何使用新功能？

· 选择主菜单 5) 更新脚本，会自动下载最新版本并覆盖当前脚本，然后退出。重新运行脚本即可使用新功能。

📝 版本历史

版本 日期 更新内容
v2.5 2026-06-08 增加 v3 稳定版过滤（去除 nightly/rc）；默认配置代理（Y/n）；版本选择支持默认第一个
v2.4 2026-06-07 修复 v2.11.5 下载失败（增加 armv8 备选 URL）；适配 FreeBSD 系统
v2.3 2026-06-06 增加脚本自更新功能；优化架构检测
v2.2 2026-06-05 支持 GOST v3 安装
v2.1 2026-06-04 新增开机自启及进程保活
v2.0 2026-06-03 初始发布，支持 v2 全版本

🤝 贡献

欢迎提交 Issue 或 Pull Request。如果你有更好的建议或发现 Bug，请到 GitHub 仓库 反馈。

📄 许可证

本项目采用 MIT 许可证。GOST 本身遵循其各自的开源协议。

---

轻松管理 GOST 代理，一键搞定！
