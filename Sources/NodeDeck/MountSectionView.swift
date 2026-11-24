import AppKit
import NodeDeckCore
import SwiftUI

struct MountSectionView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    let snapshot: HostSnapshot

    private var items: [FolderMountItem] {
        store.mountItems(for: snapshot.host)
    }

    private var mountedCount: Int {
        items.filter(\.isMounted).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SectionTitle(
                    title: l10n.t("目录挂载", "Directory Mounts"),
                    detail: items.isEmpty
                        ? l10n.t("将远端目录直接挂载到本地访达", "Mount remote folders directly into Finder")
                        : l10n.t("\(mountedCount) / \(items.count) 已挂载", "\(mountedCount) of \(items.count) mounted")
                )

                Button {
                    store.presentAddMount(for: snapshot.host)
                } label: {
                    Label(l10n.t("添加挂载", "Add Mount"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .help("Configure a remote directory to mount locally")
            }

            if !store.isRcloneAvailable && items.allSatisfy({ $0.sourceKind == .managedSFTP }) {
                rcloneHintBanner
            }

            if items.isEmpty {
                emptyMountsCard
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MountItemRow(item: item)
                        if index < items.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
                .cardBackground()
            }
        }
        .sheet(isPresented: $store.isShowingAddMountSheet) {
            if let draft = store.editingMountConfig {
                MountEditorSheet(
                    initialConfig: draft,
                    host: snapshot.host,
                    metrics: snapshot.metrics,
                    isEditingExisting: store.mountConfigs.contains(where: { $0.id == draft.id })
                )
            }
        }
    }

    private var emptyMountsCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.11))
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("No folders mounted for \(snapshot.host.alias)")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Mount a project or server folder over SSH/LAN into macOS Finder without FUSE or sudo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Mount Folder…") {
                store.presentAddMount(for: snapshot.host)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)
        }
        .padding(14)
        .cardBackground()
    }

    private var rcloneHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.warning)
            Text("Install rclone (`brew install rclone`) to mount SFTP directories natively via macOS NFS.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy Install Command") {
                TerminalLauncher.copyText("brew install rclone")
                store.showFeedback(.info, "Copied: brew install rclone")
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
        }
        .padding(10)
        .cardBackground()
    }
}

