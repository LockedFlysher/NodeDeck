import Darwin
import Foundation

public enum RemoteMetricsCollector {
    private static var controlSocketDirectory: String {
        "/tmp/ndmux-\(getuid())"
    }

    private static var controlPathTemplate: String {
        "\(controlSocketDirectory)/%C"
    }

    private static func ensureControlDirectory() {
        let dir = controlSocketDirectory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private static func evictMuxSocket(for alias: String) {
        _ = ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-O", "exit",
                "-o", "ControlPath=\(controlPathTemplate)",
                alias
            ],
            timeout: 2
        )
    }

    private static func measureTcpRttMs(host: String, port: Int, timeoutMs: Int32 = 2500) -> Double? {
        guard !host.isEmpty else { return nil }
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(max(1, min(65535, port)))
        guard getaddrinfo(host, portStr, &hints, &res) == 0, let addrList = res else {
            return nil
        }
        defer { freeaddrinfo(addrList) }

        let fd = socket(addrList.pointee.ai_family, addrList.pointee.ai_socktype, addrList.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let startedAt = Date()
        let rc = connect(fd, addrList.pointee.ai_addr, addrList.pointee.ai_addrlen)
        if rc == 0 {
            return max(1.0, Date().timeIntervalSince(startedAt) * 1000.0)
        }
        guard errno == EINPROGRESS else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        guard pr > 0 else { return nil }

        var soErr: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen) == 0, soErr == 0 else {
            return nil
        }
        return max(1.0, Date().timeIntervalSince(startedAt) * 1000.0)
    }

    public static func collect(
        host: SSHHost,
        timeout: TimeInterval = 16
    ) async -> HostProbeResult {
        await Task.detached(priority: .utility) {
            ensureControlDirectory()
            let startedAt = Date()
            let result = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-T",
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(controlPathTemplate)",
                    "-o", "ControlPersist=60",
                    "-o", "ConnectTimeout=5",
                    "-o", "ConnectionAttempts=1",
                    "-o", "ServerAliveInterval=4",
                    "-o", "ServerAliveCountMax=1",
                    "-o", "ClearAllForwardings=yes",
                    "-o", "LogLevel=ERROR",
                    host.alias,
                    "/bin/sh", "-s"
                ],
                input: metricsScript,
                timeout: timeout
            )
            let totalElapsedMs = Date().timeIntervalSince(startedAt) * 1_000

            if result.timedOut {
                evictMuxSocket(for: host.alias)
                return HostProbeResult(
                    metrics: nil,
                    latencyMilliseconds: totalElapsedMs,
                    errorMessage: "Connection timed out"
                )
            }

            if let metrics = RemoteMetricsParser.parse(result.stdout) {
                let warmTcpRtt: Double? = (host.proxyJump == nil)
                    ? measureTcpRttMs(host: host.hostName, port: host.port)
                    : nil
                let scriptMs = metrics.scriptDurationMilliseconds ?? 0
                let effectiveRTT = warmTcpRtt ?? max(1, totalElapsedMs - scriptMs)
                return HostProbeResult(
                    metrics: metrics,
                    latencyMilliseconds: effectiveRTT,
                    errorMessage: nil
                )
            }

            evictMuxSocket(for: host.alias)
            let error = meaningfulError(from: result.stderr)
            return HostProbeResult(
                metrics: nil,
                latencyMilliseconds: totalElapsedMs,
                errorMessage: error ?? "Remote metrics collection failed"
            )
        }.value
    }

    private static func meaningfulError(from stderr: String) -> String? {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let last = lines.last {
            let localized: String
            switch true {
            case last.localizedCaseInsensitiveContains("operation timed out"),
                 last.localizedCaseInsensitiveContains("connection timed out"):
                localized = "Connection timed out"
            case last.localizedCaseInsensitiveContains("connection refused"):
                localized = "Connection refused (check tunnel or sshd)"
            case last.localizedCaseInsensitiveContains("permission denied"):
                localized = "Authentication failed or permission denied"
            case last.localizedCaseInsensitiveContains("no route to host"),
                 last.localizedCaseInsensitiveContains("network is unreachable"):
                localized = "Network unreachable"
            case last.localizedCaseInsensitiveContains("could not resolve hostname"):
                localized = "Could not resolve hostname"
            case last.localizedCaseInsensitiveContains("host key verification failed"):
                localized = "Host key verification failed"
            case last.localizedCaseInsensitiveContains("connection closed"):
                localized = "Connection closed by remote"
            default:
                localized = last
            }

            if localized.count > 180 {
                return String(localized.prefix(177)) + "..."
            }
            return localized
        }
        return nil
    }

    static let metricsScript = #"""
