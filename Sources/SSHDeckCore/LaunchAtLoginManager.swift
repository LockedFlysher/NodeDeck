import Foundation

public enum LaunchAtLoginManager {
    public static let agentLabel = "io.sshdeck.app"

    public static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    public static func resolvedExecutablePath() -> String {
        let installedAppExec = "/Applications/SSH Deck.app/Contents/MacOS/SSHDeck"
        if FileManager.default.isExecutableFile(atPath: installedAppExec) {
            return installedAppExec
        }
        let userInstalledExec = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Applications/SSH Deck.app/Contents/MacOS/SSHDeck")
        if FileManager.default.isExecutableFile(atPath: userInstalledExec) {
            return userInstalledExec
        }
        if let bundleExec = Bundle.main.executablePath,
           bundleExec.contains(".app/Contents/MacOS/"),
           FileManager.default.isExecutableFile(atPath: bundleExec) {
            return bundleExec
        }
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    public static func isEnabled(plistURL: URL = launchAgentPlistURL) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return false
        }
        return (plist["RunAtLoad"] as? Bool) ?? false
    }

    public static func setEnabled(
        _ enabled: Bool,
        executablePath: String? = nil,
        plistURL: URL = launchAgentPlistURL
    ) throws {
        if enabled {
            let dir = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let exec = executablePath ?? resolvedExecutablePath()
            let logPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/sshdeck-autostart.log").path
            let dict: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exec, "--background"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "StandardOutPath": logPath,
                "StandardErrorPath": logPath
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        }
    }
}
