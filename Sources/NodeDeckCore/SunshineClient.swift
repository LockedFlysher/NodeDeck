import CMoonlightCommon
import Foundation
import Security

public struct SunshineHostConfig: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var hostAlias: String
    public var address: String
    public var httpPort: Int
    public var httpsPort: Int
    public var serverName: String
    public var serverCertPEM: String?
    public var isPaired: Bool

    public init(
        id: UUID = UUID(),
        hostAlias: String,
        address: String,
        httpPort: Int = 47989,
        httpsPort: Int = 47984,
        serverName: String = "",
        serverCertPEM: String? = nil,
        isPaired: Bool = false
    ) {
        self.id = id
        self.hostAlias = hostAlias
        self.address = address
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.serverName = serverName
        self.serverCertPEM = serverCertPEM
        self.isPaired = isPaired
    }

    public var webUIURLString: String {
        "https://\(address):\(httpPort + 1)"
    }
}

public struct SunshineServerInfo: Equatable, Sendable {
    public let hostname: String
    public let appVersion: String
    public let gfeVersion: String
    public let httpsPort: Int
    public let pairStatus: Bool
    public let currentGame: Int
    public let serverCodecModeSupport: Int
}

public struct SunshineApp: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
}

public struct SunshineLaunchSession: Sendable {
    public let address: String
    public let httpPort: Int
    public let httpsPort: Int
    public let appVersion: String
    public let gfeVersion: String
    public let serverCodecModeSupport: Int
    public let rtspSessionURL: String
    public let rikey: Data
    public let rikeyId: Int32
    public let appId: Int
    public let appTitle: String
}

public enum SunshineError: LocalizedError {
    case identityCreationFailed
    case networkError(String)
    case invalidResponse(String)
    case pairingFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .identityCreationFailed:
            return "Failed to generate local Moonlight client TLS certificate."
        case .networkError(let msg):
            return "Sunshine connection failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid Sunshine response: \(msg)"
        case .pairingFailed(let msg):
            return "Sunshine pairing failed: \(msg)"
        case .launchFailed(let msg):
            return "Failed to launch Sunshine stream: \(msg)"
        }
    }
}

public final class SunshineClient: @unchecked Sendable {
    public static let shared = SunshineClient()

    private let p12Password = "nodedeck-moonlight"
    private let lock = NSLock()
    private var cachedCertPEM: String?
    private var cachedUniqueId: String?
    private var cachedSession: URLSession?

    private init() {}

