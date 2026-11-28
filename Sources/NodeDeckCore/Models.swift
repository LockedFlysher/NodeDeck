import Foundation

public enum SSHRouteKind: String, Sendable {
    case localTunnel
    case directLAN
    case remote

    public var label: String {
        switch self {
        case .localTunnel: return "Local Tunnel"
        case .directLAN: return "LAN Direct"
        case .remote: return "Remote"
        }
    }

    public var shortBadge: String {
        switch self {
        case .localTunnel: return "Tunnel"
        case .directLAN: return "LAN"
        case .remote: return "WAN"
        }
    }
}

public struct SSHHost: Identifiable, Hashable, Sendable {
    public let alias: String
    public let alternateAliases: [String]
    public let hostName: String
    public let user: String
    public let port: Int
    public let identityFile: String?
    public let proxyJump: String?
    public let serverAliveInterval: Int?
    public let compression: Bool
    public let localForwards: [String]

    public var id: String { alias }

    public init(
        alias: String,
        alternateAliases: [String] = [],
        hostName: String,
        user: String,
        port: Int,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        serverAliveInterval: Int? = nil,
        compression: Bool = false,
        localForwards: [String] = []
    ) {
        self.alias = alias
        self.alternateAliases = alternateAliases
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.serverAliveInterval = serverAliveInterval
        self.compression = compression
        self.localForwards = localForwards
    }

    public var allAliases: [String] {
        [alias] + alternateAliases
    }

    public var endpoint: String {
        port == 22 ? hostName : "\(hostName):\(port)"
    }

    public var loginTarget: String {
        port == 22 ? "\(user)@\(hostName)" : "\(user)@\(hostName):\(port)"
    }

    public var terminalCommand: String {
        "ssh \(Shell.quote(alias))"
    }

    public var shortEndpoint: String {
        if hostName.count > 34 {
            return String(hostName.prefix(31)) + "..."
        }
        return endpoint
    }

    public var routeKind: SSHRouteKind {
        let lower = hostName.lowercased()
        if lower == "127.0.0.1" || lower == "::1" || lower == "localhost" {
            return .localTunnel
        }
        if lower.hasPrefix("10.") ||
            lower.hasPrefix("192.168.") ||
            lower.hasPrefix("fe80:") ||
            lower.hasSuffix(".local") ||
            Self.isPrivate172(lower) {
            return .directLAN
        }
        return .remote
    }

    private static func isPrivate172(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts[0] == "172", let second = Int(parts[1]) else {
            return false
        }
        return (16...31).contains(second)
    }
}

public struct GPUInfo: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let utilization: Double?
    public let memoryUsedMB: Double?
    public let memoryTotalMB: Double?
    public let temperatureC: Double?
    public let powerW: Double?
    public let isSleeping: Bool

    public init(
        name: String,
        utilization: Double? = nil,
        memoryUsedMB: Double? = nil,
        memoryTotalMB: Double? = nil,
        temperatureC: Double? = nil,
        powerW: Double? = nil,
        isSleeping: Bool = false
    ) {
        self.name = name
        self.utilization = utilization
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
        self.temperatureC = temperatureC
        self.powerW = powerW
        self.isSleeping = isSleeping
    }

    public var isAMD: Bool {
        let lower = name.lowercased()
        return lower.contains("amd") || lower.contains("radeon") || lower.contains("instinct")
    }

    public var memoryFraction: Double? {
        guard let used = memoryUsedMB, let total = memoryTotalMB, total > 0 else {
            return nil
        }
        return min(max(used / total, 0), 1)
    }
}

public struct RemoteProcess: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let cpuPercent: Double
    public let memoryPercent: Double

    public init(name: String, cpuPercent: Double, memoryPercent: Double) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
    }
}

public enum SlurmNodeCategory: String, Sendable {
    case idle
    case allocated
    case mixed
    case unavailable
    case other

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .allocated: return "Allocated"
        case .mixed: return "Mixed"
        case .unavailable: return "Unavailable"
        case .other: return "Other"
        }
    }
}

