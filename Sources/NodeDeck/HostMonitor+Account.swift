import Foundation
import NodeDeckCore

extension HostMonitor {
    func loadAccountStateFromDisk() {
        accountSession = EmbeddedEasyTierManager.loadSession()
        if accountSession.isLoggedIn {
            Task { await syncAccountState(silent: true) }
        }
    }

    func registerAccount(serverUrl: String, username: String, password: String, inviteCode: String) async throws {
        let deviceId = EmbeddedEasyTierManager.getOrCreateDeviceId()
        let deviceName = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-") ?? "mac"
        let resp = try await controlPlaneClient.register(
            serverUrl: serverUrl,
            username: username,
            password: password,
            inviteCode: inviteCode,
            deviceId: deviceId,
            deviceName: deviceName
        )
        await applyAccountResponse(serverUrl: serverUrl, response: resp, fallbackToken: nil)
    }

    func loginAccount(serverUrl: String, username: String, password: String) async throws {
        let deviceId = EmbeddedEasyTierManager.getOrCreateDeviceId()
        let deviceName = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-") ?? "mac"
        let resp = try await controlPlaneClient.login(
            serverUrl: serverUrl,
            username: username,
            password: password,
            deviceId: deviceId,
            deviceName: deviceName
        )
        await applyAccountResponse(serverUrl: serverUrl, response: resp, fallbackToken: nil)
    }

    func syncAccountState(silent: Bool = false) async {
        guard accountSession.isLoggedIn else { return }
        do {
            let resp = try await controlPlaneClient.heartbeat(
                serverUrl: accountSession.serverUrl,
                token: accountSession.token,
                deviceName: accountSession.deviceName.isEmpty ? "mac" : accountSession.deviceName,
                meshIpv4: accountSession.virtualCidr
            )
            await applyAccountResponse(serverUrl: accountSession.serverUrl, response: resp, fallbackToken: accountSession.token)
            if !silent {
                showFeedback(.success, AppLocalization.shared.t("账号与设备列表已同步", "Account & devices synced"))
            }
        } catch {
            if !silent {
                showFeedback(.error, error.localizedDescription)
            }
        }
    }

    func logoutAccount() async {
        let prev = accountSession
        if prev.isLoggedIn {
            await controlPlaneClient.logout(serverUrl: prev.serverUrl, token: prev.token)
        }
        let cleared = AccountSession(serverUrl: prev.serverUrl.isEmpty ? ControlPlaneClient.defaultServerURL : prev.serverUrl)
        accountSession = cleared
        accountDevices = []
        EmbeddedEasyTierManager.saveSession(cleared)
        showFeedback(.info, AppLocalization.shared.t("已退出账号", "Signed out"))
    }

    func startBuiltInMacMesh() async throws {
        let tomlURL = try EmbeddedEasyTierManager.writeRuntimeToml(for: accountSession)
        try await EmbeddedEasyTierManager.installAndStartSystemMeshDaemon(tomlURL: tomlURL)
        showFeedback(.success, AppLocalization.shared.t("内置 EasyTier 组网已启动 (\(accountSession.virtualIp))", "Built-in EasyTier Mesh started (\(accountSession.virtualIp))"))
        refreshAll()
    }

    private func applyAccountResponse(
        serverUrl: String,
        response: ControlPlaneStateResponse,
        fallbackToken: String?
    ) async {
        let token = response.token ?? fallbackToken ?? ""
        let session = AccountSession(
            serverUrl: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
            username: response.user.username,
            token: token,
            deviceId: response.device.deviceId,
            deviceName: response.device.deviceName,
            virtualIp: response.device.virtualIp,
            virtualCidr: response.device.virtualCidr,
            mesh: response.mesh
        )
        accountSession = session
        accountDevices = response.devices
        EmbeddedEasyTierManager.saveSession(session)
        _ = try? EmbeddedEasyTierManager.writeRuntimeToml(for: session)

        // Publish Mac's public Moonlight client cert to control plane so Linux hosts auto-authorize it
        if !token.isEmpty, let pub = EmbeddedEasyTierManager.readPublicMoonlightIdentity() {
            try? await controlPlaneClient.registerClientCert(
                serverUrl: session.serverUrl,
                token: token,
                deviceName: session.deviceName,
                uniqueId: pub.uniqueId,
                certPem: pub.certPem
            )
        }

        // Publish Mac's local Ed25519 SSH public key & sync same-account SSH public keys into ~/.ssh/authorized_keys
        if !token.isEmpty, let pubKey = EmbeddedEasyTierManager.ensureLocalSshPublicKey() {
            try? await controlPlaneClient.registerSshPublicKey(
                serverUrl: session.serverUrl,
                token: token,
                deviceName: session.deviceName,
                publicKey: pubKey
            )
        }
        if !response.sshPublicKeys.isEmpty {
            _ = EmbeddedEasyTierManager.syncAccountSshPublicKeys(response.sshPublicKeys)
        }

        // Auto-authorize same-account clients' Moonlight public certs into local macOS NodeDeckHost
        if !response.clientCerts.isEmpty {
            _ = SunshineHostManager.shared.syncAccountClientCertificates(response.clientCerts)
        }

        // Auto-sync remote host devices' Sunshine configs so newly discovered hosts are immediately streamable
        for dev in response.devices where dev.deviceId != session.deviceId && (dev.role == "host" || dev.role == "both") && dev.sunshineEnabled && !dev.virtualIp.isEmpty {
            let exists = sunshineHostConfigs.contains {
                $0.hostAlias.caseInsensitiveCompare(dev.deviceName) == .orderedSame || $0.address == dev.virtualIp
            }
            if !exists {
                let cfg = SunshineHostConfig(
                    hostAlias: dev.deviceName,
                    address: dev.virtualIp,
                    httpPort: dev.sunshineHttpPort,
                    httpsPort: dev.sunshineHttpsPort,
                    serverName: dev.deviceName,
                    isPaired: true
                )
                sunshineHostConfigs.append(cfg)
                try? SunshineClient.saveHosts(sunshineHostConfigs)
            }
        }
    }
}
