import AppKit
import Combine
import NodeDeckCore
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private weak var store: HostMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private lazy var statusIcon: NSImage = Self.makeTemplateStatusIcon()

    init(store: HostMonitor) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        statusItem.isVisible = true

        let rootView = MenuBarPopoverView(onClosePopover: { [weak self] in
            self?.closePopover()
        })
        .environmentObject(store)

        let hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        configureButton()
        bindStore(store)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = statusIcon
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateBadge(tunnelItems: store?.allTunnelItems ?? [], onlineHosts: store?.onlineCount ?? 0, totalHosts: store?.hosts.count ?? 0)
    }

    private func bindStore(_ store: HostMonitor) {
        Publishers.CombineLatest3(store.$allTunnelItems, store.$snapshots, store.$hosts)
            .receive(on: RunLoop.main)
            .sink { [weak self] tunnelItems, snapshots, hosts in
                let online = snapshots.values.filter { $0.state == .online }.count
                self?.updateBadge(tunnelItems: tunnelItems, onlineHosts: online, totalHosts: hosts.count)
            }
            .store(in: &cancellables)
    }

    private func updateBadge(tunnelItems: [TunnelRuntimeItem], onlineHosts: Int, totalHosts: Int) {
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.image = statusIcon

        let activeTunnels = tunnelItems.filter(\.isRunning).count
        let hasError = tunnelItems.contains { $0.state == .error }

        if hasError {
            button.title = " !"
        } else if activeTunnels > 0 {
            button.title = " \(activeTunnels)"
        } else {
            button.title = ""
        }

        let mountedCount = store?.mountedHostCount ?? 0
        if tunnelItems.isEmpty {
            button.toolTip = "NodeDeck · \(onlineHosts)/\(totalHosts) nodes online · \(mountedCount) mounted"
        } else {
            button.toolTip = "NodeDeck · \(onlineHosts)/\(totalHosts) nodes online · \(activeTunnels)/\(tunnelItems.count) tunnels active"
        }

        let winFrame = button.window?.frame ?? .zero
        let btnFrame = button.frame
        let statusLine = "isVisible=\(statusItem.isVisible) title='\(button.title)' btnFrame=\(btnFrame) winFrame=\(winFrame)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nodedeck-statusbar.log")
        try? statusLine.data(using: .utf8)?.write(to: logURL, options: .atomic)
    }

    @objc private func handleStatusBarClick(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        store?.syncTunnelSnapshots()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        removeMouseMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        removeMouseMonitor()
    }

    private func removeMouseMonitor() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
    }

    /// Draws a crisp 18x18 vector terminal+tunnel template icon so it is guaranteed non-nil
    /// and automatically adapts to macOS Light & Dark Menu Bars.
    static func makeTemplateStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Outer rounded terminal badge
            let frameRect = rect.insetBy(dx: 1.6, dy: 2.4)
            let framePath = NSBezierPath(roundedRect: frameRect, xRadius: 3.4, yRadius: 3.4)
            framePath.lineWidth = 1.55
            framePath.stroke()

            // '>' prompt chevron
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 4.8, y: 11.2))
            chevron.line(to: NSPoint(x: 7.7, y: 9.0))
            chevron.line(to: NSPoint(x: 4.8, y: 6.8))
            chevron.lineWidth = 1.55
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()

            // '_' cursor bar
            let underscore = NSBezierPath()
            underscore.move(to: NSPoint(x: 9.3, y: 6.9))
            underscore.line(to: NSPoint(x: 12.8, y: 6.9))
            underscore.lineWidth = 1.55
            underscore.lineCapStyle = .round
            underscore.stroke()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NodeDeck"
        return image
    }
}
