import NodeDeckCore
import SwiftUI

private enum HostDetailTab: String, CaseIterable, Identifiable {
    case overview
    case desktopAndNetwork
    case workspace

    var id: String { rawValue }
}

struct HostDetailView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    let snapshot: HostSnapshot

    @State private var selectedTab: HostDetailTab = .overview
    @State private var didCopyCommand = false
    @State private var slurmFilter = "idle"

    private var mountedItems: [FolderMountItem] {
        store.mountItems(for: snapshot.host).filter(\.isMounted)
    }

    private var vscodeItems: [VSCodeWorkspaceItem] {
        store.vscodeItems(for: snapshot.host)
    }

    private var activeNetworkCount: Int {
        let forwards = store.portForwardItems(for: snapshot.host).filter(\.isRunning).count
        let paired = store.sunshineConfig(for: snapshot.host) != nil ? 1 : 0
        return forwards + paired
    }

    private var workspaceBadgeCount: Int {
        mountedItems.count + vscodeItems.filter(\.isOpenInWindow).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hostHeader

                tabPickerBar

                if let feedback = store.feedback {
                    feedbackBanner(feedback)
                }

                if snapshot.state == .offline {
                    offlineBanner
                }

                switch selectedTab {
                case .overview:
                    if let metrics = snapshot.metrics {
                        metricsSection(metrics)
                        gpuSection(metrics)
                        slurmSection(metrics)
                        processSection(metrics)
                        informationSection(metrics)
                    } else if snapshot.state == .checking {
                        connectingPlaceholder
                    } else {
                        noMetricsPlaceholder
                    }

                case .desktopAndNetwork:
                    RemoteDesktopSectionView(snapshot: snapshot)
                    PortForwardSectionView(snapshot: snapshot)

                case .workspace:
                    VSCodeSectionView(snapshot: snapshot)
                    MountSectionView(snapshot: snapshot)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .id(snapshot.id)
    }

    private var tabPickerBar: some View {
        HStack(spacing: 6) {
            tabPill(
                tab: .overview,
                icon: "gauge.with.dots.needle.33percent",
                title: l10n.t("概览", "Overview"),
                badge: nil
            )
            tabPill(
                tab: .desktopAndNetwork,
                icon: "play.display",
                title: l10n.t("远程与网络", "Desktop & Network"),
                badge: activeNetworkCount > 0 ? activeNetworkCount : nil
            )
            tabPill(
                tab: .workspace,
                icon: "folder.badge.gearshape",
                title: l10n.t("工作区", "Workspace"),
                badge: workspaceBadgeCount > 0 ? workspaceBadgeCount : nil
            )
            Spacer()
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    private func tabPill(tab: HostDetailTab, icon: String, title: String, badge: Int?) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? AppTheme.accent.opacity(0.22) : Color.secondary.opacity(0.15))
                        )
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.clear)
            )
            .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hostHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                hostIdentityBlock
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    primaryActionButtons
                    utilityIconButtons
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    hostIdentityBlock
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        utilityIconButtons
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                FlowLayout(spacing: 8, lineSpacing: 8) {
                    primaryActionButtons
                }
            }
        }
    }

    private var hostIdentityBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            HostAvatar(host: snapshot.host, size: 52)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.host.alias)
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !snapshot.host.alternateAliases.isEmpty {
                        Text(snapshot.host.alternateAliases.joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppTheme.subtleBorder, lineWidth: 1)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(snapshot.host.loginTarget)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                FlowLayout(spacing: 8, lineSpacing: 6) {
                    StatusBadge(state: snapshot.state)
                    if let mesh = store.meshTransport(for: snapshot.host) {
                        meshTransportPill(mesh)
                    } else {
                        RouteBadge(route: snapshot.host.routeKind)
                    }
                    if let latency = snapshot.latencyMilliseconds, snapshot.state == .online {
                        Label(DisplayFormat.latency(latency), systemImage: "bolt.horizontal")
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 3)
                            .help("Estimated SSH round-trip latency")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func meshTransportPill(_ mesh: MeshPeerTransport) -> some View {
        let tint: Color = mesh.isP2P
            ? (mesh.tunnelProto.contains("tcp") ? .teal : .green)
            : (mesh.isTcpRelay ? .red : .orange)
        let icon = mesh.isP2P ? "arrow.left.arrow.right.circle.fill" : (mesh.isTcpRelay ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
        let tip: String = mesh.isP2P
            ? l10n.t("EasyTier 点对点直连 (\(mesh.detailedBadge))", "EasyTier P2P Direct (\(mesh.detailedBadge))")
            : l10n.t(
                "当前经由中继转发 (\(mesh.detailedBadge)\(mesh.relayVia.isEmpty ? "" : " · via \(mesh.relayVia)"))。若卡顿或码率低，请在云端防火墙放行 UDP 11010 或将 EasyTier 加入代理直连以恢复 P2P。",
                "Traffic is relayed (\(mesh.detailedBadge)\(mesh.relayVia.isEmpty ? "" : " · via \(mesh.relayVia)")). Open UDP 11010 on your seed server or bypass local proxy for EasyTier to restore P2P."
            )
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(mesh.detailedBadge)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
        .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(tip)
    }

    @ViewBuilder
    private var primaryActionButtons: some View {
        Button {
            store.openSSHInTerminal(for: snapshot.host)
        } label: {
            Label(l10n.t("打开终端", "Terminal"), systemImage: "terminal")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accent)
        .fixedSize(horizontal: true, vertical: false)
        .help("\(snapshot.host.terminalCommand) (⌘↩)")

        if let native = store.sunshineConfig(for: snapshot.host) {
            Button {
                store.launchNativeMoonlightStream(
                    hostAlias: snapshot.host.alias,
                    address: native.address,
                    httpPort: native.httpPort
                )
            } label: {
                Label(l10n.t("远程桌面", "Remote Desktop"), systemImage: "play.display")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help(l10n.t(
                "启动内置硬件加速远程桌面 (\(store.streamResolution.label) @ \(store.streamRefreshRate.label) · ⇧⌘D)",
                "Stream native hardware-accelerated desktop (\(store.streamResolution.label) @ \(store.streamRefreshRate.label) · ⇧⌘D)"
            ))
        } else {
            Button {
                TerminalLauncher.copyCommand(for: snapshot.host)
                didCopyCommand = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    didCopyCommand = false
                }
            } label: {
                Label(
                    didCopyCommand ? l10n.t("已复制", "Copied") : l10n.t("复制 SSH", "Copy SSH"),
                    systemImage: didCopyCommand ? "checkmark" : "doc.on.doc"
                )
                .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help(l10n.t("复制 SSH 连接命令 (⇧⌘C)", "Copy SSH command (⇧⌘C)"))
        }
    }

    @ViewBuilder
    private var utilityIconButtons: some View {
        Button {
            store.togglePin(snapshot.host.alias)
        } label: {
            Image(systemName: store.isPinned(snapshot.host.alias) ? "pin.fill" : "pin")
                .foregroundStyle(store.isPinned(snapshot.host.alias) ? AppTheme.accent : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .help(store.isPinned(snapshot.host.alias) ? l10n.t("取消置顶", "Unpin host") : l10n.t("置顶此主机", "Pin host to top"))

        Button {
            store.refresh(alias: snapshot.host.alias)
        } label: {
            Image(systemName: "arrow.clockwise")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .disabled(snapshot.state == .checking)
        .help(l10n.t("刷新主机指标", "Refresh this host"))

        Menu {
            Button(l10n.t("复制 SSH 命令", "Copy SSH Command")) {
                TerminalLauncher.copyCommand(for: snapshot.host)
                store.showFeedback(.info, l10n.t("已复制 \(snapshot.host.terminalCommand)", "Copied \(snapshot.host.terminalCommand)"))
            }
            Divider()
            Button(l10n.t("编辑设备配置…", "Edit Device…")) {
                store.presentEditHost(snapshot.host)
            }
            Button(l10n.t("删除设备…", "Delete Device…"), role: .destructive) {
                store.requestDeleteHost(snapshot.host)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help(l10n.t("更多操作", "More actions"))
    }

    private func feedbackBanner(_ feedback: ActionFeedback) -> some View {
        let color: Color = switch feedback.kind {
        case .info: AppTheme.disk
        case .success: AppTheme.statusColor(.online)
        case .error: AppTheme.critical
        }
        let icon: String = switch feedback.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }

        return HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(feedback.message)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer()
            Button {
                store.dismissFeedback()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
    }

    private var offlineBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(AppTheme.statusColor(.offline))
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("无法连接到主机", "Unable to connect"))
                    .font(.callout.weight(.medium))
                Text(snapshot.message ?? l10n.t("SSH 探测失败", "SSH probe failed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let lastUpdated = snapshot.lastUpdated {
                    Text(l10n.t("显示 \(DisplayFormat.time(lastUpdated)) 的缓存指标", "Showing cached metrics from \(DisplayFormat.time(lastUpdated))"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(l10n.t("重试", "Retry")) {
                store.refresh(alias: snapshot.host.alias)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.statusColor(.offline).opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.statusColor(.offline).opacity(0.16), lineWidth: 1)
        )
    }

    private func metricsSection(_ metrics: HostMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(
                title: l10n.t("资源占用", "Resource Usage"),
                detail: snapshot.lastUpdated.map { l10n.t("更新于 \(DisplayFormat.time($0))", "Updated \(DisplayFormat.time($0))") }
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 175), spacing: 10)],
                spacing: 10
            ) {
                MetricTile(
                    title: "CPU",
                    value: DisplayFormat.percent(metrics.cpuUsage / 100),
                    subtitle: "\(metrics.cpuCores) cores · load \(DisplayFormat.number(metrics.load1))",
                    fraction: metrics.cpuUsage / 100,
                    color: AppTheme.cpu,
                    symbol: "cpu"
                )

                MetricTile(
                    title: "Memory",
                    value: DisplayFormat.percent(metrics.memoryFraction),
                    subtitle: "\(DisplayFormat.bytes(metrics.memoryUsed)) / \(DisplayFormat.bytes(metrics.memoryTotal))",
                    fraction: metrics.memoryFraction,
                    color: AppTheme.memory,
                    symbol: "memorychip"
                )

                MetricTile(
                    title: "Disk (/)",
                    value: DisplayFormat.percent(metrics.diskFraction),
                    subtitle: "\(DisplayFormat.bytes(metrics.diskAvailable)) free of \(DisplayFormat.bytes(metrics.diskTotal))",
                    fraction: metrics.diskFraction,
                    color: AppTheme.disk,
                    symbol: "internaldrive"
                )

                MetricTile(
                    title: "Load",
                    value: DisplayFormat.number(metrics.load1),
                    subtitle: "5m \(DisplayFormat.number(metrics.load5)) · 15m \(DisplayFormat.number(metrics.load15))",
                    fraction: metrics.cpuCores > 0
                        ? min(metrics.load1 / Double(metrics.cpuCores), 1)
                        : 0,
                    color: AppTheme.load,
                    symbol: "waveform.path.ecg"
                )
            }
        }
    }

    @ViewBuilder
    private func gpuSection(_ metrics: HostMetrics) -> some View {
        if !metrics.gpus.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: l10n.t("GPU 加速卡", "GPU Accelerators"),
                    detail: l10n.t("\(metrics.gpus.count) 张设备", "\(metrics.gpus.count) device(s)")
                )

                VStack(spacing: 0) {
                    ForEach(Array(metrics.gpus.enumerated()), id: \.element.id) { index, gpu in
                        GPURow(gpu: gpu)
                        if index < metrics.gpus.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
                .cardBackground()
            }
        }
    }

    @ViewBuilder
    private func slurmSection(_ metrics: HostMetrics) -> some View {
        if let slurm = metrics.slurm {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        SectionTitle(
                            title: "Slurm Cluster",
                            detail: "\(slurm.nodes.count) nodes · \(slurm.idleNodeCount) idle · \(slurm.occupiedNodeCount) occupied"
                        )

                        SlurmFilterControl(
                            selection: $slurmFilter,
                            idleCount: slurm.idleNodeCount,
                            allocatedCount: slurm.allocatedNodeCount,
                            mixedCount: slurm.mixedNodeCount,
                            totalCount: slurm.nodes.count
                        )
                        .frame(width: 320)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(
                            title: "Slurm Cluster",
                            detail: "\(slurm.nodes.count) nodes · \(slurm.idleNodeCount) idle · \(slurm.occupiedNodeCount) occupied"
                        )

                        SlurmFilterControl(
                            selection: $slurmFilter,
                            idleCount: slurm.idleNodeCount,
                            allocatedCount: slurm.allocatedNodeCount,
                            mixedCount: slurm.mixedNodeCount,
                            totalCount: slurm.nodes.count
                        )
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 165), spacing: 10)],
                    spacing: 10
                ) {
                    SlurmSummaryTile(
                        title: "Idle Nodes",
                        value: "\(slurm.idleNodeCount)",
                        subtitle: "Ready to use",
                        color: AppTheme.slurmColor(.idle),
                        symbol: "checkmark.circle"
                    )
                    SlurmSummaryTile(
                        title: "Fully Allocated",
                        value: "\(slurm.allocatedNodeCount)",
                        subtitle: "All CPUs allocated",
                        color: AppTheme.slurmColor(.allocated),
                        symbol: "lock.circle"
                    )
                    SlurmSummaryTile(
                        title: "Partially Used",
                        value: "\(slurm.mixedNodeCount)",
                        subtitle: "Free CPUs remain",
                        color: AppTheme.slurmColor(.mixed),
                        symbol: "circle.lefthalf.filled"
                    )
                    SlurmSummaryTile(
                        title: "Idle CPUs",
                        value: "\(slurm.idleCPUs)",
                        subtitle: "of \(slurm.totalCPUs) cores",
                        color: AppTheme.disk,
                        symbol: "cpu"
                    )
                }

                VStack(spacing: 0) {
                    slurmTableHeader
                    Divider()

                    let visibleNodes = filteredSlurmNodes(slurm)
                    if visibleNodes.isEmpty {
                        Text("No nodes match this filter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(visibleNodes.enumerated()), id: \.element.id) { index, node in
                                    SlurmNodeRow(node: node)
                                    if index < visibleNodes.count - 1 {
                                        Divider()
                                            .padding(.leading, 14)
                                    }
                                }
                            }
                        }
                        .frame(height: min(max(CGFloat(visibleNodes.count) * 38, 60), 300))
                    }
                }
                .cardBackground()
            }
        }
    }

    private var slurmTableHeader: some View {
        HStack(spacing: 10) {
            Text("Node")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("State")
                .frame(width: 54, alignment: .leading)
            Text("Idle CPUs")
                .frame(width: 72, alignment: .trailing)
            Text("Memory")
                .frame(width: 58, alignment: .trailing)
            Text("GPU")
                .frame(width: 76, alignment: .leading)
            Text("Partition")
                .frame(width: 92, alignment: .leading)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func filteredSlurmNodes(_ slurm: SlurmInfo) -> [SlurmNode] {
        let nodes: [SlurmNode]
        switch slurmFilter {
        case "idle":
            nodes = slurm.nodes.filter { $0.category == .idle }
        case "allocated":
            nodes = slurm.nodes.filter { $0.category == .allocated }
        case "mixed":
            nodes = slurm.nodes.filter { $0.category == .mixed }
        default:
            nodes = slurm.nodes
        }

        return nodes.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func processSection(_ metrics: HostMetrics) -> some View {
        if !metrics.processes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: l10n.t("高负载进程", "Top Processes"),
                    detail: l10n.t("按 CPU 排序", "Sorted by CPU")
                )

                VStack(spacing: 0) {
                    HStack {
                        Text(l10n.t("进程与参数", "Command & Arguments"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU")
                            .frame(width: 64, alignment: .trailing)
                        Text(l10n.t("内存", "Memory"))
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(metrics.processes.enumerated()), id: \.element.id) { index, process in
                        HStack(alignment: .top) {
                            Text(process.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .help(process.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.1f%%", process.cpuPercent))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(process.cpuPercent > 50 ? AppTheme.load : .primary)
                                .frame(width: 64, alignment: .trailing)
                            Text(String(format: "%.1f%%", process.memoryPercent))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        if index < metrics.processes.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
                .cardBackground()
            }
        }
    }

    private func informationSection(_ metrics: HostMetrics) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 270), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            InfoPanel(
                title: "Connection",
                rows: [
                    InfoRowData(label: "Alias", value: snapshot.host.allAliases.joined(separator: ", "), monospaced: true),
                    InfoRowData(label: "Host", value: snapshot.host.hostName, monospaced: true),
                    InfoRowData(label: "User", value: snapshot.host.user, monospaced: true),
                    InfoRowData(label: "Port", value: "\(snapshot.host.port)", monospaced: true),
                    InfoRowData(
                        label: "Identity",
                        value: snapshot.host.identityFile ?? "Default key",
                        monospaced: true
                    ),
                    InfoRowData(
                        label: "Jump",
                        value: snapshot.host.proxyJump ?? "None",
                        monospaced: true
                    ),
                    InfoRowData(
                        label: "Forward",
                        value: snapshot.host.localForwards.isEmpty
                            ? "None"
                            : snapshot.host.localForwards.joined(separator: ", "),
                        monospaced: true
                    ),
                    InfoRowData(
                        label: "Keepalive",
                        value: snapshot.host.serverAliveInterval.map { "\($0)s" } ?? "Not set",
                        monospaced: false
                    )
                ]
            )

            InfoPanel(
                title: "System",
                rows: [
                    InfoRowData(label: "Hostname", value: metrics.hostname, monospaced: true),
                    InfoRowData(label: "OS", value: metrics.osName, monospaced: false),
                    InfoRowData(label: "Kernel", value: metrics.kernel, monospaced: true),
                    InfoRowData(label: "Arch", value: metrics.architecture, monospaced: true),
                    InfoRowData(
                        label: "Processor",
                        value: metrics.cpuModel.isEmpty ? "--" : metrics.cpuModel,
                        monospaced: false
                    ),
                    InfoRowData(label: "Uptime", value: DisplayFormat.uptime(metrics.uptimeSeconds), monospaced: false),
                    InfoRowData(
                        label: "Swap",
                        value: metrics.swapTotal > 0
                            ? "\(DisplayFormat.bytes(metrics.swapUsed)) / \(DisplayFormat.bytes(metrics.swapTotal))"
                            : "Disabled",
                        monospaced: false
                    ),
                    InfoRowData(
                        label: "SSH RTT",
                        value: DisplayFormat.latency(snapshot.latencyMilliseconds),
                        monospaced: true
                    )
                ]
            )
        }
    }

    private var connectingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Collecting remote metrics")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var noMetricsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No performance data yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Check Now") {
                store.refresh(alias: snapshot.host.alias)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}

private struct SlurmSummaryTile: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)

            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .cardBackground()
    }
}

