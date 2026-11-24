import AppKit
import Foundation
import NodeDeckCore

struct PairedMoonlightHost: Hashable, Sendable {
    let hostname: String
    let localAddress: String
    let localPort: Int
    let manualAddress: String
    let manualPort: Int
    let isPaired: Bool

    var effectiveDirectAddress: String? {
        for raw in [manualAddress, localAddress] {
            let addr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !addr.isEmpty, addr != "127.0.0.1", addr != "localhost" {
                return addr
            }
        }
        return nil
    }

    var effectiveHTTPPort: Int {
        if manualPort > 0 { return manualPort }
        if localPort > 0 { return localPort }
        return 47989
    }
}

enum MoonlightLauncher {
    private static let candidateAppBundlePaths: [String] = [
        "/Applications/Moonlight V+.app",
        "/Applications/Moonlight V+ for PC.app",
        "/Applications/Moonlight.app"
    ]

    static var appBundlePath: String {
        for candidate in candidateAppBundlePaths where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return "/Applications/Moonlight.app"
    }

    static var executablePath: String {
        "\(appBundlePath)/Contents/MacOS/Moonlight"
    }

    static var candidatePreferencesPlistURLs: [URL] {
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        return [
            prefs.appendingPathComponent("com.alkaidlab.vpluspc.plist"),
            prefs.appendingPathComponent("com.moonlight-stream.Moonlight.plist")
        ]
    }

    static var preferencesPlistURL: URL {
        for url in candidatePreferencesPlistURLs where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return candidatePreferencesPlistURLs.last!
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    static func discoverPairedHosts() -> [PairedMoonlightHost] {
        var merged: [PairedMoonlightHost] = []
        var seenHostnames = Set<String>()
        for url in candidatePreferencesPlistURLs {
            for host in discoverPairedHosts(plistURL: url) {
                let key = host.hostname.lowercased()
                if seenHostnames.insert(key).inserted {
                    merged.append(host)
                }
            }
        }
        return merged
    }

    static func discoverPairedHosts(plistURL: URL) -> [PairedMoonlightHost] {
        guard let data = try? Data(contentsOf: plistURL),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            return []
        }

        let size = (dict["hosts.size"] as? Int)
            ?? (dict["hosts.size"] as? NSNumber)?.intValue
            ?? 0
        guard size > 0 else { return [] }

        var results: [PairedMoonlightHost] = []
        for idx in 1...size {
            let prefix = "hosts.\(idx)."
            guard let hostname = (dict["\(prefix)hostname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hostname.isEmpty
            else { continue }

            let localAddress = (dict["\(prefix)localaddress"] as? String) ?? ""
            let localPort = (dict["\(prefix)localport"] as? Int)
                ?? (dict["\(prefix)localport"] as? NSNumber)?.intValue
                ?? 0
            let manualAddress = (dict["\(prefix)manualaddress"] as? String) ?? ""
            let manualPort = (dict["\(prefix)manualport"] as? Int)
                ?? (dict["\(prefix)manualport"] as? NSNumber)?.intValue
                ?? 0
            let certData = dict["\(prefix)srvcert"] as? Data
            let isPaired = (certData?.isEmpty == false)

            results.append(
                PairedMoonlightHost(
                    hostname: hostname,
                    localAddress: localAddress,
                    localPort: localPort,
                    manualAddress: manualAddress,
                    manualPort: manualPort,
                    isPaired: isPaired
                )
            )
        }
        return results
    }

    @discardableResult
    static func streamDesktop(host: String, appName: String = "Desktop") -> String? {
        guard isInstalled else {
            return "Moonlight.app is not installed in /Applications."
        }
        // Launch via LaunchServices (NSWorkspace) instead of Process() so macOS sets
        // Moonlight.app as its own TCC Responsible Process rather than inheriting NodeDeck
        // (which lacks Moonlight's NSMicrophoneUsageDescription and would trigger a TCC crash).
        let appURL = URL(fileURLWithPath: appBundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["stream", host, appName]
        config.createsNewApplicationInstance = true
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        return nil
    }

    @discardableResult
    static func openMoonlightApp() -> String? {
        guard FileManager.default.fileExists(atPath: appBundlePath) else {
            return "Moonlight.app is not installed in /Applications."
        }
        let url = URL(fileURLWithPath: appBundlePath)
        if NSWorkspace.shared.open(url) {
            return nil
        }
        return "Unable to open /Applications/Moonlight.app"
    }

    static func openSunshineWebUI(urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    static func openSunshineWebUI(port: Int = 47990) {
        openSunshineWebUI(urlString: "https://127.0.0.1:\(port)")
    }
}
