import Darwin
import Foundation

public enum ClipboardSyncError: LocalizedError {
    case sshFailed(String)
    case emptyClipboard
    case payloadTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .sshFailed(let msg): return msg
        case .emptyClipboard: return "Remote clipboard is empty."
        case .payloadTooLarge(let bytes): return "Clipboard text too large (\(bytes / 1024) KB, limit 256 KB)."
        }
    }
}

/// Fast SSH-multiplexed bidirectional clipboard bridge between macOS NSPasteboard and remote Linux (X11 / Wayland) or macOS hosts.
public enum ClipboardSyncManager {
    public static let maxBytes = 256 * 1024

    private static var controlSocketDirectory: String {
        "/tmp/ndmux-\(getuid())"
    }

    private static var controlPathTemplate: String {
        "\(controlSocketDirectory)/%C"
    }

    private static func ensureControlDirectory() {
        let dir = controlSocketDirectory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private static func baseSSHArgs(for hostAlias: String) -> [String] {
        ensureControlDirectory()
        return [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPathTemplate)",
            "-o", "ControlPersist=60",
            "-o", "ConnectTimeout=4",
            "-o", "ClearAllForwardings=yes",
            "-o", "LogLevel=ERROR",
            hostAlias
        ]
    }

    /// Resolves configured X11 display (e.g. ":99") from saved LinuxHostProfile when isolated virtual Xorg mode is active.
    public static func resolvePreferredDisplay(for hostAlias: String) -> String? {
        let profiles = LinuxHostProfileManager.loadProfiles()
        guard let match = profiles.first(where: {
            $0.hostAlias.caseInsensitiveCompare(hostAlias) == .orderedSame
        }), match.mode == .isolatedVirtualDesktop else {
            return nil
        }
        let d = sanitizedDisplay(match.display)
        return d.isEmpty ? nil : d
    }

    /// Shared remote shell prologue that auto-detects DISPLAY, XAUTHORITY, WAYLAND_DISPLAY, and XDG_RUNTIME_DIR
    /// from the user's live systemd user session or desktop process so isolated virtual displays (e.g. :99) and
    /// GDM sessions (e.g. :0 with /run/user/$UID/gdm/Xauthority) both work seamlessly.
    private static func displayDetectionPrologue(displayHint: String) -> String {
        """
        export LC_ALL="${LC_ALL:-C.UTF-8}"
        DISP='\(displayHint)'
        XAUTH=''
        WDISP=''
        XRDIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        [ -d "$XRDIR" ] && export XDG_RUNTIME_DIR="$XRDIR"
        if [ -z "$DISP" ] && [ -f "$HOME/.config/nodedeck/host-profile.json" ]; then
          DISP=$(python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.config/nodedeck/host-profile.json"))); print(d.get("display","") if d.get("mode")=="isolatedVirtualDesktop" else "")' 2>/dev/null)
        fi
        if [ -n "$DISP" ]; then
          dnum="${DISP#:}"; dnum="${dnum%%.*}"
          [ -S "/tmp/.X11-unix/X$dnum" ] || DISP=''
        fi
        if command -v systemctl >/dev/null 2>&1; then
          sysenv=$(systemctl --user show-environment 2>/dev/null)
          sys_disp=$(printf '%s\\n' "$sysenv" | sed -n 's/^DISPLAY=//p' | head -n1)
          sys_xauth=$(printf '%s\\n' "$sysenv" | sed -n 's/^XAUTHORITY=//p' | head -n1)
          sys_wdisp=$(printf '%s\\n' "$sysenv" | sed -n 's/^WAYLAND_DISPLAY=//p' | head -n1)
          if [ -z "$DISP" ] && [ -n "$sys_disp" ]; then
            DISP="$sys_disp"
            XAUTH="$sys_xauth"
            WDISP="$sys_wdisp"
          elif [ -n "$DISP" ] && [ "$DISP" = "$sys_disp" ]; then
            XAUTH="$sys_xauth"
            WDISP="$sys_wdisp"
          fi
        fi
        if [ -z "$DISP" ] || [ -z "$XAUTH" ]; then
          for pid in $(pgrep -u "$(id -u)" -f "nodedeck-host|sunshine|gnome-session|xfce4-session|plasmashell|mate-session|cinnamon|openbox|i3|sway|hyprland" 2>/dev/null); do
            [ -r "/proc/$pid/environ" ] || continue
            envdata=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null) || continue
            p_disp=$(printf '%s\\n' "$envdata" | sed -n 's/^DISPLAY=//p' | head -n1)
            p_xauth=$(printf '%s\\n' "$envdata" | sed -n 's/^XAUTHORITY=//p' | head -n1)
            p_wdisp=$(printf '%s\\n' "$envdata" | sed -n 's/^WAYLAND_DISPLAY=//p' | head -n1)
            if [ -z "$DISP" ] && [ -n "$p_disp" ]; then
              DISP="$p_disp"
              XAUTH="$p_xauth"
              WDISP="$p_wdisp"
              break
            elif [ -n "$DISP" ] && [ "$DISP" = "$p_disp" ] && [ -n "$p_xauth" ]; then
              XAUTH="$p_xauth"
              [ -z "$WDISP" ] && WDISP="$p_wdisp"
              break
            fi
          done
        fi
        if [ -z "$XAUTH" ] && [ -f "$HOME/.Xauthority" ]; then
          XAUTH="$HOME/.Xauthority"
        fi
        if [ -z "$DISP" ]; then
          for sock in /tmp/.X11-unix/X*; do
            [ -S "$sock" ] || continue
            cand=":${sock##*X}"
            if DISPLAY="$cand" XAUTHORITY="$XAUTH" xclip -o -selection clipboard >/dev/null 2>&1 || DISPLAY="$cand" XAUTHORITY="$XAUTH" xset q >/dev/null 2>&1; then
              DISP="$cand"
              break
            fi
          done
        fi
        DISP="${DISP:-:0}"
        export DISPLAY="$DISP"
        [ -n "$XAUTH" ] && export XAUTHORITY="$XAUTH"
        [ -n "$WDISP" ] && export WAYLAND_DISPLAY="$WDISP"
        [ -d "$XRDIR" ] && export XDG_RUNTIME_DIR="$XRDIR"
        """
    }

