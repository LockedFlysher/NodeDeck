import Foundation
import NodeDeckCore

extension HostMonitor {
    // MARK: - Native Sunshine / Moonlight Management

    func sunshineConfig(for host: SSHHost) -> SunshineHostConfig? {
        let aliasesLower = Set(host.allAliases.map { $0.lowercased() })
        return sunshineHostConfigs.first { cfg in
            aliasesLower.contains(cfg.hostAlias.lowercased()) ||
                cfg.address.caseInsensitiveCompare(host.hostName) == .orderedSame
        }
    }

    func presentPairSunshine(for host: SSHHost) {
        sunshinePairTargetHost = host
        isShowingSunshinePairSheet = true
    }

    func saveSunshineHostConfig(_ config: SunshineHostConfig) {
        var updated = sunshineHostConfigs
        if let idx = updated.firstIndex(where: {
            $0.hostAlias.caseInsensitiveCompare(config.hostAlias) == .orderedSame ||
                $0.address.caseInsensitiveCompare(config.address) == .orderedSame
        }) {
            updated[idx] = config
        } else {
            updated.append(config)
        }
        sunshineHostConfigs = updated
        Task.detached(priority: .utility) {
            try? SunshineClient.saveHosts(updated)
        }
        showFeedback(.success, "Paired native Sunshine desktop for \(config.hostAlias) (\(config.address)).")
    }

    func removeSunshineHostConfig(_ config: SunshineHostConfig) {
        sunshineHostConfigs.removeAll { $0.id == config.id }
        let updated = sunshineHostConfigs
        Task.detached(priority: .utility) {
            try? SunshineClient.saveHosts(updated)
        }
        showFeedback(.info, "Unpaired Sunshine host \(config.hostAlias).")
    }

    func refreshLocalSunshineHostState() {
        Task.detached(priority: .utility) {
            if SunshineHostManager.isAutoStartEnabled && SunshineHostManager.shared.currentState() == .stopped {
                _ = try? SunshineHostManager.shared.startHost()
            }
            let state = SunshineHostManager.shared.currentState()
            let perms = SunshineHostManager.checkPermissions()
            await MainActor.run {
                self.localSunshineHostState = state
                self.localHostPermissions = perms
            }
        }
    }