public struct SlurmNode: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let partition: String
    public let state: String
    public let allocatedCPUs: Int
    public let idleCPUs: Int
    public let otherCPUs: Int
    public let totalCPUs: Int
    public let memoryMB: UInt64
    public let gres: String
    public let features: String

    public init(
        name: String,
        partition: String,
        state: String,
        allocatedCPUs: Int,
        idleCPUs: Int,
        otherCPUs: Int,
        totalCPUs: Int,
        memoryMB: UInt64,
        gres: String,
        features: String
    ) {
        self.name = name
        self.partition = partition
        self.state = state
        self.allocatedCPUs = allocatedCPUs
        self.idleCPUs = idleCPUs
        self.otherCPUs = otherCPUs
        self.totalCPUs = totalCPUs
        self.memoryMB = memoryMB
        self.gres = gres
        self.features = features
    }

    public var category: SlurmNodeCategory {
        let normalized = state.lowercased()
        if normalized.hasPrefix("idle") {
            return .idle
        }
        if normalized.hasPrefix("alloc") {
            return .allocated
        }
        if normalized.hasPrefix("mix") {
            return .mixed
        }
        if normalized.hasPrefix("down") ||
            normalized.hasPrefix("drain") ||
            normalized.hasPrefix("fail") ||
            normalized.hasPrefix("error") ||
            normalized.hasPrefix("unknown") ||
            normalized.hasPrefix("maint") ||
            normalized.hasPrefix("power") {
            return .unavailable
        }
        return .other
    }

    public var gpuDescription: String? {
        guard gres.hasPrefix("gpu:"), !gres.contains("(null)") else {
            return nil
        }
        let parts = gres.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        let model = parts[1].uppercased()
        let count = parts[2]
        return "\(model) x\(count)"
    }
}

public struct SlurmInfo: Sendable {
    public let nodes: [SlurmNode]

    public init(nodes: [SlurmNode]) {
        self.nodes = nodes
    }

    public var idleNodeCount: Int {
        nodes.filter { $0.category == .idle }.count
    }

    public var allocatedNodeCount: Int {
        nodes.filter { $0.category == .allocated }.count
    }

    public var mixedNodeCount: Int {
        nodes.filter { $0.category == .mixed }.count
    }

    public var idleCPUs: Int {
        nodes.reduce(0) { $0 + $1.idleCPUs }
    }

    public var totalCPUs: Int {
        nodes.reduce(0) { $0 + $1.totalCPUs }
    }

    public var occupiedNodeCount: Int {
        allocatedNodeCount + mixedNodeCount
    }
}

public struct HostMetrics: Sendable {
    public let hostname: String
    public let osName: String
    public let kernel: String
    public let architecture: String
    public let user: String
    public let homeDirectory: String
    public let candidateDirectories: [String]
    public let cpuModel: String
    public let cpuCores: Int
    public let cpuUsage: Double
    public let load1: Double
    public let load5: Double
    public let load15: Double
    public let memoryTotal: UInt64
    public let memoryAvailable: UInt64
    public let swapTotal: UInt64
    public let swapFree: UInt64
    public let diskTotal: UInt64
    public let diskUsed: UInt64
    public let diskAvailable: UInt64
    public let uptimeSeconds: TimeInterval
    public let gpus: [GPUInfo]
    public let processes: [RemoteProcess]
    public let slurm: SlurmInfo?
    public let scriptDurationMilliseconds: Double?
    public let capturedAt: Date