    public static var storageDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NodeDeck/moonlight")
    }

    public static var hostsConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NodeDeck/sunshine-hosts.json")
    }

    public static func loadSavedHosts(from url: URL = hostsConfigURL) -> [SunshineHostConfig] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SunshineHostConfig].self, from: data)
        else {
            return []
        }
        return decoded
    }

    public static func saveHosts(_ hosts: [SunshineHostConfig], to url: URL = hostsConfigURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(hosts)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Client Identity (Cert + Key + PKCS12 + UniqueID)

    private func ensureIdentity() throws -> (certPEM: String, uniqueId: String, session: URLSession) {
        lock.lock()
        if let cert = cachedCertPEM, let uid = cachedUniqueId, let sess = cachedSession {
            lock.unlock()
            return (cert, uid, sess)
        }
        lock.unlock()

        let dir = Self.storageDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let certURL = dir.appendingPathComponent("client.crt")
        let keyURL = dir.appendingPathComponent("client.key")
        let p12URL = dir.appendingPathComponent("client.p12")
        let uidURL = dir.appendingPathComponent("uniqueid.txt")

        if !FileManager.default.fileExists(atPath: certURL.path) ||
            !FileManager.default.fileExists(atPath: keyURL.path) ||
            !FileManager.default.fileExists(atPath: p12URL.path) {
            let rc = nd_generate_client_identity(certURL.path, keyURL.path, p12URL.path, p12Password)
            guard rc == 0 else {
                throw SunshineError.identityCreationFailed
            }
        }

        let uniqueId: String
        if let existing = try? String(contentsOf: uidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            uniqueId = existing
        } else {
            let randomHex = Self.randomBytes(count: 8).map { String(format: "%02x", $0) }.joined()
            try randomHex.write(to: uidURL, atomically: true, encoding: .utf8)
            uniqueId = randomHex
        }

        guard let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
              let p12Data = try? Data(contentsOf: p12URL)
        else {
            throw SunshineError.identityCreationFailed
        }

        let identity = try loadPKCS12Identity(data: p12Data, password: p12Password)
        let delegate = SunshineTLSDelegate(identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        lock.lock()
        cachedCertPEM = certPEM
        cachedUniqueId = uniqueId
        cachedSession = session
        lock.unlock()

        return (certPEM, uniqueId, session)
    }

    private func loadPKCS12Identity(data: Data, password: String) throws -> SecIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else {
            throw SunshineError.identityCreationFailed
        }
        return (identityRef as! SecIdentity)
    }

    // MARK: - API Calls

    public func fetchServerInfo(address: String, httpPort: Int = 47989) async throws -> SunshineServerInfo {
        let (_, uniqueId, session) = try ensureIdentity()
        let xml = try await requestXML(
            session: session,
            scheme: "http",
            address: address,
            port: httpPort,
            path: "/serverinfo",
            query: ["uniqueid": uniqueId, "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: "")]
        )
        let root = SimpleXMLParser.parse(xml)
        let hostname = root.firstText("hostname") ?? address
        let appVersion = root.firstText("appversion") ?? "7.1.431.0"
        let gfeVersion = root.firstText("GfeVersion") ?? "3.23.0.74"
        let httpsPort = Int(root.firstText("HttpsPort") ?? "") ?? (httpPort - 5)
        let pairStatus = root.firstText("PairStatus") == "1"
        let currentGame = Int(root.firstText("currentgame") ?? "") ?? 0
        let codecSupport = Int(root.firstText("ServerCodecModeSupport") ?? "") ?? 0

        return SunshineServerInfo(
            hostname: hostname,
            appVersion: appVersion,
            gfeVersion: gfeVersion,
            httpsPort: httpsPort,
            pairStatus: pairStatus,
            currentGame: currentGame,
            serverCodecModeSupport: codecSupport
        )
    }

    public func fetchAppList(address: String, httpsPort: Int = 47984) async throws -> [SunshineApp] {
        let (_, uniqueId, session) = try ensureIdentity()
        let xml = try await requestXML(
            session: session,
            scheme: "https",
            address: address,
            port: httpsPort,
            path: "/applist",
            query: ["uniqueid": uniqueId, "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: "")]
        )
        let root = SimpleXMLParser.parse(xml)
        return root.children(named: "App").compactMap { node in
            guard let idStr = node.firstText("ID"), let id = Int(idStr),
                  let title = node.firstText("AppTitle")
            else { return nil }
            return SunshineApp(id: id, title: title)
        }
    }

    public func launchStream(
        address: String,
        httpPort: Int = 47989,
        preferredAppTitle: String = "Desktop",
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60
    ) async throws -> SunshineLaunchSession {
        let (_, uniqueId, session) = try ensureIdentity()
        let info = try await fetchServerInfo(address: address, httpPort: httpPort)
        let apps = try await fetchAppList(address: address, httpsPort: info.httpsPort)

        let targetApp = apps.first(where: { $0.title.caseInsensitiveCompare(preferredAppTitle) == .orderedSame })
            ?? apps.first(where: { $0.title.localizedCaseInsensitiveContains("desktop") })
            ?? apps.first
        guard let app = targetApp else {
            throw SunshineError.launchFailed("No applications found on Sunshine host.")
        }

        let rikey = Self.randomBytes(count: 16)
        let rikeyId = Int32.random(in: 1...Int32.max)
        let actionPath = (info.currentGame == app.id && info.currentGame != 0) ? "/resume" : "/launch"

        let xml = try await requestXML(
            session: session,
            scheme: "https",
            address: address,
            port: info.httpsPort,
            path: actionPath,
            query: [
                "uniqueid": uniqueId,
                "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "appid": String(app.id),
                "mode": "\(width)x\(height)x\(fps)",
                "additionalStates": "1",
                "sops": "0",
                "rikey": Self.toHex(rikey),
                "rikeyid": String(rikeyId),
                "localAudioPlayMode": "0",
                "surroundAudioInfo": "196610",
                "remoteControllersBitmap": "0",
                "gcmap": "0",
                "gcpersist": "0"
            ],
            timeout: 20
        )

        let root = SimpleXMLParser.parse(xml)
        let sessionURL = root.firstText("sessionUrl0") ?? "rtsp://\(address):48010"
        let launched = root.firstText("gamesession") == "1" || root.firstText("resume") == "1" || root.firstText("sessionUrl0") != nil
        guard launched else {
            let msg = root.attributes["status_message"] ?? "Sunshine declined stream launch."
            throw SunshineError.launchFailed(msg)
        }

        return SunshineLaunchSession(
            address: address,
            httpPort: httpPort,
            httpsPort: info.httpsPort,
            appVersion: info.appVersion,
            gfeVersion: info.gfeVersion,
            serverCodecModeSupport: info.serverCodecModeSupport,
            rtspSessionURL: sessionURL,
            rikey: rikey,
            rikeyId: rikeyId,
            appId: app.id,
            appTitle: app.title
        )
    }

    public func pairViaSudoerSSH(
        hostAlias: String,
        address: String,
        httpPort: Int = 47989,
        password: String
    ) async throws -> SunshineHostConfig {
        let (certPEM, uniqueId, _) = try ensureIdentity()
        let certB64 = Data(certPEM.utf8).base64EncodedString()
        let passB64 = Data(password.utf8).base64EncodedString()
        let clientName = "NodeDeck-\(Host.current().localizedName ?? "Mac")"

        // Remote script:
        // 1) Verifies sudoer credentials with `sudo -S -v` (if password supplied)
        // 2) Injects NodeDeck's client.crt directly into ~/.config/sunshine/sunshine_state.json (zero PIN needed!)
        // 3) Reloads/restarts Sunshine so the new client cert is immediately trusted
        // 4) Prints detected HTTP port
        let remotePy = """
        import base64, json, os, re, subprocess, sys, time, uuid

        pwd = base64.b64decode("\(passB64)").decode("utf-8", errors="ignore")
        cert_pem = base64.b64decode("\(certB64)").decode("utf-8")
        client_name = \(jsonStringLiteral(clientName))
        client_uid = \(jsonStringLiteral(uniqueId))

        if pwd:
            p = subprocess.run(["sudo", "-S", "-k", "-v"], input=(pwd + "\\n").encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if p.returncode != 0:
                print("ERR:SUDO_AUTH_FAILED", file=sys.stderr)
                sys.exit(11)

        candidates = [
            (os.path.expanduser("~/.config/nodedeck"), "host.conf", "host_state.json"),
            (os.path.expanduser("~/.config/nodedeck/host"), "host.conf", "sunshine_state.json"),
            (os.path.expanduser("~/.config/sunshine"), "sunshine.conf", "sunshine_state.json"),
        ]
        conf_dir, conf_name, default_state = candidates[0]
        for c_dir, c_name, d_state in candidates:
            if os.path.exists(os.path.join(c_dir, c_name)):
                conf_dir, conf_name, default_state = c_dir, c_name, d_state
                break
        else:
            if not os.path.exists("/opt/nodedeck/host/bin/nodedeck-host"):
                conf_dir, conf_name, default_state = candidates[2]
        os.makedirs(conf_dir, exist_ok=True)
        conf_path = os.path.join(conf_dir, conf_name)
        state_path = os.path.join(conf_dir, default_state)

        detected_port = \(httpPort)
        if os.path.exists(conf_path):
            txt = open(conf_path, "r", encoding="utf-8", errors="ignore").read()
            m = re.search(r"^\\s*port\\s*=\\s*(\\d+)", txt, re.M)
            if m:
                detected_port = int(m.group(1))
            ms = re.search(r"^\\s*file_state\\s*=\\s*(.+)$", txt, re.M)
            if ms:
                raw_st = ms.group(1).strip().replace("$HOME", os.path.expanduser("~"))
                if not re.match(r"^/bin/(ba|z|da)?sh/", raw_st):
                    state_path = raw_st if os.path.isabs(raw_st) else os.path.join(conf_dir, raw_st)
        os.makedirs(os.path.dirname(state_path), exist_ok=True)

        state = {}
        if os.path.exists(state_path):
            try:
                state = json.load(open(state_path, "r", encoding="utf-8"))
            except Exception:
                state = {}

        root = state.setdefault("root", {})
        if not root.get("uniqueid"):
            root["uniqueid"] = str(uuid.uuid4()).upper()
        devices = root.setdefault("named_devices", [])
        devices = [d for d in devices if d.get("cert") != cert_pem and d.get("name") != client_name]
        devices.append({
            "name": client_name,
            "uuid": str(uuid.uuid5(uuid.NAMESPACE_DNS, "nodedeck-" + client_uid)).upper(),
            "cert": cert_pem
        })
        root["named_devices"] = devices

        with open(state_path, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)

        # Reload NodeDeck integrated host (or legacy sunshine) so it picks up the newly trusted client certificate
        restarted = False
        for svc in ["nodedeck-host", "foundation-sunshine", "sunshine"]:
            if subprocess.run(["systemctl", "--user", "is-active", "--quiet", svc]).returncode == 0:
                subprocess.run(["systemctl", "--user", "restart", svc], check=False)
                restarted = True
                break
        if not restarted:
            pg = subprocess.run(["pgrep", "-fa", "nodedeck-host|sunshine"], stdout=subprocess.PIPE, text=True)
            cmdline = None
            for line in pg.stdout.splitlines():
                parts = line.split(None, 1)
                if len(parts) == 2 and ("nodedeck-host" in parts[1] or "sunshine" in parts[1]) and "python" not in parts[1]:
                    cmdline = parts[1]
                    break
            if cmdline:
                subprocess.run(["pkill", "-f", "nodedeck-host|sunshine"], check=False)
                time.sleep(0.8)
                subprocess.Popen(cmdline, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                restarted = True

        print(f"OK:{detected_port}:{int(restarted)}")
        """

        let result = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    "-o", "ControlMaster=no",
                    hostAlias,
                    "python3", "-"
                ],
                input: remotePy,
                timeout: 18
            )
        }.value

        if result.status != 0 {
            if result.stderr.contains("ERR:SUDO_AUTH_FAILED") {
                throw SunshineError.pairingFailed("远端主机 sudoer 密码校验失败，请检查账号和密码。")
            }
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SunshineError.pairingFailed(msg.isEmpty ? "SSH 自动注入配对证书失败 (exit \(result.status))" : msg)
        }

        var resolvedPort = httpPort
        if let okLine = result.stdout.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("OK:") }) {
            let parts = okLine.split(separator: ":")
            if parts.count >= 2, let p = Int(parts[1]) {
                resolvedPort = p
            }
        }

        // Wait briefly for Sunshine to finish restarting and verify mutual TLS /serverinfo
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let info = try await fetchServerInfo(address: address, httpPort: resolvedPort)

        return SunshineHostConfig(
            hostAlias: hostAlias,
            address: address,
            httpPort: resolvedPort,
            httpsPort: info.httpsPort,
            serverName: info.hostname,
            serverCertPEM: nil,
            isPaired: true
        )
    }

    private func jsonStringLiteral(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let str = String(data: data, encoding: .utf8),
           str.count >= 2 {
            return String(str.dropFirst().dropLast())
        }
        return "\"NodeDeck\""
    }

    public func cancelSession(address: String, httpsPort: Int = 47984) async {
        guard let (_, uniqueId, session) = try? ensureIdentity() else { return }
        _ = try? await requestXML(
            session: session,
            scheme: "https",
            address: address,
            port: httpsPort,
            path: "/cancel",
            query: ["uniqueid": uniqueId, "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: "")]
        )
    }

    // MARK: - HTTP Helper

    private func requestXML(
        session: URLSession,
        scheme: String,
        address: String,
        port: Int,
        path: String,
        query: [String: String],
        timeout: TimeInterval = 12
    ) async throws -> String {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = address
        comps.port = port
        comps.path = path
        comps.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else {
            throw SunshineError.networkError("Invalid URL for \(address):\(port)\(path)")
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SunshineError.networkError("HTTP \(http.statusCode)")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw SunshineError.invalidResponse("Non-UTF8 response")
            }
            return text
        } catch let err as SunshineError {
            throw err
        } catch {
            throw SunshineError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Crypto Wrappers (OpenSSL via CMoonlightCommon)

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func toHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - TLS Delegate (Self-Signed Sunshine Cert + Client Identity)

private final class SunshineTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: SecIdentity

    init(identity: SecIdentity) {
        self.identity = identity
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if method == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Minimal XML Parser for Sunshine / GameStream responses

private final class SimpleXMLNode {
    let name: String
    let attributes: [String: String]
    var text: String = ""
    var children: [SimpleXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func firstText(_ tagName: String) -> String? {
        if let child = children.first(where: { $0.name == tagName }) {
            let trimmed = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func children(named tagName: String) -> [SimpleXMLNode] {
        children.filter { $0.name == tagName }
    }
}

private final class SimpleXMLParser: NSObject, XMLParserDelegate {
    private var stack: [SimpleXMLNode] = []
    private var root: SimpleXMLNode?

    static func parse(_ xmlString: String) -> SimpleXMLNode {
        let parserObj = SimpleXMLParser()
        let xmlParser = XMLParser(data: Data(xmlString.utf8))
        xmlParser.delegate = parserObj
        xmlParser.parse()
        return parserObj.root ?? SimpleXMLNode(name: "root", attributes: [:])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = SimpleXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}