private struct MountItemRow: View {
    @EnvironmentObject private var store: HostMonitor
    let item: FolderMountItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.mountColor(item.state).opacity(0.13))
                    Image(systemName: item.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(AppTheme.mountColor(item.state))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)

                        MountStatePill(state: item.state)

                        if let fsType = item.fileSystemType {
                            Text(fsType)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                                )
                        }

                        if let config = item.config, config.autoMount {
                            Label("Auto", systemImage: "bolt.fill")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }

                    HStack(spacing: 5) {
                        Text(item.remoteDescription)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(item.displayLocalPath)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if item.isMounted {
                        Button {
                            store.openMountInFinder(item)
                        } label: {
                            Label("Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open \(item.displayLocalPath) in Finder")

                        Button {
                            store.openMountInTerminal(item)
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open local Terminal in \(item.displayLocalPath)")
                    }

                    if item.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 68)
                    } else if item.isMounted {
                        Button("Unmount") {
                            store.unmountItem(item)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if let config = item.config {
                        Button("Mount") {
                            store.mountFolder(config)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .controlSize(.small)
                    }

                    Menu {
                        Button("Copy Local Path") {
                            TerminalLauncher.copyText(item.localPath)
                            store.showFeedback(.info, "Copied \(item.displayLocalPath)")
                        }
                        Button("Copy Remote Source") {
                            TerminalLauncher.copyText(item.config?.remotePath ?? item.remoteDescription)
                            store.showFeedback(.info, "Copied remote path")
                        }

                        if let config = item.config {
                            Divider()
                            if item.isMounted && item.sourceKind == .managedSFTP && config.strategy == .smbFirst {
                                Button("Switch to LAN SMB3") {
                                    store.switchMountToSMB(item)
                                }
                            }
                            Button(config.autoMount ? "Disable Auto-Mount" : "Enable Auto-Mount") {
                                store.toggleAutoMount(for: config)
                            }
                            Button("Edit Mount…") {
                                store.presentEditMount(config)
                            }
                            Divider()
                            Button("Remove Mount", role: .destructive) {
                                store.removeMountConfig(config)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if let errorMessage = item.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.critical)
                    .lineLimit(2)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MountStatePill: View {
    let state: MountRuntimeState

    private var title: String {
        switch state {
        case .mounted: return "Mounted"
        case .mounting: return "Mounting…"
        case .unmounting: return "Unmounting…"
        case .unmounted: return "Unmounted"
        case .error: return "Error"
        }
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(AppTheme.mountColor(state))
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.mountColor(state).opacity(0.12))
            )
    }
}

private struct MountEditorSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @Environment(\.dismiss) private var dismiss

    let host: SSHHost
    let metrics: HostMetrics?
    let isEditingExisting: Bool

    @State private var id: UUID
    @State private var remotePath: String
    @State private var localPath: String
    @State private var label: String
    @State private var autoMount: Bool
    @State private var strategy: MountStrategy
    @State private var smbEndpointsText: String
    @State private var smbShare: String
    @State private var smbUser: String
    @State private var rcloneFallbackAlias: String
    @State private var hasCustomizedLocalPath: Bool
    @State private var hasCustomizedSMBShare: Bool

    init(
        initialConfig: FolderMountConfig,
        host: SSHHost,
        metrics: HostMetrics?,
        isEditingExisting: Bool
    ) {
        self.host = host
        self.metrics = metrics
        self.isEditingExisting = isEditingExisting
        _id = State(initialValue: initialConfig.id)
        _remotePath = State(initialValue: initialConfig.remotePath)
        _localPath = State(initialValue: initialConfig.localPath)
        _label = State(initialValue: initialConfig.label)
        _autoMount = State(initialValue: initialConfig.autoMount)
        _strategy = State(initialValue: initialConfig.strategy)
        let defaultEndpoints: [String] = {
            if !initialConfig.smbEndpoints.isEmpty {
                return initialConfig.smbEndpoints
            }
            if host.routeKind == .directLAN, !host.hostName.lowercased().hasPrefix("fe80:") {
                return [host.hostName]
            }
            return []
        }()
        _smbEndpointsText = State(initialValue: defaultEndpoints.joined(separator: ", "))
        let effectiveUser = initialConfig.smbUser ?? host.user
        let initialShare = initialConfig.smbShare
            ?? FolderMountConfig.inferredSMBShare(from: initialConfig.remotePath, user: effectiveUser)
            ?? ""
        _smbShare = State(initialValue: initialShare)
        _smbUser = State(initialValue: effectiveUser)
        _rcloneFallbackAlias = State(initialValue: initialConfig.rcloneFallbackAlias ?? "")
        _hasCustomizedLocalPath = State(initialValue: isEditingExisting)
        _hasCustomizedSMBShare = State(initialValue: initialConfig.smbShare != nil)
    }

    private var remoteSuggestions: [String] {
        var list: [String] = []
        let home = metrics?.homeDirectory.isEmpty == false
            ? metrics!.homeDirectory
            : "/home/\(host.user)"
        if let candidates = metrics?.candidateDirectories {
            for item in candidates where !list.contains(item) {
                list.append(item)
            }
        }
        for fallback in ["\(home)/project", "\(home)/PycharmProjects", "\(home)/server", home] where !list.contains(fallback) {
            list.append(fallback)
        }
        return Array(list.prefix(6))
    }

    private var parsedSMBEndpoints: [String] {
        smbEndpointsText
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isValid: Bool {
        let baseOK = !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if strategy == .smbOnly {
            return baseOK && !parsedSMBEndpoints.isEmpty
        }
        return baseOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEditingExisting ? "Edit Directory Mount" : "Mount Remote Directory")
                        .font(.headline)
                    Text("Host: \(host.alias) (\(host.loginTarget))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mount Protocol & Fallback")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $strategy) {
                    ForEach(MountStrategy.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Remote Directory Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("/home/\(host.user)/project", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: remotePath) { _, newValue in
                        if !hasCustomizedLocalPath {
                            let suggested = MountManager.suggestedLocalPath(
                                hostAlias: host.alias,
                                remotePath: newValue
                            )
                            localPath = suggested
                            label = (suggested as NSString).lastPathComponent
                        }
                        if !hasCustomizedSMBShare {
                            smbShare = FolderMountConfig.inferredSMBShare(from: newValue, user: smbUser) ?? ""
                        }
                    }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(remoteSuggestions, id: \.self) { suggestion in
                            Button {
                                remotePath = suggestion
                            } label: {
                                Text(shortRemoteLabel(suggestion))
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(remotePath == suggestion ? AppTheme.accent.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(remotePath == suggestion ? AppTheme.accent.opacity(0.4) : AppTheme.subtleBorder, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if strategy != .sftpOnly {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LAN SMB Host(s) (priority order)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("192.168.1.10, 10.0.0.10", text: $smbEndpointsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("SMB Share")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("project", text: $smbShare)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 155)
                            .onChange(of: smbShare) { _, _ in
                                hasCustomizedSMBShare = true
                            }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Local Mount Point on Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("/Users/\(NSUserName())/\(host.alias.uppercased())-project", text: $localPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: localPath) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                label = ((trimmed as NSString).expandingTildeInPath as NSString).lastPathComponent
                            }
                        }

                    Button("Choose Parent…") {
                        chooseParentDirectory()
                    }
                    .buttonStyle(.bordered)
                }
                Text(
                    strategy == .smbFirst
                        ? "Tries native macOS SMB3 over LAN/EasyTier first; automatically falls back to rclone SFTP when off-LAN."
                        : "NodeDeck creates an empty folder at this path and mounts the remote directory into Finder."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume Label")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Volume name", text: $label)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Auto-mount when host is reachable", isOn: $autoMount)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.top, 18)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Only") {
                    save(mountImmediately: false)
                }
                .disabled(!isValid)

                Button(isEditingExisting ? "Save & Remount" : "Mount Now") {
                    save(mountImmediately: true)
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

    private func shortRemoteLabel(_ full: String) -> String {
        let home = metrics?.homeDirectory ?? "/home/\(host.user)"
        if full == home { return "~" }
        if full.hasPrefix(home + "/") {
            return "~/" + full.dropFirst(home.count + 1)
        }
        return full
    }

    private func chooseParentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Parent Folder"
        if panel.runModal() == .OK, let parent = panel.url {
            hasCustomizedLocalPath = true
            let folderName = label.isEmpty ? "\(host.alias.uppercased())-mount" : label
            localPath = parent.appendingPathComponent(folderName, isDirectory: true).path
        }
    }

    private func save(mountImmediately: Bool) {
        let trimmedRemote = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocal = (localPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let finalLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (trimmedLocal as NSString).lastPathComponent
            : label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = smbShare.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = smbUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFallback = rcloneFallbackAlias.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = FolderMountConfig(
            id: id,
            hostAlias: host.alias,
            label: finalLabel,
            remotePath: trimmedRemote,
            localPath: trimmedLocal,
            autoMount: autoMount,
            strategy: strategy,
            smbEndpoints: strategy == .sftpOnly ? [] : parsedSMBEndpoints,
            smbShare: trimmedShare.isEmpty ? nil : trimmedShare,
            smbUser: trimmedUser.isEmpty ? nil : trimmedUser,
            rcloneFallbackAlias: trimmedFallback.isEmpty ? nil : trimmedFallback
        )
        store.saveMountConfig(config, mountImmediately: mountImmediately)
        dismiss()
    }
}
