import NodeDeckCore
import SwiftUI

struct TunnelSectionView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    let snapshot: HostSnapshot

    private var items: [TunnelRuntimeItem] {
        store.tunnelItems(for: snapshot.host)
    }

    private var runningCount: Int {
        items.filter(\.isRunning).count
    }

    private var moonlightTarget: MoonlightTarget? {
        store.moonlightTarget(for: snapshot.host)
    }

    private var nativeSunshine: SunshineHostConfig? {
        store.sunshineConfig(for: snapshot.host)
    }

    private var moonlightItem: TunnelRuntimeItem? {
        guard let cfg = moonlightTarget?.tunnelConfig else { return nil }
        return store.allTunnelItems.first { $0.id == cfg.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    SectionTitle(
                        title: l10n.t("远程桌面", "Remote Desktop"),
                        detail: nativeSunshine != nil
                            ? l10n.t("已就绪，点击即可直连", "Ready to connect")
                            : l10n.t("尚未配对", "Not paired yet")
                    )

                    Button {
                        store.presentHostProfile(for: snapshot.host)
                    } label: {
                        Label(l10n.t("主机配置", "Host Settings"), systemImage: "server.rack")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(l10n.t("高级设置：配置 Linux 多用户虚拟屏、GPU 与端口", "Advanced: configure Linux multi-user display, GPU, and port"))
                }

                if let native = nativeSunshine {
                    nativeSunshineBanner(native)
                } else {
                    unpairedSunshineBanner
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    SectionTitle(
                        title: l10n.t("GOST 隧道", "GOST Tunnels"),
                        detail: items.isEmpty
                            ? l10n.t("无自定义隧道（直连/局域网模式无需配置）", "No custom tunnels configured")
                            : l10n.t("\(runningCount) / \(items.count) 条运行中", "\(runningCount) of \(items.count) active")
                    )

                    Button {
                        store.presentAddTunnel(for: snapshot.host)
                    } label: {
                        Label(l10n.t("添加隧道", "Add Tunnel"), systemImage: "plus")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }

                if !store.isGostAvailable && !items.isEmpty {
                    gostMissingBanner
                }

                if !items.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            TunnelItemRow(item: item)
                            if index < items.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .cardBackground()
                }
            }
        }
        .sheet(isPresented: $store.isShowingTunnelSheet) {
            if let draft = store.editingTunnelConfig {
                TunnelEditorSheet(
                    initialConfig: draft,
                    isEditingExisting: store.tunnelConfigs.contains(where: { $0.id == draft.id })
                )
            }
        }
        .sheet(isPresented: $store.isShowingSunshinePairSheet) {
            if let pairHost = store.sunshinePairTargetHost {
                SunshinePairSheet(host: pairHost)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $store.isShowingHostProfileSheet) {
            if let targetHost = store.editingHostProfileTarget {
                HostProfileSheet(
                    host: targetHost,
                    initialProfile: store.hostProfile(for: targetHost)
                )
                .environmentObject(store)
            }
        }
    }

    private func nativeSunshineBanner(_ config: SunshineHostConfig) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.14))
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.host.alias)
                        .font(.system(size: 13.5, weight: .semibold))
                    TunnelStatePill(state: .running)
                }
                Text("\(config.address):\(config.httpPort)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Menu {
                    Button(l10n.t("1080p @ 60fps 串流", "Stream 1080p @ 60fps")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 1920, height: 1080, fps: 60)
                    }
                    Button(l10n.t("1080p + 隐私屏模式", "Stream 1080p + Privacy Screen")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 1920, height: 1080, fps: 60, enablePrivacyScreen: true)
                    }
                    Button(l10n.t("1440p @ 60fps 串流", "Stream 1440p @ 60fps")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 2560, height: 1440, fps: 60)
                    }
                    Button(l10n.t("4K @ 60fps 串流", "Stream 4K @ 60fps")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 3840, height: 2160, fps: 60)
                    }
                    Divider()
                    Button(l10n.t("打开宿主机 Web 管理台", "Open Host Web UI")) {
                        MoonlightLauncher.openSunshineWebUI(urlString: config.webUIURLString)
                    }
                    Button(l10n.t("重新免 PIN 配对…", "Re-pair Host…")) {
                        store.presentPairSunshine(for: snapshot.host)
                    }
                    Button(l10n.t("取消配对", "Unpair Host"), role: .destructive) {
                        store.removeSunshineHostConfig(config)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort)
                } label: {
                    Label(l10n.t("连接桌面", "Stream Desktop"), systemImage: "play.display")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.small)
                .help(l10n.t("打开内置硬件加速远程桌面窗口", "Open built-in hardware-accelerated desktop stream"))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(13)
        .cardBackground()
    }

    private var unpairedSunshineBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("尚未配对远程桌面", "Remote Desktop Not Paired Yet"))
                    .font(.system(size: 12.5, weight: .medium))
                Text(l10n.t(
                    "通过你已信任的 SSH 通道直接注入本地证书到 \(snapshot.host.hostName)，零云端中转、免 PIN 一键配对。",
                    "Injects a local client certificate over your SSH session to \(snapshot.host.hostName) — zero cloud relay, no manual PIN."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(l10n.t("免 PIN 配对…", "Zero-PIN Pair…")) {
                store.presentPairSunshine(for: snapshot.host)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)
        }
        .padding(13)
        .cardBackground()
    }

    private func moonlightBanner(_ target: MoonlightTarget, runtimeItem: TunnelRuntimeItem?) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.14))
                Image(systemName: "display.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let runtimeItem {
                        TunnelStatePill(state: runtimeItem.state)
                    } else {
                        TunnelStatePill(state: .running)
                    }
                }
                Text(target.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    MoonlightLauncher.openSunshineWebUI(urlString: target.webURLString)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Sunshine Web UI (\(target.webURLString))")

                Button {
                    store.launchMoonlight(target: target)
                } label: {
                    Label("Launch Moonlight", systemImage: "play.display")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.small)
                .help("Stream \(target.title) in Moonlight")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(13)
        .cardBackground()
    }

    private var gostMissingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
            Text("Install gost (`brew install gost`) so NodeDeck can manage QUIC tunnels.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy Command") {
                TerminalLauncher.copyText("brew install gost")
                store.showFeedback(.info, "Copied: brew install gost")
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
        }
        .padding(10)
        .cardBackground()
    }
}

