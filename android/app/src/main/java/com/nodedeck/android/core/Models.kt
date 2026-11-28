package com.nodedeck.android.core

import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.pow
import kotlin.math.roundToInt

enum class SSHRouteKind(val shortBadge: String) {
    LOCAL_TUNNEL("Tunnel"),
    DIRECT_LAN("LAN"),
    REMOTE("WAN")
}

@Serializable
data class SSHHost(
    val id: String = UUID.randomUUID().toString(),
    val alias: String,
    val hostName: String,
    val user: String = "root",
    val port: Int = 22,
    val authType: SSHAuthType = SSHAuthType.PASSWORD,
    val password: String = "",
    val privateKeyName: String = "",
    val privateKeyPassphrase: String = "",
    val proxyJumpAlias: String = "",
    val notes: String = ""
) {
    val loginTarget: String
        get() = if (port == 22) "$user@$hostName" else "$user@$hostName:$port"

    val routeKind: SSHRouteKind
        get() {
            val lower = hostName.trim().lowercase()
            if (lower == "127.0.0.1" || lower == "::1" || lower == "localhost") {
                return SSHRouteKind.LOCAL_TUNNEL
            }
            if (lower.startsWith("10.") ||
                lower.startsWith("192.168.") ||
                lower.startsWith("100.") ||
                lower.startsWith("fe80:") ||
                lower.endsWith(".local") ||
                isPrivate172(lower)
            ) {
                return SSHRouteKind.DIRECT_LAN
            }
            return SSHRouteKind.REMOTE
        }

    companion object {
        private fun isPrivate172(host: String): Boolean {
            val parts = host.split(".")
            if (parts.size != 4 || parts[0] != "172") return false
            val second = parts[1].toIntOrNull() ?: return false
            return second in 16..31
        }
    }
}

@Serializable
enum class SSHAuthType {
    PASSWORD,
    PRIVATE_KEY
}

enum class HostConnectionState {
    IDLE,
    CHECKING,
    ONLINE,
    OFFLINE
}

data class GPUInfo(
    val name: String,
    val utilization: Double?,
    val memoryUsedMB: Double?,
    val memoryTotalMB: Double?,
    val temperatureC: Double?,
    val powerW: Double?,
    val isSleeping: Boolean = false
) {
    val isAMD: Boolean
        get() = name.contains("AMD", ignoreCase = true) || name.contains("Radeon", ignoreCase = true)

    val memoryFraction: Double?
        get() = if (memoryUsedMB != null && memoryTotalMB != null && memoryTotalMB > 0) {
            (memoryUsedMB / memoryTotalMB).coerceIn(0.0, 1.0)
        } else null
}

data class SlurmNodeInfo(
    val name: String,
    val partition: String,
    val state: String,
    val cpusAllocated: Int,
    val cpusIdle: Int,
    val cpusTotal: Int,
    val memoryMB: Int,
    val gres: String
)

data class TopProcessInfo(
    val command: String,
    val cpuPercent: Double,
    val memPercent: Double
)

data class HostMetrics(
    val hostname: String,
    val os: String,
    val kernel: String,
    val arch: String,
    val user: String,
    val homeDirectory: String,
    val candidateDirectories: List<String>,
    val cpuModel: String,
    val cpuCores: Int,
    val cpuUsage: Double,
    val load1: Double,
    val load5: Double,
    val load15: Double,
    val uptimeSeconds: Long,
    val memTotalBytes: Long,
    val memAvailableBytes: Long,
    val swapTotalBytes: Long,
    val swapFreeBytes: Long,
    val diskTotalBytes: Long,
    val diskUsedBytes: Long,
    val diskAvailableBytes: Long,
    val gpus: List<GPUInfo>,
    val hasSlurm: Boolean,
    val slurmNodes: List<SlurmNodeInfo>,
    val processes: List<TopProcessInfo>,
    val scriptDurationMs: Double?
) {
    val memUsedBytes: Long get() = (memTotalBytes - memAvailableBytes).coerceAtLeast(0L)
    val memoryFraction: Double
        get() = if (memTotalBytes > 0) (memUsedBytes.toDouble() / memTotalBytes.toDouble()).coerceIn(0.0, 1.0) else 0.0
    val diskFraction: Double
        get() = if (diskTotalBytes > 0) (diskUsedBytes.toDouble() / diskTotalBytes.toDouble()).coerceIn(0.0, 1.0) else 0.0
}

data class HostSnapshot(
    val host: SSHHost,
    val state: HostConnectionState = HostConnectionState.IDLE,
    val metrics: HostMetrics? = null,
    val latencyMs: Double? = null,
    val errorMessage: String? = null,
    val lastUpdatedMs: Long? = null
)

@Serializable
enum class PortForwardDirection(val flag: String) {
    LOCAL("-L"),
    REMOTE("-R"),
    DYNAMIC("-D")
}

