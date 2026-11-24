# NodeDeck

<p align="center">
  <img src="docs/icon.png" alt="NodeDeck icon" width="128" />
</p>

<p align="center">
  <a href="README_zh.md"><strong>简体中文</strong></a> ·
  <a href="#highlights">Features</a> ·
  <a href="#architecture--security">Architecture &amp; Security</a> ·
  <a href="#install">Install</a> ·
  <a href="#build-from-source">Build</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-1f6f78?style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Linux-Ubuntu%20%2F%20Debian-2b5876?style=flat-square" alt="Linux" />
  <img src="https://img.shields.io/badge/Zero--Cloud-Local--First-2d6a4f?style=flat-square" alt="Zero Cloud" />
  <img src="https://img.shields.io/badge/License-MIT%20%2B%20GPL--3.0-4a5568?style=flat-square" alt="License" />
</p>

**NodeDeck** is a zero-cloud, local-first operations deck for GPU workstations, lab servers, mesh nodes, and HPC clusters — natively built for **macOS (SwiftUI + VideoToolbox)** and **Linux (GTK3 + FFmpeg VAAPI/CUDA + SDL2)**.

It unifies OpenSSH device management, live CPU/GPU/Slurm/process telemetry, built-in hardware-accelerated Moonlight/Sunshine remote desktop streaming, SSH port forwarding, VS Code Remote-SSH workspaces, and Finder directory mounts in one lightweight desktop app — with **no cloud relay, no user accounts, and zero telemetry**.

---

## Highlights

- **Clean Tabbed Workspace & Instant Bilingual UI (`中文 / English`)**
  - Distraction-free detail view split into **Overview**, **Desktop & Network**, and **Workspace** tabs with live activity badges.
  - One-click runtime language switching (**System / 简体中文 / English**) on both macOS and Linux — no restart required.
- **All-in-One Built-in Remote Desktop Client & Headless Host (No External Moonlight or Sunshine Required)**
  - **Built-in Client**: Embeds `moonlight-common-c` (`RTSP + ENet + FEC`) with native **VideoToolbox** HEVC/H.264 decoding on macOS and automatic **FFmpeg VAAPI (Intel/AMD) → CUDA/NVDEC (NVIDIA)** hardware decoding on Linux.
  - **Built-in Headless Host (`nodedeck-host`)**: Compiled directly from open-source `third_party/sunshine` with `-DSUNSHINE_ENABLE_TRAY=OFF` (zero Qt6, zero external DMG/installer bloat). Start/stop the local host in one click on both macOS (`NodeDeckHost.app`, `LSUIElement=true`) and Linux (`/opt/nodedeck/host` + `systemd --user`).
  - Native low-latency keyboard engine (full Win32 VK + extended-key + repeat filtering + focus-loss key release), **Relative Mouse Lock** (`⌃⌥⇧M` / `Ctrl+Alt+Shift+M`) for 3D/CAD/FPS, **Automatic Bidirectional SSH Clipboard Sync** (auto-detects X11 `:99`/`:0` & Wayland), **Privacy Screen**, and a real-time RTT / bitrate / transport-route telemetry HUD.
- **Zero-PIN SSH Certificate Pairing & Linux Multi-User Isolation**
  - Generates an RSA-2048 client certificate locally and injects it into your remote Sunshine / `nodedeck-host` over your authenticated SSH session — no manual browser PIN entry.
  - Manage per-user Linux host isolation profiles (isolated Xorg virtual display `:99`, dedicated `CUDA_VISIBLE_DEVICES`, silent virtual audio sink, disjoint port pool) with automatic SHA-256 config drift reconciliation.
- **Full SSH Device CRUD & Multiplexed Live Telemetry**
  - Add, edit, pin, filter, and delete hosts directly in `~/.ssh/config` (preserving comments, `Include` files, and custom directives).
  - Uses an isolated SSH `ControlMaster` socket (`/tmp/ndmux-<uid>/%C`, 60s idle auto-exit) for fast polling of CPU, RAM, swap, disk, NVIDIA & AMD GPUs, Slurm (`sinfo`) nodes, and **Top Processes with full command-line arguments**.
- **SSH Port Forwarding (`-L` / `-R` / `-D`), VS Code & Mounts**
  - One-click local/remote/SOCKS5 SSH port forwards (Jupyter, TensorBoard, WebUI, APIs) with auto-start and browser launch.
  - Automatic VS Code Remote-SSH workspace discovery and native macOS **SMB3 + `rclone nfsmount`** directory mounting into Finder.

---

## Architecture & Security

NodeDeck includes an in-app **How It Works & Security Model** panel (`shield.checkered` icon in the sidebar / header bar) so users can inspect every local storage path and protocol boundary directly inside the app.

