import SSHDeckCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: HostMonitor
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
                Text("SSH Deck")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    StatusDot(state: store.onlineCount > 0 ? .online : .idle, size: 6)
                    Text("\(store.onlineCount)/\(store.hosts.count) online · \(store.mountedHostCount) mounted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

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
                .help("Refresh all hosts (⌘R)")
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
            TextField("Search hosts, mounts, or IPs (⌘F)", text: $searchText)
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
                    Text("\(filter.rawValue) \(count)")
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
        Button("Open in Terminal") {
            store.openSSHInTerminal(for: host)
        }

        let wsItems = store.vscodeItems(for: host)
        if !wsItems.isEmpty {
            Menu("VS Code Workspaces") {
                ForEach(wsItems) { item in
                    let suffix = item.isOpenInWindow ? " (Open)" : ""
                    Button("\(item.name)\(suffix) — \(item.remotePath)") {
                        store.openVSCodeWorkspace(item, for: host)
                    }
                }
                Divider()
                Button("Open Remote Path…") {
                    store.selectedAlias = host.alias
                    store.presentOpenVSCodePath(for: host)
                }
            }
        } else {
            Button("Open in VS Code…") {
                store.selectedAlias = host.alias
                store.presentOpenVSCodePath(for: host)
            }
        }

        if let moonlight = store.moonlightTarget(for: host) {
            Button("Stream Moonlight Desktop") {
                store.launchMoonlight(target: moonlight)
            }
        }

        let mounted = store.mountItems(for: host).filter(\.isMounted)
        if let firstMounted = mounted.first {
            Button("Open \(firstMounted.label) in Finder") {
                store.openMountInFinder(firstMounted)
            }
        }
        Button("Mount Directory…") {
            store.selectedAlias = host.alias
            store.presentAddMount(for: host)
        }

        Divider()

        Button(store.isPinned(host.alias) ? "Unpin Host" : "Pin to Top") {
            store.togglePin(host.alias)
        }

        Button("Refresh Host") {
            store.refresh(alias: host.alias)
        }

        Divider()

        Button("Copy SSH Command") {
            TerminalLauncher.copyCommand(for: host)
            store.showFeedback(.info, "Copied \(host.terminalCommand)")
        }

        Button("Copy Host Endpoint") {
            TerminalLauncher.copyText(host.endpoint)
            store.showFeedback(.info, "Copied \(host.endpoint)")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Auto refresh", selection: $store.refreshInterval) {
                    Text("Manual").tag(0.0)
                    Text("Every 15 seconds").tag(15.0)
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every 1 minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label(refreshLabel, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Menu {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                Divider()
                Button("Start All GOST Tunnels") {
                    store.startAllTunnels()
                }
                Button("Restart Active Tunnels") {
                    store.restartAllActiveTunnels()
                }
                Button("Reload SSH Config & Mounts") {
                    store.reloadConfiguration()
                }
                Divider()
                Button("Quit SSH Deck", role: .destructive) {
                    store.shutdownAndQuit()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tunnels, Launch at Login, and App Settings")

            if let lastRefresh = store.lastRefresh {
                Text(DisplayFormat.time(lastRefresh))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var refreshLabel: String {
        switch Int(store.refreshInterval) {
        case 0: return "Manual"
        case 15: return "15s refresh"
        case 30: return "30s refresh"
        case 60: return "1m refresh"
        case 120: return "2m refresh"
        case 300: return "5m refresh"
        default: return "\(Int(store.refreshInterval))s refresh"
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
