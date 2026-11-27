package com.nodedeck.android.core

object RemoteMetricsParser {
    val metricsScript: String = """
printf 'NODEDECK_BEGIN\n'
t_start=${'$'}(awk '{print ${'$'}1}' /proc/uptime 2>/dev/null)
printf 'HOSTNAME=%s\n' "${'$'}(hostname 2>/dev/null)"
printf 'OS=%s\n' "${'$'}(. /etc/os-release 2>/dev/null; printf '%s' "${'$'}{PRETTY_NAME:-${'$'}{NAME:-${'$'}(uname -s 2>/dev/null || printf Linux)}}")"
printf 'KERNEL=%s\n' "${'$'}(uname -sr 2>/dev/null)"
printf 'ARCH=%s\n' "${'$'}(uname -m 2>/dev/null)"
printf 'USER=%s\n' "${'$'}(id -un 2>/dev/null)"
printf 'HOME_DIR=%s\n' "${'$'}{HOME:-}"
if [ -n "${'$'}{HOME:-}" ]; then
  for cand in project projects PycharmProjects workspace code server Documents Downloads; do
    if [ -d "${'$'}HOME/${'$'}cand" ]; then
      printf 'CANDIDATE_DIR=%s/%s\n' "${'$'}HOME" "${'$'}cand"
    fi
  done
fi
printf 'CPU_MODEL=%s\n' "${'$'}(awk -F: '/model name|Model/ {gsub(/^ +/, "", ${'$'}2); print ${'$'}2; exit}' /proc/cpuinfo 2>/dev/null)"
printf 'CPU_CORES=%s\n' "${'$'}(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 0)"
set -- ${'$'}(awk '/^cpu / {print ${'$'}2,${'$'}3,${'$'}4,${'$'}5,${'$'}6,${'$'}7,${'$'}8,${'$'}9; exit}' /proc/stat 2>/dev/null)
cpu_total_1=${'$'}(( ${'$'}{1:-0} + ${'$'}{2:-0} + ${'$'}{3:-0} + ${'$'}{4:-0} + ${'$'}{5:-0} + ${'$'}{6:-0} + ${'$'}{7:-0} + ${'$'}{8:-0} ))
cpu_idle_1=${'$'}(( ${'$'}{4:-0} + ${'$'}{5:-0} ))
sleep 0.25 2>/dev/null || sleep 1
set -- ${'$'}(awk '/^cpu / {print ${'$'}2,${'$'}3,${'$'}4,${'$'}5,${'$'}6,${'$'}7,${'$'}8,${'$'}9; exit}' /proc/stat 2>/dev/null)
cpu_total_2=${'$'}(( ${'$'}{1:-0} + ${'$'}{2:-0} + ${'$'}{3:-0} + ${'$'}{4:-0} + ${'$'}{5:-0} + ${'$'}{6:-0} + ${'$'}{7:-0} + ${'$'}{8:-0} ))
cpu_idle_2=${'$'}(( ${'$'}{4:-0} + ${'$'}{5:-0} ))
printf 'CPU_USAGE=%s\n' "${'$'}(awk -v t1="${'$'}cpu_total_1" -v i1="${'$'}cpu_idle_1" -v t2="${'$'}cpu_total_2" -v i2="${'$'}cpu_idle_2" 'BEGIN { dt=t2-t1; di=i2-i1; if (dt > 0) printf "%.1f", 100*(dt-di)/dt; else printf "0.0" }')"
set -- ${'$'}(cat /proc/loadavg 2>/dev/null)
printf 'LOAD1=%s\n' "${'$'}{1:-0}"
printf 'LOAD5=%s\n' "${'$'}{2:-0}"
printf 'LOAD15=%s\n' "${'$'}{3:-0}"
printf 'UPTIME_SECONDS=%s\n' "${'$'}(awk '{printf "%d", ${'$'}1}' /proc/uptime 2>/dev/null)"
mem_total_kb=${'$'}(awk '/^MemTotal:/ {print ${'$'}2; exit}' /proc/meminfo 2>/dev/null)
mem_available_kb=${'$'}(awk '/^MemAvailable:/ {print ${'$'}2; exit}' /proc/meminfo 2>/dev/null)
if [ -z "${'$'}mem_available_kb" ]; then
  mem_available_kb=${'$'}(awk '/^MemFree:/ {print ${'$'}2; exit}' /proc/meminfo 2>/dev/null)
fi
swap_total_kb=${'$'}(awk '/^SwapTotal:/ {print ${'$'}2; exit}' /proc/meminfo 2>/dev/null)
swap_free_kb=${'$'}(awk '/^SwapFree:/ {print ${'$'}2; exit}' /proc/meminfo 2>/dev/null)
printf 'MEM_TOTAL=%s\n' "${'$'}(( ${'$'}{mem_total_kb:-0} * 1024 ))"
printf 'MEM_AVAILABLE=%s\n' "${'$'}(( ${'$'}{mem_available_kb:-0} * 1024 ))"
printf 'SWAP_TOTAL=%s\n' "${'$'}(( ${'$'}{swap_total_kb:-0} * 1024 ))"
printf 'SWAP_FREE=%s\n' "${'$'}(( ${'$'}{swap_free_kb:-0} * 1024 ))"
df -Pk / 2>/dev/null | awk 'NR==2 {printf "DISK_TOTAL=%d\nDISK_USED=%d\nDISK_AVAILABLE=%d\n", ${'$'}2*1024, ${'$'}3*1024, ${'$'}4*1024}'
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | while IFS= read -r gpu_line; do
    [ -n "${'$'}gpu_line" ] && printf 'GPU=%s, active\n' "${'$'}gpu_line"
  done
fi
for card_dev in /sys/class/drm/card[0-9]*/device; do
  [ -f "${'$'}card_dev/vendor" ] || continue
  vendor=${'$'}(cat "${'$'}card_dev/vendor" 2>/dev/null)
  [ "${'$'}vendor" = "0x1002" ] || continue
  dev_id=${'$'}(cat "${'$'}card_dev/device" 2>/dev/null | tr 'A-F' 'a-f')
  gpu_name=${'$'}(cat "${'$'}card_dev/product_name" 2>/dev/null)
  [ -z "${'$'}gpu_name" ] && gpu_name="AMD Radeon GPU (${'$'}dev_id)"
  pstate=${'$'}(cat "${'$'}card_dev/power/runtime_status" 2>/dev/null)
  util=${'$'}(cat "${'$'}card_dev/gpu_busy_percent" 2>/dev/null)
  if [ -z "${'$'}util" ] && [ "${'$'}pstate" = "suspended" ]; then util="0"; fi
  vram_used=""
  vram_total=""
  [ -f "${'$'}card_dev/mem_info_vram_used" ] && vram_used=${'$'}(awk '{printf "%.0f", ${'$'}1/1048576}' "${'$'}card_dev/mem_info_vram_used" 2>/dev/null)
  [ -f "${'$'}card_dev/mem_info_vram_total" ] && vram_total=${'$'}(awk '{printf "%.0f", ${'$'}1/1048576}' "${'$'}card_dev/mem_info_vram_total" 2>/dev/null)
  temp=""
  pwr=""
  for hm in "${'$'}card_dev"/hwmon/hwmon*; do
    [ -d "${'$'}hm" ] || continue
    t_raw=${'$'}(cat "${'$'}hm/temp1_input" 2>/dev/null)
    [ -n "${'$'}t_raw" ] && temp=${'$'}(awk -v v="${'$'}t_raw" 'BEGIN {printf "%.0f", v/1000}')
    p_raw=${'$'}(cat "${'$'}hm/power1_average" 2>/dev/null || cat "${'$'}hm/power1_input" 2>/dev/null)
    [ -n "${'$'}p_raw" ] && pwr=${'$'}(awk -v v="${'$'}p_raw" 'BEGIN {printf "%.1f", v/1000000}')
    break
  done
  printf 'GPU=%s, %s, %s, %s, %s, %s, %s\n' "${'$'}gpu_name" "${'$'}{util:-N/A}" "${'$'}{vram_used:-N/A}" "${'$'}{vram_total:-N/A}" "${'$'}{temp:-N/A}" "${'$'}{pwr:-N/A}" "${'$'}{pstate:-active}"
done
if command -v sinfo >/dev/null 2>&1; then
  printf 'SLURM=1\n'
  sinfo -h -N -o '%N|%P|%T|%C|%m|%G|%f' 2>/dev/null | awk -F'|' '{ nodes[${'$'}1]=${'$'}0 } END { for (node in nodes) print "SLURM_NODE=" nodes[node] }'
fi
ps -ww -eo pcpu=,pmem=,args= --sort=-pcpu 2>/dev/null | head -n 5 | awk 'NF >= 3 { cpu=${'$'}1; mem=${'$'}2; ${'$'}1=""; ${'$'}2=""; sub(/^[[:space:]]+/, ""); gsub(/\|/, " "); if (length(${'$'}0) > 220) ${'$'}0 = substr(${'$'}0, 1, 217) "..."; printf "PROC=%s|%s|%s\n", ${'$'}0, cpu, mem }'
t_end=${'$'}(awk '{print ${'$'}1}' /proc/uptime 2>/dev/null)
if [ -n "${'$'}t_start" ] && [ -n "${'$'}t_end" ]; then
  awk -v s="${'$'}t_start" -v e="${'$'}t_end" 'BEGIN { d=(e-s)*1000; if (d >= 0) printf "SCRIPT_MS=%.1f\n", d }'
fi
printf 'NODEDECK_END\n'
""".trimIndent()

