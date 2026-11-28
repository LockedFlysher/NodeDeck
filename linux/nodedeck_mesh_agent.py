#!/usr/bin/env python3
"""
NodeDeck Unified Account & Built-in EasyTier Mesh Agent for Linux.

Supports both headless GPU hosts (role=host/both) and desktop clients (role=controller/both):
- Invite-gated registration & login against the NodeDeck Control Plane
- Sticky virtual IPv4 assignment & isolated per-user EasyTier P2P mesh
- Dynamic LAN IP discovery & mapped_listeners refresh (mirrors desktop runner)
- Automatic Moonlight public client-certificate sync into local nodedeck-host/sunshine
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import pwd
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

DEFAULT_SERVER_URL = "https://lockedflysher.duckdns.org:8443/nodedeck-api"


def default_state_dir() -> Path:
    env_dir = os.environ.get("NODEDECK_MESH_DIR")
    if env_dir:
        return Path(env_dir)
    if os.geteuid() == 0:
        return Path("/etc/nodedeck")
    return Path.home() / ".config/nodedeck"


def session_path(state_dir: Path) -> Path:
    return state_dir / "account.json"


def runtime_toml_path(state_dir: Path) -> Path:
    return state_dir / "easytier-runtime.toml"


def load_session(state_dir: Path) -> dict[str, Any] | None:
    p = session_path(state_dir)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def save_session(state_dir: Path, data: dict[str, Any]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    p = session_path(state_dir)
    old_umask = os.umask(0o077)
    try:
        p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        os.chmod(p, 0o600)
    finally:
        os.umask(old_umask)


def find_easytier_binary() -> str:
    candidates = [
        "/opt/nodedeck/easytier/easytier-core",
        str(Path.home() / ".local/share/nodedeck/easytier/easytier-core"),
        "/usr/local/bin/easytier-core",
        shutil.which("easytier-core") or "",
    ]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise FileNotFoundError("easytier-core binary not found")


def discover_lan_ips(mesh_ipv4: str = "") -> list[str]:
    ip_only = mesh_ipv4.split("/")[0]
    parts = ip_only.split(".")
    mesh_prefix = f"{parts[0]}.{parts[1]}.{parts[2]}." if len(parts) == 4 else ""
    skip_prefixes = ("lo", "et", "tun", "utun", "wg", "tailscale", "docker", "br-", "veth", "virbr")

    res = subprocess.run(
        ["/usr/sbin/ip", "-o", "-4", "addr", "show", "up", "scope", "global"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        res = subprocess.run(
            ["ip", "-o", "-4", "addr", "show", "up", "scope", "global"],
            capture_output=True,
            text=True,
        )
    ips: set[str] = set()
    for line in res.stdout.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        ifname = cols[1]
        if ifname.startswith(skip_prefixes):
            continue
        ip = cols[3].split("/")[0]
        if ip.startswith("127.") or ip.startswith("169.254."):
            continue
        if mesh_prefix and ip.startswith(mesh_prefix):
            continue
        ips.add(ip)
    return sorted(ips)


def detect_sunshine_config(target_user: str) -> tuple[bool, int, int, Path | None, Path | None]:
    """Detect local nodedeck-host / sunshine port, config dir, and exact file_state path."""
    try:
        home = Path(pwd.getpwnam(target_user).pw_dir)
    except KeyError:
        home = Path.home()

    candidates = [
        (home / ".config/nodedeck", "host.conf"),
        (home / ".config/nodedeck/host", "host.conf"),
        (home / ".config/sunshine", "sunshine.conf"),
    ]
    for conf_dir, conf_name in candidates:
        conf_file = conf_dir / conf_name
        if conf_file.exists():
            txt = conf_file.read_text(encoding="utf-8", errors="ignore")
            m_port = re.search(r"^\s*port\s*=\s*(\d+)", txt, re.M)
            http_port = int(m_port.group(1)) if m_port else 47989
            https_port = max(1, http_port - 5)
            m_state = re.search(r"^\s*file_state\s*=\s*(.+)$", txt, re.M)
            if m_state:
                raw_state = m_state.group(1).strip().replace("$HOME", str(home))
                state_path = Path(raw_state)
                if not state_path.is_absolute():
                    state_path = conf_dir / state_path
            else:
                state_path = conf_dir / ("host_state.json" if conf_name == "host.conf" else "sunshine_state.json")
            return True, http_port, https_port, conf_dir, state_path
    return False, 47989, 47984, None, None


def ensure_default_sunshine_config(target_user: str) -> tuple[bool, int, int, Path | None, Path | None]:
    """Ensure a brand-new Linux host initializes default nodedeck-host config on account sign-in (zero sudo)."""
    enabled, hp, hsp, conf_dir, state_path = detect_sunshine_config(target_user)
    if enabled:
        return enabled, hp, hsp, conf_dir, state_path
    host_bin = Path("/opt/nodedeck/host/bin/nodedeck-host")
    if not host_bin.is_file():
        return False, 47989, 47984, None, None
    try:
        pw = pwd.getpwnam(target_user)
        home, uid, gid = Path(pw.pw_dir), pw.pw_uid, pw.pw_gid
    except KeyError:
        home, uid, gid = Path.home(), -1, -1

    cfg_dir = home / ".config/nodedeck"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    apps_file = cfg_dir / "apps.json"
    conf_file = cfg_dir / "host.conf"
    state_file = cfg_dir / "host_state.json"
    if not apps_file.exists():
        apps_file.write_text('{\n  "env": {},\n  "apps": [{ "name": "Desktop", "image-path": "desktop.png" }]\n}\n', encoding="utf-8")
    if not conf_file.exists():
        conf_file.write_text(
            f"port = 47989\n"
            f"file_apps = {apps_file}\n"
            f"file_state = {state_file}\n"
            f"credentials_file = {cfg_dir / 'credentials.json'}\n"
            f"pkey = {cfg_dir / 'host.key'}\n"
            f"cert = {cfg_dir / 'host.cert'}\n",
            encoding="utf-8",
        )
    if os.geteuid() == 0 and uid >= 0:
        for p in (cfg_dir, apps_file, conf_file):
            try:
                os.chown(p, uid, gid)
            except Exception:
                pass
    return True, 47989, 47984, cfg_dir, state_file


def sync_client_certs_to_sunshine(target_user: str, client_certs: list[dict[str, Any]]) -> bool:
    """
    Injects all authenticated account clients' public Moonlight X.509 certificates into
    sunshine_state.json. Reloads nodedeck-host/sunshine ONLY when new certs are added.
    """
    if not client_certs:
        return False
    enabled, _, _, conf_dir, state_path = detect_sunshine_config(target_user)
    if not enabled or conf_dir is None or state_path is None:
        return False

    state: dict[str, Any] = {}
    if state_path.exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except Exception:
            state = {}

    root = state.setdefault("root", {})
    if not root.get("uniqueid"):
        root["uniqueid"] = str(uuid.uuid4()).upper()
    devices: list[dict[str, Any]] = root.setdefault("named_devices", [])
    existing_certs = {str(d.get("cert", "")).strip() for d in devices}

    changed = False
    for c in client_certs:
        cert_pem = str(c.get("cert_pem", "")).strip()
        if "BEGIN CERTIFICATE" not in cert_pem:
            continue
        if cert_pem in existing_certs:
            continue
        dev_name = str(c.get("device_name") or "NodeDeck-Client")
        uid = str(c.get("unique_id") or secrets.token_hex(8))
        devices = [d for d in devices if d.get("name") != dev_name]
        devices.append({
            "name": dev_name,
            "uuid": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"nodedeck-cp-{uid}")).upper(),
            "cert": cert_pem + "\n",
        })
        existing_certs.add(cert_pem)
        changed = True

    if not changed:
        return False

    root["named_devices"] = devices
    state_path.write_text(json.dumps(state, indent=2), encoding="utf-8")

    try:
        pw = pwd.getpwnam(target_user)
        os.chown(state_path, pw.pw_uid, pw.pw_gid)
    except Exception:
        pass

    # Reload user's sunshine/nodedeck-host service gently
    reload_user_sunshine(target_user)
    return True


def ensure_local_ssh_pubkey(target_user: str) -> str:
    """Ensure target_user has an Ed25519 SSH keypair (generating one if absent) and return its public key."""
    try:
        pw = pwd.getpwnam(target_user)
        home = Path(pw.pw_dir)
        uid, gid = pw.pw_uid, pw.pw_gid
    except KeyError:
        home = Path.home()
        uid = gid = -1

    ssh_dir = home / ".ssh"
    ssh_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh_dir, 0o700)
    if os.geteuid() == 0 and uid >= 0:
        os.chown(ssh_dir, uid, gid)

    for cand in ("id_ed25519.pub", "id_rsa.pub"):
        p = ssh_dir / cand
        if p.exists():
            txt = p.read_text(encoding="utf-8", errors="ignore").strip()
            if txt.startswith(("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-")):
                return txt

    key_path = ssh_dir / "id_ed25519"
    pub_path = ssh_dir / "id_ed25519.pub"
    if not key_path.exists():
        comment = f"nodedeck@{socket.gethostname()}"
        cmd = ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path), "-C", comment, "-q"]
        if os.geteuid() == 0 and uid > 0:
            subprocess.run(["runuser", "-u", target_user, "--"] + cmd, check=False)
        else:
            subprocess.run(cmd, check=False)
    if os.geteuid() == 0 and uid >= 0:
        for f in (key_path, pub_path):
            if f.exists():
                os.chown(f, uid, gid)
    if key_path.exists():
        os.chmod(key_path, 0o600)
    if pub_path.exists():
        os.chmod(pub_path, 0o644)
        return pub_path.read_text(encoding="utf-8", errors="ignore").strip()
    return ""


def sync_ssh_keys_to_authorized_keys(target_user: str, ssh_public_keys: list[dict[str, Any]]) -> bool:
    """Append authenticated same-account devices' SSH public keys into ~target_user/.ssh/authorized_keys."""
    if not ssh_public_keys:
        return False
    try:
        pw = pwd.getpwnam(target_user)
        home = Path(pw.pw_dir)
        uid, gid = pw.pw_uid, pw.pw_gid
    except KeyError:
        home = Path.home()
        uid = gid = -1

    ssh_dir = home / ".ssh"
    ssh_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh_dir, 0o700)
    auth_file = ssh_dir / "authorized_keys"
    existing_lines = auth_file.read_text(encoding="utf-8", errors="ignore").splitlines() if auth_file.exists() else []
    # Deduplicate by (key_type, key_blob)
    existing_blobs = set()
    for ln in existing_lines:
        parts = ln.strip().split()
        if len(parts) >= 2:
            existing_blobs.add((parts[0], parts[1]))

    added = False
    for item in ssh_public_keys:
        pub = str(item.get("public_key") or "").strip()
        if not pub or "\n" in pub or "\r" in pub:
            continue
        parts = pub.split()
        if len(parts) < 2 or not parts[0].startswith(("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-")):
            continue
        blob = (parts[0], parts[1])
        if blob in existing_blobs:
            continue
        dev_name = re.sub(r"[^A-Za-z0-9._-]", "_", str(item.get("device_name") or "device"))
        existing_lines.append(f"{parts[0]} {parts[1]} nodedeck-{dev_name}")
        existing_blobs.add(blob)
        added = True

    if not added:
        return False
    auth_file.write_text("\n".join(existing_lines).rstrip() + "\n", encoding="utf-8")
    os.chmod(auth_file, 0o600)
    if os.geteuid() == 0 and uid >= 0:
        os.chown(ssh_dir, uid, gid)
        os.chown(auth_file, uid, gid)
    return True


