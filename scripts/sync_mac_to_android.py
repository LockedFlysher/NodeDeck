#!/usr/bin/env python3
"""
Zero-cloud USB sync from macOS NodeDeck + ~/.ssh/config to connected Android NodeDeck.

Transfers directly over local ADB into com.nodedeck.android's app-private sandbox
(via `adb shell run-as com.nodedeck.android`, never touching shared storage or cloud).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

ANDROID_PACKAGE = "com.nodedeck.android"


def find_adb(user_home: Path) -> str:
    adb = shutil.which("adb")
    if adb:
        return adb
    for base in (user_home, Path.home()):
        candidate = base / "Library/Android/sdk/platform-tools/adb"
        if candidate.exists():
            return str(candidate)
    raise FileNotFoundError("adb not found on PATH or ~/Library/Android/sdk/platform-tools/adb")


def parse_ssh_config(config_path: Path, user_home: Path):
    if not config_path.exists():
        return [], set()

    hosts = []
    key_paths = set()
    aliases = []
    hostname = ""
    user = ""
    port = 22
    proxy_jump = ""
    identity_file = ""

    def flush():
        nonlocal aliases, hostname, user, port, proxy_jump, identity_file
        primary = next((a for a in aliases if "*" not in a and "?" not in a and not a.startswith("!")), None)
        if primary:
            resolved_host = hostname or primary
            key_name = ""
            if identity_file:
                raw_id = identity_file.replace("~/", f"{user_home}/") if identity_file.startswith("~/") else identity_file
                expanded = Path(os.path.expanduser(raw_id))
                if expanded.exists() and expanded.is_file():
                    key_paths.add(expanded)
                    key_name = expanded.name
            hosts.append({
                "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"nodedeck-ssh-{primary}")),
                "alias": primary,
                "hostName": resolved_host,
                "user": user or "root",
                "port": port,
                "authType": "PRIVATE_KEY" if key_name else "PASSWORD",
                "password": "",
                "privateKeyName": key_name,
                "privateKeyPassphrase": "",
                "proxyJumpAlias": proxy_jump,
                "notes": "",
            })
        aliases = []
        hostname = ""
        user = ""
        port = 22
        proxy_jump = ""
        identity_file = ""

    for raw in config_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = re.split(r"\s+", line, maxsplit=1)
        if len(parts) < 2:
            continue
        k = parts[0].lower()
        v = parts[1].strip()
        if k == "host":
            flush()
            aliases = [tok for tok in re.split(r"\s+", v) if tok]
        elif k == "hostname" and not hostname:
            hostname = v
        elif k == "user" and not user:
            user = v
        elif k == "port":
            try:
                port = int(v)
            except ValueError:
                port = 22
        elif k == "proxyjump" and not proxy_jump:
            proxy_jump = v
        elif k == "identityfile" and not identity_file:
            identity_file = v.strip('"')
    flush()

    # Also include standard default keys if present, and assign default key to hosts without explicit IdentityFile
    default_key_name = ""
    for default_name in ("id_ed25519", "id_rsa"):
        p = user_home / ".ssh" / default_name
        if p.exists() and p.is_file():
            key_paths.add(p)
            if not default_key_name:
                default_key_name = p.name

    if default_key_name:
        for h in hosts:
            if not h["privateKeyName"]:
                h["authType"] = "PRIVATE_KEY"
                h["privateKeyName"] = default_key_name

    return hosts, key_paths


def load_mac_sunshine_hosts(app_support: Path):
    src = app_support / "sunshine-hosts.json"
    if not src.exists():
        return []
    raw = json.loads(src.read_text(encoding="utf-8"))
    out = []
    for item in raw:
        out.append({
            "id": item.get("id") or str(uuid.uuid4()),
            "hostAlias": item.get("hostAlias", ""),
            "address": item.get("address", ""),
            "httpPort": int(item.get("httpPort", 47989)),
            "httpsPort": int(item.get("httpsPort", 47984)),
            "serverName": item.get("serverName", ""),
            "isPaired": bool(item.get("isPaired", True)),
        })
    return out


def load_mac_host_profiles(app_support: Path):
    src = app_support / "host-profiles.json"
    if not src.exists():
        return []
    raw = json.loads(src.read_text(encoding="utf-8"))
    out = []
    for item in raw:
        mode_raw = str(item.get("mode", "physicalDesktop"))
        mode = "ISOLATED_VIRTUAL_DESKTOP" if "isolated" in mode_raw.lower() else "PHYSICAL_DESKTOP"
        out.append({
            "hostAlias": item.get("hostAlias", ""),
            "mode": mode,
            "display": item.get("display", ":99"),
            "basePort": int(item.get("basePort", 47989)),
            "encoder": item.get("encoder", "nvenc"),
            "cudaDeviceIndex": str(item.get("cudaDeviceIndex", "0")),
            "drmRenderNode": item.get("drmRenderNode", "/dev/dri/renderD128"),
            "virtualAudioSink": bool(item.get("virtualAudioSink", False)),
            "clipboardSync": bool(item.get("clipboardSync", True)),
        })
    return out


def adb_write_sandbox_file(adb: str, serial: str | None, rel_path: str, content: bytes):
    cmd = [adb]
    if serial:
        cmd += ["-s", serial]
    cmd += ["shell", f"run-as {ANDROID_PACKAGE} sh -c 'cat > {rel_path}'"]
    proc = subprocess.run(cmd, input=content, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Failed writing {rel_path}: {proc.stderr.decode(errors='ignore')}")


def adb_run(adb: str, serial: str | None, args: list[str]):
    cmd = [adb]
    if serial:
        cmd += ["-s", serial]
    cmd += args
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def main():
    parser = argparse.ArgumentParser(description="Sync macOS NodeDeck & SSH config to Android over USB")
    parser.add_argument("-s", "--serial", help="ADB device serial")
    parser.add_argument("--no-keys", action="store_true", help="Skip syncing SSH private keys")
    parser.add_argument("--no-moonlight-cert", action="store_true", help="Skip syncing Moonlight client certificate")
    args = parser.parse_args()

    user_home = Path.home()
    adb = find_adb(user_home)
    app_support = user_home / "Library/Application Support/NodeDeck"
    ssh_config = user_home / ".ssh/config"

    hosts, key_paths = parse_ssh_config(ssh_config, user_home)
    sunshine_hosts = load_mac_sunshine_hosts(app_support)
    host_profiles = load_mac_host_profiles(app_support)

    adb_run(adb, args.serial, ["shell", f"run-as {ANDROID_PACKAGE} mkdir -p files/nodedeck/ssh_keys files/nodedeck/moonlight"])

    adb_write_sandbox_file(adb, args.serial, "files/nodedeck/hosts.json", json.dumps(hosts, indent=2).encode("utf-8"))
    adb_write_sandbox_file(adb, args.serial, "files/nodedeck/sunshine_hosts.json", json.dumps(sunshine_hosts, indent=2).encode("utf-8"))
    adb_write_sandbox_file(adb, args.serial, "files/nodedeck/host_profiles.json", json.dumps(host_profiles, indent=2).encode("utf-8"))
    adb_run(adb, args.serial, ["shell", f"run-as {ANDROID_PACKAGE} chmod 600 files/nodedeck/hosts.json files/nodedeck/sunshine_hosts.json files/nodedeck/host_profiles.json"])

    synced_keys = []
    if not args.no_keys:
        for kp in sorted(key_paths):
            safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", kp.name)
            adb_write_sandbox_file(adb, args.serial, f"files/nodedeck/ssh_keys/{safe_name}", kp.read_bytes())
            adb_run(adb, args.serial, ["shell", f"run-as {ANDROID_PACKAGE} chmod 600 files/nodedeck/ssh_keys/{safe_name}"])
            synced_keys.append(safe_name)

    synced_moonlight = []
    if not args.no_moonlight_cert:
        ml_dir = app_support / "moonlight"
        for fname in ("client.crt", "client.key", "uniqueid.txt"):
            fpath = ml_dir / fname
            if fpath.exists():
                adb_write_sandbox_file(adb, args.serial, f"files/nodedeck/moonlight/{fname}", fpath.read_bytes())
                adb_run(adb, args.serial, ["shell", f"run-as {ANDROID_PACKAGE} chmod 600 files/nodedeck/moonlight/{fname}"])
                synced_moonlight.append(fname)

    # Restart NodeDeck Android app so it reloads all synced files cleanly
    adb_run(adb, args.serial, ["shell", "am", "force-stop", ANDROID_PACKAGE])
    adb_run(adb, args.serial, ["shell", "am", "start", "-W", "-n", f"{ANDROID_PACKAGE}/.MainActivity"])

    print(f"Synced {len(hosts)} SSH hosts: {[h['alias'] for h in hosts]}")
    print(f"Synced {len(synced_keys)} SSH keys: {synced_keys}")
    print(f"Synced {len(sunshine_hosts)} Sunshine hosts: {[s['hostAlias'] for s in sunshine_hosts]}")
    print(f"Synced {len(host_profiles)} Linux host profiles")
    print(f"Synced Moonlight identity files: {synced_moonlight}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