printf 'NODEDECK_BEGIN\n'
t_start=$(awk '{print $1}' /proc/uptime 2>/dev/null)
printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null)"
printf 'OS=%s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-$(uname -s 2>/dev/null || printf Linux)}}")"
printf 'KERNEL=%s\n' "$(uname -sr 2>/dev/null)"
printf 'ARCH=%s\n' "$(uname -m 2>/dev/null)"
printf 'USER=%s\n' "$(id -un 2>/dev/null)"
printf 'HOME_DIR=%s\n' "${HOME:-}"
if [ -n "${HOME:-}" ]; then
  for cand in project projects PycharmProjects workspace code server Documents Downloads; do
    if [ -d "$HOME/$cand" ]; then
      printf 'CANDIDATE_DIR=%s/%s\n' "$HOME" "$cand"
    fi
  done
fi
printf 'CPU_MODEL=%s\n' "$(awk -F: '/model name|Model/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
printf 'CPU_CORES=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 0)"
set -- $(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat 2>/dev/null)
cpu_total_1=$(( ${1:-0} + ${2:-0} + ${3:-0} + ${4:-0} + ${5:-0} + ${6:-0} + ${7:-0} + ${8:-0} ))
cpu_idle_1=$(( ${4:-0} + ${5:-0} ))
sleep 0.25 2>/dev/null || sleep 1
set -- $(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat 2>/dev/null)
cpu_total_2=$(( ${1:-0} + ${2:-0} + ${3:-0} + ${4:-0} + ${5:-0} + ${6:-0} + ${7:-0} + ${8:-0} ))
cpu_idle_2=$(( ${4:-0} + ${5:-0} ))
printf 'CPU_USAGE=%s\n' "$(awk -v t1="$cpu_total_1" -v i1="$cpu_idle_1" -v t2="$cpu_total_2" -v i2="$cpu_idle_2" 'BEGIN { dt=t2-t1; di=i2-i1; if (dt > 0) printf "%.1f", 100*(dt-di)/dt; else printf "0.0" }')"
set -- $(cat /proc/loadavg 2>/dev/null)
printf 'LOAD1=%s\n' "${1:-0}"
printf 'LOAD5=%s\n' "${2:-0}"
printf 'LOAD15=%s\n' "${3:-0}"
printf 'UPTIME_SECONDS=%s\n' "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)"
mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
mem_available_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
if [ -z "$mem_available_kb" ]; then
  mem_available_kb=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
