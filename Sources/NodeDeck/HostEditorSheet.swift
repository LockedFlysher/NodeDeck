import AppKit
import NodeDeckCore
import SwiftUI

struct HostEditorSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
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
                    Text(draft.isEditing ? l10n.t("编辑设备", "Edit Device") : l10n.t("添加设备", "Add Device"))
                        .font(.headline)
                    Text(l10n.t(
                        "直接写入本地 ~/.ssh/config，完整保留其他主机与自定义指令。",
                        "Writes directly to ~/.ssh/config while preserving other entries."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        fieldBlock(title: l10n.t("设备别名（必填）", "Alias (Required)")) {
                            TextField(l10n.t("例如 gpu-node", "e.g. gpu-node"), text: $draft.alias)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }

                        fieldBlock(title: l10n.t("备用别名（可选）", "Alternate Aliases (Optional)")) {
                            TextField(l10n.t("空格分隔多个别名", "space-separated aliases"), text: $draft.alternateAliases)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                    }

                    fieldBlock(title: l10n.t("主机地址 / IP（必填）", "HostName / IP Address (Required)")) {
                        TextField(l10n.t("例如 192.168.1.10 或 server.example.com", "e.g. 192.168.1.10 or server.example.com"), text: $draft.hostName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                    }

                    HStack(spacing: 10) {
                        fieldBlock(title: l10n.t("用户名", "User")) {
                            TextField("ubuntu", text: $draft.user)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }

                        fieldBlock(title: l10n.t("端口", "Port")) {
                            TextField("22", text: $draft.port)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                        .frame(width: 110)
                    }

                    fieldBlock(title: l10n.t("SSH 私钥文件（可选）", "Identity File (Optional)")) {
                        HStack(spacing: 8) {
                            TextField("~/.ssh/id_ed25519", text: $draft.identityFile)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))

                            Button(l10n.t("选择…", "Choose…")) {
                                chooseIdentityFile()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    fieldBlock(title: l10n.t("备注 / 说明（可选）", "Note / Comment (Optional)")) {
                        TextField(l10n.t("例如 实验室 GPU 工作站", "e.g. Lab GPU Workstation"), text: $draft.comment)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }

                    DisclosureGroup(l10n.t("高级 SSH 选项", "Advanced SSH Options"), isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                fieldBlock(title: l10n.t("跳板机 (ProxyJump)", "ProxyJump")) {
                                    TextField("bastion-host", text: $draft.proxyJump)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                }

                                fieldBlock(title: l10n.t("心跳间隔 (秒)", "ServerAliveInterval (s)")) {
                                    TextField("30", text: $draft.serverAliveInterval)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                }
                                .frame(width: 140)
                            }

                            Toggle(l10n.t("启用 SSH 压缩传输", "Enable SSH Compression"), isOn: $draft.compression)
                                .font(.caption)

                            fieldBlock(title: l10n.t("附加配置项（每行一条）", "Extra Directives (one per line)")) {
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
                        DisclosureGroup(l10n.t("预览 ~/.ssh/config 配置块", "Preview ~/.ssh/config Block"), isExpanded: $showPreview) {
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
                        Label(l10n.t("删除设备…", "Delete Device…"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(l10n.t("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(draft.isEditing ? l10n.t("保存修改", "Save Changes") : l10n.t("添加设备", "Add Device")) {
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
        panel.title = l10n.t("选择 SSH 私钥文件", "Select SSH Private Key")
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
