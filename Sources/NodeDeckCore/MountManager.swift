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
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
        let nodeDeckFile = appSupport
            .appendingPathComponent("NodeDeck")
            .appendingPathComponent("mounts.json")
        let legacyFile = appSupport
            .appendingPathComponent("SSHDeck")
            .appendingPathComponent("mounts.json")
        if !FileManager.default.fileExists(atPath: nodeDeckFile.path),
           FileManager.default.fileExists(atPath: legacyFile.path) {
            try? FileManager.default.createDirectory(
                at: nodeDeckFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: legacyFile, to: nodeDeckFile)
        }
        return nodeDeckFile
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
        let entries = rawSystemMounts()
        let zombies = entries.filter { entry in
            entry.source == "localhost:/" &&
                entry.fileSystemType.lowercased() == "nfs" &&
                findRclonePIDs(forLocalPath: entry.localPath, canonicalLocalPath: entry.canonicalLocalPath).isEmpty
        }
        guard !zombies.isEmpty else { return entries }

        for zombie in zombies {
            _ = ProcessRunner.run(
                executable: "/sbin/umount",
                arguments: ["-f", zombie.localPath],
                timeout: 4
            )
        }
        return rawSystemMounts()
    }

    private static func rawSystemMounts() -> [SystemMountEntry] {
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
        // Pass explicit isDirectory: false so Foundation does not call lstat() on the leaf path
        // (which can deadlock the main thread if the path is an unresponsive remote NFS/SMB mount).
        let standardizedURL = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
        let path = standardizedURL.path
        guard path != "/" else { return "/" }

        // Resolve symlinks only on the parent directory so we never issue kernel stat/getattrlist
        // RPCs into a potentially unresponsive remote NFS/SMB mount root.
        let parentResolved = standardizedURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var standardized = parentResolved
            .appendingPathComponent(standardizedURL.lastPathComponent, isDirectory: false)
            .standardizedFileURL
            .path
        if standardized.hasPrefix("/System/Volumes/Data/") {
            standardized = String(standardized.dropFirst("/System/Volumes/Data".count))
        }
        return standardized
    }

    public static func resolveSMBEndpoints(for config: FolderMountConfig, host: SSHHost? = nil) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ raw: String) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(cleaned)
        }

        for raw in config.smbEndpoints {
            for part in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
                appendCandidate(String(part))
            }
        }

        if ordered.isEmpty, config.strategy != .sftpOnly, let host {
            let lower = host.hostName.lowercased()
            if host.routeKind == .directLAN, !lower.hasPrefix("fe80:") {
                appendCandidate(host.hostName)
            }
        }

        return ordered
    }

    public static func resolveSMBShares(for config: FolderMountConfig, user: String) -> [String] {
        var candidates: [String] = []
        if let explicit = config.smbShare?.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n")),
           !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let inferred = FolderMountConfig.inferredSMBShare(from: config.remotePath, user: user),
           !inferred.isEmpty,
           !candidates.contains(inferred) {
            candidates.append(inferred)
        }
        let cleanRemote = config.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let homePrefix = "/home/\(user)/"
        if cleanRemote.hasPrefix(homePrefix) {
            let rel = String(cleanRemote.dropFirst(homePrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !rel.isEmpty {
                let viaHomeShare = "home/\(rel)"
                if !candidates.contains(viaHomeShare) {
                    candidates.append(viaHomeShare)
                }
            }
        }
        return candidates
    }

    public static func hasKeychainSMBCredential(server: String, account: String) -> Bool {
        let res = ProcessRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-internet-password", "-s", server, "-a", account, "-r", "smb "],
            discardOutput: true,
            timeout: 3
        )
        return res.status == 0
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

            let smbUser = (config.smbUser?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? host.user
            let resolvedEndpoints = resolveSMBEndpoints(for: config, host: host)
            let primaryShare = resolveSMBShares(for: config, user: smbUser).first

            let sourceKind: MountSourceKind
            let fsBadge: String
            let remoteDesc: String

            if let activeEntry {
                let lowerFS = activeEntry.fileSystemType.lowercased()
                if lowerFS == "smbfs" {
                    sourceKind = .managedSMB
                    fsBadge = "SMBFS"
                    remoteDesc = activeEntry.source
                } else {
                    sourceKind = .managedSFTP
                    fsBadge = config.strategy == .smbFirst && !resolvedEndpoints.isEmpty
                        ? "NFS (rclone)"
                        : activeEntry.fileSystemType.uppercased()
                    remoteDesc = "\(config.hostAlias):\(config.remotePath)"
                }
            } else if config.strategy != .sftpOnly, let firstEndpoint = resolvedEndpoints.first {
                sourceKind = .managedSMB
                fsBadge = config.strategy == .smbFirst ? "SMB3 · rclone" : "SMB3"
                if let share = primaryShare {
                    remoteDesc = "//\(smbUser)@\(firstEndpoint)/\(share)"
                } else {
                    remoteDesc = "\(config.hostAlias):\(config.remotePath)"
                }
            } else {
                sourceKind = .managedSFTP
                fsBadge = "NFS (SFTP)"
                remoteDesc = "\(config.hostAlias):\(config.remotePath)"
            }

            items.append(
                FolderMountItem(
                    id: id,
                    config: config,
                    hostAlias: host.alias,
                    label: config.label.isEmpty ? (expandedLocal as NSString).lastPathComponent : config.label,
                    remoteDescription: remoteDesc,
                    localPath: expandedLocal,
                    displayLocalPath: config.displayLocalPath,
                    fileSystemType: fsBadge,
                    sourceKind: sourceKind,
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
                        label: (entry.localPath as NSString).lastPathComponent,
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
        let lowerLocalName = (entry.localPath as NSString).lastPathComponent.lowercased()
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

    public static func mount(
        config: FolderMountConfig,
        host: SSHHost? = nil,
        preferSMBOnlyUpgrade: Bool = false
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
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

            // Reap any orphaned rclone nfsmount daemon left behind for this unmounted path.
            for orphanPID in findRclonePIDs(forLocalPath: localPath, canonicalLocalPath: canonicalTarget) {
                _ = kill(orphanPID, SIGKILL)
            }

            try prepareCleanLocalMountDirectory(at: localPath)
            try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

            let effectiveStrategy: MountStrategy = preferSMBOnlyUpgrade ? .smbOnly : config.strategy

            // Tier 1: Native LAN / Mesh SMB3 (preferred whenever strategy is .smbFirst or .smbOnly)
            var lastSMBError: String?
            if effectiveStrategy != .sftpOnly {
                let smbUser = (config.smbUser?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? host?.user
                    ?? NSUserName()
                let endpoints = resolveSMBEndpoints(for: config, host: host)
                let shares = resolveSMBShares(for: config, user: smbUser)

                for endpoint in endpoints {
                    guard isHostPortReachable(host: endpoint, port: 445, timeoutMs: 450) else {
                        lastSMBError = "SMB TCP 445 unreachable on \(endpoint)"
                        continue
                    }

                    for share in shares {
                        try prepareCleanLocalMountDirectory(at: localPath)
                        switch tryMountSMB(server: endpoint, share: share, account: smbUser, localPath: localPath, canonicalTarget: canonicalTarget) {
                        case .success:
                            return
                        case .failure(let err):
                            lastSMBError = err.message
                        }
                    }
                }

                if effectiveStrategy == .smbOnly {
                    throw MountOperationError.mountFailed(
                        lastSMBError ?? "LAN SMB server is unreachable (verify LAN/EasyTier connection and Keychain SMB password)."
                    )
                }
            }

            // Tier 2: rclone nfsmount over SFTP/SSH (automatic fallback when SMB is unavailable)
            guard let rclone = findRcloneExecutable() else {
                if let lastSMBError {
                    throw MountOperationError.mountFailed("\(lastSMBError); rclone fallback unavailable (brew install rclone).")
                }
                throw MountOperationError.rcloneNotFound
            }

            try prepareCleanLocalMountDirectory(at: localPath)

            let selectedAlias = selectReachableSSHAlias(primary: alias, fallback: config.rcloneFallbackAlias)
            let volName = sanitizeVolumeName(
                config.label.isEmpty ? (localPath as NSString).lastPathComponent : config.label
            )
            let logFileURL = logDirectoryURL.appendingPathComponent("nodedeck-rclone-\(volName).log")
            let dedicatedSFTPPort: String = {
                let lower = selectedAlias.lowercased()
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
            let sshCommand = "/usr/bin/ssh \(dedicatedSFTPPort)-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o IPQoS=none -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o ClearAllForwardings=yes \(Shell.quote(selectedAlias))"

            let result = ProcessRunner.run(
                executable: rclone,
                arguments: buildRcloneArguments(
                    remotePath: remotePath,
                    localPath: localPath,
                    sshCommand: sshCommand,
                    volName: volName,
                    logFilePath: logFileURL.path
                ),
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
            if let lastSMBError {
                throw MountOperationError.mountFailed("SMB unavailable (\(lastSMBError)); rclone fallback failed: \(errDetail)")
            }
            throw MountOperationError.mountFailed(errDetail)
        }.value
    }

    private struct SMBAttemptFailure: Error {
        let message: String
    }

    private static func prepareCleanLocalMountDirectory(at localPath: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: localPath, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw MountOperationError.invalidConfiguration("Local mount path exists and is a file: \(localPath)")
            }
            let children = (try? fm.contentsOfDirectory(atPath: localPath)) ?? []
            let meaningful = children.filter { $0 != ".DS_Store" }
            if !meaningful.isEmpty {
                throw MountOperationError.localFolderNotEmpty(localPath)
            }
            // Recreate empty directory inode (clearing any stray Finder .DS_Store) to prevent stale NFS/SMB EBUSY
            try? fm.removeItem(atPath: localPath)
        }
        try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
    }

    private static func isHostPortReachable(host: String, port: Int, timeoutMs: Int32) -> Bool {
        if TunnelManager.isTCPPortOpen(host: host, port: port, timeoutMs: timeoutMs) {
            return true
        }
        // Fallback for hostname / .local resolution when host is not a dotted IPv4 literal
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) != 1 {
            let sec = max(1, Int((timeoutMs + 999) / 1000))
            let nc = ProcessRunner.run(
                executable: "/usr/bin/nc",
                arguments: ["-z", "-G", "\(sec)", "-w", "\(sec)", host, "\(port)"],
                discardOutput: true,
                timeout: TimeInterval(sec + 1)
            )
            return nc.status == 0
        }
        return false
    }

    private static func tryMountSMB(
        server: String,
        share: String,
        account: String,
        localPath: String,
        canonicalTarget: String
    ) -> Result<Void, SMBAttemptFailure> {
        let pwLookup = ProcessRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-internet-password", "-s", server, "-a", account, "-r", "smb ", "-w"],
            timeout: 4
        )
        let password = pwLookup.stdout.trimmingCharacters(in: CharacterSet.newlines)
        guard pwLookup.status == 0, !password.isEmpty else {
            return .failure(SMBAttemptFailure(message: "Missing macOS Keychain SMB password for \(account)@\(server)"))
        }

        let smbURL = "//\(account)@\(server)/\(share)"
        let expectScript = """
        set timeout 14
        log_user 0
        set url [gets stdin]
        set dst [gets stdin]
        set pw [gets stdin]
        spawn /sbin/mount_smbfs -f 0644 -d 0755 $url $dst
        expect {
            -re {Password[^\\r\\n]*:} {
                send -- "$pw\\r"
                exp_continue
            }
            timeout { exit 124 }
            eof {
                catch wait result
                exit [lindex $result 3]
            }
        }
        """

        let mountRes = ProcessRunner.run(
            executable: "/usr/bin/expect",
            arguments: ["-c", expectScript],
            input: "\(smbURL)\n\(localPath)\n\(password)\n",
            timeout: 16
        )

        let isMountedNow = rawSystemMounts().contains {
            $0.canonicalLocalPath == canonicalTarget || $0.localPath == localPath
        }
        if mountRes.status == 0 && isMountedNow {
            return .success(())
        }

        let detail = mountRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(
            SMBAttemptFailure(
                message: detail.isEmpty
                    ? "mount_smbfs failed for \(smbURL) (exit \(mountRes.status))"
                    : "mount_smbfs failed for \(smbURL): \(detail)"
            )
        )
    }

    private static func selectReachableSSHAlias(primary: String, fallback: String?) -> String {
        guard let fallbackRaw = fallback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallbackRaw.isEmpty,
              fallbackRaw.caseInsensitiveCompare(primary) != .orderedSame
        else {
            return primary
        }

        if isSSHAliasReachable(primary) {
            return primary
        }
        if isSSHAliasReachable(fallbackRaw) {
            return fallbackRaw
        }
        return primary
    }

    private static func isSSHAliasReachable(_ alias: String) -> Bool {
        let probe = ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ConnectTimeout=3",
                "-o", "ConnectionAttempts=1",
                "-o", "ClearAllForwardings=yes",
                alias,
                "true"
            ],
            discardOutput: true,
            timeout: 5
        )
        return probe.status == 0
    }

    public static func unmount(localPath: String, sourceKind: MountSourceKind) async throws {
        try await Task.detached(priority: .userInitiated) {
            let expanded = (localPath as NSString).expandingTildeInPath
            let canonicalTarget = canonicalPath(expanded)

            // Unmount from macOS kernel FIRST while rclone's local NFSv3 server is still alive
            // (killing rclone --daemon first leaves a dead hard NFS mount that hangs stat/Finder).
            var currentlyMounted = rawSystemMounts().contains {
                $0.canonicalLocalPath == canonicalTarget || $0.localPath == expanded
            }

            if currentlyMounted {
                let direct = ProcessRunner.run(
                    executable: "/sbin/umount",
                    arguments: [expanded],
                    timeout: 6
                )
                if direct.status != 0 {
                    let polite = ProcessRunner.run(
                        executable: "/usr/sbin/diskutil",
                        arguments: ["unmount", expanded],
                        timeout: 6
                    )
                    if polite.status != 0 {
                        _ = ProcessRunner.run(
                            executable: "/sbin/umount",
                            arguments: ["-f", expanded],
                            timeout: 6
                        )
                    }
                }
            }

            currentlyMounted = rawSystemMounts().contains {
                $0.canonicalLocalPath == canonicalTarget || $0.localPath == expanded
            }
            if currentlyMounted {
                throw MountOperationError.unmountFailed(
                    "Volume is busy (close open files or Finder/Terminal tabs in \(expanded) and retry)."
                )
            }

            let pids = findRclonePIDs(forLocalPath: expanded, canonicalLocalPath: canonicalTarget)
            if !pids.isEmpty {
                for pid in pids {
                    _ = kill(pid, SIGTERM)
                }
                for _ in 0..<8 {
                    if pids.allSatisfy({ kill($0, 0) != 0 }) { break }
                    usleep(100_000)
                }
                for pid in pids where kill(pid, 0) == 0 {
                    _ = kill(pid, SIGKILL)
                }
            }

            if sourceKind != .externalSystem {
                refreshEmptyDirectoryInode(at: expanded)
            }
        }.value
    }

    public static func buildRcloneArguments(
        remotePath: String,
        localPath: String,
        sshCommand: String,
        volName: String,
        logFilePath: String
    ) -> [String] {
        [
            "nfsmount",
            ":sftp:\(remotePath)",
            localPath,
            "--sftp-ssh", sshCommand,
            "--sftp-known-hosts-file", "none",
            "--sftp-idle-timeout", "0",
            "--vfs-cache-mode", "full",
            "--vfs-cache-max-age", "1h",
            "--vfs-cache-max-size", "2G",
            "--vfs-read-ahead", "16M",
            "--vfs-fast-fingerprint",
            "--dir-cache-time", "5m",
            "--attr-timeout", "1m",
            "--contimeout", "8s",
            "--timeout", "15s",
            "--low-level-retries", "5",
            "--transfers", "2",
            "--checkers", "2",
            "--volname", volName,
            "--daemon",
            "--log-file", logFilePath
        ]
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
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.contains(localPath) || tokens.contains(canonicalLocalPath) else { continue }
            if let first = tokens.first, let pid = Int32(first) {
                pids.append(pid)
            }
        }
        return pids
    }

    private static func refreshEmptyDirectoryInode(at path: String) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path),
              children.allSatisfy({ $0 == ".DS_Store" })
        else {
            return
        }
        try? fm.removeItem(atPath: path)
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private static func sanitizeVolumeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "NodeDeckMount" : cleaned
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