fi
swap_total_kb=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
swap_free_kb=$(awk '/^SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
printf 'MEM_TOTAL=%s\n' "$(( ${mem_total_kb:-0} * 1024 ))"
printf 'MEM_AVAILABLE=%s\n' "$(( ${mem_available_kb:-0} * 1024 ))"
printf 'SWAP_TOTAL=%s\n' "$(( ${swap_total_kb:-0} * 1024 ))"
printf 'SWAP_FREE=%s\n' "$(( ${swap_free_kb:-0} * 1024 ))"
df -Pk / 2>/dev/null | awk 'NR==2 {printf "DISK_TOTAL=%d\nDISK_USED=%d\nDISK_AVAILABLE=%d\n", $2*1024, $3*1024, $4*1024}'
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | while IFS= read -r gpu_line; do
    [ -n "$gpu_line" ] && printf 'GPU=%s, active\n' "$gpu_line"
  done
fi
for card_dev in /sys/class/drm/card[0-9]*/device; do
  [ -f "$card_dev/vendor" ] || continue
  vendor=$(cat "$card_dev/vendor" 2>/dev/null)
  [ "$vendor" = "0x1002" ] || continue
  dev_id=$(cat "$card_dev/device" 2>/dev/null | tr 'A-F' 'a-f')
  slot=$(awk -F= '/^PCI_SLOT_NAME=/ {print $2}' "$card_dev/uevent" 2>/dev/null)
  gpu_name=$(cat "$card_dev/product_name" 2>/dev/null)
  if [ -z "$gpu_name" ] && [ -n "$slot" ] && command -v lspci >/dev/null 2>&1; then
    pci_desc=$(lspci -s "${slot#0000:}" 2>/dev/null | sed 's/^[^:]*: [^:]*: //')
    bracket=$(printf '%s' "$pci_desc" | sed -n 's/.*\[\(Radeon[^]]*\)\].*/AMD \1/p')
    [ -n "$bracket" ] && gpu_name="$bracket"
  fi
  if [ -z "$gpu_name" ]; then
    case "$dev_id" in
      0x7590) gpu_name="AMD Radeon RX 9060 XT" ;;
      0x7550) gpu_name="AMD Radeon RX 9070 XT" ;;
      0x7551) gpu_name="AMD Radeon RX 9070" ;;
      0x744c) gpu_name="AMD Radeon RX 7900 XTX" ;;
      0x7448) gpu_name="AMD Radeon PRO W7900" ;;
      0x747e) gpu_name="AMD Radeon RX 7800 XT" ;;
      0x7480) gpu_name="AMD Radeon RX 7700 XT" ;;
      *) gpu_name="AMD Radeon GPU ($dev_id)" ;;
    esac
  fi
  pstate=$(cat "$card_dev/power/runtime_status" 2>/dev/null)
  util=$(cat "$card_dev/gpu_busy_percent" 2>/dev/null)
  if [ -z "$util" ] && [ "$pstate" = "suspended" ]; then
    util="0"
  fi
  vram_used=""
  vram_total=""
  [ -f "$card_dev/mem_info_vram_used" ] && vram_used=$(awk '{printf "%.0f", $1/1048576}' "$card_dev/mem_info_vram_used" 2>/dev/null)
  [ -f "$card_dev/mem_info_vram_total" ] && vram_total=$(awk '{printf "%.0f", $1/1048576}' "$card_dev/mem_info_vram_total" 2>/dev/null)
  temp=""
  pwr=""
  for hm in "$card_dev"/hwmon/hwmon*; do
    [ -d "$hm" ] || continue
    t_raw=$(cat "$hm/temp1_input" 2>/dev/null)
    [ -n "$t_raw" ] && temp=$(awk -v v="$t_raw" 'BEGIN {printf "%.0f", v/1000}')
    p_raw=$(cat "$hm/power1_average" 2>/dev/null || cat "$hm/power1_input" 2>/dev/null)
    [ -n "$p_raw" ] && pwr=$(awk -v v="$p_raw" 'BEGIN {printf "%.1f", v/1000000}')
    break
  done
  printf 'GPU=%s, %s, %s, %s, %s, %s, %s\n' "$gpu_name" "${util:-N/A}" "${vram_used:-N/A}" "${vram_total:-N/A}" "${temp:-N/A}" "${pwr:-N/A}" "${pstate:-active}"
done
if command -v sinfo >/dev/null 2>&1; then
  printf 'SLURM=1\n'
  sinfo -h -N -o '%N|%P|%T|%C|%m|%G|%f' 2>/dev/null | awk -F'|' '{ nodes[$1]=$0 } END { for (node in nodes) print "SLURM_NODE=" nodes[node] }'
fi
ps -ww -eo pcpu=,pmem=,args= --sort=-pcpu 2>/dev/null | head -n 5 | awk 'NF >= 3 { cpu=$1; mem=$2; $1=""; $2=""; sub(/^[[:space:]]+/, ""); gsub(/\|/, " "); if (length($0) > 220) $0 = substr($0, 1, 217) "..."; printf "PROC=%s|%s|%s\n", $0, cpu, mem }'
t_end=$(awk '{print $1}' /proc/uptime 2>/dev/null)
if [ -n "$t_start" ] && [ -n "$t_end" ]; then
  awk -v s="$t_start" -v e="$t_end" 'BEGIN { d=(e-s)*1000; if (d >= 0) printf "SCRIPT_MS=%.1f\n", d }'
