import AppKit
import NodeDeckCore
import SwiftUI

struct PortForwardSectionView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    let snapshot: HostSnapshot

    private var items: [PortForwardRuntimeItem] {
        store.portForwardItems(for: snapshot.host)
    }

    private var runningCount: Int {
        items.filter(\.isRunning).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SectionTitle(
                    title: l10n.t("SSH 端口转发", "SSH Port Forwarding"),
                    detail: items.isEmpty
                        ? l10n.t("将远端 Jupyter、TensorBoard、WebUI 或 API 映射到本机", "Forward remote ports (Jupyter, TensorBoard, WebUI, APIs) to localhost")
                        : l10n.t("\(runningCount) / \(items.count) 条运行中", "\(runningCount) of \(items.count) active")
                )

                Button {
                    store.presentAddPortForward(for: snapshot.host)
                } label: {
                    Label(l10n.t("添加转发", "Add Forward"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .help("Add an SSH port forward for \(snapshot.host.alias)")
            }

            if items.isEmpty {
                emptyCard
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PortForwardRow(item: item)
                        if index < items.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
                .cardBackground()
            }
        }
        .sheet(isPresented: $store.isShowingPortForwardSheet) {
            if let draft = store.editingPortForwardConfig {
                PortForwardEditorSheet(
                    initialConfig: draft,
                    isEditingExisting: store.portForwardConfigs.contains(where: { $0.id == draft.id })
                )
                .environmentObject(store)
            }
        }
    }

    private var emptyCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("No SSH port forwards configured")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Map remote web apps or services to 127.0.0.1 over SSH (-L / -R / -D).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Add Forward…") {
                store.presentAddPortForward(for: snapshot.host)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(13)
        .cardBackground()
    }
}

private struct PortForwardRow: View {
    @EnvironmentObject private var store: HostMonitor
    let item: PortForwardRuntimeItem

