import AppKit
import NodeDeckCore
import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    var onClosePopover: (() -> Void)? = nil

    private var moonlightTargets: [MoonlightTarget] {
        store.allMoonlightTargets
    }

    private var quickHosts: [SSHHost] {
        Array(store.sortedHosts(matching: "").prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()

            if !moonlightTargets.isEmpty {
                moonlightSection
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }

            hostsSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()
            footerSection
        }
        .frame(width: 356)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.start()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.accent)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("NodeDeck")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("\(store.onlineCount)/\(store.hosts.count) nodes · \(store.mountedHostCount) mounts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.refreshAll()
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.borderless)
            .help(l10n.t("刷新主机与挂载", "Refresh hosts and mounts"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var moonlightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.t("远程桌面", "REMOTE DESKTOPS"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(moonlightTargets) { target in
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AppTheme.accent.opacity(0.15))
                        Image(systemName: "play.display")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(target.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text(target.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(l10n.t("连接", "Connect")) {
                        onClosePopover?()
                        store.launchMoonlight(target: target)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.subtleBorder, lineWidth: 1)
                )
            }
        }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("QUICK HOSTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(quickHosts) { host in
                let snap = store.snapshots[host.alias]
                let mounted = store.mountItems(for: host).filter(\.isMounted)
                let vscodeList = store.vscodeItems(for: host)
                HStack(spacing: 8) {
                    StatusDot(state: snap?.state ?? .idle, size: 7)

                    Text(host.alias)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if let rtt = snap?.latencyMilliseconds, snap?.state == .online {
                        Text(DisplayFormat.latency(rtt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if let firstMount = mounted.first {
                        Button {
                            onClosePopover?()
                            store.openMountInFinder(firstMount)
                        } label: {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.mountColor(.mounted))
                        }
                        .buttonStyle(.borderless)
                        .help("Open \(firstMount.displayLocalPath) in Finder")
                    }

                    if let primaryWS = vscodeList.first {
                        Button {
                            onClosePopover?()
                            store.openVSCodeWorkspace(primaryWS, for: host)
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(primaryWS.isOpenInWindow ? AppTheme.statusColor(.online) : AppTheme.disk)
                        }
                        .buttonStyle(.borderless)
                        .help("VS Code: \(primaryWS.name) (\(primaryWS.remotePath))")
                    } else if store.isVSCodeInstalled {
                        Button {
                            onClosePopover?()
                            store.openVSCodeEmptyWindow(for: host)
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Connect VS Code Remote-SSH to \(host.alias)")
                    }

                    Button {
                        onClosePopover?()
                        store.openSSHInTerminal(for: host)
                    } label: {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("SSH to \(host.alias)")
                }
                .padding(.vertical, 2.5)
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Launch at Login", systemImage: "power.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(spacing: 8) {
                Button {
                    onClosePopover?()
                    WindowCoordinator.shared.showMainWindow()
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    onClosePopover?()
                    WindowCoordinator.shared.prepareForTermination()
                    store.shutdownAndQuit()
                } label: {
                    Label("Quit", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