fi
printf 'NODEDECK_END\n'
"""#
}

public enum RemoteMetricsParser {
    public static func parse(_ output: String, capturedAt: Date = Date()) -> HostMetrics? {
        let hasNodeDeckMarkers = output.contains("NODEDECK_BEGIN") && output.contains("NODEDECK_END")
        let hasLegacyMarkers = output.contains("SSHDECK_BEGIN") && output.contains("SSHDECK_END")
        guard hasNodeDeckMarkers || hasLegacyMarkers else {
            return nil
        }

        var values: [String: String] = [:]
        var gpuLines: [String] = []
        var processLines: [String] = []
        var slurmNodeLines: [String] = []
        var candidateDirs: [String] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])

            switch key {
            case "GPU":
                gpuLines.append(value)
            case "PROC":
                processLines.append(value)
            case "SLURM_NODE":
                slurmNodeLines.append(value)
            case "CANDIDATE_DIR":
                if !value.isEmpty {
                    candidateDirs.append(value)
                }
            default:
                values[key] = value
            }
        }

        guard let hostname = values["HOSTNAME"], !hostname.isEmpty else {
            return nil
        }

        let slurmNodes = slurmNodeLines.compactMap(parseSlurmNode)
        let slurm = values["SLURM"] == "1" && !slurmNodes.isEmpty
            ? SlurmInfo(nodes: slurmNodes)
            : nil

        return HostMetrics(
            hostname: hostname,
            osName: values["OS"] ?? "Linux",
            kernel: values["KERNEL"] ?? "",
            architecture: values["ARCH"] ?? "",
            user: values["USER"] ?? "",
            homeDirectory: values["HOME_DIR"] ?? "",
            candidateDirectories: candidateDirs,
            cpuModel: values["CPU_MODEL"] ?? "",
            cpuCores: Int(values["CPU_CORES"] ?? "") ?? 0,
            cpuUsage: Double(values["CPU_USAGE"] ?? "") ?? 0,
            load1: Double(values["LOAD1"] ?? "") ?? 0,
            load5: Double(values["LOAD5"] ?? "") ?? 0,
            load15: Double(values["LOAD15"] ?? "") ?? 0,
            memoryTotal: UInt64(values["MEM_TOTAL"] ?? "") ?? 0,
            memoryAvailable: UInt64(values["MEM_AVAILABLE"] ?? "") ?? 0,
            swapTotal: UInt64(values["SWAP_TOTAL"] ?? "") ?? 0,
            swapFree: UInt64(values["SWAP_FREE"] ?? "") ?? 0,
            diskTotal: UInt64(values["DISK_TOTAL"] ?? "") ?? 0,
            diskUsed: UInt64(values["DISK_USED"] ?? "") ?? 0,
            diskAvailable: UInt64(values["DISK_AVAILABLE"] ?? "") ?? 0,
            uptimeSeconds: TimeInterval(values["UPTIME_SECONDS"] ?? "") ?? 0,
            gpus: gpuLines.compactMap(parseGPU),
            processes: processLines.compactMap(parseProcess),
            slurm: slurm,
            scriptDurationMilliseconds: Double(values["SCRIPT_MS"] ?? ""),
            capturedAt: capturedAt
        )
    }

    private static func parseGPU(_ rawLine: String) -> GPUInfo? {
        let fields = rawLine.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = fields.first, !name.isEmpty else { return nil }

        func number(at index: Int) -> Double? {
            guard fields.indices.contains(index) else { return nil }
            let value = fields[index]
            guard value != "[N/A]", value != "N/A", !value.isEmpty else { return nil }
            return Double(value)
        }

        let stateField = fields.indices.contains(6) ? fields[6].lowercased() : ""
        let isSleeping = stateField == "suspended"

        return GPUInfo(
            name: name,
            utilization: number(at: 1),
            memoryUsedMB: number(at: 2),
            memoryTotalMB: number(at: 3),
            temperatureC: number(at: 4),
            powerW: number(at: 5),
            isSleeping: isSleeping
        )
    }

    private static func parseProcess(_ rawLine: String) -> RemoteProcess? {
        let fields = rawLine.split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 3, !fields[0].isEmpty else { return nil }
        return RemoteProcess(
            name: fields[0],
            cpuPercent: Double(fields[1]) ?? 0,
            memoryPercent: Double(fields[2]) ?? 0
        )
    }

    private static func parseSlurmNode(_ rawLine: String) -> SlurmNode? {
        let fields = rawLine.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 7, !fields[0].isEmpty else { return nil }

        let cpuParts = fields[3].split(separator: "/").compactMap { Int($0) }
        guard cpuParts.count >= 4 else { return nil }

        let partition = fields[1].hasSuffix("*")
            ? String(fields[1].dropLast())
            : fields[1]

        return SlurmNode(
            name: fields[0],
            partition: partition,
            state: fields[2],
            allocatedCPUs: cpuParts[0],
            idleCPUs: cpuParts[1],
            otherCPUs: cpuParts[2],
            totalCPUs: cpuParts[3],
            memoryMB: UInt64(fields[4]) ?? 0,
            gres: fields[5],
            features: fields[6]
        )
    }
}
