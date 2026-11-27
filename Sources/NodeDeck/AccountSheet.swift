import NodeDeckCore
import SwiftUI

struct AccountSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss

    @State private var authMode = 0 // 0 = Sign In, 1 = Register
    @State private var username = ""
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var serverUrl = ControlPlaneClient.defaultServerURL
    @State private var showServerConfig = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("NodeDeck 统一账号与内置组网", "NodeDeck Account & Built-in Mesh"))
                        .font(.title3.weight(.semibold))
                    Text(l10n.t(
                        "一次登录即可自动加入私有 EasyTier 组网、同步名下设备与远程桌面证书",
                        "Sign in once to auto-join your private EasyTier mesh, sync devices, and auto-pair Moonlight"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.t("关闭", "Done")) { dismiss() }
            }

            Divider()

            if !store.accountSession.isLoggedIn {
                Picker("", selection: $authMode) {
                    Text(l10n.t("登录", "Sign In")).tag(0)
                    Text(l10n.t("邀请码注册", "Register")).tag(1)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    TextField(l10n.t("用户名", "Username"), text: $username)
                        .textFieldStyle(.roundedBorder)

                    SecureField(l10n.t("密码", "Password"), text: $password)
                        .textFieldStyle(.roundedBorder)

                    if authMode == 1 {
                        TextField(l10n.t("邀请码", "Invite Code"), text: $inviteCode)
                            .textFieldStyle(.roundedBorder)
                    }

                    DisclosureGroup(l10n.t("控制服务器地址", "Control Server URL"), isExpanded: $showServerConfig) {
                        TextField("https://...", text: $serverUrl)
                            .textFieldStyle(.roundedBorder)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button {
                        submitAuth()
                    } label: {
                        HStack(spacing: 6) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(authMode == 0
                                ? l10n.t("登录并自动组网", "Sign In & Connect")
                                : l10n.t("注册并自动组网", "Register & Connect"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(busy || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
            } else {
                // Logged-in dashboard
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(store.accountSession.username) · \(store.accountSession.virtualCidr)")
                                .font(.headline)
                            Text("\(store.accountSession.deviceName) · \(store.accountSession.serverUrl)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(l10n.t("同步", "Sync")) {
                            Task { await store.syncAccountState() }
                        }
                        Button(l10n.t("启动/切换本机组网", "Apply Built-in Mesh")) {
                            busy = true
                            errorMessage = nil
                            Task {
                                do {
                                    try await store.startBuiltInMacMesh()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                                busy = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .disabled(busy)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Divider()

                    Text(l10n.t("账号下设备 (\(store.accountDevices.count))", "Account Devices (\(store.accountDevices.count))"))
                        .font(.subheadline.weight(.semibold))

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.accountDevices) { dev in
                                HStack {
                                    Circle()
                                        .fill(dev.online ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(dev.deviceName) (\(dev.platform)/\(dev.role))")
                                            .font(.subheadline.weight(.medium))
                                        Text("\(dev.virtualIp)" + (dev.sunshineEnabled ? " · Remote :\(dev.sunshineHttpPort)" : ""))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 180)

                    HStack {
                        Button(l10n.t("退出登录", "Sign Out"), role: .destructive) {
                            Task { await store.logoutAccount() }
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if !store.accountSession.serverUrl.isEmpty {
                serverUrl = store.accountSession.serverUrl
            }
            if !store.accountSession.username.isEmpty {
                username = store.accountSession.username
            }
        }
    }

    private func submitAuth() {
        busy = true
        errorMessage = nil
        let cleanUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInvite = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if authMode == 0 {
                    try await store.loginAccount(serverUrl: cleanUrl, username: cleanUser, password: password)
                } else {
                    try await store.registerAccount(serverUrl: cleanUrl, username: cleanUser, password: password, inviteCode: cleanInvite)
                }
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
