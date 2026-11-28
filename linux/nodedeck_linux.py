#!/usr/bin/env python3
"""NodeDeck for Linux (GTK3 + Built-in moonlight-common-c / FFmpeg VAAPI+CUDA / SDL2 Streamer)."""

import base64
import hashlib
import json
import os
import pty
import random
import re
import secrets
import select
import shutil
import socket
import ssl
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, Gtk

SSH_CONFIG = Path.home() / ".ssh" / "config"
CONF_DIR = Path.home() / ".config" / "nodedeck"
FORWARDS_FILE = CONF_DIR / "port-forwards.json"
SUNSHINE_FILE = CONF_DIR / "sunshine-hosts.json"
PROFILES_FILE = CONF_DIR / "host-profiles.json"
SETTINGS_FILE = CONF_DIR / "settings.json"
CERT_DIR = CONF_DIR / "moonlight"
SSH_MUX_DIR = Path(f"/tmp/ndmux-{os.getuid()}")


DEFAULT_CONTROL_SERVER = "https://lockedflysher.duckdns.org:8443/nodedeck-api"
ACCOUNT_FILE = CONF_DIR / "account.json"


def load_account_session() -> dict:
    for p in (ACCOUNT_FILE, Path("/etc/nodedeck/account.json")):
        try:
            if p.exists():
                data = json.loads(p.read_text(encoding="utf-8"))
                if isinstance(data, dict) and data.get("token"):
                    return data
        except Exception:
            pass
    return {}


def save_account_session(data: dict) -> None:
    try:
        CONF_DIR.mkdir(parents=True, exist_ok=True)
        ACCOUNT_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        os.chmod(ACCOUNT_FILE, 0o600)
    except Exception:
        pass


def fetch_live_account_state(acct: dict) -> dict | None:
    token = str(acct.get("token") or "").strip()
    server_url = str(acct.get("server_url") or DEFAULT_CONTROL_SERVER).rstrip("/")
    if not token or not server_url:
        return None
    req = urllib.request.Request(
        f"{server_url}/api/v1/state",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        fresh = json.loads(resp.read().decode("utf-8"))
    fresh["token"] = token
    fresh["server_url"] = server_url
    if acct.get("ssh_user"):
        fresh["ssh_user"] = acct["ssh_user"]
    save_account_session(fresh)
    return fresh


def upload_linux_client_cert(acct: dict) -> bool:
    token = str(acct.get("token") or "").strip()
    server_url = str(acct.get("server_url") or DEFAULT_CONTROL_SERVER).rstrip("/")
    if not token or not server_url:
        return False
    try:
        cert_path, _key_path, uid = ensure_client_cert()
        cert_pem = cert_path.read_text(encoding="utf-8").strip()
        if "BEGIN CERTIFICATE" not in cert_pem or not uid:
            return False
        dev_name = str(acct.get("device", {}).get("device_name") or socket.gethostname())
        payload = json.dumps({
            "device_name": dev_name,
            "unique_id": uid,
            "cert_pem": cert_pem,
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{server_url}/api/v1/certs/register",
            data=payload,
            headers={
                "Content-Type": "application/json; charset=utf-8",
                "Authorization": f"Bearer {token}",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except Exception:
        return False


def load_sunshine_hosts_dict() -> dict:
    raw = load_json(SUNSHINE_FILE, {})
    if isinstance(raw, dict):
        return raw
    # Migrate legacy list format back to alias-keyed dict
    migrated = {}
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, dict) and item.get("hostAlias"):
                migrated[item["hostAlias"]] = item
        save_json(SUNSHINE_FILE, migrated)
    return migrated


def ensure_local_ssh_pubkey() -> str:
    """Ensure current user has an Ed25519 SSH keypair (generating one if missing) and return its public key."""
    ssh_dir = Path.home() / ".ssh"
    ssh_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh_dir, 0o700)
    for cand in ("id_ed25519.pub", "id_rsa.pub"):
        p = ssh_dir / cand
        if p.exists():
            txt = p.read_text(encoding="utf-8", errors="ignore").strip()
            if txt.startswith(("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-")):
                return txt
    key_path = ssh_dir / "id_ed25519"
    pub_path = ssh_dir / "id_ed25519.pub"
    if not key_path.exists():
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path), "-C", f"nodedeck@{socket.gethostname()}", "-q"],
            check=False,
        )
    if key_path.exists():
        os.chmod(key_path, 0o600)
    if pub_path.exists():
        os.chmod(pub_path, 0o644)
        return pub_path.read_text(encoding="utf-8", errors="ignore").strip()
    return ""


def upload_linux_ssh_pubkey(acct: dict) -> bool:
    token = str(acct.get("token") or "").strip()
    server_url = str(acct.get("server_url") or DEFAULT_CONTROL_SERVER).rstrip("/")
    pub = ensure_local_ssh_pubkey()
    if not token or not server_url or not pub:
        return False
    try:
        dev_name = str(acct.get("device", {}).get("device_name") or socket.gethostname())
        req = urllib.request.Request(
            f"{server_url}/api/v1/ssh-keys/register",
            data=json.dumps({"device_name": dev_name, "public_key": pub}).encode("utf-8"),
            headers={
                "Content-Type": "application/json; charset=utf-8",
                "Authorization": f"Bearer {token}",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except Exception:
        return False


def sync_account_ssh_keys(acct: dict) -> int:
    keys = acct.get("ssh_public_keys") or []
    if not keys:
        return 0
    ssh_dir = Path.home() / ".ssh"
    ssh_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh_dir, 0o700)
    auth_file = ssh_dir / "authorized_keys"
    lines = auth_file.read_text(encoding="utf-8", errors="ignore").splitlines() if auth_file.exists() else []
    blobs = set()
    for ln in lines:
        p = ln.strip().split()
        if len(p) >= 2:
            blobs.add((p[0], p[1]))
    added = 0
    for item in keys:
        pub = str(item.get("public_key") or "").strip()
        if not pub or "\n" in pub or "\r" in pub:
            continue
        p = pub.split()
        if len(p) < 2 or not p[0].startswith(("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-")):
            continue
        if (p[0], p[1]) in blobs:
            continue
        dev_name = re.sub(r"[^A-Za-z0-9._-]", "_", str(item.get("device_name") or "device"))
        lines.append(f"{p[0]} {p[1]} nodedeck-{dev_name}")
        blobs.add((p[0], p[1]))
        added += 1
    if added:
        auth_file.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
        os.chmod(auth_file, 0o600)
    return added


def install_ssh_pubkey_with_password(hostname: str, port: int, user: str, password: str) -> tuple[bool, str]:
    """Authenticate once with user/password over SSH PTY and install local Ed25519 public key for passwordless login."""
    pub = ensure_local_ssh_pubkey()
    if not pub:
        return False, "Failed to generate local Ed25519 SSH keypair"
    pub_b64 = base64.b64encode((pub + "\n").encode("utf-8")).decode("ascii")
    remote_cmd = (
        f"mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
        f"KEY=$(printf '%s' '{pub_b64}' | base64 -d) && "
        f"(grep -qxF \"$KEY\" ~/.ssh/authorized_keys || printf '%s\\n' \"$KEY\" >> ~/.ssh/authorized_keys) && "
        f"echo NODEDECK_KEY_INSTALLED"
    )
    cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "PreferredAuthentications=password,keyboard-interactive",
        "-o", "PubkeyAuthentication=no",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "ConnectTimeout=8",
        "-p", str(port),
        f"{user}@{hostname}",
        remote_cmd,
    ]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("ssh", cmd)
    out = b""
    pw_sent = False
    deadline = time.time() + 18.0
    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.25)
            if r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
                low = out.lower()
                if not pw_sent and (b"password:" in low or b"verification code" in low or "密码".encode("utf-8") in out):
                    os.write(fd, (password + "\n").encode("utf-8"))
                    pw_sent = True
                if b"NODEDECK_KEY_INSTALLED" in out:
                    break
            else:
                wpid, _ = os.waitpid(pid, os.WNOHANG)
                if wpid != 0:
                    break
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    text = out.decode("utf-8", errors="ignore")
    if "NODEDECK_KEY_INSTALLED" in text:
        return True, "OK"
    if "Permission denied" in text or "Authentication failed" in text:
        return False, "密码错误或该主机未开启 SSH 密码登录 (Permission denied)"
    return False, (text.strip().splitlines()[-1] if text.strip() else "SSH authorization failed")


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


def is_local_ssh_running() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", 22), timeout=0.25):
            return True
    except Exception:
        return False


def local_host_conf_path() -> Path:
    for cand in (CONF_DIR / "host.conf", CONF_DIR / "host" / "host.conf"):
        if cand.exists():
            return cand
    return CONF_DIR / "host.conf"


def read_local_host_conf() -> dict[str, str]:
    p = local_host_conf_path()
    out: dict[str, str] = {}
    if not p.exists():
        return out
    for raw in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def write_local_host_conf(updates: dict[str, str | None]) -> Path:
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    apps_path = CONF_DIR / "apps.json"
    if not apps_path.exists():
        apps_path.write_text('{\n  "env": {},\n  "apps": [{ "name": "Desktop", "image-path": "desktop.png" }]\n}\n', encoding="utf-8")
    p = local_host_conf_path()
    cfg = read_local_host_conf()
    # Auto-repair any legacy /bin/bash paths
    for k in ("file_apps", "file_state", "credentials_file", "pkey", "cert"):
        if k not in cfg or re.match(r"^/bin/(ba|z|da)?sh/", cfg.get(k, "")):
            defaults = {
                "file_apps": str(CONF_DIR / "apps.json"),
                "file_state": str(CONF_DIR / "host_state.json"),
                "credentials_file": str(CONF_DIR / "credentials.json"),
                "pkey": str(CONF_DIR / "host.key"),
                "cert": str(CONF_DIR / "host.cert"),
            }
            cfg[k] = defaults[k]
    cfg.setdefault("port", "47989")
    for k, v in updates.items():
        if v is None or v == "" or v == "auto":
            cfg.pop(k, None)
        else:
            cfg[k] = str(v)
    p.write_text("\n".join(f"{k} = {v}" for k, v in cfg.items()) + "\n", encoding="utf-8")
    return p


