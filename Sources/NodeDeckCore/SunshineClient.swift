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
    case notPaired
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
        case .notPaired:
            return "This host is not paired with NodeDeck yet. Pair it with a PIN first."
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
    private var cachedKeyPEM: String?
    private var cachedUniqueId: String?
    private var cachedIdentity: SecIdentity?
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

    public static func generateRandomPIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    // MARK: - Client Identity (Cert + Key + PKCS12 + UniqueID)

    private func ensureIdentity() throws -> (certPEM: String, keyPEM: String, uniqueId: String, session: URLSession) {
        lock.lock()
        if let cert = cachedCertPEM, let key = cachedKeyPEM, let uid = cachedUniqueId, let sess = cachedSession {
            lock.unlock()
            return (cert, key, uid, sess)
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
              let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8),
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
        cachedKeyPEM = keyPEM
        cachedUniqueId = uniqueId
        cachedIdentity = identity
        cachedSession = session
        lock.unlock()

        return (certPEM, keyPEM, uniqueId, session)
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
        let (_, _, uniqueId, session) = try ensureIdentity()
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
        let (_, _, uniqueId, session) = try ensureIdentity()
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

    public func pair(address: String, httpPort: Int = 47989, pin: String) async throws -> SunshineHostConfig {
        let (certPEM, keyPEM, uniqueId, session) = try ensureIdentity()
        let info = try await fetchServerInfo(address: address, httpPort: httpPort)

        let salt = Self.randomBytes(count: 16)
        let saltHex = Self.toHex(salt)
        let clientCertHex = Self.toHex(Data(certPEM.utf8))

        // Step 1: getservercert
        let step1XML = try await requestXML(
            session: session,
            scheme: "http",
            address: address,
            port: httpPort,
            path: "/pair",
            query: [
                "uniqueid": uniqueId,
                "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "devicename": "roth",
                "updateState": "1",
                "phrase": "getservercert",
                "salt": saltHex,
                "clientcert": clientCertHex
            ],
            timeout: 45
        )
        let step1 = SimpleXMLParser.parse(step1XML)
        guard step1.firstText("paired") == "1",
              let plainCertHex = step1.firstText("plaincert"),
              let serverCertData = Self.fromHex(plainCertHex),
              let serverCertPEM = String(data: serverCertData, encoding: .utf8)
        else {
            throw SunshineError.pairingFailed("Host rejected PIN or pairing timed out (step 1).")
        }

        // Derive AES-128 key = SHA256(salt + pin)[0..<16]
        var saltedPin = Data(salt)
        saltedPin.append(Data(pin.utf8))
        let aesKey = Self.sha256(saltedPin).prefix(16)

        // Step 2: clientchallenge
        let clientChallenge = Self.randomBytes(count: 16)
        let encClientChallenge = try Self.aes128ECBEncrypt(key: Data(aesKey), data: clientChallenge)
        let step2XML = try await requestXML(
            session: session,
            scheme: "http",
            address: address,
            port: httpPort,
            path: "/pair",
            query: [
                "uniqueid": uniqueId,
                "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "devicename": "roth",
                "updateState": "1",
                "clientchallenge": Self.toHex(encClientChallenge)
            ]
        )
        let step2 = SimpleXMLParser.parse(step2XML)
        guard step2.firstText("paired") == "1",
              let challengeRespHex = step2.firstText("challengeresponse"),
              let challengeRespEnc = Self.fromHex(challengeRespHex)
        else {
            throw SunshineError.pairingFailed("Server rejected challenge (step 2).")
        }

        let challengeRespDec = try Self.aes128ECBDecrypt(key: Data(aesKey), data: challengeRespEnc)
        guard challengeRespDec.count >= 48 else {
            throw SunshineError.pairingFailed("Unexpected challenge response length.")
        }
        let serverResponseHash = challengeRespDec.subdata(in: 0..<32)
        let serverChallenge = challengeRespDec.subdata(in: 32..<48)

        // Step 3: serverchallengeresp
        let clientCertSig = try Self.extractCertSignature(certPEM: certPEM)
        let clientSecret = Self.randomBytes(count: 16)
        var respInput = Data()
        respInput.append(serverChallenge)
        respInput.append(clientCertSig)
        respInput.append(clientSecret)
        let clientRespHash = Self.sha256(respInput)
        let encClientRespHash = try Self.aes128ECBEncrypt(key: Data(aesKey), data: clientRespHash)

        let step3XML = try await requestXML(
            session: session,
            scheme: "http",
            address: address,
            port: httpPort,
            path: "/pair",
            query: [
                "uniqueid": uniqueId,
                "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "devicename": "roth",
                "updateState": "1",
                "serverchallengeresp": Self.toHex(encClientRespHash)
            ]
        )
        let step3 = SimpleXMLParser.parse(step3XML)
        guard step3.firstText("paired") == "1",
              let pairingSecretHex = step3.firstText("pairingsecret"),
              let pairingSecret = Self.fromHex(pairingSecretHex),
              pairingSecret.count > 16
        else {
            throw SunshineError.pairingFailed("Server rejected PIN challenge response (step 3 — check PIN).")
        }

        let serverSecret = pairingSecret.subdata(in: 0..<16)
        let serverSignature = pairingSecret.subdata(in: 16..<pairingSecret.count)

        guard Self.verifySHA256(certPEM: serverCertPEM, data: serverSecret, signature: serverSignature) else {
            throw SunshineError.pairingFailed("Server signature verification failed.")
        }

        let serverCertSig = try Self.extractCertSignature(certPEM: serverCertPEM)
        var expectedServerHashInput = Data()
        expectedServerHashInput.append(clientChallenge)
        expectedServerHashInput.append(serverCertSig)
        expectedServerHashInput.append(serverSecret)
        guard Self.sha256(expectedServerHashInput) == serverResponseHash else {
            throw SunshineError.pairingFailed("PIN mismatch during pairing verification.")
        }

        // Step 4: clientpairingsecret
        let clientSignature = try Self.signSHA256(keyPEM: keyPEM, data: clientSecret)
        var clientPairingSecret = Data()
        clientPairingSecret.append(clientSecret)
        clientPairingSecret.append(clientSignature)

        let step4XML = try await requestXML(
            session: session,
            scheme: "http",
            address: address,
            port: httpPort,
            path: "/pair",
            query: [
                "uniqueid": uniqueId,
                "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "devicename": "roth",
                "updateState": "1",
                "clientpairingsecret": Self.toHex(clientPairingSecret)
            ]
        )
        let step4 = SimpleXMLParser.parse(step4XML)
        guard step4.firstText("paired") == "1" else {
            throw SunshineError.pairingFailed("Server rejected client pairing secret (step 4).")
        }

        // Step 5: HTTPS pairchallenge
        let step5XML = try await requestXML(
            session: session,
            scheme: "https",
            address: address,
            port: info.httpsPort,
            path: "/pair",
            query: [
                "uniqueid": uniqueId,
                "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "devicename": "roth",
                "updateState": "1",
                "phrase": "pairchallenge"
            ]
        )
        let step5 = SimpleXMLParser.parse(step5XML)
        guard step5.firstText("paired") == "1" else {
            throw SunshineError.pairingFailed("HTTPS pairchallenge failed (step 5).")
        }

        return SunshineHostConfig(
            hostAlias: info.hostname,
            address: address,
            httpPort: httpPort,
            httpsPort: info.httpsPort,
            serverName: info.hostname,
            serverCertPEM: serverCertPEM,
            isPaired: true
        )
    }

    public func launchStream(
        address: String,
        httpPort: Int = 47989,
        preferredAppTitle: String = "Desktop",
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60
    ) async throws -> SunshineLaunchSession {
        let (_, _, uniqueId, session) = try ensureIdentity()
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

    public func submitPIN(
        address: String,
        webPort: Int,
        username: String,
        password: String,
        pin: String,
        clientName: String = "NodeDeck"
    ) async throws {
        let (_, _, _, session) = try ensureIdentity()
        guard let url = URL(string: "https://\(address):\(webPort)/api/pin") else {
            throw SunshineError.networkError("Invalid Sunshine Web UI URL.")
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        let creds = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = ["pin": pin, "name": clientName]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw SunshineError.pairingFailed("Sunshine Web UI 账号或密码错误 (HTTP 401)。")
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw SunshineError.pairingFailed("Sunshine /api/pin 返回 HTTP \(http.statusCode): \(body)")
            }
        }
    }

    public func pairWithCredentials(
        address: String,
        httpPort: Int = 47989,
        username: String,
        password: String
    ) async throws -> SunshineHostConfig {
        let pin = Self.generateRandomPIN()
        let webPort = httpPort + 1

        async let pairTask = pair(address: address, httpPort: httpPort, pin: pin)
        // Give step 1 (/pair?phrase=getservercert) a brief moment to register pending PIN on Sunshine
        try? await Task.sleep(nanoseconds: 450_000_000)
        try await submitPIN(
            address: address,
            webPort: webPort,
            username: username,
            password: password,
            pin: pin
        )
        return try await pairTask
    }

    public func pairViaSudoerSSH(
        hostAlias: String,
        address: String,
        httpPort: Int = 47989,
        username: String,
        password: String
    ) async throws -> SunshineHostConfig {
        let (certPEM, _, uniqueId, _) = try ensureIdentity()
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

        nd_host_dir = os.path.expanduser("~/.config/nodedeck/host")
        legacy_dir = os.path.expanduser("~/.config/sunshine")
        if os.path.exists(os.path.join(nd_host_dir, "host.conf")) or os.path.exists("/opt/nodedeck/host/bin/nodedeck-host"):
            conf_dir = nd_host_dir
            conf_path = os.path.join(conf_dir, "host.conf")
        else:
            conf_dir = legacy_dir
            conf_path = os.path.join(conf_dir, "sunshine.conf")
        os.makedirs(conf_dir, exist_ok=True)
        state_path = os.path.join(conf_dir, "sunshine_state.json")

        detected_port = \(httpPort)
        if os.path.exists(conf_path):
            txt = open(conf_path, "r", encoding="utf-8", errors="ignore").read()
            m = re.search(r"^\\s*port\\s*=\\s*(\\d+)", txt, re.M)
            if m:
                detected_port = int(m.group(1))

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
        guard let (_, _, uniqueId, session) = try? ensureIdentity() else { return }
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

    private static func fromHex(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var out = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    private static func sha256(_ data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            let base = ptr.bindMemory(to: UInt8.self).baseAddress
            _ = nd_sha256(base, data.count, &out)
        }
        return Data(out)
    }

    private static func aes128ECBEncrypt(key: Data, data: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: data.count)
        let rc = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { inPtr in
                nd_aes128_ecb_encrypt(
                    keyPtr.bindMemory(to: UInt8.self).baseAddress,
                    inPtr.bindMemory(to: UInt8.self).baseAddress,
                    data.count,
                    &out
                )
            }
        }
        guard rc == 0 else { throw SunshineError.pairingFailed("AES encrypt failed") }
        return Data(out)
    }

    private static func aes128ECBDecrypt(key: Data, data: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: data.count)
        let rc = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { inPtr in
                nd_aes128_ecb_decrypt(
                    keyPtr.bindMemory(to: UInt8.self).baseAddress,
                    inPtr.bindMemory(to: UInt8.self).baseAddress,
                    data.count,
                    &out
                )
            }
        }
        guard rc == 0 else { throw SunshineError.pairingFailed("AES decrypt failed") }
        return Data(out)
    }

    private static func extractCertSignature(certPEM: String) throws -> Data {
        var out = [UInt8](repeating: 0, count: 1024)
        var outLen = out.count
        let rc = certPEM.withCString { cstr in
            nd_extract_cert_signature_pem(cstr, &out, &outLen)
        }
        guard rc == 0 else { throw SunshineError.pairingFailed("Failed to extract cert signature") }
        return Data(out.prefix(outLen))
    }

    private static func signSHA256(keyPEM: String, data: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: 1024)
        var outLen = out.count
        let rc = keyPEM.withCString { cstr in
            data.withUnsafeBytes { ptr in
                nd_sign_sha256_pem(cstr, ptr.bindMemory(to: UInt8.self).baseAddress, data.count, &out, &outLen)
            }
        }
        guard rc == 0 else { throw SunshineError.pairingFailed("RSA sign failed") }
        return Data(out.prefix(outLen))
    }

    private static func verifySHA256(certPEM: String, data: Data, signature: Data) -> Bool {
        let rc = certPEM.withCString { cstr in
            data.withUnsafeBytes { dPtr in
                signature.withUnsafeBytes { sPtr in
                    nd_verify_sha256_pem(
                        cstr,
                        dPtr.bindMemory(to: UInt8.self).baseAddress,
                        data.count,
                        sPtr.bindMemory(to: UInt8.self).baseAddress,
                        signature.count
                    )
                }
            }
        }
        return rc == 1
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