private struct TunnelItemRow: View {
    @EnvironmentObject private var store: HostMonitor
    let item: TunnelRuntimeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.tunnelColor(item.state).opacity(0.13))
                    Image(systemName: item.config.role.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.tunnelColor(item.state))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.config.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)

                        TunnelStatePill(state: item.state)

                        if let pid = item.pid {
                            Text("PID \(pid)")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                                )
                        }

                        if item.config.autoStart {
                            Label("Auto", systemImage: "bolt.fill")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(item.config.portSummary)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(item.config.redactedForwardEndpoint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if item.isRunning {
                        Button("Restart") {
                            store.restartTunnel(item.config)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Stop") {
                            store.stopTunnel(item.config)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Start") {
                            store.startTunnel(item.config)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .controlSize(.small)
                        .disabled(item.state == .starting)
                    }

                    Menu {
                        Button(item.config.autoStart ? "Disable Auto-Start" : "Enable Auto-Start") {
                            store.toggleTunnelAutoStart(item.config)
                        }
                        Button("Edit Tunnel…") {
                            store.presentEditTunnel(item.config)
                        }
                        Divider()
                        Button("Remove Tunnel", role: .destructive) {
                            store.removeTunnelConfig(item.config)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if let errorMessage = item.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.critical)
                    .lineLimit(2)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct TunnelStatePill: View {
    let state: TunnelRuntimeState

    private var label: String {
        switch state {
        case .running: return "Active"
        case .starting: return "Starting"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }

    var body: some View {
        let color = AppTheme.tunnelColor(state)
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.14))
            )
    }
}

private struct TunnelEditorSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @Environment(\.dismiss) private var dismiss

    let isEditingExisting: Bool
    private let id: UUID
    @State private var hostAlias: String
    @State private var label: String
    @State private var role: TunnelRole
    @State private var listenSpecsText: String
    @State private var forwardChain: String
    @State private var autoStart: Bool

    init(initialConfig: GostTunnelConfig, isEditingExisting: Bool) {
        self.isEditingExisting = isEditingExisting
        self.id = initialConfig.id
        _hostAlias = State(initialValue: initialConfig.hostAlias)
        _label = State(initialValue: initialConfig.label)
        _role = State(initialValue: initialConfig.role)
        _listenSpecsText = State(initialValue: initialConfig.listenSpecs.joined(separator: "\n"))
        _forwardChain = State(initialValue: initialConfig.forwardChain)
        _autoStart = State(initialValue: initialConfig.autoStart)
    }

    private var parsedSpecs: [String] {
        listenSpecsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var isValid: Bool {
        !hostAlias.trimmingCharacters(in: .whitespaces).isEmpty &&
            !label.trimmingCharacters(in: .whitespaces).isEmpty &&
            !parsedSpecs.isEmpty &&
            !forwardChain.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditingExisting ? "Edit GOST Tunnel" : "Add GOST Tunnel")
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Host Alias")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("gpu-node", text: $hostAlias)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                .frame(width: 140)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Label")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("SSH (QUIC)", text: $label)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Role")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $role) {
                        ForEach(TunnelRole.allCases, id: \.self) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Local Listen Rules (-L, one per line)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $listenSpecsText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(height: 92)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.subtleBorder, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Upstream Relay Chain (-F)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("relay+quic://user:token@203.0.113.10:18443?keepalive=true", text: $forwardChain)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }

            Toggle("Start automatically with NodeDeck", isOn: $autoStart)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Only") {
                    commit(startImmediately: false)
                }
                .disabled(!isValid)

                Button(isEditingExisting ? "Save & Restart" : "Save & Start") {
                    commit(startImmediately: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func commit(startImmediately: Bool) {
        let cfg = GostTunnelConfig(
            id: id,
            hostAlias: hostAlias.trimmingCharacters(in: .whitespacesAndNewlines),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            listenSpecs: parsedSpecs,
            forwardChain: forwardChain.trimmingCharacters(in: .whitespacesAndNewlines),
            autoStart: autoStart
        )
        store.saveTunnelConfig(cfg, startImmediately: startImmediately)
        dismiss()
    }
}