    fun parse(output: String): HostMetrics? {
        if (!output.contains("NODEDECK_BEGIN") || !output.contains("NODEDECK_END")) {
            return null
        }

        val values = mutableMapOf<String, String>()
        val gpus = mutableListOf<GPUInfo>()
        val slurmNodes = mutableListOf<SlurmNodeInfo>()
        val procs = mutableListOf<TopProcessInfo>()
        val dirs = mutableListOf<String>()

        for (rawLine in output.lines()) {
            val line = rawLine.trim()
            val eqIdx = line.indexOf('=')
            if (eqIdx <= 0) continue
            val key = line.substring(0, eqIdx)
            val value = line.substring(eqIdx + 1).trim()
            when (key) {
                "CANDIDATE_DIR" -> if (value.isNotBlank()) dirs.add(value)
                "GPU" -> parseGpu(value)?.let { gpus.add(it) }
                "SLURM_NODE" -> parseSlurmNode(value)?.let { slurmNodes.add(it) }
                "PROC" -> parseProc(value)?.let { procs.add(it) }
                else -> values[key] = value
            }
        }

        return HostMetrics(
            hostname = values["HOSTNAME"].orEmpty(),
            os = values["OS"].orEmpty().ifBlank { "Linux" },
            kernel = values["KERNEL"].orEmpty(),
            arch = values["ARCH"].orEmpty(),
            user = values["USER"].orEmpty(),
            homeDirectory = values["HOME_DIR"].orEmpty(),
            candidateDirectories = dirs,
            cpuModel = values["CPU_MODEL"].orEmpty(),
            cpuCores = values["CPU_CORES"]?.toIntOrNull() ?: 0,
            cpuUsage = values["CPU_USAGE"]?.toDoubleOrNull() ?: 0.0,
            load1 = values["LOAD1"]?.toDoubleOrNull() ?: 0.0,
            load5 = values["LOAD5"]?.toDoubleOrNull() ?: 0.0,
            load15 = values["LOAD15"]?.toDoubleOrNull() ?: 0.0,
            uptimeSeconds = values["UPTIME_SECONDS"]?.toLongOrNull() ?: 0L,
            memTotalBytes = values["MEM_TOTAL"]?.toLongOrNull() ?: 0L,
            memAvailableBytes = values["MEM_AVAILABLE"]?.toLongOrNull() ?: 0L,
            swapTotalBytes = values["SWAP_TOTAL"]?.toLongOrNull() ?: 0L,
            swapFreeBytes = values["SWAP_FREE"]?.toLongOrNull() ?: 0L,
            diskTotalBytes = values["DISK_TOTAL"]?.toLongOrNull() ?: 0L,
            diskUsedBytes = values["DISK_USED"]?.toLongOrNull() ?: 0L,
            diskAvailableBytes = values["DISK_AVAILABLE"]?.toLongOrNull() ?: 0L,
            gpus = gpus,
            hasSlurm = values["SLURM"] == "1" || slurmNodes.isNotEmpty(),
            slurmNodes = slurmNodes.sortedBy { it.name },
            processes = procs,
            scriptDurationMs = values["SCRIPT_MS"]?.toDoubleOrNull()
        )
    }

