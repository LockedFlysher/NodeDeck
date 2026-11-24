import NodeDeckCore
import SwiftUI

struct HostProfileSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss

    let host: SSHHost

    @State private var profile: LinuxHostProfile
    @State private var basePortText: String
    @State private var isApplying = false
    @State private var errorMessage: String?

    init(host: SSHHost, initialProfile: LinuxHostProfile) {
        self.host = host
        _profile = State(initialValue: initialProfile)
        _basePortText = State(initialValue: String(initialProfile.basePort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.16))
                    Image(systemName: "server.rack")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("多用户主机隔离配置 — \(host.alias)", "Multi-User Host Isolation — \(host.alias)"))
                        .font(.headline)
                    Text(l10n.t(
                        "保存后将同步到远端 host.conf 与 nodedeck-host.service；开启自同步后启动时若配置变更会自动更新。",
                        "Writes remote host.conf & nodedeck-host.service over SSH; auto-reconciles on startup when changed."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("桌面与屏幕模式", "Desktop & Display Mode"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $profile.mode) {
                        ForEach(LinuxHostDisplayMode.allCases) { mode in
                            Text(mode == .physicalDesktop
                                ? l10n.t("物理屏 / 现有桌面 (KMS)", "Physical Desktop (KMS)")
                                : l10n.t("多用户独立虚拟屏 (:99 Xorg)", "Isolated Virtual Desktop (:99 Xorg)")
                            ).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t("基准端口 (多用户错开)", "Base Port (Per-User Offset)"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("47989", text: $basePortText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t("视频编码器", "Video Encoder"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $profile.encoder) {
                            Text("NVENC (NVIDIA)").tag("nvenc")
                            Text("VAAPI (Intel/AMD)").tag("vaapi")
                            Text("Software (CPU)").tag("software")
                        }
                        .labelsHidden()
                    }
                }

                if profile.mode == .isolatedVirtualDesktop {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.t("隔离 DISPLAY", "Isolated DISPLAY"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField(":99", text: $profile.display)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                        .frame(width: 110)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("GPU (CUDA_VISIBLE_DEVICES)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("0 / 1", text: $profile.cudaDeviceIndex)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.t("DRM 渲染节点", "DRM Render Node"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("/dev/dri/renderD128", text: $profile.drmRenderNode)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                        }
                    }
                }

                Toggle(l10n.t("启用用户专属虚拟静音音频汇 (sunshine_virtual_sink，不外放)", "Use isolated silent virtual audio sink (sunshine_virtual_sink)"), isOn: $profile.virtualAudioSink)
                    .font(.caption)

                Toggle(l10n.t("启用远端剪贴板同步 (clipboard_sync)", "Enable remote clipboard sync"), isOn: $profile.clipboardSync)
                    .font(.caption)

                Toggle(l10n.t("启动时自动检测配置变更并同步到远端 Host", "Auto-reconcile config diff to remote host on startup"), isOn: $profile.autoReconcileOnStart)
                    .font(.caption)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            HStack {
                Spacer()
                Button(l10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isApplying ? l10n.t("正在同步远端 Host…", "Syncing to Host…") : l10n.t("保存并立即同步", "Save & Sync Now")) {
                    saveAndApply()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func saveAndApply() {
        guard let port = Int(basePortText.trimmingCharacters(in: .whitespaces)), (1024...65000).contains(port) else {
            errorMessage = "端口必须在 1024–65000 之间。"
            return
        }
        var updated = profile
        updated.basePort = port
        isApplying = true
        errorMessage = nil

        Task {
            if let err = await store.saveAndReconcileHostProfile(updated, for: host, force: true) {
                isApplying = false
                errorMessage = err
            } else {
                isApplying = false
                dismiss()
            }
        }
    }
}
