import Darwin
import Foundation

public enum SunshineHostState: String, Equatable, Sendable {
    case notInstalled
    case stopped
    case running
}

public final class SunshineHostManager: @unchecked Sendable {
    public static let shared = SunshineHostManager()

    private let lock = NSLock()
    private var managedProcess: Process?

    private init() {}

    public static var bundledBinaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NodeDeckHost.app/Contents/MacOS/nodedeck-host")
            .path
    }

    public static var hostConfigDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NodeDeck/host", isDirectory: true)
    }

    public static var hostConfigFileURL: URL {
        hostConfigDirectoryURL.appendingPathComponent("host.conf")
    }

    public static var hostLogFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nodedeck-host.log")
    }

    public static var candidateBinaries: [String] {
        [
            bundledBinaryPath,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nodedeck-host").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sunshine").path,
            "/opt/nodedeck/host/bin/nodedeck-host",
            "/opt/homebrew/bin/sunshine",
            "/usr/local/bin/sunshine",
            "/usr/bin/sunshine"
        ]
    }

    public static func findBinary() -> String? {
        candidateBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isBundledHostAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: bundledBinaryPath) ||
        FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nodedeck-host").path)
    }

    public func currentState() -> SunshineHostState {
        guard Self.findBinary() != nil else { return .notInstalled }
        let isManagedRunning = lock.withLock { managedProcess?.isRunning == true }
        if isManagedRunning { return .running }

        let pgrep = ProcessRunner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "NodeDeckHost\\.app/Contents/MacOS/nodedeck-host|(^|/)nodedeck-host($| )|(^|/)sunshine($| )"],
            timeout: 2
        )
        return pgrep.status == 0 ? .running : .stopped
    }

    private static func ensureDefaultConfig() throws -> URL {
        let dir = hostConfigDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let appsURL = dir.appendingPathComponent("apps.json")
        if !FileManager.default.fileExists(atPath: appsURL.path) {
            let appsJSON = """
            {
              "env": {},
              "apps": [
                {
                  "name": "Desktop",
                  "image-path": "desktop.png"
                }
              ]
            }
            """
            try appsJSON.write(to: appsURL, atomically: true, encoding: .utf8)
        }

        let confURL = hostConfigFileURL
        if !FileManager.default.fileExists(atPath: confURL.path) {
            let statePath = dir.appendingPathComponent("host_state.json").path
            let credsPath = dir.appendingPathComponent("credentials.json").path
            let pkeyPath = dir.appendingPathComponent("host.key").path
            let certPath = dir.appendingPathComponent("host.cert").path
            let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let content = """
            # Managed by NodeDeck Built-in Host
            sunshine_name = \(hostName)
            port = 47989
            file_apps = \(appsURL.path)
            file_state = \(statePath)
            credentials_file = \(credsPath)
            pkey = \(pkeyPath)
            cert = \(certPath)
            """
            try content.write(to: confURL, atomically: true, encoding: .utf8)
        }
        return confURL
    }

    @discardableResult
    public func startHost() throws -> Int32 {
        guard let bin = Self.findBinary() else {
            throw SunshineError.launchFailed("Built-in host binary is missing. Run scripts/build-host-macos.sh and rebuild NodeDeck.")
        }
        if currentState() == .running {
            return lock.withLock { managedProcess?.processIdentifier ?? 0 }
        }

        let confURL = try Self.ensureDefaultConfig()
        let logURL = Self.hostLogFileURL
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [confURL.path]
        proc.currentDirectoryURL = Self.hostConfigDirectoryURL
        proc.standardOutput = logHandle ?? FileHandle.nullDevice
        proc.standardError = logHandle ?? FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        try proc.run()
        lock.withLock {
            managedProcess = proc
        }
        return proc.processIdentifier
    }

    public func stopHost() {
        let proc = lock.withLock { () -> Process? in
            let p = managedProcess
            managedProcess = nil
            return p
        }
        if let proc, proc.isRunning {
            proc.terminate()
        } else {
            _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-f", "NodeDeckHost\\.app/Contents/MacOS/nodedeck-host"], timeout: 3)
            _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-x", "nodedeck-host"], timeout: 3)
            _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-x", "sunshine"], timeout: 3)
        }
    }
}
