import AppKit
import NodeDeckCore
import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.08, green: 0.52, blue: 0.46)
    static let cpu = Color(red: 0.10, green: 0.54, blue: 0.48)
    static let amdGPU = Color(red: 0.78, green: 0.28, blue: 0.24)
    static let memory = Color(red: 0.78, green: 0.45, blue: 0.15)
    static let disk = Color(red: 0.18, green: 0.42, blue: 0.70)
    static let load = Color(red: 0.67, green: 0.29, blue: 0.31)
    static let warning = Color(red: 0.84, green: 0.52, blue: 0.12)
    static let critical = Color(red: 0.78, green: 0.23, blue: 0.25)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtleBorder = Color(nsColor: .separatorColor).opacity(0.45)

    static func statusColor(_ state: HostConnectionState) -> Color {
        switch state {
        case .online:
            return Color(red: 0.16, green: 0.62, blue: 0.37)
        case .offline:
            return Color(red: 0.78, green: 0.25, blue: 0.27)
        case .checking:
            return Color(red: 0.82, green: 0.54, blue: 0.13)
        case .idle:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }

    static func mountColor(_ state: MountRuntimeState) -> Color {
        switch state {
        case .mounted:
            return Color(red: 0.16, green: 0.62, blue: 0.37)
        case .mounting, .unmounting:
            return Color(red: 0.82, green: 0.54, blue: 0.13)
        case .error:
            return Color(red: 0.78, green: 0.25, blue: 0.27)
        case .unmounted:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    static func routeColor(_ route: SSHRouteKind) -> Color {
        switch route {
        case .localTunnel:
            return Color(red: 0.12, green: 0.55, blue: 0.49)
        case .directLAN:
            return Color(red: 0.18, green: 0.48, blue: 0.75)
        case .remote:
            return Color(red: 0.52, green: 0.42, blue: 0.68)
        }
    }

    static func severityColor(fraction: Double, base: Color) -> Color {
        if fraction >= 0.92 {
            return critical
        }
        if fraction >= 0.80 {
            return warning
        }
        return base
    }

    static func slurmColor(_ category: SlurmNodeCategory) -> Color {
        switch category {
        case .idle:
            return Color(red: 0.16, green: 0.62, blue: 0.37)
        case .allocated:
            return Color(red: 0.78, green: 0.25, blue: 0.27)
        case .mixed:
            return Color(red: 0.82, green: 0.54, blue: 0.13)
        case .unavailable:
            return Color(nsColor: .secondaryLabelColor)
        case .other:
            return Color(red: 0.32, green: 0.46, blue: 0.68)
        }
    }

    static func avatarColor(for host: SSHHost) -> Color {
        let value = host.alias.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let palette: [Color] = [
            Color(red: 0.12, green: 0.47, blue: 0.45),
            Color(red: 0.20, green: 0.38, blue: 0.62),
            Color(red: 0.57, green: 0.38, blue: 0.19),
            Color(red: 0.44, green: 0.34, blue: 0.55)
        ]
        return palette[value % palette.count]
    }
}

enum DisplayFormat {
    static func bytes(_ value: UInt64) -> String {
        let number = Double(value)
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("KB", 1_000)
        ]

        for (unit, divisor) in units where number >= divisor {
            let converted = number / divisor
            if converted >= 100 {
                return String(format: "%.0f %@", converted, unit)
            }
            if converted >= 10 {
                return String(format: "%.1f %@", converted, unit)
            }
            return String(format: "%.2f %@", converted, unit)
        }
        return "\(value) B"
    }

    static func vram(usedMB: Double?, totalMB: Double?) -> String {
        guard let used = usedMB, let total = totalMB else { return "--" }
        if total >= 1_024 {
            return String(format: "%.1f / %.1f GB", used / 1_024, total / 1_024)
        }
        return "\(Int(used)) / \(Int(total)) MB"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    static func number(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "--" }
        if milliseconds >= 1_000 {
            return String(format: "%.1f s", milliseconds / 1_000)
        }
        return String(format: "%.0f ms", milliseconds)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "--" }
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .omitted, time: .standard)
    }
}

struct HostAvatar: View {
    let host: SSHHost
    var size: CGFloat = 38

    private var symbolName: String {
        let combined = host.allAliases.joined(separator: " ").lowercased()
        if combined.contains("phone") || combined.contains("termux") {
            return "iphone"
        }
        if combined.contains("cluster") || combined.contains("slurm") || combined.contains("hpc") {
            return "square.stack.3d.up.fill"
        }
        if combined.contains("gpu") || combined.contains("rtx") || combined.contains("a100") || combined.contains("h100") || combined.contains("4090") || combined.contains("5090") {
            return "cpu.fill"
        }
        if combined.contains("workstation") ||
            combined.contains("desktop") ||
            combined.contains("laptop") ||
            combined.contains("studio") ||
            combined.contains("mac") {
            return "desktopcomputer"
        }
        if combined.contains("cloud") || combined.contains("vps") || combined.contains("vm") {
            return "cloud.fill"
        }
        return "server.rack"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.avatarColor(for: host).opacity(0.16))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.avatarColor(for: host).opacity(0.24), lineWidth: 1)
            Image(systemName: symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(AppTheme.avatarColor(for: host))
        }
        .frame(width: size, height: size)
    }
}

struct StatusDot: View {
    let state: HostConnectionState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(AppTheme.statusColor(state))
            .frame(width: size, height: size)
            .overlay {
                if state == .checking {
                    Circle()
                        .stroke(AppTheme.statusColor(state).opacity(0.35), lineWidth: 2)
                        .scaleEffect(1.8)
                }
            }
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let state: HostConnectionState

    private var label: String {
        switch state {
        case .online: return "Online"
        case .offline: return "Offline"
        case .checking: return "Checking"
        case .idle: return "Waiting"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state, size: 7)
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(AppTheme.statusColor(state))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AppTheme.statusColor(state).opacity(0.11))
        )
    }
}

struct RouteBadge: View {
    let route: SSHRouteKind
    var compact: Bool = false

    var body: some View {
        Text(compact ? route.shortBadge : route.label)
            .font(.system(size: compact ? 9.5 : 11, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(AppTheme.routeColor(route))
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, compact ? 1.5 : 3.5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.routeColor(route).opacity(0.11))
            )
    }
}

struct MeterBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(value, 0), 1)
            let effectiveColor = AppTheme.severityColor(fraction: fraction, base: color)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(effectiveColor.opacity(0.13))
                Capsule(style: .continuous)
                    .fill(effectiveColor)
                    .frame(width: fraction > 0 ? max(geometry.size.width * fraction, 3) : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(DisplayFormat.percent(value))
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
        }
    }
}

/// Responsive wrapping horizontal layout for action toolbars, badges, and chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            totalWidth = max(totalWidth, currentX + size.width)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: proposal.width ?? totalWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.subtleBorder, lineWidth: 1)
            )
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}
