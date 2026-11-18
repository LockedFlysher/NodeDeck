import SSHDeckCore
import SwiftUI

struct VSCodeSectionView: View {
    @EnvironmentObject private var store: HostMonitor
    let snapshot: HostSnapshot

    private var items: [VSCodeWorkspaceItem] {
        store.vscodeItems(for: snapshot.host)
    }

    private var openCount: Int {
        items.filter(\.isOpenInWindow).count
    }

    private var detailText: String {
        if items.isEmpty {
            return "Connect via Remote-SSH or open a remote project directory"
        }
        if openCount > 0 {
            return "\(openCount) active window\(openCount == 1 ? "" : "s") · \(items.count) workspace\(items.count == 1 ? "" : "s") on \(snapshot.host.alias)"
        }
        return "\(items.count) recent workspace\(items.count == 1 ? "" : "s") in VS Code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                SectionTitle(
                    title: "VS Code Workspaces",
                    detail: detailText
                )

                HStack(spacing: 6) {
                    Button {
                        store.openVSCodeEmptyWindow(for: snapshot.host)
                    } label: {
                        Label("New Window", systemImage: "macwindow.badge.plus")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!store.isVSCodeInstalled)
                    .help("Connect VS Code Remote-SSH to \(snapshot.host.alias) in a new window")

                    Button {
                        store.presentOpenVSCodePath(for: snapshot.host)
                    } label: {
                        Label("Open Path…", systemImage: "folder.badge.plus")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!store.isVSCodeInstalled)
                    .help("Open a remote directory or .code-workspace on \(snapshot.host.alias)")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if !store.isVSCodeInstalled {
                missingVSCodeBanner
            } else if items.isEmpty {
                emptyWorkspacesCard
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        VSCodeWorkspaceRow(item: item, host: snapshot.host)
                        if index < items.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
                .cardBackground()
            }
        }
        .sheet(isPresented: $store.isShowingOpenVSCodePathSheet) {
            if let targetHost = store.openVSCodePathTargetHost {
                OpenVSCodePathSheet(
                    host: targetHost,
                    metrics: store.snapshots[targetHost.alias]?.metrics
                )
            }
        }
    }

    private var emptyWorkspacesCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.disk.opacity(0.13))
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.disk)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("No VS Code workspaces recorded for \(snapshot.host.alias) yet")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Connect via Remote-SSH or choose a remote project folder to open directly in VS Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let defaultDir = snapshot.metrics?.candidateDirectories.first
                ?? snapshot.metrics?.homeDirectory
                ?? "/home/\(snapshot.host.user)"

            Button {
                store.openVSCodeRemotePath(defaultDir, for: snapshot.host)
            } label: {
                Label("Open \(URL(fileURLWithPath: defaultDir).lastPathComponent)", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.disk)
            .controlSize(.small)
        }
        .padding(13)
        .cardBackground()
    }

    private var missingVSCodeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
            Text("Visual Studio Code.app was not found in /Applications.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(11)
        .cardBackground()
    }
}

private struct VSCodeWorkspaceRow: View {
    @EnvironmentObject private var store: HostMonitor
    let item: VSCodeWorkspaceItem
    let host: SSHHost

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt
    }()

    private var badgeColor: Color {
        item.isOpenInWindow ? AppTheme.statusColor(.online) : AppTheme.disk
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(badgeColor.opacity(0.13))
                Image(systemName: item.kind == .workspaceFile ? "square.grid.2x2.fill" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(badgeColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if item.isLastActive {
                        statusPill(label: "Focused", color: AppTheme.statusColor(.online))
                    } else if item.isOpenInWindow {
                        statusPill(label: "Open in VS Code", color: AppTheme.statusColor(.online))
                    } else {
                        statusPill(label: "Recent", color: .secondary)
                    }

                    if let lastOpenedAt = item.lastOpenedAt, !item.isOpenInWindow {
                        Text(Self.relativeFormatter.localizedString(for: lastOpenedAt, relativeTo: Date()))
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.remotePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if item.effectiveAuthority.caseInsensitiveCompare(host.alias) != .orderedSame {
                        Text("· via \(item.effectiveAuthority)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .help(item.vscodeRemoteURI)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if item.isOpenInWindow {
                    Button {
                        store.openVSCodeWorkspace(item, for: host)
                    } label: {
                        Label("Switch", systemImage: "macwindow")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .controlSize(.small)
                    .help("Focus \(item.remotePath) in VS Code")
                } else {
                    Button {
                        store.openVSCodeWorkspace(item, for: host)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Connect and open \(item.remotePath) in VS Code")
                }

                Menu {
                    Button("Open in New VS Code Window") {
                        store.openVSCodeWorkspace(item, for: host, forceNewWindow: true)
                    }
                    Button("Mount Folder in Finder…") {
                        let suggestedLocal = MountManager.suggestedLocalPath(
                            hostAlias: host.alias,
                            remotePath: item.remotePath
                        )
                        store.presentEditMount(
                            FolderMountConfig(
                                hostAlias: host.alias,
                                label: URL(fileURLWithPath: suggestedLocal).lastPathComponent,
                                remotePath: item.remotePath,
                                localPath: suggestedLocal,
                                autoMount: true
                            )
                        )
                    }
                    Divider()
                    Button("Copy Remote Path") {
                        TerminalLauncher.copyText(item.remotePath)
                        store.showFeedback(.info, "Copied \(item.remotePath)")
                    }
                    Button("Copy VS Code Remote URI") {
                        TerminalLauncher.copyText(item.vscodeRemoteURI)
                        store.showFeedback(.info, "Copied VS Code URI")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func statusPill(label: String, color: Color) -> some View {
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

private struct OpenVSCodePathSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @Environment(\.dismiss) private var dismiss

    let host: SSHHost
    let metrics: HostMetrics?

    @State private var remotePath: String
    @State private var openInNewWindow: Bool = true

    init(host: SSHHost, metrics: HostMetrics?) {
        self.host = host
        self.metrics = metrics
        let initial = metrics?.candidateDirectories.first
            ?? (metrics?.homeDirectory.isEmpty == false ? metrics!.homeDirectory : "/home/\(host.user)")
        _remotePath = State(initialValue: initial)
    }

    private var suggestions: [String] {
        var list: [String] = []
        if let home = metrics?.homeDirectory, !home.isEmpty {
            list.append(home)
        } else {
            list.append("/home/\(host.user)")
        }
        for dir in metrics?.candidateDirectories ?? [] where !list.contains(dir) {
            list.append(dir)
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Remote Workspace in VS Code")
                .font(.title3.weight(.semibold))

            Text("Target Host: \(host.alias) (\(host.loginTarget))")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Directory or .code-workspace Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("/home/\(host.user)/project", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected Directories on \(host.alias)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowChipStrip(items: suggestions) { dir in
                        remotePath = dir
                    }
                }
            }

            Toggle("Open in a new VS Code window", isOn: $openInNewWindow)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect & Open") {
                    store.openVSCodeRemotePath(remotePath, for: host, forceNewWindow: openInNewWindow)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct FlowChipStrip: View {
    let items: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { path in
                    Button {
                        onSelect(path)
                    } label: {
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(AppTheme.subtleBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