def register_local_ssh_pubkey(server_url: str, token: str, device_name: str, target_user: str) -> None:
    pub = ensure_local_ssh_pubkey(target_user)
    if not pub:
        return
    try:
        api_request(
            server_url,
            "POST",
            "/api/v1/ssh-keys/register",
            payload={"device_name": device_name, "public_key": pub},
            token=token,
        )
    except Exception as exc:
        print(f"[nodedeck-mesh] ssh-key register warning: {exc}", flush=True)


def reload_user_sunshine(target_user: str, start_if_stopped: bool = False) -> bool:
    try:
        uid = pwd.getpwnam(target_user).pw_uid
    except KeyError:
        uid = os.getuid()

    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = f"/run/user/{uid}"
    env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{uid}/bus"

    def _run_systemctl(*sc_args: str) -> subprocess.CompletedProcess:
        if os.geteuid() == 0 and uid != 0:
            return subprocess.run(
                ["runuser", "-u", target_user, "--", "env",
                 f"XDG_RUNTIME_DIR=/run/user/{uid}",
                 f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus",
                 "systemctl", "--user", *sc_args],
                capture_output=True,
            )
        return subprocess.run(["systemctl", "--user", *sc_args], env=env, capture_output=True)

    for svc in ("nodedeck-host", "foundation-sunshine", "sunshine"):
        if _run_systemctl("is-active", "--quiet", svc).returncode == 0:
            _run_systemctl("restart", svc)
            return True

    if start_if_stopped:
        # Try systemd --user nodedeck-host.service first
        _run_systemctl("daemon-reload")
        if _run_systemctl("enable", "--now", "nodedeck-host.service").returncode == 0:
            time.sleep(1.5)
            if _run_systemctl("is-active", "--quiet", "nodedeck-host.service").returncode == 0:
                return True
        # Fallback: start bundled nodedeck-host directly in user space with desktop DISPLAY
        host_bin = Path("/opt/nodedeck/host/bin/nodedeck-host")
        enabled, _, _, conf_dir, _ = ensure_default_sunshine_config(target_user)
        if enabled and conf_dir is not None and host_bin.is_file():
            conf_file = conf_dir / "host.conf"
            if conf_file.exists():
                subprocess.run(["pkill", "-x", "nodedeck-host"], capture_output=True)
                log_path = conf_dir / "nodedeck-host.log"
                run_env = env.copy()
                run_env.setdefault("DISPLAY", ":0")
                try:
                    with open(log_path, "ab") as logf:
                        subprocess.Popen(
                            [str(host_bin), str(conf_file)],
                            cwd=str(conf_dir),
                            env=run_env,
                            stdout=logf,
                            stderr=logf,
                            stdin=subprocess.DEVNULL,
                            start_new_session=True,
                        )
                    return True
                except Exception:
                    pass
    return False


