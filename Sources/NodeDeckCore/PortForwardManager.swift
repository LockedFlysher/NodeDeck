import Darwin
import Foundation
import os

public enum SSHPortForwardDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case remote
    case dynamic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: return "Local (-L)"
        case .remote: return "Remote (-R)"
        case .dynamic: return "SOCKS5 (-D)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .local: return "LOCAL"
        case .remote: return "REMOTE"
        case .dynamic: return "SOCKS5"
        }
    }

    public var symbol: String {
        switch self {
        case .local: return "arrow.down.left.circle"
        case .remote: return "arrow.up.right.circle"
        case .dynamic: return "globe"
        }
    }
}

public struct SSHPortForwardConfig: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var hostAlias: String
    public var label: String
    public var direction: SSHPortForwardDirection
    public var localHost: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var autoStart: Bool
    public var urlScheme: String

    public init(
        id: UUID = UUID(),
        hostAlias: String,
        label: String,
        direction: SSHPortForwardDirection = .local,
        localHost: String = "127.0.0.1",
        localPort: Int,
        remoteHost: String = "127.0.0.1",
        remotePort: Int,
        autoStart: Bool = false,
        urlScheme: String = "http"
    ) {
        self.id = id
        self.hostAlias = hostAlias
        self.label = label
        self.direction = direction
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoStart = autoStart
        self.urlScheme = urlScheme
    }

    public var sshForwardFlag: String {
        switch direction {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    public var sshForwardSpec: String {
        let lHost = localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : localHost
        let rHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : remoteHost
        switch direction {
        case .local:
            return "\(lHost):\(localPort):\(rHost):\(remotePort)"
        case .remote:
            return "\(rHost):\(remotePort):\(lHost):\(localPort)"
        case .dynamic:
            return "\(lHost):\(localPort)"
        }
    }

    public var summaryText: String {
        let lHost = localHost.isEmpty ? "127.0.0.1" : localHost
        let rHost = remoteHost.isEmpty ? "127.0.0.1" : remoteHost
        switch direction {
        case .local:
            return "\(lHost):\(localPort) → \(rHost):\(remotePort)"
        case .remote:
            return "remote \(rHost):\(remotePort) → \(lHost):\(localPort)"
        case .dynamic:
            return "SOCKS5 \(lHost):\(localPort)"
        }
    }

    public var openableURLString: String? {
        guard direction == .local else { return nil }
        let scheme = urlScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !scheme.isEmpty else { return nil }
        let host = (localHost == "0.0.0.0" || localHost.isEmpty) ? "127.0.0.1" : localHost
        return "\(scheme)://\(host):\(localPort)"
    }
}

public enum PortForwardState: String, Equatable, Sendable {
    case stopped
    case starting
    case running
    case error
}

public struct PortForwardRuntimeItem: Identifiable, Equatable, Sendable {
    public var id: UUID { config.id }
    public let config: SSHPortForwardConfig
    public let state: PortForwardState
    public let pid: Int32?
    public let errorMessage: String?

    public var isRunning: Bool { state == .running }

    public init(
        config: SSHPortForwardConfig,
        state: PortForwardState,
        pid: Int32? = nil,
        errorMessage: String? = nil
    ) {
        self.config = config
        self.state = state
        self.pid = pid
        self.errorMessage = errorMessage
    }
}

public enum PortForwardError: LocalizedError {
    case invalidPort(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let detail):
            return detail
        case .processFailed(let detail):
            return detail
        }
    }
}

public final class PortForwardManager: @unchecked Sendable {
    public static let shared = PortForwardManager()

    private struct ManagedProcess {
        let process: Process
        let config: SSHPortForwardConfig
        var state: PortForwardState
        var errorMessage: String?
    }

    private struct State {
        var processes: [UUID: ManagedProcess] = [:]
        var errors: [UUID: String] = [:]
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    public static var defaultConfigFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NodeDeck/port-forwards.json")
    }

