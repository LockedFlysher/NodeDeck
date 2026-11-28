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
import base64, json, os, subprocess

prof = json.loads(base64.b64decode("$payloadB64").decode("utf-8"))
home = os.path.expanduser("~")
nd_conf = os.path.join(home, ".config", "nodedeck")
host_conf_dir = os.path.join(nd_conf, "host")
os.makedirs(host_conf_dir, exist_ok=True)

mode = prof["mode"]
base_port = int(prof["basePort"])
encoder = prof["encoder"].strip() or "nvenc"
render_node = prof["drmRenderNode"].strip()
virtual_audio = bool(prof["virtualAudioSink"])
clipboard = bool(prof["clipboardSync"])
alias = prof["hostAlias"]

conf_lines = [
    f"sunshine_name = {alias}",
    "capture = x11",
    f"encoder = {encoder}",
    f"port = {base_port}",
    f"clipboard_sync = {'enabled' if clipboard else 'disabled'}",
    "upnp = disabled",
    f"file_state = {os.path.join(host_conf_dir, 'sunshine_state.json')}",
    f"file_apps = {os.path.join(host_conf_dir, 'apps.json')}",
    f"credentials_file = {os.path.join(host_conf_dir, 'sunshine_state.json')}",
]
if render_node and mode == "ISOLATED_VIRTUAL_DESKTOP":
    conf_lines.append(f"adapter_name = {render_node}")
if virtual_audio:
    conf_lines.append("audio_sink = sunshine_virtual_sink")

with open(os.path.join(host_conf_dir, "host.conf"), "w", encoding="utf-8") as f:
    f.write("\n".join(conf_lines) + "\n")

restarted = False
for svc in ["nodedeck-host", "foundation-sunshine", "sunshine"]:
    if subprocess.run(["systemctl", "--user", "is-active", "--quiet", svc]).returncode == 0:
        r = subprocess.run(["systemctl", "--user", "restart", svc], check=False)
        restarted = (r.returncode == 0)
        break
print(f"OK:{int(restarted)}")
        """.trimIndent()
        val res = sshManager.exec(host, allHosts, "python3 -", stdinText = remotePy, timeoutMs = 18_000)
        if (res.exitCode != 0) {
            throw IllegalStateException(res.stderr.trim().ifBlank { "Host profile sync failed" })
        }
        return res.stdout.lines().lastOrNull { it.startsWith("OK:") }?.endsWith(":1") == true
    }
}
