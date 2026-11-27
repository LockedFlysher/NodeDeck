package com.nodedeck.android.core

import android.util.Base64

class ClipboardSyncManager(private val sshManager: SshManager) {
    suspend fun pushText(text: String, host: SSHHost, allHosts: List<SSHHost>) {
        if (text.isEmpty()) return
        val b64 = Base64.encodeToString(text.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val cmd = """
            b64='$b64'
            if command -v wl-copy >/dev/null 2>&1 && [ -n "${'$'}{WAYLAND_DISPLAY:-}" ]; then
              printf '%s' "${'$'}b64" | base64 -d | wl-copy
              exit 0
            fi
            for d in :99 :0 :1; do
              if DISPLAY=${'$'}d XAUTHORITY="${'$'}HOME/.Xauthority" xclip -selection clipboard -o >/dev/null 2>&1 || [ -S "/tmp/.X11-unix/X${'$'}{d#:}" ]; then
                if command -v xclip >/dev/null 2>&1; then
                  printf '%s' "${'$'}b64" | base64 -d | DISPLAY=${'$'}d XAUTHORITY="${'$'}HOME/.Xauthority" xclip -selection clipboard -in
                  exit 0
                elif command -v xsel >/dev/null 2>&1; then
                  printf '%s' "${'$'}b64" | base64 -d | DISPLAY=${'$'}d XAUTHORITY="${'$'}HOME/.Xauthority" xsel --clipboard --input
                  exit 0
                fi
              fi
            done
            echo "NO_CLIPBOARD_TOOL" >&2
            exit 1
        """.trimIndent()
        val res = sshManager.exec(host, allHosts, "/bin/sh -s", stdinText = cmd, timeoutMs = 8_000)
        if (res.exitCode != 0) {
            throw IllegalStateException(res.stderr.trim().ifBlank { "Remote clipboard push failed" })
        }
    }

    suspend fun pullText(host: SSHHost, allHosts: List<SSHHost>): String {
        val cmd = """
            if command -v wl-paste >/dev/null 2>&1 && [ -n "${'$'}{WAYLAND_DISPLAY:-}" ]; then
              wl-paste --no-newline 2>/dev/null | base64 -w 0
              exit 0
            fi
            for d in :99 :0 :1; do
              if [ -S "/tmp/.X11-unix/X${'$'}{d#:}" ]; then
                if command -v xclip >/dev/null 2>&1; then
                  DISPLAY=${'$'}d XAUTHORITY="${'$'}HOME/.Xauthority" xclip -selection clipboard -o 2>/dev/null | base64 -w 0
                  exit 0
                elif command -v xsel >/dev/null 2>&1; then
                  DISPLAY=${'$'}d XAUTHORITY="${'$'}HOME/.Xauthority" xsel --clipboard --output 2>/dev/null | base64 -w 0
                  exit 0
                fi
              fi
            done
            exit 1
        """.trimIndent()
        val res = sshManager.exec(host, allHosts, "/bin/sh -s", stdinText = cmd, timeoutMs = 8_000)
        if (res.exitCode != 0) {
            throw IllegalStateException(res.stderr.trim().ifBlank { "Remote clipboard pull failed" })
        }
        val raw = res.stdout.trim()
        if (raw.isEmpty()) return ""
        return String(Base64.decode(raw, Base64.DEFAULT), Charsets.UTF_8)
    }
}
