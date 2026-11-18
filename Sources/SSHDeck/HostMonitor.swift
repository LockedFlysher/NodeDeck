import AppKit
import Combine
import Foundation
import SSHDeckCore

struct ActionFeedback: Identifiable, Equatable {
    enum Kind {
        case info
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case online = "Online"
    case mounted = "Mounted"
    case gpu = "GPU"

    var id: String { rawValue }
}

@MainActor
final class HostMonitor: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var snapshots: [String: HostSnapshot] = [:]
    @Published var selectedAlias: String?
    @Published var sidebarFilter: SidebarFilter = .all
    @Published private(set) var pinnedAliases: Set<String>
    @Published private(set) var isScanning = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var scanError: String?
    @Published private(set) var lastRefresh: Date?

    // Directory mount state
    @Published private(set) var mountConfigs: [FolderMountConfig] = []
    @Published private(set) var systemMounts: [SystemMountEntry] = []
    @Published private(set) var mountBusyStates: [String: MountRuntimeState] = [:]
    @Published private(set) var mountErrors: [String: String] = [:]
    @Published private(set) var isRcloneAvailable: Bool = false
    @Published var isShowingAddMountSheet = false
    @Published var editingMountConfig: FolderMountConfig?

    // GOST tunnel & Launch at Login state
    @Published private(set) var tunnelConfigs: [GostTunnelConfig] = []
    @Published private(set) var allTunnelItems: [TunnelRuntimeItem] = []
    @Published private(set) var isGostAvailable: Bool = false
    @Published var isShowingTunnelSheet = false
    @Published var editingTunnelConfig: GostTunnelConfig?
    @Published private(set) var launchAtLogin: Bool = false

    // VS Code Remote-SSH workspaces state
    @Published private(set) var vscodeRawEntries: [VSCodeRawEntry] = []
    @Published private(set) var isVSCodeInstalled: Bool = false
    @Published var isShowingOpenVSCodePathSheet = false
    @Published var openVSCodePathTargetHost: SSHHost?

