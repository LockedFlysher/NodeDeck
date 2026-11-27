import AppKit
import NodeDeckCore
import SwiftUI

struct LocalHostSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isRestarting = false

    private var isRunning: Bool {
        store.localSunshineHostState == .running
    }

    private var perms: LocalHostPermissionStatus {
        store.localHostPermissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isRunning ? AppTheme.accent.opacity(0.18) : Color.secondary.opacity(0.12))
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isRunning ? AppTheme.accent : .secondary)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("本机 Mac 被控端设置", "Local Mac Remote Host"))
                        .font(.headline)
                    Text(l10n.t(
                        "开启后，同账号下的手机 / Linux / 其他电脑可直接免配对远控这台 Mac。",
                        "Allow authorized devices in your account to remotely control this Mac."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Master Toggle Card
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isRunning ? (perms.screenRecording && perms.lastLogHint == nil ? Color.green : Color.orange) : Color.secondary.opacity(0.5))
                            .frame(width: 9, height: 9)
                        Text(l10n.t("打开本机被控", "Enable Local Mac Host"))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if isRunning {
                        let ip = store.accountSession.virtualIp.isEmpty ? "127.0.0.1" : store.accountSession.virtualIp
                        Text(l10n.t("服务运行中 · 监听 \(ip):47989", "Running · Listening on \(ip):47989"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if store.localSunshineHostState == .notInstalled {
                        Text(l10n.t("未检测到内置 nodedeck-host 引擎", "Built-in nodedeck-host binary not found"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(l10n.t("当前未开启，其他设备无法串流本机桌面", "Stopped · Remote desktop disabled on this Mac"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { isRunning },
                        set: { enabled in
                            store.setLocalSunshineHostEnabled(enabled)
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(store.localSunshineHostState == .notInstalled)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.subtleBorder, lineWidth: 1)
            )

            // Warning banner if running but Screen Recording TCC denied
            if isRunning && (!perms.screenRecording || perms.lastLogHint == "TCC_DENIED") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t("录屏权限尚未对当前版本的 NodeDeck 生效", "Screen Recording Permission Needs Refresh"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(l10n.t(
                            "macOS 在应用更新重签后会要求重新确认录屏权限。若「系统设置 → 录屏与系统录音」里 NodeDeck 开关已显示打开，请先关闭再重新打开（或点减号移除后重新添加 /Applications/NodeDeck.app），然后点击下方「重启本机被控」。",
                            "macOS invalidates ad-hoc Screen Recording grants after an app rebuild. Toggle NodeDeck OFF and back ON in Screen & System Audio Recording (or remove & re-add /Applications/NodeDeck.app), then click Restart Local Host below."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
            }

            // 3-step System Permission Guidance
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.t("macOS 系统权限引导（开启被控必需）", "macOS Permission Checklist"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                permissionRow(
                    title: l10n.t("1. 录屏与系统录音", "1. Screen & System Audio Recording"),
                    subtitle: l10n.t("必需 · 用于采集本机屏幕画面与系统声音（请授权 NodeDeck）", "Required · Captures Mac screen & audio for NodeDeck"),
                    granted: perms.screenRecording && perms.lastLogHint != "TCC_DENIED",
                    actionLabel: l10n.t("前往授权", "Open Settings")
                ) {
                    SunshineHostManager.requestScreenRecordingPermission()
                    openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                }

                permissionRow(
                    title: l10n.t("2. 辅助功能（键鼠控制）", "2. Accessibility (Mouse & Keyboard)"),
                    subtitle: l10n.t("必需 · 用于远端点击、拖拽与键盘输入", "Required · Injects remote mouse & keyboard events"),
                    granted: perms.accessibility,
                    actionLabel: l10n.t("前往授权", "Open Settings")
                ) {
                    SunshineHostManager.requestAccessibilityPermission()
                    openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }

                permissionRow(
                    title: l10n.t("3. 远程登录 SSH（端口 22）", "3. Remote Login SSH (Port 22)"),
                    subtitle: l10n.t("推荐 · 用于手机/Linux 终端直连与自动多显示器切换", "Recommended · Enables remote terminal & display switching"),
                    granted: perms.sshRemoteLogin,
                    actionLabel: l10n.t("共享设置", "Sharing")
                ) {
                    openSystemSettings("x-apple.systempreferences:com.apple.Sharing-Settings.extension")
                }
            }

            Divider()

            // Footer Actions
            HStack(spacing: 10) {
                Button {
                    store.refreshLocalSunshineHostState()
                } label: {
                    Label(l10n.t("重新检测权限", "Re-check"), systemImage: "arrow.clockwise")
                }

                if isRunning {
                    Button {
                        isRestarting = true
                        store.restartLocalSunshineHost()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            isRestarting = false
                            store.refreshLocalSunshineHostState()
                        }
                    } label: {
                        if isRestarting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(l10n.t("重启本机被控使权限生效", "Restart Host"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestarting)
                }

                Spacer()

                Button(l10n.t("完成", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            store.refreshLocalSunshineHostState()
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(actionLabel, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(granted ? Color.green.opacity(0.25) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func openSystemSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
