# NodeDeck

<p align="center">
  <img src="docs/icon.png" alt="NodeDeck icon" width="128" />
</p>

<p align="center">
  <a href="README.md"><strong>English</strong></a> ·
  <a href="#核心特性">核心特性</a> ·
  <a href="#技术架构与安全透明">技术架构与安全透明</a> ·
  <a href="#安装方式">安装方式</a> ·
  <a href="#从源码构建">源码构建</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-1f6f78?style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Linux-Ubuntu%20%2F%20Debian-2b5876?style=flat-square" alt="Linux" />
  <img src="https://img.shields.io/badge/零云端-纯本地架构-2d6a4f?style=flat-square" alt="Zero Cloud" />
  <img src="https://img.shields.io/badge/License-MIT%20%2B%20GPL--3.0-4a5568?style=flat-square" alt="License" />
</p>

**NodeDeck** 是一款面向 GPU 工作站、实验室服务器、组网节点与 HPC 集群的**零云端、纯本地**跨平台运维与远程桌面工作台，原生支持 **macOS（SwiftUI + VideoToolbox）** 与 **Linux（GTK3 + FFmpeg VAAPI/CUDA + SDL2）**。

它将 OpenSSH 设备管理、实时 CPU/GPU/Slurm/进程监控、内置硬件加速远程桌面（Moonlight/Sunshine 协议）、SSH 端口转发、GOST 隧道、VS Code Remote-SSH 工作区与访达目录挂载整合在同一轻量桌面端中——**无云端中转、免账号登录、零遥测上报**。

---

## 核心特性

- **极简标签页布局 + 免重启中英文切换（`简体中文 / English`）**
  - 详情页清晰拆分为 **概览**、**远程与网络**、**工作区** 三个标签页并带实时计数徽章，首屏直达核心监控，告别重复按钮与冗余堆砌。
  - macOS 与 Linux 双端均支持一键实时切换 **跟随系统 / 简体中文 / English**，无需重启应用。
- **内置硬件加速远程桌面（无需额外安装 Moonlight）**
  - 内置开源 `moonlight-common-c` 协议栈（`RTSP + ENet + FEC`），macOS 调用原生 **VideoToolbox** 硬解 HEVC/H.264，Linux 自动探测 **FFmpeg VAAPI（Intel/AMD）→ CUDA/NVDEC（NVIDIA）** 硬件解码并直出 NV12 纹理。
  - 原生低延迟键盘引擎（完整 Win32 VK + 扩展键 + 过滤重复按键 + 失焦全键抬起防卡键）、**相对鼠标锁定模式**（`⌃⌥⇧M` / `Ctrl+Alt+Shift+M`，适配 3D/CAD/游戏）、**SSH 双向剪贴板同步**（自动推送默认关闭）、**隐私屏**，以及实时 RTT / 码率 / 传输路径 HUD。
- **SSH 免 PIN 证书配对 & Linux 多用户隔离配置**
  - 在本机生成 RSA-2048 证书，通过你已认证的 SSH 通道直接注入远端 `host_state.json`，完全跳过浏览器输入 PIN 码。
  - 内置 Linux 多用户宿主机隔离配置管理（独立虚拟 Xorg `:99`、独立 `CUDA_VISIBLE_DEVICES`、静音虚拟音频汇 `sunshine_virtual_sink`、多用户错开端口池），启动时通过 SHA-256 自动检测差异并同步远端服务。
- **完整 SSH 设备管理 & ControlMaster 高速实时监控**
  - 支持图形化新增、编辑、置顶、筛选与删除 `~/.ssh/config` 主机配置（完整保留注释、`Include` 文件与自定义字段）。
  - 采用隔离的 SSH `ControlMaster` 短连接复用（`/tmp/ndmux-<uid>/%C`，60 秒空闲自动退出），高速采集 CPU、内存、磁盘、NVIDIA/AMD 显卡、Slurm（`sinfo`）集群状态及**带完整启动参数的高负载进程列表**。
