#!/usr/bin/env python3
"""NodeDeck for Linux (GTK3 + Built-in moonlight-common-c / FFmpeg VAAPI+CUDA / SDL2 Streamer)."""

import base64
import hashlib
import json
import os
import random
import re
import secrets
import ssl
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

SSH_CONFIG = Path.home() / ".ssh" / "config"
CONF_DIR = Path.home() / ".config" / "nodedeck"
FORWARDS_FILE = CONF_DIR / "port-forwards.json"
SUNSHINE_FILE = CONF_DIR / "sunshine-hosts.json"
PROFILES_FILE = CONF_DIR / "host-profiles.json"
SETTINGS_FILE = CONF_DIR / "settings.json"
CERT_DIR = CONF_DIR / "moonlight"
SSH_MUX_DIR = Path(f"/tmp/ndmux-{os.getuid()}")


def detect_default_lang() -> str:
    env_lang = (os.getenv("LC_ALL") or os.getenv("LANG") or "").lower()
    return "zh" if env_lang.startswith("zh") else "en"


def resolve_stream_bin() -> str:
    candidates = [
        Path.home() / ".local" / "share" / "nodedeck" / "nodedeck-stream",
        Path("/opt/nodedeck/nodedeck-stream"),
    ]
    for path in candidates:
        if path.exists() and os.access(path, os.X_OK):
            return str(path)
    return "/opt/nodedeck/nodedeck-stream"


def resolve_host_bin() -> str:
    candidates = [
        Path.home() / ".local" / "share" / "nodedeck" / "host" / "bin" / "nodedeck-host",
        Path("/opt/nodedeck/host/bin/nodedeck-host"),
        Path("/usr/bin/sunshine"),
        Path("/usr/local/bin/sunshine"),
    ]
    for path in candidates:
        if path.exists() and os.access(path, os.X_OK):
            return str(path)
    return ""


