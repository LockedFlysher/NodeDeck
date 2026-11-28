package com.nodedeck.android.mesh

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.Inet4Address
import java.net.NetworkInterface

@Serializable
data class MeshConfig(
    val hostname: String = "android",
    val ipv4: String = "",
    val networkName: String = "",
    val networkSecret: String = "",
    val seedUri: String = "",
    val port: Int = 28443,
    val extraProxyCidrs: List<String> = emptyList()
) {
    val isConfigured: Boolean
        get() = networkName.isNotBlank() && networkSecret.isNotBlank() && seedUri.isNotBlank() && ipv4.isNotBlank()
}

enum class MeshConnectionState {
    STOPPED,
    CONNECTING,
    CONNECTED,
    ERROR
}

data class MeshPeerStatus(
    val peerId: Long,
    val hostname: String,
    val virtualIpv4: String,
    val isDirect: Boolean,
    val cost: Long,
    val latencyMs: Double,
    val lossRate: Float,
    val rxBytes: Long,
    val txBytes: Long,
    val proto: String
) {
    val isTcpRelay: Boolean
        get() = !isDirect && proto.lowercase().contains("tcp")

    fun transportBadge(): String {
        val p = proto.lowercase()
        return if (isDirect) {
            when {
                p.contains("udp") -> "P2P · UDP"
                p.contains("tcp") -> "P2P · TCP"
                p.isNotBlank() && p != "p2p" -> "P2P · ${p.uppercase()}"
                else -> "P2P"
            }
        } else {
            when {
                p.contains("udp") -> "UDP Relay"
                p.contains("tcp") -> "TCP Relay"
                else -> "Relay($cost)"
            }
        }
    }
}

data class MeshRuntimeSnapshot(
    val state: MeshConnectionState = MeshConnectionState.STOPPED,
    val localIpv4: String = "",
    val localHostname: String = "",
    val lanIps: List<String> = emptyList(),
    val peers: List<MeshPeerStatus> = emptyList(),
    val errorMessage: String? = null
)

object MeshConfigCodec {
    const val INSTANCE_NAME = "nodedeck-mesh"
    const val DEFAULT_MTU = 1360

    fun isUsableLanIp(ip: String, meshPrefix3: String = ""): Boolean {
        if (ip.isBlank()) return false
        return !(ip.startsWith("127.") ||
            ip.startsWith("169.254.") ||
            (meshPrefix3.isNotBlank() && ip.startsWith(meshPrefix3)))
    }

