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
                    Text(l10n.t("SSH 免 PIN 自动配对", "Zero-PIN SSH Auto Pairing"))
                        .font(.headline)
                    Text(l10n.t(
                        "通过 SSH 校验 \(host.alias) 权限后直接注入本机客户端证书，无需浏览器输入 PIN 码。",
                        "Verifies credentials over your SSH session to \(host.alias) and injects your local client cert directly."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(AppTheme.accent)
                    .font(.caption)
                Text(l10n.t(
                    "安全说明：密码仅用于本次 SSH 校验，绝不落盘、不经第三方云端服务器。",
                    "Security note: Your password is used strictly for this SSH check—never saved or sent to any cloud."
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
                    if isPairing {
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

                Button(isPairing ? l10n.t("正在自动配对…", "Pairing…") : l10n.t("登录并自动配对", "Verify & Auto Pair")) {
                    startAutoPairing()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isPairing ||
                        address.trimmingCharacters(in: .whitespaces).isEmpty ||
                        username.trimmingCharacters(in: .whitespaces).isEmpty ||
                        password.isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 460)
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
