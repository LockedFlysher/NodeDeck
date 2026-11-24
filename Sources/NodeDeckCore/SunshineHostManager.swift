import Darwin
import Foundation

public enum SunshineHostState: String, Equatable, Sendable {
    case notInstalled
    case stopped
    case running
}

public final class SunshineHostManager: @unchecked Sendable {
    public static let shared = SunshineHostManager()

    private let lock = NSLock()
    private var managedProcess: Process?

    private init() {}

    public static var candidateBinaries: [String] {
        var paths: [String] = []
        if let bundlePath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sunshine").path as String? {
            paths.append(bundlePath)
        }
        paths.append(contentsOf: [
            "/opt/foundation-sunshine/bin/sunshine",
            "/opt/homebrew/bin/sunshine",
            "/usr/local/bin/sunshine",
            "/usr/bin/sunshine"
        ])
        return paths
    }

    public static func findBinary() -> String? {
        candidateBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func currentState() -> SunshineHostState {
        guard Self.findBinary() != nil else { return .notInstalled }
        let isManagedRunning = lock.withLock { managedProcess?.isRunning == true }
        if isManagedRunning { return .running }

        let pgrep = ProcessRunner.run(executable: "/usr/bin/pgrep", arguments: ["-x", "sunshine"], timeout: 2)
        return pgrep.status == 0 ? .running : .stopped
    }

    @discardableResult
    public func startHost() throws -> Int32 {
        guard let bin = Self.findBinary() else {
            throw SunshineError.launchFailed("Sunshine host binary not installed. Install via `brew install LizardByte/homebrew/sunshine`.")
        }
        if currentState() == .running {
            return lock.withLock { managedProcess?.processIdentifier ?? 0 }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        try proc.run()
        lock.withLock {
            managedProcess = proc
        }
        return proc.processIdentifier
    }

    public func stopHost() {
        let proc = lock.withLock { () -> Process? in
            let p = managedProcess
            managedProcess = nil
            return p
        }
        if let proc, proc.isRunning {
            proc.terminate()
        } else {
            _ = ProcessRunner.run(executable: "/usr/bin/pkill", arguments: ["-x", "sunshine"], timeout: 3)
        }
    }
}
