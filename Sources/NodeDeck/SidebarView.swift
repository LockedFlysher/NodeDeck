import NodeDeckCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding

    private var filteredHosts: [SSHHost] {
        store.sortedHosts(matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            filterBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if let scanError = store.scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            hostList

            Divider()
            footer
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.accent)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("NodeDeck")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    StatusDot(state: store.onlineCount > 0 ? .online : .idle, size: 6)
                    Text(l10n.t(
                        "\(store.onlineCount)/\(store.hosts.count) 在线 · \(store.mountedHostCount) 挂载",
                        "\(store.onlineCount)/\(store.hosts.count) online · \(store.mountedHostCount) mounted"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                store.presentAddHost()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(l10n.t("添加设备 (⌘N)", "Add Device (⌘N)"))

            if store.isRefreshing || store.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(l10n.t("刷新全部主机 (⌘R)", "Refresh all hosts (⌘R)"))
            }
        }
        .padding(.top, 32)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(l10n.t("搜索主机、挂载或 IP (⌘F)", "Search hosts, mounts, or IPs (⌘F)"), text: $searchText)
                .textFieldStyle(.plain)
                .focused(searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(SidebarFilter.allCases) { filter in
                let count = filterCount(filter)
                let isSelected = store.sidebarFilter == filter
                Button {
                    store.sidebarFilter = filter
                } label: {
                    Text("\(filter.localizedTitle) \(count)")
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? AppTheme.accent.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    private func filterCount(_ filter: SidebarFilter) -> Int {
        switch filter {
        case .all: return store.hosts.count
        case .online: return store.onlineCount
        case .mounted: return store.mountedHostCount
        case .gpu: return store.gpuHostCount
        }
    }

    private var hostList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(filteredHosts) { host in
                    if let snapshot = store.snapshots[host.alias] {
                        Button {
                            store.selectedAlias = host.alias
                        } label: {
                            HostRow(
                                snapshot: snapshot,
                                isSelected: store.selectedAlias == host.alias,
                                isPinned: store.isPinned(host.alias),
                                mountedCount: store.mountedItemsCount(for: host),
                                openVSCodeCount: store.openVSCodeWorkspaceCount(for: host)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            hostContextMenu(for: host)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func hostContextMenu(for host: SSHHost) -> some View {
        Button(l10n.t("在终端中打开", "Open in Terminal")) {
            store.openSSHInTerminal(for: host)
        }

        let wsItems = store.vscodeItems(for: host)
        if !wsItems.isEmpty {
            Menu(l10n.t("VS Code 工作区", "VS Code Workspaces")) {
                ForEach(wsItems) { item in
                    let suffix = item.isOpenInWindow ? l10n.t(" (已打开)", " (Open)") : ""
                    Button("\(item.name)\(suffix) — \(item.remotePath)") {
                        store.openVSCodeWorkspace(item, for: host)
                    }
                }
                Divider()
                Button(l10n.t("打开远程路径…", "Open Remote Path…")) {
                    store.selectedAlias = host.alias
                    store.presentOpenVSCodePath(for: host)
                }
            }
        } else {
            Button(l10n.t("在 VS Code 中打开…", "Open in VS Code…")) {
                store.selectedAlias = host.alias
                store.presentOpenVSCodePath(for: host)
            }
        }

        if let cfg = store.sunshineConfig(for: host) {
            Button(l10n.t("连接远程桌面", "Stream Remote Desktop")) {
                store.launchNativeMoonlightStream(hostAlias: host.alias, address: cfg.address, httpPort: cfg.httpPort)
            }
        }

        let mounted = store.mountItems(for: host).filter(\.isMounted)
        if let firstMounted = mounted.first {
            Button(l10n.t("在访达中打开 \(firstMounted.label)", "Open \(firstMounted.label) in Finder")) {
                store.openMountInFinder(firstMounted)
            }
        }
        Button(l10n.t("挂载远端目录…", "Mount Directory…")) {
            store.selectedAlias = host.alias
            store.presentAddMount(for: host)
        }

        Divider()

        Button(store.isPinned(host.alias) ? l10n.t("取消置顶", "Unpin Host") : l10n.t("置顶显示", "Pin to Top")) {
            store.togglePin(host.alias)
        }

        Button(l10n.t("刷新主机状态", "Refresh Host")) {
            store.refresh(alias: host.alias)
        }

        Divider()

        Button(l10n.t("复制 SSH 命令", "Copy SSH Command")) {
            TerminalLauncher.copyCommand(for: host)
            store.showFeedback(.info, l10n.t("已复制 \(host.terminalCommand)", "Copied \(host.terminalCommand)"))
        }

        Button(l10n.t("复制主机地址", "Copy Host Endpoint")) {
            TerminalLauncher.copyText(host.endpoint)
            store.showFeedback(.info, l10n.t("已复制 \(host.endpoint)", "Copied \(host.endpoint)"))
        }

        Divider()

        Button(l10n.t("编辑设备…", "Edit Device…")) {
            store.presentEditHost(host)
        }

        Button(l10n.t("删除设备…", "Delete Device…"), role: .destructive) {
            store.requestDeleteHost(host)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                Picker(l10n.t("自动刷新", "Auto refresh"), selection: $store.refreshInterval) {
                    Text(l10n.t("手动", "Manual")).tag(0.0)
                    Text(l10n.t("每 15 秒", "Every 15s")).tag(15.0)
                    Text(l10n.t("每 30 秒", "Every 30s")).tag(30.0)
                    Text(l10n.t("每 1 分钟", "Every 1m")).tag(60.0)
                    Text(l10n.t("每 2 分钟", "Every 2m")).tag(120.0)
                    Text(l10n.t("每 5 分钟", "Every 5m")).tag(300.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label(refreshLabel, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                store.isShowingArchitectureGuide = true
            } label: {
                Image(systemName: "shield.checkered")
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.borderless)
            .help(l10n.t("技术原理与安全透明", "How It Works & Security Model"))

            Button {
                l10n.toggleChineseEnglish()
            } label: {
                Text(l10n.isChinese ? "EN" : "中")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(AppTheme.subtleBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(l10n.t("切换为 English", "Switch to 简体中文"))

            Menu {
                Picker(l10n.t("界面语言", "Language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.menuTitle).tag(lang)
                    }
                }
                Divider()
                Toggle(
                    l10n.t("开机自启动", "Launch at Login"),
                    isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                Divider()
                Button(l10n.t("技术原理与安全说明…", "How It Works & Security…")) {
                    store.isShowingArchitectureGuide = true
                }
                Divider()
                Button(l10n.t("重载 SSH 配置与挂载", "Reload SSH Config & Mounts")) {
                    store.reloadConfiguration()
                }
                Button(l10n.t("打开 ~/.ssh/config", "Open ~/.ssh/config")) {
                    store.openSSHConfigInEditor()
                }
                Divider()
                Button(
                    store.localSunshineHostState == .running
                        ? l10n.t("停止本机被控端服务", "Stop Local Host Service")
                        : l10n.t("启动本机被控端服务", "Start Local Host Service")
                ) {
                    store.toggleLocalSunshineHost()
                }
                Divider()
                Button(l10n.t("退出 NodeDeck", "Quit NodeDeck"), role: .destructive) {
                    store.shutdownAndQuit()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n.t("设置、语言与本机被控端", "Settings, Language & Local Host"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var refreshLabel: String {
        switch Int(store.refreshInterval) {
        case 0: return l10n.t("手动", "Manual")
        case 15: return l10n.t("15秒", "15s")
        case 30: return l10n.t("30秒", "30s")
        case 60: return l10n.t("1分钟", "1m")
        case 120: return l10n.t("2分钟", "2m")
        case 300: return l10n.t("5分钟", "5m")
        default: return "\(Int(store.refreshInterval))s"
        }
    }
}

private struct HostRow: View {
    let snapshot: HostSnapshot
    let isSelected: Bool
    let isPinned: Bool
    let mountedCount: Int
    let openVSCodeCount: Int

    var body: some View {
        HStack(spacing: 10) {
            HostAvatar(host: snapshot.host, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.accent)
                    }
                    Text(snapshot.host.alias)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    StatusDot(state: snapshot.state, size: 6)
                    if mountedCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 8.5))
                            if mountedCount > 1 {
                                Text("\(mountedCount)")
                                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                            }
                        }
                        .foregroundStyle(AppTheme.mountColor(.mounted))
                        .help("\(mountedCount) directory mount(s) active")
                    }
                    if openVSCodeCount > 0 {
                        HStack(spacing: 1.5) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 8, weight: .bold))
                            if openVSCodeCount > 1 {
                                Text("\(openVSCodeCount)")
                                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                            }
                        }
                        .foregroundStyle(AppTheme.disk)
                        .help("\(openVSCodeCount) VS Code workspace window(s) currently open")
                    }
                }

                HStack(spacing: 5) {
                    RouteBadge(route: snapshot.host.routeKind, compact: true)
                    Text(snapshot.host.shortEndpoint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                if snapshot.state == .checking {
                    ProgressView()
                        .controlSize(.mini)
                } else if snapshot.state == .online {
                    Text(DisplayFormat.latency(snapshot.latencyMilliseconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if snapshot.state == .offline {
                    Text("Offline")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.statusColor(.offline))
                }

                if let metrics = snapshot.metrics {
                    HStack(spacing: 5) {
                        if !metrics.gpus.isEmpty {
                            let maxGPU = Int(metrics.gpus.compactMap(\.utilization).max() ?? 0)
                            Text("GPU \(maxGPU)%")
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(AppTheme.cpu)
                        } else {
                            Text("CPU \(Int(metrics.cpuUsage))%")
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AppTheme.accent.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? AppTheme.accent.opacity(0.22) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
