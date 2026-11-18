import Darwin
import Foundation

public enum MountOperationError: LocalizedError, Sendable {
    case rcloneNotFound
    case invalidConfiguration(String)
    case localFolderNotEmpty(String)
    case mountFailed(String)
    case unmountFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rcloneNotFound:
            return "rclone was not found. Install it with: brew install rclone"
        case .invalidConfiguration(let detail):
            return detail
        case .localFolderNotEmpty(let path):
            return "Local directory is not empty: \(path). Choose a new or empty folder."
        case .mountFailed(let detail):
            return detail
        case .unmountFailed(let detail):
            return detail
        }
    }
}

public enum MountManager {
    public static var defaultConfigFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("SSHDeck")
            .appendingPathComponent("mounts.json")
    }

    public static var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
    }

    public static func findRcloneExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/rclone",
            "/usr/local/bin/rclone"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let result = ProcessRunner.run(
            executable: "/usr/bin/which",
            arguments: ["rclone"],
            timeout: 2
        )
        let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0, !resolved.isEmpty, FileManager.default.isExecutableFile(atPath: resolved) {
            return resolved
        }
        return nil
    }

    public static func loadConfigs(from url: URL = defaultConfigFileURL) -> [FolderMountConfig] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([FolderMountConfig].self, from: data) else {
            return []
        }
        return decoded
    }

    public static func saveConfigs(
        _ configs: [FolderMountConfig],
        to url: URL = defaultConfigFileURL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        try data.write(to: url, options: .atomic)
    }

    public static func activeSystemMounts() -> [SystemMountEntry] {
        let result = ProcessRunner.run(
            executable: "/sbin/mount",
            arguments: [],
            timeout: 3
        )
        guard result.status == 0 else { return [] }
        return parseMountTable(result.stdout)
    }

    public static func parseMountTable(_ output: String) -> [SystemMountEntry] {
        var entries: [SystemMountEntry] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let onRange = line.range(of: " on "),
                  let parenRange = line.range(of: " (", options: .backwards),
                  onRange.upperBound < parenRange.lowerBound else {
                continue
            }

            let source = String(line[..<onRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let localPath = String(line[onRange.upperBound..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let attrs = String(line[parenRange.upperBound...])
            let fsType = attrs
                .split(separator: ",")
                .first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " )")) } ?? "mount"

            guard !localPath.isEmpty,
                  !localPath.hasPrefix("/System/"),
                  localPath != "/",
                  localPath != "/dev" else {
                continue
            }

            entries.append(
                SystemMountEntry(
                    source: source,
                    localPath: localPath,
                    canonicalLocalPath: canonicalPath(localPath),
                    fileSystemType: fsType
                )
            )
        }

        return entries
    }

    public static func canonicalPath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var standardized = url.resolvingSymlinksInPath().standardizedFileURL.path
        if standardized.hasPrefix("/System/Volumes/Data/") {
            standardized = String(standardized.dropFirst("/System/Volumes/Data".count))
        }
        return standardized
    }

    public static func buildItems(
        for host: SSHHost,
        configs: [FolderMountConfig],
        systemMounts: [SystemMountEntry],
        busyStates: [String: MountRuntimeState] = [:],
        errors: [String: String] = [:]
    ) -> [FolderMountItem] {
        let aliasSet = Set(host.allAliases.map { $0.lowercased() })
        let hostConfigs = configs.filter { aliasSet.contains($0.hostAlias.lowercased()) }

        var matchedMountPaths = Set<String>()
        var items: [FolderMountItem] = []

        for config in hostConfigs {
            let expandedLocal = config.expandedLocalPath
            let canonicalLocal = canonicalPath(expandedLocal)
            let activeEntry = systemMounts.first {
                $0.canonicalLocalPath == canonicalLocal || $0.localPath == expandedLocal
            }
            if let activeEntry {
                matchedMountPaths.insert(activeEntry.canonicalLocalPath)
            }

            let id = config.id.uuidString
            let errorMessage = errors[id]
            let runtimeState: MountRuntimeState
            if let busy = busyStates[id] {
                runtimeState = busy
            } else if activeEntry != nil {
                runtimeState = .mounted
            } else if errorMessage != nil {
                runtimeState = .error
            } else {
                runtimeState = .unmounted
            }

            items.append(
                FolderMountItem(
                    id: id,
                    config: config,
                    hostAlias: host.alias,
                    label: config.label.isEmpty ? URL(fileURLWithPath: expandedLocal).lastPathComponent : config.label,
                    remoteDescription: "\(config.hostAlias):\(config.remotePath)",
                    localPath: expandedLocal,
                    displayLocalPath: config.displayLocalPath,
                    fileSystemType: activeEntry?.fileSystemType.uppercased() ?? "NFS (SFTP)",
                    sourceKind: .managedSFTP,
                    state: runtimeState,
                    errorMessage: errorMessage
                )
            )
        }

        // Also surface any external system SMB / NFS mounts matching this host
        let allConfiguredCanonicals = Set(configs.map { canonicalPath($0.expandedLocalPath) })
        for entry in systemMounts where !matchedMountPaths.contains(entry.canonicalLocalPath) &&
            !allConfiguredCanonicals.contains(entry.canonicalLocalPath) {
            if matchesExternalMount(entry, host: host) {
                let id = "external:\(entry.canonicalLocalPath)"
                let busy = busyStates[id]
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let displayLocal = entry.localPath.hasPrefix(home + "/")
                    ? "~" + entry.localPath.dropFirst(home.count)
                    : entry.localPath

                items.append(
                    FolderMountItem(
                        id: id,
                        config: nil,
                        hostAlias: host.alias,
                        label: URL(fileURLWithPath: entry.localPath).lastPathComponent,
                        remoteDescription: entry.source,
                        localPath: entry.localPath,
                        displayLocalPath: displayLocal,
                        fileSystemType: entry.fileSystemType.uppercased(),
                        sourceKind: .externalSystem,
                        state: busy ?? .mounted,
                        errorMessage: errors[id]
                    )
                )
            }
        }

        return items
    }

    private static func matchesExternalMount(_ entry: SystemMountEntry, host: SSHHost) -> Bool {
        let lowerSource = entry.source.lowercased()
        let lowerLocalName = URL(fileURLWithPath: entry.localPath).lastPathComponent.lowercased()
        let lowerHost = host.hostName.lowercased()

        if lowerHost != "127.0.0.1", lowerHost != "localhost", lowerHost != "::1",
           lowerSource.contains(lowerHost) {
            return true
        }

        for candidateAlias in host.allAliases {
            let tokens = candidateAlias
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter {
                    $0.count >= 3 &&
                        !["ssh", "lan", "wan", "workstation", "server", "ethernet", "direct", "cloud", "cluster"].contains($0)
                }

            for token in tokens where lowerLocalName.contains(token) || lowerSource.contains(token) {
                return true
            }
        }
        return false
    }

    public static func mount(config: FolderMountConfig) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let rclone = findRcloneExecutable() else {
                throw MountOperationError.rcloneNotFound
            }

            let alias = config.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let remotePath = config.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let localPath = config.expandedLocalPath.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !alias.isEmpty, !remotePath.isEmpty, !localPath.isEmpty else {
                throw MountOperationError.invalidConfiguration("Host alias, remote path, and local path are required.")
            }

            let canonicalTarget = canonicalPath(localPath)
            if activeSystemMounts().contains(where: { $0.canonicalLocalPath == canonicalTarget || $0.localPath == localPath }) {
                return
            }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: localPath, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw MountOperationError.invalidConfiguration("Local mount path exists and is a file: \(localPath)")
                }
                let children = (try? fm.contentsOfDirectory(atPath: localPath)) ?? []
                if !children.isEmpty {
                    throw MountOperationError.localFolderNotEmpty(localPath)
                }
                // Recreate empty directory inode to prevent stale macOS NFS vnode EBUSY
                try? fm.removeItem(atPath: localPath)
            }

            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
            try? fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

            let volName = sanitizeVolumeName(
                config.label.isEmpty ? URL(fileURLWithPath: localPath).lastPathComponent : config.label
            )
            let logFileURL = logDirectoryURL.appendingPathComponent("sshdeck-rclone-\(volName).log")
            let dedicatedSFTPPort: String = {
                let lower = alias.lowercased()
                let configuredTunnels = TunnelManager.loadConfigs()
                if let sftpTunnel = configuredTunnels.first(where: {
                    $0.hostAlias.lowercased() == lower &&
                        $0.role == .custom &&
                        $0.label.localizedCaseInsensitiveContains("sftp")
                }),
                   let port = sftpTunnel.primaryLocalPort,
                   TunnelManager.isTCPPortOpen(port: port, timeoutMs: 80) {
                    return "-o Port=\(port) "
                }
                return ""
            }()
            let sshCommand = "/usr/bin/ssh \(dedicatedSFTPPort)-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o IPQoS=none -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ClearAllForwardings=yes \(Shell.quote(alias))"

            let result = ProcessRunner.run(
                executable: rclone,
                arguments: [
                    "nfsmount",
                    ":sftp:\(remotePath)",
                    localPath,
                    "--sftp-ssh", sshCommand,
                    "--sftp-known-hosts-file", "none",
                    "--vfs-cache-mode", "writes",
                    "--dir-cache-time", "30s",
                    "--transfers", "2",
                    "--checkers", "2",
                    "--volname", volName,
                    "--daemon",
                    "--log-file", logFileURL.path
                ],
                discardOutput: true,
                timeout: 22
            )

            if result.status == 0 {
                let mountedNow = activeSystemMounts().contains {
                    $0.canonicalLocalPath == canonicalTarget || $0.localPath == localPath
                }
                if mountedNow {
                    return
                }
            }

            let errDetail = extractMountError(stderr: result.stderr, logURL: logFileURL)
            throw MountOperationError.mountFailed(errDetail)
        }.value
    }

    public static func unmount(localPath: String, sourceKind: MountSourceKind) async throws {
        try await Task.detached(priority: .userInitiated) {
            let expanded = (localPath as NSString).expandingTildeInPath
            let canonicalTarget = canonicalPath(expanded)

            if sourceKind == .managedSFTP {
                let pids = findRclonePIDs(forLocalPath: expanded, canonicalLocalPath: canonicalTarget)
                for pid in pids {
                    _ = kill(pid, SIGINT)
                }

                // Wait up to ~3.5s for rclone's built-in clean NFS unmount
                for _ in 0..<14 {
                    usleep(250_000)
                    let stillMounted = activeSystemMounts().contains {
                        $0.canonicalLocalPath == canonicalTarget || $0.localPath == expanded
                    }
                    let alivePIDs = pids.filter { kill($0, 0) == 0 }
                    if !stillMounted && alivePIDs.isEmpty {
                        refreshEmptyDirectoryInode(at: expanded)
                        return
                    }
                }
            }

            // Fallback to diskutil unmount / force unmount
            var currentlyMounted = activeSystemMounts().contains {
                $0.canonicalLocalPath == canonicalTarget || $0.localPath == expanded
            }

            if currentlyMounted {
                let polite = ProcessRunner.run(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["unmount", expanded],
                    timeout: 8
                )
                if polite.status != 0 {
                    _ = ProcessRunner.run(
                        executable: "/usr/sbin/diskutil",
                        arguments: ["unmount", "force", expanded],
                        timeout: 8
                    )
                }
            }

            if sourceKind == .managedSFTP {
                for pid in findRclonePIDs(forLocalPath: expanded, canonicalLocalPath: canonicalTarget) {
                    _ = kill(pid, SIGTERM)
                }
                usleep(300_000)
            }

            currentlyMounted = activeSystemMounts().contains {
                $0.canonicalLocalPath == canonicalTarget || $0.localPath == expanded
            }
            if currentlyMounted {
                throw MountOperationError.unmountFailed(
                    "Volume is busy (close open files or Finder/Terminal tabs in \(expanded) and retry)."
                )
            }

            if sourceKind == .managedSFTP {
                refreshEmptyDirectoryInode(at: expanded)
            }
        }.value
    }

    public static func suggestedLocalPath(hostAlias: String, remotePath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cleanedRemote = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let folderName = URL(fileURLWithPath: "/" + cleanedRemote).lastPathComponent
        let cleanHost = hostAlias
            .replacingOccurrences(of: "workstation-", with: "")
            .replacingOccurrences(of: "-direct", with: "")
            .uppercased()
        let suffix = (folderName.isEmpty || folderName == "/" || folderName == "~") ? "home" : folderName
        return "\(home)/\(cleanHost)-\(suffix)"
    }

    private static func findRclonePIDs(forLocalPath localPath: String, canonicalLocalPath: String) -> [pid_t] {
        let result = ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 3
        )
        guard result.status == 0 else { return [] }

        var pids: [pid_t] = []
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("rclone"), trimmed.contains("nfsmount") else { continue }
            guard trimmed.contains(localPath) || trimmed.contains(canonicalLocalPath) else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if let first = parts.first, let pid = Int32(first) {
                pids.append(pid)
            }
        }
        return pids
    }

    private static func refreshEmptyDirectoryInode(at path: String) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path), children.isEmpty else {
            return
        }
        try? fm.removeItem(atPath: path)
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private static func sanitizeVolumeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "SSHDeckMount" : cleaned
    }

    private static func extractMountError(stderr: String, logURL: URL) -> String {
        let stdLines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let last = stdLines.last {
            return last
        }

        if let logText = try? String(contentsOf: logURL, encoding: .utf8) {
            let relevant = logText
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.contains("CRITICAL") || $0.contains("ERROR") || $0.contains("Fatal") }
            if let last = relevant.last {
                return last
            }
        }

        return "Failed to mount remote directory via SFTP/NFS (verify SSH access and remote path)."
    }
}