    private fun parseOptionalDouble(raw: String?): Double? {
        val cleaned = raw?.trim() ?: return null
        if (cleaned.isEmpty() || cleaned.equals("N/A", ignoreCase = true) || cleaned.equals("[N/A]", ignoreCase = true)) {
            return null
        }
        return cleaned.toDoubleOrNull()
    }

    private fun parseGpu(raw: String): GPUInfo? {
        val parts = raw.split(",").map { it.trim() }
        if (parts.isEmpty() || parts[0].isBlank()) return null
        val state = parts.getOrNull(6).orEmpty().lowercase()
        return GPUInfo(
            name = parts[0],
            utilization = parseOptionalDouble(parts.getOrNull(1)),
            memoryUsedMB = parseOptionalDouble(parts.getOrNull(2)),
            memoryTotalMB = parseOptionalDouble(parts.getOrNull(3)),
            temperatureC = parseOptionalDouble(parts.getOrNull(4)),
            powerW = parseOptionalDouble(parts.getOrNull(5)),
            isSleeping = state == "suspended"
        )
    }

    private fun parseSlurmNode(raw: String): SlurmNodeInfo? {
        val p = raw.split("|")
        if (p.size < 6) return null
        val cpuParts = p[3].split("/")
        val alloc = cpuParts.getOrNull(0)?.toIntOrNull() ?: 0
        val idle = cpuParts.getOrNull(1)?.toIntOrNull() ?: 0
        val total = cpuParts.getOrNull(3)?.toIntOrNull() ?: (alloc + idle)
        return SlurmNodeInfo(
            name = p[0],
            partition = p[1].trimEnd('*'),
            state = p[2].trimEnd('*'),
            cpusAllocated = alloc,
            cpusIdle = idle,
            cpusTotal = total,
            memoryMB = p[4].toIntOrNull() ?: 0,
            gres = p[5]
        )
    }

    private fun parseProc(raw: String): TopProcessInfo? {
        val p = raw.split("|")
        if (p.size < 3) return null
        return TopProcessInfo(
            command = p[0].trim(),
            cpuPercent = p[1].trim().toDoubleOrNull() ?: 0.0,
            memPercent = p[2].trim().toDoubleOrNull() ?: 0.0
        )
    }
}
