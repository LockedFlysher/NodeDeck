import AppKit
import Foundation
import NodeDeckCore

extension HostMonitor {
    // MARK: - Device (SSH Host) Management

    func presentAddHost() {
        editingHostTarget = nil
        editingHostDraft = SSHConfigEditor.makeDefaultNewDraft()
        isShowingHostEditorSheet = true
    }

    func presentEditHost(_ host: SSHHost) {
        editingHostTarget = host
        editingHostDraft = SSHConfigEditor.makeDraft(from: host, configURL: configURL)
        isShowingHostEditorSheet = true
    }

    @discardableResult
    func saveHostDraft(_ draft: SSHHostDraft) -> String? {
        do {
            try SSHConfigEditor.upsertHost(draft, configURL: configURL)
            let newAlias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)

            if let oldAlias = draft.originalAlias, oldAlias != newAlias {
                if pinnedAliases.remove(oldAlias) != nil {
                    pinnedAliases.insert(newAlias)
                    UserDefaults.standard.set(Array(pinnedAliases).sorted(), forKey: Self.pinnedAliasesKey)
                }
            }

            selectedAlias = newAlias
            isShowingHostEditorSheet = false
            editingHostDraft = nil
            editingHostTarget = nil
            reloadConfiguration()
            showFeedback(
                .success,
                draft.isEditing ? "Updated device \"\(newAlias)\"." : "Added device \"\(newAlias)\"."
            )
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func requestDeleteHost(_ host: SSHHost) {
        hostPendingDeletion = host
    }

    func confirmDeleteHost(_ host: SSHHost, removeAssociatedData: Bool = true) {
        hostPendingDeletion = nil
        do {
            try SSHConfigEditor.deleteHost(
                alias: host.alias,
                alternateAliases: host.alternateAliases,
                configURL: configURL
            )
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showFeedback(.error, msg)
            return
        }

        let aliasesLower = Set(host.allAliases.map { $0.lowercased() })

        let removedPins = pinnedAliases.filter { aliasesLower.contains($0.lowercased()) }
        if !removedPins.isEmpty {
            for pin in removedPins {
                pinnedAliases.remove(pin)
            }
            UserDefaults.standard.set(Array(pinnedAliases).sorted(), forKey: Self.pinnedAliasesKey)
        }

        if selectedAlias.map({ aliasesLower.contains($0.lowercased()) }) == true {
            selectedAlias = nil
        }

        if removeAssociatedData {
            let matchingForwards = portForwardConfigs.filter { aliasesLower.contains($0.hostAlias.lowercased()) }
            if !matchingForwards.isEmpty {
                for fwd in matchingForwards {
                    PortForwardManager.shared.stop(id: fwd.id)
                }
                portForwardConfigs.removeAll { aliasesLower.contains($0.hostAlias.lowercased()) }
                persistPortForwardConfigs(portForwardConfigs)
                syncPortForwardSnapshots()
            }

            let beforeSunshine = sunshineHostConfigs.count
            sunshineHostConfigs.removeAll {
                aliasesLower.contains($0.hostAlias.lowercased()) ||
                    $0.address.caseInsensitiveCompare(host.hostName) == .orderedSame
            }
            if sunshineHostConfigs.count != beforeSunshine {
                let updated = sunshineHostConfigs
                Task.detached(priority: .utility) {
                    try? SunshineClient.saveHosts(updated)
                }
            }

            let matchingTunnels = tunnelConfigs.filter { aliasesLower.contains($0.hostAlias.lowercased()) }
            if !matchingTunnels.isEmpty {
                for tunnel in matchingTunnels {
                    TunnelManager.shared.stop(id: tunnel.id)
                }
                tunnelConfigs.removeAll { aliasesLower.contains($0.hostAlias.lowercased()) }
                persistTunnelConfigs(tunnelConfigs)
                syncTunnelSnapshots()
            }

            let matchingMounts = mountConfigs.filter { aliasesLower.contains($0.hostAlias.lowercased()) }
            if !matchingMounts.isEmpty {
                let currentItems = mountItems(for: host)
                mountConfigs.removeAll { aliasesLower.contains($0.hostAlias.lowercased()) }
                persistMountConfigs(mountConfigs)
                Task {
                    for cfg in matchingMounts {
                        let id = cfg.id.uuidString
                        if let mounted = currentItems.first(where: { $0.id == id && $0.isMounted }) {
                            try? await MountManager.unmount(localPath: mounted.localPath, sourceKind: mounted.sourceKind)
                        }
                        mountErrors.removeValue(forKey: id)
                    }
                    await refreshMountStatus()
                }
            }
        }

        reloadConfiguration()
        showFeedback(.info, "Deleted device \"\(host.alias)\" from ~/.ssh/config.")
    }

    func openSSHConfigInEditor() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? "".write(to: configURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(configURL)
    }
}
