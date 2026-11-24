import AppKit
import NodeDeckCore
import SwiftUI

struct ArchitectureGuideSheet: View {
    @ObservedObject private var l10n = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    trustPledgeBanner
                    dataFlowDiagramCard
                    technicalStackGrid
                    localFilesAuditCard
                    licenseFooterCard
                }
                .padding(22)
            }

            Divider()
            HStack {
                Text(l10n.t(
                    "所有配置与证书均保存在本机，可随时审查或删除。",
                    "All configs and certificates stay on your device and can be audited or removed anytime."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(l10n.t("关闭", "Done")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.15))
                Image(systemName: "shield.checkered")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("技术原理与安全透明", "How NodeDeck Works & Security Model"))
                    .font(.headline)
                Text(l10n.t(
                    "无云端服务器 · 全开源协议 · 所有密钥与数据均由你本地掌控",
                    "Zero Cloud Servers · Open-Source Protocols · Local-First Ownership"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                l10n.toggleChineseEnglish()
            } label: {
                Text(l10n.isChinese ? "EN" : "中文")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var trustPledgeBanner: some View {
        HStack(spacing: 10) {
            trustPill(icon: "icloud.slash", title: l10n.t("零云端中转", "Zero Cloud"))
            trustPill(icon: "person.crop.circle.badge.xmark", title: l10n.t("免注册账号", "No Account"))
            trustPill(icon: "lock.shield", title: l10n.t("端到端加密", "End-to-End Encrypted"))
            trustPill(icon: "eye.slash", title: l10n.t("零遥测上报", "Zero Telemetry"))
        }
    }

    private func trustPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private var dataFlowDiagramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                l10n.t("端到端连接与数据流向", "End-to-End Connection & Data Flow"),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                flowNode(
                    icon: "laptopcomputer",
                    title: l10n.t("本机 NodeDeck", "Local NodeDeck"),
                    detail: l10n.t("VideoToolbox / VAAPI 硬解\n本地 RSA-2048 证书\n~/.ssh/config 托管", "VideoToolbox / VAAPI Decode\nLocal RSA-2048 Cert\n~/.ssh/config Managed")
                )

                VStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text(l10n.t("直连 / 自建隧道", "Direct / Your Tunnel"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text("SSH · TLS · AES-GCM")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 118)

                flowNode(
                    icon: "server.rack",
                    title: l10n.t("你的 Linux / Mac 主机", "Your Linux / Mac Host"),
                    detail: l10n.t("nodedeck-host (Sunshine)\n多用户独立 :99 虚拟屏\nSSH ControlMaster 指标", "nodedeck-host (Sunshine)\nMulti-User :99 Virtual Xorg\nSSH ControlMaster Metrics")
                )
            }
        }
        .padding(14)
        .cardBackground()
    }

    private func flowNode(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    private var technicalStackGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                l10n.t("核心技术方案透明说明", "Core Technical Architecture"),
                systemImage: "cpu"
            )
            .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                techCard(
                    icon: "play.display",
                    title: l10n.t("内置主控端与无头被控端", "Built-in Client & Headless Host"),
                    body: l10n.t(
                        "主控端内置开源 moonlight-common-c（VideoToolbox / VAAPI+NVDEC 硬解）；被控端由开源 Sunshine 源码去除 Qt 编译内置为 nodedeck-host，无需额外安装 Moonlight 或 Sunshine。",
                        "Embeds moonlight-common-c client (VideoToolbox / VAAPI+NVDEC) and source-built headless zero-Qt Sunshine host (nodedeck-host). No separate Moonlight or Sunshine install required."
                    )
                )

                techCard(
                    icon: "key.viewfinder",
                    title: l10n.t("SSH 免 PIN 证书配对", "Zero-PIN SSH Certificate Pairing"),
                    body: l10n.t(
                        "在你的本机生成 RSA-2048 证书，经由你已认证的 SSH 通道直接写入远端 host_state.json。输入密码仅用于当次验证，绝不保存或外发。",
                        "Generates an RSA-2048 cert locally and writes it directly into remote host_state.json over your authenticated SSH session. Passwords are never stored or sent elsewhere."
                    )
                )

                techCard(
                    icon: "person.2.badge.gearshape",
                    title: l10n.t("Linux 多用户桌面隔离", "Linux Multi-User Isolation"),
                    body: l10n.t(
                        "每名用户可绑定独立 Xorg 虚拟屏（如 :99）、独立 GPU（CUDA_VISIBLE_DEVICES）、静音虚拟音频汇与独立端口段，重启前通过 SHA-256 自动同步差异。",
                        "Each user can bind an isolated Xorg display (:99), dedicated GPU (CUDA_VISIBLE_DEVICES), silent virtual audio sink, and disjoint ports, reconciled via SHA-256 diff."
                    )
                )

                techCard(
                    icon: "bolt.horizontal.circle",
                    title: l10n.t("SSH 复用与安全同步", "Multiplexed SSH & Clipboard"),
                    body: l10n.t(
                        "性能指标与剪贴板同步复用隔离的 ControlMaster 通道（60 秒无操作自动退出），不改动你的 ~/.ssh/config 主连接，且剪贴板自动同步默认关闭。",
                        "Metrics and clipboard sync share an isolated ControlMaster socket (auto-expires after 60s idle) without touching your main SSH setup. Auto-clipboard push is OFF by default."
                    )
                )
            }
        }
    }

    private func techCard(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .cardBackground()
    }

    private var localFilesAuditCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                l10n.t("可审计的本地文件位置", "Auditable Local Storage Locations"),
                systemImage: "folder.badge.questionmark"
            )
            .font(.subheadline.weight(.semibold))

            auditRow(
                label: l10n.t("SSH 主机清单", "SSH Host Config"),
                path: "~/.ssh/config",
                url: SSHConfigParser.defaultConfigURL
            )
            auditRow(
                label: l10n.t("NodeDeck 本地配置与证书", "App Config & Client Certs"),
                path: "~/Library/Application Support/NodeDeck",
                url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NodeDeck")
            )
        }
        .padding(14)
        .cardBackground()
    }

    private func auditRow(label: String, path: String, url: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.t("在访达中查看", "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var licenseFooterCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(l10n.t(
                "开源构成：NodeDeck 一方代码采用 MIT 协议；内置串流协议层 moonlight-common-c 与源码编译内置的无头宿主机服务 Sunshine (nodedeck-host) 采用 GPL-3.0 协议，详见仓库 THIRD_PARTY_LICENSES.md。",
                "Open-Source Stack: First-party NodeDeck code is MIT-licensed; embedded moonlight-common-c and source-built headless Sunshine host (nodedeck-host) are GPL-3.0 (see THIRD_PARTY_LICENSES.md)."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
    }
}
