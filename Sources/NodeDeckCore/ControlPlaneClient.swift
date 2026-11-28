import Foundation

public struct ControlPlaneUser: Codable, Equatable, Sendable {
    public let username: String

    public init(username: String = "") {
        self.username = username
    }
}

public struct ControlPlaneDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let role: String
    public let virtualIp: String
    public let virtualCidr: String
    public let sshUser: String
    public let sshPort: Int
    public let sunshineHttpPort: Int
    public let sunshineHttpsPort: Int
    public let sunshineEnabled: Bool
    public let online: Bool
    public let lastSeen: Int64

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case platform
        case role
        case virtualIp = "virtual_ip"
        case virtualCidr = "virtual_cidr"
        case sshUser = "ssh_user"
        case sshPort = "ssh_port"
        case sunshineHttpPort = "sunshine_http_port"
        case sunshineHttpsPort = "sunshine_https_port"
        case sunshineEnabled = "sunshine_enabled"
        case online
        case lastSeen = "last_seen"
    }
}

public struct ControlPlaneMeshInfo: Codable, Equatable, Sendable {
    public let networkName: String
    public let networkSecret: String
    public let subnet: String
    public let seedUri: String
    public let listenPort: Int

    enum CodingKeys: String, CodingKey {
        case networkName = "network_name"
        case networkSecret = "network_secret"
        case subnet
        case seedUri = "seed_uri"
        case listenPort = "listen_port"
    }
}

public struct ControlPlaneClientCert: Codable, Equatable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let uniqueId: String
    public let certPem: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case uniqueId = "unique_id"
        case certPem = "cert_pem"
    }
}

public struct ControlPlaneSshKey: Codable, Equatable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let publicKey: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case publicKey = "public_key"
    }
}

public struct ControlPlaneCommand: Codable, Equatable, Sendable {
    public let id: Int
    public let senderDeviceId: String
    public let action: String
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case senderDeviceId = "sender_device_id"
        case action
        case createdAt = "created_at"
    }
}

public struct ControlPlaneActivateResponse: Codable, Sendable {
    public let ok: Bool
    public let commandId: Int
    public let status: String
    public let targetDevice: ControlPlaneDevice?

    enum CodingKeys: String, CodingKey {
        case ok
        case commandId = "command_id"
        case status
        case targetDevice = "target_device"
    }
}

public struct ControlPlaneCommandStatus: Codable, Sendable {
    public let id: Int
    public let status: String
    public let action: String
    public let sunshineHttpPort: Int?
    public let sunshineHttpsPort: Int?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id, status, action, result
    }

    private struct ResultPayload: Codable {
        let sunshine_http_port: Int?
        let sunshine_https_port: Int?
        let error: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        let r = try c.decodeIfPresent(ResultPayload.self, forKey: .result)
        sunshineHttpPort = r?.sunshine_http_port
        sunshineHttpsPort = r?.sunshine_https_port
        error = r?.error
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(status, forKey: .status)
        try c.encode(action, forKey: .action)
    }
}

public struct ControlPlaneStateResponse: Codable, Sendable {
    public let token: String?
    public let user: ControlPlaneUser
    public let device: ControlPlaneDevice
    public let mesh: ControlPlaneMeshInfo
    public let devices: [ControlPlaneDevice]
    public let clientCerts: [ControlPlaneClientCert]
    public let sshPublicKeys: [ControlPlaneSshKey]
    public let pendingCommands: [ControlPlaneCommand]

    enum CodingKeys: String, CodingKey {
        case token, user, device, mesh, devices
        case clientCerts = "client_certs"
        case sshPublicKeys = "ssh_public_keys"
        case pendingCommands = "pending_commands"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        user = try c.decode(ControlPlaneUser.self, forKey: .user)
        device = try c.decode(ControlPlaneDevice.self, forKey: .device)
        mesh = try c.decode(ControlPlaneMeshInfo.self, forKey: .mesh)
        devices = try c.decodeIfPresent([ControlPlaneDevice].self, forKey: .devices) ?? []
        clientCerts = try c.decodeIfPresent([ControlPlaneClientCert].self, forKey: .clientCerts) ?? []
        sshPublicKeys = try c.decodeIfPresent([ControlPlaneSshKey].self, forKey: .sshPublicKeys) ?? []
        pendingCommands = try c.decodeIfPresent([ControlPlaneCommand].self, forKey: .pendingCommands) ?? []
    }
}