    fun discoverLanIps(meshIpv4: String = ""): List<String> {
        val ipOnly = meshIpv4.substringBefore('/')
        val parts = ipOnly.split('.')
        val meshPrefix3 = if (parts.size == 4) "${parts[0]}.${parts[1]}.${parts[2]}." else ""
        val skipPrefixes = listOf("lo", "tun", "utun", "wg", "et", "dummy", "p2p", "rmnet", "ccmni", "v4-", "clat")
        val ips = mutableSetOf<String>()
        runCatching {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return emptyList()
            while (ifaces.hasMoreElements()) {
                val nif = ifaces.nextElement()
                if (!nif.isUp || nif.isLoopback) continue
                val name = nif.name.orEmpty().lowercase()
                if (skipPrefixes.any { name.startsWith(it) }) continue
                val addrs = nif.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val hostAddr = addr.hostAddress.orEmpty()
                        if (isUsableLanIp(hostAddr, meshPrefix3)) {
                            ips.add(hostAddr)
                        }
                    }
                }
            }
        }
        return ips.sorted()
    }

    fun expandSeedUris(raw: String): List<String> {
        val tokens = raw.split(Regex("[\\s,]+")).map { it.trim() }.filter { it.isNotEmpty() }
        val ordered = mutableListOf<String>()
        for (uri in tokens) {
            when {
                uri.startsWith("tcp://") -> {
                    val udpUri = "udp://" + uri.removePrefix("tcp://")
                    if (udpUri !in ordered) ordered.add(udpUri)
                    if (uri !in ordered) ordered.add(uri)
                }
                uri.startsWith("udp://") -> {
                    if (uri !in ordered) ordered.add(uri)
                    val tcpUri = "tcp://" + uri.removePrefix("udp://")
                    if (tcpUri !in ordered) ordered.add(tcpUri)
                }
                else -> if (uri !in ordered) ordered.add(uri)
            }
        }
        return ordered
    }

    fun buildRuntimeToml(config: MeshConfig, lanIps: List<String>): String {
        val port = config.port.coerceIn(1024, 65535)
        val mapped = lanIps.map { ip -> "\"udp://$ip:$port\"" }
        val ipv4WithMask = if (config.ipv4.contains("/")) config.ipv4.trim() else "${config.ipv4.trim()}/24"
        val seedUris = expandSeedUris(config.seedUri)
        return buildString {
            appendLine("instance_name = \"$INSTANCE_NAME\"")
            appendLine("hostname = \"${escapeToml(config.hostname.ifBlank { "android" })}\"")
            appendLine("ipv4 = \"${escapeToml(ipv4WithMask)}\"")
            appendLine("listeners = [\"udp://0.0.0.0:$port\", \"tcp://0.0.0.0:$port\"]")
            appendLine("mapped_listeners = [${mapped.joinToString(", ")}]")
            appendLine()
            appendLine("[network_identity]")
            appendLine("network_name = \"${escapeToml(config.networkName)}\"")
            appendLine("network_secret = \"${escapeToml(config.networkSecret)}\"")
            appendLine()
            seedUris.forEach { uri ->
                appendLine("[[peer]]")
                appendLine("uri = \"${escapeToml(uri)}\"")
                appendLine()
            }
            appendLine("[flags]")
            appendLine("default_protocol = \"udp\"")
            appendLine("multi_thread = true")
            appendLine("latency_first = true")
        }
    }

    fun splitCidr(cidr: String, defaultPrefix: Int = 24): Pair<String, Int> {
        val parts = cidr.trim().split("/")
        val ip = parts[0].trim()
        val prefix = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(1, 32) ?: defaultPrefix
        return ip to prefix
    }

    fun computeNetworkAddress(ip: String, prefix: Int): String {
        val octets = ip.split('.').mapNotNull { it.toIntOrNull()?.coerceIn(0, 255) }
        if (octets.size != 4) return ip
        val ipInt = (octets[0] shl 24) or (octets[1] shl 16) or (octets[2] shl 8) or octets[3]
        val mask = if (prefix <= 0) 0 else (-1 shl (32 - prefix))
        val net = ipInt and mask
        return "${(net ushr 24) and 0xFF}.${(net ushr 16) and 0xFF}.${(net ushr 8) and 0xFF}.${net and 0xFF}"
    }

    private fun escapeToml(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"")

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    @Serializable
    private data class EtRunningInfoMap(val map: Map<String, EtRunningInfo> = emptyMap())

    @Serializable
    private data class EtRunningInfo(
        @SerialName("my_node_info") val myNodeInfo: EtMyNodeInfo? = null,
        val routes: List<EtRoute> = emptyList(),
        val peers: List<EtPeerInfo> = emptyList(),
        val running: Boolean = false,
        @SerialName("error_msg") val errorMsg: String? = null
    )

    @Serializable
    private data class EtMyNodeInfo(
        @SerialName("virtual_ipv4") val virtualIpv4: EtIpv4Inet? = null,
        val hostname: String = ""
    )

    @Serializable
    private data class EtIpv4Inet(
        val address: EtIpv4Addr? = null,
        @SerialName("network_length") val networkLength: Long = 24
    ) {
        fun toCidr(): String = address?.let { "${it.toDotted()}/$networkLength" }.orEmpty()
        fun toIp(): String = address?.toDotted().orEmpty()
    }

    @Serializable
    private data class EtIpv4Addr(val addr: Long = 0) {
        fun toDotted(): String =
            "${(addr shr 24) and 0xFF}.${(addr shr 16) and 0xFF}.${(addr shr 8) and 0xFF}.${addr and 0xFF}"
    }

    @Serializable
    private data class EtRoute(
        @SerialName("peer_id") val peerId: Long = 0,
        @SerialName("ipv4_addr") val ipv4Addr: EtIpv4Inet? = null,
        @SerialName("next_hop_peer_id") val nextHopPeerId: Long = 0,
        val cost: Long = 0,
        @SerialName("path_latency") val pathLatency: Long = 0,
        val hostname: String = ""
    )

    @Serializable
    private data class EtPeerInfo(
        @SerialName("peer_id") val peerId: Long = 0,
        val conns: List<EtPeerConn> = emptyList()
    )

    @Serializable
    private data class EtPeerConn(
        val tunnel: EtTunnel? = null,
        val stats: EtConnStats? = null,
        @SerialName("loss_rate") val lossRate: Float = 0f,
        @SerialName("is_closed") val isClosed: Boolean = false
    )

    @Serializable
    private data class EtTunnel(@SerialName("tunnel_type") val tunnelType: String = "")

    @Serializable
    private data class EtConnStats(
        @SerialName("rx_bytes") val rxBytes: String = "0",
        @SerialName("tx_bytes") val txBytes: String = "0",
        @SerialName("latency_us") val latencyUs: String = "0"
    )

    fun parseRuntimeSnapshot(
        rawJson: String,
        fallbackLocalIp: String,
        fallbackHostname: String,
        lanIps: List<String>
    ): MeshRuntimeSnapshot? {
        val parsed = runCatching { json.decodeFromString<EtRunningInfoMap>(rawJson) }.getOrNull() ?: return null
        val info = parsed.map[INSTANCE_NAME] ?: parsed.map.values.firstOrNull() ?: return null
        val peerById = info.peers.associateBy { it.peerId }

        val peerList = info.routes.map { r ->
            val p = peerById[r.peerId]
            val conn = p?.conns?.firstOrNull { !it.isClosed } ?: p?.conns?.firstOrNull()
            val hopConn = if (r.nextHopPeerId != 0L && r.nextHopPeerId != r.peerId) {
                peerById[r.nextHopPeerId]?.conns?.firstOrNull { !it.isClosed }
                    ?: peerById[r.nextHopPeerId]?.conns?.firstOrNull()
            } else null
            val direct = (r.nextHopPeerId != 0L && r.nextHopPeerId == r.peerId) || r.cost == 1L
            val latMs = conn?.stats?.latencyUs?.toLongOrNull()?.let { it / 1000.0 }
                ?: (r.pathLatency.toDouble())
            val rawProto = conn?.tunnel?.tunnelType?.substringBefore("://").orEmpty()
                .ifBlank { hopConn?.tunnel?.tunnelType?.substringBefore("://").orEmpty() }
            MeshPeerStatus(
                peerId = r.peerId,
                hostname = r.hostname.ifBlank { "peer-${r.peerId}" },
                virtualIpv4 = r.ipv4Addr?.toIp().orEmpty().ifBlank { "—" },
                isDirect = direct,
                cost = r.cost,
                latencyMs = latMs,
                lossRate = conn?.lossRate ?: hopConn?.lossRate ?: 0f,
                rxBytes = conn?.stats?.rxBytes?.toLongOrNull() ?: 0L,
                txBytes = conn?.stats?.txBytes?.toLongOrNull() ?: 0L,
                proto = rawProto.ifBlank { if (direct) "p2p" else "relay" }
            )
        }.sortedBy { it.virtualIpv4 }

        val localIp = info.myNodeInfo?.virtualIpv4?.toCidr().orEmpty().ifBlank { fallbackLocalIp }
        val localHost = info.myNodeInfo?.hostname.orEmpty().ifBlank { fallbackHostname }

        return if (!info.running) {
            MeshRuntimeSnapshot(
                state = MeshConnectionState.ERROR,
                localIpv4 = localIp,
                localHostname = localHost,
                lanIps = lanIps,
                peers = peerList,
                errorMessage = info.errorMsg ?: "EasyTier instance stopped"
            )
        } else {
            MeshRuntimeSnapshot(
                state = MeshConnectionState.CONNECTED,
                localIpv4 = localIp,
                localHostname = localHost,
                lanIps = lanIps,
                peers = peerList,
                errorMessage = null
            )
        }
    }
}