def is_local_host_running() -> bool:
    try:
        r = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", "nodedeck-host.service"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    try:
        r = subprocess.run(
            ["pgrep", "-f", r"(^|/)nodedeck-host($| )|(^|/)sunshine($| )"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
        return r.returncode == 0
    except Exception:
        return False


def has_user_host_service() -> bool:
    for p in (
        Path.home() / ".config/systemd/user/nodedeck-host.service",
        Path("/usr/lib/systemd/user/nodedeck-host.service"),
        Path("/etc/systemd/user/nodedeck-host.service"),
    ):
        if p.exists():
            return True
    return False


def ensure_local_host_config() -> Path:
    host_dir = CONF_DIR / "host"
    host_dir.mkdir(parents=True, exist_ok=True)
    apps_file = host_dir / "apps.json"
    if not apps_file.exists():
        apps_file.write_text(
            json.dumps({"env": {}, "apps": [{"name": "Desktop", "image-path": "desktop.png"}]}, indent=2),
            encoding="utf-8",
        )
    conf_file = host_dir / "host.conf"
    if not conf_file.exists():
        conf_file.write_text(
            "\n".join(
                [
                    "# Managed by NodeDeck Built-in Host",
                    f"sunshine_name = {os.uname().nodename}",
                    "port = 47989",
                    f"file_apps = {apps_file}",
                    f"file_state = {host_dir / 'host_state.json'}",
                    f"credentials_file = {host_dir / 'credentials.json'}",
                    f"pkey = {host_dir / 'host.key'}",
                    f"cert = {host_dir / 'host.cert'}",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
    return conf_file


def resolve_icon_path() -> str:
    candidates = [
        Path.home() / ".local" / "share" / "nodedeck" / "nodedeck.png",
        Path("/opt/nodedeck/nodedeck.png"),
        Path("/usr/share/pixmaps/nodedeck.png"),
    ]
    for path in candidates:
        if path.exists():
            return str(path)
    return ""


def ssh_mux_base_args(alias: str, connect_timeout: int = 5):
    SSH_MUX_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(SSH_MUX_DIR, 0o700)
    except OSError:
        pass
    return [
        "ssh",
        "-T",
        "-o", "BatchMode=yes",
        "-o", "ControlMaster=auto",
        "-o", f"ControlPath={SSH_MUX_DIR}/%C",
        "-o", "ControlPersist=60",
        "-o", f"ConnectTimeout={connect_timeout}",
        "-o", "ClearAllForwardings=yes",
        "-o", "LogLevel=ERROR",
        alias,
    ]


def ensure_client_cert():
    CERT_DIR.mkdir(parents=True, exist_ok=True)
    cert = CERT_DIR / "client.crt"
    key = CERT_DIR / "client.key"
    uid_file = CERT_DIR / "uniqueid.txt"
    if not cert.exists() or not key.exists():
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key), "-out", str(cert),
                "-days", "7300", "-subj", "/CN=NVIDIA GameStream Client",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        os.chmod(key, 0o600)
    if not uid_file.exists():
        uid_file.write_text(secrets.token_hex(8), encoding="utf-8")
    return cert, key, uid_file.read_text(encoding="utf-8").strip()


def parse_ssh_hosts():
    if not SSH_CONFIG.exists():
        return []
    hosts = []
    cur = None
    for raw in SSH_CONFIG.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        k, v = parts[0].lower(), parts[1].strip()
        if k == "host":
            aliases = [a for a in v.split() if "*" not in a and "?" not in a and not a.startswith("!")]
            if aliases:
                cur = {
                    "alias": aliases[0],
                    "alternates": aliases[1:],
                    "hostname": aliases[0],
                    "user": os.getenv("USER", "root"),
                    "port": "22",
                }
                hosts.append(cur)
            else:
                cur = None
        elif cur is not None:
            if k == "hostname":
                cur["hostname"] = v
            elif k == "user":
                cur["user"] = v
            elif k == "port":
                cur["port"] = v
    return hosts


def append_ssh_host(alias, hostname, user, port="22"):
    SSH_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    block = f"\nHost {alias}\n  HostName {hostname}\n  User {user}\n"
    if port and port != "22":
        block += f"  Port {port}\n"
    with open(SSH_CONFIG, "a", encoding="utf-8") as f:
        f.write(block)
    os.chmod(SSH_CONFIG, 0o600)


def update_ssh_host(old_alias, new_alias, hostname, user, port="22"):
    if not SSH_CONFIG.exists():
        append_ssh_host(new_alias, hostname, user, port)
        return
    lines = SSH_CONFIG.read_text(encoding="utf-8", errors="ignore").splitlines()
    out = []
    in_target = False
    replaced_fields = set()

    def flush_missing():
        if "hostname" not in replaced_fields:
            out.append(f"  HostName {hostname}")
        if "user" not in replaced_fields:
            out.append(f"  User {user}")
        if port and port != "22" and "port" not in replaced_fields:
            out.append(f"  Port {port}")

    for line in lines:
        stripped = line.strip()
        if stripped.lower().startswith("host "):
            if in_target:
                flush_missing()
                in_target = False
            tokens = stripped.split()[1:]
            if old_alias in tokens:
                in_target = True
                replaced_fields.clear()
                new_tokens = [new_alias if t == old_alias else t for t in tokens]
                out.append("Host " + " ".join(new_tokens))
                continue
        if in_target:
            parts = stripped.split(None, 1)
            if len(parts) == 2:
                k = parts[0].lower()
                if k == "hostname":
                    out.append(f"  HostName {hostname}")
                    replaced_fields.add("hostname")
                    continue
                if k == "user":
                    out.append(f"  User {user}")
                    replaced_fields.add("user")
                    continue
                if k == "port":
                    if port and port != "22":
                        out.append(f"  Port {port}")
                    replaced_fields.add("port")
                    continue
        out.append(line)
    if in_target:
        flush_missing()

    SSH_CONFIG.write_text("\n".join(out).strip() + "\n", encoding="utf-8")
    os.chmod(SSH_CONFIG, 0o600)


def delete_ssh_host(alias):
    if not SSH_CONFIG.exists():
        return
    lines = SSH_CONFIG.read_text(encoding="utf-8", errors="ignore").splitlines()
    out = []
    skip = False
    for line in lines:
        stripped = line.strip()
        if stripped.lower().startswith("host "):
            tokens = stripped.split()[1:]
            if alias in tokens:
                skip = True
                continue
            skip = False
        if not skip:
            out.append(line)
    SSH_CONFIG.write_text("\n".join(out).strip() + "\n", encoding="utf-8")
    os.chmod(SSH_CONFIG, 0o600)


def load_json(path, default):
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return default


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


METRICS_SCRIPT = r"""
printf 'ND_BEGIN\n'
printf 'OS=%s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-$(uname -s)}")"
printf 'KERNEL=%s\n' "$(uname -sr 2>/dev/null)"
printf 'CORES=%s\n' "$(nproc 2>/dev/null || echo 0)"
set -- $(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat 2>/dev/null)
t1=$(( ${1:-0}+${2:-0}+${3:-0}+${4:-0}+${5:-0}+${6:-0}+${7:-0}+${8:-0} ))
i1=$(( ${4:-0}+${5:-0} ))
sleep 0.2 2>/dev/null || sleep 1
set -- $(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat 2>/dev/null)
t2=$(( ${1:-0}+${2:-0}+${3:-0}+${4:-0}+${5:-0}+${6:-0}+${7:-0}+${8:-0} ))
i2=$(( ${4:-0}+${5:-0} ))
printf 'CPU=%s\n' "$(awk -v t1="$t1" -v i1="$i1" -v t2="$t2" -v i2="$i2" 'BEGIN{dt=t2-t1;di=i2-i1;printf "%.1f", (dt>0 ? 100*(dt-di)/dt : 0)}')"
mt=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
ma=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
printf 'MEM_TOTAL_MB=%s\n' "$(( ${mt:-0} / 1024 ))"
printf 'MEM_USED_MB=%s\n' "$(( (${mt:-0} - ${ma:-0}) / 1024 ))"
df -Pm / 2>/dev/null | awk 'NR==2 {printf "DISK_USED_GB=%.1f\nDISK_TOTAL_GB=%.1f\n", $3/1024, $2/1024}'
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] && printf 'GPU=%s\n' "$line"
  done
fi
ps -ww -eo pcpu=,pmem=,args= --sort=-pcpu 2>/dev/null | head -n 5 | awk 'NF >= 3 { cpu=$1; mem=$2; $1=""; $2=""; sub(/^[[:space:]]+/, ""); gsub(/\|/, " "); if (length($0) > 180) $0 = substr($0, 1, 177) "..."; printf "PROC=%s|%s|%s\n", $0, cpu, mem }'
printf 'ND_END\n'
"""


def collect_remote_metrics(alias: str):
    t0 = time.monotonic()
    res = subprocess.run(
        ssh_mux_base_args(alias, connect_timeout=5) + ["/bin/sh", "-s"],
        input=METRICS_SCRIPT.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=12,
    )
    elapsed_ms = max(1, int((time.monotonic() - t0) * 1000) - 200)
    if res.returncode != 0:
        err = res.stderr.decode(errors="ignore").strip() or f"SSH exit {res.returncode}"
        return {"error": err}
    text = res.stdout.decode(errors="ignore")
    if "ND_BEGIN" not in text or "ND_END" not in text:
        return {"error": "Invalid metrics payload"}
    kv = {}
    gpus = []
    procs = []
    for line in text.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "GPU":
            gpus.append([p.strip() for p in v.split(",")])
        elif k == "PROC":
            parts = v.split("|")
            if len(parts) >= 3:
                procs.append((parts[0].strip(), parts[1].strip(), parts[2].strip()))
        else:
            kv[k] = v.strip()
    kv["GPUS"] = gpus
    kv["PROCS"] = procs
    kv["RTT_MS"] = elapsed_ms
    return kv


def profile_digest(profile: dict) -> str:
    canonical = json.dumps(profile, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def reconcile_remote_host_profile(alias: str, profile: dict):
    digest = profile_digest(profile)
    mode = profile.get("mode", "physicalDesktop")
    display = profile.get("display", ":99")
    base_port = int(profile.get("basePort", 47989))
    encoder = profile.get("encoder", "nvenc")
    cuda_idx = str(profile.get("cudaDeviceIndex", "0"))
    virtual_audio = bool(profile.get("virtualAudioSink", False))
    conf_lines = [
        "# Managed by NodeDeck Host Profile",
        f"port = {base_port}",
        f"encoder = {encoder}",
        f"capture = {'x11' if mode == 'isolatedVirtualDesktop' else 'kms'}",
        "file_state = $HOME/.config/nodedeck/host_state.json",
    ]
    if virtual_audio:
        conf_lines.append("audio_sink = sunshine_virtual_sink")
    conf_text = "\n".join(conf_lines) + "\n"
    conf_b64 = base64.b64encode(conf_text.encode("utf-8")).decode("ascii")
    profile_b64 = base64.b64encode(json.dumps(profile, indent=2).encode("utf-8")).decode("ascii")

    remote_script = f"""
set -e
mkdir -p "$HOME/.config/nodedeck"
printf '%s' '{profile_b64}' | base64 -d > "$HOME/.config/nodedeck/host-profile.json"
printf '%s' '{conf_b64}' | base64 -d > "$HOME/.config/nodedeck/host.conf"
printf '%s\\n' '{digest}' > "$HOME/.config/nodedeck/host-profile.sha256"
SVC_FILE="$HOME/.config/systemd/user/nodedeck-host.service"
if [ -f "$SVC_FILE" ]; then
  if [ "{mode}" = "isolatedVirtualDesktop" ]; then
    grep -q '^Environment=DISPLAY=' "$SVC_FILE" && sed -i 's|^Environment=DISPLAY=.*|Environment=DISPLAY={display}|' "$SVC_FILE" || sed -i '/^\\[Service\\]/a Environment=DISPLAY={display}' "$SVC_FILE"
    grep -q '^Environment=CUDA_VISIBLE_DEVICES=' "$SVC_FILE" && sed -i 's|^Environment=CUDA_VISIBLE_DEVICES=.*|Environment=CUDA_VISIBLE_DEVICES={cuda_idx}|' "$SVC_FILE" || sed -i '/^\\[Service\\]/a Environment=CUDA_VISIBLE_DEVICES={cuda_idx}' "$SVC_FILE"
  fi
  systemctl --user daemon-reload || true
  systemctl --user restart nodedeck-host.service || true
  echo "RELOADED"
else
  echo "WRITTEN"
fi
"""
    res = subprocess.run(
        ssh_mux_base_args(alias, connect_timeout=6) + ["/bin/sh", "-c", remote_script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
    )
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode(errors="ignore").strip() or f"SSH exit {res.returncode}")
    return res.stdout.decode(errors="ignore").strip()


class NodeDeckWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="NodeDeck (Linux)")
        self.set_default_size(1060, 720)
        icon_path = resolve_icon_path()
        if icon_path:
            try:
                self.set_icon_from_file(icon_path)
            except Exception:
                pass
        self.hosts = []
        self.selected_host = None
        self.forwards = load_json(FORWARDS_FILE, [])
        self.forward_procs = {}
        self.sunshine_hosts = load_json(SUNSHINE_FILE, {})
        self.host_profiles = load_json(PROFILES_FILE, {})
        self.settings = load_json(SETTINGS_FILE, {})
        self.lang = self.settings.get("language") or detect_default_lang()
        self.metrics_cache = {}
        self.stream_resolution = "1920x1080x60"
        self.stream_hwaccel = "auto"
        self.active_tab_index = 0

        self.hb = Gtk.HeaderBar()
        self.hb.set_show_close_button(True)
        self.hb.props.title = "NodeDeck"
        self.set_titlebar(self.hb)

        self.btn_add = Gtk.Button()
        self.btn_add.connect("clicked", self.on_add_device)
        self.hb.pack_start(self.btn_add)

        self.btn_host = Gtk.Button()
        self.btn_host.connect("clicked", self.on_toggle_local_host)
        self.hb.pack_start(self.btn_host)

        self.btn_refresh = Gtk.Button()
        self.btn_refresh.connect("clicked", lambda *_: (self._update_chrome_labels(), self.reload_hosts()))
        self.hb.pack_end(self.btn_refresh)

        self.btn_lang = Gtk.Button()
        self.btn_lang.connect("clicked", self.on_toggle_lang)
        self.hb.pack_end(self.btn_lang)

        self.btn_arch = Gtk.Button()
        self.btn_arch.connect("clicked", self.on_show_architecture)
        self.hb.pack_end(self.btn_arch)

        self._update_chrome_labels()

        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        paned.set_position(250)
        self.add(paned)

        # Left sidebar
        scroll = Gtk.ScrolledWindow()
        self.listbox = Gtk.ListBox()
        self.listbox.connect("row-selected", self.on_select_host)
        scroll.add(self.listbox)
        paned.pack1(scroll, False, False)

        # Right detail pane (scrollable)
        detail_scroll = Gtk.ScrolledWindow()
        self.detail_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.detail_box.set_margin_top(16)
        self.detail_box.set_margin_bottom(16)
        self.detail_box.set_margin_start(16)
        self.detail_box.set_margin_end(16)
        detail_scroll.add(self.detail_box)
        paned.pack2(detail_scroll, True, False)

        self.status_label = Gtk.Label(label="")
        self.status_label.set_xalign(0)
        self.reload_hosts()

    def t(self, zh: str, en: str) -> str:
        return zh if self.lang == "zh" else en

    def _update_chrome_labels(self):
        self.hb.props.subtitle = self.t(
            "零云端 · SSH 管理 · 内置主/被控端 · 多用户隔离",
            "Zero-Cloud · SSH · Built-in Client & Host · Multi-User Isolation",
        )
        self.btn_add.set_label(self.t("+ 添加设备", "+ Add Device"))
        host_bin = resolve_host_bin()
        if not host_bin:
            self.btn_host.set_label(self.t("○ 本机被控端未就绪", "○ Host Missing"))
            self.btn_host.set_sensitive(False)
        elif is_local_host_running():
            self.btn_host.set_label(self.t("● 本机被控端: 运行中", "● Local Host: On"))
            self.btn_host.set_sensitive(True)
        else:
            self.btn_host.set_label(self.t("○ 启动本机被控端", "○ Start Local Host"))
            self.btn_host.set_sensitive(True)
        self.btn_refresh.set_label(self.t("刷新", "Refresh"))
        self.btn_lang.set_label("EN" if self.lang == "zh" else "中文")
        self.btn_arch.set_label(self.t("技术原理与安全", "How It Works"))

    def on_toggle_local_host(self, _btn):
        host_bin = resolve_host_bin()
        if not host_bin:
            return
        running = is_local_host_running()
        try:
            if running:
                if has_user_host_service():
                    subprocess.run(["systemctl", "--user", "stop", "nodedeck-host.service"], timeout=5)
                subprocess.run(["pkill", "-x", "nodedeck-host"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                subprocess.run(["pkill", "-x", "sunshine"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                self.status_label.set_text(self.t("已停止本机被控端服务", "Stopped local host service"))
            else:
                if has_user_host_service():
                    subprocess.run(["systemctl", "--user", "start", "nodedeck-host.service"], check=True, timeout=5)
                else:
                    conf_file = ensure_local_host_config()
                    log_path = CONF_DIR / "host" / "nodedeck-host.log"
                    with open(log_path, "ab") as logf:
                        subprocess.Popen(
                            [host_bin, str(conf_file)],
                            cwd=str(conf_file.parent),
                            stdout=logf,
                            stderr=logf,
                            stdin=subprocess.DEVNULL,
                            start_new_session=True,
                        )
                self.status_label.set_text(self.t("本机被控端服务已启动（端口 47989）", "Local host service started (port 47989)"))
        except Exception as exc:
            self.status_label.set_text(self.t(f"本机被控端操作失败: {exc}", f"Local host error: {exc}"))
        GLib.timeout_add(600, lambda: (self._update_chrome_labels(), False)[1])

    def on_toggle_lang(self, _btn):
        self.lang = "en" if self.lang == "zh" else "zh"
        self.settings["language"] = self.lang
        save_json(SETTINGS_FILE, self.settings)
        self._update_chrome_labels()
        self.render_detail()

    def on_show_architecture(self, _btn):
        dlg = Gtk.Dialog(
            title=self.t("技术原理与安全透明", "How NodeDeck Works & Security Model"),
            transient_for=self,
            flags=0,
        )
        dlg.add_buttons(self.t("关闭", "Done"), Gtk.ResponseType.OK)
        dlg.set_default_size(600, 440)
        box = dlg.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(16)
        box.set_margin_end(16)

        sections = [
            (
                self.t("1. 零云端 · 纯本地信任模型", "1. Zero-Cloud, Local-First Security"),
                self.t(
                    "无账号系统、无第三方中转服务器、无遥测上报。所有 SSH 配置（~/.ssh/config）、RSA-2048 客户端证书（~/.config/nodedeck/moonlight）与隔离配置均严格保存在你的本机。",
                    "No account login, no third-party relay server, and zero telemetry. All SSH configs (~/.ssh/config), RSA-2048 client certs (~/.config/nodedeck/moonlight), and profiles stay strictly on your machine.",
                ),
            ),
            (
                self.t("2. 内置主控端与无头被控端（All-in-One）", "2. Built-in Client & Headless Host (All-in-One)"),
                self.t(
                    "主控端内置开源 moonlight-common-c（RTSP + ENet + FEC）并自动探测 FFmpeg VAAPI/CUDA 硬解；被控端基于开源 Sunshine 源码去除 Qt 编译内置为 nodedeck-host，无需额外安装 Moonlight 或 Sunshine。",
                    "Built-in moonlight-common-c client with automatic FFmpeg VAAPI/CUDA hardware decode, paired with source-built headless zero-Qt Sunshine host (nodedeck-host). No separate Moonlight or Sunshine install required.",
                ),
            ),
            (
                self.t("3. 免 PIN SSH 证书配对与多用户隔离", "3. Zero-PIN SSH Pairing & Multi-User Isolation"),
                self.t(
                    "通过你已认证的 SSH 通道将本机证书直接写入远端 host_state.json；Linux 多用户节点支持独立虚拟 Xorg (:99)、独立 GPU (CUDA_VISIBLE_DEVICES) 与静音音频汇，互不干扰。",
                    "Injects your local certificate into remote host_state.json over your trusted SSH session. Supports isolated virtual Xorg (:99), dedicated GPU binding, and silent virtual audio sinks per user.",
                ),
            ),
            (
                self.t("4. 开源合规说明", "4. Open-Source License Transparency"),
                self.t(
                    "NodeDeck 一方代码为 MIT 协议；内置串流协议 moonlight-common-c 与源码编译内置的 Sunshine (nodedeck-host) 采用 GPL-3.0 协议。",
                    "First-party NodeDeck code is MIT-licensed; embedded moonlight-common-c and source-built Sunshine (nodedeck-host) are GPL-3.0.",
                ),
            ),
        ]
        for heading, desc in sections:
            lbl = Gtk.Label()
            lbl.set_markup(f"<b>{GLib.markup_escape_text(heading)}</b>\n{GLib.markup_escape_text(desc)}")
            lbl.set_line_wrap(True)
            lbl.set_xalign(0)
            box.pack_start(lbl, False, False, 4)

        dlg.show_all()
        dlg.run()
        dlg.destroy()

    def reload_hosts(self):
        prev_alias = self.selected_host["alias"] if self.selected_host else None
        self.hosts = parse_ssh_hosts()
        for child in self.listbox.get_children():
            self.listbox.remove(child)
        target_idx = 0
        for idx, h in enumerate(self.hosts):
            if h["alias"] == prev_alias:
                target_idx = idx
            row = Gtk.ListBoxRow()
            row.host_data = h
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            box.set_margin_top(6)
            box.set_margin_bottom(6)
            box.set_margin_start(10)
            box.set_margin_end(10)
            lbl1 = Gtk.Label(label=h["alias"])
            lbl1.set_xalign(0)
            lbl2 = Gtk.Label(label=f'{h["user"]}@{h["hostname"]}:{h["port"]}')
            lbl2.set_xalign(0)
            lbl2.get_style_context().add_class("dim-label")
            box.pack_start(lbl1, False, False, 0)
            box.pack_start(lbl2, False, False, 0)
            row.add(box)
            self.listbox.add(row)
        self.listbox.show_all()
        if self.hosts:
            self.listbox.select_row(self.listbox.get_row_at_index(target_idx))

    def on_select_host(self, _lb, row):
        if row is None:
            return
        self.selected_host = row.host_data
        self.render_detail()
        if self.selected_host["alias"] not in self.metrics_cache:
            self.refresh_metrics_async(self.selected_host["alias"])

    def refresh_metrics_async(self, alias: str):
        self.status_label.set_text(f"Probing live metrics for {alias}...")

        def worker():
            try:
                data = collect_remote_metrics(alias)
            except Exception as exc:
                data = {"error": str(exc)}
            self.metrics_cache[alias] = data
            GLib.idle_add(self._on_metrics_ready, alias, data)

        threading.Thread(target=worker, daemon=True).start()

    def _on_metrics_ready(self, alias, data):
        if "error" in data:
            self.status_label.set_text(f"{alias}: {data['error']}")
        else:
            self.status_label.set_text(f"{alias} online · RTT {data.get('RTT_MS', '?')} ms")
        if self.selected_host and self.selected_host["alias"] == alias:
            self.render_detail()

    def render_detail(self):
        for child in self.detail_box.get_children():
            self.detail_box.remove(child)
        h = self.selected_host
        if not h:
            return

        # Header
        top = Gtk.Box(spacing=8)
        title = Gtk.Label()
        title.set_markup(
            f'<span size="x-large" weight="bold">{GLib.markup_escape_text(h["alias"])}</span>  '
            f'<span alpha="65%">{GLib.markup_escape_text(h["user"])}@{GLib.markup_escape_text(h["hostname"])}:{h["port"]}</span>'
        )
        title.set_xalign(0)
        top.pack_start(title, True, True, 0)

        btn_term = Gtk.Button(label=self.t("打开终端", "Terminal"))
        btn_term.connect("clicked", lambda *_: subprocess.Popen(["x-terminal-emulator", "-e", "ssh", h["alias"]]))
        top.pack_start(btn_term, False, False, 0)

        saved = self.sunshine_hosts.get(h["alias"])
        if saved:
            btn_top_stream = Gtk.Button(label=self.t("远程桌面", "Remote Desktop"))
            btn_top_stream.get_style_context().add_class("suggested-action")
            btn_top_stream.connect("clicked", lambda *_: self.launch_stream(saved))
            top.pack_start(btn_top_stream, False, False, 0)

        btn_edit = Gtk.Button(label=self.t("编辑", "Edit"))
        btn_edit.connect("clicked", lambda *_: self.on_edit_device(h))
        top.pack_start(btn_edit, False, False, 0)

        btn_del = Gtk.Button(label=self.t("删除", "Delete"))
        btn_del.connect("clicked", lambda *_: (delete_ssh_host(h["alias"]), self.reload_hosts()))
        top.pack_start(btn_del, False, False, 0)
        self.detail_box.pack_start(top, False, False, 0)

        # Tabbed notebook to eliminate vertical clutter (Overview vs Desktop & Network)
        notebook = Gtk.Notebook()
        overview_tab = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        overview_tab.set_margin_top(10)
        overview_tab.set_margin_bottom(10)
        overview_tab.set_margin_start(10)
        overview_tab.set_margin_end(10)

        net_tab = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        net_tab.set_margin_top(10)
        net_tab.set_margin_bottom(10)
        net_tab.set_margin_start(10)
        net_tab.set_margin_end(10)

        # Live System Metrics Card (Tab 1: Overview)
        m_frame = Gtk.Frame(label=self.t("实时系统与 GPU 指标", "Live System & GPU Metrics"))
        m_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        m_vbox.set_margin_top(10)
        m_vbox.set_margin_bottom(10)
        m_vbox.set_margin_start(10)
        m_vbox.set_margin_end(10)

        m_head = Gtk.Box(spacing=8)
        m = self.metrics_cache.get(h["alias"])
        if not m:
            summary_lbl = Gtk.Label(label=self.t("正在探测远端主机…", "Probing remote host..."))
        elif "error" in m:
            summary_lbl = Gtk.Label(label=self.t(f"离线 / 错误: {m['error']}", f"Offline / Error: {m['error']}"))
        else:
            summary_lbl = Gtk.Label(
                label=f"{m.get('OS', 'Linux')} ({m.get('KERNEL', '')}) · {m.get('CORES', '?')} cores · RTT {m.get('RTT_MS', '?')} ms"
            )
        summary_lbl.set_xalign(0)
        m_head.pack_start(summary_lbl, True, True, 0)
        btn_probe = Gtk.Button(label=self.t("刷新指标", "Refresh Metrics"))
        btn_probe.connect("clicked", lambda *_: self.refresh_metrics_async(h["alias"]))
        m_head.pack_start(btn_probe, False, False, 0)
        m_vbox.pack_start(m_head, False, False, 0)

        if m and "error" not in m:
            cpu_pct = float(m.get("CPU", "0") or 0)
            mem_used = int(m.get("MEM_USED_MB", "0") or 0)
            mem_tot = max(1, int(m.get("MEM_TOTAL_MB", "1") or 1))
            disk_used = float(m.get("DISK_USED_GB", "0") or 0)
            disk_tot = max(0.1, float(m.get("DISK_TOTAL_GB", "1") or 1))

            for label_text, frac in [
                (f"CPU: {cpu_pct:.1f}%", min(1.0, cpu_pct / 100.0)),
                (f"RAM: {mem_used / 1024:.1f} / {mem_tot / 1024:.1f} GiB ({100 * mem_used / mem_tot:.0f}%)", min(1.0, mem_used / mem_tot)),
                (f"Disk (/): {disk_used:.1f} / {disk_tot:.1f} GiB ({100 * disk_used / disk_tot:.0f}%)", min(1.0, disk_used / disk_tot)),
            ]:
                pbar = Gtk.ProgressBar()
                pbar.set_fraction(max(0.0, frac))
                pbar.set_show_text(True)
                pbar.set_text(label_text)
                m_vbox.pack_start(pbar, False, False, 0)

            for g in m.get("GPUS", []):
                if len(g) >= 6:
                    g_name, g_util, g_vused, g_vtot, g_temp, g_pwr = g[:6]
                    try:
                        g_frac = min(1.0, float(g_util) / 100.0)
                    except ValueError:
                        g_frac = 0.0
                    gpbar = Gtk.ProgressBar()
                    gpbar.set_fraction(max(0.0, g_frac))
                    gpbar.set_show_text(True)
                    gpbar.set_text(f"{g_name} · {g_util}% · VRAM {g_vused}/{g_vtot} MiB · {g_temp}°C · {g_pwr}W")
                    m_vbox.pack_start(gpbar, False, False, 0)

        m_frame.add(m_vbox)
        overview_tab.pack_start(m_frame, False, False, 0)

        if m and "error" not in m and m.get("PROCS"):
            p_frame = Gtk.Frame(label=self.t("高负载进程（完整命令与参数）", "Top Processes (Command & Args)"))
            p_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            p_vbox.set_margin_top(8)
            p_vbox.set_margin_bottom(8)
            p_vbox.set_margin_start(10)
            p_vbox.set_margin_end(10)
            for cmd, cpu, mem in m.get("PROCS", []):
                prow = Gtk.Box(spacing=8)
                clbl = Gtk.Label(label=cmd)
                clbl.set_xalign(0)
                clbl.set_ellipsize(3)  # PANGO_ELLIPSIZE_END
                clbl.set_tooltip_text(cmd)
                clbl.set_selectable(True)
                rlbl = Gtk.Label(label=f"CPU {cpu}% · MEM {mem}%")
                rlbl.set_xalign(1)
                prow.pack_start(clbl, True, True, 0)
                prow.pack_start(rlbl, False, False, 0)
                p_vbox.pack_start(prow, False, False, 0)
            p_frame.add(p_vbox)
            overview_tab.pack_start(p_frame, False, False, 0)

        # Remote Desktop (Tab 2: Desktop & Network)
        rd_frame = Gtk.Frame(label=self.t("远程桌面", "Remote Desktop"))
        rd_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        rd_vbox.set_margin_top(10)
        rd_vbox.set_margin_bottom(10)
        rd_vbox.set_margin_start(10)
        rd_vbox.set_margin_end(10)

        rd_row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        info_txt = (
            self.t(f'已配对: {saved["address"]}:{saved["httpPort"]}', f'Paired: {saved["address"]}:{saved["httpPort"]}')
            if saved
            else self.t(f'尚未配对 ({h["hostname"]})', f'Not paired yet ({h["hostname"]})')
        )
        rd_lbl = Gtk.Label(label=info_txt)
        rd_lbl.set_xalign(0)
        rd_row1.pack_start(rd_lbl, True, True, 0)

        btn_profile = Gtk.Button(label=self.t("多用户隔离配置", "Host Isolation Profile"))
        btn_profile.connect("clicked", lambda *_: self.on_edit_host_profile(h))
        rd_row1.pack_start(btn_profile, False, False, 0)

        btn_pair = Gtk.Button(label=self.t("免 PIN 配对", "Zero-PIN Pair"))
        btn_pair.connect("clicked", lambda *_: self.on_pair_sunshine(h))
        rd_row1.pack_start(btn_pair, False, False, 0)

        rd_vbox.pack_start(rd_row1, False, False, 0)

        rd_row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        res_combo = Gtk.ComboBoxText()
        for opt in ["1920x1080x60", "2560x1440x60", "3840x2160x60", "1920x1080x120"]:
            res_combo.append(opt, opt)
        res_combo.set_active_id(self.stream_resolution)
        res_combo.connect("changed", lambda cb: setattr(self, "stream_resolution", cb.get_active_id() or "1920x1080x60"))

        hw_combo = Gtk.ComboBoxText()
        for val, text in [
            ("auto", self.t("硬解: 自动 (VAAPI/CUDA)", "HW Decode: Auto (VAAPI/CUDA)")),
            ("vaapi", "VAAPI (Intel/AMD)"),
            ("cuda", "CUDA (NVIDIA)"),
            ("none", self.t("CPU 软解", "Software CPU")),
        ]:
            hw_combo.append(val, text)
        hw_combo.set_active_id(self.stream_hwaccel)
        hw_combo.connect("changed", lambda cb: setattr(self, "stream_hwaccel", cb.get_active_id() or "auto"))

        rd_row2.pack_start(Gtk.Label(label=self.t("参数:", "Mode:")), False, False, 0)
        rd_row2.pack_start(res_combo, False, False, 0)
        rd_row2.pack_start(hw_combo, False, False, 0)
        rd_vbox.pack_start(rd_row2, False, False, 0)

        rd_frame.add(rd_vbox)
        net_tab.pack_start(rd_frame, False, False, 0)

        # Port Forwarding (inside Tab 2)
        pf_frame = Gtk.Frame(label=self.t("SSH 端口转发", "SSH Port Forwarding"))
        pf_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        pf_vbox.set_margin_top(10)
        pf_vbox.set_margin_bottom(10)
        pf_vbox.set_margin_start(10)
        pf_vbox.set_margin_end(10)

        btn_add_pf = Gtk.Button(label=self.t("+ 添加端口转发 (-L / -R / -D)", "+ Add Port Forward (-L / -R / -D)"))
        btn_add_pf.connect("clicked", lambda *_: self.on_add_forward(h))
        pf_vbox.pack_start(btn_add_pf, False, False, 0)

        for fwd in [f for f in self.forwards if f["hostAlias"] == h["alias"]]:
            row = Gtk.Box(spacing=8)
            fid = fwd["id"]
            running = fid in self.forward_procs and self.forward_procs[fid].poll() is None
            state_txt = self.t("运行中", "Active") if running else self.t("已停止", "Stopped")
            lbl = Gtk.Label(label=f'[{fwd["flag"]}] {fwd["label"]}: {fwd["spec"]} ({state_txt})')
            lbl.set_xalign(0)
            row.pack_start(lbl, True, True, 0)
            btn_toggle = Gtk.Button(label=self.t("停止", "Stop") if running else self.t("启动", "Start"))
            btn_toggle.connect("clicked", lambda *_, f=fwd: self.toggle_forward(f))
            row.pack_start(btn_toggle, False, False, 0)
            btn_rm = Gtk.Button(label=self.t("移除", "Remove"))
            btn_rm.connect("clicked", lambda *_, f=fwd: self.remove_forward(f))
            row.pack_start(btn_rm, False, False, 0)
            pf_vbox.pack_start(row, False, False, 0)

        pf_frame.add(pf_vbox)
        net_tab.pack_start(pf_frame, False, False, 0)

        notebook.append_page(overview_tab, Gtk.Label(label=self.t("概览", "Overview")))
        notebook.append_page(net_tab, Gtk.Label(label=self.t("远程与网络", "Desktop & Network")))
        notebook.connect("switch-page", lambda _nb, _pg, idx: setattr(self, "active_tab_index", idx))
        self.detail_box.pack_start(notebook, True, True, 0)
        self.detail_box.pack_end(self.status_label, False, False, 0)
        self.detail_box.show_all()
        notebook.set_current_page(self.active_tab_index)

    def on_add_device(self, _btn):
        dlg = Gtk.Dialog(title=self.t("添加 SSH 设备", "Add SSH Device"), transient_for=self, flags=0)
        dlg.add_buttons(self.t("取消", "Cancel"), Gtk.ResponseType.CANCEL, self.t("添加", "Add"), Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        e_alias = Gtk.Entry(placeholder_text=self.t("例如 gpu-node", "e.g. gpu-node"))
        e_host = Gtk.Entry(placeholder_text=self.t("例如 192.168.1.10", "e.g. 192.168.1.10"))
        e_user = Gtk.Entry(text=os.getenv("USER", "ubuntu"))
        e_port = Gtk.Entry(text="22")
        for lbl_txt, widget in [
            (self.t("设备别名:", "Alias:"), e_alias),
            (self.t("主机 / IP:", "HostName / IP:"), e_host),
            (self.t("用户名:", "User:"), e_user),
            (self.t("端口:", "Port:"), e_port),
        ]:
            row = Gtk.Box(spacing=6)
            lbl = Gtk.Label(label=lbl_txt)
            lbl.set_width_chars(14)
            lbl.set_xalign(0)
            row.pack_start(lbl, False, False, 0)
            row.pack_start(widget, True, True, 0)
            box.pack_start(row, False, False, 4)
        dlg.show_all()
        if dlg.run() == Gtk.ResponseType.OK:
            if e_alias.get_text().strip() and e_host.get_text().strip():
                append_ssh_host(e_alias.get_text().strip(), e_host.get_text().strip(), e_user.get_text().strip(), e_port.get_text().strip())
                self.reload_hosts()
        dlg.destroy()

    def on_edit_device(self, host):
        dlg = Gtk.Dialog(title=self.t(f'编辑 SSH 设备 ({host["alias"]})', f'Edit SSH Device ({host["alias"]})'), transient_for=self, flags=0)
        dlg.add_buttons(self.t("取消", "Cancel"), Gtk.ResponseType.CANCEL, self.t("保存", "Save"), Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        e_alias = Gtk.Entry(text=host["alias"])
        e_host = Gtk.Entry(text=host["hostname"])
        e_user = Gtk.Entry(text=host["user"])
        e_port = Gtk.Entry(text=host["port"])
        for lbl_txt, widget in [
            (self.t("设备别名:", "Alias:"), e_alias),
            (self.t("主机 / IP:", "HostName / IP:"), e_host),
            (self.t("用户名:", "User:"), e_user),
            (self.t("端口:", "Port:"), e_port),
        ]:
            row = Gtk.Box(spacing=6)
            lbl = Gtk.Label(label=lbl_txt)
            lbl.set_width_chars(14)
            lbl.set_xalign(0)
            row.pack_start(lbl, False, False, 0)
            row.pack_start(widget, True, True, 0)
            box.pack_start(row, False, False, 4)
        dlg.show_all()
        if dlg.run() == Gtk.ResponseType.OK:
            na = e_alias.get_text().strip()
            nh = e_host.get_text().strip()
            nu = e_user.get_text().strip()
            np = e_port.get_text().strip() or "22"
            if na and nh:
                update_ssh_host(host["alias"], na, nh, nu, np)
                if host["alias"] != na and host["alias"] in self.sunshine_hosts:
                    self.sunshine_hosts[na] = self.sunshine_hosts.pop(host["alias"])
                    save_json(SUNSHINE_FILE, self.sunshine_hosts)
                self.selected_host = {"alias": na, "hostname": nh, "user": nu, "port": np}
                self.reload_hosts()
        dlg.destroy()

    def on_edit_host_profile(self, host):
        alias = host["alias"]
        existing = self.host_profiles.get(alias, {
            "hostAlias": alias,
            "mode": "physicalDesktop",
            "display": ":99",
            "basePort": 47989,
            "encoder": "nvenc",
            "cudaDeviceIndex": "0",
            "virtualAudioSink": False,
        })
        dlg = Gtk.Dialog(title=self.t(f"主机多用户隔离配置 ({alias})", f"Linux Host Isolation Profile ({alias})"), transient_for=self, flags=0)
        dlg.add_buttons(self.t("取消", "Cancel"), Gtk.ResponseType.CANCEL, self.t("保存并同步", "Save & Sync Host"), Gtk.ResponseType.OK)
        box = dlg.get_content_area()

        c_mode = Gtk.ComboBoxText()
        c_mode.append("physicalDesktop", self.t("物理桌面 (KMS/X11)", "Physical Desktop (KMS/X11)"))
        c_mode.append("isolatedVirtualDesktop", self.t("多用户独立虚拟屏 (:99 Xorg)", "Isolated Virtual Desktop (:99 Xorg)"))
        c_mode.set_active_id(existing.get("mode", "physicalDesktop"))

        e_disp = Gtk.Entry(text=str(existing.get("display", ":99")))
        e_port = Gtk.Entry(text=str(existing.get("basePort", 47989)))
        c_enc = Gtk.ComboBoxText()
        for enc in ["nvenc", "vaapi", "software"]:
            c_enc.append(enc, enc)
        c_enc.set_active_id(existing.get("encoder", "nvenc"))
        e_cuda = Gtk.Entry(text=str(existing.get("cudaDeviceIndex", "0")))
        chk_audio = Gtk.CheckButton(label=self.t("启用独立虚拟静音音频汇 (sunshine_virtual_sink)", "Use Isolated Virtual Audio Sink (sunshine_virtual_sink)"))
        chk_audio.set_active(bool(existing.get("virtualAudioSink", False)))

        for lbl_txt, widget in [
            (self.t("桌面模式:", "Desktop Mode:"), c_mode),
            (self.t("X11 显示号:", "X11 Display:"), e_disp),
            (self.t("基准端口:", "Base HTTP Port:"), e_port),
            (self.t("视频编码器:", "Video Encoder:"), c_enc),
            (self.t("CUDA GPU 索引:", "CUDA GPU Index:"), e_cuda),
        ]:
            row = Gtk.Box(spacing=6)
            lbl = Gtk.Label(label=lbl_txt)
            lbl.set_width_chars(16)
            lbl.set_xalign(0)
            row.pack_start(lbl, False, False, 0)
            row.pack_start(widget, True, True, 0)
            box.pack_start(row, False, False, 4)
        box.pack_start(chk_audio, False, False, 6)
        dlg.show_all()

        if dlg.run() == Gtk.ResponseType.OK:
            updated = {
                "hostAlias": alias,
                "mode": c_mode.get_active_id() or "physicalDesktop",
                "display": e_disp.get_text().strip() or ":99",
                "basePort": int(e_port.get_text().strip() or "47989"),
                "encoder": c_enc.get_active_id() or "nvenc",
                "cudaDeviceIndex": e_cuda.get_text().strip() or "0",
                "virtualAudioSink": chk_audio.get_active(),
            }
            self.host_profiles[alias] = updated
            save_json(PROFILES_FILE, self.host_profiles)
            self.status_label.set_text(self.t(f"正在同步主机配置到 {alias}…", f"Syncing host profile to {alias}..."))

            def worker():
                try:
                    out = reconcile_remote_host_profile(alias, updated)
                    GLib.idle_add(self.status_label.set_text, self.t(f"主机配置已同步到 {alias} ({out})", f"Host profile synced to {alias} ({out})"))
                except Exception as exc:
                    GLib.idle_add(self.status_label.set_text, self.t(f"同步失败: {exc}", f"Profile sync failed: {exc}"))

            threading.Thread(target=worker, daemon=True).start()
        dlg.destroy()

    def on_add_forward(self, host):
        dlg = Gtk.Dialog(title=self.t(f'添加端口转发 ({host["alias"]})', f'Add Port Forward ({host["alias"]})'), transient_for=self, flags=0)
        dlg.add_buttons(self.t("取消", "Cancel"), Gtk.ResponseType.CANCEL, self.t("添加", "Add"), Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        e_label = Gtk.Entry(text="Jupyter")
        e_flag = Gtk.Entry(text="-L")
        e_spec = Gtk.Entry(text="127.0.0.1:8888:127.0.0.1:8888")
        for lbl_txt, widget in [
            (self.t("名称:", "Label:"), e_label),
            (self.t("方向 (-L/-R/-D):", "Flag (-L/-R/-D):"), e_flag),
            (self.t("转发规则:", "Spec:"), e_spec),
        ]:
            row = Gtk.Box(spacing=6)
            lbl = Gtk.Label(label=lbl_txt)
            lbl.set_width_chars(16)
            lbl.set_xalign(0)
            row.pack_start(lbl, False, False, 0)
            row.pack_start(widget, True, True, 0)
            box.pack_start(row, False, False, 4)
        dlg.show_all()
        if dlg.run() == Gtk.ResponseType.OK:
            self.forwards.append({
                "id": secrets.token_hex(6),
                "hostAlias": host["alias"],
                "label": e_label.get_text().strip() or "Forward",
                "flag": e_flag.get_text().strip() or "-L",
                "spec": e_spec.get_text().strip(),
            })
            save_json(FORWARDS_FILE, self.forwards)
            self.render_detail()
        dlg.destroy()

    def toggle_forward(self, fwd):
        fid = fwd["id"]
        proc = self.forward_procs.get(fid)
        if proc and proc.poll() is None:
            proc.terminate()
            self.forward_procs.pop(fid, None)
        else:
            cmd = ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", fwd["flag"], fwd["spec"], fwd["hostAlias"]]
            self.forward_procs[fid] = subprocess.Popen(cmd)
        self.render_detail()

    def remove_forward(self, fwd):
        fid = fwd["id"]
        if fid in self.forward_procs:
            self.forward_procs[fid].terminate()
            self.forward_procs.pop(fid, None)
        self.forwards = [f for f in self.forwards if f["id"] != fid]
        save_json(FORWARDS_FILE, self.forwards)
        self.render_detail()

    def on_pair_sunshine(self, host):
        dlg = Gtk.Dialog(title=self.t(f'免 PIN 配对 ({host["alias"]})', f'Zero-PIN Pair ({host["alias"]})'), transient_for=self, flags=0)
        dlg.add_buttons(self.t("取消", "Cancel"), Gtk.ResponseType.CANCEL, self.t("开始配对", "Pair"), Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        e_addr = Gtk.Entry(text=host["hostname"])
        e_port = Gtk.Entry(text="47989")
        e_user = Gtk.Entry(text=host["user"])
        e_pass = Gtk.Entry(placeholder_text=self.t("可选 Sudo 密码（用户态留空）", "Optional Sudo Password (blank for user-space)"))
        e_pass.set_visibility(False)
        for lbl_txt, widget in [
            (self.t("宿主机地址:", "Host Address:"), e_addr),
            (self.t("HTTP 端口:", "HTTP Port:"), e_port),
            (self.t("SSH 账号:", "SSH User:"), e_user),
            (self.t("密码:", "Password:"), e_pass),
        ]:
            row = Gtk.Box(spacing=6)
            lbl = Gtk.Label(label=lbl_txt)
            lbl.set_width_chars(14)
            lbl.set_xalign(0)
            row.pack_start(lbl, False, False, 0)
            row.pack_start(widget, True, True, 0)
            box.pack_start(row, False, False, 4)
        dlg.show_all()
        if dlg.run() == Gtk.ResponseType.OK:
            addr = e_addr.get_text().strip()
            port = int(e_port.get_text().strip() or "47989")
            user = e_user.get_text().strip()
            pwd = e_pass.get_text()
            self.status_label.set_text(self.t(f"正在配对 {addr}:{port}…", f"Pairing with {addr}:{port}..."))
            threading.Thread(target=self._pair_worker, args=(host["alias"], addr, port, user, pwd), daemon=True).start()
        dlg.destroy()

    def _pair_worker(self, alias, addr, port, user, pwd):
        try:
            cert, key, uid = ensure_client_cert()
            cert_b64 = base64.b64encode(cert.read_bytes()).decode()
            pwd_b64 = base64.b64encode(pwd.encode()).decode()
            remote_py = f"""
import base64, json, os, re, subprocess, sys, uuid
pwd = base64.b64decode("{pwd_b64}").decode("utf-8", errors="ignore")
cert_pem = base64.b64decode("{cert_b64}").decode("utf-8")
if pwd:
    p = subprocess.run(["sudo", "-S", "-k", "-v"], input=(pwd + "\\n").encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        print("ERR:SUDO_AUTH_FAILED", file=sys.stderr)
        sys.exit(11)
nd_dir = os.path.expanduser("~/.config/nodedeck")
sun_dir = os.path.expanduser("~/.config/sunshine")
if os.path.exists(os.path.join(nd_dir, "host.conf")) or os.path.exists(os.path.join(nd_dir, "host_state.json")):
    conf_dir, state_name, conf_name, svc = nd_dir, "host_state.json", "host.conf", "nodedeck-host.service"
else:
    conf_dir, state_name, conf_name, svc = sun_dir, "sunshine_state.json", "sunshine.conf", "sunshine"
os.makedirs(conf_dir, exist_ok=True)
state_path = os.path.join(conf_dir, state_name)
conf_path = os.path.join(conf_dir, conf_name)
detected_port = {port}
if os.path.exists(conf_path):
    m = re.search(r"^\\s*port\\s*=\\s*(\\d+)", open(conf_path, encoding="utf-8", errors="ignore").read(), re.M)
    if m:
        detected_port = int(m.group(1))
state = json.load(open(state_path, encoding="utf-8")) if os.path.exists(state_path) else {{}}
root = state.setdefault("root", {{}})
if not root.get("uniqueid"):
    root["uniqueid"] = str(uuid.uuid4()).upper()
devices = [d for d in root.setdefault("named_devices", []) if d.get("cert") != cert_pem and d.get("name") != "NodeDeck-Linux"]
devices.append({{"name": "NodeDeck-Linux", "uuid": str(uuid.uuid5(uuid.NAMESPACE_DNS, "nodedeck-linux-{uid}")).upper(), "cert": cert_pem}})
root["named_devices"] = devices
json.dump(state, open(state_path, "w", encoding="utf-8"), indent=2)
if subprocess.run(["systemctl", "--user", "is-active", "--quiet", svc]).returncode == 0:
    subprocess.run(["systemctl", "--user", "restart", svc], check=False)
print(f"OK:{{detected_port}}")
"""
            res = subprocess.run(
                ssh_mux_base_args(alias, connect_timeout=6) + ["python3", "-"],
                input=remote_py.encode(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=18,
            )
            if res.returncode != 0:
                raise RuntimeError(res.stderr.decode(errors="ignore").strip() or f"SSH exit {res.returncode}")
            resolved_port = port
            for line in res.stdout.decode(errors="ignore").splitlines():
                if line.startswith("OK:"):
                    resolved_port = int(line.split(":")[1])
            self.sunshine_hosts[alias] = {"address": addr, "httpPort": resolved_port, "httpsPort": resolved_port - 5}
            save_json(SUNSHINE_FILE, self.sunshine_hosts)
            GLib.idle_add(self.status_label.set_text, f"Zero-PIN paired NodeDeck Host {addr}:{resolved_port}")
            GLib.idle_add(self.render_detail)
        except Exception as exc:
            GLib.idle_add(self.status_label.set_text, f"Pair error: {exc}")

    def launch_stream(self, saved):
        threading.Thread(target=self._launch_stream_worker, args=(saved,), daemon=True).start()

    def _launch_stream_worker(self, saved):
        try:
            cert, key, uid = ensure_client_cert()
            ctx = ssl._create_unverified_context()
            ctx.load_cert_chain(certfile=str(cert), keyfile=str(key))
            addr, http_port, https_port = saved["address"], saved["httpPort"], saved["httpsPort"]
            w_str, h_str, fps_str = self.stream_resolution.split("x")

            info_xml = urllib.request.urlopen(f"http://{addr}:{http_port}/serverinfo?uniqueid={uid}", timeout=8).read()
            info = ET.fromstring(info_xml)
            appver = info.findtext("appversion") or "7.1.431.0"
            gfever = info.findtext("GfeVersion") or "3.23.0.74"
            codec_support = info.findtext("ServerCodecModeSupport") or "0"

            apps_xml = urllib.request.urlopen(f"https://{addr}:{https_port}/applist?uniqueid={uid}", context=ctx, timeout=8).read()
            apps = ET.fromstring(apps_xml).findall("App")
            app_id = next((a.findtext("ID") for a in apps if "desktop" in (a.findtext("AppTitle") or "").lower()), apps[0].findtext("ID"))

            rikey = secrets.token_hex(16)
            rikeyid = str(random.randint(1, 2147483647))
            q = urllib.parse.urlencode({
                "uniqueid": uid, "appid": app_id, "mode": self.stream_resolution,
                "additionalStates": "1", "sops": "0", "rikey": rikey, "rikeyid": rikeyid,
                "localAudioPlayMode": "0", "surroundAudioInfo": "196610",
            })
            launch_xml = urllib.request.urlopen(f"https://{addr}:{https_port}/launch?{q}", context=ctx, timeout=15).read()
            rtsp = ET.fromstring(launch_xml).findtext("sessionUrl0") or f"rtsp://{addr}:48010"

            stream_bin = resolve_stream_bin()
            subprocess.Popen([
                stream_bin, "--host", addr, "--appver", appver, "--gfever", gfever,
                "--rtsp", rtsp, "--rikey", rikey, "--rikeyid", rikeyid,
                "--width", w_str, "--height", h_str, "--fps", fps_str,
                "--codec-support", codec_support,
                "--hwaccel", self.stream_hwaccel,
            ])
            GLib.idle_add(self.status_label.set_text, f"Streaming {addr} ({self.stream_resolution}, hwaccel={self.stream_hwaccel})")
        except Exception as exc:
            GLib.idle_add(self.status_label.set_text, f"Stream error: {exc}")


if __name__ == "__main__":
    win = NodeDeckWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