public struct AccountSession: Codable, Equatable, Sendable {
    public var serverUrl: String
    public var username: String
    public var token: String
    public var deviceId: String
    public var deviceName: String
    public var virtualIp: String
    public var virtualCidr: String
    public var mesh: ControlPlaneMeshInfo?

    public var isLoggedIn: Bool {
        !token.isEmpty && !username.isEmpty
    }

    public init(
        serverUrl: String = ControlPlaneClient.defaultServerURL,
        username: String = "",
        token: String = "",
        deviceId: String = "",
        deviceName: String = "",
        virtualIp: String = "",
        virtualCidr: String = "",
        mesh: ControlPlaneMeshInfo? = nil
    ) {
        self.serverUrl = serverUrl
        self.username = username
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.virtualIp = virtualIp
        self.virtualCidr = virtualCidr
        self.mesh = mesh
    }
}

public enum ControlPlaneError: LocalizedError {
    case invalidURL
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Control Plane Server URL"
        case .serverError(let msg):
            return msg
        }
    }
}

public final class ControlPlaneClient: Sendable {
    public static let defaultServerURL = "https://lockedflysher.duckdns.org:8443/nodedeck-api"

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: cfg)
    }

    private func localHostCapabilities() -> (role: String, sunshineEnabled: Bool, httpPort: Int, httpsPort: Int, sshUser: String) {
        let running = SunshineHostManager.shared.currentState() == .running
        return (
            role: running ? "both" : "controller",
            sunshineEnabled: running,
            httpPort: 47989,
            httpsPort: 47984,
            sshUser: NSUserName()
        )
    }

    public func register(
        serverUrl: String,
        username: String,
        password: String,
        inviteCode: String,
        deviceId: String,
        deviceName: String
    ) async throws -> ControlPlaneStateResponse {
        let cap = localHostCapabilities()
        let payload: [String: Any] = [
            "username": username,
            "password": password,
            "invite_code": inviteCode,
            "device_id": deviceId,
            "device_name": deviceName,
            "platform": "macos",
            "role": cap.role,
            "ssh_user": cap.sshUser,
            "ssh_port": 22,
            "sunshine_http_port": cap.httpPort,
            "sunshine_https_port": cap.httpsPort,
            "sunshine_enabled": cap.sunshineEnabled,
            "lan_ips": EmbeddedEasyTierManager.discoverLanIPs()
        ]
        return try await postJSON(serverUrl: serverUrl, path: "/api/v1/auth/register", payload: payload, token: nil)
    }

    public func login(
        serverUrl: String,
        username: String,
        password: String,
        deviceId: String,
        deviceName: String
    ) async throws -> ControlPlaneStateResponse {
        let cap = localHostCapabilities()
        let payload: [String: Any] = [
            "username": username,
            "password": password,
            "device_id": deviceId,
            "device_name": deviceName,
            "platform": "macos",
            "role": cap.role,
            "ssh_user": cap.sshUser,
            "ssh_port": 22,
            "sunshine_http_port": cap.httpPort,
            "sunshine_https_port": cap.httpsPort,
            "sunshine_enabled": cap.sunshineEnabled,
            "lan_ips": EmbeddedEasyTierManager.discoverLanIPs()
        ]
        return try await postJSON(serverUrl: serverUrl, path: "/api/v1/auth/login", payload: payload, token: nil)
    }

    public func heartbeat(
        serverUrl: String,
        token: String,
        deviceName: String,
        meshIpv4: String
    ) async throws -> ControlPlaneStateResponse {
        let cap = localHostCapabilities()
        let payload: [String: Any] = [
            "device_name": deviceName,
            "platform": "macos",
            "role": cap.role,
            "ssh_user": cap.sshUser,
            "ssh_port": 22,
            "sunshine_http_port": cap.httpPort,
            "sunshine_https_port": cap.httpsPort,
            "sunshine_enabled": cap.sunshineEnabled,
            "lan_ips": EmbeddedEasyTierManager.discoverLanIPs(excludingSubnetOf: meshIpv4)
        ]
        return try await postJSON(serverUrl: serverUrl, path: "/api/v1/devices/heartbeat", payload: payload, token: token)
    }

    public func registerClientCert(
        serverUrl: String,
        token: String,
        deviceName: String,
        uniqueId: String,
        certPem: String
    ) async throws {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/v1/certs/register") else {
            throw ControlPlaneError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "device_name": deviceName,
            "unique_id": uniqueId,
            "cert_pem": certPem
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ControlPlaneError.serverError(text)
        }
    }

    public func registerSshPublicKey(
        serverUrl: String,
        token: String,
        deviceName: String,
        publicKey: String
    ) async throws {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/v1/ssh-keys/register") else {
            throw ControlPlaneError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "device_name": deviceName,
            "public_key": publicKey
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ControlPlaneError.serverError(text)
        }
    }

    public func activateDevice(
        serverUrl: String,
        token: String,
        targetDeviceId: String = "",
        targetName: String = "",
        targetIp: String = "",
        action: String = "activate_host"
    ) async throws -> ControlPlaneActivateResponse {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/v1/devices/activate") else {
            throw ControlPlaneError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "target_device_id": targetDeviceId,
            "target_name": targetName,
            "target_ip": targetIp,
            "action": action
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String, !err.isEmpty {
                throw ControlPlaneError.serverError(err)
            }
            throw ControlPlaneError.serverError("HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ControlPlaneActivateResponse.self, from: data)
    }

    public func getCommandStatus(
        serverUrl: String,
        token: String,
        commandId: Int
    ) async throws -> ControlPlaneCommandStatus {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/v1/commands/\(commandId)") else {
            throw ControlPlaneError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ControlPlaneError.serverError("HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ControlPlaneCommandStatus.self, from: data)
    }

    public func ackCommand(
        serverUrl: String,
        token: String,
        commandId: Int,
        status: String,
        result: [String: Any]
    ) async {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/v1/commands/\(commandId)/ack") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["status": status, "result": result]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
    }

    public func logout(serverUrl: String, token: String) async {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/v1/auth/logout") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)
        _ = try? await session.data(for: req)
    }

    private func postJSON(
        serverUrl: String,
        path: String,
        payload: [String: Any],
        token: String?
    ) async throws -> ControlPlaneStateResponse {
        let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)\(path)") else {
            throw ControlPlaneError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String, !err.isEmpty {
                throw ControlPlaneError.serverError(err)
            }
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ControlPlaneError.serverError(text)
        }
        return try JSONDecoder().decode(ControlPlaneStateResponse.self, from: data)
    }
}