private struct SlurmFilterControl: View {
    @Binding var selection: String
    let idleCount: Int
    let allocatedCount: Int
    let mixedCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 2) {
            item(id: "idle", title: "Idle \(idleCount)")
            item(id: "allocated", title: "Full \(allocatedCount)")
            item(id: "mixed", title: "Partial \(mixedCount)")
            item(id: "all", title: "All \(totalCount)")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    private func item(id: String, title: String) -> some View {
        Button {
            selection = id
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: selection == id ? .semibold : .regular))
                .foregroundStyle(selection == id ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selection == id ? AppTheme.accent.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SlurmNodeRow: View {
    let node: SlurmNode

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(AppTheme.slurmColor(node.category))
                    .frame(width: 6, height: 6)

                Text(node.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(node.category.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.slurmColor(node.category))
                .frame(width: 54, alignment: .leading)

            Text("\(node.idleCPUs) / \(node.totalCPUs)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(node.idleCPUs > 0 ? .primary : .secondary)
                .frame(width: 72, alignment: .trailing)

            Text("\(node.memoryMB / 1024) GB")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)

            Text(node.gpuDescription ?? "--")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(node.gpuDescription == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)

            Text(node.partition)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 92, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help("\(node.name) · \(node.state) · \(node.features)")
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let fraction: Double
    let color: Color
    let symbol: String

    var body: some View {
        let effectiveColor = AppTheme.severityColor(fraction: fraction, base: color)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(effectiveColor)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            MeterBar(value: fraction, color: color)

            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
        .cardBackground()
    }
}

private struct GPURow: View {
    let gpu: GPUInfo

    private var accentColor: Color {
        gpu.isAMD ? AppTheme.amdGPU : AppTheme.cpu
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: gpu.isAMD ? "cpu" : "rectangle.stack.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(gpu.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if gpu.isSleeping {
                        Text("D3 Sleep")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                            )
                            .help("GPU is in PCIe runtime D3cold power-saving mode")
                    }
                }

                if let fraction = gpu.memoryFraction {
                    HStack(spacing: 8) {
                        MeterBar(value: fraction, color: accentColor, height: 4)
                        Text(DisplayFormat.vram(usedMB: gpu.memoryUsedMB, totalMB: gpu.memoryTotalMB))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let utilization = gpu.utilization {
                    Text("\(Int(utilization))%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accentColor)
                        .frame(minWidth: 38, alignment: .trailing)
                }

                if let temperature = gpu.temperatureC {
                    let tempColor: Color = temperature >= 82 ? AppTheme.critical : (temperature >= 72 ? AppTheme.warning : .secondary)
                    Label("\(Int(temperature))°", systemImage: "thermometer.medium")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(tempColor)
                } else if gpu.isSleeping {
                    Text("Idle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let power = gpu.powerW {
                    Text("\(Int(power)) W")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .trailing)
                } else if gpu.isSleeping {
                    Text("0 W")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 42, alignment: .trailing)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct InfoPanel: View {
    let title: String
    let rows: [InfoRowData]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 7)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Text(row.value)
                        .font(row.monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)

                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, 84)
                }
            }
        }
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

private struct InfoRowData {
    let label: String
    let value: String
    let monospaced: Bool
}
