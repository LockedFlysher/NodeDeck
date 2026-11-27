#!/usr/bin/env python3
"""
NodeDeck Control Plane API (self-hosted, zero third-party dependencies).

Provides unified multi-user registration (invite-code gated), login, sticky IPAM,
per-user isolated EasyTier mesh credentials, device discovery, and Moonlight
public-certificate auto-pairing across Linux, macOS, and Android clients.
"""

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

VERSION = "2.1.0"

DB_PATH = Path(os.environ.get("NODEDECK_DB_PATH", "/var/lib/nodedeck-control/control.db"))
INVITE_CODE = os.environ.get("NODEDECK_INVITE_CODE", "").strip()
SEED_URI = os.environ.get("NODEDECK_SEED_URI", "tcp://127.0.0.1:11010").strip()
LISTEN_PORT = int(os.environ.get("NODEDECK_MESH_LISTEN_PORT", "28443"))
BIND_HOST = os.environ.get("NODEDECK_BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("NODEDECK_PORT", "18443"))
DEFAULT_SUBNET = os.environ.get("NODEDECK_DEFAULT_SUBNET", "10.99.0.0/24")
DEVICE_ONLINE_TTL_SEC = int(os.environ.get("NODEDECK_DEVICE_TTL_SEC", "120"))

USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$")
DB_LOCK = threading.RLock()


def get_db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    with DB_LOCK:
        conn = get_db()
        try:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    password_salt TEXT NOT NULL,
                    password_hash TEXT NOT NULL,
                    mesh_network_name TEXT NOT NULL UNIQUE,
                    mesh_network_secret TEXT NOT NULL,
                    mesh_subnet TEXT NOT NULL DEFAULT '10.99.0.0/24',
                    created_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS devices (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    device_id TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    platform TEXT NOT NULL,
                    role TEXT NOT NULL DEFAULT 'controller',
                    virtual_ip TEXT NOT NULL,
                    ssh_user TEXT NOT NULL DEFAULT '',
                    ssh_port INTEGER NOT NULL DEFAULT 22,
                    sunshine_http_port INTEGER NOT NULL DEFAULT 47989,
                    sunshine_https_port INTEGER NOT NULL DEFAULT 47984,
                    sunshine_enabled INTEGER NOT NULL DEFAULT 0,
                    lan_ips TEXT NOT NULL DEFAULT '[]',
                    last_seen INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    UNIQUE(user_id, device_id),
                    UNIQUE(user_id, virtual_ip)
                );

                CREATE TABLE IF NOT EXISTS sessions (
                    token TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    device_id TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    last_used_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS client_certs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    device_id TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    unique_id TEXT NOT NULL,
                    cert_pem TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(user_id, device_id)
                );

                CREATE TABLE IF NOT EXISTS ssh_keys (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    device_id TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    public_key TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(user_id, device_id)
                );
                """
            )
            conn.commit()
        finally:
            conn.close()


def hash_password(password: str, salt_hex: str | None = None) -> tuple[str, str]:
    salt = bytes.fromhex(salt_hex) if salt_hex else secrets.token_bytes(16)
    derived = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=16384,
        r=8,
        p=1,
        dklen=32,
    )
    return salt.hex(), derived.hex()


def verify_password(password: str, salt_hex: str, expected_hash: str) -> bool:
    _, candidate = hash_password(password, salt_hex)
    return hmac.compare_digest(candidate, expected_hash)


def allocate_virtual_ip(
    conn: sqlite3.Connection,
    user_id: int,
    subnet_cidr: str,
    preferred_ip: str | None = None,
) -> str:
    net = ipaddress.IPv4Network(subnet_cidr, strict=False)
    rows = conn.execute("SELECT virtual_ip FROM devices WHERE user_id = ?", (user_id,)).fetchall()
    used = {r["virtual_ip"].split("/")[0] for r in rows}
    # Reserve .254 for seed relay convention if within /24
    reserved_last = str(net.broadcast_address - 1) if net.num_addresses >= 16 else ""

    if preferred_ip:
        cand = preferred_ip.split("/")[0].strip()
        try:
            addr = ipaddress.IPv4Address(cand)
            if addr in net and addr != net.network_address and addr != net.broadcast_address:
                if cand != reserved_last and cand not in used:
                    return cand
        except ValueError:
            pass

    for host in net.hosts():
        s = str(host)
        if s == reserved_last or s in used:
            continue
        return s
    raise RuntimeError("No available virtual IPv4 addresses in user subnet")


def upsert_device(
    conn: sqlite3.Connection,
    user: sqlite3.Row,
    payload: dict[str, Any],
) -> sqlite3.Row:
    now = int(time.time())
    user_id = int(user["id"])
    subnet = user["mesh_subnet"]
    device_id = str(payload.get("device_id") or "").strip()
    if not device_id:
        device_id = f"dev-{secrets.token_hex(8)}"
    device_name = str(payload.get("device_name") or "device").strip()[:64] or "device"
    platform = str(payload.get("platform") or "unknown").strip().lower()[:32]
    role = str(payload.get("role") or "controller").strip().lower()
    if role not in ("controller", "host", "both"):
        role = "controller"
    ssh_user = str(payload.get("ssh_user") or "").strip()[:64]
    ssh_port = int(payload.get("ssh_port") or 22)
    sunshine_http_port = int(payload.get("sunshine_http_port") or 47989)
    sunshine_https_port = int(payload.get("sunshine_https_port") or max(1, sunshine_http_port - 5))
    sunshine_enabled = 1 if bool(payload.get("sunshine_enabled", False)) else 0
    lan_ips = payload.get("lan_ips")
    lan_ips_json = json.dumps(lan_ips if isinstance(lan_ips, list) else [])
    preferred_ip = str(payload.get("preferred_ip") or "").strip() or None

    existing = conn.execute(
        "SELECT * FROM devices WHERE user_id = ? AND device_id = ?",
        (user_id, device_id),
    ).fetchone()

    if existing is None:
        vip = allocate_virtual_ip(conn, user_id, subnet, preferred_ip=preferred_ip)
        conn.execute(
            """
            INSERT INTO devices (
                user_id, device_id, device_name, platform, role, virtual_ip,
                ssh_user, ssh_port, sunshine_http_port, sunshine_https_port,
                sunshine_enabled, lan_ips, last_seen, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                user_id, device_id, device_name, platform, role, vip,
                ssh_user, ssh_port, sunshine_http_port, sunshine_https_port,
                sunshine_enabled, lan_ips_json, now, now,
            ),
        )
    else:
        conn.execute(
            """
            UPDATE devices SET
                device_name = ?,
                platform = ?,
                role = ?,
                ssh_user = CASE WHEN ? != '' THEN ? ELSE ssh_user END,
                ssh_port = ?,
                sunshine_http_port = ?,
                sunshine_https_port = ?,
                sunshine_enabled = ?,
                lan_ips = ?,
                last_seen = ?
            WHERE id = ?
            """,
            (
                device_name, platform, role,
                ssh_user, ssh_user, ssh_port,
                sunshine_http_port, sunshine_https_port,
                sunshine_enabled, lan_ips_json, now,
                existing["id"],
            ),
        )

    row = conn.execute(
        "SELECT * FROM devices WHERE user_id = ? AND device_id = ?",
        (user_id, device_id),
    ).fetchone()
    assert row is not None
    return row