    @Published var feedback: ActionFeedback?

    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: Self.refreshIntervalKey)
            configureAutoRefresh()
        }
    }

    private static let refreshIntervalKey = "sshdeck.refreshInterval"
    private static let pinnedAliasesKey = "sshdeck.pinnedAliases"
    private let configURL: URL
    private let mountsURL: URL
    private let tunnelsURL: URL
    private var hasStarted = false
    private var isShuttingDown = false
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var feedbackDismissTask: Task<Void, Never>?
    private var refreshingAliases = Set<String>()

    init(
        configURL: URL = SSHConfigParser.defaultConfigURL,
        mountsURL: URL = MountManager.defaultConfigFileURL,
        tunnelsURL: URL = TunnelManager.defaultConfigFileURL
    ) {
        self.configURL = configURL
        self.mountsURL = mountsURL
        self.tunnelsURL = tunnelsURL
        let storedInterval = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
        self.refreshInterval = storedInterval > 0 ? storedInterval : 30
        let storedPins = UserDefaults.standard.stringArray(forKey: Self.pinnedAliasesKey) ?? []
        self.pinnedAliases = Set(storedPins)
        self.launchAtLogin = LaunchAtLoginManager.isEnabled()
    }

    var selectedSnapshot: HostSnapshot? {
        guard let selectedAlias else { return nil }
        return snapshots[selectedAlias]
    }

    var onlineCount: Int {
        snapshots.values.filter { $0.state == .online }.count
    }

    var mountedHostCount: Int {
        hosts.filter { mountedItemsCount(for: $0) > 0 }.count
    }

    var gpuHostCount: Int {
        snapshots.values.filter { !($0.metrics?.gpus.isEmpty ?? true) }.count
    }

    var activeTunnelCount: Int {
        allTunnelItems.filter(\.isRunning).count
    }

    var menuBarSymbol: String {
        activeTunnelCount > 0 ? "terminal.fill" : "terminal"
    }

    func isPinned(_ alias: String) -> Bool {
        pinnedAliases.contains(alias)
    }

    func togglePin(_ alias: String) {
        if pinnedAliases.contains(alias) {
            pinnedAliases.remove(alias)
        } else {
            pinnedAliases.insert(alias)
        }
        UserDefaults.standard.set(Array(pinnedAliases).sorted(), forKey: Self.pinnedAliasesKey)
    }

    func sortedHosts(matching searchText: String) -> [SSHHost] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = hosts.filter { host in
            let passesSearch: Bool
            if query.isEmpty {
                passesSearch = true
            } else {
                passesSearch = host.allAliases.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                    host.hostName.localizedCaseInsensitiveContains(query) ||
                    host.user.localizedCaseInsensitiveContains(query) ||
                    mountItems(for: host).contains(where: {
                        $0.label.localizedCaseInsensitiveContains(query) ||
                            $0.localPath.localizedCaseInsensitiveContains(query)
                    }) ||
                    tunnelItems(for: host).contains(where: {
                        $0.config.label.localizedCaseInsensitiveContains(query) ||
                            $0.config.portSummary.localizedCaseInsensitiveContains(query)
                    }) ||
                    vscodeItems(for: host).contains(where: {
                        $0.name.localizedCaseInsensitiveContains(query) ||
                            $0.remotePath.localizedCaseInsensitiveContains(query)
                    })
            }
            guard passesSearch else { return false }

            switch sidebarFilter {
            case .all:
                return true
            case .online:
                return snapshots[host.alias]?.state == .online
            case .mounted:
                return mountedItemsCount(for: host) > 0
            case .gpu:
                return !(snapshots[host.alias]?.metrics?.gpus.isEmpty ?? true)
            }
        }

        return searched.sorted { lhs, rhs in
            let lPin = pinnedAliases.contains(lhs.alias)
            let rPin = pinnedAliases.contains(rhs.alias)
            if lPin != rPin { return lPin && !rPin }
            return false
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isShuttingDown = false
        launchAtLogin = LaunchAtLoginManager.isEnabled()

        let loadedTunnels = TunnelManager.loadConfigs(from: tunnelsURL)
        tunnelConfigs = loadedTunnels
        isGostAvailable = TunnelManager.findGostExecutable() != nil
        syncTunnelSnapshots()

        Task {
            // Bring up auto-start GOST tunnels BEFORE probing SSH hosts & auto-mounting!
            await ensureAutoStartTunnels()
            reloadMounts()
            reloadVSCodeWorkspaces()
            reloadConfiguration()
            configureAutoRefresh()
        }
    }

    func stop() {
        isShuttingDown = true
        scanTask?.cancel()
        refreshTask?.cancel()
        autoRefreshTask?.cancel()
        feedbackDismissTask?.cancel()
        scanTask = nil
        refreshTask = nil
        autoRefreshTask = nil
        feedbackDismissTask = nil
        TunnelManager.shared.stopAll()
        syncTunnelSnapshots()
        hasStarted = false
    }

    func shutdownAndQuit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginManager.isEnabled()
            showFeedback(
                .success,
                enabled ? "Enabled Launch at Login (starts in Menu Bar)." : "Disabled Launch at Login."
            )
        } catch {
            launchAtLogin = LaunchAtLoginManager.isEnabled()
            showFeedback(.error, "Launch at Login failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GOST Tunnel Management

    func syncTunnelSnapshots() {
        let cfgs = tunnelConfigs
        let items = TunnelManager.shared.snapshotItems(for: cfgs)
        allTunnelItems = items
        isGostAvailable = TunnelManager.findGostExecutable() != nil
    }

    func tunnelItems(for host: SSHHost) -> [TunnelRuntimeItem] {
        allTunnelItems.filter { TunnelManager.shared.matchesHost($0.config, host: host) }
    }

    func activeTunnelCount(for host: SSHHost) -> Int {
        tunnelItems(for: host).filter(\.isRunning).count
    }

    func hasMoonlightTunnel(for host: SSHHost) -> Bool {
        moonlightTarget(for: host) != nil
    }

    var allMoonlightTargets: [MoonlightTarget] {
        let pairedHosts = MoonlightLauncher.discoverPairedHosts()
        var targets: [MoonlightTarget] = []

        for item in allTunnelItems where item.config.role == .moonlight {
            targets.append(makeMoonlightTarget(from: item.config, pairedHosts: pairedHosts))
        }

        // Also surface any paired direct-LAN Sunshine hosts discovered in Moonlight preferences
        for paired in pairedHosts where paired.isPaired {
            guard let directIP = paired.effectiveDirectAddress else { continue }
            let httpPort = paired.localPort > 0 ? paired.localPort : 47989
            let webPort = httpPort + 1
            let alreadyCovered = targets.contains { $0.streamEndpoint.caseInsensitiveCompare(paired.hostname) == .orderedSame }
            if !alreadyCovered {
                targets.append(
                    MoonlightTarget(
                        hostAlias: paired.hostname.lowercased(),
                        title: "\(paired.hostname) Desktop",
                        subtitle: "\(directIP):\(httpPort) · Direct LAN Stream",
                        streamEndpoint: paired.hostname,
                        webURLString: "https://\(directIP):\(webPort)",
                        tunnelConfig: nil
                    )
                )
            }
        }

        return targets
    }

    func moonlightTarget(for host: SSHHost) -> MoonlightTarget? {
        let pairedHosts = MoonlightLauncher.discoverPairedHosts()
        if let moonlightCfg = tunnelItems(for: host).first(where: { $0.config.role == .moonlight })?.config {
            return makeMoonlightTarget(from: moonlightCfg, pairedHosts: pairedHosts)
        }

        let aliasesLower = host.allAliases.map { $0.lowercased() }

        // Match sibling SSH host entries sharing the same distinctive machine token with a configured Moonlight tunnel
        for item in allTunnelItems where item.config.role == .moonlight {
            let tunnelAlias = item.config.hostAlias.lowercased()
            if aliasesLower.contains(where: { $0.contains(tunnelAlias) || tunnelAlias.contains($0) }) {
                return makeMoonlightTarget(from: item.config, pairedHosts: pairedHosts)
            }
        }

        // Match direct-LAN paired Moonlight hosts by IP or hostname token
        for paired in pairedHosts where paired.isPaired {
            guard let directIP = paired.effectiveDirectAddress else { continue }
            let pairedLower = paired.hostname.lowercased()
            if host.hostName.lowercased() == directIP.lowercased() ||
                aliasesLower.contains(where: { $0.contains(pairedLower) || pairedLower.contains($0) }) {
                let httpPort = paired.localPort > 0 ? paired.localPort : 47989
                return MoonlightTarget(
                    hostAlias: host.alias,
                    title: "\(paired.hostname) Sunshine Desktop",
                    subtitle: "Direct LAN \(directIP):\(httpPort) — low-latency native stream.",
                    streamEndpoint: paired.hostname,
                    webURLString: "https://\(directIP):\(httpPort + 1)",
                    tunnelConfig: nil
                )
            }
        }

        return nil
    }

    private func makeMoonlightTarget(
        from config: GostTunnelConfig,
        pairedHosts: [PairedMoonlightHost] = MoonlightLauncher.discoverPairedHosts()
    ) -> MoonlightTarget {
        let httpPort = config.moonlightHTTPPort ?? 47989
        let webPort = config.sunshineWebPort ?? (httpPort + 1)

        // Resolve the paired Moonlight computer name bound to 127.0.0.1:<httpPort> if available
        let matchedPaired = pairedHosts.first { paired in
            let isLoopback = paired.manualAddress == "127.0.0.1" || paired.localAddress == "127.0.0.1"
            let portMatches = paired.effectiveHTTPPort == httpPort
            return isLoopback && portMatches
        }

        let streamEndpoint = matchedPaired?.hostname ?? (config.moonlightStreamEndpoint ?? "127.0.0.1")
        let displayTitle = matchedPaired.map { "\($0.hostname) Desktop" } ?? config.label

        return MoonlightTarget(
            hostAlias: config.hostAlias,
            title: displayTitle,
            subtitle: config.portSummary,
            streamEndpoint: streamEndpoint,
            webURLString: "https://127.0.0.1:\(webPort)",
            tunnelConfig: config
        )
    }

    private func attachExitHandler(for config: GostTunnelConfig) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleTunnelUnexpectedExit(config)
            }
        }
    }

    func ensureAutoStartTunnels() async {
        guard isGostAvailable else { return }
        let autoConfigs = tunnelConfigs.filter(\.autoStart)
        guard !autoConfigs.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for cfg in autoConfigs {
                let onExit = attachExitHandler(for: cfg)
                group.addTask {
                    try? await TunnelManager.shared.start(config: cfg, onTermination: onExit)
                }
            }
        }
        syncTunnelSnapshots()
    }

    private func handleTunnelUnexpectedExit(_ config: GostTunnelConfig) {
        syncTunnelSnapshots()
        guard !isShuttingDown else { return }
        guard let latest = tunnelConfigs.first(where: { $0.id == config.id }), latest.autoStart else {
            return
        }
        let onExit = attachExitHandler(for: latest)
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !isShuttingDown else { return }
            let snap = TunnelManager.shared.snapshotItems(for: [latest]).first
            if snap?.isRunning != true && snap?.state != .starting {
                try? await TunnelManager.shared.start(config: latest, onTermination: onExit)
                syncTunnelSnapshots()
            }
        }
    }

    func startTunnel(_ config: GostTunnelConfig) {
        let onExit = attachExitHandler(for: config)
        Task {
            syncTunnelSnapshots()
            do {
                try await TunnelManager.shared.start(config: config, onTermination: onExit)
                syncTunnelSnapshots()
                showFeedback(.success, "Started tunnel \"\(config.label)\".")
                if let host = hosts.first(where: { TunnelManager.shared.matchesHost(config, host: $0) }) {
                    refresh(alias: host.alias)
                }
            } catch {
                syncTunnelSnapshots()
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showFeedback(.error, msg)
            }
        }
    }

    func stopTunnel(_ config: GostTunnelConfig) {
        Task.detached(priority: .userInitiated) {
            TunnelManager.shared.stop(id: config.id)
            await MainActor.run {
                self.syncTunnelSnapshots()
                self.showFeedback(.info, "Stopped tunnel \"\(config.label)\".")
            }
        }
    }

    func restartTunnel(_ config: GostTunnelConfig) {
        Task {
            await Task.detached(priority: .userInitiated) {
                TunnelManager.shared.stop(id: config.id)
            }.value
            syncTunnelSnapshots()
            startTunnel(config)
        }
    }

    func startAllTunnels() {
        Task {
            for cfg in tunnelConfigs {
                let onExit = attachExitHandler(for: cfg)
                try? await TunnelManager.shared.start(config: cfg, onTermination: onExit)
            }
            syncTunnelSnapshots()
            showFeedback(.success, "All configured GOST tunnels started.")
            refreshAll()
        }
    }

    func restartAllActiveTunnels() {
        Task {
            let active = allTunnelItems.filter(\.isRunning).map(\.config)
            for cfg in active {
                let onExit = attachExitHandler(for: cfg)
                TunnelManager.shared.stop(id: cfg.id)
                try? await TunnelManager.shared.start(config: cfg, onTermination: onExit)
            }
            syncTunnelSnapshots()
            showFeedback(.success, "Restarted \(active.count) GOST tunnel(s).")
        }
    }

    func presentAddTunnel(for host: SSHHost) {
        editingTunnelConfig = GostTunnelConfig(
            hostAlias: host.alias,
            label: "\(host.alias) Tunnel",
            role: .ssh,
            listenSpecs: ["tcp://127.0.0.1:2299/127.0.0.1:22"],
            forwardChain: "relay+quic://user:token@203.0.113.10:18443?\(TunnelManager.defaultQuicQuery)",
            autoStart: true
        )
        isShowingTunnelSheet = true
    }

    func presentEditTunnel(_ config: GostTunnelConfig) {
        editingTunnelConfig = config
        isShowingTunnelSheet = true
    }

    func saveTunnelConfig(_ config: GostTunnelConfig, startImmediately: Bool) {
        var updated = tunnelConfigs
        if let idx = updated.firstIndex(where: { $0.id == config.id }) {
            updated[idx] = config
        } else {
            updated.append(config)
        }
        tunnelConfigs = updated
        persistTunnelConfigs(updated)
        isShowingTunnelSheet = false
        editingTunnelConfig = nil
        syncTunnelSnapshots()

        if startImmediately {
            restartTunnel(config)
        } else {
            showFeedback(.success, "Saved tunnel \"\(config.label)\".")
        }
    }

    func toggleTunnelAutoStart(_ config: GostTunnelConfig) {
        guard let idx = tunnelConfigs.firstIndex(where: { $0.id == config.id }) else { return }
        tunnelConfigs[idx].autoStart.toggle()
        persistTunnelConfigs(tunnelConfigs)
        syncTunnelSnapshots()
    }

    func removeTunnelConfig(_ config: GostTunnelConfig) {
        TunnelManager.shared.stop(id: config.id)
        tunnelConfigs.removeAll { $0.id == config.id }
        persistTunnelConfigs(tunnelConfigs)
        syncTunnelSnapshots()
        showFeedback(.info, "Removed tunnel \"\(config.label)\".")
    }

    private func persistTunnelConfigs(_ configs: [GostTunnelConfig]) {
        let url = tunnelsURL
        Task.detached(priority: .utility) {
            try? TunnelManager.saveConfigs(configs, to: url)
        }
    }

    func launchMoonlightDesktop(for host: SSHHost) {
        if let target = moonlightTarget(for: host) {
            launchMoonlight(target: target)
        } else if let err = MoonlightLauncher.openMoonlightApp() {
            showFeedback(.error, err)
        }
    }

    func launchMoonlightDesktop(using config: GostTunnelConfig) {
        launchMoonlight(target: makeMoonlightTarget(from: config))
    }

    func launchMoonlight(target: MoonlightTarget) {
        Task {
            if let config = target.tunnelConfig {
                let onExit = attachExitHandler(for: config)
                let item = TunnelManager.shared.snapshotItems(for: [config]).first
                if item?.isRunning != true {
                    do {
                        try await TunnelManager.shared.start(config: config, onTermination: onExit)
                        syncTunnelSnapshots()
                    } catch {
                        syncTunnelSnapshots()
                        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        showFeedback(.error, msg)
                        return
                    }
                }
            }
            if let err = MoonlightLauncher.streamDesktop(host: target.streamEndpoint, appName: "Desktop") {
                showFeedback(.error, err)
            } else {
                showFeedback(.success, "Launching Moonlight Desktop (\(target.title))…")
            }
        }
    }

    // MARK: - VS Code Remote-SSH Workspaces

    func reloadVSCodeWorkspaces() {
        Task {
            await refreshVSCodeWorkspaces()
        }
    }

    func refreshVSCodeWorkspaces() async {
        let loaded = await Task.detached(priority: .utility) {
            (
                entries: VSCodeManager.discoverRawEntries(),
                installed: VSCodeManager.isInstalled
            )
        }.value
        vscodeRawEntries = loaded.entries
        isVSCodeInstalled = loaded.installed
    }

    func vscodeItems(for host: SSHHost) -> [VSCodeWorkspaceItem] {
        VSCodeManager.buildItems(
            for: host,
            rawEntries: vscodeRawEntries,
            allHosts: hosts,
            mountConfigs: mountConfigs,
            tunnelConfigs: tunnelConfigs
        )
    }

    func openVSCodeWorkspaceCount(for host: SSHHost) -> Int {
        vscodeItems(for: host).filter(\.isOpenInWindow).count
    }

    func presentOpenVSCodePath(for host: SSHHost) {
        openVSCodePathTargetHost = host
        isShowingOpenVSCodePathSheet = true
    }

    func openPrimaryVSCodeOrPicker(for host: SSHHost) {
        let items = vscodeItems(for: host)
        if let first = items.first {
            openVSCodeWorkspace(first, for: host)
        } else {
            presentOpenVSCodePath(for: host)
        }
    }

    private func ensureSSHTunnelRunningIfNeeded(for host: SSHHost) async -> Bool {
        guard let sshCfg = tunnelItems(for: host).first(where: { $0.config.role == .ssh })?.config else {
            return true
        }
        let item = TunnelManager.shared.snapshotItems(for: [sshCfg]).first
        if item?.isRunning == true {
            return true
        }
        let onExit = attachExitHandler(for: sshCfg)
        do {
            try await TunnelManager.shared.start(config: sshCfg, onTermination: onExit)
            syncTunnelSnapshots()
            return true
        } catch {
            syncTunnelSnapshots()
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showFeedback(.error, msg)
            return false
        }
    }

    func openVSCodeWorkspace(_ item: VSCodeWorkspaceItem, for host: SSHHost, forceNewWindow: Bool = false) {
        Task {
            guard await ensureSSHTunnelRunningIfNeeded(for: host) else { return }
            do {
                try VSCodeManager.openWorkspace(item, forceNewWindow: forceNewWindow)
                showFeedback(.success, "Opening \(item.name) (\(host.alias)) in VS Code…")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refreshVSCodeWorkspaces()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showFeedback(.error, msg)
            }
        }
    }

    func openVSCodeRemotePath(_ remotePath: String, for host: SSHHost, forceNewWindow: Bool = false) {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isShowingOpenVSCodePathSheet = false
        openVSCodePathTargetHost = nil

        Task {
            guard await ensureSSHTunnelRunningIfNeeded(for: host) else { return }
            let kind: VSCodeWorkspaceKind = trimmed.hasSuffix(".code-workspace") ? .workspaceFile : .folder
            do {
                try VSCodeManager.openRemotePath(
                    authority: host.alias,
                    remotePath: trimmed,
                    kind: kind,
                    forceNewWindow: forceNewWindow
                )
                let label = URL(fileURLWithPath: trimmed).lastPathComponent
                showFeedback(.success, "Opening \(label) on \(host.alias) in VS Code…")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refreshVSCodeWorkspaces()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showFeedback(.error, msg)
            }
        }
    }

    func openVSCodeEmptyWindow(for host: SSHHost) {
        Task {
            guard await ensureSSHTunnelRunningIfNeeded(for: host) else { return }
            do {
                try VSCodeManager.openEmptyHostWindow(authority: host.alias)
                showFeedback(.success, "Connecting VS Code Remote-SSH to \(host.alias)…")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refreshVSCodeWorkspaces()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showFeedback(.error, msg)
            }
        }
    }

    // MARK: - Mount Management

    func reloadMounts() {
        let url = mountsURL
        Task {
            let loaded = await Task.detached(priority: .utility) {
                (
                    configs: MountManager.loadConfigs(from: url),
                    system: MountManager.activeSystemMounts(),
                    hasRclone: MountManager.findRcloneExecutable() != nil
                )
            }.value
            mountConfigs = loaded.configs
            systemMounts = loaded.system
            isRcloneAvailable = loaded.hasRclone
        }
    }

    func refreshMountStatus() async {
        let latest = await Task.detached(priority: .utility) {
            (
                system: MountManager.activeSystemMounts(),
                hasRclone: MountManager.findRcloneExecutable() != nil
            )
        }.value
        systemMounts = latest.system
        isRcloneAvailable = latest.hasRclone
    }

    private func autoMountOnlineHostsIfNeeded() async {
        guard isRcloneAvailable else { return }
        for cfg in mountConfigs where cfg.autoMount {
            let id = cfg.id.uuidString
            guard mountBusyStates[id] == nil else { continue }
            guard let host = hosts.first(where: {
                $0.allAliases.map { $0.lowercased() }.contains(cfg.hostAlias.lowercased())
            }) else { continue }
            guard snapshots[host.alias]?.state == .online else { continue }
            let existing = mountItems(for: host).first { $0.id == id }
            if existing?.isMounted == true { continue }
            mountBusyStates[id] = .mounting
            try? await MountManager.mount(config: cfg)
            mountBusyStates.removeValue(forKey: id)
        }
        await refreshMountStatus()
    }

    func mountItems(for host: SSHHost) -> [FolderMountItem] {
        MountManager.buildItems(
            for: host,
            configs: mountConfigs,
            systemMounts: systemMounts,
            busyStates: mountBusyStates,
            errors: mountErrors
        )
    }

    func mountedItemsCount(for host: SSHHost) -> Int {
        mountItems(for: host).filter(\.isMounted).count
    }

    func presentAddMount(for host: SSHHost) {
        let homeDir = snapshots[host.alias]?.metrics?.homeDirectory ?? "/home/\(host.user)"
        let suggestedRemote = snapshots[host.alias]?.metrics?.candidateDirectories.first ?? homeDir
        let suggestedLocal = MountManager.suggestedLocalPath(
            hostAlias: host.alias,
            remotePath: suggestedRemote
        )
        let label = URL(fileURLWithPath: suggestedLocal).lastPathComponent
        editingMountConfig = FolderMountConfig(
            hostAlias: host.alias,
            label: label,
            remotePath: suggestedRemote,
            localPath: suggestedLocal,
            autoMount: true
        )
        isShowingAddMountSheet = true
    }

    func presentEditMount(_ config: FolderMountConfig) {
        editingMountConfig = config
        isShowingAddMountSheet = true
    }

    func saveMountConfig(_ config: FolderMountConfig, mountImmediately: Bool) {
        var updated = mountConfigs
        if let existingIndex = updated.firstIndex(where: { $0.id == config.id }) {
            updated[existingIndex] = config
        } else {
            updated.append(config)
        }
        mountConfigs = updated
        persistMountConfigs(updated)
        isShowingAddMountSheet = false
        editingMountConfig = nil

        if mountImmediately {
            mountFolder(config)
        } else {
            showFeedback(.success, "Saved mount configuration \"\(config.label)\".")
        }
    }

    func toggleAutoMount(for config: FolderMountConfig) {
        guard let index = mountConfigs.firstIndex(where: { $0.id == config.id }) else { return }
        mountConfigs[index].autoMount.toggle()
        persistMountConfigs(mountConfigs)
    }

    func removeMountConfig(_ config: FolderMountConfig) {
        let id = config.id.uuidString
        Task {
            let items = hosts
                .first(where: { $0.allAliases.map { $0.lowercased() }.contains(config.hostAlias.lowercased()) })
                .map { mountItems(for: $0) } ?? []
            if let existing = items.first(where: { $0.id == id }), existing.isMounted {
                mountBusyStates[id] = .unmounting
                try? await MountManager.unmount(localPath: config.expandedLocalPath, sourceKind: .managedSFTP)
                mountBusyStates.removeValue(forKey: id)
            }
            mountConfigs.removeAll { $0.id == config.id }
            mountErrors.removeValue(forKey: id)
            persistMountConfigs(mountConfigs)
            await refreshMountStatus()
            showFeedback(.info, "Removed mount \"\(config.label)\".")
        }
    }

    func mountFolder(_ config: FolderMountConfig) {
        let id = config.id.uuidString
        guard mountBusyStates[id] == nil else { return }

        mountBusyStates[id] = .mounting
        mountErrors.removeValue(forKey: id)

        Task {
            do {
                try await MountManager.mount(config: config)
                mountBusyStates.removeValue(forKey: id)
                await refreshMountStatus()
                showFeedback(.success, "Mounted \(config.displayLocalPath)")
            } catch {
                mountBusyStates.removeValue(forKey: id)
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                mountErrors[id] = msg
                await refreshMountStatus()
                showFeedback(.error, msg)
            }
        }
    }

    func unmountItem(_ item: FolderMountItem) {
        guard mountBusyStates[item.id] == nil else { return }
        mountBusyStates[item.id] = .unmounting
        mountErrors.removeValue(forKey: item.id)

        Task {
            do {
                try await MountManager.unmount(localPath: item.localPath, sourceKind: item.sourceKind)
                mountBusyStates.removeValue(forKey: item.id)
                await refreshMountStatus()
                showFeedback(.info, "Unmounted \(item.displayLocalPath)")
            } catch {
                mountBusyStates.removeValue(forKey: item.id)
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                mountErrors[item.id] = msg
                await refreshMountStatus()
                showFeedback(.error, msg)
            }
        }
    }

    func openPrimaryMountOrComposer(for host: SSHHost) {
        let items = mountItems(for: host)
        if let mounted = items.first(where: \.isMounted) {
            openMountInFinder(mounted)
        } else if let firstConfig = items.first?.config {
            mountFolder(firstConfig)
        } else {
            presentAddMount(for: host)
        }
    }

    func openMountInFinder(_ item: FolderMountItem) {
        if let err = TerminalLauncher.openInFinder(item.localPath) {
            showFeedback(.error, err)
        }
    }

    func openMountInTerminal(_ item: FolderMountItem) {
        if let err = TerminalLauncher.openLocalDirectoryInTerminal(item.localPath) {
            showFeedback(.error, err)
        }
    }

    func openSSHInTerminal(for host: SSHHost) {
        if let err = TerminalLauncher.openTerminal(for: host) {
            showFeedback(.error, err)
        }
    }

    func showFeedback(_ kind: ActionFeedback.Kind, _ message: String) {
        feedbackDismissTask?.cancel()
        let next = ActionFeedback(kind: kind, message: message)
        feedback = next

        let delayNs: UInt64 = kind == .error ? 6_000_000_000 : 2_800_000_000
        feedbackDismissTask = Task {
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            if feedback?.id == next.id {
                feedback = nil
            }
        }
    }

    func dismissFeedback() {
        feedbackDismissTask?.cancel()
        feedback = nil
    }

    private func persistMountConfigs(_ configs: [FolderMountConfig]) {
        let url = mountsURL
        Task.detached(priority: .utility) {
            try? MountManager.saveConfigs(configs, to: url)
        }
    }

    // MARK: - SSH Discovery & Streaming Refresh

    func reloadConfiguration() {
        scanTask?.cancel()
        refreshTask?.cancel()
        isRefreshing = false
        isScanning = true
        scanError = nil

        reloadMounts()
        reloadVSCodeWorkspaces()
        syncTunnelSnapshots()

        let url = configURL
        scanTask = Task {
            do {
                let discovered = try await Task.detached(priority: .userInitiated) {
                    try SSHConfigParser.discover(configURL: url)
                }.value

                guard !Task.isCancelled else { return }

                let oldSnapshots = snapshots
                var nextSnapshots: [String: HostSnapshot] = [:]
                for host in discovered {
                    let previous = oldSnapshots[host.alias]
                    nextSnapshots[host.alias] = HostSnapshot(
                        host: host,
                        state: previous?.state ?? .idle,
                        metrics: previous?.metrics,
                        latencyMilliseconds: previous?.latencyMilliseconds,
                        lastUpdated: previous?.lastUpdated,
                        message: previous?.message
                    )
                }

                hosts = discovered
                snapshots = nextSnapshots
                isScanning = false

                if selectedAlias == nil || nextSnapshots[selectedAlias ?? ""] == nil {
                    selectedAlias = sortedHosts(matching: "").first?.alias ?? discovered.first?.alias
                }

                refreshAll()
            } catch {
                guard !Task.isCancelled else { return }
                isScanning = false
                scanError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                hosts = []
                snapshots = [:]
                selectedAlias = nil
            }
        }
    }

    func refreshAll() {
        guard !hosts.isEmpty else { return }
        refreshTask?.cancel()

        let hostsToProbe = hosts
        isRefreshing = true
        syncTunnelSnapshots()

        for host in hostsToProbe {
            if var snapshot = snapshots[host.alias] {
                snapshot.state = .checking
                snapshots[host.alias] = snapshot
            }
        }

        refreshTask = Task {
            await refreshMountStatus()
            await refreshVSCodeWorkspaces()

            await withTaskGroup(of: (String, HostProbeResult).self) { group in
                for host in hostsToProbe {
                    group.addTask {
                        (host.alias, await RemoteMetricsCollector.collect(host: host))
                    }
                }

                for await (alias, result) in group {
                    guard !Task.isCancelled else { break }
                    guard var snapshot = snapshots[alias] else { continue }
                    apply(result, to: &snapshot)
                    snapshots[alias] = snapshot
                    lastRefresh = Date()
                }
            }

            if !Task.isCancelled {
                await autoMountOnlineHostsIfNeeded()
                syncTunnelSnapshots()
                isRefreshing = false
                lastRefresh = Date()
            }
        }
    }

    func refresh(alias: String) {
        guard !refreshingAliases.contains(alias) else { return }
        guard var snapshot = snapshots[alias] else { return }

        refreshingAliases.insert(alias)
        snapshot.state = .checking
        snapshots[alias] = snapshot
        let host = snapshot.host
        syncTunnelSnapshots()

        Task {
            await refreshMountStatus()
            let result = await RemoteMetricsCollector.collect(host: host)
            refreshingAliases.remove(alias)

            guard var updated = snapshots[alias] else { return }
            apply(result, to: &updated)
            snapshots[alias] = updated
            lastRefresh = Date()
        }
    }

    private func apply(_ result: HostProbeResult, to snapshot: inout HostSnapshot) {
        snapshot.latencyMilliseconds = result.latencyMilliseconds
        if let metrics = result.metrics {
            snapshot.state = .online
            snapshot.metrics = metrics
            snapshot.lastUpdated = metrics.capturedAt
            snapshot.message = nil
        } else {
            snapshot.state = .offline
            snapshot.message = result.errorMessage
        }
    }

    private func configureAutoRefresh() {
        autoRefreshTask?.cancel()

        guard refreshInterval > 0 else { return }
        let interval = refreshInterval

        autoRefreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if !isRefreshing {
                    refreshAll()
                }
            }
        }
    }
}
