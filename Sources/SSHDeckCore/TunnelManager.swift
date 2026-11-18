import Darwin
import Foundation

public enum TunnelError: LocalizedError {
    case gostNotFound
    case emptyListenSpecs
    case emptyForwardChain
    case portDidNotOpen(Int, String)
    case udpBindFailed(Int, String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .gostNotFound:
            return "GOST binary not found. Install via `brew install gost`."
        case .emptyListenSpecs:
            return "At least one local listen rule (-L) is required."
        case .emptyForwardChain:
            return "Forward relay chain (-F) cannot be empty."
        case .portDidNotOpen(let port, let detail):
            return detail.isEmpty
                ? "Local tunnel port 127.0.0.1:\(port) did not start listening."
                : "Port \(port) failed: \(detail)"
        case .udpBindFailed(let port, let detail):
            return "Direct UDP port 127.0.0.1:\(port) failed to bind: \(detail)"
        case .processFailed(let message):
            return message
        }
    }
}

private final class PacketBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let capacity: Int

    init(capacity: Int = 65536) {
        self.capacity = capacity
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        pointer.deallocate()
    }
}

public final class DirectUDPRelayEndpoint: @unchecked Sendable {
    public let rule: GostTunnelConfig.DirectUDPRule
    private let queue: DispatchQueue
    private let localSource: DispatchSourceRead
    private let upstreamSource: DispatchSourceRead
    private let lock = NSLock()
    private var isStopped = false

    public init(rule: GostTunnelConfig.DirectUDPRule) throws {
        self.rule = rule

        var remoteAddr = sockaddr_in()
        remoteAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remoteAddr.sin_family = sa_family_t(AF_INET)
        remoteAddr.sin_port = in_port_t(UInt16(rule.remotePort).bigEndian)
        guard inet_pton(AF_INET, rule.remoteHost, &remoteAddr.sin_addr) == 1 else {
            throw TunnelError.udpBindFailed(rule.localPort, "Invalid remote IPv4 address \(rule.remoteHost)")
        }

        let localFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard localFD >= 0 else {
            throw TunnelError.udpBindFailed(rule.localPort, String(cString: strerror(errno)))
        }

        let upstreamFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard upstreamFD >= 0 else {
            let err = String(cString: strerror(errno))
            close(localFD)
            throw TunnelError.udpBindFailed(rule.localPort, err)
        }

        Self.configureSocket(localFD, allowReuseAddr: true)
        Self.configureSocket(upstreamFD, allowReuseAddr: false)

        var localAddr = sockaddr_in()
        localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = in_port_t(UInt16(rule.localPort).bigEndian)
        guard inet_pton(AF_INET, rule.localHost, &localAddr.sin_addr) == 1 else {
            close(localFD)
            close(upstreamFD)
            throw TunnelError.udpBindFailed(rule.localPort, "Invalid local IPv4 address \(rule.localHost)")
        }

        let bindLocal = withUnsafePointer(to: &localAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(localFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindLocal == 0 else {
            let err = String(cString: strerror(errno))
            close(localFD)
            close(upstreamFD)
            throw TunnelError.udpBindFailed(rule.localPort, err)
        }

        var anyAddr = sockaddr_in()
        anyAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        anyAddr.sin_family = sa_family_t(AF_INET)
        anyAddr.sin_port = 0
        anyAddr.sin_addr.s_addr = INADDR_ANY.bigEndian
        _ = withUnsafePointer(to: &anyAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(upstreamFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let serialQueue = DispatchQueue(
            label: "com.sshdeck.udp-relay.\(rule.localPort)",
            qos: .userInteractive
        )
        self.queue = serialQueue

        let sharedBuffer = PacketBuffer(capacity: 65536)
        var lastClientAddr: sockaddr_in?
        let targetAddr = remoteAddr
        let sockAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let lSource = DispatchSource.makeReadSource(fileDescriptor: localFD, queue: serialQueue)
        let uSource = DispatchSource.makeReadSource(fileDescriptor: upstreamFD, queue: serialQueue)

        lSource.setEventHandler {
            var burstCount = 0
            while true {
                var srcAddr = sockaddr_in()
                var srcLen = sockAddrLen
                let n = withUnsafeMutablePointer(to: &srcAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(localFD, sharedBuffer.pointer, sharedBuffer.capacity, 0, $0, &srcLen)
                    }
                }
                if n < 0 {
                    let e = errno
                    if e == EAGAIN || e == EWOULDBLOCK {
                        break
                    }
                    continue
                }
                lastClientAddr = srcAddr
                var dst = targetAddr
                Self.sendWithBackoff(
                    fd: upstreamFD,
                    buffer: sharedBuffer.pointer,
                    length: n,
                    dest: &dst,
                    addrLen: sockAddrLen
                )
                burstCount += 1
                if burstCount % 16 == 0 {
                    usleep(20)
                }
            }
        }

        uSource.setEventHandler {
            var burstCount = 0
            while true {
                let n = Darwin.recvfrom(upstreamFD, sharedBuffer.pointer, sharedBuffer.capacity, 0, nil, nil)
                if n < 0 {
                    let e = errno
                    if e == EAGAIN || e == EWOULDBLOCK {
                        break
                    }
                    continue
                }
                guard var client = lastClientAddr else { continue }
                Self.sendWithBackoff(
                    fd: localFD,
                    buffer: sharedBuffer.pointer,
                    length: n,
                    dest: &client,
                    addrLen: sockAddrLen
                )
                burstCount += 1
                if burstCount % 16 == 0 {
                    usleep(20)
                }
            }
        }

        lSource.setCancelHandler {
            _ = sharedBuffer.capacity
            close(localFD)
        }
        uSource.setCancelHandler {
            _ = sharedBuffer.capacity
            close(upstreamFD)
        }

        self.localSource = lSource
        self.upstreamSource = uSource
        lSource.resume()
        uSource.resume()
    }

    public var isActive: Bool {
        lock.withLock { !isStopped }
    }

    public func stop() {
        let shouldCancel = lock.withLock { () -> Bool in
            if isStopped { return false }
            isStopped = true
            return true
        }
        guard shouldCancel else { return }
        localSource.cancel()
        upstreamSource.cancel()
    }

    deinit {
        stop()
    }

    private static func sendWithBackoff(
        fd: Int32,
        buffer: UnsafeRawPointer,
        length: Int,
        dest: inout sockaddr_in,
        addrLen: socklen_t
    ) {
        for attempt in 0..<14 {
            let sent = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, buffer, length, 0, $0, addrLen)
                }
            }
            if sent >= 0 {
                return
            }
            let e = errno
            if e == ENOBUFS || e == EAGAIN || e == EWOULDBLOCK || e == EINTR {
                usleep(attempt < 4 ? 35 : 100)
                continue
            }
            return
        }
    }

