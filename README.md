# SSH Deck

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1f6f78?style=flat-square)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-2d6a4f?style=flat-square)](LICENSE)

SSH Deck is a native macOS dashboard for the hosts you already manage in OpenSSH. It reads your SSH config, checks host availability, and turns a remote machine into a compact operations view without storing passwords or sending telemetry.

![SSH Deck icon](docs/icon.png)

## Highlights

- Discovers concrete `Host` entries from `~/.ssh/config`, including `Include` files and grouped multi-alias lines
- Resolves the effective hostname, user, port, identity file, jump host, local forwards, and route type (`Local Tunnel`, `LAN Direct`, `Remote`) concurrently with `ssh -G`
- Streams live host probe results as each host responds instead of blocking on slow or offline nodes
- Discovers **VS Code Remote-SSH workspaces** (`storage.json` + `workspaceStorage`) per host — distinguishing **Focused / Open in VS Code** active windows from recent workspaces — with one-click window switching, custom remote folder opening (`⇧⌘V`), and Finder mount integration
- Integrates native macOS directory mounting (`rclone nfsmount` over SFTP/SSH without macFUSE or `sudo`, plus external SMB/NFS mount detection) with one-click Finder, Terminal, and background auto-mount support
- Built-in **GOST QUIC + Direct LAN UDP Tunnel Manager** (`~/Library/Application Support/SSHDeck/tunnels.json`) that starts tunnels automatically with SSH Deck, pairs QUIC TCP control channels with sub-millisecond native POSIX UDP media relays (`udp-direct://`), monitors health/ports, and cleanly terminates child `gost` processes when SSH Deck quits
- Native **macOS Menu Bar resident icon** (`NSStatusItem` + `NSPopover`) with live active-tunnel badge, quick tunnel switches, one-click **Moonlight NVENC** remote desktop launch (`⇧⌘D`), VS Code & Finder shortcuts, and **Launch at Login** toggle (`--background` silent startup; closing the main window via `×` or `⌘W` hides the Dock icon cleanly into the Menu Bar)
- Shows CPU, memory, swap, disk (including free capacity), load, uptime, and true SSH round-trip latency
- Shows NVIDIA & AMD GPU utilization, VRAM in GB, temperature warnings, and power
- Shows the top remote processes by CPU usage
- Detects Slurm with `sinfo` and summarizes idle, fully allocated, and partially used nodes
- Filters hosts (`All`, `Online`, `Mounted`, `GPU`), pins favorite hosts, and supports context menus and keyboard shortcuts (`⌘R`, `⇧⌘R`, `⌘F`, `⌘↩`, `⇧⌘O`, `⇧⌘M`)
- Keeps the last successful metrics when a host goes offline

## Requirements

- macOS 14 or newer
- OpenSSH available at `/usr/bin/ssh`
- Public-key authentication for hosts that should be monitored automatically
- Linux remotes for the complete metric set (`/proc`, `df`, and optional `nvidia-smi`)
- Slurm `sinfo` available on a remote host for the cluster section

SSH Deck uses `BatchMode=yes` for background probes. It does not prompt for passwords and does not store them. Add your public key to each host's `authorized_keys` if you want automatic metrics.

## Install

Download the latest release zip, unzip it, and move `SSH Deck.app` to `/Applications`.

The release is ad-hoc signed and is not notarized. If macOS blocks the first launch, open it from Finder with the context menu and choose **Open**. On macOS versions that quarantine the download, you can also run:

```bash
xattr -dr com.apple.quarantine "/Applications/SSH Deck.app"
```

The first time you use **Open Terminal**, macOS may ask for permission for SSH Deck to control Terminal.

## Build

```bash
swift test
./scripts/build-app.sh
open "dist/SSH Deck.app"
```

`build-app.sh` builds a universal binary for Apple Silicon and Intel Macs by default. Set `UNIVERSAL=0` to build only the current architecture:

```bash
UNIVERSAL=0 ./scripts/build-app.sh
```

The release artifact is written to:

```text
artifacts/SSHDeck-macos-universal.zip
```

## Configuration

SSH Deck is read-only with respect to SSH configuration. It uses your existing aliases, for example:

```sshconfig
Host gpu-workstation
  HostName 203.0.113.10
  Port 6051
  User example
  IdentityFile ~/.ssh/id_ed25519
```

Aliases can contain letters, numbers, hyphens, and dots. Use `Include` if you split configuration across multiple files.

## Security And Privacy

- Reads `~/.ssh/config` and runs the local OpenSSH client
- Does not store, display, or transmit passwords
- Does not upload host data, metrics, or analytics
- Runs only read-only remote shell commands for metrics
- Disables local port forwarding for background probes
- Respects OpenSSH host-key verification and authentication settings

## Limitations

- Full metrics currently target Linux `/proc`
- Non-Linux hosts can still show SSH availability and connection configuration
- GPU metrics depend on `nvidia-smi`
- Slurm metrics depend on `sinfo`

## License

MIT