def detect_local_host_encoder_status() -> tuple[str, str]:
    """Return (status_kind, summary) from current nodedeck-host invocation journal: ok / warn / unknown."""
    lines: list[str] = []
    try:
        inv = subprocess.run(
            ["systemctl", "--user", "show", "-p", "InvocationID", "--value", "nodedeck-host.service"],
            capture_output=True,
            text=True,
            timeout=2,
        ).stdout.strip()
        if inv:
            r = subprocess.run(
                ["journalctl", "--user", f"_SYSTEMD_INVOCATION_ID={inv}", "--no-pager"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            lines = r.stdout.splitlines()
        if not lines:
            r = subprocess.run(
                ["journalctl", "--user", "-u", "nodedeck-host.service", "-n", "500", "--no-pager"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            lines = r.stdout.splitlines()
    except Exception:
        lines = []
    active_enc = ""
    failed_msg = ""
    for ln in reversed(lines):
        if not active_enc and "Found H.264 encoder:" in ln:
            active_enc = ln.split("Found H.264 encoder:", 1)[1].strip()
        elif not active_enc and "Found HEVC encoder:" in ln:
            active_enc = ln.split("Found HEVC encoder:", 1)[1].strip()
        elif not failed_msg and ("Unable to find display or encoder" in ln or "Unable to initialize capture method" in ln):
            failed_msg = "encoder_or_capture_failed"
        if "Starting nodedeck-host.service" in ln:
            break
    if active_enc:
        return "ok", active_enc
    if failed_msg:
        return "warn", failed_msg
    return "unknown", ""


def detect_local_gpu_summary() -> tuple[list[str], list[str], str]:
    gpus: list[str] = []
    if shutil.which("nvidia-smi"):
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            for ln in r.stdout.splitlines():
                if ln.strip():
                    gpus.append(ln.strip())
        except Exception:
            pass
    if shutil.which("lspci"):
        try:
            r = subprocess.run(["lspci"], capture_output=True, text=True, timeout=2)
            for ln in r.stdout.splitlines():
                if any(tok in ln for tok in ("VGA compatible controller", "3D controller", "Display controller")):
                    desc = ln.split(":", 2)[-1].strip()
                    norm_desc = desc.lower()
                    if desc and not any(
                        (g.lower() in norm_desc or g.lower().removeprefix("nvidia ") in norm_desc)
                        for g in gpus
                    ):
                        gpus.append(desc)
        except Exception:
            pass
    render_nodes = sorted(str(p) for p in Path("/dev/dri").glob("renderD*")) if Path("/dev/dri").exists() else []
    sess = os.environ.get("XDG_SESSION_TYPE") or ("wayland" if os.environ.get("WAYLAND_DISPLAY") else "x11")
    return gpus, render_nodes, sess


def resolve_easytier_cli() -> str:
    candidates = [
        "/opt/nodedeck/easytier/easytier-cli",
        str(Path.home() / ".local" / "share" / "nodedeck" / "easytier" / "easytier-cli"),
        "/usr/local/bin/easytier-cli",
        shutil.which("easytier-cli") or "",
    ]
    for p in candidates:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return ""


def fetch_easytier_peer_transports() -> list[dict]:
    cli = resolve_easytier_cli()
    if not cli:
        return []
    try:
        pr = subprocess.run([cli, "-o", "json", "peer"], capture_output=True, text=True, timeout=1.5)
        if pr.returncode != 0 or not pr.stdout.strip():
            return []
        peers = json.loads(pr.stdout)
        if not isinstance(peers, list):
            return []
    except Exception:
        return []

    proto_by_host: dict[str, str] = {}
    loss_by_host: dict[str, float] = {}
    for item in peers:
        if not isinstance(item, dict):
            continue
        h = str(item.get("hostname") or "").strip().lower()
        tp = str(item.get("tunnel_proto") or "").strip().lower()
        if h and tp and tp != "-":
            proto_by_host[h] = tp
        ls = str(item.get("loss_rate") or "").replace("%", "").strip()
        try:
            if h and ls and ls != "-":
                loss_by_host[h] = float(ls)
        except ValueError:
            pass

    next_hop_by_ip: dict[str, str] = {}
    next_hop_by_host: dict[str, str] = {}
    try:
        rr = subprocess.run([cli, "-o", "json", "route"], capture_output=True, text=True, timeout=1.5)
        if rr.returncode == 0 and rr.stdout.strip():
            routes = json.loads(rr.stdout)
            if isinstance(routes, list):
                for r in routes:
                    if not isinstance(r, dict):
                        continue
                    ip = str(r.get("ipv4") or "").split("/", 1)[0].strip()
                    h = str(r.get("hostname") or "").strip().lower()
                    nh = str(r.get("next_hop_hostname") or "").strip()
                    if nh and nh not in ("DIRECT", "Local"):
                        if ip:
                            next_hop_by_ip[ip] = nh
                        if h:
                            next_hop_by_host[h] = nh
    except Exception:
        pass

    out: list[dict] = []
    for item in peers:
        if not isinstance(item, dict):
            continue
        cost_raw = str(item.get("cost") or "").strip()
        if cost_raw.lower() == "local":
            continue
        ip = str(item.get("ipv4") or "").split("/", 1)[0].strip()
        hostname = str(item.get("hostname") or "").strip()
        if not ip and not hostname:
            continue
        is_p2p = cost_raw.lower() == "p2p"
        hop = 1 if is_p2p else 2
        m_hop = re.search(r"\((\d+)\)", cost_raw)
        if m_hop:
            hop = int(m_hop.group(1))
        proto = str(item.get("tunnel_proto") or "").strip().lower()
        if proto == "-":
            proto = ""
        relay_via = next_hop_by_ip.get(ip) or next_hop_by_host.get(hostname.lower()) or ""
        if not is_p2p and not proto:
            if relay_via and relay_via.lower() in proto_by_host:
                proto = proto_by_host[relay_via.lower()]
            else:
                for k, v in proto_by_host.items():
                    if "seed" in k or "public" in k:
                        proto = v
                        break
        lat_ms = None
        try:
            ls = str(item.get("lat_ms") or "").strip()
            if ls and ls != "-":
                lat_ms = float(ls)
        except ValueError:
            pass
        loss_pct = None
        try:
            lr = str(item.get("loss_rate") or "").replace("%", "").strip()
            if lr and lr != "-":
                loss_pct = float(lr)
        except ValueError:
            pass
        if not is_p2p and (not loss_pct) and relay_via and loss_by_host.get(relay_via.lower(), 0.0) > 0:
            loss_pct = loss_by_host[relay_via.lower()]

        if is_p2p:
            if "udp" in proto:
                badge = "P2P · UDP"
            elif "tcp" in proto:
                badge = "P2P · TCP"
            elif proto:
                badge = f"P2P · {proto.upper()}"
            else:
                badge = "P2P"
        else:
            if "udp" in proto:
                badge = "UDP Relay"
            elif "tcp" in proto:
                badge = "TCP Relay"
            else:
                badge = f"Relay({hop})"
        detail_parts = [badge]
        if lat_ms and lat_ms > 0:
            detail_parts.append(f"{int(round(lat_ms))}ms")
        if loss_pct and loss_pct >= 5.0:
            detail_parts.append(f"loss {int(round(loss_pct))}%")
        out.append({
            "ipv4": ip,
            "hostname": hostname,
            "is_p2p": is_p2p,
            "is_tcp_relay": (not is_p2p) and ("tcp" in proto),
            "proto": proto,
            "relay_via": relay_via,
            "lat_ms": lat_ms,
            "loss_pct": loss_pct,
            "badge": badge,
            "detailed": " · ".join(detail_parts),
        })
    return out


def match_easytier_transport(peers: list[dict], address: str, alias: str = "") -> dict | None:
    addr = (address or "").strip().lower()
    al = (alias or "").strip().lower()
    if addr:
        for p in peers:
            if p.get("ipv4", "").lower() == addr:
                return p
    if al:
        for p in peers:
            if p.get("hostname", "").lower() == al:
                return p
    return None


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
        "-o", "StrictHostKeyChecking=accept-new",
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
            elif k == "proxyjump":
                cur["proxyjump"] = v
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
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  printf 'OS=macOS %s\n' "$(sw_vers -productVersion 2>/dev/null || printf Darwin)"
  printf 'KERNEL=%s\n' "$(uname -sr 2>/dev/null)"
  printf 'CORES=%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
  cpu_u=$(top -l 1 -n 0 2>/dev/null | awk -F'[:%, ]+' '/CPU usage/ {printf "%.1f", $3 + $5; exit}')
  printf 'CPU=%s\n' "${cpu_u:-0.0}"
  mt_b=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  pg_sz=$(pagesize 2>/dev/null || echo 16384)
  ma_b=$(vm_stat 2>/dev/null | awk -v ps="$pg_sz" '/Pages free:|Pages inactive:|Pages speculative:/ {gsub(/\./,"",$NF); sum+=$NF} END {printf "%.0f", sum*ps}')
  mt_mb=$(( ${mt_b:-0} / 1048576 ))
  ma_mb=$(( ${ma_b:-0} / 1048576 ))
  printf 'MEM_TOTAL_MB=%s\n' "$mt_mb"
  printf 'MEM_USED_MB=%s\n' "$(( mt_mb > ma_mb ? mt_mb - ma_mb : 0 ))"
  df -Pm / 2>/dev/null | awk 'NR==2 {printf "DISK_USED_GB=%.1f\nDISK_TOTAL_GB=%.1f\n", $3/1024, $2/1024}'
  ps -eo pcpu=,pmem=,comm= -r 2>/dev/null | head -n 5 | awk 'NF >= 3 { cpu=$1; mem=$2; $1=""; $2=""; sub(/^[[:space:]]+/, ""); printf "PROC=%s|%s|%s\n", $0, cpu, mem }'
  printf 'ND_END\n'
  exit 0
fi
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


def measure_tcp_rtt_ms(host: str, port: int, timeout: float = 2.5) -> int | None:
    if not host:
        return None
    try:
        infos = socket.getaddrinfo(host, int(port), type=socket.SOCK_STREAM)
        if not infos:
            return None
        af, socktype, proto, _, sa = infos[0]
        s = socket.socket(af, socktype, proto)
        s.settimeout(timeout)
        try:
            t0 = time.monotonic()
            s.connect(sa)
            return max(1, int((time.monotonic() - t0) * 1000))
        finally:
            s.close()
    except Exception:
        return None


def collect_remote_metrics(alias: str, host_name: str = "", port: int = 22, has_proxy: bool = False):
    tcp_rtt = None if has_proxy else measure_tcp_rtt_ms(host_name, port)
    t0 = time.monotonic()
    res = subprocess.run(
        ssh_mux_base_args(alias, connect_timeout=5) + ["/bin/sh", "-s"],
        input=METRICS_SCRIPT.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=12,
    )
    elapsed_ms = tcp_rtt if tcp_rtt is not None else max(1, int((time.monotonic() - t0) * 1000) - 200)
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


NODEDECK_CSS = b"""
window, dialog {
    background-color: #141920;
    color: #e6edf3;
    font-family: "Inter", "Noto Sans CJK SC", "Ubuntu", "Cantarell", sans-serif;
    font-size: 13px;
}

headerbar.nd-headerbar {
    background-color: #10151b;
    background-image: none;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    box-shadow: none;
    min-height: 36px;
    padding: 0 10px;
}
headerbar.nd-headerbar .title {
    color: #c9d4e0;
    font-weight: 600;
    font-size: 12.5px;
}

paned > separator {
    background-color: rgba(255, 255, 255, 0.08);
    min-width: 1px;
    min-height: 1px;
}

.nd-sidebar {
    background-color: #10151b;
}

.nd-detail-canvas {
    background-color: #151b23;
}

.nd-brand-icon {
    background-color: #148575;
    color: #ffffff;
    border-radius: 9px;
    font-weight: 800;
    font-size: 13px;
    min-width: 34px;
    min-height: 34px;
}

.nd-brand-title {
    color: #f0f6fc;
    font-size: 16px;
    font-weight: 700;
}

.nd-brand-sub {
    color: #8b9bb0;
    font-size: 11px;
}

.nd-icon-btn {
    background-color: transparent;
    background-image: none;
    border: 1px solid transparent;
    border-radius: 7px;
    color: #9fb0c3;
    padding: 4px 8px;
    min-width: 26px;
    min-height: 26px;
    box-shadow: none;
}
.nd-icon-btn:hover {
    background-color: rgba(255, 255, 255, 0.08);
    color: #ffffff;
}
.nd-icon-btn-accent {
    color: #26b8a4;
}

entry.nd-search {
    background-color: #19202a;
    background-image: none;
    color: #e6edf3;
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    padding: 5px 10px;
    min-height: 30px;
    box-shadow: none;
}
entry.nd-search:focus {
    border-color: #148575;
}

.nd-segmented-tray {
    background-color: #171e27;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 9px;
    padding: 3px;
}

button.nd-seg-btn {
    background-color: transparent;
    background-image: none;
    border: none;
    border-radius: 6px;
    color: #8b9bb0;
    font-size: 11.5px;
    font-weight: 500;
    padding: 4px 8px;
    min-height: 24px;
    box-shadow: none;
}
button.nd-seg-btn:hover {
    color: #d6e1ec;
    background-color: rgba(255, 255, 255, 0.04);
}
button.nd-seg-btn:checked {
    background-color: rgba(20, 133, 117, 0.24);
    color: #5ce0cd;
    font-weight: 600;
}

button.nd-tab-btn {
    background-color: transparent;
    background-image: none;
    border: none;
    border-radius: 7px;
    color: #8b9bb0;
    font-size: 12.5px;
    font-weight: 500;
    padding: 6px 14px;
    min-height: 28px;
    box-shadow: none;
}
button.nd-tab-btn:hover {
    color: #e6edf3;
    background-color: rgba(255, 255, 255, 0.05);
}
button.nd-tab-btn.nd-tab-active {
    background-color: #242f3d;
    color: #ffffff;
    font-weight: 600;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
}

list.nd-host-list {
    background-color: transparent;
}
list.nd-host-list row {
    background-color: transparent;
    color: #e6edf3;
    border-radius: 10px;
    margin: 2px 6px;
    padding: 0;
    border: 1px solid transparent;
    transition: background-color 120ms ease;
}
list.nd-host-list row label {
    color: #e6edf3;
}
list.nd-host-list row label.nd-dim {
    color: #8b9bb0;
}
list.nd-host-list row label.nd-badge-remote {
    color: #4bd6c3;
}
list.nd-host-list row label.nd-badge-gpu {
    color: #f0a85b;
}
list.nd-host-list row label.nd-avatar {
    color: #ffffff;
}
list.nd-host-list row:hover {
    background-color: rgba(255, 255, 255, 0.045);
}
list.nd-host-list row:selected {
    background-color: rgba(20, 133, 117, 0.20);
    border: 1px solid rgba(38, 184, 164, 0.42);
}

.nd-avatar {
    border-radius: 9px;
    color: #ffffff;
    font-weight: 700;
}
.nd-avatar-sm {
    min-width: 32px;
    min-height: 32px;
    font-size: 12px;
    border-radius: 8px;
}
.nd-avatar-lg {
    min-width: 50px;
    min-height: 50px;
    font-size: 18px;
    border-radius: 12px;
}
.nd-avatar-0 { background-color: #1f7873; }
.nd-avatar-1 { background-color: #33619e; }
.nd-avatar-2 { background-color: #916130; }
.nd-avatar-3 { background-color: #70578c; }

.nd-card {
    background-color: #1b222c;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 12px;
    padding: 14px 16px;
}
.nd-card-compact {
    background-color: #171e27;
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 10px;
    padding: 9px 12px;
}
.nd-alert-card {
    background-color: rgba(199, 64, 69, 0.12);
    border: 1px solid rgba(199, 64, 69, 0.38);
    border-radius: 12px;
    padding: 12px 16px;
}

.nd-section-title {
    color: #9fb0c3;
    font-size: 12px;
    font-weight: 600;
}
.nd-kpi-label {
    color: #8b9bb0;
    font-size: 11.5px;
    font-weight: 600;
}
.nd-kpi-value {
    color: #f0f6fc;
    font-size: 24px;
    font-weight: 700;
}
.nd-kpi-sub {
    color: #8b9bb0;
    font-size: 11.5px;
}
.nd-mono {
    font-family: "JetBrains Mono", "Fira Code", "Ubuntu Mono", monospace;
}
.nd-dim {
    color: #8b9bb0;
}

.nd-badge {
    border-radius: 999px;
    padding: 2px 8px;
    font-size: 11px;
    font-weight: 600;
}
.nd-badge-online {
    background-color: rgba(41, 158, 94, 0.18);
    color: #46d687;
}
.nd-badge-offline {
    background-color: rgba(199, 64, 69, 0.20);
    color: #ff7b80;
}
.nd-badge-checking {
    background-color: rgba(209, 138, 33, 0.20);
    color: #f2b44f;
}
.nd-badge-lan {
    background-color: rgba(46, 122, 191, 0.20);
    color: #6ab4f5;
}
.nd-badge-wan {
    background-color: rgba(133, 107, 173, 0.22);
    color: #bfa6eb;
}
.nd-badge-remote {
    background-color: rgba(20, 133, 117, 0.22);
    color: #4bd6c3;
}
.nd-badge-gpu {
    background-color: rgba(199, 115, 38, 0.22);
    color: #f0a85b;
}
.nd-badge-neutral {
    background-color: rgba(255, 255, 255, 0.08);
    color: #b4c2d1;
}

button.nd-btn-primary {
    background-color: #148575;
    background-image: none;
    color: #ffffff;
    border: 1px solid #1aa390;
    border-radius: 8px;
    padding: 6px 14px;
    font-weight: 600;
    font-size: 12.5px;
    box-shadow: none;
}
button.nd-btn-primary:hover {
    background-color: #189b88;
}

button.nd-btn-secondary {
    background-color: #212a36;
    background-image: none;
    color: #dce5ef;
    border: 1px solid rgba(255, 255, 255, 0.11);
    border-radius: 8px;
    padding: 6px 12px;
    font-weight: 500;
    font-size: 12.5px;
    box-shadow: none;
}
button.nd-btn-secondary:hover {
    background-color: #2a3545;
    color: #ffffff;
}

button.nd-btn-danger {
    background-color: rgba(199, 64, 69, 0.14);
    background-image: none;
    color: #ff7b80;
    border: 1px solid rgba(199, 64, 69, 0.34);
    border-radius: 8px;
    padding: 6px 12px;
    font-weight: 500;
    font-size: 12.5px;
    box-shadow: none;
}
button.nd-btn-danger:hover {
    background-color: rgba(199, 64, 69, 0.26);
    color: #ffd0d2;
}

button.nd-pill-choice {
    background-color: #151c24;
    background-image: none;
    color: #9fb0c3;
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    padding: 5px 12px;
    font-size: 12px;
    font-weight: 500;
    box-shadow: none;
}
button.nd-pill-choice:hover {
    background-color: #202a36;
    color: #ffffff;
}
button.nd-pill-choice.nd-pill-selected {
    background-color: #148575;
    border-color: #1fa693;
    color: #ffffff;
    font-weight: 600;
}

progressbar.nd-bar trough {
    background-color: #11161d;
    border: none;
    border-radius: 999px;
    min-height: 7px;
}
progressbar.nd-bar progress {
    border: none;
    border-radius: 999px;
    min-height: 7px;
}
progressbar.nd-bar-cpu progress { background-color: #1a8a7a; }
progressbar.nd-bar-mem progress { background-color: #c77326; }
progressbar.nd-bar-disk progress { background-color: #2e6bb3; }
progressbar.nd-bar-gpu-nv progress { background-color: #299e5e; }
progressbar.nd-bar-gpu-amd progress { background-color: #c7473d; }
progressbar.nd-bar-warn progress { background-color: #d6851f; }
progressbar.nd-bar-crit progress { background-color: #c73b40; }

switch {
    background-color: #273240;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 999px;
    color: transparent;
}
switch:checked {
    background-color: #148575;
    border-color: #1ca693;
}
switch slider {
    background-color: #f0f6fc;
    border-radius: 999px;
    min-width: 18px;
    min-height: 18px;
}

.nd-footer-bar {
    background-color: #0e1318;
    border-top: 1px solid rgba(255, 255, 255, 0.07);
    padding: 7px 10px;
}

.nd-status-strip {
    color: #7c8ea3;
    font-size: 11.5px;
    padding: 6px 2px 0 2px;
}

separator.nd-divider {
    background-color: rgba(255, 255, 255, 0.07);
    min-height: 1px;
}

scrollbar slider {
    background-color: rgba(255, 255, 255, 0.16);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.28);
}

dialog entry, dialog combobox button {
    background-color: #1c242e;
    background-image: none;
    color: #e6edf3;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 7px;
    padding: 5px 9px;
}
menu {
    background-color: #1a212b;
    border: 1px solid rgba(255, 255, 255, 0.10);
    border-radius: 8px;
    padding: 4px;
}
menuitem {
    border-radius: 5px;
    padding: 5px 10px;
    color: #dce5ef;
}
menuitem:hover {
    background-color: rgba(20, 133, 117, 0.28);
    color: #ffffff;
}
"""


def _apply_nodedeck_theme():
    settings = Gtk.Settings.get_default()
    if settings is not None:
        try:
            settings.set_property("gtk-application-prefer-dark-theme", True)
        except Exception:
            pass
    provider = Gtk.CssProvider()
    provider.load_from_data(NODEDECK_CSS)
    screen = Gdk.Screen.get_default()
    if screen is not None:
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )


def _avatar_style_index(alias: str) -> int:
    return sum(ord(ch) for ch in (alias or "N")) % 4


def _avatar_initials(alias: str) -> str:
    clean = re.sub(r"[^A-Za-z0-9\u4e00-\u9fff]+", " ", alias or "").strip()
    if not clean:
        return "ND"
    parts = clean.split()
    if len(parts) >= 2:
        return (parts[0][0] + parts[1][0]).upper()
    return clean[:2].upper()


def _is_lan_or_mesh_host(hostname: str) -> bool:
    h = (hostname or "").strip().lower()
    return (
        h.startswith(("10.", "192.168.", "127.", "100."))
        or bool(re.match(r"^172\.(1[6-9]|2[0-9]|3[0-1])\.", h))
        or h.endswith(".local")
        or h == "localhost"
    )


def _recommended_bitrate_mbps(res: str, fps: str) -> int:
    try:
        w_s, h_s = res.split("x")
        pixel_ratio = (max(640, int(w_s)) * max(360, int(h_s))) / (1920.0 * 1080.0)
        fps_ratio = max(30, int(fps)) / 60.0
        raw = 20000.0 * (pixel_ratio ** 0.72) * (fps_ratio ** 0.75)
        kbps = max(20000, min(120000, int(round(raw / 5000.0)) * 5000))
        return kbps // 1000
    except Exception:
        return 20


def _make_badge(text: str, style_class: str) -> Gtk.Label:
    lbl = Gtk.Label(label=text)
    ctx = lbl.get_style_context()
    ctx.add_class("nd-badge")
    ctx.add_class(style_class)
    return lbl


def _make_avatar(alias: str, large: bool = False) -> Gtk.Label:
    lbl = Gtk.Label(label=_avatar_initials(alias))
    ctx = lbl.get_style_context()
    ctx.add_class("nd-avatar")
    ctx.add_class("nd-avatar-lg" if large else "nd-avatar-sm")
    ctx.add_class(f"nd-avatar-{_avatar_style_index(alias)}")
    lbl.set_halign(Gtk.Align.CENTER)
    lbl.set_valign(Gtk.Align.CENTER)
    return lbl


def _severity_bar_class(frac: float, base_class: str) -> str:
    if frac >= 0.92:
        return "nd-bar-crit"
    if frac >= 0.80:
        return "nd-bar-warn"
    return base_class


class NodeDeckWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="NodeDeck")
        _apply_nodedeck_theme()
        self.set_default_size(1140, 760)
        icon_path = resolve_icon_path()
        if icon_path:
            try:
                self.set_icon_from_file(icon_path)
            except Exception:
                pass
        self.hosts = []
        self.selected_host = None
        self._reloading_hosts = False
        self._updating_host_switch = False
        self.forwards = load_json(FORWARDS_FILE, [])
        self.forward_procs = {}
        self.sunshine_hosts = load_sunshine_hosts_dict()
        self.host_profiles = load_json(PROFILES_FILE, {})
        self.settings = load_json(SETTINGS_FILE, {})
        self.pinned_aliases = set(self.settings.get("pinned_aliases", []))
        self.search_query = ""
        self.filter_mode = "all"
        self.lang = self.settings.get("language") or detect_default_lang()
        self.metrics_cache = {}
        self.mesh_transports = []
        saved_res = self.settings.get("stream_resolution", "1920x1080")
        if saved_res not in ("1920x1080", "2560x1440", "3840x2160"):
            saved_res = "1920x1080"
        self.stream_resolution = saved_res
        saved_fps = str(self.settings.get("stream_fps", "60"))
        if saved_fps not in ("60", "120", "144", "165"):
            saved_fps = "60"
        self.stream_fps = saved_fps
        self.stream_hwaccel = "auto"
        self.active_tab_index = 0

        # Minimal dark macOS-like titlebar
        self.hb = Gtk.HeaderBar()
        self.hb.set_show_close_button(True)
        self.hb.props.title = "NodeDeck"
        self.hb.get_style_context().add_class("nd-headerbar")
        self.set_titlebar(self.hb)

        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        paned.set_position(296)
        self.add(paned)

        # === LEFT SIDEBAR (1:1 macOS SidebarView.swift) ===
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        sidebar.get_style_context().add_class("nd-sidebar")
        sidebar.set_size_request(272, -1)

        # 1. Sidebar Brand Header
        brand_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        brand_row.set_margin_top(14)
        brand_row.set_margin_bottom(10)
        brand_row.set_margin_start(14)
        brand_row.set_margin_end(12)

        brand_icon = Gtk.Label(label=">_")
        brand_icon.get_style_context().add_class("nd-brand-icon")
        brand_row.pack_start(brand_icon, False, False, 0)

        brand_text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        lbl_brand = Gtk.Label(label="NodeDeck")
        lbl_brand.get_style_context().add_class("nd-brand-title")
        lbl_brand.set_xalign(0)
        self.lbl_online_sub = Gtk.Label(label="")
        self.lbl_online_sub.get_style_context().add_class("nd-brand-sub")
        self.lbl_online_sub.set_xalign(0)
        brand_text.pack_start(lbl_brand, False, False, 0)
        brand_text.pack_start(self.lbl_online_sub, False, False, 0)
        brand_row.pack_start(brand_text, True, True, 0)

        self.btn_account_icon = Gtk.Button(label="◉")
        self.btn_account_icon.get_style_context().add_class("nd-icon-btn")
        self.btn_account_icon.connect("clicked", self.on_open_account_dialog)
        brand_row.pack_start(self.btn_account_icon, False, False, 0)

        self.btn_add = Gtk.Button(label="+")
        self.btn_add.get_style_context().add_class("nd-icon-btn")
        self.btn_add.connect("clicked", self.on_add_device)
        brand_row.pack_start(self.btn_add, False, False, 0)

        self.btn_refresh = Gtk.Button(label="↻")
        self.btn_refresh.get_style_context().add_class("nd-icon-btn")
        self.btn_refresh.connect("clicked", self.on_refresh_all)
        brand_row.pack_start(self.btn_refresh, False, False, 0)

        sidebar.pack_start(brand_row, False, False, 0)

        # 2. Search Pill
        self.search_entry = Gtk.SearchEntry()
        self.search_entry.get_style_context().add_class("nd-search")
        self.search_entry.set_margin_start(12)
        self.search_entry.set_margin_end(12)
        self.search_entry.set_margin_bottom(8)
        self.search_entry.connect("search-changed", self.on_search_changed)
        sidebar.pack_start(self.search_entry, False, False, 0)

        # 3. Segmented Filter Tray (All / Online / Remote)
        filter_tray = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)
        filter_tray.get_style_context().add_class("nd-segmented-tray")
        filter_tray.set_margin_start(12)
        filter_tray.set_margin_end(12)
        filter_tray.set_margin_bottom(10)
        self.filter_buttons = {}
        for key in ("all", "online", "remote"):
            fb = Gtk.ToggleButton()
            fb.get_style_context().add_class("nd-seg-btn")
            fb.set_active(key == "all")
            fb.connect("toggled", self.on_filter_toggled, key)
            filter_tray.pack_start(fb, True, True, 0)
            self.filter_buttons[key] = fb
        sidebar.pack_start(filter_tray, False, False, 0)

        sep1 = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        sep1.get_style_context().add_class("nd-divider")
        sidebar.pack_start(sep1, False, False, 0)

        # 4. Scrollable Host List
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.listbox = Gtk.ListBox()
        self.listbox.get_style_context().add_class("nd-host-list")
        self.listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.listbox.connect("row-selected", self.on_select_host)
        self.listbox.connect("button-press-event", self.on_listbox_button_press)
        scroll.add(self.listbox)
        sidebar.pack_start(scroll, True, True, 4)

        # 5. Pinned Local Host Quick Bar (1:1 macOS localHostQuickBar)
        host_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        host_bar.get_style_context().add_class("nd-card-compact")
        host_bar.set_margin_start(10)
        host_bar.set_margin_end(10)
        host_bar.set_margin_top(4)
        host_bar.set_margin_bottom(8)

        host_text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        self.lbl_host_title = Gtk.Label()
        self.lbl_host_title.set_xalign(0)
        self.lbl_host_sub = Gtk.Label()
        self.lbl_host_sub.get_style_context().add_class("nd-brand-sub")
        self.lbl_host_sub.set_xalign(0)
        host_text_box.pack_start(self.lbl_host_title, False, False, 0)
        host_text_box.pack_start(self.lbl_host_sub, False, False, 0)
        host_bar.pack_start(host_text_box, True, True, 0)

        self.sw_local_host = Gtk.Switch()
        self.sw_local_host.set_valign(Gtk.Align.CENTER)
        self.sw_local_host.connect("state-set", self.on_local_host_switch)
        host_bar.pack_end(self.sw_local_host, False, False, 0)

        self.btn_host_settings = Gtk.Button(label="⚙")
        self.btn_host_settings.set_valign(Gtk.Align.CENTER)
        self.btn_host_settings.get_style_context().add_class("nd-icon-btn")
        self.btn_host_settings.connect("clicked", self.on_configure_local_host)
        host_bar.pack_end(self.btn_host_settings, False, False, 0)
        sidebar.pack_start(host_bar, False, False, 0)

        # 5b. Pinned Local SSH Activation Bar (explicit sudo activation for metrics/terminal/SFTP)
        ssh_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        ssh_bar.get_style_context().add_class("nd-card-compact")
        ssh_bar.set_margin_start(10)
        ssh_bar.set_margin_end(10)
        ssh_bar.set_margin_top(0)
        ssh_bar.set_margin_bottom(8)

        ssh_text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        self.lbl_ssh_title = Gtk.Label()
        self.lbl_ssh_title.set_xalign(0)
        self.lbl_ssh_sub = Gtk.Label()
        self.lbl_ssh_sub.get_style_context().add_class("nd-brand-sub")
        self.lbl_ssh_sub.set_xalign(0)
        ssh_text_box.pack_start(self.lbl_ssh_title, False, False, 0)
        ssh_text_box.pack_start(self.lbl_ssh_sub, False, False, 0)
        ssh_bar.pack_start(ssh_text_box, True, True, 0)

        self.btn_activate_ssh = Gtk.Button()
        self.btn_activate_ssh.set_valign(Gtk.Align.CENTER)
        self.btn_activate_ssh.get_style_context().add_class("nd-icon-btn-accent")
        self.btn_activate_ssh.connect("clicked", self.on_activate_local_ssh)
        ssh_bar.pack_end(self.btn_activate_ssh, False, False, 0)
        sidebar.pack_start(ssh_bar, False, False, 0)

        # 6. Sidebar Footer (Account Pill + How It Works + Lang Toggle)
        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        footer.get_style_context().add_class("nd-footer-bar")

        self.btn_account = Gtk.Button()
        self.btn_account.get_style_context().add_class("nd-icon-btn")
        self.btn_account.connect("clicked", self.on_open_account_dialog)
        footer.pack_start(self.btn_account, True, True, 0)

        self.btn_arch = Gtk.Button()
        self.btn_arch.get_style_context().add_class("nd-icon-btn")
        self.btn_arch.connect("clicked", self.on_show_architecture)
        footer.pack_end(self.btn_arch, False, False, 0)

        self.btn_lang = Gtk.Button()
        self.btn_lang.get_style_context().add_class("nd-icon-btn")
        self.btn_lang.connect("clicked", self.on_toggle_lang)
        footer.pack_end(self.btn_lang, False, False, 0)

        sidebar.pack_end(footer, False, False, 0)
        paned.pack1(sidebar, False, False)

        # === RIGHT DETAIL CANVAS (1:1 macOS HostDetailView.swift) ===
        right_outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        right_outer.get_style_context().add_class("nd-detail-canvas")

        detail_scroll = Gtk.ScrolledWindow()
        detail_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.detail_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.detail_box.set_margin_top(22)
        self.detail_box.set_margin_bottom(24)
        self.detail_box.set_margin_start(24)
        self.detail_box.set_margin_end(24)
        detail_scroll.add(self.detail_box)
        right_outer.pack_start(detail_scroll, True, True, 0)

        status_wrap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        status_wrap.set_margin_start(24)
        status_wrap.set_margin_end(24)
        status_wrap.set_margin_bottom(8)
        self.status_label = Gtk.Label(label="")
        self.status_label.get_style_context().add_class("nd-status-strip")
        self.status_label.set_xalign(0)
        self.status_label.set_ellipsize(3)
        status_wrap.pack_start(self.status_label, True, True, 0)
        right_outer.pack_end(status_wrap, False, False, 0)

        paned.pack2(right_outer, True, False)

        self._update_chrome_labels()
        self.reload_hosts()
        self.sync_account_async(silent=True)
        self.refresh_all_metrics_async()

    def t(self, zh: str, en: str) -> str:
        return zh if self.lang == "zh" else en

    def _update_chrome_labels(self):
        self.search_entry.set_placeholder_text(self.t("搜索主机、IP 或用户…", "Search hosts, IPs, or users…"))
        self.btn_add.set_tooltip_text(self.t("添加设备", "Add Device"))
        self.btn_refresh.set_tooltip_text(self.t("刷新全部节点", "Refresh All Nodes"))

        online_cnt = sum(1 for h in self.hosts if (m := self.metrics_cache.get(h["alias"])) and "error" not in m)
        remote_cnt = sum(1 for h in self.hosts if h["alias"] in self.sunshine_hosts)
        self.lbl_online_sub.set_markup(
            f'<span foreground="#46d687">●</span> {online_cnt}/{len(self.hosts)} '
            + GLib.markup_escape_text(self.t("在线", "online"))
        )
        self.filter_buttons["all"].set_label(self.t(f"全部 {len(self.hosts)}", f"All {len(self.hosts)}"))
        self.filter_buttons["online"].set_label(self.t(f"在线 {online_cnt}", f"Online {online_cnt}"))
        self.filter_buttons["remote"].set_label(self.t(f"远控 {remote_cnt}", f"Remote {remote_cnt}"))

        host_bin = resolve_host_bin()
        running = is_local_host_running() if host_bin else False
        self._updating_host_switch = True
        try:
            self.sw_local_host.set_sensitive(bool(host_bin))
            self.sw_local_host.set_active(running)
        finally:
            self._updating_host_switch = False

        self.btn_host_settings.set_tooltip_text(self.t("本机被控设置（视频编码器 / 采集方式 / 端口）", "Local Host Settings (Encoder / Capture / Port)"))
        self.btn_host_settings.set_sensitive(bool(host_bin))

        if not host_bin:
            self.lbl_host_title.set_markup(f'<span foreground="#8b9bb0">○</span> <b>{GLib.markup_escape_text(self.t("本机被控端", "Local Host"))}</b>')
            self.lbl_host_sub.set_text(self.t("未安装 nodedeck-host", "nodedeck-host not bundled"))
        elif running:
            cfg_now = read_local_host_conf()
            cur_port = cfg_now.get("port", "47989")
            enc_kind, enc_info = detect_local_host_encoder_status()
            if enc_kind == "warn":
                self.lbl_host_title.set_markup(f'<span foreground="#f0a742">⚠</span> <b>{GLib.markup_escape_text(self.t("本机被控异常", "Host Warning"))}</b>')
                self.lbl_host_sub.set_text(self.t("编码器/采集未就绪 · 点 ⚙ 切换", "Encoder/capture issue · click ⚙"))
            elif enc_kind == "ok":
                short_enc = enc_info.split(" ", 1)[0]
                self.lbl_host_title.set_markup(f'<span foreground="#46d687">●</span> <b>{GLib.markup_escape_text(self.t("本机被控端", "Local Host"))}</b>')
                self.lbl_host_sub.set_text(self.t(f"运行中 · :{cur_port} · {short_enc}", f"Running · :{cur_port} · {short_enc}"))
            else:
                self.lbl_host_title.set_markup(f'<span foreground="#46d687">●</span> <b>{GLib.markup_escape_text(self.t("本机被控端", "Local Host"))}</b>')
                self.lbl_host_sub.set_text(self.t(f"运行中 · 端口 {cur_port}", f"Running · Port {cur_port}"))
        else:
            self.lbl_host_title.set_markup(f'<span foreground="#8b9bb0">○</span> <b>{GLib.markup_escape_text(self.t("本机被控端", "Local Host"))}</b>')
            self.lbl_host_sub.set_text(self.t("已关闭 · 点击右侧开启", "Stopped · Toggle to enable"))

        ssh_ok = is_local_ssh_running()
        if ssh_ok:
            self.lbl_ssh_title.set_markup(f'<span foreground="#46d687">●</span> <b>{GLib.markup_escape_text(self.t("本机 SSH", "Host SSH"))}</b>')
            self.lbl_ssh_sub.set_text(self.t("端口 22 运行中（性能面板就绪）", "Port 22 active (metrics ready)"))
            self.btn_activate_ssh.set_label(self.t("已激活", "Active"))
            self.btn_activate_ssh.get_style_context().remove_class("nd-icon-btn-accent")
            self.btn_activate_ssh.get_style_context().add_class("nd-icon-btn")
        else:
            self.lbl_ssh_title.set_markup(f'<span foreground="#f0a742">○</span> <b>{GLib.markup_escape_text(self.t("本机 SSH 未启用", "Host SSH Off"))}</b>')
            self.lbl_ssh_sub.set_text(self.t("需激活以查看性能面板/终端", "Activate for metrics & terminal"))
            self.btn_activate_ssh.set_label(self.t("激活主机 SSH", "Activate SSH"))
            self.btn_activate_ssh.get_style_context().remove_class("nd-icon-btn")
            self.btn_activate_ssh.get_style_context().add_class("nd-icon-btn-accent")

        acct = load_account_session()
        acct_user = acct.get("user", {}).get("username")
        acct_ip = acct.get("device", {}).get("virtual_ip")
        if acct_user:
            self.btn_account.set_label(f"● {acct_user} · {acct_ip}" if acct_ip else f"● {acct_user}")
            self.btn_account.get_style_context().add_class("nd-icon-btn-accent")
            self.btn_account_icon.get_style_context().add_class("nd-icon-btn-accent")
            self.btn_account_icon.set_tooltip_text(f"{acct_user} ({acct_ip})")
        else:
            self.btn_account.set_label(self.t("登录 / 组网", "Sign In / Mesh"))
            self.btn_account.get_style_context().remove_class("nd-icon-btn-accent")
            self.btn_account_icon.get_style_context().remove_class("nd-icon-btn-accent")
            self.btn_account_icon.set_tooltip_text(self.t("账号登录与内置组网", "Sign In & Built-in Mesh"))

        self.btn_lang.set_label("EN" if self.lang == "zh" else "中文")
        self.btn_arch.set_label(self.t("原理", "Info"))
        self.btn_arch.set_tooltip_text(self.t("技术原理与安全透明", "How It Works & Security"))

    def on_local_host_switch(self, _sw, state):
        if self._updating_host_switch:
            return False
        self.on_toggle_local_host(None, desired_state=bool(state))
        return False

    def on_configure_local_host(self, _btn=None):
        cfg = read_local_host_conf()
        gpus, render_nodes, sess_type = detect_local_gpu_summary()
        enc_kind, enc_info = detect_local_host_encoder_status()

        dlg = Gtk.Dialog(
            title=self.t("本机被控端设置（编码器与画面采集）", "Local Host Settings (Encoder & Capture)"),
            transient_for=self,
            flags=0,
        )
        dlg.set_default_size(500, 340)
        box = dlg.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(16)
        box.set_margin_end(16)

        gpu_line = " / ".join(gpus[:2]) if gpus else self.t("未检测到独立 GPU", "No discrete GPU detected")
        if enc_kind == "ok":
            status_line = self.t(f"当前生效编码器：{enc_info}", f"Active encoder: {enc_info}")
        elif enc_kind == "warn":
            status_line = self.t(
                "⚠ 上次启动未能初始化编码器/采集（常见于双显卡本切换或屏幕休眠），建议下方显式选择编码器并保存重启。",
                "⚠ Last startup failed to initialize capture/encoder. Pick an encoder below and apply.",
            )
        else:
            status_line = self.t("当前被控端尚未完成编码器探测。", "Encoder not probed yet.")

        info_lbl = Gtk.Label(
            label=self.t(
                f"本机环境：{sess_type.upper()} · GPU：{gpu_line}\n{status_line}",
                f"Environment: {sess_type.upper()} · GPU: {gpu_line}\n{status_line}",
            )
        )
        info_lbl.set_xalign(0)
        info_lbl.set_line_wrap(True)
        box.pack_start(info_lbl, False, False, 0)

        cmb_enc = Gtk.ComboBoxText()
        enc_options = [
            ("auto", self.t("自动选择 (auto · 优先硬编，失败自动回退软编)", "Auto (prefer HW, fallback to software)")),
            ("nvenc", self.t("NVIDIA NVENC (nvenc · 独显直连显示器推荐)", "NVIDIA NVENC (dedicated NVIDIA display)")),
            ("vaapi", self.t("VA-API (vaapi · Intel/AMD 核显硬编，需 VA 驱动)", "VA-API (Intel/AMD iGPU hardware encode)")),
            ("vulkan", self.t("Vulkan Video (vulkan · 通用硬件编码)", "Vulkan Video (hardware encode)")),
            ("software", self.t("CPU 软编 libx264 (software · 双显卡本/Wayland 最稳)", "Software libx264 (highest compatibility)")),
        ]
        cur_enc = cfg.get("encoder", "auto") or "auto"
        for opt_id, opt_lbl in enc_options:
            cmb_enc.append(opt_id, opt_lbl)
        cmb_enc.set_active_id(cur_enc if any(k == cur_enc for k, _ in enc_options) else "auto")

        cmb_cap = Gtk.ComboBoxText()
        cap_options = [
            ("auto", self.t("自动选择 (auto · Wayland 自动走 KMS)", "Auto (KMS on Wayland / X11 on Xorg)")),
            ("kms", self.t("KMS 底层直采 (kms · GNOME Wayland 推荐)", "KMS Direct Capture (GNOME Wayland)")),
            ("x11", self.t("X11 桌面采集 (x11 · 传统 Xorg 桌面)", "X11 Capture (Xorg desktop)")),
        ]
        cur_cap = cfg.get("capture", "auto") or "auto"
        for opt_id, opt_lbl in cap_options:
            cmb_cap.append(opt_id, opt_lbl)
        cmb_cap.set_active_id(cur_cap if any(k == cur_cap for k, _ in cap_options) else "auto")

        ent_port = Gtk.Entry(text=cfg.get("port", "47989"))

        cmb_drm = Gtk.ComboBoxText()
        cmb_drm.append("auto", self.t("自动 (auto)", "Auto"))
        for rn in render_nodes:
            cmb_drm.append(rn, rn)
        cur_drm = cfg.get("adapter_name", "auto") or "auto"
        cmb_drm.set_active_id(cur_drm if cur_drm in render_nodes else "auto")

        for lbl_txt, widget in [
            (self.t("视频编码器:", "Video Encoder:"), cmb_enc),
            (self.t("画面采集方式:", "Capture Method:"), cmb_cap),
            (self.t("渲染设备节点:", "DRM Render Node:"), cmb_drm),
            (self.t("监听端口:", "HTTP Port:"), ent_port),
        ]:
            row = Gtk.Box(spacing=8)
            lbl = Gtk.Label(label=lbl_txt)
            lbl.set_width_chars(14)
            lbl.set_xalign(0)
            row.pack_start(lbl, False, False, 0)
            row.pack_start(widget, True, True, 0)
            box.pack_start(row, False, False, 2)

        hint_lbl = Gtk.Label(
            label=self.t(
                "提示：Intel+NVIDIA 双显卡笔记本（如机械革命）在 Wayland 下若屏幕接在核显，推荐先选「CPU 软编 libx264」或安装 intel-media-va-driver 后选「VA-API」。",
                "Tip: On hybrid Intel+NVIDIA Wayland laptops where the built-in panel is wired to Intel iGPU, pick 'Software libx264' or 'VA-API' (with intel-media-va-driver).",
            )
        )
        hint_lbl.set_xalign(0)
        hint_lbl.set_line_wrap(True)
        hint_lbl.get_style_context().add_class("nd-brand-sub")
        box.pack_start(hint_lbl, False, False, 2)

        dlg.add_buttons(
            self.t("取消", "Cancel"),
            Gtk.ResponseType.CANCEL,
            self.t("保存并重启被控端", "Save & Restart Host"),
            Gtk.ResponseType.OK,
        )
        dlg.set_default_response(Gtk.ResponseType.OK)
        dlg.show_all()
        resp = dlg.run()
        sel_enc = cmb_enc.get_active_id() or "auto"
        sel_cap = cmb_cap.get_active_id() or "auto"
        sel_drm = cmb_drm.get_active_id() or "auto"
        sel_port = ent_port.get_text().strip() or "47989"
        dlg.destroy()

        if resp != Gtk.ResponseType.OK:
            return

        write_local_host_conf({
            "encoder": sel_enc,
            "capture": sel_cap,
            "adapter_name": sel_drm,
            "port": sel_port if sel_port.isdigit() else "47989",
        })
        self.status_label.set_text(self.t(f"已保存编码器 ({sel_enc})，正在重启本机被控端并探测…", f"Saved encoder ({sel_enc}), restarting local host…"))

        def worker():
            subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
            subprocess.run(["systemctl", "--user", "enable", "--now", "nodedeck-host.service"], capture_output=True)
            subprocess.run(["systemctl", "--user", "restart", "nodedeck-host.service"], capture_output=True)
            time.sleep(3.0)
            kind, info = detect_local_host_encoder_status()
            GLib.idle_add(self._on_local_host_configured, sel_enc, kind, info)

        threading.Thread(target=worker, daemon=True).start()

    def _on_local_host_configured(self, chosen_enc: str, kind: str, info: str):
        self._update_chrome_labels()
        if kind == "ok":
            self.status_label.set_text(self.t(f"本机被控端已就绪 · 当前编码器：{info}", f"Local host ready · Active encoder: {info}"))
        elif kind == "warn":
            self.status_label.set_text(
                self.t(
                    f"编码器 ({chosen_enc}) 未能启动，建议点 ⚙ 切换为 software (libx264) 并确认显示器未休眠",
                    f"Encoder ({chosen_enc}) failed; switch to software (libx264) in ⚙",
                )
            )
        else:
            self.status_label.set_text(self.t(f"已应用配置 ({chosen_enc}) 并重启本机被控端", f"Applied ({chosen_enc}) and restarted local host"))

    def on_activate_local_ssh(self, _btn):
        ssh_ok = is_local_ssh_running()
        has_pkexec = bool(shutil.which("pkexec"))
        dlg = Gtk.Dialog(
            title=self.t("激活主机 SSH 服务（需要管理员提权）", "Activate Host SSH Service (Admin Required)"),
            transient_for=self,
            flags=0,
        )
        dlg.set_default_size(460, 260)
        box = dlg.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(16)
        box.set_margin_end(16)

        msg = Gtk.Label(
            label=self.t(
                "查看 CPU/GPU 实时性能面板、交互式终端与 SFTP 文件浏览需要本机运行 openssh-server（22 端口）。\n\n"
                "NodeDeck 将申请一次管理员权限并自动执行：\n"
                "1. 安装 openssh-server、补齐 /run/sshd 与主机密钥（ssh-keygen -A）\n"
                "2. 自检 sshd -t、解决 Ubuntu 24.04 ssh.socket 冲突并开机自启 ssh.service\n"
                "3. 如启用了 ufw 防火墙，自动放行 22 与 47984-48010 端口\n"
                "4. 同步账号下全部设备公钥到 ~/.ssh/authorized_keys（此后手机/Mac 免密直连）\n\n"
                "（提权凭据仅用于本次操作，绝不落盘或上传）"
                + ("\n\n当前检测：端口 22 已开启，可再次执行以修复配置或同步公钥。" if ssh_ok else ""),
                "Live CPU/GPU metrics, terminal, and SFTP require openssh-server on port 22.\n\n"
                "NodeDeck will request one-time administrator elevation to:\n"
                "1. Install openssh-server, create /run/sshd & generate host keys (ssh-keygen -A)\n"
                "2. Validate sshd -t, resolve Ubuntu 24.04 ssh.socket conflict & enable ssh.service\n"
                "3. Allow ports 22 & 47984-48010 if UFW is active\n"
                "4. Sync account SSH public keys into ~/.ssh/authorized_keys\n\n"
                "(Credentials are never saved or transmitted.)",
            )
        )
        msg.set_xalign(0)
        msg.set_line_wrap(True)
        box.pack_start(msg, False, False, 0)

        ent_pwd = Gtk.Entry()
        ent_pwd.set_visibility(False)
        if has_pkexec:
            ent_pwd.set_placeholder_text(
                self.t(
                    "留空将弹出系统管理员提权框（推荐），或直接输入 sudo 密码",
                    "Leave blank for system auth prompt (recommended), or enter sudo password",
                )
            )
        else:
            ent_pwd.set_placeholder_text(self.t("输入本机 sudo 管理员密码", "Enter local sudo password"))
        ent_pwd.set_activates_default(True)
        box.pack_start(ent_pwd, False, False, 0)

        dlg.add_buttons(
            self.t("取消", "Cancel"),
            Gtk.ResponseType.CANCEL,
            self.t("提权并激活 SSH", "Elevate & Activate SSH"),
            Gtk.ResponseType.OK,
        )
        dlg.set_default_response(Gtk.ResponseType.OK)
        dlg.show_all()
        resp = dlg.run()
        pwd = ent_pwd.get_text()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK:
            return
        if not pwd and not has_pkexec:
            self.status_label.set_text(self.t("未检测到 pkexec，请输入 sudo 密码以完成提权。", "pkexec unavailable; please enter sudo password."))
            return

        self.status_label.set_text(self.t("正在申请管理员提权并激活本机 SSH 服务…", "Requesting elevation and activating host SSH…"))

        def worker():
            script = (
                "set -e; "
                "if ! command -v sshd >/dev/null 2>&1; then "
                "  if command -v apt-get >/dev/null 2>&1; then "
                "    DEBIAN_FRONTEND=noninteractive apt-get update -qq && "
                "    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server; "
                "  elif command -v dnf >/dev/null 2>&1; then "
                "    dnf install -y -q openssh-server; "
                "  elif command -v pacman >/dev/null 2>&1; then "
                "    pacman -Sy --noconfirm openssh; "
                "  fi; "
                "fi; "
                "mkdir -p /run/sshd && chmod 0755 /run/sshd; "
                "ssh-keygen -A >/dev/null 2>&1 || true; "
                "if ! /usr/sbin/sshd -t 2>/dev/null; then "
                "  if command -v dpkg-reconfigure >/dev/null 2>&1; then "
                "    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server >/dev/null 2>&1 || true; "
                "    mkdir -p /run/sshd && chmod 0755 /run/sshd; "
                "    ssh-keygen -A >/dev/null 2>&1 || true; "
                "  fi; "
                "fi; "
                "/usr/sbin/sshd -t; "
                "systemctl stop ssh.socket 2>/dev/null || true; "
                "systemctl disable ssh.socket 2>/dev/null || true; "
                "systemctl reset-failed ssh.service sshd.service 2>/dev/null || true; "
                "(systemctl enable --now ssh || systemctl enable --now sshd || service ssh start); "
                "if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then "
                "  ufw allow 22/tcp >/dev/null 2>&1 || true; "
                "  ufw allow 47984:48010/tcp >/dev/null 2>&1 || true; "
                "  ufw allow 47998:48010/udp >/dev/null 2>&1 || true; "
                "fi"
            )
            try:
                if pwd:
                    proc = subprocess.run(
                        ["sudo", "-S", "-k", "bash", "-c", script],
                        input=pwd + "\n",
                        capture_output=True,
                        text=True,
                        timeout=180,
                    )
                else:
                    proc = subprocess.run(
                        ["pkexec", "bash", "-c", script],
                        capture_output=True,
                        text=True,
                        timeout=180,
                    )
                if proc.returncode != 0:
                    lines = [ln.strip() for ln in (proc.stderr or proc.stdout).splitlines() if ln.strip() and "[sudo]" not in ln]
                    err_msg = "\n".join(lines[-4:]) if lines else f"Exit code {proc.returncode}"
                    GLib.idle_add(self._on_ssh_activation_failed, err_msg)
                    return
                acct = load_account_session()
                if acct.get("token"):
                    fresh = fetch_live_account_state(acct) or acct
                    sync_account_ssh_keys(fresh)
                GLib.idle_add(self._on_ssh_activated)
            except Exception as exc:
                GLib.idle_add(self._on_ssh_activation_failed, str(exc))

        threading.Thread(target=worker, daemon=True).start()

    def _on_ssh_activation_failed(self, err_msg: str):
        self._update_chrome_labels()
        self.status_label.set_text(self.t(f"激活 SSH 失败: {err_msg.splitlines()[-1]}", f"SSH activation failed: {err_msg.splitlines()[-1]}"))
        md = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text=self.t("激活主机 SSH 失败", "Host SSH Activation Failed"),
        )
        md.format_secondary_text(err_msg)
        md.run()
        md.destroy()

    def _on_ssh_activated(self):
        self._update_chrome_labels()
        self.status_label.set_text(
            self.t(
                "本机 SSH 已激活（端口 22 已监听 + 账号公钥已同步），手机/Mac 现在可直接查看性能面板！",
                "Host SSH activated (port 22 active + account keys synced)!",
            )
        )

    def on_open_account_dialog(self, _btn):
        acct = load_account_session()
        dlg = Gtk.Dialog(
            title=self.t("NodeDeck 统一账号与内置组网", "NodeDeck Account & Built-in Mesh"),
            transient_for=self,
            flags=0,
        )
        dlg.set_default_size(460, 360)
        box = dlg.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(16)
        box.set_margin_end(16)

        if acct.get("token"):
            user = acct.get("user", {}).get("username", "")
            dev = acct.get("device", {})
            info = Gtk.Label(
                label=self.t(
                    f"已登录账号：{user}\n本机节点：{dev.get('device_name', '')} ({dev.get('virtual_cidr', '')})\n控制服务器：{acct.get('server_url', DEFAULT_CONTROL_SERVER)}",
                    f"Signed in as: {user}\nDevice: {dev.get('device_name', '')} ({dev.get('virtual_cidr', '')})\nServer: {acct.get('server_url', DEFAULT_CONTROL_SERVER)}",
                )
            )
            info.set_xalign(0)
            box.pack_start(info, False, False, 0)

            devs = acct.get("devices", [])
            dev_lines = [
                f"• {d.get('device_name')} [{d.get('platform')}/{d.get('role')}] — {d.get('virtual_ip')} ({'online' if d.get('online') else 'offline'})"
                for d in devs
            ]
            lbl_devs = Gtk.Label(label="\n".join(dev_lines) if dev_lines else self.t("暂无其他设备", "No other devices"))
            lbl_devs.set_xalign(0)
            box.pack_start(lbl_devs, False, False, 4)

            dlg.add_buttons(
                self.t("退出登录", "Sign Out"),
                Gtk.ResponseType.REJECT,
                self.t("同步设备", "Sync"),
                Gtk.ResponseType.APPLY,
                self.t("关闭", "Close"),
                Gtk.ResponseType.OK,
            )
            dlg.show_all()
            resp = dlg.run()
            dlg.destroy()
            if resp == Gtk.ResponseType.REJECT:
                try:
                    agent = Path("/opt/nodedeck/nodedeck_mesh_agent.py")
                    if not agent.exists():
                        agent = Path(__file__).resolve().parent / "nodedeck_mesh_agent.py"
                    subprocess.run(["python3", str(agent), "logout"], timeout=10)
                except Exception:
                    pass
                self._update_chrome_labels()
            elif resp == Gtk.ResponseType.APPLY:
                self.sync_account_async(silent=False)
            return

        mode_combo = Gtk.ComboBoxText()
        mode_combo.append("login", self.t("登录已有账号", "Sign In"))
        mode_combo.append("register", self.t("使用邀请码注册", "Register with Invite Code"))
        mode_combo.set_active(0)
        box.pack_start(mode_combo, False, False, 0)

        ent_user = Gtk.Entry()
        ent_user.set_placeholder_text(self.t("用户名", "Username"))
        box.pack_start(ent_user, False, False, 0)

        ent_pass = Gtk.Entry()
        ent_pass.set_visibility(False)
        ent_pass.set_placeholder_text(self.t("密码", "Password"))
        box.pack_start(ent_pass, False, False, 0)

        ent_invite = Gtk.Entry()
        ent_invite.set_placeholder_text(self.t("邀请码（注册必填）", "Invite Code (required for registration)"))
        box.pack_start(ent_invite, False, False, 0)

        ent_server = Gtk.Entry()
        ent_server.set_text(DEFAULT_CONTROL_SERVER)
        box.pack_start(ent_server, False, False, 0)

        def on_mode_change(_cb):
            ent_invite.set_visible(mode_combo.get_active_id() == "register")

        mode_combo.connect("changed", on_mode_change)
        dlg.add_buttons(
            self.t("取消", "Cancel"),
            Gtk.ResponseType.CANCEL,
            self.t("确认并组网", "Continue"),
            Gtk.ResponseType.OK,
        )
        dlg.show_all()
        ent_invite.set_visible(False)
        resp = dlg.run()
        mode = mode_combo.get_active_id()
        u = ent_user.get_text().strip()
        p = ent_pass.get_text()
        inv = ent_invite.get_text().strip()
        srv = ent_server.get_text().strip() or DEFAULT_CONTROL_SERVER
        dlg.destroy()

        if resp != Gtk.ResponseType.OK or not u or not p:
            return

        agent = Path("/opt/nodedeck/nodedeck_mesh_agent.py")
        if not agent.exists():
            agent = Path(__file__).resolve().parent / "nodedeck_mesh_agent.py"
        cmd = ["python3", str(agent), mode, "--server", srv, "--username", u, "--password", p, "--role", "both"]
        if mode == "register":
            cmd += ["--invite", inv]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        if res.returncode == 0:
            self.sync_account_async(silent=False)
            self._update_chrome_labels()
            self.status_label.set_text(self.t(f"已登录 {u}，正在同步账号设备…", f"Signed in as {u}, syncing devices…"))
        else:
            err = (res.stderr or res.stdout).strip()
            self.status_label.set_text(self.t(f"认证失败: {err}", f"Auth failed: {err}"))

    def on_refresh_all(self, _btn=None):
        self._update_chrome_labels()
        self.reload_hosts()
        self.sync_account_async(silent=False)
        self.refresh_all_metrics_async()

    def sync_account_async(self, silent: bool = False):
        acct = load_account_session()
        if not acct.get("token"):
            return

        def worker():
            try:
                # Auto-heal upgraded sessions: ensure user-space mesh daemon is running (zero sudo)
                if os.geteuid() != 0:
                    if subprocess.run(["systemctl", "--user", "is-active", "--quiet", "nodedeck-mesh.service"], capture_output=True).returncode != 0:
                        if subprocess.run(["systemctl", "--user", "enable", "--now", "nodedeck-mesh.service"], capture_output=True).returncode != 0:
                            agent = Path("/opt/nodedeck/nodedeck_mesh_agent.py")
                            if not agent.exists():
                                agent = Path(__file__).resolve().parent / "nodedeck_mesh_agent.py"
                            if subprocess.run(["pgrep", "-u", str(os.getuid()), "-f", "nodedeck_mesh_agent.py.*daemon"], capture_output=True).returncode != 0 and agent.exists():
                                subprocess.Popen(
                                    ["python3", str(agent), "--state-dir", str(Path.home() / ".config/nodedeck"), "daemon"],
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    stdin=subprocess.DEVNULL,
                                    start_new_session=True,
                                )
                fresh = fetch_live_account_state(acct) or acct
                upload_linux_client_cert(fresh)
                upload_linux_ssh_pubkey(fresh)
                sync_account_ssh_keys(fresh)
                added = self._sync_account_devices_to_linux(fresh)
                GLib.idle_add(self._on_account_synced, fresh, added, silent, None)
            except Exception as exc:
                GLib.idle_add(self._on_account_synced, acct, 0, silent, str(exc))

        threading.Thread(target=worker, daemon=True).start()

    def _on_account_synced(self, acct: dict, synced_count: int, silent: bool, err: str | None):
        self.reload_hosts()
        self._update_chrome_labels()
        if err:
            if not silent:
                self.status_label.set_text(self.t(f"账号同步失败: {err}", f"Account sync failed: {err}"))
        else:
            if synced_count > 0:
                self.refresh_all_metrics_async()
            if not silent:
                devs_total = len(acct.get("devices", []))
                self.status_label.set_text(
                    self.t(
                        f"账号同步完成：共 {devs_total} 台设备，已同步 {synced_count} 台主机节点",
                        f"Synced {devs_total} account device(s), {synced_count} host(s) ready",
                    )
                )

    def _sync_account_devices_to_linux(self, acct: dict) -> int:
        if not acct:
            return 0
        self_id = acct.get("device", {}).get("device_id")
        self_ip = acct.get("device", {}).get("virtual_ip")
        sunshine_hosts = load_sunshine_hosts_dict()
        existing_ssh = parse_ssh_hosts()
        synced_count = 0

        for dev in acct.get("devices", []):
            dev_id = dev.get("device_id")
            ip = str(dev.get("virtual_ip") or "").strip()
            alias = str(dev.get("device_name") or "").strip()
            if not ip or not alias or dev_id == self_id or ip == self_ip:
                continue
            if dev.get("role") not in ("host", "both"):
                continue

            ssh_user = str(dev.get("ssh_user") or os.getenv("USER") or "root").strip()
            ssh_port = str(int(dev.get("ssh_port") or 22))
            match_host = next(
                (h for h in existing_ssh if h["alias"].lower() == alias.lower() or h["hostname"] == ip),
                None,
            )
            if match_host:
                target_alias = match_host["alias"]
                if match_host["hostname"] != ip or (dev.get("ssh_user") and match_host["user"] != ssh_user) or str(match_host["port"]) != ssh_port:
                    update_ssh_host(target_alias, target_alias, ip, ssh_user, ssh_port)
            else:
                target_alias = alias
                append_ssh_host(target_alias, ip, ssh_user, ssh_port)
                existing_ssh.append({"alias": target_alias, "hostname": ip, "user": ssh_user, "port": ssh_port})
            synced_count += 1

            if dev.get("sunshine_enabled"):
                sunshine_hosts[target_alias] = {
                    "hostAlias": target_alias,
                    "address": ip,
                    "httpPort": int(dev.get("sunshine_http_port") or 47989),
                    "httpsPort": int(dev.get("sunshine_https_port") or 47984),
                    "serverName": alias,
                    "isPaired": True,
                }

        save_json(SUNSHINE_FILE, sunshine_hosts)
        self.sunshine_hosts = sunshine_hosts
        return synced_count

    def on_toggle_local_host(self, _btn, desired_state: bool | None = None):
        host_bin = resolve_host_bin()
        if not host_bin:
            return
        running = is_local_host_running()
        should_start = (not running) if desired_state is None else desired_state
        try:
            if not should_start:
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
        self.reload_hosts()

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
                    "无第三方中转与遥测上报。所有 SSH 配置（~/.ssh/config）、RSA-2048 客户端证书（~/.config/nodedeck/moonlight）与隔离配置均严格保存在本机。",
                    "No third-party relay and zero telemetry. All SSH configs (~/.ssh/config), RSA-2048 client certs (~/.config/nodedeck/moonlight), and profiles stay strictly on your machine.",
                ),
            ),
            (
                self.t("2. 内置主控端与无头被控端（自包含 All-in-One）", "2. Built-in Client & Headless Host (Self-Contained)"),
                self.t(
                    "主控端内置 moonlight-common-c（RTSP + ENet + FEC）与静态精简版 FFmpeg 7.1.1（自动支持 VAAPI/CUDA 硬解）；被控端内置源码编译无头 Sunshine（nodedeck-host），免外部多媒体库依赖。",
                    "Built-in moonlight-common-c client with statically linked FFmpeg 7.1.1 (VAAPI/CUDA decode), paired with source-built headless Sunshine host (nodedeck-host).",
                ),
            ),
            (
                self.t("3. 免 PIN 证书配对与自动 SSH Ed25519 公钥同步", "3. Zero-PIN Pairing & Auto Ed25519 Key Sync"),
                self.t(
                    "同账号设备自动交换 Moonlight 证书与 SSH Ed25519 公钥，零配置免密直连；Linux 多用户节点支持独立虚拟 Xorg (:99)、独立 GPU 绑定与静音虚拟音频汇。",
                    "Same-account devices automatically exchange Moonlight certificates and Ed25519 SSH keys; Linux hosts support isolated virtual Xorg (:99), GPU binding, and virtual audio sinks.",
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
            lbl.set_markup(f"<b>{GLib.markup_escape_text(heading)}</b>\n<span foreground='#9fb0c3'>{GLib.markup_escape_text(desc)}</span>")
            lbl.set_line_wrap(True)
            lbl.set_xalign(0)
            box.pack_start(lbl, False, False, 4)

        dlg.show_all()
        dlg.run()
        dlg.destroy()

    def on_search_changed(self, entry):
        self.search_query = entry.get_text().strip().lower()
        self.reload_hosts()

    def on_filter_toggled(self, btn, key):
        if not btn.get_active():
            if self.filter_mode == key:
                btn.set_active(True)
            return
        self.filter_mode = key
        for k, other in self.filter_buttons.items():
            if k != key and other.get_active():
                other.set_active(False)
        self.reload_hosts()

    def toggle_pin_host(self, alias: str):
        if alias in self.pinned_aliases:
            self.pinned_aliases.remove(alias)
        else:
            self.pinned_aliases.add(alias)
        self.settings["pinned_aliases"] = sorted(self.pinned_aliases)
        save_json(SETTINGS_FILE, self.settings)
        self.reload_hosts()

    def confirm_and_delete_host(self, host: dict):
        alias = host["alias"]
        dlg = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text=self.t(f"确定删除设备「{alias}」吗？", f"Delete host '{alias}'?"),
        )
        dlg.format_secondary_text(
            self.t(
                f"将从 ~/.ssh/config 与远程桌面配置中移除 {host['user']}@{host['hostname']}。",
                f"This removes {host['user']}@{host['hostname']} from ~/.ssh/config and Sunshine config.",
            )
        )
        resp = dlg.run()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK:
            return
        delete_ssh_host(alias)
        if alias in self.sunshine_hosts:
            self.sunshine_hosts.pop(alias, None)
            save_json(SUNSHINE_FILE, self.sunshine_hosts)
        if alias in self.host_profiles:
            self.host_profiles.pop(alias, None)
            save_json(PROFILES_FILE, self.host_profiles)
        if alias in self.pinned_aliases:
            self.pinned_aliases.discard(alias)
            self.settings["pinned_aliases"] = sorted(self.pinned_aliases)
            save_json(SETTINGS_FILE, self.settings)
        self.metrics_cache.pop(alias, None)
        if self.selected_host and self.selected_host["alias"] == alias:
            self.selected_host = None
        self.reload_hosts()
        self.status_label.set_text(self.t(f"已删除设备 {alias}", f"Deleted host {alias}"))

    def on_listbox_button_press(self, listbox, event):
        if event.button != 3:
            return False
        row = listbox.get_row_at_y(int(event.y))
        if row is None or not hasattr(row, "host_data"):
            return False
        listbox.select_row(row)
        h = row.host_data
        alias = h["alias"]
        menu = Gtk.Menu()

        def add_item(label, cb):
            mi = Gtk.MenuItem(label=label)
            mi.connect("activate", lambda *_: cb())
            menu.append(mi)

        add_item(self.t("打开终端", "Open Terminal"), lambda: subprocess.Popen(["x-terminal-emulator", "-e", "ssh", alias]))
        saved = self.sunshine_hosts.get(alias)
        if saved:
            add_item(self.t("启动远程桌面", "Launch Remote Desktop"), lambda: self.launch_stream(saved))
        add_item("VS Code Remote SSH", lambda: self.open_vscode_remote(h))
        add_item(self.t("刷新状态", "Refresh Metrics"), lambda: self.refresh_metrics_async(alias))
        add_item(self.t("输入密码配置免密登录", "Authorize SSH Key with Password"), lambda: self.on_authorize_host_password(h))
        menu.append(Gtk.SeparatorMenuItem())
        pin_lbl = self.t("取消置顶", "Unpin") if alias in self.pinned_aliases else self.t("置顶设备", "Pin to Top")
        add_item(pin_lbl, lambda: self.toggle_pin_host(alias))
        add_item(
            self.t("复制 SSH 命令", "Copy SSH Command"),
            lambda: Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(f"ssh {alias}", -1),
        )
        add_item(self.t("编辑设备", "Edit Host"), lambda: self.on_edit_device(h))
        menu.append(Gtk.SeparatorMenuItem())
        add_item(self.t("删除设备", "Delete Host"), lambda: self.confirm_and_delete_host(h))

        menu.show_all()
        menu.popup_at_pointer(event)
        return True

    def on_authorize_host_password(self, host: dict):
        dlg = Gtk.Dialog(
            title=self.t(f"授权 SSH 免密登录 · {host['alias']}", f"Authorize SSH Key · {host['alias']}"),
            transient_for=self,
            flags=0,
        )
        dlg.set_default_size(420, 220)
        box = dlg.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(16)
        box.set_margin_end(16)

        hint = Gtk.Label(
            label=self.t(
                f"输入 {host['hostname']}:{host['port']} 的登录账号与密码（仅用一次，不会保存密码）。\nNodeDeck 将自动生成本地 Ed25519 公钥并安装到目标主机，之后永久免密直连。",
                f"Enter credentials for {host['hostname']}:{host['port']} (used once, never saved).\nNodeDeck will install your local Ed25519 public key for permanent passwordless SSH.",
            )
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(hint, False, False, 0)

        ent_user = Gtk.Entry()
        ent_user.set_text(host["user"])
        ent_user.set_placeholder_text(self.t("目标用户名", "Username"))
        box.pack_start(ent_user, False, False, 0)

        ent_pwd = Gtk.Entry()
        ent_pwd.set_visibility(False)
        ent_pwd.set_placeholder_text(self.t("目标用户密码", "Password"))
        box.pack_start(ent_pwd, False, False, 0)

        dlg.add_buttons(
            self.t("取消", "Cancel"),
            Gtk.ResponseType.CANCEL,
            self.t("授权并配置免密", "Authorize & Install Key"),
            Gtk.ResponseType.OK,
        )
        dlg.show_all()
        resp = dlg.run()
        u = ent_user.get_text().strip() or host["user"]
        p = ent_pwd.get_text()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK or not p:
            return

        if u != host["user"]:
            update_ssh_host(host["alias"], host["alias"], host["hostname"], u, str(host["port"]))
            host["user"] = u

        self.status_label.set_text(self.t(f"正在向 {host['alias']} 安装 Ed25519 公钥…", f"Installing SSH key on {host['alias']}…"))

        def worker():
            ok, msg = install_ssh_pubkey_with_password(host["hostname"], int(host["port"]), u, p)
            GLib.idle_add(self._on_authorize_done, host["alias"], ok, msg)

        threading.Thread(target=worker, daemon=True).start()

    def _on_authorize_done(self, alias: str, ok: bool, msg: str):
        if ok:
            self.status_label.set_text(self.t(f"已为 {alias} 配置免密公钥，正在刷新…", f"Installed SSH key on {alias}, refreshing…"))
            self.reload_hosts()
            self.refresh_metrics_async(alias)
        else:
            self.status_label.set_text(self.t(f"授权失败 ({alias}): {msg}", f"Auth failed ({alias}): {msg}"))
            err_dlg = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text=self.t(f"无法授权 {alias}", f"Failed to authorize {alias}"),
            )
            err_dlg.format_secondary_text(msg)
            err_dlg.run()
            err_dlg.destroy()

    def open_vscode_remote(self, host: dict):
        code_bin = None
        for cand in ("code", "code-insiders", "codium"):
            if subprocess.run(["which", cand], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                code_bin = cand
                break
        if not code_bin:
            self.status_label.set_text(self.t("未检测到 VS Code (code 命令)", "VS Code CLI not found"))
            return
        subprocess.Popen([code_bin, "--remote", f"ssh-remote+{host['alias']}"])
        self.status_label.set_text(self.t(f"正在通过 VS Code 打开 {host['alias']}…", f"Opening {host['alias']} in VS Code…"))

    def refresh_mesh_transports_async(self):
        def _bg():
            peers = fetch_easytier_peer_transports()
            def _apply():
                changed = peers != self.mesh_transports
                self.mesh_transports = peers
                if changed and self.selected_host:
                    self.render_detail()
            GLib.idle_add(_apply)
        threading.Thread(target=_bg, daemon=True).start()

    def refresh_all_metrics_async(self):
        self.refresh_mesh_transports_async()
        for h in list(self.hosts):
            self.refresh_metrics_async(h["alias"])

    def reload_hosts(self):
        prev_alias = self.selected_host["alias"] if self.selected_host else None
        all_hosts = parse_ssh_hosts()
        all_hosts.sort(key=lambda h: (0 if h["alias"] in self.pinned_aliases else 1, h["alias"].lower()))
        self.hosts = all_hosts

        filtered = []
        for h in all_hosts:
            alias = h["alias"]
            if self.search_query:
                hay = f"{alias} {h['hostname']} {h['user']}".lower()
                if self.search_query not in hay:
                    continue
            if self.filter_mode == "online":
                m = self.metrics_cache.get(alias)
                if not m or "error" in m:
                    continue
            elif self.filter_mode == "remote":
                if alias not in self.sunshine_hosts:
                    continue
            filtered.append(h)

        self._reloading_hosts = True
        try:
            for child in self.listbox.get_children():
                self.listbox.remove(child)
            target_idx = 0
            for idx, h in enumerate(filtered):
                alias = h["alias"]
                if alias == prev_alias:
                    target_idx = idx
                row = Gtk.ListBoxRow()
                row.host_data = h

                outer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
                outer.set_margin_top(8)
                outer.set_margin_bottom(8)
                outer.set_margin_start(10)
                outer.set_margin_end(10)

                outer.pack_start(_make_avatar(alias, large=False), False, False, 0)

                mid = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
                top_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
                m = self.metrics_cache.get(alias)
                if not m:
                    dot = '<span foreground="#d18a21">●</span>'
                    rtt_txt = ""
                elif "error" in m:
                    dot = '<span foreground="#c74045">●</span>'
                    rtt_txt = ""
                else:
                    dot = '<span foreground="#46d687">●</span>'
                    rtt_val = m.get("RTT_MS", "?")
                    rtt_txt = f'<span foreground="#46d687" size="small">{rtt_val} ms</span>'

                pin_mark = '<span foreground="#26b8a4">★ </span>' if alias in self.pinned_aliases else ""
                lbl1 = Gtk.Label()
                lbl1.set_markup(f"{dot} {pin_mark}<b>{GLib.markup_escape_text(alias)}</b>")
                lbl1.set_xalign(0)
                lbl1.set_ellipsize(3)
                top_row.pack_start(lbl1, True, True, 0)
                if rtt_txt:
                    lbl_rtt = Gtk.Label()
                    lbl_rtt.set_markup(rtt_txt)
                    top_row.pack_end(lbl_rtt, False, False, 0)
                mid.pack_start(top_row, False, False, 0)

                bot_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
                lbl2 = Gtk.Label(label=f'{h["user"]}@{h["hostname"]}')
                lbl2.get_style_context().add_class("nd-dim")
                lbl2.get_style_context().add_class("nd-mono")
                lbl2.set_xalign(0)
                lbl2.set_ellipsize(3)
                bot_row.pack_start(lbl2, True, True, 0)

                if alias in self.sunshine_hosts:
                    bot_row.pack_end(_make_badge("Remote", "nd-badge-remote"), False, False, 0)
                if m and "error" not in m and m.get("GPUS"):
                    bot_row.pack_end(_make_badge("GPU", "nd-badge-gpu"), False, False, 0)

                mid.pack_start(bot_row, False, False, 0)
                outer.pack_start(mid, True, True, 0)
                row.add(outer)
                self.listbox.add(row)

            self.listbox.show_all()
            if filtered:
                row_to_sel = self.listbox.get_row_at_index(target_idx)
                self.listbox.select_row(row_to_sel)
                self.selected_host = filtered[target_idx]
            else:
                self.selected_host = None
                for child in self.detail_box.get_children():
                    self.detail_box.remove(child)
        finally:
            self._reloading_hosts = False
        self._update_chrome_labels()
        if self.selected_host:
            self.render_detail()

    def on_select_host(self, _lb, row):
        if self._reloading_hosts or row is None:
            return
        self.selected_host = row.host_data
        self.render_detail()
        if self.selected_host["alias"] not in self.metrics_cache:
            self.refresh_metrics_async(self.selected_host["alias"])

    def refresh_metrics_async(self, alias: str):
        self.status_label.set_text(self.t(f"正在探测 {alias} 实时指标…", f"Probing live metrics for {alias}…"))
        host_obj = next((h for h in self.hosts if h.get("alias") == alias), {})

        saved_sun = self.sunshine_hosts.get(alias)

        def worker():
            try:
                data = collect_remote_metrics(
                    alias,
                    host_name=str(host_obj.get("hostname") or alias),
                    port=int(host_obj.get("port") or 22),
                    has_proxy=bool(host_obj.get("proxyjump")),
                )
            except Exception as exc:
                data = {"error": str(exc)}
            # Mode A: if SSH is disabled/unconfigured on the target PC, still show Online when nodedeck-host is reachable
            if "error" in data:
                sun_addr = str((saved_sun or {}).get("address") or host_obj.get("hostname") or "")
                sun_port = int((saved_sun or {}).get("httpPort") or 47989)
                if sun_addr:
                    sun_rtt = measure_tcp_rtt_ms(sun_addr, sun_port, timeout=2.0)
                    if sun_rtt is not None:
                        data = {
                            "OS": "Remote Desktop Host (No SSH)",
                            "KERNEL": "Account-Paired",
                            "CORES": "--",
                            "CPU": "0",
                            "MEM_USED_MB": "0",
                            "MEM_TOTAL_MB": "1",
                            "DISK_USED_GB": "0",
                            "DISK_TOTAL_GB": "1",
                            "GPUS": [],
                            "PROCS": [],
                            "RTT_MS": sun_rtt,
                        }
            self.metrics_cache[alias] = data
            GLib.idle_add(self._on_metrics_ready, alias, data)

        threading.Thread(target=worker, daemon=True).start()

    def _on_metrics_ready(self, alias, data):
        if "error" in data:
            self.status_label.set_text(f"{alias}: {data['error']}")
        else:
            self.status_label.set_text(f"{alias} online · RTT {data.get('RTT_MS', '?')} ms")
        self.reload_hosts()

    def _switch_detail_tab(self, idx: int):
        if self.active_tab_index != idx:
            self.active_tab_index = idx
            self.render_detail()

    def _make_kpi_card(self, title: str, value_txt: str, sub_txt: str, frac: float, bar_class: str) -> Gtk.Box:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.get_style_context().add_class("nd-card")

        lbl_t = Gtk.Label(label=title)
        lbl_t.get_style_context().add_class("nd-kpi-label")
        lbl_t.set_xalign(0)
        card.pack_start(lbl_t, False, False, 0)

        lbl_v = Gtk.Label(label=value_txt)
        lbl_v.get_style_context().add_class("nd-kpi-value")
        lbl_v.set_xalign(0)
        card.pack_start(lbl_v, False, False, 0)

        pbar = Gtk.ProgressBar()
        pbar.set_fraction(max(0.0, min(1.0, frac)))
        pbar.get_style_context().add_class("nd-bar")
        pbar.get_style_context().add_class(_severity_bar_class(frac, bar_class))
        card.pack_start(pbar, False, False, 2)

        lbl_s = Gtk.Label(label=sub_txt)
        lbl_s.get_style_context().add_class("nd-kpi-sub")
        lbl_s.set_xalign(0)
        lbl_s.set_ellipsize(3)
        card.pack_start(lbl_s, False, False, 0)
        return card

    def render_detail(self):
        for child in self.detail_box.get_children():
            self.detail_box.remove(child)
        h = self.selected_host
        if not h:
            return
        alias = h["alias"]
        m = self.metrics_cache.get(alias)
        saved = self.sunshine_hosts.get(alias)

        # === 1. HERO HEADER (1:1 macOS HostDetailView.hostHeader) ===
        hero = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        hero.pack_start(_make_avatar(alias, large=True), False, False, 0)

        ident = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        lbl_alias = Gtk.Label()
        lbl_alias.set_markup(f'<span size="xx-large" weight="bold">{GLib.markup_escape_text(alias)}</span>')
        lbl_alias.set_xalign(0)
        ident.pack_start(lbl_alias, False, False, 0)

        lbl_target = Gtk.Label(label=f'{h["user"]}@{h["hostname"]}:{h["port"]}')
        lbl_target.get_style_context().add_class("nd-dim")
        lbl_target.get_style_context().add_class("nd-mono")
        lbl_target.set_xalign(0)
        lbl_target.set_selectable(True)
        ident.pack_start(lbl_target, False, False, 0)

        badges_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        if not m:
            badges_row.pack_start(_make_badge(self.t("● 探测中", "● Probing"), "nd-badge-checking"), False, False, 0)
        elif "error" in m:
            badges_row.pack_start(_make_badge(self.t("● 离线", "● Offline"), "nd-badge-offline"), False, False, 0)
        else:
            badges_row.pack_start(_make_badge(self.t("● 在线", "● Online"), "nd-badge-online"), False, False, 0)
        mesh_info = match_easytier_transport(self.mesh_transports, h["hostname"], alias)
        if mesh_info:
            if mesh_info["is_p2p"]:
                m_cls = "nd-badge-lan" if "tcp" in mesh_info.get("proto", "") else "nd-badge-online"
                m_lbl = _make_badge(mesh_info["detailed"], m_cls)
                m_lbl.set_tooltip_text(self.t("EasyTier 点对点直连", "EasyTier P2P Direct"))
            else:
                m_cls = "nd-badge-offline" if mesh_info.get("is_tcp_relay") else "nd-badge-checking"
                m_lbl = _make_badge(
                    ("⚠ " if mesh_info.get("is_tcp_relay") else "") + mesh_info["detailed"],
                    m_cls,
                )
                via_txt = f" (via {mesh_info['relay_via']})" if mesh_info.get("relay_via") else ""
                m_lbl.set_tooltip_text(self.t(
                    f"当前经由中继转发{via_txt}。若码率低或延迟高，请在云端防火墙放行 UDP 11010 或将 EasyTier 加入代理直连以恢复 P2P。",
                    f"Relayed{via_txt}. Open UDP 11010 on seed server or bypass local proxy for EasyTier to restore P2P.",
                ))
            badges_row.pack_start(m_lbl, False, False, 0)
        elif _is_lan_or_mesh_host(h["hostname"]):
            badges_row.pack_start(_make_badge("Mesh / LAN", "nd-badge-lan"), False, False, 0)
        else:
            badges_row.pack_start(_make_badge("WAN", "nd-badge-wan"), False, False, 0)
        if m and "error" not in m:
            badges_row.pack_start(_make_badge(f'⚡ {m.get("RTT_MS", "?")} ms', "nd-badge-neutral"), False, False, 0)
        if saved:
            badges_row.pack_start(_make_badge("Remote", "nd-badge-remote"), False, False, 0)
        ident.pack_start(badges_row, False, False, 0)
        hero.pack_start(ident, True, True, 0)

        # Primary CTA Buttons
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        actions.set_valign(Gtk.Align.CENTER)

        btn_term = Gtk.Button(label=self.t("▸ 打开终端", "▸ Terminal"))
        btn_term.get_style_context().add_class("nd-btn-primary")
        btn_term.connect("clicked", lambda *_: subprocess.Popen(["x-terminal-emulator", "-e", "ssh", alias]))
        actions.pack_start(btn_term, False, False, 0)

        if saved:
            btn_stream = Gtk.Button(label=self.t("▶ 远程桌面", "▶ Remote Desktop"))
            btn_stream.get_style_context().add_class("nd-btn-primary")
            btn_stream.connect("clicked", lambda *_: self.launch_stream(saved))
            actions.pack_start(btn_stream, False, False, 0)

        btn_vscode = Gtk.Button(label="VS Code")
        btn_vscode.get_style_context().add_class("nd-btn-secondary")
        btn_vscode.connect("clicked", lambda *_: self.open_vscode_remote(h))
        actions.pack_start(btn_vscode, False, False, 0)

        btn_refresh_one = Gtk.Button(label="↻")
        btn_refresh_one.get_style_context().add_class("nd-btn-secondary")
        btn_refresh_one.set_tooltip_text(self.t("刷新本节点状态", "Refresh Host"))
        btn_refresh_one.connect("clicked", lambda *_: self.refresh_metrics_async(alias))
        actions.pack_start(btn_refresh_one, False, False, 0)

        hero.pack_end(actions, False, False, 0)
        self.detail_box.pack_start(hero, False, False, 0)

        # === 2. SEGMENTED PILL TAB BAR (1:1 macOS HostDetailView.tabPickerBar) ===
        host_fwds = [f for f in self.forwards if f["hostAlias"] == alias]
        active_fwds = sum(1 for f in host_fwds if f["id"] in self.forward_procs and self.forward_procs[f["id"]].poll() is None)
        net_badge = active_fwds + (1 if saved else 0)
        net_title = self.t("远程与网络", "Desktop & Network") + (f" ({net_badge})" if net_badge > 0 else "")

        tab_tray = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        tab_tray.get_style_context().add_class("nd-segmented-tray")
        for idx, lbl in [
            (0, self.t("概览", "Overview")),
            (1, net_title),
            (2, self.t("工作区与工具", "Workspace & Tools")),
        ]:
            tb = Gtk.Button(label=lbl)
            tb.get_style_context().add_class("nd-tab-btn")
            if self.active_tab_index == idx:
                tb.get_style_context().add_class("nd-tab-active")
            tb.connect("clicked", lambda *_, i=idx: self._switch_detail_tab(i))
            tab_tray.pack_start(tb, False, False, 0)
        tab_wrap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        tab_wrap.pack_start(tab_tray, False, False, 0)
        self.detail_box.pack_start(tab_wrap, False, False, 0)

        # === 3. OFFLINE / AUTH ERROR BANNER (1:1 macOS offlineBanner) ===
        if m and "error" in m:
            alert = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            alert.get_style_context().add_class("nd-alert-card")
            alert_txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            at1 = Gtk.Label()
            at1.set_markup(f'<span foreground="#ff7b80" weight="bold">{GLib.markup_escape_text(self.t("SSH 连接失败或需要授权公钥", "SSH Connection Failed / Authorization Needed"))}</span>')
            at1.set_xalign(0)
            at2 = Gtk.Label(label=str(m["error"]))
            at2.get_style_context().add_class("nd-dim")
            at2.set_xalign(0)
            at2.set_line_wrap(True)
            alert_txt.pack_start(at1, False, False, 0)
            alert_txt.pack_start(at2, False, False, 0)
            alert.pack_start(alert_txt, True, True, 0)

            btn_auth = Gtk.Button(label=self.t("🔑 输入密码配置免密", "🔑 Authorize Key"))
            btn_auth.get_style_context().add_class("nd-btn-primary")
            btn_auth.set_valign(Gtk.Align.CENTER)
            btn_auth.connect("clicked", lambda *_: self.on_authorize_host_password(h))
            alert.pack_end(btn_auth, False, False, 0)
            self.detail_box.pack_start(alert, False, False, 0)

        # === 4. TAB CONTENT ===
        if self.active_tab_index == 0:
            self._render_overview_tab(h, m)
        elif self.active_tab_index == 1:
            self._render_network_tab(h, saved, host_fwds)
        else:
            self._render_workspace_tab(h)

        self.detail_box.show_all()

    def _render_overview_tab(self, h: dict, m: dict | None):
        if not m:
            ph = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            ph.get_style_context().add_class("nd-card")
            lbl = Gtk.Label(label=self.t("正在通过 SSH 采集实时系统与 GPU 指标…", "Probing live system & GPU metrics over SSH…"))
            lbl.get_style_context().add_class("nd-dim")
            lbl.set_xalign(0)
            ph.pack_start(lbl, False, False, 0)
            self.detail_box.pack_start(ph, False, False, 0)
            return

        if "error" in m:
            return

        # 3-Column KPI Grid (CPU / Memory / Disk)
        cpu_pct = float(m.get("CPU", "0") or 0)
        cores = m.get("CORES", "?")
        mem_used = int(m.get("MEM_USED_MB", "0") or 0)
        mem_tot = max(1, int(m.get("MEM_TOTAL_MB", "1") or 1))
        mem_frac = min(1.0, mem_used / mem_tot)
        disk_used = float(m.get("DISK_USED_GB", "0") or 0)
        disk_tot = max(0.1, float(m.get("DISK_TOTAL_GB", "1") or 1))
        disk_frac = min(1.0, disk_used / disk_tot)

        kpi_grid = Gtk.Grid()
        kpi_grid.set_column_homogeneous(True)
        kpi_grid.set_column_spacing(12)
        kpi_grid.attach(
            self._make_kpi_card(
                self.t("CPU 负载", "CPU"),
                f"{cpu_pct:.0f}%",
                f"{cores} cores",
                cpu_pct / 100.0,
                "nd-bar-cpu",
            ),
            0, 0, 1, 1,
        )
        kpi_grid.attach(
            self._make_kpi_card(
                self.t("内存", "Memory"),
                f"{mem_frac * 100:.0f}%",
                f"{mem_used / 1024:.1f} / {mem_tot / 1024:.1f} GiB",
                mem_frac,
                "nd-bar-mem",
            ),
            1, 0, 1, 1,
        )
        kpi_grid.attach(
            self._make_kpi_card(
                self.t("根磁盘 /", "Disk /"),
                f"{disk_frac * 100:.0f}%",
                f"{disk_used:.1f} / {disk_tot:.0f} GiB",
                disk_frac,
                "nd-bar-disk",
            ),
            2, 0, 1, 1,
        )
        self.detail_box.pack_start(kpi_grid, False, False, 0)

        # GPU Cards (1:1 macOS gpuSection)
        gpus = m.get("GPUS", [])
        if gpus:
            gpu_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            gpu_card.get_style_context().add_class("nd-card")
            g_hdr = Gtk.Label(label=f"GPU ({len(gpus)})")
            g_hdr.get_style_context().add_class("nd-section-title")
            g_hdr.set_xalign(0)
            gpu_card.pack_start(g_hdr, False, False, 0)

            for idx, g in enumerate(gpus):
                if len(g) < 6:
                    continue
                if idx > 0:
                    sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
                    sep.get_style_context().add_class("nd-divider")
                    gpu_card.pack_start(sep, False, False, 2)
                g_name, g_util, g_vused, g_vtot, g_temp, g_pwr = g[:6]
                is_amd = "amd" in g_name.lower() or "radeon" in g_name.lower()
                bar_cls = "nd-bar-gpu-amd" if is_amd else "nd-bar-gpu-nv"
                try:
                    u_frac = min(1.0, max(0.0, float(g_util) / 100.0))
                except ValueError:
                    u_frac = 0.0
                try:
                    vu, vt = float(g_vused), max(1.0, float(g_vtot))
                    v_frac = min(1.0, max(0.0, vu / vt))
                    v_txt = f"{vu / 1024:.1f} / {vt / 1024:.1f} GiB" if vt >= 1024 else f"{vu:.0f} / {vt:.0f} MiB"
                except ValueError:
                    v_frac, v_txt = 0.0, f"{g_vused}/{g_vtot} MiB"

                top_g = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
                lbl_gn = Gtk.Label()
                lbl_gn.set_markup(f"<b>{GLib.markup_escape_text(g_name)}</b>")
                lbl_gn.set_xalign(0)
                top_g.pack_start(lbl_gn, True, True, 0)
                top_g.pack_end(_make_badge(f"{g_pwr}W", "nd-badge-neutral"), False, False, 0)
                top_g.pack_end(_make_badge(f"{g_temp}°C", "nd-badge-gpu"), False, False, 0)
                gpu_card.pack_start(top_g, False, False, 0)

                # Core bar
                r1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
                l1 = Gtk.Label(label=self.t("核心占用", "Core"))
                l1.get_style_context().add_class("nd-kpi-sub")
                r1.pack_start(l1, False, False, 0)
                v1 = Gtk.Label(label=f"{g_util}%")
                v1.get_style_context().add_class("nd-mono")
                r1.pack_end(v1, False, False, 0)
                gpu_card.pack_start(r1, False, False, 0)

                pb_core = Gtk.ProgressBar()
                pb_core.set_fraction(u_frac)
                pb_core.get_style_context().add_class("nd-bar")
                pb_core.get_style_context().add_class(bar_cls)
                gpu_card.pack_start(pb_core, False, False, 0)

                # VRAM bar
                r2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
                l2 = Gtk.Label(label="VRAM")
                l2.get_style_context().add_class("nd-kpi-sub")
                r2.pack_start(l2, False, False, 0)
                v2 = Gtk.Label(label=v_txt)
                v2.get_style_context().add_class("nd-mono")
                v2.get_style_context().add_class("nd-kpi-sub")
                r2.pack_end(v2, False, False, 0)
                gpu_card.pack_start(r2, False, False, 0)

                pb_vram = Gtk.ProgressBar()
                pb_vram.set_fraction(v_frac)
                pb_vram.get_style_context().add_class("nd-bar")
                pb_vram.get_style_context().add_class("nd-bar-cpu")
                gpu_card.pack_start(pb_vram, False, False, 0)

            self.detail_box.pack_start(gpu_card, False, False, 0)

        # Top Processes Card
        procs = m.get("PROCS", [])
        if procs:
            p_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            p_card.get_style_context().add_class("nd-card")
            p_hdr = Gtk.Label(label=self.t("高负载进程", "Top Processes"))
            p_hdr.get_style_context().add_class("nd-section-title")
            p_hdr.set_xalign(0)
            p_card.pack_start(p_hdr, False, False, 0)

            for cmd, cpu, mem in procs:
                short_cmd = cmd.strip().split()[0].rsplit("/", 1)[-1] if cmd.strip() else cmd
                prow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
                clbl = Gtk.Label(label=short_cmd)
                clbl.get_style_context().add_class("nd-mono")
                clbl.set_xalign(0)
                clbl.set_ellipsize(3)
                clbl.set_tooltip_text(cmd)
                clbl.set_selectable(True)
                prow.pack_start(clbl, True, True, 0)

                rlbl = Gtk.Label()
                rlbl.set_markup(
                    f'<span foreground="#4bd6c3">CPU {GLib.markup_escape_text(cpu)}%</span>'
                    f'  <span foreground="#8b9bb0">MEM {GLib.markup_escape_text(mem)}%</span>'
                )
                rlbl.get_style_context().add_class("nd-mono")
                prow.pack_end(rlbl, False, False, 0)
                p_card.pack_start(prow, False, False, 0)
            self.detail_box.pack_start(p_card, False, False, 0)

        # System Info Card
        info_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        info_card.get_style_context().add_class("nd-card")
        i_hdr = Gtk.Label(label=self.t("系统信息", "System Information"))
        i_hdr.get_style_context().add_class("nd-section-title")
        i_hdr.set_xalign(0)
        info_card.pack_start(i_hdr, False, False, 0)

        for k_lbl, v_lbl in [
            (self.t("操作系统", "OS"), m.get("OS", "Linux")),
            (self.t("内核版本", "Kernel"), m.get("KERNEL", "--")),
            (self.t("处理器核心", "CPU Cores"), f"{cores} cores"),
            ("SSH RTT", f'{m.get("RTT_MS", "--")} ms'),
            (self.t("连接目标", "Target"), f'{h["user"]}@{h["hostname"]}:{h["port"]}'),
        ]:
            kv_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            kl = Gtk.Label(label=k_lbl)
            kl.get_style_context().add_class("nd-dim")
            kl.set_xalign(0)
            vl = Gtk.Label(label=str(v_lbl))
            vl.get_style_context().add_class("nd-mono")
            vl.set_xalign(1)
            vl.set_selectable(True)
            kv_row.pack_start(kl, False, False, 0)
            kv_row.pack_end(vl, True, True, 0)
            info_card.pack_start(kv_row, False, False, 0)
        self.detail_box.pack_start(info_card, False, False, 0)

    def _render_network_tab(self, h: dict, saved: dict | None, host_fwds: list):
        # 1. Remote Desktop Card with macOS-style Pill Selectors
        rd_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        rd_card.get_style_context().add_class("nd-card")

        hdr_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        lbl_rd = Gtk.Label(label=self.t("远程桌面串流 (Moonlight / Sunshine)", "Remote Desktop (Moonlight / Sunshine)"))
        lbl_rd.get_style_context().add_class("nd-section-title")
        lbl_rd.set_xalign(0)
        hdr_row.pack_start(lbl_rd, True, True, 0)
        if saved:
            hdr_row.pack_end(_make_badge(f'● {saved["address"]}:{saved["httpPort"]}', "nd-badge-online"), False, False, 0)
        else:
            hdr_row.pack_end(_make_badge(self.t("尚未配对", "Not Paired"), "nd-badge-neutral"), False, False, 0)
        rd_card.pack_start(hdr_row, False, False, 0)

        # Resolution pills
        res_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        rl = Gtk.Label(label=self.t("分辨率", "Resolution"))
        rl.get_style_context().add_class("nd-dim")
        rl.set_width_chars(10)
        rl.set_xalign(0)
        res_row.pack_start(rl, False, False, 0)
        for val, lbl in [("1920x1080", "1080p"), ("2560x1440", "1440p"), ("3840x2160", "4K")]:
            b = Gtk.Button(label=lbl)
            b.get_style_context().add_class("nd-pill-choice")
            if self.stream_resolution == val:
                b.get_style_context().add_class("nd-pill-selected")
            b.connect("clicked", lambda *_, v=val: self._set_stream_res(v))
            res_row.pack_start(b, False, False, 0)
        rd_card.pack_start(res_row, False, False, 0)

        # FPS pills + auto bitrate
        fps_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        fl = Gtk.Label(label=self.t("刷新率", "Refresh Rate"))
        fl.get_style_context().add_class("nd-dim")
        fl.set_width_chars(10)
        fl.set_xalign(0)
        fps_row.pack_start(fl, False, False, 0)
        for fps_val in ["60", "120", "144", "165"]:
            b = Gtk.Button(label=f"{fps_val}Hz")
            b.get_style_context().add_class("nd-pill-choice")
            if self.stream_fps == fps_val:
                b.get_style_context().add_class("nd-pill-selected")
            b.connect("clicked", lambda *_, v=fps_val: self._set_stream_fps(v))
            fps_row.pack_start(b, False, False, 0)
        auto_mbps = _recommended_bitrate_mbps(self.stream_resolution, self.stream_fps)
        lbl_mbps = _make_badge(self.t(f"自动码率 {auto_mbps} Mbps", f"Auto {auto_mbps} Mbps"), "nd-badge-remote")
        fps_row.pack_end(lbl_mbps, False, False, 0)
        rd_card.pack_start(fps_row, False, False, 0)

        # HW Decoder pills
        hw_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        hl = Gtk.Label(label=self.t("硬件解码", "HW Decode"))
        hl.get_style_context().add_class("nd-dim")
        hl.set_width_chars(10)
        hl.set_xalign(0)
        hw_row.pack_start(hl, False, False, 0)
        for val, lbl in [
            ("auto", self.t("自动", "Auto")),
            ("vaapi", "VAAPI"),
            ("cuda", "CUDA"),
            ("none", self.t("软解", "CPU")),
        ]:
            b = Gtk.Button(label=lbl)
            b.get_style_context().add_class("nd-pill-choice")
            if self.stream_hwaccel == val:
                b.get_style_context().add_class("nd-pill-selected")
            b.connect("clicked", lambda *_, v=val: self._set_stream_hw(v))
            hw_row.pack_start(b, False, False, 0)
        rd_card.pack_start(hw_row, False, False, 0)

        # Action row
        act_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        if saved:
            btn_go = Gtk.Button(label=self.t("▶ 启动远程桌面", "▶ Launch Remote Desktop"))
            btn_go.get_style_context().add_class("nd-btn-primary")
            btn_go.connect("clicked", lambda *_: self.launch_stream(saved))
            act_row.pack_start(btn_go, False, False, 0)

        btn_pair = Gtk.Button(
            label=self.t("账号一键激活配对", "Activate via Account")
            if load_account_session().get("token")
            else self.t("免 PIN 配对", "Zero-PIN Pair")
        )
        btn_pair.get_style_context().add_class("nd-btn-secondary" if saved else "nd-btn-primary")
        btn_pair.connect("clicked", lambda *_: self.on_pair_sunshine(h))
        act_row.pack_start(btn_pair, False, False, 0)

        btn_profile = Gtk.Button(label=self.t("多用户隔离配置", "Host Isolation Profile"))
        btn_profile.get_style_context().add_class("nd-btn-secondary")
        btn_profile.connect("clicked", lambda *_: self.on_edit_host_profile(h))
        act_row.pack_start(btn_profile, False, False, 0)
        rd_card.pack_start(act_row, False, False, 2)
        self.detail_box.pack_start(rd_card, False, False, 0)

        # 2. SSH Port Forwarding Card
        pf_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        pf_card.get_style_context().add_class("nd-card")

        pf_hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        lbl_pf = Gtk.Label(label=self.t("SSH 端口转发 (-L / -R / -D)", "SSH Port Forwarding (-L / -R / -D)"))
        lbl_pf.get_style_context().add_class("nd-section-title")
        lbl_pf.set_xalign(0)
        pf_hdr.pack_start(lbl_pf, True, True, 0)

        btn_add_pf = Gtk.Button(label=self.t("+ 新建转发", "+ Add Forward"))
        btn_add_pf.get_style_context().add_class("nd-btn-secondary")
        btn_add_pf.connect("clicked", lambda *_: self.on_add_forward(h))
        pf_hdr.pack_end(btn_add_pf, False, False, 0)
        pf_card.pack_start(pf_hdr, False, False, 0)

        if not host_fwds:
            empty_pf = Gtk.Label(label=self.t("暂无端口转发规则，可一键映射 Jupyter / TensorBoard / WebUI 或本地 SOCKS5 代理。", "No port forwards yet. Map Jupyter / TensorBoard / WebUI or a local SOCKS5 proxy."))
            empty_pf.get_style_context().add_class("nd-dim")
            empty_pf.set_xalign(0)
            empty_pf.set_line_wrap(True)
            pf_card.pack_start(empty_pf, False, False, 0)
        else:
            for fwd in host_fwds:
                row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
                row.get_style_context().add_class("nd-card-compact")
                fid = fwd["id"]
                running = fid in self.forward_procs and self.forward_procs[fid].poll() is None
                row.pack_start(_make_badge(fwd["flag"], "nd-badge-lan"), False, False, 0)
                lbl = Gtk.Label()
                lbl.set_markup(f'<b>{GLib.markup_escape_text(fwd["label"])}</b>  <span foreground="#8b9bb0">{GLib.markup_escape_text(fwd["spec"])}</span>')
                lbl.get_style_context().add_class("nd-mono")
                lbl.set_xalign(0)
                lbl.set_ellipsize(3)
                row.pack_start(lbl, True, True, 0)
                row.pack_start(
                    _make_badge(
                        self.t("运行中", "Active") if running else self.t("已停止", "Stopped"),
                        "nd-badge-online" if running else "nd-badge-neutral",
                    ),
                    False, False, 0,
                )
                btn_toggle = Gtk.Button(label=self.t("停止", "Stop") if running else self.t("启动", "Start"))
                btn_toggle.get_style_context().add_class("nd-btn-secondary" if running else "nd-btn-primary")
                btn_toggle.connect("clicked", lambda *_, f=fwd: self.toggle_forward(f))
                row.pack_start(btn_toggle, False, False, 0)
                btn_rm = Gtk.Button(label=self.t("移除", "Remove"))
                btn_rm.get_style_context().add_class("nd-btn-danger")
                btn_rm.connect("clicked", lambda *_, f=fwd: self.remove_forward(f))
                row.pack_start(btn_rm, False, False, 0)
                pf_card.pack_start(row, False, False, 0)

        self.detail_box.pack_start(pf_card, False, False, 0)

    def _render_workspace_tab(self, h: dict):
        alias = h["alias"]
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        card.get_style_context().add_class("nd-card")

        hdr = Gtk.Label(label=self.t("快捷工作区与节点管理", "Quick Workspace & Host Actions"))
        hdr.get_style_context().add_class("nd-section-title")
        hdr.set_xalign(0)
        card.pack_start(hdr, False, False, 0)

        row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        b_copy = Gtk.Button(label=self.t("复制 SSH 命令", "Copy SSH Command"))
        b_copy.get_style_context().add_class("nd-btn-secondary")
        b_copy.connect("clicked", lambda *_: (
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(f"ssh {alias}", -1),
            self.status_label.set_text(self.t(f"已复制: ssh {alias}", f"Copied: ssh {alias}")),
        ))
        row1.pack_start(b_copy, False, False, 0)

        b_auth = Gtk.Button(label=self.t("🔑 输入密码配置免密公钥", "🔑 Authorize SSH Key"))
        b_auth.get_style_context().add_class("nd-btn-secondary")
        b_auth.connect("clicked", lambda *_: self.on_authorize_host_password(h))
        row1.pack_start(b_auth, False, False, 0)

        b_pin = Gtk.Button(label=self.t("取消置顶", "Unpin") if alias in self.pinned_aliases else self.t("置顶节点", "Pin Host"))
        b_pin.get_style_context().add_class("nd-btn-secondary")
        b_pin.connect("clicked", lambda *_: self.toggle_pin_host(alias))
        row1.pack_start(b_pin, False, False, 0)
        card.pack_start(row1, False, False, 0)

        sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        sep.get_style_context().add_class("nd-divider")
        card.pack_start(sep, False, False, 2)

        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        b_edit = Gtk.Button(label=self.t("编辑 SSH 配置", "Edit SSH Config"))
        b_edit.get_style_context().add_class("nd-btn-secondary")
        b_edit.connect("clicked", lambda *_: self.on_edit_device(h))
        row2.pack_start(b_edit, False, False, 0)

        b_del = Gtk.Button(label=self.t("删除此设备", "Delete Host"))
        b_del.get_style_context().add_class("nd-btn-danger")
        b_del.connect("clicked", lambda *_: self.confirm_and_delete_host(h))
        row2.pack_end(b_del, False, False, 0)
        card.pack_start(row2, False, False, 0)

        self.detail_box.pack_start(card, False, False, 0)

    def _set_stream_res(self, val: str):
        self.stream_resolution = val
        self.settings["stream_resolution"] = val
        save_json(SETTINGS_FILE, self.settings)
        self.render_detail()

    def _set_stream_fps(self, val: str):
        self.stream_fps = val
        self.settings["stream_fps"] = val
        save_json(SETTINGS_FILE, self.settings)
        self.render_detail()

    def _set_stream_hw(self, val: str):
        self.stream_hwaccel = val
        self.render_detail()

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
        acct = load_account_session()
        if acct.get("token"):
            # Mode A: Zero-SSH, Zero-Sudo account-authenticated activation & certificate pairing
            self.status_label.set_text(
                self.t(f"正在通过账号激活并配对 {host['alias']}（免 SSH / 免 sudo）…", f"Activating & pairing {host['alias']} via account…")
            )
            threading.Thread(target=self._account_activate_worker, args=(host,), daemon=True).start()
            return

        dlg = Gtk.Dialog(title=self.t(f'免 PIN SSH 配对 ({host["alias"]})', f'Zero-PIN SSH Pair ({host["alias"]})'), transient_for=self, flags=0)
        dlg.add_buttons(self.t("取消", "Cancel"), Gtk.ResponseType.CANCEL, self.t("开始配对", "Pair"), Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        box.set_margin_top(12)
        box.set_margin_bottom(12)
        box.set_margin_start(14)
        box.set_margin_end(14)
        e_addr = Gtk.Entry(text=host["hostname"])
        e_port = Gtk.Entry(text="47989")
        for lbl_txt, widget in [
            (self.t("宿主机地址:", "Host Address:"), e_addr),
            (self.t("HTTP 端口:", "HTTP Port:"), e_port),
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
            self.status_label.set_text(self.t(f"正在配对 {addr}:{port}…", f"Pairing with {addr}:{port}..."))
            threading.Thread(target=self._pair_worker, args=(host["alias"], addr, port), daemon=True).start()
        dlg.destroy()

    def _account_activate_worker(self, host: dict):
        try:
            acct = load_account_session()
            token = str(acct.get("token") or "").strip()
            server_url = str(acct.get("server_url") or DEFAULT_CONTROL_SERVER).rstrip("/")
            if not token:
                raise RuntimeError("Not signed in")
            upload_linux_client_cert(acct)
            payload = json.dumps({
                "target_name": host["alias"],
                "target_ip": host["hostname"],
                "action": "activate_host",
            }).encode("utf-8")
            req = urllib.request.Request(
                f"{server_url}/api/v1/devices/activate",
                data=payload,
                headers={"Content-Type": "application/json; charset=utf-8", "Authorization": f"Bearer {token}"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                act = json.loads(resp.read().decode("utf-8"))
            cmd_id = act.get("command_id")
            target_dev = act.get("target_device") or {}
            http_port = int(target_dev.get("sunshine_http_port") or 47989)
            https_port = int(target_dev.get("sunshine_https_port") or max(1, http_port - 5))
            addr = str(target_dev.get("virtual_ip") or host["hostname"])

            # Poll command completion up to 16s
            for _ in range(16):
                time.sleep(1.0)
                st_req = urllib.request.Request(
                    f"{server_url}/api/v1/commands/{cmd_id}",
                    headers={"Authorization": f"Bearer {token}"},
                    method="GET",
                )
                with urllib.request.urlopen(st_req, timeout=8) as r2:
                    st = json.loads(r2.read().decode("utf-8"))
                if st.get("status") == "done":
                    res_obj = st.get("result") or {}
                    http_port = int(res_obj.get("sunshine_http_port") or http_port)
                    https_port = int(res_obj.get("sunshine_https_port") or max(1, http_port - 5))
                    break
                if st.get("status") == "failed":
                    err = (st.get("result") or {}).get("error") or "Activation failed on target device"
                    raise RuntimeError(err)

            self.sunshine_hosts[host["alias"]] = {
                "hostAlias": host["alias"],
                "address": addr,
                "httpPort": http_port,
                "httpsPort": https_port,
                "serverName": host["alias"],
                "isPaired": True,
            }
            save_json(SUNSHINE_FILE, self.sunshine_hosts)
            GLib.idle_add(
                self.status_label.set_text,
                self.t(f"账号激活配对完成：{host['alias']} ({addr}:{http_port})", f"Account activation & pairing ready: {host['alias']} ({addr}:{http_port})"),
            )
            GLib.idle_add(self.reload_hosts)
        except Exception as exc:
            GLib.idle_add(self.status_label.set_text, self.t(f"账号激活失败: {exc}", f"Account activation failed: {exc}"))

    def _pair_worker(self, alias, addr, port):
        try:
            cert, _, uid = ensure_client_cert()
            cert_b64 = base64.b64encode(cert.read_bytes()).decode()
            remote_py = f"""
import base64, json, os, re, subprocess, sys, uuid
cert_pem = base64.b64decode("{cert_b64}").decode("utf-8")
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

    def _show_stream_error(self, msg: str):
        self.status_label.set_text(f"Stream error: {msg}")
        dlg = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text=self.t("远程桌面连接失败", "Remote Desktop Failed"),
        )
        dlg.format_secondary_text(msg)
        dlg.run()
        dlg.destroy()

    def _launch_stream_worker(self, saved):
        try:
            cert, key, uid = ensure_client_cert()
            ctx = ssl._create_unverified_context()
            ctx.maximum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_cert_chain(certfile=str(cert), keyfile=str(key))
            addr, http_port, https_port = saved["address"], int(saved["httpPort"]), int(saved["httpsPort"])
            w_str, h_str = self.stream_resolution.split("x")
            fps_str = self.stream_fps
            mode_str = f"{w_str}x{h_str}x{fps_str}"
            pixel_ratio = (max(640, int(w_str)) * max(360, int(h_str))) / (1920.0 * 1080.0)
            fps_ratio = max(30, int(fps_str)) / 60.0
            raw_bitrate = 20000.0 * (pixel_ratio ** 0.72) * (fps_ratio ** 0.75)
            bitrate_kbps = max(20000, min(120000, int(round(raw_bitrate / 5000.0)) * 5000))

            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=ctx),
            )

            info_xml = opener.open(f"http://{addr}:{http_port}/serverinfo?uniqueid={uid}", timeout=8).read()
            info = ET.fromstring(info_xml)
            appver = info.findtext("appversion") or "7.1.431.0"
            gfever = info.findtext("GfeVersion") or "3.23.0.74"
            codec_support = info.findtext("ServerCodecModeSupport") or "0"
            current_game = (info.findtext("currentgame") or "0").strip()
            server_state = (info.findtext("state") or "").upper()

            apps_xml = opener.open(f"https://{addr}:{https_port}/applist?uniqueid={uid}", timeout=8).read()
            apps_root = ET.fromstring(apps_xml)
            if apps_root.attrib.get("status_code", "200") != "200":
                raise RuntimeError(apps_root.attrib.get("status_message") or "Client certificate not paired on host")
            apps = apps_root.findall("App")
            if not apps:
                raise RuntimeError("No applications published on remote Sunshine host")
            app_id = next((a.findtext("ID") for a in apps if "desktop" in (a.findtext("AppTitle") or "").lower()), apps[0].findtext("ID"))

            rikey = secrets.token_hex(16)
            rikeyid = str(random.randint(1, 2147483647))
            q = urllib.parse.urlencode({
                "uniqueid": uid, "appid": app_id, "mode": mode_str,
                "additionalStates": "1", "sops": "0", "rikey": rikey, "rikeyid": rikeyid,
                "localAudioPlayMode": "0", "surroundAudioInfo": "196610",
            })

            def call_session(ep: str):
                raw = opener.open(f"https://{addr}:{https_port}/{ep}?{q}", timeout=15).read()
                root = ET.fromstring(raw)
                return root.attrib.get("status_code", "200"), root.attrib.get("status_message", ""), (root.findtext("sessionUrl0") or "").strip()

            primary_ep = "resume" if (current_game != "0" or "BUSY" in server_state) else "launch"
            sc, sm, rtsp = call_session(primary_ep)
            if sc != "200" or not rtsp:
                # If resume failed or another stale session blocked launch, try cancel + launch once
                try:
                    opener.open(f"https://{addr}:{https_port}/cancel?uniqueid={uid}", timeout=6).read()
                except Exception:
                    pass
                sc, sm, rtsp = call_session("launch")
            if sc != "200" or not rtsp:
                raise RuntimeError(f"Sunshine HTTP {sc}: {sm or 'Failed to start streaming session'}")

            stream_bin = resolve_stream_bin()
            live_peers = fetch_easytier_peer_transports()
            host_alias = str(saved.get("hostAlias") or saved.get("serverName") or "")
            matched_route = match_easytier_transport(live_peers or self.mesh_transports, addr, host_alias)
            route_badge = matched_route["badge"] if matched_route else ("LAN Direct" if _is_lan_or_mesh_host(addr) else "WAN Direct")
            CONF_DIR.mkdir(parents=True, exist_ok=True)
            log_path = CONF_DIR / "stream-last.log"
            log_fh = open(log_path, "w", encoding="utf-8")
            proc = subprocess.Popen(
                [
                    stream_bin, "--host", addr, "--appver", appver, "--gfever", gfever,
                    "--rtsp", rtsp, "--rikey", rikey, "--rikeyid", rikeyid,
                    "--width", w_str, "--height", h_str, "--fps", fps_str,
                    "--bitrate", str(bitrate_kbps),
                    "--codec-support", codec_support,
                    "--hwaccel", self.stream_hwaccel,
                    "--route", route_badge,
                ],
                stdout=log_fh,
                stderr=log_fh,
            )
            log_fh.close()
            GLib.idle_add(self.status_label.set_text, f"Streaming {addr} [{route_badge}] ({mode_str}, {bitrate_kbps // 1000} Mbps, hwaccel={self.stream_hwaccel})")

            # Watch for immediate crash/exit without blocking long-running streams on a pipe buffer
            time.sleep(2.5)
            rc = proc.poll()
            if rc is not None and rc != 0:
                detail = ""
                try:
                    detail = log_path.read_text(encoding="utf-8", errors="ignore").strip()
                except Exception:
                    pass
                GLib.idle_add(self._show_stream_error, (detail[-400:] if detail else f"nodedeck-stream exited with code {rc}"))
        except Exception as exc:
            GLib.idle_add(self._show_stream_error, str(exc))


if __name__ == "__main__":
    win = NodeDeckWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