    private var stateColor: Color {
        switch item.state {
        case .running: return AppTheme.statusColor(.online)
        case .starting: return AppTheme.warning
        case .error: return AppTheme.critical
        case .stopped: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(stateColor.opacity(0.13))
                    Image(systemName: item.config.direction.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(stateColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.config.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)

                        Text(item.config.direction.shortBadge)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                            )

                        PortForwardStatePill(state: item.state)

                        if let pid = item.pid {
                            Text("PID \(pid)")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if item.config.autoStart {
                            Label("Auto", systemImage: "bolt.fill")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }

                    Text(item.config.summaryText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if item.isRunning, let urlString = item.config.openableURLString, let url = URL(string: urlString) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open \(urlString) in Browser")
                    }

                    if item.isRunning {
                        Button("Stop") {
                            store.stopPortForward(item.config)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Start") {
                            store.startPortForward(item.config)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .controlSize(.small)
                        .disabled(item.state == .starting)
                    }

                    Menu {
                        if let urlString = item.config.openableURLString {
                            Button("Copy \(urlString)") {
                                TerminalLauncher.copyText(urlString)
                                store.showFeedback(.info, "Copied \(urlString)")
                            }
                        }
                        Button(item.config.autoStart ? "Disable Auto-Start" : "Enable Auto-Start") {
                            store.togglePortForwardAutoStart(item.config)
                        }
                        Button("Edit Forward…") {
                            store.presentEditPortForward(item.config)
                        }
                        Divider()
                        Button("Remove Forward", role: .destructive) {
                            store.removePortForwardConfig(item.config)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if let err = item.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(AppTheme.critical)
                    .lineLimit(2)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PortForwardStatePill: View {
    let state: PortForwardState

    private var label: String {
        switch state {
        case .running: return "Active"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }

    private var color: Color {
        switch state {
        case .running: return AppTheme.statusColor(.online)
        case .starting: return AppTheme.warning
        case .stopped: return .secondary
        case .error: return AppTheme.critical
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}

private struct PortForwardEditorSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @Environment(\.dismiss) private var dismiss

    let initialConfig: SSHPortForwardConfig
    let isEditingExisting: Bool

    @State private var label: String
    @State private var direction: SSHPortForwardDirection
    @State private var localHost: String
    @State private var localPortText: String
    @State private var remoteHost: String
    @State private var remotePortText: String
    @State private var urlScheme: String
    @State private var autoStart: Bool
    @State private var startNow = true
    @State private var validationError: String?

    init(initialConfig: SSHPortForwardConfig, isEditingExisting: Bool) {
        self.initialConfig = initialConfig
        self.isEditingExisting = isEditingExisting
        _label = State(initialValue: initialConfig.label)
        _direction = State(initialValue: initialConfig.direction)
        _localHost = State(initialValue: initialConfig.localHost)
        _localPortText = State(initialValue: String(initialConfig.localPort))
        _remoteHost = State(initialValue: initialConfig.remoteHost)
        _remotePortText = State(initialValue: String(initialConfig.remotePort))
        _urlScheme = State(initialValue: initialConfig.urlScheme)
        _autoStart = State(initialValue: initialConfig.autoStart)
    }

    private let presets: [(name: String, port: Int, dir: SSHPortForwardDirection, scheme: String)] = [
        ("Jupyter", 8888, .local, "http"),
        ("TensorBoard", 6006, .local, "http"),
        ("WebUI", 7860, .local, "http"),
        ("API / vLLM", 8000, .local, "http"),
        ("SOCKS5", 1080, .dynamic, "")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditingExisting ? "Edit SSH Port Forward" : "Add SSH Port Forward")
                    .font(.headline)
                Text("Host: \(initialConfig.hostAlias)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isEditingExisting {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.name) { preset in
                            Button("\(preset.name) :\(preset.port)") {
                                label = preset.name
                                direction = preset.dir
                                localPortText = String(preset.port)
                                remotePortText = String(preset.port)
                                urlScheme = preset.scheme
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Label")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("e.g. JupyterLab", text: $label)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Direction")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("Direction", selection: $direction) {
                            ForEach(SSHPortForwardDirection.allCases) { dir in
                                Text(dir.title).tag(dir)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(width: 150)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local Bind Host")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("127.0.0.1", text: $localHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local Port")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("8888", text: $localPortText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                    }
                    .frame(width: 110)
                }

                if direction != .dynamic {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remote Host")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("127.0.0.1", text: $remoteHost)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remote Port")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("8888", text: $remotePortText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                        .frame(width: 110)
                    }
                }

                if direction == .local {
                    HStack(spacing: 10) {
                        Text("Browser URL Scheme")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $urlScheme) {
                            Text("http://").tag("http")
                            Text("https://").tag("https")
                            Text("None").tag("")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Auto-start when NodeDeck launches", isOn: $autoStart)
                        .font(.caption)
                    Toggle("Start immediately", isOn: $startNow)
                        .font(.caption)
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditingExisting ? "Save" : "Add Forward") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private func save() {
        guard let lPort = Int(localPortText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(lPort) else {
            validationError = "Local port must be between 1 and 65535."
            return
        }
        let rPort: Int
        if direction == .dynamic {
            rPort = 0
        } else {
            guard let parsed = Int(remotePortText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(parsed) else {
                validationError = "Remote port must be between 1 and 65535."
                return
            }
            rPort = parsed
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = SSHPortForwardConfig(
            id: initialConfig.id,
            hostAlias: initialConfig.hostAlias,
            label: trimmedLabel.isEmpty ? "Port \(lPort)" : trimmedLabel,
            direction: direction,
            localHost: localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : localHost.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: lPort,
            remoteHost: remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : remoteHost.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePort: rPort,
            autoStart: autoStart,
            urlScheme: direction == .local ? urlScheme : ""
        )
        store.savePortForwardConfig(cfg, startImmediately: startNow)
        dismiss()
    }
}