def format_device(row: sqlite3.Row, prefix_len: int, now: int) -> dict[str, Any]:
    last_seen = int(row["last_seen"])
    return {
        "device_id": row["device_id"],
        "device_name": row["device_name"],
        "platform": row["platform"],
        "role": row["role"],
        "virtual_ip": row["virtual_ip"],
        "virtual_cidr": f"{row['virtual_ip']}/{prefix_len}",
        "ssh_user": row["ssh_user"],
        "ssh_port": int(row["ssh_port"]),
        "sunshine_http_port": int(row["sunshine_http_port"]),
        "sunshine_https_port": int(row["sunshine_https_port"]),
        "sunshine_enabled": bool(row["sunshine_enabled"]),
        "lan_ips": json.loads(row["lan_ips"] or "[]"),
        "last_seen": last_seen,
        "online": (now - last_seen) <= DEVICE_ONLINE_TTL_SEC,
    }


def build_state_payload(
    conn: sqlite3.Connection,
    user: sqlite3.Row,
    current_device: sqlite3.Row,
    token: str | None = None,
) -> dict[str, Any]:
    now = int(time.time())
    net = ipaddress.IPv4Network(user["mesh_subnet"], strict=False)
    prefix_len = net.prefixlen
    dev_rows = conn.execute(
        "SELECT * FROM devices WHERE user_id = ? ORDER BY virtual_ip ASC",
        (user["id"],),
    ).fetchall()
    cert_rows = conn.execute(
        "SELECT device_id, device_name, unique_id, cert_pem, updated_at FROM client_certs WHERE user_id = ?",
        (user["id"],),
    ).fetchall()
    ssh_rows = conn.execute(
        "SELECT device_id, device_name, public_key, updated_at FROM ssh_keys WHERE user_id = ?",
        (user["id"],),
    ).fetchall()

    payload: dict[str, Any] = {
        "user": {
            "username": user["username"],
        },
        "device": format_device(current_device, prefix_len, now),
        "mesh": {
            "network_name": user["mesh_network_name"],
            "network_secret": user["mesh_network_secret"],
            "subnet": user["mesh_subnet"],
            "seed_uri": SEED_URI,
            "listen_port": LISTEN_PORT,
        },
        "devices": [format_device(r, prefix_len, now) for r in dev_rows],
        "client_certs": [
            {
                "device_id": c["device_id"],
                "device_name": c["device_name"],
                "unique_id": c["unique_id"],
                "cert_pem": c["cert_pem"],
                "updated_at": int(c["updated_at"]),
            }
            for c in cert_rows
        ],
        "ssh_public_keys": [
            {
                "device_id": k["device_id"],
                "device_name": k["device_name"],
                "public_key": k["public_key"],
                "updated_at": int(k["updated_at"]),
            }
            for k in ssh_rows
        ],
    }
    if token is not None:
        payload["token"] = token
    return payload


