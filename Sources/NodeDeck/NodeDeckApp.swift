import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject {
    static let shared = WindowCoordinator()

    weak var mainWindow: NSWindow?
    private var didApplyInitialBackgroundHide = false
    private(set) var isTerminating = false
    private var titlebarDoubleClickMonitor: Any?
    private var preZoomFrame: NSRect?

    var launchedInBackground: Bool {
        CommandLine.arguments.contains("--background")
    }

    func prepareForTermination() {
        isTerminating = true
        NSApp.setActivationPolicy(.accessory)
    }

    func attachMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.isReleasedWhenClosed = false
        installTitlebarDoubleClickMonitorIfNeeded()

        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(handleCloseButton(_:))
        }

        if launchedInBackground && !didApplyInitialBackgroundHide {
            didApplyInitialBackgroundHide = true
            DispatchQueue.main.async { [weak window] in
                window?.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func installTitlebarDoubleClickMonitorIfNeeded() {
        guard titlebarDoubleClickMonitor == nil else { return }
        titlebarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self,
                  event.clickCount == 2,
                  let window = self.mainWindow,
                  event.window === window,
                  !window.styleMask.contains(.fullScreen)
            else {
                return event
            }

            let location = event.locationInWindow
            let topDistance = window.frame.height - location.y
            // Standard hidden-titlebar strip (28–32pt) excluding traffic-light buttons on the left.
            guard topDistance >= 0, topDistance <= 32, location.x >= 78 else {
                return event
            }

            // Do not hijack double-clicks on interactive controls (buttons, text fields, etc.).
            if let hitView = window.contentView?.hitTest(location) {
                var cursor: NSView? = hitView
                while let view = cursor {
                    if view is NSControl {
                        return event
                    }
                    cursor = view.superview
                }
            }

            self.toggleZoomFill(for: window)
            return nil
        }
    }

    func toggleZoomFill(for window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else {
            window.zoom(nil)
            return
        }
        let targetFrame = screen.visibleFrame
        let currentFrame = window.frame
        let isAlreadyFilled =
            abs(currentFrame.width - targetFrame.width) <= 8 &&
            abs(currentFrame.height - targetFrame.height) <= 8 &&
            abs(currentFrame.minX - targetFrame.minX) <= 8 &&
            abs(currentFrame.minY - targetFrame.minY) <= 8

        if isAlreadyFilled, let saved = preZoomFrame {
            preZoomFrame = nil
            window.setFrame(saved, display: true, animate: true)
        } else {
            preZoomFrame = currentFrame
            window.setFrame(targetFrame, display: true, animate: true)
        }
    }

    @objc func handleCloseButton(_ sender: AnyObject?) {
        hideMainWindowToMenuBar()
    }

    func hideMainWindowToMenuBar() {
        guard !isTerminating else { return }
        if let mainWindow {
            mainWindow.orderOut(nil)
        }
        for window in NSApp.windows where window.level == .normal && window.styleMask.contains(.closable) {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow(openWindow: OpenWindowAction? = nil) {
        NSApp.setActivationPolicy(.regular)
        let target = mainWindow ?? NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title == "NodeDeck"
        })
        if let target {
            if target.isMiniaturized {
                target.deminiaturize(nil)
            }
            target.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                WindowCoordinator.shared.attachMainWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window {
                WindowCoordinator.shared.attachMainWindow(window)
            }
        }
    }
}

@MainActor
final class NodeDeckAppDelegate: NSObject, NSApplicationDelegate {
    let store = HostMonitor()
    private var statusBarController: StatusBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        statusBarController = StatusBarController(store: store)
        store.start()

        if WindowCoordinator.shared.launchedInBackground {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                WindowCoordinator.shared.hideMainWindowToMenuBar()
            }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            statusBarController?.closePopover()
            WindowCoordinator.shared.showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep Menu Bar resident icon + GOST/UDP tunnels alive when dashboard window is closed.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowCoordinator.shared.prepareForTermination()
        store.stop()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                WindowCoordinator.shared.prepareForTermination()
                self?.store.stop()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

@main
struct NodeDeckApp: App {
    @NSApplicationDelegateAdaptor(NodeDeckAppDelegate.self) private var appDelegate

    private var store: HostMonitor {
        appDelegate.store
    }

    var body: some Scene {
        Window("NodeDeck", id: "main") {
            ContentView()
                .environmentObject(store)
                .background(MainWindowAccessor())
                .frame(minWidth: 740, minHeight: 520)
                .onAppear {
                    store.start()
                }
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .saveItem) {
                Button("Hide to Menu Bar") {
                    WindowCoordinator.shared.hideMainWindowToMenuBar()
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandMenu("Hosts") {
                Button("Refresh All") {
                    store.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Reload SSH Config & Mounts") {
                    store.reloadConfiguration()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Open in Terminal") {
                    if let host = store.selectedSnapshot?.host {
                        store.openSSHInTerminal(for: host)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.selectedSnapshot == nil)

                Button("Open Workspace in VS Code") {
                    if let host = store.selectedSnapshot?.host {
                        store.openPrimaryVSCodeOrPicker(for: host)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(store.selectedSnapshot == nil || !store.isVSCodeInstalled)

                Button("Stream Moonlight Desktop") {
                    if let host = store.selectedSnapshot?.host {
                        store.launchMoonlightDesktop(for: host)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.selectedSnapshot.map { !store.hasMoonlightTunnel(for: $0.host) } ?? true)

                Button("Copy SSH Command") {
                    if let host = store.selectedSnapshot?.host {
                        TerminalLauncher.copyCommand(for: host)
                        store.showFeedback(.info, "Copied \(host.terminalCommand)")
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedSnapshot == nil)

                Divider()

                Button("Open or Mount Primary Folder") {
                    if let host = store.selectedSnapshot?.host {
                        store.openPrimaryMountOrComposer(for: host)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store.selectedSnapshot == nil)

                Button("Add Directory Mount…") {
                    if let host = store.selectedSnapshot?.host {
                        store.presentAddMount(for: host)
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(store.selectedSnapshot == nil)

                Button("Add GOST Tunnel…") {
                    if let host = store.selectedSnapshot?.host {
                        store.presentAddTunnel(for: host)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store.selectedSnapshot == nil)
            }
        }
    }
}
