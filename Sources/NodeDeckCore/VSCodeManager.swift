import Foundation

public enum VSCodeLaunchError: LocalizedError, Sendable {
    case vscodeNotInstalled
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .vscodeNotInstalled:
            return "Visual Studio Code was not found in /Applications or PATH."
        case .launchFailed(let detail):
            return "Failed to launch VS Code: \(detail)"
        }
    }
}

public enum VSCodeManager {
    public static var defaultUserStorageRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Code")
            .appendingPathComponent("User")
    }

    public static let appBundleCandidates = [
        "/Applications/Visual Studio Code.app",
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Applications/Visual Studio Code.app")
    ]

    public static func findCodeExecutable() -> String? {
        let candidates = [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let whichRes = ProcessRunner.run(executable: "/usr/bin/which", arguments: ["code"], timeout: 2)
        let resolved = whichRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if whichRes.status == 0, !resolved.isEmpty, FileManager.default.isExecutableFile(atPath: resolved) {
            return resolved
        }
        return nil
    }

    public static var isInstalled: Bool {
        if findCodeExecutable() != nil { return true }
        return appBundleCandidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Discovery from storage.json & workspaceStorage

    public static func discoverRawEntries(userRoot: URL = defaultUserStorageRoot) -> [VSCodeRawEntry] {
        var merged: [String: VSCodeRawEntry] = [:]

        func upsert(_ candidate: VSCodeRawEntry) {
            let key = "\(candidate.authorityUser ?? "")@\(candidate.authorityHost.lowercased())::\(candidate.kind.rawValue)::\(candidate.remotePath)"
            if let existing = merged[key] {
                let newerDate: Date? = {
                    switch (existing.lastOpenedAt, candidate.lastOpenedAt) {
                    case let (a?, b?): return max(a, b)
                    case let (a?, nil): return a
                    case let (nil, b?): return b
                    case (nil, nil): return nil
                    }
                }()
                merged[key] = VSCodeRawEntry(
                    rawURI: candidate.isOpenInWindow ? candidate.rawURI : existing.rawURI,
                    authorityHost: existing.authorityHost,
                    authorityUser: existing.authorityUser ?? candidate.authorityUser,
                    remotePath: existing.remotePath,
                    kind: existing.kind,
                    isOpenInWindow: existing.isOpenInWindow || candidate.isOpenInWindow,
                    isLastActive: existing.isLastActive || candidate.isLastActive,
                    lastOpenedAt: newerDate
                )
            } else {
                merged[key] = candidate
            }
        }

        // 1. Parse globalStorage/storage.json (active windows, backupWorkspaces, profileAssociations)
        let storageJSONURL = userRoot
            .appendingPathComponent("globalStorage")
            .appendingPathComponent("storage.json")
        if let data = try? Data(contentsOf: storageJSONURL),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let windowsState = root["windowsState"] as? [String: Any] {
                if let lastActive = windowsState["lastActiveWindow"] as? [String: Any] {
                    if let folder = lastActive["folder"] as? String,
                       let entry = parseRemoteURI(folder, kind: .folder, isOpen: true, isLastActive: true, date: Date()) {
                        upsert(entry)
                    }
                    if let ws = lastActive["workspaceIdentifier"] as? [String: Any],
                       let cfgURI = ws["configURIPath"] as? String,
                       let entry = parseRemoteURI(cfgURI, kind: .workspaceFile, isOpen: true, isLastActive: true, date: Date()) {
                        upsert(entry)
                    }
                }
                if let opened = windowsState["openedWindows"] as? [[String: Any]] {
                    for win in opened {
                        if let folder = win["folder"] as? String,
                           let entry = parseRemoteURI(folder, kind: .folder, isOpen: true, isLastActive: false, date: Date()) {
                            upsert(entry)
                        }
                        if let ws = win["workspaceIdentifier"] as? [String: Any],
                           let cfgURI = ws["configURIPath"] as? String,
                           let entry = parseRemoteURI(cfgURI, kind: .workspaceFile, isOpen: true, isLastActive: false, date: Date()) {
                            upsert(entry)
                        }
                    }
                }
            }

            if let backup = root["backupWorkspaces"] as? [String: Any] {
                if let folders = backup["folders"] as? [[String: Any]] {
                    for item in folders {
                        if let uri = item["folderUri"] as? String,
                           let entry = parseRemoteURI(uri, kind: .folder, isOpen: true, isLastActive: false, date: nil) {
                            upsert(entry)
                        }
                    }
                }
                if let workspaces = backup["workspaces"] as? [[String: Any]] {
                    for item in workspaces {
                        if let uri = item["configURIPath"] as? String,
                           let entry = parseRemoteURI(uri, kind: .workspaceFile, isOpen: true, isLastActive: false, date: nil) {
                            upsert(entry)
                        }
                    }
                }
            }

            if let profileAssoc = root["profileAssociations"] as? [String: Any],
               let workspacesMap = profileAssoc["workspaces"] as? [String: Any] {
                for rawURI in workspacesMap.keys {
                    let kind: VSCodeWorkspaceKind = rawURI.hasSuffix(".code-workspace") ? .workspaceFile : .folder
                    if let entry = parseRemoteURI(rawURI, kind: kind, isOpen: false, isLastActive: false, date: nil) {
                        upsert(entry)
                    }
                }
            }
        }

        // 2. Parse workspaceStorage/*/workspace.json for modification timestamps & recent workspaces
        let wsStorageDir = userRoot.appendingPathComponent("workspaceStorage")
        if let subdirs = try? FileManager.default.contentsOfDirectory(
            at: wsStorageDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in subdirs {
                let wsFile = dir.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: wsFile),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }

                let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? (try? wsFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

                if let folder = obj["folder"] as? String,
                   let entry = parseRemoteURI(folder, kind: .folder, isOpen: false, isLastActive: false, date: mtime) {
                    upsert(entry)
                } else if let wsURI = obj["workspace"] as? String,
                          let entry = parseRemoteURI(wsURI, kind: .workspaceFile, isOpen: false, isLastActive: false, date: mtime) {
                    upsert(entry)
                }
            }
        }

        return Array(merged.values)
    }

    public static func parseRemoteURI(
        _ rawURI: String,
        kind: VSCodeWorkspaceKind,
        isOpen: Bool = false,
        isLastActive: Bool = false,
        date: Date? = nil
    ) -> VSCodeRawEntry? {
        let decoded = rawURI.removingPercentEncoding ?? rawURI
        let prefix = "vscode-remote://ssh-remote+"
        guard decoded.lowercased().hasPrefix(prefix) else { return nil }

        let remainder = String(decoded.dropFirst(prefix.count))
        guard let slashIdx = remainder.firstIndex(of: "/") else { return nil }

        let rawAuthority = String(remainder[..<slashIdx])
        var remotePath = String(remainder[slashIdx...])
        if remotePath.count > 1 && remotePath.hasSuffix("/") {
            remotePath.removeLast()
        }
        guard !rawAuthority.isEmpty, !remotePath.isEmpty else { return nil }

        let resolvedAuthority = decodeHexAuthorityIfNeeded(rawAuthority)
        let (user, host) = splitUserHost(resolvedAuthority)
        guard !host.isEmpty else { return nil }

        return VSCodeRawEntry(
            rawURI: decoded,
            authorityHost: host,
            authorityUser: user,
            remotePath: remotePath,
            kind: kind,
            isOpenInWindow: isOpen,
            isLastActive: isLastActive,
            lastOpenedAt: date
        )
    }

    private static let genericAliasTokens: Set<String> = [
        "workstation", "server", "host", "direct", "lan", "wan",
        "ethernet", "ssh", "node", "vm", "cloud", "dual", "local", "ubuntu", "linux"
    ]

    public static func buildItems(
        for host: SSHHost,
        rawEntries: [VSCodeRawEntry],
        allHosts: [SSHHost] = [],
        mountConfigs: [FolderMountConfig] = [],
        tunnelConfigs: [GostTunnelConfig] = []
    ) -> [VSCodeWorkspaceItem] {
        let hostAliasesLower = Set(host.allAliases.map { $0.lowercased() })
        var byPath: [String: VSCodeWorkspaceItem] = [:]

        for entry in rawEntries {
            guard matches(
                entry: entry,
                host: host,
                allHosts: allHosts,
                mountConfigs: mountConfigs,
                tunnelConfigs: tunnelConfigs
            ) else { continue }

            // Preserve exact alias if it belongs to this SSHHost so VS Code focuses an already-open window
            // instead of spawning a second window; otherwise upgrade to host.alias!
            let effectiveAuthority: String
            if hostAliasesLower.contains(entry.authorityHost.lowercased()) {
                effectiveAuthority = entry.authorityHost
            } else {
                effectiveAuthority = host.alias
            }

            let dedupKey = "\(entry.kind.rawValue)::\(entry.remotePath)"
            let candidate = VSCodeWorkspaceItem(
                hostAlias: host.alias,
                effectiveAuthority: effectiveAuthority,
                originalAuthority: entry.authorityHost,
                remotePath: entry.remotePath,
                kind: entry.kind,
                isOpenInWindow: entry.isOpenInWindow,
                isLastActive: entry.isLastActive,
                lastOpenedAt: entry.lastOpenedAt
            )

            if let prev = byPath[dedupKey] {
                let preferCandidateAuthority = hostAliasesLower.contains(entry.authorityHost.lowercased()) &&
                    (entry.isOpenInWindow || !hostAliasesLower.contains(prev.originalAuthority.lowercased()))
                let newerDate: Date? = {
                    switch (prev.lastOpenedAt, candidate.lastOpenedAt) {
                    case let (a?, b?): return max(a, b)
                    case let (a?, nil): return a
                    case let (nil, b?): return b
                    case (nil, nil): return nil
                    }
                }()
                byPath[dedupKey] = VSCodeWorkspaceItem(
                    hostAlias: host.alias,
                    effectiveAuthority: preferCandidateAuthority ? candidate.effectiveAuthority : prev.effectiveAuthority,
                    originalAuthority: preferCandidateAuthority ? candidate.originalAuthority : prev.originalAuthority,
                    remotePath: prev.remotePath,
                    kind: prev.kind,
                    isOpenInWindow: prev.isOpenInWindow || candidate.isOpenInWindow,
                    isLastActive: prev.isLastActive || candidate.isLastActive,
                    lastOpenedAt: newerDate
                )
            } else {
                byPath[dedupKey] = candidate
            }
        }

        return byPath.values.sorted { lhs, rhs in
            if lhs.isLastActive != rhs.isLastActive {
                return lhs.isLastActive && !rhs.isLastActive
            }
            if lhs.isOpenInWindow != rhs.isOpenInWindow {
                return lhs.isOpenInWindow && !rhs.isOpenInWindow
            }
            let lDate = lhs.lastOpenedAt ?? .distantPast
            let rDate = rhs.lastOpenedAt ?? .distantPast
            if lDate != rDate {
                return lDate > rDate
            }
            return lhs.remotePath < rhs.remotePath
        }
    }

    public static func matches(
        entry: VSCodeRawEntry,
        host: SSHHost,
        allHosts: [SSHHost] = [],
        mountConfigs: [FolderMountConfig] = [],
        tunnelConfigs: [GostTunnelConfig] = []
    ) -> Bool {
        let authLower = entry.authorityHost.lowercased()
        let hostAliases = host.allAliases.map { $0.lowercased() }

        // 1. Direct alias or alternateAlias match
        if hostAliases.contains(authLower) {
            return true
        }

        // 2. Generic distinctive machine-token stem matching (e.g. "workstation-alpha-old" <-> "alpha-direct")
        let hostDistinctTokens = distinctiveTokens(from: hostAliases)
        let authDistinctTokens = distinctiveTokens(from: [authLower])
        if !hostDistinctTokens.isDisjoint(with: authDistinctTokens) {
            return true
        }

        // 3. Match against tunnel relay upstream host associated exclusively with this host
        let hostTunnelRelays = Set(
            tunnelConfigs
                .filter { hostAliases.contains($0.hostAlias.lowercased()) }
                .compactMap { $0.forwardHost?.lowercased() }
        )
        let otherTunnelRelays = Set(
            tunnelConfigs
                .filter { !hostAliases.contains($0.hostAlias.lowercased()) }
                .compactMap { $0.forwardHost?.lowercased() }
        )
        let exclusiveRelays = hostTunnelRelays.subtracting(otherTunnelRelays)
        if exclusiveRelays.contains(authLower) {
            return true
        }

        // 4. IP / HostName match (with user & mounted-directory prefix disambiguation for shared jump/FRP gateways)
        let siblingGatewayHostNames = Set(
            allHosts
                .filter { !distinctiveTokens(from: $0.allAliases).isDisjoint(with: hostDistinctTokens) }
                .map { $0.hostName.lowercased() }
                .filter { $0 != "127.0.0.1" && $0 != "localhost" && $0 != "::1" }
        )
        let candidateHostNames: Set<String> = {
            var set = siblingGatewayHostNames
            let clean = host.hostName.lowercased()
            if clean != "127.0.0.1" && clean != "localhost" && clean != "::1" {
                set.insert(clean)
            }
            return set
        }()

        if candidateHostNames.contains(authLower) {
            if let entryUser = entry.authorityUser?.lowercased(), entryUser != host.user.lowercased() {
                return false
            }

            let allSameIPHosts = allHosts.filter { candidateHostNames.contains($0.hostName.lowercased()) }
            let sameIPAndUserHosts = allSameIPHosts.filter { $0.user.lowercased() == host.user.lowercased() }

            if allSameIPHosts.count > 1 && entry.authorityUser == nil {
                // When URI had no explicit user@ on a multi-tenant gateway, require path to match /home/<user> or configured mount prefix
                let expectedHome = "/home/\(host.user)"
                if !entry.remotePath.hasPrefix(expectedHome) {
                    return false
                }
            }

            if sameIPAndUserHosts.count > 1 {
                // Disambiguate multiple hosts sharing both gateway IP and username via configured mount path roots
                let myMountRoots = mountConfigs
                    .filter { hostAliases.contains($0.hostAlias.lowercased()) || !distinctiveTokens(from: [$0.hostAlias]).isDisjoint(with: hostDistinctTokens) }
                    .map(\.remotePath)
                if !myMountRoots.isEmpty {
                    let myRootPrefixes = Set(myMountRoots.map { topLevelRoot(of: $0) })
                    return myRootPrefixes.contains(topLevelRoot(of: entry.remotePath))
                }
            }

            return true
        }

        return false
    }

    private static func distinctiveTokens(from strings: [String]) -> Set<String> {
        var result = Set<String>()
        let separators = CharacterSet.alphanumerics.inverted
        for raw in strings {
            let lower = raw.lowercased()
            // Skip pure IPv4 addresses when extracting name tokens
            if lower.split(separator: ".").count == 4, lower.allSatisfy({ $0.isNumber || $0 == "." }) {
                continue
            }
            for part in lower.components(separatedBy: separators) where part.count >= 3 {
                if !genericAliasTokens.contains(part) {
                    result.insert(part)
                }
            }
        }
        return result
    }

    private static func topLevelRoot(of path: String) -> String {
        let comps = path.split(separator: "/", maxSplits: 2).map(String.init)
        guard let first = comps.first else { return "/" }
        return "/" + first
    }

    // MARK: - Launching VS Code

    public static func openWorkspace(_ item: VSCodeWorkspaceItem, forceNewWindow: Bool = false) throws {
        try openRemotePath(
            authority: item.effectiveAuthority,
            remotePath: item.remotePath,
            kind: item.kind,
            forceNewWindow: forceNewWindow
        )
    }

    public static func openRemotePath(
        authority: String,
        remotePath: String,
        kind: VSCodeWorkspaceKind = .folder,
        forceNewWindow: Bool = false
    ) throws {
        guard let codeBin = findCodeExecutable() else {
            throw VSCodeLaunchError.vscodeNotInstalled
        }
        let cleanPath = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        let uri = "vscode-remote://ssh-remote+\(authority)\(cleanPath)"
        var args: [String] = []
        if forceNewWindow {
            args.append("--new-window")
        }
        args.append(kind == .workspaceFile ? "--file-uri" : "--folder-uri")
        args.append(uri)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codeBin)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw VSCodeLaunchError.launchFailed(error.localizedDescription)
        }
    }

    public static func openEmptyHostWindow(authority: String) throws {
        guard let codeBin = findCodeExecutable() else {
            throw VSCodeLaunchError.vscodeNotInstalled
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codeBin)
        proc.arguments = ["--new-window", "--remote", "ssh-remote+\(authority)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw VSCodeLaunchError.launchFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func splitUserHost(_ authority: String) -> (String?, String) {
        if let atIdx = authority.lastIndex(of: "@") {
            let user = String(authority[..<atIdx])
            let hostPort = String(authority[authority.index(after: atIdx)...])
            return (user.isEmpty ? nil : user, stripPortIfIPv4(hostPort))
        }
        return (nil, stripPortIfIPv4(authority))
    }

    private static func stripPortIfIPv4(_ hostPort: String) -> String {
        let colons = hostPort.filter { $0 == ":" }.count
        if colons == 1, let colonIdx = hostPort.lastIndex(of: ":") {
            return String(hostPort[..<colonIdx])
        }
        return hostPort
    }

    private static func decodeHexAuthorityIfNeeded(_ raw: String) -> String {
        guard raw.count >= 4, raw.count % 2 == 0, raw.lowercased().hasPrefix("7b22") else {
            return raw
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count / 2)
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let next = raw.index(idx, offsetBy: 2)
            guard let byte = UInt8(raw[idx..<next], radix: 16) else { return raw }
            bytes.append(byte)
            idx = next
        }
        if let obj = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
           let hostName = obj["hostName"] as? String,
           !hostName.isEmpty {
            if let user = obj["user"] as? String, !user.isEmpty {
                return "\(user)@\(hostName)"
            }
            return hostName
        }
        return raw
    }
}