```text
┌─────────────────────────────┐         Direct LAN / WireGuard / SSH         ┌─────────────────────────────┐
│     Local NodeDeck Client   │ ◄══════════════════════════════════════════► │    Your Linux / Mac Host    │
│ • VideoToolbox / VAAPI/CUDA │          SSH · TLS · AES-GCM · Opus          │ • OpenSSH (ControlMaster)   │
│ • Local RSA-2048 Certs      │       (Zero Cloud · Zero Telemetry)          │ • nodedeck-host (Sunshine)  │
│ • ~/.ssh/config Managed     │                                              │ • Multi-User :99 Isolation  │
└─────────────────────────────┘                                              └─────────────────────────────┘
```

- **Zero Cloud & No Account**: All host lists (`~/.ssh/config`), client certificates (`~/Library/Application Support/NodeDeck` on macOS, `~/.config/nodedeck` on Linux), and runtime settings stay strictly on your local machine.
- **No Plaintext Password Storage**: Background metric probes run with `BatchMode=yes` using your SSH keys; optional credentials entered during Zero-PIN pairing are used solely for that SSH verification step and are never written to disk.
- **Privacy by Default**: Telemetry, crash reporting, and cloud relays do not exist; bidirectional clipboard sync runs strictly over your local SSH session and can be toggled anytime in the stream HUD.

---

## Install

Both release packages are **All-in-One** bundles containing **both** the built-in Moonlight client and the source-built headless Sunshine host (`nodedeck-host`) — no external Moonlight or Sunshine installation required.

### macOS (14.0+, Apple Silicon)

1. Download `NodeDeck-macos-arm64.zip` from [GitHub Releases](../../releases/latest).
2. Unzip and move `NodeDeck.app` to `/Applications`.
3. Because release binaries are ad-hoc signed (not notarized), remove the quarantine attribute on first launch if macOS warns:

```bash
xattr -dr com.apple.quarantine "/Applications/NodeDeck.app"
```

> To allow other devices to connect to this Mac via the built-in host, grant **Screen & System Audio Recording** and **Accessibility** permissions when enabling **Local Host** in System Settings.

### Linux (Ubuntu 22.04 / 24.04 & Debian x86_64)

Download `nodedeck_2.0.0_amd64.deb` from [GitHub Releases](../../releases/latest) and install with `apt` (automatically resolves GTK3, SDL2, FFmpeg, Opus, and `nodedeck-host` runtime libraries):

```bash
sudo apt install ./nodedeck_2.0.0_amd64.deb
nodedeck
```

---

## Build from Source

Clone with submodules so the open-source `third_party/sunshine` host code is included:

```bash
git clone --recursive https://github.com/LockedFlysher/NodeDeck.git
cd NodeDeck
```

### macOS

Requires Xcode / Swift 6 toolchain and Homebrew (`openssl@3`, `opus`, `cmake`, `ninja`, `pkgconf`, `boost`, `miniupnpc`):

```bash
brew install openssl@3 opus cmake ninja pkgconf boost miniupnpc
# 1. Build headless zero-Qt Sunshine host from third_party/sunshine
./scripts/build-host-macos.sh
# 2. Run tests and package All-in-One NodeDeck.app (embeds NodeDeckHost.app)
swift test
UNIVERSAL=0 INSTALL=1 ./scripts/build-app.sh release
open "/Applications/NodeDeck.app"
```

> `Package.swift` automatically resolves OpenSSL 3 and Opus from `HOMEBREW_PREFIX`, `/opt/homebrew`, or `/usr/local` (or custom `NODEDECK_OPENSSL_PREFIX` / `NODEDECK_OPUS_PREFIX` overrides).

### Linux

```bash
# 1. Build headless zero-Qt Sunshine host from third_party/sunshine (into .build/host-linux)
./linux/build-host-linux.sh

# 2. Build All-in-One .deb package (Client + Built-in nodedeck-host) into artifacts/
BUNDLE_HOST=1 ./linux/build-deb.sh
```

---

## Configuration Example

NodeDeck reads and manages standard OpenSSH entries in `~/.ssh/config`:

```sshconfig
Host gpu-workstation
  HostName 203.0.113.10
  Port 22
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
```

---

## License & Third-Party Notices

- NodeDeck's first-party Swift and Python source code is licensed under the **MIT License** ([LICENSE](LICENSE)).
- NodeDeck embeds `moonlight-common-c` (**GPL-3.0**) and compiles `Sunshine` (`third_party/sunshine` → headless `nodedeck-host`, **GPL-3.0**) directly from source. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the complete component & distribution compliance table.