public enum EmbeddedEasyTierManager {
    public static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NodeDeck", isDirectory: true)
    }

    public static var accountFileURL: URL {
        appSupportDir.appendingPathComponent("account.json")
    }

    public static var meshDirURL: URL {
        appSupportDir.appendingPathComponent("mesh", isDirectory: true)
    }

    public static var runtimeTomlURL: URL {
        meshDirURL.appendingPathComponent("runtime.toml")
    }

    public static var deviceIdKey: String { "nodedeck.controlPlane.deviceId" }

    public static func getOrCreateDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = "macos-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
        UserDefaults.standard.set(created, forKey: deviceIdKey)
        return created
    }

    public static func loadSession() -> AccountSession {
        guard let data = try? Data(contentsOf: accountFileURL),
              let sess = try? JSONDecoder().decode(AccountSession.self, from: data) else {
            return AccountSession()
        }
        return sess
    }

    public static func saveSession(_ session: AccountSession) {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: accountFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountFileURL.path)
        }
    }

    public static func resolveEasyTierBinary() -> String? {
        var candidates: [String] = []
        if let bundlePath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/easytier-core").path as String? {
            candidates.append(bundlePath)
        }
        candidates.append("/usr/local/bin/easytier-core")
        candidates.append("/opt/homebrew/bin/easytier-core")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func discoverLanIPs(excludingSubnetOf meshIpv4: String = "") -> [String] {
        let prefix3: String
        let parts = meshIpv4.split(separator: "/").first?.split(separator: ".") ?? []
        if parts.count == 4 {
            prefix3 = "\(parts[0]).\(parts[1]).\(parts[2])."
        } else {
            prefix3 = ""
        }
        var results = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("en"),
               let sa = current.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && (prefix3.isEmpty || !ip.hasPrefix(prefix3)) {
                        results.insert(ip)
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return results.sorted()
    }

    /// Expands seed URI(s) so UDP relay is tried first (avoiding TCP-over-TCP jitter on relay fallback)
    /// while keeping TCP as automatic fallback when UDP is firewalled.
    /// If multiple explicit URIs are provided (e.g. separate UDP and TCP ports such as
    /// `udp://host:25565,tcp://host:11010`), preserve them verbatim with UDP ordered first.
    public static func expandSeedUris(_ raw: String) -> [String] {
        let tokens = raw
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if tokens.count > 1 {
            let udps = tokens.filter { $0.hasPrefix("udp://") }
            let others = tokens.filter { !$0.hasPrefix("udp://") }
            var ordered: [String] = []
            for uri in udps + others where !ordered.contains(uri) {
                ordered.append(uri)
            }
            return ordered
        }
        var ordered: [String] = []
        for uri in tokens {
            if uri.hasPrefix("tcp://") {
                let udpUri = "udp://" + uri.dropFirst("tcp://".count)
                if !ordered.contains(udpUri) { ordered.append(udpUri) }
                if !ordered.contains(uri) { ordered.append(uri) }
            } else if uri.hasPrefix("udp://") {
                if !ordered.contains(uri) { ordered.append(uri) }
                let tcpUri = "tcp://" + uri.dropFirst("udp://".count)
                if !ordered.contains(tcpUri) { ordered.append(tcpUri) }
            } else if !ordered.contains(uri) {
                ordered.append(uri)
            }
        }
        return ordered
    }

    public static func writeRuntimeToml(for session: AccountSession) throws -> URL {
        guard let mesh = session.mesh else {
            throw ControlPlaneError.serverError("Missing mesh credentials in account session")
        }
        try FileManager.default.createDirectory(at: meshDirURL, withIntermediateDirectories: true)
        let lanIPs = discoverLanIPs(excludingSubnetOf: session.virtualCidr)
        let port = max(1024, min(65535, mesh.listenPort))
        let mapped = lanIPs.map { "\"udp://\($0):\(port)\"" }.joined(separator: ", ")
        let peerBlocks = expandSeedUris(mesh.seedUri)
            .map { "[[peer]]\nuri = \"\($0)\"" }
            .joined(separator: "\n\n")
        let toml = """
        hostname = "\(session.deviceName.isEmpty ? "mac" : session.deviceName)"
        ipv4 = "\(session.virtualCidr)"
        listeners = ["udp://0.0.0.0:\(port)", "tcp://0.0.0.0:\(port)"]
        mapped_listeners = [\(mapped)]

        [network_identity]
        network_name = "\(mesh.networkName)"
        network_secret = "\(mesh.networkSecret)"

        \(peerBlocks)

        [flags]
        default_protocol = "udp"
        multi_thread = true
        latency_first = true
        """
        try toml.write(to: runtimeTomlURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeTomlURL.path)
        return runtimeTomlURL
    }

    public static func ensureLocalSshPublicKey() -> String? {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)

        for cand in ["id_ed25519.pub", "id_rsa.pub"] {
            let p = sshDir.appendingPathComponent(cand)
            if let txt = try? String(contentsOf: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               txt.hasPrefix("ssh-ed25519 ") || txt.hasPrefix("ssh-rsa ") || txt.hasPrefix("ecdsa-sha2-") {
                return txt
            }
        }
        let keyURL = sshDir.appendingPathComponent("id_ed25519")
        let pubURL = sshDir.appendingPathComponent("id_ed25519.pub")
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            let host = Host.current().localizedName ?? "mac"
            _ = ProcessRunner.run(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-t", "ed25519", "-N", "", "-f", keyURL.path, "-C", "nodedeck@\(host)", "-q"],
                timeout: 10
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return try? String(contentsOf: pubURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public static func syncAccountSshPublicKeys(_ keys: [ControlPlaneSshKey]) -> Int {
        guard !keys.isEmpty else { return 0 }
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)

        let authURL = sshDir.appendingPathComponent("authorized_keys")
        var lines = (try? String(contentsOf: authURL, encoding: .utf8))?
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty } ?? []
        var existingBlobs = Set<String>()
        for ln in lines {
            let parts = ln.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                existingBlobs.insert("\(parts[0]) \(parts[1])")
            }
        }

        var added = 0
        for item in keys {
            let pub = item.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pub.isEmpty, !pub.contains("\n"), !pub.contains("\r") else { continue }
            let parts = pub.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  parts[0].hasPrefix("ssh-ed25519") || parts[0].hasPrefix("ssh-rsa") || parts[0].hasPrefix("ecdsa-sha2-") else {
                continue
            }
            let blob = "\(parts[0]) \(parts[1])"
            guard !existingBlobs.contains(blob) else { continue }
            let safeName = item.deviceName.replacingOccurrences(of: " ", with: "_")
            lines.append("\(blob) nodedeck-\(safeName)")
            existingBlobs.insert(blob)
            added += 1
        }
        if added > 0 {
            let out = lines.joined(separator: "\n") + "\n"
            try? out.write(to: authURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        }
        return added
    }

    public static func readPublicMoonlightIdentity() -> (uniqueId: String, certPem: String)? {
        let mlDir = appSupportDir.appendingPathComponent("moonlight", isDirectory: true)
        let uidURL = mlDir.appendingPathComponent("uniqueid.txt")
        let certURL = mlDir.appendingPathComponent("client.crt")
        guard let uid = try? String(contentsOf: uidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let cert = try? String(contentsOf: certURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty, cert.contains("BEGIN CERTIFICATE") else {
            return nil
        }
        return (uid, cert)
    }

    public static func resolveMeshDaemonBinary() -> String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nodedeck-mesh-daemon").path,
            "/Applications/NodeDeck.app/Contents/Helpers/nodedeck-mesh-daemon",
            "/usr/local/bin/nodedeck-mesh-daemon"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// Returns true once the self-healing pure-Rust `nodedeck-mesh-daemon` LaunchDaemon is installed
    /// (which automatically tracks Control Plane seed_uri & LAN IP changes without further user clicks).
    public static func isAutoMeshDaemonInstalled() -> Bool {
        let plistPath = "/Library/LaunchDaemons/io.nodedeck.mesh.plist"
        guard let txt = try? String(contentsOfFile: plistPath, encoding: .utf8) else {
            return false
        }
        return txt.contains("nodedeck-mesh-daemon")
    }

    /// Installs or upgrades the macOS system LaunchDaemon (`io.nodedeck.mesh`) ONCE via macOS Admin prompt.
    /// Uses the pure-Rust `nodedeck-mesh-daemon` so future seed_uri / Wi-Fi / account updates reload
    /// `easytier-core` 100% automatically with zero user interaction.
    public static func installAndStartSystemMeshDaemon(tomlURL: URL) async throws {
        let daemonBin = resolveMeshDaemonBinary()
        guard let etBin = resolveEasyTierBinary() else {
            throw ControlPlaneError.serverError("Built-in easytier-core binary not found")
        }
        let plistPath = "/Library/LaunchDaemons/io.nodedeck.mesh.plist"
        let confDst = "/etc/nodedeck/easytier-runtime.toml"
        let acctSrc = appSupportDir.appendingPathComponent("account.json").path.replacingOccurrences(of: "'", with: "'\\''")
        let acctDst = "/etc/nodedeck/account.json"
        let escapedSrc = tomlURL.path.replacingOccurrences(of: "'", with: "'\\''")

        let programArgsXml: String
        if let daemonBin {
            let escapedDaemon = daemonBin.replacingOccurrences(of: "'", with: "'\\''")
            programArgsXml = """
            <string>\(escapedDaemon)</string>
            <string>--state-dir</string>
            <string>/etc/nodedeck</string>
            <string>daemon</string>
            """
        } else {
            let escapedBin = etBin.replacingOccurrences(of: "'", with: "'\\''")
            programArgsXml = """
            <string>\(escapedBin)</string>
            <string>-c</string>
            <string>\(confDst)</string>
            """
        }

        let shellCmd = """
        mkdir -p /etc/nodedeck && chmod 700 /etc/nodedeck && \
        cp '\(escapedSrc)' '\(confDst)' && chmod 600 '\(confDst)' && \
        ([ -f '\(acctSrc)' ] && cp '\(acctSrc)' '\(acctDst)' && chmod 600 '\(acctDst)' || true) && \
        launchctl bootout system '\(plistPath)' 2>/dev/null || true; \
        cat > '\(plistPath)' <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>io.nodedeck.mesh</string>
          <key>ProgramArguments</key>
          <array>
            \(programArgsXml)
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
        </dict>
        </plist>
        PLIST
        chmod 644 '\(plistPath)' && launchctl bootstrap system '\(plistPath)'
        """
        let appleScript = "do shell script \"\(shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Authorization cancelled"
            throw ControlPlaneError.serverError(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func resolveEasyTierCliBinary() -> String? {
        var candidates: [String] = []
        let bundleHelpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/easytier-cli").path
        candidates.append(bundleHelpers)
        candidates.append("/Applications/NodeDeck.app/Contents/Helpers/easytier-cli")
        candidates.append("/usr/local/bin/easytier-cli")
        candidates.append("/opt/homebrew/bin/easytier-cli")
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// Queries local EasyTier daemon via `easytier-cli -o json peer` + `route` to resolve
    /// the real transport mode (P2P UDP / P2P TCP / UDP Relay / TCP Relay) for every mesh peer.
    public static func fetchLivePeerTransports() -> [MeshPeerTransport] {
        guard let cli = resolveEasyTierCliBinary() else { return [] }
        guard let peerData = runQuickCli(cli, args: ["-o", "json", "peer"]),
              let peerArr = (try? JSONSerialization.jsonObject(with: peerData)) as? [[String: Any]] else {
            return []
        }

        // Build hostname -> tunnel_proto map so relayed peers inherit their next-hop relay's protocol (udp vs tcp).
        var protoByHost: [String: String] = [:]
        var lossByHost: [String: Double] = [:]
        for item in peerArr {
            let h = (item["hostname"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tp = (item["tunnel_proto"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !h.isEmpty, !tp.isEmpty, tp != "-" {
                protoByHost[h.lowercased()] = tp
            }
            if !h.isEmpty, let lossStr = item["loss_rate"] as? String {
                let cleaned = lossStr.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let val = Double(cleaned) {
                    lossByHost[h.lowercased()] = val
                }
            }
        }

        var nextHopByIp: [String: String] = [:]
        var nextHopByHost: [String: String] = [:]
        if let routeData = runQuickCli(cli, args: ["-o", "json", "route"]),
           let routeArr = (try? JSONSerialization.jsonObject(with: routeData)) as? [[String: Any]] {
            for r in routeArr {
                let ip = (r["ipv4"] as? String ?? "").components(separatedBy: "/").first ?? ""
                let h = (r["hostname"] as? String ?? "").lowercased()
                let nh = (r["next_hop_hostname"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !nh.isEmpty && nh != "DIRECT" && nh != "Local" {
                    if !ip.isEmpty { nextHopByIp[ip] = nh }
                    if !h.isEmpty { nextHopByHost[h] = nh }
                }
            }
        }

        var results: [MeshPeerTransport] = []
        for item in peerArr {
            let costRaw = (item["cost"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if costRaw.caseInsensitiveCompare("Local") == .orderedSame { continue }
            let ip = (item["ipv4"] as? String ?? "").components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hostname = (item["hostname"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ip.isEmpty && hostname.isEmpty { continue }

            let isP2P = costRaw.lowercased() == "p2p"
            var hopCount = isP2P ? 1 : 2
            if !isP2P, let open = costRaw.firstIndex(of: "("), let close = costRaw.firstIndex(of: ")"), open < close {
                let inner = String(costRaw[costRaw.index(after: open)..<close])
                if let n = Int(inner) { hopCount = n }
            }

            var proto = (item["tunnel_proto"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if proto == "-" { proto = "" }
            let relayVia = nextHopByIp[ip] ?? nextHopByHost[hostname.lowercased()] ?? ""
            if !isP2P && proto.isEmpty {
                if !relayVia.isEmpty, let hopProto = protoByHost[relayVia.lowercased()] {
                    proto = hopProto
                } else if let seedProto = protoByHost.first(where: { $0.key.contains("seed") || $0.key.contains("public") })?.value {
                    proto = seedProto
                }
            }

            let latMs: Double? = {
                if let s = item["lat_ms"] as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let n = item["lat_ms"] as? Double { return n }
                return nil
            }()

            var lossPct: Double? = {
                if let s = item["loss_rate"] as? String {
                    let cleaned = s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return Double(cleaned)
                }
                return nil
            }()
            if !isP2P && (lossPct == nil || lossPct == 0) {
                if !relayVia.isEmpty, let hopLoss = lossByHost[relayVia.lowercased()], hopLoss > 0 {
                    lossPct = hopLoss
                }
            }

            results.append(MeshPeerTransport(
                ipv4: ip,
                hostname: hostname,
                isP2P: isP2P,
                hopCount: hopCount,
                tunnelProto: proto,
                relayVia: relayVia,
                latencyMs: latMs,
                lossRatePct: lossPct
            ))
        }
        return results
    }

    public static func matchPeerTransport(
        peers: [MeshPeerTransport],
        address: String,
        alias: String? = nil
    ) -> MeshPeerTransport? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !addr.isEmpty, let byIp = peers.first(where: { !$0.ipv4.isEmpty && $0.ipv4.lowercased() == addr }) {
            return byIp
        }
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !alias.isEmpty {
            if let byHost = peers.first(where: { $0.hostname.lowercased() == alias }) {
                return byHost
            }
        }
        return nil
    }

    private static func runQuickCli(_ bin: String, args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(1.5)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        return outPipe.fileHandleForReading.readDataToEndOfFile()
    }
}

public struct MeshPeerTransport: Equatable, Sendable {
    public let ipv4: String
    public let hostname: String
    public let isP2P: Bool
    public let hopCount: Int
    public let tunnelProto: String
    public let relayVia: String
    public let latencyMs: Double?
    public let lossRatePct: Double?

    public init(
        ipv4: String,
        hostname: String,
        isP2P: Bool,
        hopCount: Int,
        tunnelProto: String,
        relayVia: String = "",
        latencyMs: Double? = nil,
        lossRatePct: Double? = nil
    ) {
        self.ipv4 = ipv4
        self.hostname = hostname
        self.isP2P = isP2P
        self.hopCount = hopCount
        self.tunnelProto = tunnelProto
        self.relayVia = relayVia
        self.latencyMs = latencyMs
        self.lossRatePct = lossRatePct
    }

    public var isTcpRelay: Bool {
        let p = tunnelProto.lowercased()
        return !isP2P && p.contains("tcp") && !p.contains("udp")
    }

    public var isUdpRelay: Bool {
        !isP2P && tunnelProto.lowercased().contains("udp")
    }

    public var shortBadge: String {
        let p = tunnelProto.lowercased()
        if isP2P {
            if p.contains("udp") { return "P2P · UDP" }
            if p.contains("tcp") { return "P2P · TCP" }
            if !p.isEmpty { return "P2P · \(p.uppercased())" }
            return "P2P"
        }
        if p.contains("udp") { return "UDP Relay" }
        if p.contains("tcp") { return "TCP Relay" }
        return "Relay(\(hopCount))"
    }

    public var detailedBadge: String {
        var parts = [shortBadge]
        if let lat = latencyMs, lat > 0 {
            parts.append("\(Int(lat.rounded()))ms")
        }
        if let loss = lossRatePct, loss >= 5.0 {
            parts.append("loss \(Int(loss.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }
}