    public static func loadConfigs(from url: URL = defaultConfigFileURL) -> [SSHPortForwardConfig] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SSHPortForwardConfig].self, from: data)
        else {
            return []
        }
        return decoded
    }

    public static func saveConfigs(_ configs: [SSHPortForwardConfig], to url: URL = defaultConfigFileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        try data.write(to: url, options: .atomic)
    }

    public func matchesHost(_ config: SSHPortForwardConfig, host: SSHHost) -> Bool {
        let target = config.hostAlias.lowercased()
        return host.allAliases.contains { $0.lowercased() == target }
    }

    public func snapshotItems(for configs: [SSHPortForwardConfig]) -> [PortForwardRuntimeItem] {
        stateLock.withLock { state in
            configs.map { cfg in
                if let managed = state.processes[cfg.id], managed.process.isRunning {
                    return PortForwardRuntimeItem(
                        config: cfg,
                        state: managed.state,
                        pid: managed.process.processIdentifier,
                        errorMessage: managed.errorMessage
                    )
                }
                if let err = state.errors[cfg.id] {
                    return PortForwardRuntimeItem(config: cfg, state: .error, pid: nil, errorMessage: err)
                }
                return PortForwardRuntimeItem(config: cfg, state: .stopped, pid: nil, errorMessage: nil)
            }
        }
    }

    public func start(
        config: SSHPortForwardConfig,
        onUnexpectedExit: (@Sendable () -> Void)? = nil
    ) async throws {
        guard (1...65535).contains(config.localPort) else {
            throw PortForwardError.invalidPort("Local port \(config.localPort) is invalid.")
        }
        if config.direction != .dynamic {
            guard (1...65535).contains(config.remotePort) else {
                throw PortForwardError.invalidPort("Remote port \(config.remotePort) is invalid.")
            }
        }

        stop(id: config.id)

        try await Task.detached(priority: .userInitiated) { [self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-N",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=8",
                config.sshForwardFlag, config.sshForwardSpec,
                config.hostAlias
            ]

            let stderrPipe = Pipe()
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = stderrPipe
            proc.standardInput = FileHandle.nullDevice

            final class ErrorCollector: @unchecked Sendable {
                private let dataLock = OSAllocatedUnfairLock(initialState: Data())
                func append(_ chunk: Data) {
                    dataLock.withLock { $0.append(chunk) }
                }
                func text() -> String {
                    let snapshot = dataLock.withLock { $0 }
                    return String(decoding: snapshot, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            let collector = ErrorCollector()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collector.append(chunk)
                }
            }

            proc.terminationHandler = { [weak self] terminated in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                let wasManaged: Bool = self.stateLock.withLock { state in
                    guard let entry = state.processes[config.id], entry.process === terminated else {
                        return false
                    }
                    state.processes.removeValue(forKey: config.id)
                    let errMsg = collector.text()
                    if terminated.terminationStatus != 0 {
                        state.errors[config.id] = errMsg.isEmpty
                            ? "SSH forward exited with status \(terminated.terminationStatus)"
                            : errMsg
                    }
                    return true
                }
                if wasManaged {
                    onUnexpectedExit?()
                }
            }

            stateLock.withLock { state in
                state.errors.removeValue(forKey: config.id)
                state.processes[config.id] = ManagedProcess(process: proc, config: config, state: .starting, errorMessage: nil)
            }

            do {
                try proc.run()
            } catch {
                stateLock.withLock { state in
                    state.processes.removeValue(forKey: config.id)
                    state.errors[config.id] = error.localizedDescription
                }
                throw PortForwardError.processFailed(error.localizedDescription)
            }

            // Wait up to 6s for local port to open (or for remote forward to stabilize)
            let deadline = Date().addingTimeInterval(6.0)
            var ready = false
            while Date() < deadline {
                if !proc.isRunning {
                    let msg = collector.text()
                    let finalMsg = msg.isEmpty ? "SSH port forward failed to start." : msg
                    stateLock.withLock { state in
                        state.processes.removeValue(forKey: config.id)
                        state.errors[config.id] = finalMsg
                    }
                    throw PortForwardError.processFailed(finalMsg)
                }

                if config.direction == .local || config.direction == .dynamic {
                    if NetworkProbe.isTCPPortOpen(port: config.localPort, timeoutMs: 120) {
                        ready = true
                        break
                    }
                } else {
                    // For remote (-R) forwards, staying alive for 1.5s with ExitOnForwardFailure=yes indicates success
                    if Date().timeIntervalSince(deadline.addingTimeInterval(-6.0)) >= 1.5 {
                        ready = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            if !ready && !proc.isRunning {
                let msg = collector.text()
                throw PortForwardError.processFailed(msg.isEmpty ? "SSH port forward terminated." : msg)
            }

            stateLock.withLock { state in
                if var entry = state.processes[config.id], entry.process === proc {
                    entry.state = .running
                    state.processes[config.id] = entry
                }
            }
        }.value
    }

    public func stop(id: UUID) {
        let entry: ManagedProcess? = stateLock.withLock { state in
            state.errors.removeValue(forKey: id)
            return state.processes.removeValue(forKey: id)
        }

        guard let proc = entry?.process, proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    public func stopAll() {
        let active: [ManagedProcess] = stateLock.withLock { state in
            let list = Array(state.processes.values)
            state.processes.removeAll()
            state.errors.removeAll()
            return list
        }

        for entry in active where entry.process.isRunning {
            entry.process.terminate()
        }
    }
}
