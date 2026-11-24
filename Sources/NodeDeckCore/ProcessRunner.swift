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

public enum NetworkProbe {
    public static func isTCPPortOpen(host: String = "127.0.0.1", port: Int, timeoutMs: Int32 = 250) -> Bool {
        guard port > 0 && port <= 65535 else { return false }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let polled = poll(&pfd, 1, timeoutMs)
        guard polled > 0 else { return false }

        var sockErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &len) == 0 else {
            return false
        }
        return sockErr == 0
    }
}
