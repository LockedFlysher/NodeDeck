import AppKit
import Foundation
import SSHDeckCore

struct PairedMoonlightHost: Hashable, Sendable {
    let hostname: String
    let localAddress: String
    let localPort: Int
    let manualAddress: String
    let manualPort: Int
    let isPaired: Bool

    var effectiveDirectAddress: String? {
        let addr = localAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty, addr != "127.0.0.1", addr != "localhost" else { return nil }
        return addr
    }

    var effectiveHTTPPort: Int {
        if manualPort > 0 { return manualPort }
        if localPort > 0 { return localPort }
        return 47989
    }
}

enum MoonlightLauncher {
    static let appBundlePath = "/Applications/Moonlight.app"
    static let executablePath = "/Applications/Moonlight.app/Contents/MacOS/Moonlight"

    static var preferencesPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.moonlight-stream.Moonlight.plist")
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    static func discoverPairedHosts(plistURL: URL = preferencesPlistURL) -> [PairedMoonlightHost] {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["stream", host, appName]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return nil
        } catch {
            return "Failed to launch Moonlight stream: \(error.localizedDescription)"
        }
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