def ensure_user_mesh_daemon_running(state_dir: Path) -> None:
    """Start user-space nodedeck-mesh daemon without sudo (uses cap_net_admin on easytier-core)."""
    if os.geteuid() == 0:
        return
    # Skip if system-level nodedeck-mesh.service is already active and sharing /etc/nodedeck
    if subprocess.run(["systemctl", "is-active", "--quiet", "nodedeck-mesh.service"], capture_output=True).returncode == 0:
        return
    uid = os.getuid()
    env = os.environ.copy()
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{uid}/bus")
    if subprocess.run(["systemctl", "--user", "enable", "--now", "nodedeck-mesh.service"], env=env, capture_output=True).returncode == 0:
        return
    # Fallback: launch detached user-space daemon directly if not already running
    chk = subprocess.run(["pgrep", "-u", str(uid), "-f", "nodedeck_mesh_agent.py daemon"], capture_output=True)
    if chk.returncode != 0:
        log_path = state_dir / "mesh-daemon.log"
        try:
            with open(log_path, "ab") as logf:
                subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()), "--state-dir", str(state_dir), "daemon"],
                    stdout=logf,
                    stderr=logf,
                    stdin=subprocess.DEVNULL,
                    start_new_session=True,
                )
        except Exception:
            pass


def process_pending_commands(
    server_url: str,
    token: str,
    target_user: str,
    client_certs: list[dict[str, Any]],
    pending_commands: list[dict[str, Any]],
) -> None:
    """Execute account-authorized remote activation/cert-sync commands (zero SSH, zero sudo)."""
    for cmd in pending_commands:
        cmd_id = cmd.get("id")
        action = str(cmd.get("action") or "")
        if not cmd_id or action not in ("activate_host", "sync_certs"):
            continue
        try:
            enabled, http_port, https_port, _, _ = ensure_default_sunshine_config(target_user)
            if not enabled:
                api_request(
                    server_url,
                    "POST",
                    f"/api/v1/commands/{cmd_id}/ack",
                    payload={"status": "failed", "result": {"error": "nodedeck-host binary not installed on this device"}},
                    token=token,
                )
                continue
            reloaded = sync_client_certs_to_sunshine(target_user, client_certs) if client_certs else False
            if action == "activate_host":
                running = subprocess.run(["pgrep", "-x", "nodedeck-host"], capture_output=True).returncode == 0
                if not running or not reloaded:
                    reload_user_sunshine(target_user, start_if_stopped=True)
            api_request(
                server_url,
                "POST",
                f"/api/v1/commands/{cmd_id}/ack",
                payload={
                    "status": "done",
                    "result": {
                        "sunshine_enabled": True,
                        "sunshine_http_port": http_port,
                        "sunshine_https_port": https_port,
                    },
                },
                token=token,
            )
            print(f"[nodedeck-mesh] Executed account command #{cmd_id} ({action}) -> port {http_port}", flush=True)
        except Exception as exc:
            try:
                api_request(
                    server_url,
                    "POST",
                    f"/api/v1/commands/{cmd_id}/ack",
                    payload={"status": "failed", "result": {"error": str(exc)}},
                    token=token,
                )
            except Exception:
                pass


