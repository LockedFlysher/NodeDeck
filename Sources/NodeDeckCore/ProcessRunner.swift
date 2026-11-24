import Darwin
import Foundation

public struct ProcessRunResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
    public let timedOut: Bool

    public init(stdout: String, stderr: String, status: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.timedOut = timedOut
    }
}

public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        discardOutput: Bool = false,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if discardOutput {
            process.standardOutput = FileHandle.nullDevice
        } else {
            process.standardOutput = outputPipe
        }
        process.standardError = errorPipe

        if input != nil {
            process.standardInput = inputPipe
        }

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !currentPath.contains("/opt/homebrew/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(currentPath)"
        }
        process.environment = environment

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                stdout: "",
                stderr: error.localizedDescription,
                status: -1,
                timedOut: false
            )
        }

        if let input {
            let writeFD = inputPipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let ioGroup = DispatchGroup()

        if !discardOutput {
            ioGroup.enter()
            let outHandle = outputPipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                stdoutBox.data = (try? outHandle.readToEnd()) ?? Data()
                ioGroup.leave()
            }
        }

        ioGroup.enter()
        let errHandle = errorPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = (try? errHandle.readToEnd()) ?? Data()
            ioGroup.leave()
        }

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        var timedOut = false
        if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if waitGroup.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waitGroup.wait(timeout: .now() + 1)
            }
        }

        _ = ioGroup.wait(timeout: .now() + 1.5)

        return ProcessRunResult(
            stdout: String(decoding: stdoutBox.data, as: UTF8.self),
            stderr: String(decoding: stderrBox.data, as: UTF8.self),
            status: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