    public static func pushText(
        _ text: String,
        to hostAlias: String,
        preferredDisplay: String? = nil
    ) async throws {
        let byteCount = text.utf8.count
        guard byteCount <= maxBytes else {
            throw ClipboardSyncError.payloadTooLarge(byteCount)
        }

        let resolvedHint = sanitizedDisplay(preferredDisplay ?? resolvePreferredDisplay(for: hostAlias))
        let remoteScript = """
        if command -v pbcopy >/dev/null 2>&1; then
          pbcopy
          exit $?
        fi
        \(displayDetectionPrologue(displayHint: resolvedHint))
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
          wl-copy >/dev/null 2>&1
        elif command -v xclip >/dev/null 2>&1; then
          # Redirect stdout/stderr to /dev/null so xclip's background selection owner does not hold SSH pipes open!
          xclip -selection clipboard -in >/dev/null 2>&1
        elif command -v xsel >/dev/null 2>&1; then
          xsel --clipboard --input >/dev/null 2>&1
        else
          echo "No clipboard tool found (install xclip, xsel, or wl-clipboard)" >&2
          exit 127
        fi
        """

        try await Task.detached(priority: .userInitiated) {
            let res = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: baseSSHArgs(for: hostAlias) + ["/bin/sh -c \(Shell.quote(remoteScript))"],
                input: text,
                timeout: 6
            )
            if res.timedOut {
                throw ClipboardSyncError.sshFailed("Clipboard push timed out.")
            }
            if res.status != 0 {
                let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ClipboardSyncError.sshFailed(err.isEmpty ? "Remote clipboard write failed (exit \(res.status))." : err)
            }
        }.value
    }

    public static func pullText(
        from hostAlias: String,
        preferredDisplay: String? = nil
    ) async throws -> String {
        let resolvedHint = sanitizedDisplay(preferredDisplay ?? resolvePreferredDisplay(for: hostAlias))
        let remoteScript = """
        if command -v pbpaste >/dev/null 2>&1; then
          pbpaste
          exit $?
        fi
        \(displayDetectionPrologue(displayHint: resolvedHint))
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then
          wl-paste --no-newline 2>/dev/null
        elif command -v xclip >/dev/null 2>&1; then
          xclip -selection clipboard -out 2>/dev/null
        elif command -v xsel >/dev/null 2>&1; then
          xsel --clipboard --output 2>/dev/null
        else
          echo "No clipboard tool found (install xclip, xsel, or wl-clipboard)" >&2
          exit 127
        fi
        """

        return try await Task.detached(priority: .userInitiated) {
            let res = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: baseSSHArgs(for: hostAlias) + ["/bin/sh -c \(Shell.quote(remoteScript))"],
                timeout: 6
            )
            if res.timedOut {
                throw ClipboardSyncError.sshFailed("Clipboard pull timed out.")
            }
            if res.status != 0 {
                let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if err.isEmpty {
                    throw ClipboardSyncError.emptyClipboard
                }
                throw ClipboardSyncError.sshFailed(err)
            }
            if res.stdout.isEmpty {
                throw ClipboardSyncError.emptyClipboard
            }
            return res.stdout
        }.value
    }

    private static func sanitizedDisplay(_ display: String?) -> String {
        guard let d = display?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else {
            return ""
        }
        // Only allow standard X11 display characters like :99 or :0.0
        let allowed = CharacterSet(charactersIn: ":0123456789.")
        guard d.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return ""
        }
        return d
    }
}