    public init(
        hostname: String,
        osName: String,
        kernel: String,
        architecture: String,
        user: String,
        homeDirectory: String = "",
        candidateDirectories: [String] = [],
        cpuModel: String,
        cpuCores: Int,
        cpuUsage: Double,
        load1: Double,
        load5: Double,
        load15: Double,
        memoryTotal: UInt64,
        memoryAvailable: UInt64,
        swapTotal: UInt64,
        swapFree: UInt64,
        diskTotal: UInt64,
        diskUsed: UInt64,
        diskAvailable: UInt64,
        uptimeSeconds: TimeInterval,
        gpus: [GPUInfo] = [],
        processes: [RemoteProcess] = [],
        slurm: SlurmInfo? = nil,
        scriptDurationMilliseconds: Double? = nil,
        capturedAt: Date = Date()
    ) {
        self.hostname = hostname
        self.osName = osName
        self.kernel = kernel
        self.architecture = architecture
        self.user = user
        self.homeDirectory = homeDirectory
        self.candidateDirectories = candidateDirectories
        self.cpuModel = cpuModel
        self.cpuCores = cpuCores
        self.cpuUsage = cpuUsage
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memoryTotal = memoryTotal
        self.memoryAvailable = memoryAvailable
        self.swapTotal = swapTotal
        self.swapFree = swapFree
        self.diskTotal = diskTotal
        self.diskUsed = diskUsed
        self.diskAvailable = diskAvailable
        self.uptimeSeconds = uptimeSeconds
        self.gpus = gpus
        self.processes = processes
        self.slurm = slurm
        self.scriptDurationMilliseconds = scriptDurationMilliseconds
        self.capturedAt = capturedAt
    }

    public var memoryUsed: UInt64 {
        memoryTotal > memoryAvailable ? memoryTotal - memoryAvailable : 0
    }

    public var memoryFraction: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(max(Double(memoryUsed) / Double(memoryTotal), 0), 1)
    }

    public var swapUsed: UInt64 {
        swapTotal > swapFree ? swapTotal - swapFree : 0
    }

    public var diskFraction: Double {
        guard diskTotal > 0 else { return 0 }
        return min(max(Double(diskUsed) / Double(diskTotal), 0), 1)
    }
}

public enum HostConnectionState: String, Sendable {
    case idle
    case checking
    case online
    case offline
}

public struct HostSnapshot: Identifiable, Sendable {
    public let host: SSHHost
    public var state: HostConnectionState
    public var metrics: HostMetrics?
    public var latencyMilliseconds: Double?
    public var lastUpdated: Date?
    public var message: String?

    public var id: String { host.alias }

    public init(
        host: SSHHost,
        state: HostConnectionState = .idle,
        metrics: HostMetrics? = nil,
        latencyMilliseconds: Double? = nil,
        lastUpdated: Date? = nil,
        message: String? = nil
    ) {
        self.host = host
        self.state = state
        self.metrics = metrics
        self.latencyMilliseconds = latencyMilliseconds
        self.lastUpdated = lastUpdated
        self.message = message
    }
}

public struct HostProbeResult: Sendable {
    public let metrics: HostMetrics?
    public let latencyMilliseconds: Double?
    public let errorMessage: String?

    public init(
        metrics: HostMetrics?,
        latencyMilliseconds: Double?,
        errorMessage: String?
    ) {
        self.metrics = metrics
        self.latencyMilliseconds = latencyMilliseconds
        self.errorMessage = errorMessage
    }
}

// MARK: - Directory Mount Models

public enum MountStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case smbFirst
    case sftpOnly
    case smbOnly

    public var label: String {
        switch self {
        case .smbFirst: return "LAN SMB First (rclone Fallback)"
        case .sftpOnly: return "rclone SFTP Only"
        case .smbOnly: return "LAN SMB Only"
        }
    }
}

