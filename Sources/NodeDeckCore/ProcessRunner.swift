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

/// Pure-POSIX subprocess runner using `posix_spawn` + `POSIX_SPAWN_CLOEXEC_DEFAULT` + non-blocking `poll()`.
///
/// Avoids Foundation `Process` (`NSConcreteTask.waitUntilExit`) and `Pipe`/`NSFileHandle` entirely:
/// - Spawns zero extra GCD threads per invocation.
/// - Guarantees deterministic `defer` closure of every pipe FD (immune to FD exhaustion / `_NSFileHandleIsClosed` crashes).
/// - Prevents unrelated FDs from leaking into child processes (including background `ssh ControlPersist` masters).
/// - Never blocks 60s when an `ssh` ControlMaster grandchild keeps stdout/stderr inherited after the direct child exits.
public enum ProcessRunner {
    private static let maxCapturedBytes = 4 * 1024 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        discardOutput: Bool = false,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]

        func closeIfValid(_ fd: inout Int32) {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }

        defer {
            closeIfValid(&inPipe[0])
            closeIfValid(&inPipe[1])
            closeIfValid(&outPipe[0])
            closeIfValid(&outPipe[1])
            closeIfValid(&errPipe[0])
            closeIfValid(&errPipe[1])
        }

        if input != nil {
            guard pipe(&inPipe) == 0 else {
                return ProcessRunResult(stdout: "", stderr: posixErrorString("pipe(stdin)"), status: -1, timedOut: false)
            }
            _ = fcntl(inPipe[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
        }

        if !discardOutput {
            guard pipe(&outPipe) == 0 else {
                return ProcessRunResult(stdout: "", stderr: posixErrorString("pipe(stdout)"), status: -1, timedOut: false)
            }
            _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(outPipe[1], F_SETFD, FD_CLOEXEC)
        }

        guard pipe(&errPipe) == 0 else {
            return ProcessRunResult(stdout: "", stderr: posixErrorString("pipe(stderr)"), status: -1, timedOut: false)
        }
        _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(errPipe[1], F_SETFD, FD_CLOEXEC)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if input != nil {
            posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }

        if discardOutput {
            posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        } else {
            posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        }
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        defer { posix_spawnattr_destroy(&spawnAttr) }
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        // Build argv & envp C string arrays
        let argvStrings = [executable] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        cArgv.append(nil)
        defer {
            for ptr in cArgv { free(ptr) }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !currentPath.contains("/opt/homebrew/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(currentPath)"
        }
        var cEnvp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvp.append(nil)
        defer {
            for ptr in cEnvp { free(ptr) }
        }

        var childPid: pid_t = 0
        let spawnStatus: Int32 = executable.withCString { execPtr in
            cArgv.withUnsafeMutableBufferPointer { argvBuf in
                cEnvp.withUnsafeMutableBufferPointer { envpBuf in
                    posix_spawn(&childPid, execPtr, &fileActions, &spawnAttr, argvBuf.baseAddress, envpBuf.baseAddress)
                }
            }
        }

        if spawnStatus != 0 {
            let msg = String(cString: strerror(spawnStatus))
            return ProcessRunResult(stdout: "", stderr: "Failed to launch \(executable): \(msg)", status: -1, timedOut: false)
        }

        // Close child ends in parent immediately
        closeIfValid(&inPipe[0])
        closeIfValid(&outPipe[1])
        closeIfValid(&errPipe[1])

        // Make parent ends non-blocking
        if inPipe[1] >= 0 {
            _ = fcntl(inPipe[1], F_SETFL, fcntl(inPipe[1], F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        }
        if outPipe[0] >= 0 {
            _ = fcntl(outPipe[0], F_SETFL, fcntl(outPipe[0], F_GETFL, 0) | O_NONBLOCK)
        }
        if errPipe[0] >= 0 {
            _ = fcntl(errPipe[0], F_SETFL, fcntl(errPipe[0], F_GETFL, 0) | O_NONBLOCK)
        }

        let inputBytes: [UInt8] = input.map { Array($0.utf8) } ?? []
        var inputOffset = 0
        if inputBytes.isEmpty && inPipe[1] >= 0 {
            closeIfValid(&inPipe[1])
        }

        var stdoutData = Data()
        var stderrData = Data()
        var readBuf = [UInt8](repeating: 0, count: 8192)

        let startNs = DispatchTime.now().uptimeNanoseconds
        let timeoutNs = UInt64(max(0.05, timeout) * 1_000_000_000)
        let deadlineNs = startNs &+ timeoutNs

        var childExited = false
        var waitStatus: Int32 = 0
        var postExitDeadlineNs: UInt64 = 0
        var timedOut = false

        func reapNonBlocking() {
            guard !childExited else { return }
            let r = waitpid(childPid, &waitStatus, WNOHANG)
            if r == childPid {
                childExited = true
                // Allow a short 60ms drain window for buffered pipe data; do not hang if a ControlPersist grandchild holds FDs open.
                postExitDeadlineNs = DispatchTime.now().uptimeNanoseconds &+ 60_000_000
            } else if r < 0 && errno == ECHILD {
                childExited = true
                postExitDeadlineNs = DispatchTime.now().uptimeNanoseconds
            }
        }

        while true {
            reapNonBlocking()

            let nowNs = DispatchTime.now().uptimeNanoseconds
            if !childExited && nowNs >= deadlineNs {
                timedOut = true
                break
            }
            if childExited {
                let anyOpenPipe = outPipe[0] >= 0 || errPipe[0] >= 0
                if !anyOpenPipe || nowNs >= postExitDeadlineNs {
                    break
                }
            }

            var pfds: [pollfd] = []
            var roles: [Int] = [] // 0 = stdin, 1 = stdout, 2 = stderr
            if inPipe[1] >= 0 {
                pfds.append(pollfd(fd: inPipe[1], events: Int16(POLLOUT), revents: 0))
                roles.append(0)
            }
            if outPipe[0] >= 0 {
                pfds.append(pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0))
                roles.append(1)
            }
            if errPipe[0] >= 0 {
                pfds.append(pollfd(fd: errPipe[0], events: Int16(POLLIN), revents: 0))
                roles.append(2)
            }

            let targetDeadline = childExited ? postExitDeadlineNs : deadlineNs
            let remainingMs: Int32
            if nowNs >= targetDeadline {
                remainingMs = 0
            } else {
                let diffMs = (targetDeadline - nowNs) / 1_000_000
                remainingMs = Int32(min(diffMs, 40))
            }

            if pfds.isEmpty {
                if childExited { break }
                usleep(UInt32(max(1, remainingMs)) * 1000)
                continue
            }

            let polled = pfds.withUnsafeMutableBufferPointer { buf in
                poll(buf.baseAddress, nfds_t(buf.count), max(1, remainingMs))
            }

            if polled < 0 {
                if errno == EINTR { continue }
                break
            }
            if polled == 0 {
                continue
            }

            for i in 0..<pfds.count {
                let revents = pfds[i].revents
                guard revents != 0 else { continue }
                switch roles[i] {
                case 0: // stdin write
                    if (revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                        closeIfValid(&inPipe[1])
                        continue
                    }
                    if (revents & Int16(POLLOUT)) != 0 && inputOffset < inputBytes.count {
                        let written = inputBytes.withUnsafeBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return 0 }
                            return Darwin.write(inPipe[1], base.advanced(by: inputOffset), inputBytes.count - inputOffset)
                        }
                        if written > 0 {
                            inputOffset += written
                            if inputOffset >= inputBytes.count {
                                closeIfValid(&inPipe[1])
                            }
                        } else if written < 0 && errno != EAGAIN && errno != EINTR {
                            closeIfValid(&inPipe[1])
                        }
                    }

                case 1: // stdout read
                    let n = readBuf.withUnsafeMutableBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return Darwin.read(outPipe[0], base, raw.count)
                    }
                    if n > 0 {
                        if stdoutData.count < maxCapturedBytes {
                            let toAppend = min(n, maxCapturedBytes - stdoutData.count)
                            stdoutData.append(readBuf, count: toAppend)
                        }
                    } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                        closeIfValid(&outPipe[0])
                    }

                case 2: // stderr read
                    let n = readBuf.withUnsafeMutableBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return Darwin.read(errPipe[0], base, raw.count)
                    }
                    if n > 0 {
                        if stderrData.count < maxCapturedBytes {
                            let toAppend = min(n, maxCapturedBytes - stderrData.count)
                            stderrData.append(readBuf, count: toAppend)
                        }
                    } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                        closeIfValid(&errPipe[0])
                    }

                default:
                    break
                }
            }
        }

        // Terminate & deterministically reap child if timed out
        if !childExited {
            _ = kill(childPid, SIGTERM)
            let termDeadline = DispatchTime.now().uptimeNanoseconds &+ 400_000_000
            while !childExited && DispatchTime.now().uptimeNanoseconds < termDeadline {
                reapNonBlocking()
                if !childExited { usleep(15_000) }
            }
            if !childExited {
                _ = kill(childPid, SIGKILL)
                while waitpid(childPid, &waitStatus, 0) < 0 && errno == EINTR {}
                childExited = true
            }
        }

        let exitStatus: Int32
        if (waitStatus & 0x7f) == 0 {
            exitStatus = (waitStatus >> 8) & 0xff
        } else {
            exitStatus = 128 + (waitStatus & 0x7f)
        }

        return ProcessRunResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            status: timedOut ? -1 : exitStatus,
            timedOut: timedOut
        )
    }

    private static func posixErrorString(_ context: String) -> String {
        "\(context): \(String(cString: strerror(errno)))"
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
