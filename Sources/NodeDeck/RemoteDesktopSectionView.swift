import NodeDeckCore
import SwiftUI

struct RemoteDesktopSectionView: View {
    @EnvironmentObject private var store: HostMonitor
    @ObservedObject private var l10n = AppLocalization.shared
    let snapshot: HostSnapshot

    private var nativeSunshine: SunshineHostConfig? {
        store.sunshineConfig(for: snapshot.host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SectionTitle(
                    title: l10n.t("远程桌面", "Remote Desktop"),
                    detail: nativeSunshine != nil
                        ? l10n.t("已就绪，点击即可直连", "Ready to connect")
                        : l10n.t("尚未配对", "Not paired yet")
                )

                Button {
                    store.presentHostProfile(for: snapshot.host)
                } label: {
                    Label(l10n.t("主机配置", "Host Settings"), systemImage: "server.rack")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .help(l10n.t("高级设置：配置 Linux 多用户虚拟屏、GPU 与端口", "Advanced: configure Linux multi-user display, GPU, and port"))
            }

            if let native = nativeSunshine {
                nativeSunshineBanner(native)
            } else {
                unpairedSunshineBanner
            }
        }
        .sheet(isPresented: $store.isShowingSunshinePairSheet) {
            if let pairHost = store.sunshinePairTargetHost {
                SunshinePairSheet(host: pairHost)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $store.isShowingHostProfileSheet) {
            if let targetHost = store.editingHostProfileTarget {
                HostProfileSheet(
                    host: targetHost,
                    initialProfile: store.hostProfile(for: targetHost)
                )
                .environmentObject(store)
            }
        }
    }

    private func nativeSunshineBanner(_ config: SunshineHostConfig) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.14))
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.host.alias)
                        .font(.system(size: 13.5, weight: .semibold))
                    readyPill
                }
                Text("\(config.address):\(config.httpPort)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Menu {
                    Button(l10n.t("1080p @ 60fps 串流", "Stream 1080p @ 60fps")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 1920, height: 1080, fps: 60)
                    }
                    Button(l10n.t("1080p + 隐私屏模式", "Stream 1080p + Privacy Screen")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 1920, height: 1080, fps: 60, enablePrivacyScreen: true)
                    }
                    Button(l10n.t("1440p @ 60fps 串流", "Stream 1440p @ 60fps")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 2560, height: 1440, fps: 60)
                    }
                    Button(l10n.t("4K @ 60fps 串流", "Stream 4K @ 60fps")) {
                        store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort, width: 3840, height: 2160, fps: 60)
                    }
                    Divider()
                    Button(l10n.t("打开宿主机 Web 管理台", "Open Host Web UI")) {
                        MoonlightLauncher.openSunshineWebUI(urlString: config.webUIURLString)
                    }
                    Button(l10n.t("重新免 PIN 配对…", "Re-pair Host…")) {
                        store.presentPairSunshine(for: snapshot.host)
                    }
                    Button(l10n.t("取消配对", "Unpair Host"), role: .destructive) {
                        store.removeSunshineHostConfig(config)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    store.launchNativeMoonlightStream(hostAlias: snapshot.host.alias, address: config.address, httpPort: config.httpPort)
                } label: {
                    Label(l10n.t("连接桌面", "Stream Desktop"), systemImage: "play.display")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.small)
                .help(l10n.t("打开内置硬件加速远程桌面窗口", "Open built-in hardware-accelerated desktop stream"))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(13)
        .cardBackground()
    }

    private var readyPill: some View {
        let color = AppTheme.statusColor(.online)
        return Text(l10n.t("已配对", "Ready"))
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.14))
            )
    }

    private var unpairedSunshineBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("尚未配对远程桌面", "Remote Desktop Not Paired Yet"))
                    .font(.system(size: 12.5, weight: .medium))
                Text(l10n.t(
                    "通过你已信任的 SSH 通道直接注入本地证书到 \(snapshot.host.hostName)，零云端中转、免 PIN 一键配对。",
                    "Injects a local client certificate over your SSH session to \(snapshot.host.hostName) — zero cloud relay, no manual PIN."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(l10n.t("免 PIN 配对…", "Zero-PIN Pair…")) {
                store.presentPairSunshine(for: snapshot.host)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)
        }
        .padding(13)
        .cardBackground()
    }
}