def api_request(
    server_url: str,
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    token: str | None = None,
    timeout: int = 12,
) -> dict[str, Any]:
    url = server_url.rstrip("/") + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json; charset=utf-8"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="ignore")
        try:
            msg = json.loads(raw).get("error") or raw
        except Exception:
            msg = raw or str(err)
        raise RuntimeError(f"HTTP {err.code}: {msg}") from err


def expand_seed_uris(raw_seed: str) -> list[str]:
    """Ensure UDP relay is preferred before TCP fallback when hole-punching fails."""
    tokens = [tok.strip() for tok in re.split(r"[\s,]+", raw_seed or "") if tok.strip()]
    ordered: list[str] = []
    for uri in tokens:
        if uri.startswith("tcp://"):
            udp_uri = "udp://" + uri[len("tcp://"):]
            if udp_uri not in ordered:
                ordered.append(udp_uri)
            if uri not in ordered:
                ordered.append(uri)
        elif uri.startswith("udp://"):
            if uri not in ordered:
                ordered.append(uri)
            tcp_uri = "tcp://" + uri[len("udp://"):]
            if tcp_uri not in ordered:
                ordered.append(tcp_uri)
        else:
            if uri not in ordered:
                ordered.append(uri)
    return ordered


def write_runtime_toml(toml_file: Path, session: dict[str, Any], lan_ips: list[str]) -> None:
    mesh = session["mesh"]
    dev = session["device"]
    port = int(mesh.get("listen_port") or 28443)
    mapped = [f'"udp://{ip}:{port}"' for ip in lan_ips]
    peer_blocks = "\n".join(
        f'[[peer]]\nuri = "{u}"\n'
        for u in expand_seed_uris(str(mesh.get("seed_uri") or ""))
    )
    toml_text = (
        f'hostname = "{dev["device_name"]}"\n'
        f'ipv4 = "{dev["virtual_cidr"]}"\n'
        f'listeners = ["udp://0.0.0.0:{port}", "tcp://0.0.0.0:{port}"]\n'
        f'mapped_listeners = [{", ".join(mapped)}]\n'
        f"\n"
        f"[network_identity]\n"
        f'network_name = "{mesh["network_name"]}"\n'
        f'network_secret = "{mesh["network_secret"]}"\n'
        f"\n"
        f"{peer_blocks}\n"
        f"[flags]\n"
        f'default_protocol = "udp"\n'
        f"multi_thread = true\n"
        f"latency_first = true\n"
        f'dev_name = "et-nodedeck"\n'
    )
    old_umask = os.umask(0o077)
    try:
        toml_file.parent.mkdir(parents=True, exist_ok=True)
        toml_file.write_text(toml_text, encoding="utf-8")
        os.chmod(toml_file, 0o600)
    finally:
        os.umask(old_umask)