@Serializable
data class SSHPortForwardConfig(
    val id: String = UUID.randomUUID().toString(),
    val hostAlias: String,
    val label: String,
    val direction: PortForwardDirection = PortForwardDirection.LOCAL,
    val localHost: String = "127.0.0.1",
    val localPort: Int,
    val remoteHost: String = "127.0.0.1",
    val remotePort: Int = 8888,
    val urlScheme: String = "http"
) {
    val specSummary: String
        get() = when (direction) {
            PortForwardDirection.LOCAL -> "$localHost:$localPort → $remoteHost:$remotePort"
            PortForwardDirection.REMOTE -> "$remoteHost:$remotePort → $localHost:$localPort"
            PortForwardDirection.DYNAMIC -> "SOCKS5 $localHost:$localPort"
        }

    val openableUrl: String?
        get() = if (direction == PortForwardDirection.LOCAL && urlScheme.isNotBlank()) {
            "$urlScheme://$localHost:$localPort"
        } else null
}

@Serializable
data class SunshineHostConfig(
    val id: String = UUID.randomUUID().toString(),
    val hostAlias: String,
    val address: String,
    val httpPort: Int = 47989,
    val httpsPort: Int = 47984,
    val serverName: String = "",
    val isPaired: Boolean = true
)

data class SunshineServerInfo(
    val hostname: String,
    val appVersion: String,
    val gfeVersion: String,
    val httpsPort: Int,
    val pairStatus: Boolean,
    val currentGame: Int,
    val serverCodecModeSupport: Int
)

data class SunshineApp(
    val id: Int,
    val title: String
)

data class SunshineLaunchSession(
    val address: String,
    val httpPort: Int,
    val httpsPort: Int,
    val appVersion: String,
    val gfeVersion: String,
    val serverCodecModeSupport: Int,
    val rtspSessionUrl: String,
    val rikey: ByteArray,
    val rikeyId: Int,
    val appId: Int,
    val appTitle: String
)

@Serializable
enum class LinuxHostDisplayMode {
    PHYSICAL_DESKTOP,
    ISOLATED_VIRTUAL_DESKTOP
}

@Serializable
data class LinuxHostProfile(
    val hostAlias: String,
    val mode: LinuxHostDisplayMode = LinuxHostDisplayMode.PHYSICAL_DESKTOP,
    val display: String = ":99",
    val basePort: Int = 47989,
    val encoder: String = "nvenc",
    val drmRenderNode: String = "/dev/dri/renderD128",
    val virtualAudioSink: Boolean = false,
    val clipboardSync: Boolean = true
)

enum class StreamResolutionPreset(val label: String, val width: Int, val height: Int) {
    HD_1080("1080p", 1920, 1080),
    QHD_1440("1440p", 2560, 1440),
    UHD_4K("4K", 3840, 2160);

    companion object {
        fun fromLabel(label: String?): StreamResolutionPreset =
            entries.firstOrNull { it.label == label } ?: HD_1080

        fun fromDimensions(width: Int, height: Int): StreamResolutionPreset? =
            entries.firstOrNull { it.width == width && it.height == height }
    }
}

enum class StreamRefreshRate(val fps: Int) {
    HZ_60(60),
    HZ_120(120),
    HZ_144(144),
    HZ_165(165);

    val label: String get() = "${fps}Hz"
    val clientRefreshRateX100: Int get() = fps * 100

    companion object {
        fun fromFps(fps: Int): StreamRefreshRate =
            entries.firstOrNull { it.fps == fps } ?: HZ_60
    }
}

object StreamQualityMath {
    fun recommendedBitrateKbps(width: Int, height: Int, fps: Int): Int {
        val w = width.coerceAtLeast(640)
        val h = height.coerceAtLeast(360)
        val f = fps.coerceAtLeast(30)
        val pixelRatio = (w.toDouble() * h.toDouble()) / (1920.0 * 1080.0)
        val fpsRatio = f.toDouble() / 60.0
        val raw = 20_000.0 * pixelRatio.pow(0.72) * fpsRatio.pow(0.75)
        val rounded = (raw / 5_000.0).roundToInt() * 5_000
        return rounded.coerceIn(20_000, 120_000)
    }
}

enum class HostFilter {
    ALL, ONLINE, GPU
}

object DisplayFormat {
    fun bytes(bytes: Long): String {
        if (bytes <= 0L) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var v = bytes.toDouble()
        var idx = 0
        while (v >= 1024.0 && idx < units.lastIndex) {
            v /= 1024.0
            idx++
        }
        return if (idx <= 1) "${v.roundToInt()} ${units[idx]}" else String.format("%.1f %s", v, units[idx])
    }

    fun uptime(seconds: Long): String {
        if (seconds <= 0L) return "—"
        val days = seconds / 86400
        val hours = (seconds % 86400) / 3600
        val mins = (seconds % 3600) / 60
        return when {
            days > 0 -> "${days}d ${hours}h"
            hours > 0 -> "${hours}h ${mins}m"
            else -> "${mins}m"
        }
    }

    fun latency(ms: Double): String = "${ms.roundToInt()} ms"
}