public struct FolderMountConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var hostAlias: String
    public var label: String
    public var remotePath: String
    public var localPath: String
    public var autoMount: Bool
    public var strategy: MountStrategy
    public var smbEndpoints: [String]
    public var smbShare: String?
    public var smbUser: String?
    public var rcloneFallbackAlias: String?

    public init(
        id: UUID = UUID(),
        hostAlias: String,
        label: String,
        remotePath: String,
        localPath: String,
        autoMount: Bool = true,
        strategy: MountStrategy = .smbFirst,
        smbEndpoints: [String] = [],
        smbShare: String? = nil,
        smbUser: String? = nil,
        rcloneFallbackAlias: String? = nil
    ) {
        self.id = id
        self.hostAlias = hostAlias
        self.label = label
        self.remotePath = remotePath
        self.localPath = localPath
        self.autoMount = autoMount
        self.strategy = strategy
        self.smbEndpoints = smbEndpoints
        self.smbShare = smbShare
        self.smbUser = smbUser
        self.rcloneFallbackAlias = rcloneFallbackAlias
    }

    enum CodingKeys: String, CodingKey {
        case id
        case hostAlias
        case label
        case remotePath
        case localPath
        case autoMount
        case strategy
        case smbEndpoints
        case smbShare
        case smbUser
        case rcloneFallbackAlias
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.hostAlias = try container.decode(String.self, forKey: .hostAlias)
        self.label = try container.decode(String.self, forKey: .label)
        self.remotePath = try container.decode(String.self, forKey: .remotePath)
        self.localPath = try container.decode(String.self, forKey: .localPath)
        self.autoMount = try container.decodeIfPresent(Bool.self, forKey: .autoMount) ?? true
        let endpoints = try container.decodeIfPresent([String].self, forKey: .smbEndpoints) ?? []
        self.smbEndpoints = endpoints
        self.smbShare = try container.decodeIfPresent(String.self, forKey: .smbShare)
        self.smbUser = try container.decodeIfPresent(String.self, forKey: .smbUser)
        self.rcloneFallbackAlias = try container.decodeIfPresent(String.self, forKey: .rcloneFallbackAlias)
        if let explicitStrategy = try container.decodeIfPresent(MountStrategy.self, forKey: .strategy) {
            self.strategy = explicitStrategy
        } else {
            self.strategy = endpoints.isEmpty ? .sftpOnly : .smbFirst
        }
    }

    public var expandedLocalPath: String {
        (localPath as NSString).expandingTildeInPath
    }

    public var displayLocalPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = expandedLocalPath
        if expanded.hasPrefix(home + "/") {
            return "~" + expanded.dropFirst(home.count)
        }
        return expanded
    }

    public static func inferredSMBShare(from remotePath: String, user: String? = nil) -> String? {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clean = trimmed.count > 1 && trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        if let user, !user.isEmpty {
            let userHome = "/home/\(user)"
            if clean == userHome {
                return "home"
            }
            if clean.hasPrefix(userHome + "/") {
                let rel = String(clean.dropFirst(userHome.count + 1))
                if !rel.contains("/") {
                    return rel
                }
                return "home/\(rel)"
            }
        }

        let parts = clean.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "home" {
            return parts[2]
        }
        if parts.count > 3, parts[0] == "home" {
            let rel = parts.dropFirst(2).joined(separator: "/")
            return "home/\(rel)"
        }
        return parts.last
    }
}

public enum MountSourceKind: String, Hashable, Sendable {
    case managedSMB
    case managedSFTP
    case externalSystem
}

public enum MountRuntimeState: String, Hashable, Sendable {
    case unmounted
    case mounting
    case mounted
    case unmounting
    case error
}

public struct SystemMountEntry: Hashable, Sendable {
    public let source: String
    public let localPath: String
    public let canonicalLocalPath: String
    public let fileSystemType: String

    public init(source: String, localPath: String, canonicalLocalPath: String, fileSystemType: String) {
        self.source = source
        self.localPath = localPath
        self.canonicalLocalPath = canonicalLocalPath
        self.fileSystemType = fileSystemType
    }
}

