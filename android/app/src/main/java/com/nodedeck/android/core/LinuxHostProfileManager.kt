package com.nodedeck.android.core

import android.util.Base64
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class LinuxHostProfileManager(private val sshManager: SshManager) {
    private val json = Json { encodeDefaults = true }

    suspend fun reconcile(profile: LinuxHostProfile, host: SSHHost, allHosts: List<SSHHost>): Boolean {
        val payloadB64 = Base64.encodeToString(
            json.encodeToString(profile).toByteArray(Charsets.UTF_8),
            Base64.NO_WRAP
        )
        val remotePy = """
import base64, json, os, re, subprocess

prof = json.loads(base64.b64decode("$payloadB64").decode("utf-8"))
home = os.path.expanduser("~")
nd_conf = os.path.join(home, ".config", "nodedeck")
legacy_host_conf = os.path.join(nd_conf, "host", "host.conf")
primary_host_conf = os.path.join(nd_conf, "host.conf")
if os.path.exists(primary_host_conf) or not os.path.exists(legacy_host_conf):
    host_conf_dir = nd_conf
    conf_path = primary_host_conf
    default_state = os.path.join(nd_conf, "host_state.json")
else:
    host_conf_dir = os.path.join(nd_conf, "host")
    conf_path = legacy_host_conf
    default_state = os.path.join(host_conf_dir, "sunshine_state.json")
os.makedirs(host_conf_dir, exist_ok=True)

mode = prof.get("mode", "PHYSICAL_DESKTOP")
base_port = int(prof.get("basePort", 47989))
encoder = (prof.get("encoder") or "auto").strip()
capture = (prof.get("captureMethod") or "auto").strip()
render_node = (prof.get("drmRenderNode") or "").strip()
virtual_audio = bool(prof.get("virtualAudioSink", False))
clipboard = bool(prof.get("clipboardSync", True))
alias = prof.get("hostAlias", "NodeDeck")

cfg = {}
if os.path.exists(conf_path):
    for raw in open(conf_path, "r", encoding="utf-8", errors="ignore"):
        ln = raw.strip()
        if not ln or ln.startswith("#") or "=" not in ln:
            continue
        k, v = ln.split("=", 1)
        cfg[k.strip()] = v.strip()

# Preserve & repair essential paths
for k, dv in [
    ("file_apps", os.path.join(host_conf_dir, "apps.json")),
    ("file_state", default_state),
    ("credentials_file", os.path.join(host_conf_dir, "credentials.json")),
    ("pkey", os.path.join(host_conf_dir, "host.key")),
    ("cert", os.path.join(host_conf_dir, "host.cert")),
]:
    if k not in cfg or re.match(r"^/bin/(ba|z|da)?sh/", cfg.get(k, "")):
        cfg[k] = dv

cfg["sunshine_name"] = alias
cfg["port"] = str(base_port)
cfg["clipboard_sync"] = "enabled" if clipboard else "disabled"
cfg["upnp"] = "disabled"

if encoder and encoder != "auto":
    cfg["encoder"] = encoder
else:
    cfg.pop("encoder", None)

if capture and capture != "auto":
    cfg["capture"] = capture
elif mode == "ISOLATED_VIRTUAL_DESKTOP":
    cfg["capture"] = "x11"
else:
    cfg.pop("capture", None)

if render_node:
    cfg["adapter_name"] = render_node
else:
    cfg.pop("adapter_name", None)

if virtual_audio:
    cfg["audio_sink"] = "sunshine_virtual_sink"
else:
    cfg.pop("audio_sink", None)

with open(conf_path, "w", encoding="utf-8") as f:
    f.write("\n".join(f"{k} = {v}" for k, v in cfg.items()) + "\n")

restarted = False
for svc in ["nodedeck-host", "foundation-sunshine", "sunshine"]:
    if subprocess.run(["systemctl", "--user", "is-active", "--quiet", svc]).returncode == 0:
        r = subprocess.run(["systemctl", "--user", "restart", svc], check=False)
        restarted = (r.returncode == 0)
        break
if not restarted:
    r = subprocess.run(["systemctl", "--user", "enable", "--now", "nodedeck-host.service"], check=False)
    restarted = (r.returncode == 0)
print(f"OK:{int(restarted)}")
        """.trimIndent()
        val res = sshManager.exec(host, allHosts, "python3 -", stdinText = remotePy, timeoutMs = 18_000)
        if (res.exitCode != 0) {
            throw IllegalStateException(res.stderr.trim().ifBlank { "Host profile sync failed" })
        }
        return res.stdout.lines().lastOrNull { it.startsWith("OK:") }?.endsWith(":1") == true
    }
}
