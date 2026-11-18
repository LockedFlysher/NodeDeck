import AppKit
import Foundation
import SSHDeckCore

enum TerminalLauncher {
    @discardableResult
    static func openTerminal(for host: SSHHost) -> String? {
        runCommandInTerminal(host.terminalCommand)
    }

    @discardableResult
    static func openLocalDirectoryInTerminal(_ localPath: String) -> String? {
        let expanded = (localPath as NSString).expandingTildeInPath
        let result = ProcessRunner.run(
            executable: "/usr/bin/open",
            arguments: ["-a", "Terminal", expanded],
            timeout: 5
        )
        if result.status == 0 {
            return nil
        }
        return runCommandInTerminal("cd \(Shell.quote(expanded)) && clear && pwd && ls -la")
    }

    @discardableResult
    static func openInFinder(_ localPath: String) -> String? {
        let expanded = (localPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return "Folder does not exist on disk: \(expanded)"
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        if NSWorkspace.shared.open(url) {
            return nil
        }
        return "Finder could not open \(expanded)"
    }

    static func copyCommand(for host: SSHHost) {
        copyText(host.terminalCommand)
    }

    static func copyText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private static func runCommandInTerminal(_ command: String) -> String? {
        let escaped = appleScriptString(command)
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            let summary = (error[NSAppleScript.errorBriefMessage] as? String)
                ?? (error[NSAppleScript.errorMessage] as? String)
                ?? "Allow SSH Deck to control Terminal in System Settings → Privacy & Security → Automation."
            return summary
        }
        return nil
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