    func setLocalSunshineHostEnabled(_ enabled: Bool) {
        if enabled {
            do {
                _ = try SunshineHostManager.shared.startHost()
                refreshLocalSunshineHostState()
                Task { await syncAccountState(silent: true) }
                let perms = SunshineHostManager.checkPermissions()
                if !perms.screenRecording {
                    showFeedback(.info, AppLocalization.shared.t("已启动本机被控，请完成「录屏与系统录音」权限授权后重启生效。", "Local host started. Grant Screen Recording permission to NodeDeck."))
                } else {
                    showFeedback(.success, AppLocalization.shared.t("已开启本机被控（其他设备可直接远控这台 Mac）。", "Local Mac Host enabled."))
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showFeedback(.error, msg)
            }
        } else {
            SunshineHostManager.isAutoStartEnabled = false
            SunshineHostManager.shared.stopHost()
            refreshLocalSunshineHostState()
            Task { await syncAccountState(silent: true) }
            showFeedback(.info, AppLocalization.shared.t("已关闭本机被控服务。", "Local Mac Host disabled."))
        }
    }

    func restartLocalSunshineHost() {
        SunshineHostManager.shared.stopHost()
        Task.detached(priority: .userInitiated) {
            usleep(450_000)
            _ = try? SunshineHostManager.shared.startHost()
            usleep(1_200_000)
            let state = SunshineHostManager.shared.currentState()
            let perms = SunshineHostManager.checkPermissions()
            await MainActor.run {
                self.localSunshineHostState = state
                self.localHostPermissions = perms
                Task { await self.syncAccountState(silent: true) }
            }
        }
    }

    func toggleLocalSunshineHost() {
        setLocalSunshineHostEnabled(localSunshineHostState != .running)
    }

    // MARK: - Linux Multi-User Host Isolation Profiles

    func hostProfile(for host: SSHHost) -> LinuxHostProfile {
        if let existing = hostProfiles.first(where: { profile in
            host.allAliases.contains { $0.caseInsensitiveCompare(profile.hostAlias) == .orderedSame }
        }) {
            return existing
        }
        let pairedPort = sunshineConfig(for: host)?.httpPort ?? 47989
        return LinuxHostProfile(
            hostAlias: host.alias,
            mode: .physicalDesktop,
            display: ":99",
            basePort: pairedPort,
            encoder: "nvenc",
            cudaDeviceIndex: "0",
            drmRenderNode: "/dev/dri/renderD128",
            virtualAudioSink: false,
            clipboardSync: true,
            autoReconcileOnStart: true
        )
    }

    func presentHostProfile(for host: SSHHost) {
        editingHostProfileTarget = host
        isShowingHostProfileSheet = true
    }

    func saveAndReconcileHostProfile(
        _ profile: LinuxHostProfile,
        for host: SSHHost,
        force: Bool = true
    ) async -> String? {
        var updated = hostProfiles
        if let idx = updated.firstIndex(where: { $0.hostAlias.caseInsensitiveCompare(profile.hostAlias) == .orderedSame }) {
            updated[idx] = profile
        } else {
            updated.append(profile)
        }
        hostProfiles = updated
        Task.detached(priority: .utility) {
            try? LinuxHostProfileManager.saveProfiles(updated)
        }

        // Also update paired Sunshine port locally if it changed
        if var sCfg = sunshineConfig(for: host), sCfg.httpPort != profile.basePort {
            sCfg.httpPort = profile.basePort
            sCfg.httpsPort = profile.basePort - 5
            saveSunshineHostConfig(sCfg)
        }

        do {
            let outcome = try await LinuxHostProfileManager.reconcile(profile: profile, host: host, force: force)
            reconciledHostDigests[host.alias.lowercased()] = profile.configDigest
            switch outcome {
            case .upToDate:
                showFeedback(.info, "\(host.alias) 远端配置已是最新，无需重启。")
            case .updated(let restarted):
                showFeedback(
                    .success,
                    restarted
                        ? "已同步 \(host.alias) 的多用户隔离配置并重载 nodedeck-host。"
                        : "已写入 \(host.alias) 的 host.conf 配置。"
                )
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reconcileHostProfileIfNeeded(for host: SSHHost) async {
        guard let profile = hostProfiles.first(where: {
            $0.hostAlias.caseInsensitiveCompare(host.alias) == .orderedSame && $0.autoReconcileOnStart
        }) else {
            return
        }
        let key = host.alias.lowercased()
        if reconciledHostDigests[key] == profile.configDigest {
            return
        }
        reconciledHostDigests[key] = profile.configDigest
        if let outcome = try? await LinuxHostProfileManager.reconcile(profile: profile, host: host, force: false),
           case .updated(let restarted) = outcome {
            showFeedback(
                .info,
                restarted
                    ? "检测到配置变更，已自动更新并重启 \(host.alias) 的 nodedeck-host。"
                    : "检测到配置变更，已自动更新 \(host.alias) 的 host.conf。"
            )
        }
    }

    func launchNativeMoonlightStream(
        hostAlias: String? = nil,
        address: String,
        httpPort: Int = 47989,
        appTitle: String = "Desktop",
        width: Int? = nil,
        height: Int? = nil,
        fps: Int? = nil,
        enablePrivacyScreen: Bool = false
    ) {
        let resolvedWidth = width ?? streamResolution.width
        let resolvedHeight = height ?? streamResolution.height
        let resolvedFPS = fps ?? streamRefreshRate.fps

        if let preset = StreamResolutionPreset(width: resolvedWidth, height: resolvedHeight),
           preset != streamResolution {
            streamResolution = preset
        }
        if let rate = StreamRefreshRate(rawValue: resolvedFPS),
           rate != streamRefreshRate {
            streamRefreshRate = rate
        }

        MoonlightStreamWindowController.shared.openStream(
            hostAlias: hostAlias,
            address: address,
            httpPort: httpPort,
            appTitle: appTitle,
            width: resolvedWidth,
            height: resolvedHeight,
            fps: resolvedFPS,
            enablePrivacyScreen: enablePrivacyScreen,
            onStreamConfigChanged: { [weak self] newWidth, newHeight, newFPS in
                guard let self else { return }
                if let preset = StreamResolutionPreset(width: newWidth, height: newHeight),
                   preset != self.streamResolution {
                    self.streamResolution = preset
                }
                if let rate = StreamRefreshRate(rawValue: newFPS),
                   rate != self.streamRefreshRate {
                    self.streamRefreshRate = rate
                }
            }
        )
    }
}