- **SSH 端口转发（`-L` / `-R` / `-D`）、GOST 隧道、VS Code 与目录挂载**
  - 一键管理本地/远程/SOCKS5 端口转发（Jupyter、TensorBoard、WebUI、API），支持自启与浏览器直达。
  - 内置 GOST QUIC + 原生 POSIX UDP 隧道管理器。
  - 自动发现 VS Code Remote-SSH 工作区，并支持 macOS 原生 **SMB3 + `rclone nfsmount`** 挂载远端目录到访达。

---

## 技术架构与安全透明

应用内置 **「技术原理与安全透明」** 交互面板（点击侧边栏盾牌图标或 Linux 标题栏按钮即可打开），让每一处本地配置路径与底层安全边界清晰可见、随时可审：

```text
┌─────────────────────────────┐         局域网直连 / WireGuard / SSH         ┌─────────────────────────────┐
│        本机 NodeDeck        │ ◄══════════════════════════════════════════► │    你的 Linux / Mac 主机    │
│ • VideoToolbox / VAAPI/CUDA │          SSH · TLS · AES-GCM · Opus          │ • OpenSSH (ControlMaster)   │
│ • 本机 RSA-2048 证书        │            （零云端 · 零遥测）               │ • nodedeck-host (Sunshine)  │
│ • ~/.ssh/config 托管        │                                              │ • 多用户 :99 独立虚拟屏隔离 │
└─────────────────────────────┘                                              └─────────────────────────────┘
```

- **零云端、无账号**：主机列表（`~/.ssh/config`）、客户端证书（macOS 位于 `~/Library/Application Support/NodeDeck`，Linux 位于 `~/.config/nodedeck`）与全部设置均严格保存在本机。
- **绝不保存明文密码**：后台监控统一使用 `BatchMode=yes` 与你的 SSH 公钥认证；免 PIN 配对时输入的可选密码仅用于当次 SSH 校验，绝不落盘或外发。
- **默认隐私保护**：剪贴板自动推送默认关闭；不包含任何统计埋点或远端上报逻辑。

---

## 安装方式

### macOS（14.0+，Apple Silicon / Intel）

1. 前往 [GitHub Releases](../../releases/latest) 下载 `NodeDeck-macos-universal.zip`。
2. 解压后将 `NodeDeck.app` 拖入 `/Applications`。
3. 发布包采用本地自签名（未经 Apple 公证），首次打开若提示拦截，可右键点击 **打开** 或执行：

```bash
xattr -dr com.apple.quarantine "/Applications/NodeDeck.app"
```

### Linux（Ubuntu 22.04 / 24.04 & Debian x86_64）

前往 [GitHub Releases](../../releases/latest) 下载 `nodedeck_2.0.0_amd64.deb`，使用 `apt` 安装（自动补齐 GTK3、SDL2、FFmpeg 与 Opus 依赖）：

```bash
sudo apt install ./nodedeck_2.0.0_amd64.deb
nodedeck
```

---

## 从源码构建

### macOS

需安装 Xcode / Swift 6 工具链与 Homebrew 依赖（`openssl@3`、`opus`）：

```bash
brew install openssl@3 opus
swift test
UNIVERSAL=0 INSTALL=1 ./scripts/build-app.sh release
open "/Applications/NodeDeck.app"
```

> `Package.swift` 会自动探测 `HOMEBREW_PREFIX`、`/opt/homebrew` 与 `/usr/local` 下的 OpenSSL 3 和 Opus（也可通过 `NODEDECK_OPENSSL_PREFIX` / `NODEDECK_OPUS_PREFIX` 自定义）。

### Linux

```bash
# 直接编译安装到 /opt/nodedeck
sudo ./linux/install-linux.sh

# 或打包生成标准 .deb 安装包至 artifacts/
./linux/build-deb.sh
```

---

## SSH 配置示例

NodeDeck 直接兼容并管理标准 `~/.ssh/config`：

```sshconfig
Host gpu-workstation
  HostName 203.0.113.10
  Port 22
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
```

---

## 开源协议与第三方声明

- NodeDeck 一方 Swift / Python 代码采用 **MIT 协议**（详见 [LICENSE](LICENSE)）。
- 内置串流协议层 `moonlight-common-c`（**GPL-3.0**）及可选宿主机服务 `Sunshine` / `nodedeck-host`（**GPL-3.0**）的完整组件清单与分发说明详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
