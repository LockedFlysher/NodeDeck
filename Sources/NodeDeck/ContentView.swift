import NodeDeckCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HSplitView {
            SidebarView(searchText: $searchText, searchFocused: $searchFocused)
                .frame(minWidth: 236, idealWidth: 286, maxWidth: 360)

            DetailPane(searchText: searchText)
                .frame(minWidth: 460)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            Group {
                Button("") {
                    searchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

                Button("") {
                    store.presentAddHost()
                }
                .keyboardShortcut("n", modifiers: .command)
                .hidden()
            }
        )
        .sheet(isPresented: $store.isShowingHostEditorSheet) {
            if let draft = store.editingHostDraft {
                HostEditorSheet(
                    initialDraft: draft,
                    existingHost: store.editingHostTarget
                )
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $store.isShowingArchitectureGuide) {
            ArchitectureGuideSheet()
        }
        .sheet(isPresented: $store.isShowingAccountSheet) {
            AccountSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isShowingLocalHostSheet) {
            LocalHostSheet()
                .environmentObject(store)
        }
        .alert(
            l10n.t("删除设备 \"\(store.hostPendingDeletion?.alias ?? "")\"？", "Delete Device \"\(store.hostPendingDeletion?.alias ?? "")\"?"),
            isPresented: Binding(
                get: { store.hostPendingDeletion != nil },
                set: { if !$0 { store.hostPendingDeletion = nil } }
            ),
            presenting: store.hostPendingDeletion
        ) { host in
            Button(l10n.t("删除设备", "Delete Device"), role: .destructive) {
                store.confirmDeleteHost(host, removeAssociatedData: true)
            }
            Button(l10n.t("取消", "Cancel"), role: .cancel) {
                store.hostPendingDeletion = nil
            }
        } message: { host in
            let mountCount = store.mountItems(for: host).filter { $0.config != nil }.count
            let forwardCount = store.portForwardItems(for: host).count
            let extra = (mountCount > 0 || forwardCount > 0)
                ? l10n.t(
                    " 同时会移除该设备关联的 \(mountCount) 个挂载与 \(forwardCount) 条端口转发配置。",
                    " This will also remove \(mountCount) saved mount(s) and \(forwardCount) port forward(s) for this device."
                )
                : ""
            Text(l10n.t(
                "此操作将从 ~/.ssh/config 中移除 \"Host \(host.allAliases.joined(separator: " "))\" 配置块。\(extra)",
                "This removes the \"Host \(host.allAliases.joined(separator: " "))\" block from ~/.ssh/config.\(extra)"
            ))
        }
        .onAppear {
            store.start()
        }
    }
}

private struct DetailPane: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    let searchText: String

    private var filteredHosts: [SSHHost] {
        store.sortedHosts(matching: searchText)
    }

    private var visibleSnapshot: HostSnapshot? {
        if let selected = store.selectedSnapshot,
           filteredHosts.contains(where: { $0.alias == selected.host.alias }) {
            return selected
        }
        guard let first = filteredHosts.first else { return nil }
        return store.snapshots[first.alias]
    }

    var body: some View {
        Group {
            if let snapshot = visibleSnapshot {
                HostDetailView(snapshot: snapshot)
            } else if store.isScanning {
                EmptyStateView(
                    symbol: "terminal",
                    title: l10n.t("正在读取 SSH 配置", "Reading SSH config"),
                    message: nil,
                    showsProgress: true
                )
            } else if let scanError = store.scanError {
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: l10n.t("尚未配置设备", "No Devices Configured"),
                    message: scanError,
                    showsProgress: false,
                    actionTitle: l10n.t("添加设备", "Add Device"),
                    action: { store.presentAddHost() }
                )
            } else {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: l10n.t("无匹配主机", "No matching hosts"),
                    message: store.sidebarFilter != .all
                        ? l10n.t("没有符合「\(store.sidebarFilter.localizedTitle)」筛选条件的主机。", "No hosts match the \"\(store.sidebarFilter.localizedTitle)\" filter.")
                        : nil,
                    showsProgress: false,
                    actionTitle: store.sidebarFilter != .all ? l10n.t("显示全部主机", "Show All Hosts") : nil,
                    action: store.sidebarFilter != .all ? { store.sidebarFilter = .all } : nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String?
    let showsProgress: Bool
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title3.weight(.semibold))

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
            }
        }
        .padding(40)
    }
}