public struct FolderMountItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let config: FolderMountConfig?
    public let hostAlias: String
    public let label: String
    public let remoteDescription: String
    public let localPath: String
    public let displayLocalPath: String
    public let fileSystemType: String?
    public let sourceKind: MountSourceKind
    public let state: MountRuntimeState
    public let errorMessage: String?

    public init(
        id: String,
        config: FolderMountConfig?,
        hostAlias: String,
        label: String,
        remoteDescription: String,
        localPath: String,
        displayLocalPath: String,
        fileSystemType: String?,
        sourceKind: MountSourceKind,
        state: MountRuntimeState,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.config = config
        self.hostAlias = hostAlias
        self.label = label
        self.remoteDescription = remoteDescription
        self.localPath = localPath
        self.displayLocalPath = displayLocalPath
        self.fileSystemType = fileSystemType
        self.sourceKind = sourceKind
        self.state = state
        self.errorMessage = errorMessage
    }

    public var isMounted: Bool {
        state == .mounted
    }

    public var isBusy: Bool {
        state == .mounting || state == .unmounting
    }
}

// MARK: - Remote Desktop Models

public struct MoonlightTarget: Identifiable, Hashable, Sendable {
    public var id: String { "\(hostAlias.lowercased())-\(streamEndpoint)" }
    public let hostAlias: String
    public let title: String
    public let subtitle: String
    public let streamEndpoint: String
    public let webURLString: String

    public init(
        hostAlias: String,
        title: String,
        subtitle: String,
        streamEndpoint: String,
        webURLString: String
    ) {
        self.hostAlias = hostAlias
        self.title = title
        self.subtitle = subtitle
        self.streamEndpoint = streamEndpoint
        self.webURLString = webURLString
    }
}

// MARK: - VS Code Remote-SSH Workspace Models

public enum VSCodeWorkspaceKind: String, Codable, Hashable, Sendable {
    case folder
    case workspaceFile
}

public struct VSCodeRawEntry: Hashable, Sendable {
    public let rawURI: String
    public let authorityHost: String
    public let authorityUser: String?
    public let remotePath: String
    public let kind: VSCodeWorkspaceKind
    public let isOpenInWindow: Bool
    public let isLastActive: Bool
    public let lastOpenedAt: Date?

    public init(
        rawURI: String,
        authorityHost: String,
        authorityUser: String?,
        remotePath: String,
        kind: VSCodeWorkspaceKind,
        isOpenInWindow: Bool,
        isLastActive: Bool,
        lastOpenedAt: Date?
    ) {
        self.rawURI = rawURI
        self.authorityHost = authorityHost
        self.authorityUser = authorityUser
        self.remotePath = remotePath
        self.kind = kind
        self.isOpenInWindow = isOpenInWindow
        self.isLastActive = isLastActive
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct VSCodeWorkspaceItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(hostAlias.lowercased())::\(kind.rawValue)::\(remotePath)" }
    public let hostAlias: String
    public let effectiveAuthority: String
    public let originalAuthority: String
    public let remotePath: String
    public let kind: VSCodeWorkspaceKind
    public let isOpenInWindow: Bool
    public let isLastActive: Bool
    public let lastOpenedAt: Date?

    public init(
        hostAlias: String,
        effectiveAuthority: String,
        originalAuthority: String,
        remotePath: String,
        kind: VSCodeWorkspaceKind,
        isOpenInWindow: Bool,
        isLastActive: Bool,
        lastOpenedAt: Date?
    ) {
        self.hostAlias = hostAlias
        self.effectiveAuthority = effectiveAuthority
        self.originalAuthority = originalAuthority
        self.remotePath = remotePath
        self.kind = kind
        self.isOpenInWindow = isOpenInWindow
        self.isLastActive = isLastActive
        self.lastOpenedAt = lastOpenedAt
    }

    public var name: String {
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "/" }
        let base = URL(fileURLWithPath: "/" + trimmed).lastPathComponent
        if kind == .workspaceFile, base.hasSuffix(".code-workspace") {
            return String(base.dropLast(".code-workspace".count))
        }
        return base
    }

    public var vscodeRemoteURI: String {
        let normalized = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        return "vscode-remote://ssh-remote+\(effectiveAuthority)\(normalized)"
    }
}
