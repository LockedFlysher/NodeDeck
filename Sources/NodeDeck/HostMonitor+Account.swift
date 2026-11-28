import Foundation
import NodeDeckCore

extension HostMonitor {
    func loadAccountStateFromDisk() {
        accountSession = EmbeddedEasyTierManager.loadSession()
        if accountSession.isLoggedIn {
            Task { await syncAccountState(silent: true) }
            startAccountHeartbeatLoop()
        }
    }

    func startAccountHeartbeatLoop() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard self.accountSession.isLoggedIn else { break }
                await self.syncAccountState(silent: true)
            }
        }
    }

    func activateDeviceViaAccount(for host: SSHHost) async throws -> SunshineHostConfig {
        guard accountSession.isLoggedIn else {
            throw ControlPlaneError.serverError("Not signed in to a NodeDeck account")
        }
        if let pub = EmbeddedEasyTierManager.readPublicMoonlightIdentity() {
            try? await controlPlaneClient.registerClientCert(
                serverUrl: accountSession.serverUrl,
                token: accountSession.token,
                deviceName: accountSession.deviceName,
                uniqueId: pub.uniqueId,
                certPem: pub.certPem
            )
        }
        let act = try await controlPlaneClient.activateDevice(
            serverUrl: accountSession.serverUrl,
            token: accountSession.token,
            targetName: host.alias,
            targetIp: host.hostName,
            action: "activate_host"
        )
        var httpPort = act.targetDevice?.sunshineHttpPort ?? 47989
        var httpsPort = act.targetDevice?.sunshineHttpsPort ?? max(1, httpPort - 5)
        let addr = act.targetDevice?.virtualIp.isEmpty == false ? act.targetDevice!.virtualIp : host.hostName

        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let st = try? await controlPlaneClient.getCommandStatus(
                serverUrl: accountSession.serverUrl,
                token: accountSession.token,
                commandId: act.commandId
            ) {
                if st.status == "done" {
                    if let p = st.sunshineHttpPort { httpPort = p }
                    if let sp = st.sunshineHttpsPort { httpsPort = sp }
                    break
                } else if st.status == "failed" {
                    throw ControlPlaneError.serverError(st.error ?? "Target device failed to activate host")
                }
            }
        }

        let cfg = SunshineHostConfig(
            hostAlias: host.alias,
            address: addr,
            httpPort: httpPort,
            httpsPort: httpsPort,
            serverName: host.alias,
            isPaired: true
        )
        sunshineHostConfigs.removeAll {
            $0.hostAlias.caseInsensitiveCompare(host.alias) == .orderedSame || $0.address == addr
        }
        sunshineHostConfigs.append(cfg)
        try? SunshineClient.saveHosts(sunshineHostConfigs)
        return cfg
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
        var certsChanged = false
        if !response.clientCerts.isEmpty {
            certsChanged = SunshineHostManager.shared.syncAccountClientCertificates(response.clientCerts)
        }

        // Execute remote account activation / cert-sync commands from same-account phone/PC (zero SSH, zero PIN)
        if !response.pendingCommands.isEmpty && !token.isEmpty {
            for cmd in response.pendingCommands where cmd.action == "activate_host" || cmd.action == "sync_certs" {
                if cmd.action == "activate_host" {
                    if SunshineHostManager.shared.currentState() != .running {
                        _ = try? SunshineHostManager.shared.startHost()
                    } else if certsChanged {
                        SunshineHostManager.shared.stopHost()
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        _ = try? SunshineHostManager.shared.startHost()
                    }
                    refreshLocalSunshineHostState()
                }
                await controlPlaneClient.ackCommand(
                    serverUrl: session.serverUrl,
                    token: token,
                    commandId: cmd.id,
                    status: "done",
                    result: [
                        "sunshine_enabled": SunshineHostManager.shared.currentState() == .running,
                        "sunshine_http_port": 47989,
                        "sunshine_https_port": 47984
                    ]
                )
            }
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
