import Foundation
import NodeDeckCore

extension HostMonitor {
    // MARK: - SSH Port Forwarding Management

    func syncPortForwardSnapshots() {
        allPortForwardItems = PortForwardManager.shared.snapshotItems(for: portForwardConfigs)
    }

    func portForwardItems(for host: SSHHost) -> [PortForwardRuntimeItem] {
        allPortForwardItems.filter { PortForwardManager.shared.matchesHost($0.config, host: host) }
    }

    func ensureAutoStartPortForwards() async {
        let targets = portForwardConfigs.filter(\.autoStart)
        for cfg in targets {
            try? await PortForwardManager.shared.start(config: cfg) { [weak self] in
                Task { @MainActor in self?.syncPortForwardSnapshots() }
            }
        }
        syncPortForwardSnapshots()
    }

    func presentAddPortForward(for host: SSHHost) {
        editingPortForwardConfig = SSHPortForwardConfig(
            hostAlias: host.alias,
            label: "Jupyter",
            direction: .local,
            localHost: "127.0.0.1",
            localPort: 8888,
            remoteHost: "127.0.0.1",
            remotePort: 8888,
            autoStart: false,
            urlScheme: "http"
        )
        isShowingPortForwardSheet = true
    }

    func presentEditPortForward(_ config: SSHPortForwardConfig) {
        editingPortForwardConfig = config
        isShowingPortForwardSheet = true
    }

    func savePortForwardConfig(_ config: SSHPortForwardConfig, startImmediately: Bool) {
        var updated = portForwardConfigs
        if let idx = updated.firstIndex(where: { $0.id == config.id }) {
            updated[idx] = config
        } else {
            updated.append(config)
        }
        portForwardConfigs = updated
        persistPortForwardConfigs(updated)
        syncPortForwardSnapshots()
        isShowingPortForwardSheet = false
        editingPortForwardConfig = nil

        if startImmediately {
            startPortForward(config)
        } else {
            showFeedback(.success, "Saved port forward \"\(config.label)\".")
        }
    }

    func startPortForward(_ config: SSHPortForwardConfig) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await PortForwardManager.shared.start(config: config) { [weak monitor = self] in
                    Task { @MainActor in monitor?.syncPortForwardSnapshots() }
                }
                syncPortForwardSnapshots()
                showFeedback(.success, "Started \(config.label) (\(config.summaryText)).")
            } catch {
                syncPortForwardSnapshots()
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showFeedback(.error, msg)
            }
        }
    }

    func stopPortForward(_ config: SSHPortForwardConfig) {
        PortForwardManager.shared.stop(id: config.id)
        syncPortForwardSnapshots()
        showFeedback(.info, "Stopped \(config.label).")
    }

    func togglePortForwardAutoStart(_ config: SSHPortForwardConfig) {
        guard let idx = portForwardConfigs.firstIndex(where: { $0.id == config.id }) else { return }
        portForwardConfigs[idx].autoStart.toggle()
        persistPortForwardConfigs(portForwardConfigs)
        syncPortForwardSnapshots()
    }

    func removePortForwardConfig(_ config: SSHPortForwardConfig) {
        PortForwardManager.shared.stop(id: config.id)
        portForwardConfigs.removeAll { $0.id == config.id }
        persistPortForwardConfigs(portForwardConfigs)
        syncPortForwardSnapshots()
        showFeedback(.info, "Removed port forward \"\(config.label)\".")
    }

    func persistPortForwardConfigs(_ configs: [SSHPortForwardConfig]) {
        Task.detached(priority: .utility) {
            try? PortForwardManager.saveConfigs(configs)
        }
    }
}