    private static func configureSocket(_ fd: Int32, allowReuseAddr: Bool) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if allowReuseAddr {
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        for size in [Int32(7 * 1024 * 1024), Int32(4 * 1024 * 1024), Int32(2 * 1024 * 1024), Int32(1 * 1024 * 1024)] {
            var bufSize = size
            if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                break
            }
        }
        for size in [Int32(7 * 1024 * 1024), Int32(4 * 1024 * 1024), Int32(2 * 1024 * 1024), Int32(1 * 1024 * 1024)] {
            var bufSize = size
            if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                break
            }
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

public final class TunnelManager: @unchecked Sendable {
    public static let shared = TunnelManager()

    public static var defaultConfigFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("SSHDeck", isDirectory: true)
            .appendingPathComponent("tunnels.json")
    }

    public static let defaultQuicQuery = "keepalive=true&ttl=5s&maxIdleTimeout=20s&handshakeTimeout=5s&nodelay=true&udpBufferSize=2097152"

    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var udpRelays: [UUID: [DirectUDPRelayEndpoint]] = [:]
    private var verifiedOpenIDs: Set<UUID> = []
    private var lastErrors: [UUID: String] = [:]
    private var startingIDs: Set<UUID> = []

    public init() {}

    public static func findGostExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gost",
            "/usr/local/bin/gost",
            (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".local/bin/gost")
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let result = ProcessRunner.run(executable: "/usr/bin/which", arguments: ["gost"], timeout: 2)
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0, !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        return nil
    }

    public static func defaultSeedConfigs() -> [GostTunnelConfig] {
        []
    }

    public static func migrateConfigsIfNeeded(_ configs: [GostTunnelConfig]) -> (configs: [GostTunnelConfig], didMigrate: Bool) {
        var didMigrate = false
        let updated = configs.map { cfg -> GostTunnelConfig in
            var copy = cfg
            var changed = false

            // 1. Upgrade legacy QUIC queries (missing maxIdleTimeout or using outdated 300s/keepAlivePeriod options)
            if copy.forwardChain.lowercased().hasPrefix("relay+quic://"),
               (!copy.forwardChain.contains("maxIdleTimeout=") ||
                copy.forwardChain.contains("maxIdleTimeout=300s") ||
                copy.forwardChain.contains("keepAlivePeriod=")) {
                let base = copy.forwardChain.split(separator: "?", maxSplits: 1).first.map(String.init) ?? copy.forwardChain
                copy.forwardChain = "\(base)?\(defaultQuicQuery)"
                changed = true
            }

            // 2. Upgrade legacy Moonlight UDP rules to native LAN DirectUDPRelay
            if copy.role == .moonlight, let relayHost = copy.forwardHost {
                let migratedSpecs = copy.listenSpecs.map { spec -> String in
                    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.lowercased().hasPrefix("udp://"),
                          let schemeEnd = trimmed.range(of: "://")?.upperBound
                    else { return trimmed }
                    var body = String(trimmed[schemeEnd...])
                    if let qIdx = body.firstIndex(of: "?") {
                        body = String(body[..<qIdx])
                    }
                    let parts = body.split(separator: "/", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return trimmed }
                    let localPart = parts[0]
                    let remotePart = parts[1].replacingOccurrences(of: "127.0.0.1:", with: "\(relayHost):")
                    changed = true
                    return "udp-direct://\(localPart)/\(remotePart)"
                }
                copy.listenSpecs = migratedSpecs
            }

            if changed {
                didMigrate = true
            }
            return copy
        }

        return (updated, didMigrate)
    }

    public static func loadConfigs(from url: URL = defaultConfigFileURL) -> [GostTunnelConfig] {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([GostTunnelConfig].self, from: data) {
            let (migrated, changed) = migrateConfigsIfNeeded(decoded)
            if changed {
                try? saveConfigs(migrated, to: url)
            }
            return migrated
        }
        let seeded = defaultSeedConfigs()
        try? saveConfigs(seeded, to: url)
        return seeded
    }

    public static func saveConfigs(_ configs: [GostTunnelConfig], to url: URL = defaultConfigFileURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        try data.write(to: url, options: .atomic)
    }

    public static func buildArguments(for config: GostTunnelConfig) -> [String] {
        var args: [String] = []
        for spec in config.gostListenSpecs {
            var normalized = spec
            if normalized.lowercased().hasPrefix("udp://"), !normalized.contains("?") {
                normalized += "?keepAlive=true&ttl=60s&readBufferSize=65535"
            } else if normalized.lowercased().hasPrefix("tcp://"), !normalized.contains("retries=") {
                normalized += normalized.contains("?") ? "&retries=2" : "?retries=2"
            }
            args.append("-L")
            args.append(normalized)
        }
        let chain = config.forwardChain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !args.isEmpty && !chain.isEmpty {
            args.append("-F")
            args.append(chain)
        }
        return args
    }

    public static func isTCPPortOpen(host: String = "127.0.0.1", port: Int, timeoutMs: Int32 = 250) -> Bool {
        guard port > 0 && port <= 65535 else { return false }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let polled = poll(&pfd, 1, timeoutMs)
        guard polled > 0 else { return false }

        var sockErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &len) == 0 else {
            return false
        }
        return sockErr == 0
    }

    public func start(config: GostTunnelConfig, onTermination: (@Sendable () -> Void)? = nil) async throws {
        let allSpecs = config.listenSpecs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !allSpecs.isEmpty else {
            throw TunnelError.emptyListenSpecs
        }
        let gostSpecs = config.gostListenSpecs
        let udpRules = config.directUDPRules

        if !gostSpecs.isEmpty {
            guard !config.forwardChain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TunnelError.emptyForwardChain
            }
            guard Self.findGostExecutable() != nil else {
                throw TunnelError.gostNotFound
            }
        }

        let alreadyRunning = lock.withLock { () -> Bool in
            let procAlive = processes[config.id]?.isRunning ?? gostSpecs.isEmpty
            let udpAlive = udpRules.isEmpty || (udpRelays[config.id]?.allSatisfy(\.isActive) ?? false)
            if (!gostSpecs.isEmpty || !udpRules.isEmpty) && procAlive && udpAlive &&
                (processes[config.id] != nil || udpRelays[config.id] != nil) {
                return true
            }
            startingIDs.insert(config.id)
            lastErrors.removeValue(forKey: config.id)
            return false
        }
        if alreadyRunning {
            return
        }

        defer {
            lock.withLock {
                _ = startingIDs.remove(config.id)
            }
        }

        // Clean up any partial remnants for this tunnel ID first.
        stopResources(for: config.id)

        if let port = config.primaryLocalPort {
            reclaimStaleGostIfNeeded(port: port)
        }

        // 1. Bind native low-latency DirectUDPRelay endpoints (e.g. Moonlight RTP/ENet/Audio).
        var startedUDPs: [DirectUDPRelayEndpoint] = []
        do {
            for rule in udpRules {
                let relay = try DirectUDPRelayEndpoint(rule: rule)
                startedUDPs.append(relay)
            }
        } catch {
            for relay in startedUDPs {
                relay.stop()
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lock.withLock {
                lastErrors[config.id] = message
            }
            throw error
        }

        if !startedUDPs.isEmpty {
            lock.withLock {
                udpRelays[config.id] = startedUDPs
            }
        }

        // If this tunnel has only direct UDP rules, we're live immediately.
        guard !gostSpecs.isEmpty else {
            return
        }

        guard let gostPath = Self.findGostExecutable() else {
            stopResources(for: config.id)
            throw TunnelError.gostNotFound
        }

        let logURL = Self.logFileURL(for: config)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gostPath)
        proc.arguments = Self.buildArguments(for: config)
        if let logHandle {
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }

        let tunnelID = config.id
        proc.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            guard let self else { return }
            var terminatedActiveTunnel = false
            self.lock.lock()
            if self.processes[tunnelID] === finished {
                self.processes.removeValue(forKey: tunnelID)
                self.verifiedOpenIDs.remove(tunnelID)
                let orphanedUDPs = self.udpRelays.removeValue(forKey: tunnelID) ?? []
                for relay in orphanedUDPs {
                    relay.stop()
                }
                terminatedActiveTunnel = true
                if finished.terminationStatus != 0 && finished.terminationStatus != 15 {
                    let tail = Self.readLogTail(from: logURL)
                    self.lastErrors[tunnelID] = tail.isEmpty
                        ? "gost exited with code \(finished.terminationStatus)"
                        : tail
                }
            }
            self.lock.unlock()
            if terminatedActiveTunnel {
                onTermination?()
            }
        }

        do {
            try proc.run()
        } catch {
            try? logHandle?.close()
            stopResources(for: config.id)
            lock.withLock {
                lastErrors[config.id] = error.localizedDescription
            }
            throw TunnelError.processFailed(error.localizedDescription)
        }

        lock.withLock {
            processes[config.id] = proc
        }

        if let port = config.primaryLocalPort {
            for _ in 0..<18 {
                if !proc.isRunning {
                    break
                }
                if Self.isTCPPortOpen(port: port, timeoutMs: 120) {
                    lock.withLock { _ = verifiedOpenIDs.insert(config.id) }
                    return
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if !proc.isRunning || !Self.isTCPPortOpen(port: port, timeoutMs: 200) {
                let detail = Self.readLogTail(from: logURL)
                stop(id: config.id)
                lock.withLock {
                    lastErrors[config.id] = detail.isEmpty
                        ? "Local port \(port) did not bind"
                        : detail
                }
                throw TunnelError.portDidNotOpen(port, detail)
            }
            lock.withLock { _ = verifiedOpenIDs.insert(config.id) }
        } else {
            lock.withLock { _ = verifiedOpenIDs.insert(config.id) }
        }
    }

    public func stop(id: UUID) {
        lock.withLock {
            _ = lastErrors.removeValue(forKey: id)
            _ = startingIDs.remove(id)
            _ = verifiedOpenIDs.remove(id)
        }
        stopResources(for: id)
    }

    private func stopResources(for id: UUID) {
        lock.lock()
        let proc = processes.removeValue(forKey: id)
        let relays = udpRelays.removeValue(forKey: id) ?? []
        verifiedOpenIDs.remove(id)
        lock.unlock()

        for relay in relays {
            relay.stop()
        }

        guard let proc, proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(1.2)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    public func stopAll() {
        lock.lock()
        let activeProcs = Array(processes.values)
        let activeRelayGroups = Array(udpRelays.values)
        processes.removeAll()
        udpRelays.removeAll()
        startingIDs.removeAll()
        verifiedOpenIDs.removeAll()
        lock.unlock()

        for group in activeRelayGroups {
            for relay in group {
                relay.stop()
            }
        }

        for proc in activeProcs where proc.isRunning {
            proc.terminate()
        }
        let deadline = Date().addingTimeInterval(1.2)
        for proc in activeProcs {
            while proc.isRunning && Date() < deadline {
                usleep(40_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    public func snapshotItems(for configs: [GostTunnelConfig]) -> [TunnelRuntimeItem] {
        lock.lock()
        let currentProcs = processes
        let currentUDPs = udpRelays
        let currentVerified = verifiedOpenIDs
        let currentStarting = startingIDs
        let errors = lastErrors
        lock.unlock()

        return configs.map { cfg in
            let isStarting = currentStarting.contains(cfg.id)
            let needsGost = !cfg.gostListenSpecs.isEmpty
            let needsUDP = !cfg.directUDPRules.isEmpty

            let proc = currentProcs[cfg.id]
            let gostRunning = needsGost ? (proc?.isRunning ?? false) : true
            let udpRunning = needsUDP ? (currentUDPs[cfg.id]?.allSatisfy(\.isActive) ?? false) : true
            let hasAnyHandle = (needsGost && proc != nil) || (needsUDP && currentUDPs[cfg.id] != nil)
            let running = hasAnyHandle && gostRunning && udpRunning

            // Never connect to local TCP tunnel ports during periodic snapshots — that would open empty
            // QUIC streams against remote sshd (triggering preauth resets & MaxStartups throttling).
            let portOpen = needsGost ? (gostRunning && currentVerified.contains(cfg.id)) : running
            let err = errors[cfg.id]

            let state: TunnelRuntimeState
            if isStarting {
                state = .starting
            } else if running && portOpen {
                state = .running
            } else if running {
                state = .starting
            } else if err != nil {
                state = .error
            } else {
                state = .stopped
            }

            return TunnelRuntimeItem(
                config: cfg,
                state: state,
                pid: (needsGost && gostRunning) ? proc?.processIdentifier : nil,
                portOpen: portOpen,
                errorMessage: err
            )
        }
    }

    public func matchesHost(_ config: GostTunnelConfig, host: SSHHost) -> Bool {
        let target = config.hostAlias.lowercased()
        return host.allAliases.contains { $0.lowercased() == target }
    }

    private func reclaimStaleGostIfNeeded(port: Int) {
        guard Self.isTCPPortOpen(port: port, timeoutMs: 100) else { return }
        let res = ProcessRunner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-u", "\(getuid())", "-f", "gost.*127\\.0\\.0\\.1:\(port)"],
            timeout: 2
        )
        guard res.status == 0 else { return }
        let myPIDs: Set<Int32> = {
            lock.lock()
            defer { lock.unlock() }
            return Set(processes.values.filter(\.isRunning).map(\.processIdentifier))
        }()
        for token in res.stdout.split(whereSeparator: \.isWhitespace) {
            if let pid = Int32(token), pid > 1, !myPIDs.contains(pid) {
                kill(pid, SIGTERM)
            }
        }
        usleep(180_000)
    }

    private static func logFileURL(for config: GostTunnelConfig) -> URL {
        let slug = config.label
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/sshdeck-gost-\(slug.isEmpty ? config.id.uuidString : slug).log")
    }

    private static func readLogTail(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let slice = data.suffix(600)
        let lines = String(decoding: slice, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? ""
    }
}
