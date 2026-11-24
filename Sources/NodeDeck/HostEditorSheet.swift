import AppKit
import NodeDeckCore
import SwiftUI

struct HostEditorSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SSHHostDraft
    @State private var showAdvanced: Bool
    @State private var showPreview = false
    @State private var validationError: String?

    let existingHost: SSHHost?

    init(initialDraft: SSHHostDraft, existingHost: SSHHost? = nil) {
        _draft = State(initialValue: initialDraft)
        self.existingHost = existingHost
        let hasAdvanced = !initialDraft.proxyJump.isEmpty ||
            !initialDraft.extraOptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            initialDraft.compression ||
            (!initialDraft.serverAliveInterval.isEmpty && initialDraft.serverAliveInterval != "30")
        _showAdvanced = State(initialValue: hasAdvanced)
    }

    private var previewText: String? {
        try? SSHConfigEditor.renderBlock(for: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.16))
                    Image(systemName: draft.isEditing ? "slider.horizontal.3" : "plus.rectangle.on.folder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.isEditing ? "Edit Device" : "Add Device")
                        .font(.headline)
                    Text("Writes directly to ~/.ssh/config while preserving other entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        fieldBlock(title: "Alias (Required)") {
                            TextField("e.g. gpu-node", text: $draft.alias)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }

                        fieldBlock(title: "Alternate Aliases (Optional)") {
                            TextField("space-separated aliases", text: $draft.alternateAliases)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                    }

                    fieldBlock(title: "HostName / IP Address (Required)") {
                        TextField("e.g. 192.168.1.10 or server.example.com", text: $draft.hostName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                    }

                    HStack(spacing: 10) {
                        fieldBlock(title: "User") {
                            TextField("ubuntu", text: $draft.user)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }

                        fieldBlock(title: "Port") {
                            TextField("22", text: $draft.port)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                        .frame(width: 110)
                    }

                    fieldBlock(title: "Identity File (Optional)") {
                        HStack(spacing: 8) {
                            TextField("~/.ssh/id_ed25519", text: $draft.identityFile)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))

                            Button("Choose…") {
                                chooseIdentityFile()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    fieldBlock(title: "Note / Comment (Optional)") {
                        TextField("e.g. Lab GPU Workstation", text: $draft.comment)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }

                    DisclosureGroup("Advanced SSH Options", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                fieldBlock(title: "ProxyJump") {
                                    TextField("bastion-host", text: $draft.proxyJump)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                }

                                fieldBlock(title: "ServerAliveInterval (s)") {
                                    TextField("30", text: $draft.serverAliveInterval)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                }
                                .frame(width: 140)
                            }

                            Toggle("Enable SSH Compression", isOn: $draft.compression)
                                .font(.caption)

                            fieldBlock(title: "Extra Directives (one per line)") {
                                TextEditor(text: $draft.extraOptions)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(minHeight: 74, maxHeight: 110)
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
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption.weight(.semibold))

                    if let preview = previewText {
                        DisclosureGroup("Preview ~/.ssh/config Block", isExpanded: $showPreview) {
                            Text(preview)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(AppTheme.subtleBorder, lineWidth: 1)
                                )
                                .padding(.top, 4)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(.vertical, 2)
            }

            if let validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }

            Divider()

            HStack(spacing: 10) {
                if let existingHost {
                    Button(role: .destructive) {
                        dismiss()
                        store.requestDeleteHost(existingHost)
                    } label: {
                        Label("Delete Device…", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(draft.isEditing ? "Save Changes" : "Add Device") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
    }

    @ViewBuilder
    private func fieldBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if url.path.hasPrefix(home + "/") {
                draft.identityFile = "~" + url.path.dropFirst(home.count)
            } else {
                draft.identityFile = url.path
            }
        }
    }

    private func save() {
        validationError = nil
        if let err = store.saveHostDraft(draft) {
            validationError = err
        } else {
            dismiss()
        }
    }
}
