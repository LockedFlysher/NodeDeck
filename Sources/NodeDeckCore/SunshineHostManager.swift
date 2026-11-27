import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum SunshineHostState: String, Equatable, Sendable {
    case notInstalled
    case stopped
    case running
}

public struct LocalHostPermissionStatus: Equatable, Sendable {
    public let screenRecording: Bool
    public let accessibility: Bool
    public let sshRemoteLogin: Bool
    public let lastLogHint: String?

    public var allReadyForDesktop: Bool {
        screenRecording && accessibility
    }

    public init(
        screenRecording: Bool = false,
        accessibility: Bool = false,
        sshRemoteLogin: Bool = false,
        lastLogHint: String? = nil
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.sshRemoteLogin = sshRemoteLogin
        self.lastLogHint = lastLogHint
    }
}

public final class SunshineHostManager: @unchecked Sendable {
    public static let shared = SunshineHostManager()

    private static let autoStartKey = "nodedeck.localHost.autoStartEnabled"

    private let lock = NSLock()
    private var managedProcess: Process?

    private init() {}

    public static var isAutoStartEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoStartKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoStartKey) }
    }

    public static var bundledBinaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/nodedeck-host")
            .path
    }

    public static var legacyBundledAppBinaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/nodedeck-host")
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
            legacyBundledAppBinaryPath,
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
        FileManager.default.isExecutableFile(atPath: legacyBundledAppBinaryPath)
    }

    public static func checkPermissions() -> LocalHostPermissionStatus {
        let screenOk = CGPreflightScreenCaptureAccess()
        let axOk = AXIsProcessTrusted()
        let sshOk = isLocalPortOpen(22)
        var logHint: String? = nil
        if let logData = try? Data(contentsOf: hostLogFileURL),
           let logStr = String(data: logData.suffix(8192), encoding: .utf8) {
            if logStr.contains("Found H.264 encoder") || logStr.contains("Found HEVC encoder") {
                logHint = nil
            } else if logStr.contains("No screen capture permission") || logStr.contains("TCC") {
                logHint = "TCC_DENIED"
            } else if logStr.contains("Unable to find display or encoder") {
                logHint = "ENCODER_FAILED"
            }
        }
        return LocalHostPermissionStatus(
            screenRecording: screenOk,
            accessibility: axOk,
            sshRemoteLogin: sshOk,
            lastLogHint: logHint
        )
    }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func isLocalPortOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    private static func unloadLegacyLaunchAgentIfPresent() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.nodedeck.host.plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            _ = ProcessRunner.run(
                executable: "/bin/launchctl",
                arguments: ["bootout", "gui/\(getuid())", plist.path],
                timeout: 3
            )
            try? FileManager.default.removeItem(at: plist)
        }
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
        Self.unloadLegacyLaunchAgentIfPresent()
        if currentState() == .running {
            let isManaged = lock.withLock { managedProcess?.isRunning == true }
            if isManaged {
                return lock.withLock { managedProcess?.processIdentifier ?? 0 }
            }
            // Replace unmanaged/legacy host process so TCC attributes cleanly to NodeDeck.app
            stopHost()
            usleep(350_000)
        }

        let confURL = try Self.ensureDefaultConfig()
        let logURL = Self.hostLogFileURL
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: logURL)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [confURL.path]
        proc.currentDirectoryURL = Self.hostConfigDirectoryURL
        proc.standardOutput = logHandle ?? FileHandle.nullDevice
        proc.standardError = logHandle ?? FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] exited in
            guard let self else { return }
            let shouldRespawn: Bool = self.lock.withLock {
                if self.managedProcess === exited {
                    self.managedProcess = nil
                    return Self.isAutoStartEnabled
                }
                return false
            }
            if shouldRespawn {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if Self.isAutoStartEnabled && self.currentState() == .stopped {
                        _ = try? self.startHost()
                    }
                }
            }
        }

        try proc.run()
        Self.isAutoStartEnabled = true
        lock.withLock {
            managedProcess = proc
        }
        return proc.processIdentifier
    }

    /// Injects authenticated account clients' public Moonlight X.509 certificates into local
    /// macOS NodeDeckHost's `host_state.json` so same-account devices pair automatically.
    @discardableResult
    public func syncAccountClientCertificates(_ certs: [ControlPlaneClientCert]) -> Bool {
        guard !certs.isEmpty else { return false }
        _ = try? Self.ensureDefaultConfig()
        let stateURL = Self.hostConfigDirectoryURL.appendingPathComponent("host_state.json")

        var state: [String: Any] = [:]
        if let data = try? Data(contentsOf: stateURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state = parsed
        }
        var root = (state["root"] as? [String: Any]) ?? [:]
        if (root["uniqueid"] as? String)?.isEmpty ?? true {
            root["uniqueid"] = UUID().uuidString.uppercased()
        }
        var devices = (root["named_devices"] as? [[String: Any]]) ?? []
        var existingCerts = Set(devices.compactMap { ($0["cert"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) })

        var changed = false
        for cert in certs {
            let pem = cert.certPem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard pem.contains("BEGIN CERTIFICATE"), !existingCerts.contains(pem) else { continue }
            let devName = cert.deviceName.isEmpty ? "NodeDeck-Client" : cert.deviceName
            devices.removeAll { ($0["name"] as? String) == devName }
            devices.append([
                "name": devName,
                "uuid": UUID().uuidString.uppercased(),
                "cert": pem + "\n"
            ])
            existingCerts.insert(pem)
            changed = true
        }

        guard changed else { return false }
        root["named_devices"] = devices
        state["root"] = root

        if let outData = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? outData.write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }

        if currentState() == .running {
            stopHost()
            usleep(400_000)
            _ = try? startHost()
        }
        return true
    }

    public func stopHost() {
        Self.unloadLegacyLaunchAgentIfPresent()
        let proc = lock.withLock { () -> Process? in
            let p = managedProcess
            managedProcess = nil
            return p
        }
        if let proc, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-f", "NodeDeckHost\\.app/Contents/MacOS/nodedeck-host"], timeout: 3)
        _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-f", "Contents/Helpers/nodedeck-host"], timeout: 3)
        _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-x", "nodedeck-host"], timeout: 3)
        _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-x", "sunshine"], timeout: 3)
    }
}