def stop_proc(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    deadline = time.time() + 3.0
    while proc.poll() is None and time.time() < deadline:
        time.sleep(0.1)
    if proc.poll() is None:
        proc.kill()
        proc.wait()


def cmd_auth(args: argparse.Namespace, is_register: bool) -> int:
    state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
    existing = load_session(state_dir) or {}
    device_id = args.device_id or existing.get("device", {}).get("device_id") or f"linux-{socket.gethostname()}-{secrets.token_hex(4)}"
    device_name = args.name or socket.gethostname()
    ssh_user = args.ssh_user or os.environ.get("SUDO_USER") or getpass.getuser()
    # Plan A / Mode A: auto-initialize host config on brand-new PCs so account login immediately enables zero-PIN pairing
    sunshine_enabled, http_port, https_port, _, _ = ensure_default_sunshine_config(ssh_user)

    body: dict[str, Any] = {
        "username": args.username,
        "password": args.password,
        "device_id": device_id,
        "device_name": device_name,
        "platform": "linux",
        "role": "both" if sunshine_enabled else args.role,
        "ssh_user": ssh_user,
        "ssh_port": args.ssh_port,
        "sunshine_http_port": http_port,
        "sunshine_https_port": https_port,
        "sunshine_enabled": sunshine_enabled,
        "lan_ips": discover_lan_ips(),
    }
    if args.preferred_ip:
        body["preferred_ip"] = args.preferred_ip
    if is_register:
        body["invite_code"] = args.invite

    path = "/api/v1/auth/register" if is_register else "/api/v1/auth/login"
    resp = api_request(args.server, "POST", path, payload=body)
    resp["server_url"] = args.server.rstrip("/")
    resp["ssh_user"] = ssh_user
    save_session(state_dir, resp)

    if sunshine_enabled:
        if resp.get("client_certs"):
            synced = sync_client_certs_to_sunshine(ssh_user, resp["client_certs"])
            if synced:
                print(f"[nodedeck-mesh] Synced {len(resp['client_certs'])} client certificate(s) to Sunshine", flush=True)
        reload_user_sunshine(ssh_user, start_if_stopped=True)
    register_local_ssh_pubkey(args.server, resp["token"], resp["device"]["device_name"], ssh_user)
    if resp.get("ssh_public_keys"):
        if sync_ssh_keys_to_authorized_keys(ssh_user, resp["ssh_public_keys"]):
            print(f"[nodedeck-mesh] Synced {len(resp['ssh_public_keys'])} account SSH key(s)", flush=True)
    ensure_user_mesh_daemon_running(state_dir)

    dev = resp["device"]
    print(f"Signed in as {resp['user']['username']} -> {dev['device_name']} ({dev['virtual_cidr']})")
    return 0


def cmd_logout(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
    sess = load_session(state_dir)
    if sess and sess.get("token") and sess.get("server_url"):
        try:
            api_request(sess["server_url"], "POST", "/api/v1/auth/logout", payload={}, token=sess["token"])
        except Exception:
            pass
    for p in (session_path(state_dir), runtime_toml_path(state_dir)):
        if p.exists():
            p.unlink()
    print("Signed out.")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
    sess = load_session(state_dir)
    if not sess:
        print("Not signed in.")
        return 1
    dev = sess.get("device", {})
    print(f"User: {sess.get('user', {}).get('username')}")
    print(f"Device: {dev.get('device_name')} ({dev.get('virtual_cidr')}) role={dev.get('role')}")
    print(f"Server: {sess.get('server_url')}")
    print(f"Devices in account: {len(sess.get('devices', []))}")
    for d in sess.get("devices", []):
        tag = "online" if d.get("online") else "offline"
        print(f"  - {d.get('device_name')} [{d.get('platform')}/{d.get('role')}] {d.get('virtual_ip')} ({tag})")
    return 0


def cmd_daemon(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
    et_bin = find_easytier_binary()
    toml_file = runtime_toml_path(state_dir)
    stopping = False
    child: subprocess.Popen | None = None

    def handle_sig(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True
        stop_proc(child)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    last_hb = 0.0
    while not stopping:
        sess = load_session(state_dir)
        if not sess or not sess.get("token") or not sess.get("mesh"):
            stop_proc(child)
            child = None
            time.sleep(3)
            continue

        # Initial heartbeat / cert sync before starting easytier-core
        ssh_user = sess.get("ssh_user") or sess.get("device", {}).get("ssh_user") or getpass.getuser()
        lan_ips = discover_lan_ips(sess.get("device", {}).get("virtual_cidr", ""))
        try:
            sunshine_enabled, http_port, https_port, _, _ = ensure_default_sunshine_config(ssh_user)
            hb = api_request(
                sess["server_url"],
                "POST",
                "/api/v1/devices/heartbeat",
                payload={
                    "device_name": sess["device"]["device_name"],
                    "platform": "linux",
                    "role": "both" if sunshine_enabled else sess["device"].get("role", "host"),
                    "ssh_user": ssh_user,
                    "ssh_port": sess["device"].get("ssh_port", 22),
                    "sunshine_http_port": http_port,
                    "sunshine_https_port": https_port,
                    "sunshine_enabled": sunshine_enabled,
                    "lan_ips": lan_ips,
                },
                token=sess["token"],
            )
            hb["token"] = sess["token"]
            hb["server_url"] = sess["server_url"]
            hb["ssh_user"] = ssh_user
            save_session(state_dir, hb)
            sess = hb
            if sunshine_enabled:
                if hb.get("client_certs"):
                    sync_client_certs_to_sunshine(ssh_user, hb["client_certs"])
                reload_user_sunshine(ssh_user, start_if_stopped=True)
            if hb.get("pending_commands"):
                process_pending_commands(sess["server_url"], sess["token"], ssh_user, hb.get("client_certs") or [], hb["pending_commands"])
            register_local_ssh_pubkey(sess["server_url"], sess["token"], hb["device"]["device_name"], ssh_user)
            if hb.get("ssh_public_keys"):
                sync_ssh_keys_to_authorized_keys(ssh_user, hb["ssh_public_keys"])
            last_hb = time.time()
        except Exception as exc:
            print(f"[nodedeck-mesh] heartbeat warning: {exc}", flush=True)

        active_ips = discover_lan_ips(sess["device"]["virtual_cidr"])
        active_net_key = (
            sess["mesh"]["network_name"],
            sess["mesh"]["network_secret"],
            sess["device"]["virtual_cidr"],
        )
        write_runtime_toml(toml_file, sess, active_ips)
        print(
            f"[nodedeck-mesh] starting easytier-core for {sess['device']['device_name']} "
            f"({sess['device']['virtual_cidr']}) lan_ips={active_ips}",
            flush=True,
        )
        child = subprocess.Popen([et_bin, "-c", str(toml_file)])

        while not stopping:
            time.sleep(6)
            if child.poll() is not None:
                print(f"[nodedeck-mesh] easytier-core exited ({child.returncode}), restarting in 2s", flush=True)
                time.sleep(2)
                break

            latest = load_session(state_dir)
            if not latest or not latest.get("token"):
                print("[nodedeck-mesh] signed out, stopping easytier-core", flush=True)
                stop_proc(child)
                child = None
                break

            latest_key = (
                latest["mesh"]["network_name"],
                latest["mesh"]["network_secret"],
                latest["device"]["virtual_cidr"],
            )
            if latest_key != active_net_key:
                print("[nodedeck-mesh] account/mesh identity changed, restarting easytier-core", flush=True)
                stop_proc(child)
                child = None
                break

            now_ips = discover_lan_ips(latest["device"]["virtual_cidr"])
            if now_ips != active_ips:
                time.sleep(2)
                if discover_lan_ips(latest["device"]["virtual_cidr"]) != active_ips:
                    print(f"[nodedeck-mesh] LAN IP changed {active_ips} -> {now_ips}, refreshing mapped_listeners", flush=True)
                    stop_proc(child)
                    child = None
                    break

            if time.time() - last_hb >= 10.0:
                try:
                    sunshine_enabled, http_port, https_port, _, _ = detect_sunshine_config(ssh_user)
                    hb = api_request(
                        latest["server_url"],
                        "POST",
                        "/api/v1/devices/heartbeat",
                        payload={
                            "device_name": latest["device"]["device_name"],
                            "platform": "linux",
                            "role": "both" if sunshine_enabled else latest["device"].get("role", "host"),
                            "ssh_user": ssh_user,
                            "ssh_port": latest["device"].get("ssh_port", 22),
                            "sunshine_http_port": http_port,
                            "sunshine_https_port": https_port,
                            "sunshine_enabled": sunshine_enabled,
                            "lan_ips": now_ips,
                        },
                        token=latest["token"],
                    )
                    hb["token"] = latest["token"]
                    hb["server_url"] = latest["server_url"]
                    hb["ssh_user"] = ssh_user
                    save_session(state_dir, hb)
                    if sunshine_enabled and hb.get("client_certs"):
                        sync_client_certs_to_sunshine(ssh_user, hb["client_certs"])
                    if hb.get("pending_commands"):
                        process_pending_commands(latest["server_url"], latest["token"], ssh_user, hb.get("client_certs") or [], hb["pending_commands"])
                    register_local_ssh_pubkey(latest["server_url"], latest["token"], hb["device"]["device_name"], ssh_user)
                    if hb.get("ssh_public_keys"):
                        sync_ssh_keys_to_authorized_keys(ssh_user, hb["ssh_public_keys"])
                    last_hb = time.time()
                except Exception as exc:
                    print(f"[nodedeck-mesh] heartbeat warning: {exc}", flush=True)

    stop_proc(child)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="NodeDeck Unified Account & EasyTier Mesh Agent")
    parser.add_argument("--state-dir", default=None, help="State directory override")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for name in ("register", "login"):
        p = sub.add_parser(name)
        p.add_argument("--server", default=DEFAULT_SERVER_URL)
        p.add_argument("--username", required=True)
        p.add_argument("--password", required=True)
        if name == "register":
            p.add_argument("--invite", required=True)
        p.add_argument("--name", default=None, help="Device alias/hostname")
        p.add_argument("--device-id", default=None)
        p.add_argument("--role", default="host", choices=["host", "controller", "both"])
        p.add_argument("--ssh-user", default=None)
        p.add_argument("--ssh-port", type=int, default=22)
        p.add_argument("--preferred-ip", default=None)

    sub.add_parser("logout")
    sub.add_parser("status")
    sub.add_parser("daemon")

    args = parser.parse_args()
    if args.cmd == "register":
        return cmd_auth(args, is_register=True)
    if args.cmd == "login":
        return cmd_auth(args, is_register=False)
    if args.cmd == "logout":
        return cmd_logout(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "daemon":
        return cmd_daemon(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