PORTAL_HTML = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>NodeDeck Control Plane</title>
<style>
  :root { color-scheme: dark; --bg:#0d1117; --card:#161b22; --border:#30363d; --text:#e6edf3; --muted:#8b949e; --accent:#58a6ff; --ok:#3fb950; --err:#f85149; }
  * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  body { margin:0; background:var(--bg); color:var(--text); min-height:100vh; display:flex; align-items:center; justify-content:center; padding:24px; }
  .wrap { width:100%; max-width:460px; background:var(--card); border:1px solid var(--border); border-radius:14px; padding:24px; box-shadow:0 12px 32px rgba(0,0,0,.45); }
  h1 { margin:0 0 6px; font-size:20px; }
  .sub { margin:0 0 18px; color:var(--muted); font-size:13px; }
  .tabs { display:flex; gap:8px; margin-bottom:16px; }
  .tab { flex:1; padding:9px; border-radius:8px; border:1px solid var(--border); background:transparent; color:var(--muted); cursor:pointer; font-weight:600; }
  .tab.active { background:rgba(88,166,255,.14); border-color:var(--accent); color:var(--text); }
  label { display:block; font-size:12px; color:var(--muted); margin:10px 0 4px; }
  input { width:100%; padding:10px 12px; border-radius:8px; border:1px solid var(--border); background:#0d1117; color:var(--text); font-size:14px; }
  button.primary { width:100%; margin-top:16px; padding:11px; border:0; border-radius:8px; background:var(--accent); color:#081018; font-weight:700; font-size:14px; cursor:pointer; }
  button.secondary { margin-top:12px; padding:8px 12px; border-radius:8px; border:1px solid var(--border); background:transparent; color:var(--text); cursor:pointer; }
  .msg { margin-top:12px; font-size:13px; min-height:18px; }
  .msg.ok { color:var(--ok); }
  .msg.err { color:var(--err); }
  .dev { display:flex; justify-content:space-between; align-items:center; padding:10px 12px; border:1px solid var(--border); border-radius:10px; margin-top:8px; background:#0d1117; }
  .badge { font-size:11px; padding:2px 8px; border-radius:999px; border:1px solid var(--border); }
  .badge.on { color:var(--ok); border-color:rgba(63,185,80,.4); }
  .badge.off { color:var(--muted); }
  .hidden { display:none; }
</style>
</head>
<body>
<div class="wrap">
  <h1>NodeDeck 账号控制面</h1>
  <p class="sub">登录或凭邀请码注册后，在 Linux / macOS / Android 客户端直接登录即可自动加入私有 P2P 虚拟网。</p>
  <div id="authBox">
    <div class="tabs">
      <button class="tab active" id="tabLogin" onclick="setMode('login')">登录查看设备</button>
      <button class="tab" id="tabReg" onclick="setMode('register')">邀请码注册</button>
    </div>
    <label>用户名</label>
    <input id="u" autocomplete="username" placeholder="2-32位字母/数字/._-" />
    <label>密码</label>
    <input id="p" type="password" autocomplete="current-password" placeholder="4-128位密码" />
    <div id="invWrap" class="hidden">
      <label>邀请码</label>
      <input id="inv" placeholder="请输入邀请码" />
    </div>
    <button class="primary" id="submitBtn" onclick="submitAuth()">登录</button>
    <div id="msg" class="msg"></div>
  </div>
  <div id="dashBox" class="hidden">
    <div style="display:flex;justify-content:space-between;align-items:center;">
      <div><strong id="who"></strong><div class="sub" id="subnetInfo" style="margin:2px 0 0;"></div></div>
      <button class="secondary" onclick="logout()">退出</button>
    </div>
    <div id="devList" style="margin-top:12px;"></div>
  </div>
</div>
<script>
const base = window.location.pathname.replace(/\\/+$/, "");
let mode = "login";
let token = sessionStorage.getItem("nd_token") || "";
function setMode(m) {
  mode = m;
  document.getElementById("tabLogin").classList.toggle("active", m === "login");
  document.getElementById("tabReg").classList.toggle("active", m === "register");
  document.getElementById("invWrap").classList.toggle("hidden", m !== "register");
  document.getElementById("submitBtn").textContent = m === "register" ? "注册账号" : "登录";
  document.getElementById("msg").textContent = "";
}
function showMsg(text, ok) {
  const el = document.getElementById("msg");
  el.textContent = text;
  el.className = "msg " + (ok ? "ok" : "err");
}
async function submitAuth() {
  const username = document.getElementById("u").value.trim();
  const password = document.getElementById("p").value;
  const invite_code = document.getElementById("inv").value.trim();
  const payload = { username, password, device_id: "web-portal-" + username, device_name: "Web Portal", platform: "web", role: "controller" };
  if (mode === "register") payload.invite_code = invite_code;
  try {
    const res = await fetch(base + (mode === "register" ? "/api/v1/auth/register" : "/api/v1/auth/login"), {
      method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!res.ok) { showMsg(data.error || ("HTTP " + res.status), false); return; }
    token = data.token || "";
    sessionStorage.setItem("nd_token", token);
    renderDash(data);
  } catch (e) { showMsg(String(e), false); }
}
function renderDash(data) {
  document.getElementById("authBox").classList.add("hidden");
  document.getElementById("dashBox").classList.remove("hidden");
  document.getElementById("who").textContent = "账号：" + (data.user?.username || "");
  document.getElementById("subnetInfo").textContent = "私网子网：" + (data.mesh?.subnet || "") + " · 已注册设备 " + (data.devices?.length || 0) + " 台";
  const list = document.getElementById("devList");
  list.innerHTML = "";
  (data.devices || []).forEach(d => {
    const row = document.createElement("div");
    row.className = "dev";
    const left = document.createElement("div");
    const title = document.createElement("div");
    const nameEl = document.createElement("strong");
    nameEl.textContent = d.device_name || "";
    const metaEl = document.createElement("span");
    metaEl.style.cssText = "color:var(--muted);font-size:12px;margin-left:6px;";
    metaEl.textContent = `[${d.platform}/${d.role}]`;
    title.append(nameEl, metaEl);
    const sub = document.createElement("div");
    sub.style.cssText = "color:var(--muted);font-size:12px;margin-top:2px;";
    sub.textContent = (d.virtual_ip || "") + (d.sunshine_enabled ? ` · Remote Desktop :${d.sunshine_http_port}` : "");
    left.append(title, sub);
    const badge = document.createElement("span");
    badge.className = "badge " + (d.online ? "on" : "off");
    badge.textContent = d.online ? "在线" : "离线";
    row.append(left, badge);
    list.appendChild(row);
  });
}
async function logout() {
  if (token) {
    try { await fetch(base + "/api/v1/auth/logout", { method: "POST", headers: {"Authorization": "Bearer " + token, "Content-Type": "application/json"}, body: "{}" }); } catch {}
  }
  token = "";
  sessionStorage.removeItem("nd_token");
  document.getElementById("dashBox").classList.add("hidden");
  document.getElementById("authBox").classList.remove("hidden");
}
if (token) {
  fetch(base + "/api/v1/state", { headers: {"Authorization": "Bearer " + token} })
    .then(r => r.ok ? r.json() : Promise.reject())
    .then(renderDash)
    .catch(() => { token = ""; sessionStorage.removeItem("nd_token"); });
}
</script>
</body>
</html>
"""


class ControlPlaneHandler(BaseHTTPRequestHandler):
    server_version = f"NodeDeckControl/{VERSION}"

    def log_message(self, fmt: str, *args: Any) -> None:
        # Never log Authorization headers or secrets
        print(f"[nodedeck-control] {self.address_string()} {fmt % args}", flush=True)

    def _send_html(self, status: int, html: str) -> None:
        raw = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _send_json(self, status: int, body: dict[str, Any]) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0 or length > 256 * 1024:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode("utf-8"))

    def _authenticate(self, conn: sqlite3.Connection) -> tuple[sqlite3.Row, sqlite3.Row, str] | None:
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            return None
        token = auth[7:].strip()
        if not token:
            return None
        sess = conn.execute("SELECT * FROM sessions WHERE token = ?", (token,)).fetchone()
        if sess is None:
            return None
        user = conn.execute("SELECT * FROM users WHERE id = ?", (sess["user_id"],)).fetchone()
        if user is None:
            return None
        dev = conn.execute(
            "SELECT * FROM devices WHERE user_id = ? AND device_id = ?",
            (user["id"], sess["device_id"]),
        ).fetchone()
        if dev is None:
            return None
        conn.execute("UPDATE sessions SET last_used_at = ? WHERE token = ?", (int(time.time()), token))
        return user, dev, token

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/":
            self._send_html(HTTPStatus.OK, PORTAL_HTML)
            return
        if path == "/api/v1/health":
            self._send_json(HTTPStatus.OK, {"ok": True, "version": VERSION})
            return

        if path == "/api/v1/state":
            with DB_LOCK:
                conn = get_db()
                try:
                    auth = self._authenticate(conn)
                    if auth is None:
                        self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "Unauthorized"})
                        return
                    user, dev, _ = auth
                    conn.execute("UPDATE devices SET last_seen = ? WHERE id = ?", (int(time.time()), dev["id"]))
                    conn.commit()
                    dev = conn.execute("SELECT * FROM devices WHERE id = ?", (dev["id"],)).fetchone()
                    self._send_json(HTTPStatus.OK, build_state_payload(conn, user, dev))
                    return
                finally:
                    conn.close()

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        try:
            body = self._read_json()
        except Exception:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON body"})
            return

        if path == "/api/v1/auth/register":
            self._handle_register(body)
        elif path == "/api/v1/auth/login":
            self._handle_login(body)
        elif path == "/api/v1/auth/logout":
            self._handle_logout()
        elif path == "/api/v1/devices/heartbeat":
            self._handle_heartbeat(body)
        elif path == "/api/v1/certs/register":
            self._handle_cert_register(body)
        elif path == "/api/v1/ssh-keys/register":
            self._handle_ssh_key_register(body)
        else:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def _handle_register(self, body: dict[str, Any]) -> None:
        username = str(body.get("username") or "").strip()
        password = str(body.get("password") or "")
        invite = str(body.get("invite_code") or "").strip()

        if not INVITE_CODE:
            self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "Registration is disabled on this server"})
            return
        if not hmac.compare_digest(invite, INVITE_CODE):
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "Invalid invite code"})
            return
        if not USERNAME_RE.match(username):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Username must be 2-32 chars (letters, digits, . _ -)"})
            return
        if len(password) < 4 or len(password) > 128:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Password must be 4-128 characters"})
            return

        with DB_LOCK:
            conn = get_db()
            try:
                exists = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
                if exists is not None:
                    self._send_json(HTTPStatus.CONFLICT, {"error": "Username already exists"})
                    return
                now = int(time.time())
                salt_hex, hash_hex = hash_password(password)
                net_name = f"nd-{username.lower()}-{secrets.token_hex(4)}"
                net_secret = secrets.token_urlsafe(24)
                cur = conn.execute(
                    """
                    INSERT INTO users (
                        username, password_salt, password_hash,
                        mesh_network_name, mesh_network_secret, mesh_subnet, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (username, salt_hex, hash_hex, net_name, net_secret, DEFAULT_SUBNET, now),
                )
                user = conn.execute("SELECT * FROM users WHERE id = ?", (cur.lastrowid,)).fetchone()
                dev = upsert_device(conn, user, body)
                token = secrets.token_urlsafe(32)
                conn.execute(
                    "INSERT INTO sessions (token, user_id, device_id, created_at, last_used_at) VALUES (?, ?, ?, ?, ?)",
                    (token, user["id"], dev["device_id"], now, now),
                )
                conn.commit()
                self._send_json(HTTPStatus.CREATED, build_state_payload(conn, user, dev, token=token))
            finally:
                conn.close()

    def _handle_login(self, body: dict[str, Any]) -> None:
        username = str(body.get("username") or "").strip()
        password = str(body.get("password") or "")
        if not username or not password:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Username and password required"})
            return

        with DB_LOCK:
            conn = get_db()
            try:
                user = conn.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
                if user is None or not verify_password(password, user["password_salt"], user["password_hash"]):
                    self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "Invalid username or password"})
                    return
                now = int(time.time())
                dev = upsert_device(conn, user, body)
                token = secrets.token_urlsafe(32)
                conn.execute(
                    "INSERT INTO sessions (token, user_id, device_id, created_at, last_used_at) VALUES (?, ?, ?, ?, ?)",
                    (token, user["id"], dev["device_id"], now, now),
                )
                conn.commit()
                self._send_json(HTTPStatus.OK, build_state_payload(conn, user, dev, token=token))
            finally:
                conn.close()

    def _handle_logout(self) -> None:
        with DB_LOCK:
            conn = get_db()
            try:
                auth = self._authenticate(conn)
                if auth is not None:
                    _, _, token = auth
                    conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
                    conn.commit()
                self._send_json(HTTPStatus.OK, {"ok": True})
            finally:
                conn.close()

    def _handle_heartbeat(self, body: dict[str, Any]) -> None:
        with DB_LOCK:
            conn = get_db()
            try:
                auth = self._authenticate(conn)
                if auth is None:
                    self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "Unauthorized"})
                    return
                user, dev, _ = auth
                merged = dict(body)
                merged["device_id"] = dev["device_id"]
                if not merged.get("device_name"):
                    merged["device_name"] = dev["device_name"]
                if not merged.get("platform"):
                    merged["platform"] = dev["platform"]
                if not merged.get("role"):
                    merged["role"] = dev["role"]
                updated_dev = upsert_device(conn, user, merged)
                conn.commit()
                self._send_json(HTTPStatus.OK, build_state_payload(conn, user, updated_dev))
            finally:
                conn.close()

    def _handle_cert_register(self, body: dict[str, Any]) -> None:
        cert_pem = str(body.get("cert_pem") or "").strip()
        unique_id = str(body.get("unique_id") or "").strip()
        if "BEGIN CERTIFICATE" not in cert_pem or not unique_id:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Valid cert_pem and unique_id required"})
            return

        with DB_LOCK:
            conn = get_db()
            try:
                auth = self._authenticate(conn)
                if auth is None:
                    self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "Unauthorized"})
                    return
                user, dev, _ = auth
                now = int(time.time())
                device_name = str(body.get("device_name") or dev["device_name"]).strip()[:64]
                conn.execute(
                    """
                    INSERT INTO client_certs (user_id, device_id, device_name, unique_id, cert_pem, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(user_id, device_id) DO UPDATE SET
                        device_name = excluded.device_name,
                        unique_id = excluded.unique_id,
                        cert_pem = excluded.cert_pem,
                        updated_at = excluded.updated_at
                    """,
                    (user["id"], dev["device_id"], device_name, unique_id, cert_pem + "\n", now),
                )
                conn.commit()
                self._send_json(HTTPStatus.OK, {"ok": True})
            finally:
                conn.close()

    def _handle_ssh_key_register(self, body: dict[str, Any]) -> None:
        pubkey = str(body.get("public_key") or "").strip()
        allowed_prefixes = (
            "ssh-ed25519 ",
            "ssh-rsa ",
            "ecdsa-sha2-nistp256 ",
            "ecdsa-sha2-nistp384 ",
            "ecdsa-sha2-nistp521 ",
        )
        if not pubkey or "\n" in pubkey or "\r" in pubkey or len(pubkey) > 4096 or not pubkey.startswith(allowed_prefixes):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Valid single-line OpenSSH public_key required"})
            return

        with DB_LOCK:
            conn = get_db()
            try:
                auth = self._authenticate(conn)
                if auth is None:
                    self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "Unauthorized"})
                    return
                user, dev, _ = auth
                now = int(time.time())
                device_name = str(body.get("device_name") or dev["device_name"]).strip()[:64]
                conn.execute(
                    """
                    INSERT INTO ssh_keys (user_id, device_id, device_name, public_key, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(user_id, device_id) DO UPDATE SET
                        device_name = excluded.device_name,
                        public_key = excluded.public_key,
                        updated_at = excluded.updated_at
                    """,
                    (user["id"], dev["device_id"], device_name, pubkey, now),
                )
                conn.commit()
                self._send_json(HTTPStatus.OK, {"ok": True})
            finally:
                conn.close()


def main() -> None:
    init_db()
    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), ControlPlaneHandler)
    print(
        f"[nodedeck-control] v{VERSION} listening on http://{BIND_HOST}:{BIND_PORT} "
        f"(db={DB_PATH}, seed={SEED_URI}, invite_enabled={bool(INVITE_CODE)})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
