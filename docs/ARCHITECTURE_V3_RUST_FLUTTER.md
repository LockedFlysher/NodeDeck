# NodeDeck v3.0 跨平台统一架构方案（ADR-001：方案 1B 渐进式落地）

> **状态**：已敲定（2026-11-28）  
> **决策路线**：`1B`（Rust 单一逻辑主干 + Flutter 统一 UI）+ `2`（核心主干纯 Rust，Linux 彻底去 Python/GTK）+ `3`（三期渐进式迁移，确保 v2.x 随时可用、零中断）

---

## 1. 背景与目标

NodeDeck v2.1.0 当前代码总量 ~37.3k LOC，分散在 Swift（17.1k）、Kotlin（12.8k）、Python/C（6.4k）与 Server Python（1.0k）四套代码栈中：
- 控制面、EasyTier 配置与链路探测、Sunshine/Moonlight 配对与会话协商、SSH 配置/指标解析、码率数学、悬浮窗逻辑被迫写 3 份，易出现功能漂移。
- Linux `.deb` 强依赖宿主 `glibc` / `libssl3t64` / `python3-gi` / `GTK3`，在 Ubuntu 24.04 → 26.04 等发行版大版本升级时极易触发 ABI/运行环境兼容性问题。

**v3.0 目标**：
1. **逻辑主干 100% 单一真相源（Rust `nodedeck-core`）**，全平台零重复实现。
2. **UI 层通过 Flutter + `flutter_rust_bridge` 达成 1:1 跨平台一致性**（macOS / Linux / Android，并天然预留 Windows / iOS 能力）。
3. **底层硬适配严格按平台隔离（Platform Adapter Traits）**：硬件视频编解码渲染、音频输出、系统 VPN/TUN、特权提权与录屏采集保持原生零拷贝与系统最佳体验。
4. **Linux 发行版抗升级底座**：在 Ubuntu 22.04（glibc 2.35）容器构建、`rustls` 静态替代 OpenSSL、以单文件 `AppImage` 为主分发形态（辅以极简 `.deb` 仅管 systemd/`setcap`）。

---

## 2. 目标分层架构（对标 `rustdesk/rustdesk` + `EasyTier/EasyTier` + `SunshineStream/Sunshine`）

```text
+------------------------------------------------------------------------+
|  Unified UI Layer: Flutter (Dart) — macOS / Linux / Android / Windows  |
|  - Host List / Metrics / Remote Desktop & Stream Path / Floating HUD   |
|  - Account / Mesh Status / SFTP / Terminal / Local Host Encoder Sheet  |
+------------------------------------+-----------------------------------+
                                     | flutter_rust_bridge (async FFI)
+------------------------------------v-----------------------------------+
|  Shared Logic Core: Rust `crates/nodedeck-core` (Single Source of Truth)|
|  - ControlPlaneClient (reqwest + rustls, zero OpenSSL ABI dependency)  |
|  - MeshManager (EasyTier TOML/seed expansion + live peer/route parser) |
|  - SunshineProtocol (RSA-2048 certs, host.conf/file_state, XML launch) |
|  - SshOrchestrator (config parser, metrics parser, host profile sync)  |
|  - StreamMath & Telemetry State Machine (FPS/Bitrate/RTT/Route badge)  |
+------------------------------------+-----------------------------------+
                                     | Platform Adapter Traits
+--------------------+---------------+-----------------+-----------------+
| macOS Adapter      | Linux Adapter                   | Android Adapter |
| - VideoToolbox +   | - FFmpeg VAAPI/NVDEC/SW +       | - MediaCodec +  |
|   AVSampleBuffer   |   SDL2/Vulkan External Texture  |   SurfaceView   |
| - LaunchDaemon     | - systemd --user + setcap       | - VpnService +  |
|   (utun) + TCC     | - pkexec/sudo/sudo-rs + sshd    |   EasyTierJNI   |
| - ScreenCaptureKit | - Wayland KMS / X11 / PipeWire  | - Keystore      |
+--------------------+---------------------------------+-----------------+
```

---

## 3. 三期渐进式迁移路线图（不中断 v2.x 日常使用）

### Phase 1：建立 Rust 工作空间 `crates/nodedeck-core`（替代三端重复协议层）
- **交付物**：
  - `crates/nodedeck-core`：`ControlPlaneClient`（`rustls`）、`EasyTier` 配置生成与 `peer/route` 实时传输模式解析、`SunshineClient` 配对与 `host.conf`/`file_state` 统一解析、`StreamQualityMath`。
  - `crates/nodedeck-mesh-daemon`：纯 Rust 静态二进制替代 `linux/nodedeck_mesh_agent.py`（彻底告别 Linux Python 3.x 与 `libssl3t64` 依赖）。
  - 完整 `cargo test` 单元与契约测试覆盖。
- **验收标准**：`nodedeck-mesh-daemon` 在 Ubuntu 22.04 / 24.04 / 26.04 容器矩阵中零依赖运行并通过 EasyTier UDP/TCP 切换与心跳指令测试。

### Phase 2：搭建 Flutter + `flutter_rust_bridge` 统一控制面板（先攻克 Linux，告别 Python/GTK3）
- **交付物**：
  - `app/`（Flutter）+ `crates/nodedeck-bridge`（`flutter_rust_bridge`）：统一实现主机列表、性能监控、账号与实时 P2P/UDP Relay 链路视图、远程桌面配置、本机编码器设置与端口转发。
  - Linux 端率先切换为 **Flutter UI + `nodedeck-core` + 原生 `nodedeck-stream`（SDL2/VAAPI/CUDA + 1:1 悬浮窗）**，彻底淘汰 `linux/nodedeck_linux.py`。
  - 在 **Ubuntu 22.04 Docker 容器**中构建单文件 **`NodeDeck-x86_64.AppImage`** 与极简 `.deb`（仅装 systemd 单元 + `setcap`）。
- **验收标准**：同一份 `AppImage` 在 Ubuntu 22.04 / 24.04 / 26.04（Wayland & X11）均免装运行，GTK/Python 零依赖。

### Phase 3：macOS & Android 接入统一 Flutter UI + 原生硬件解码表面桥接
- **交付物**：
  - Android / macOS 接入 Flutter External Texture / PlatformView 桥接原生 `MediaCodec` / `VideoToolbox` 零拷贝渲染表面（参考 `rustdesk/rustdesk/flutter` 与 `libs/scrap`）。
  - 统一 `crates/nodedeck-core` 的 SSH / SFTP / 端口转发 / Host Profile 状态机，逐步归档 `Sources/NodeDeck` 与 `android/.../ui` 旧重复代码。
  - GitHub Actions 上线全平台 CI 矩阵（macOS arm64、Android arm64、Linux Ubuntu 22.04/24.04/26.04 + Debian 13）。

---

## 4. 风险控制与红线

1. **绝不推倒重来**：Phase 1–2 期间 macOS SwiftUI 与 Android Compose 保持稳定可用，所有线上 Bug（如网络 UDP 25565 切换、主机发现）优先在主干修复。
2. **串流零拷贝不妥协**：绝不用 WebView 承载 60–165Hz 视频流；Flutter 阶段优先采用独立原生硬件窗口或原生 External Texture 零拷贝管线。
3. **跨发行版最低 glibc 基线**：Linux 构建环境严格锁在 Ubuntu 22.04 LTS（glibc 2.35），禁止直接拿 Ubuntu 26.04 宿主机产物作为通用 Release。
