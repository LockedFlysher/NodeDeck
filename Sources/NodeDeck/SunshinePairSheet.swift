import AppKit
import NodeDeckCore
import SwiftUI

struct SunshinePairSheet: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss

    let host: SSHHost

    @State private var address: String
    @State private var httpPortText: String
    @State private var username: String
    @State private var password: String = ""
    @State private var isActivatingByAccount = false
    @State private var isPairing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    init(host: SSHHost, initialAddress: String? = nil, initialPort: Int? = nil) {
        self.host = host
        _address = State(initialValue: initialAddress ?? host.hostName)
        let defaultPort = initialPort ?? 47989
        _httpPortText = State(initialValue: String(defaultPort))
        _username = State(initialValue: host.user.isEmpty ? NSUserName() : host.user)
    }

    private var webUIURL: String {
        let port = (Int(httpPortText) ?? 47989) + 1
        return "https://\(address):\(port)/pin"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.16))
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("配对并激活远程桌面主机", "Activate & Pair Remote Host"))
                        .font(.headline)
                    Text(l10n.t(
                        "优先使用 NodeDeck 同账号免密激活 \(host.alias)；未登录同账号时可使用下方 SSH 备用方式。",
                        "Prefer 1-tap same-account activation for \(host.alias); fall back to SSH only if needed."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if store.accountSession.isLoggedIn {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n.t("账号一键激活配对（推荐 · 免 SSH / 免密码）", "1-Tap Account Activation (No SSH / No Password)"))
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(l10n.t(
                                "使用当前账号（\(store.accountSession.username)）自动同步本机证书并唤起远端被控服务，全程无需 sudo 或系统密码。",
                                "Uses your signed-in account (\(store.accountSession.username)) to sync certs and start remote host automatically."
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        startAccountActivation()
                    } label: {
                        HStack(spacing: 6) {
                            if isActivatingByAccount {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "bolt.shield.fill")
                            }
                            Text(
                                isActivatingByAccount
                                    ? l10n.t("正在通过账号激活远端被控…", "Activating via Account…")
                                    : l10n.t("账号一键激活并配对 \(host.alias)", "Activate & Pair \(host.alias) via Account")
                            )
                            .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isActivatingByAccount || isPairing)
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.green.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.28), lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(AppTheme.accent)
                    .font(.caption)
                Text(l10n.t(
                    "备用方式（SSH 免 PIN 配对）：仅当目标主机未登录同一 NodeDeck 账号时才需填写 SSH 密码；密码不落盘。",
                    "Fallback (Zero-PIN SSH): Only needed if target host isn't signed in to the same NodeDeck account."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.08))
            )

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("宿主机地址", "Host Address"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("192.168.1.10", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("HTTP 端口", "HTTP Port"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("47989", text: $httpPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                }
                .frame(width: 96)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("SSH 账号", "SSH Username"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("ubuntu", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("登录密码", "Password"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SecureField(l10n.t("输入登录密码", "Enter password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                        .onSubmit { startAutoPairing() }
                }
            }

            if let statusMessage {
                HStack(spacing: 8) {
                    if isPairing || isActivatingByAccount {
                        ProgressView().controlSize(.small)
                    }
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            Divider()

            HStack {
                Button(l10n.t("打开 Web 管理台", "Open Web UI")) {
                    if let url = URL(string: webUIURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button(l10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isPairing ? l10n.t("正在 SSH 配对…", "Pairing…") : l10n.t("SSH 备用配对", "SSH Fallback Pair")) {
                    startAutoPairing()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isPairing || isActivatingByAccount ||
                        address.trimmingCharacters(in: .whitespaces).isEmpty ||
                        username.trimmingCharacters(in: .whitespaces).isEmpty ||
                        password.isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func startAccountActivation() {
        isActivatingByAccount = true
        errorMessage = nil
        statusMessage = l10n.t(
            "正在下发账号激活指令并同步本机证书到 \(host.alias)（最多等待 15 秒）…",
            "Sending account activation command & syncing client cert to \(host.alias)…"
        )

        Task {
            do {
                _ = try await store.activateDeviceViaAccount(for: host)
                isActivatingByAccount = false
                dismiss()
            } catch {
                isActivatingByAccount = false
                statusMessage = nil
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startAutoPairing() {
        let trimmedAddr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(httpPortText.trimmingCharacters(in: .whitespaces)) ?? 47989
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        isPairing = true
        errorMessage = nil
        statusMessage = "正在通过 sudoer 校验并将证书直接写入 \(host.alias)（免 PIN）…"

        Task {
            do {
                let paired = try await SunshineClient.shared.pairViaSudoerSSH(
                    hostAlias: host.alias,
                    address: trimmedAddr,
                    httpPort: port,
                    username: trimmedUser,
                    password: password
                )
                store.saveSunshineHostConfig(paired)
                isPairing = false
                dismiss()
            } catch {
                isPairing = false
                statusMessage = nil
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
