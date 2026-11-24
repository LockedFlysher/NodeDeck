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

/// Fast SSH-multiplexed clipboard bridge between macOS NSPasteboard and remote Linux (Wayland / X11).
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

    public static func pushText(
        _ text: String,
        to hostAlias: String,
        preferredDisplay: String? = nil
    ) async throws {
        let byteCount = text.utf8.count
        guard byteCount <= maxBytes else {
            throw ClipboardSyncError.payloadTooLarge(byteCount)
        }

        let displayHint = sanitizedDisplay(preferredDisplay)
        let remoteScript = """
        DISP='\(displayHint)'
        if [ -z "$DISP" ] && [ -f "$HOME/.config/nodedeck/host-profile.json" ]; then
          DISP=$(python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.config/nodedeck/host-profile.json"))); print(d.get("display",""))' 2>/dev/null)
        fi
        DISP="${DISP:-:0}"
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
          wl-copy
        elif command -v xclip >/dev/null 2>&1; then
          DISPLAY="$DISP" xclip -selection clipboard -in
        elif command -v xsel >/dev/null 2>&1; then
          DISPLAY="$DISP" xsel --clipboard --input
        else
          echo "No clipboard tool found (install xclip, xsel, or wl-clipboard)" >&2
          exit 127
        fi
        """

        try await Task.detached(priority: .userInitiated) {
            let res = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: baseSSHArgs(for: hostAlias) + ["/bin/sh", "-c", remoteScript],
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
        let displayHint = sanitizedDisplay(preferredDisplay)
        let remoteScript = """
        DISP='\(displayHint)'
        if [ -z "$DISP" ] && [ -f "$HOME/.config/nodedeck/host-profile.json" ]; then
          DISP=$(python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.config/nodedeck/host-profile.json"))); print(d.get("display",""))' 2>/dev/null)
        fi
        DISP="${DISP:-:0}"
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then
          wl-paste --no-newline 2>/dev/null
        elif command -v xclip >/dev/null 2>&1; then
          DISPLAY="$DISP" xclip -selection clipboard -out 2>/dev/null
        elif command -v xsel >/dev/null 2>&1; then
          DISPLAY="$DISP" xsel --clipboard --output 2>/dev/null
        else
          echo "No clipboard tool found (install xclip, xsel, or wl-clipboard)" >&2
          exit 127
        fi
        """

        return try await Task.detached(priority: .userInitiated) {
            let res = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: baseSSHArgs(for: hostAlias) + ["/bin/sh", "-c", remoteScript],
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
