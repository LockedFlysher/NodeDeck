package com.nodedeck.android.mesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import com.easytier.jni.EasyTierJNI
import com.nodedeck.android.MainActivity
import com.nodedeck.android.NodeDeckApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class NodeDeckVpnService : VpnService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()

    private var vpnInterface: ParcelFileDescriptor? = null
    private var pollJob: Job? = null
    private var lanWatchJob: Job? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile private var activeConfig: MeshConfig? = null
    @Volatile private var activeLanIps: List<String> = emptyList()
    @Volatile private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                scope.launch {
                    stopMeshInternal()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                return START_NOT_STICKY
            }
            else -> {
                val cfg = NodeDeckApp.from(this).store.loadMeshConfig()
                if (!cfg.isConfigured) {
                    MeshRuntimeController.update(
                        MeshRuntimeSnapshot(
                            state = MeshConnectionState.ERROR,
                            errorMessage = "Please sign in first to obtain mesh credentials"
                        )
                    )
                    stopSelf()
                    return START_NOT_STICKY
                }
                stopping = false
                startForegroundSafe(buildNotification("Connecting ${cfg.ipv4.substringBefore('/')}…"))
                scope.launch { startOrReloadMesh(cfg) }
                return START_STICKY
            }
        }
    }

    private suspend fun startOrReloadMesh(cfg: MeshConfig) {
        lifecycleMutex.withLock {
            if (stopping) return
            val lanIps = MeshConfigCodec.discoverLanIps(cfg.ipv4)
            activeConfig = cfg
            activeLanIps = lanIps

            MeshRuntimeController.update(
                MeshRuntimeSnapshot(
                    state = MeshConnectionState.CONNECTING,
                    localIpv4 = cfg.ipv4,
                    localHostname = cfg.hostname,
                    lanIps = lanIps
                )
            )

            try {
                runCatching { EasyTierJNI.stopAllInstances() }
                delay(150)

                val toml = MeshConfigCodec.buildRuntimeToml(cfg, lanIps)
                if (EasyTierJNI.parseConfig(toml) != 0) {
                    throw IllegalStateException(EasyTierJNI.getLastError() ?: "Invalid mesh config")
                }
                if (EasyTierJNI.runNetworkInstance(toml) != 0) {
                    throw IllegalStateException(EasyTierJNI.getLastError() ?: "Failed to start EasyTier")
                }

                val newTun = establishSplitTunnel(cfg)
                val fdRc = EasyTierJNI.setTunFd(MeshConfigCodec.INSTANCE_NAME, newTun.fd)
                if (fdRc != 0) {
                    runCatching { newTun.close() }
                    throw IllegalStateException(EasyTierJNI.getLastError() ?: "setTunFd failed ($fdRc)")
                }

                val prevTun = vpnInterface
                vpnInterface = newTun
                runCatching { prevTun?.close() }

                Log.i(TAG, "Built-in EasyTier started: ${cfg.hostname} (${cfg.ipv4}), LAN IPs=$lanIps")
                MeshRuntimeController.update(
                    MeshRuntimeSnapshot(
                        state = MeshConnectionState.CONNECTED,
                        localIpv4 = cfg.ipv4,
                        localHostname = cfg.hostname,
                        lanIps = lanIps
                    )
                )
                updateNotification("Online · ${cfg.ipv4.substringBefore('/')}")
                registerNetworkWatcher()
                startPollingLoop(cfg)
            } catch (t: Throwable) {
                Log.e(TAG, "Built-in EasyTier start failed", t)
                runCatching { EasyTierJNI.stopAllInstances() }
                runCatching { vpnInterface?.close() }
                vpnInterface = null
                MeshRuntimeController.update(
                    MeshRuntimeSnapshot(
                        state = MeshConnectionState.ERROR,
                        localIpv4 = cfg.ipv4,
                        localHostname = cfg.hostname,
                        lanIps = lanIps,
                        errorMessage = t.message ?: "Mesh startup failed"
                    )
                )
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun establishSplitTunnel(cfg: MeshConfig): ParcelFileDescriptor {
        val (ip, prefix) = MeshConfigCodec.splitCidr(cfg.ipv4, 24)
        val subnet = MeshConfigCodec.computeNetworkAddress(ip, prefix)
        val builder = Builder()
            .setSession("NodeDeck Mesh")
            .setBlocking(false)
            .setMtu(MeshConfigCodec.DEFAULT_MTU)
            .addAddress(ip, prefix)
            .addRoute(subnet, prefix)

        runCatching { builder.addAddress("fd00::1", 128) }
        for (rawCidr in cfg.extraProxyCidrs) {
            val clean = rawCidr.trim()
            if (clean.isEmpty() || clean.startsWith("0.0.0.0")) continue
            runCatching {
                val (rIp, rPrefix) = MeshConfigCodec.splitCidr(clean, 24)
                builder.addRoute(MeshConfigCodec.computeNetworkAddress(rIp, rPrefix), rPrefix)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        // Split-tunnel ONLY routes the private mesh subnet so NodeDeck's own SSH & Moonlight
        // sockets reach mesh peers while WAN/LAN/STUN bypass TUN with zero loop.
        return builder.establish()
            ?: throw IllegalStateException("Android VPN permission not granted")
    }

    private fun startPollingLoop(cfg: MeshConfig) {
        pollJob?.cancel()
        pollJob = scope.launch {
            while (isActive && !stopping) {
                val raw = runCatching { EasyTierJNI.collectNetworkInfos(16) }.getOrNull()
                if (!raw.isNullOrBlank()) {
                    val parsed = MeshConfigCodec.parseRuntimeSnapshot(
                        rawJson = raw,
                        fallbackLocalIp = cfg.ipv4,
                        fallbackHostname = cfg.hostname,
                        lanIps = activeLanIps
                    )
                    if (parsed != null) {
                        MeshRuntimeController.update(parsed)
                        updateNotification("Online · ${parsed.localIpv4.substringBefore('/')} · ${parsed.peers.size} peers")
                    }
                }
                delay(2_500L)
            }
        }
    }

    private fun registerNetworkWatcher() {
        if (networkCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = scheduleLanIpRecheck()
            override fun onLost(network: Network) = scheduleLanIpRecheck()
            override fun onLinkPropertiesChanged(network: Network, linkProperties: android.net.LinkProperties) =
                scheduleLanIpRecheck()
        }
        val req = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching {
            cm.registerNetworkCallback(req, cb)
            networkCallback = cb
        }
    }

    private fun unregisterNetworkWatcher() {
        val cb = networkCallback ?: return
        networkCallback = null
        runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) }
    }

    private fun scheduleLanIpRecheck() {
        val cfg = activeConfig ?: return
        if (stopping) return
        lanWatchJob?.cancel()
        lanWatchJob = scope.launch {
            delay(2_000L)
            if (stopping) return@launch
            val currentIps = MeshConfigCodec.discoverLanIps(cfg.ipv4)
            if (currentIps != activeLanIps) {
                startOrReloadMesh(cfg)
            }
        }
    }

    private suspend fun stopMeshInternal() {
        lifecycleMutex.withLock {
            stopping = true
            pollJob?.cancel(); pollJob = null
            lanWatchJob?.cancel(); lanWatchJob = null
            unregisterNetworkWatcher()
            runCatching { EasyTierJNI.stopAllInstances() }
            runCatching { vpnInterface?.close() }
            vpnInterface = null
            activeConfig = null
            MeshRuntimeController.update(MeshRuntimeSnapshot(state = MeshConnectionState.STOPPED))
        }
    }

    override fun onRevoke() {
        super.onRevoke()
        scope.launch {
            stopMeshInternal()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        stopping = true
        pollJob?.cancel()
        lanWatchJob?.cancel()
        unregisterNetworkWatcher()
        runCatching { EasyTierJNI.stopAllInstances() }
        runCatching { vpnInterface?.close() }
        vpnInterface = null
        MeshRuntimeController.update(MeshRuntimeSnapshot(state = MeshConnectionState.STOPPED))
        scope.cancel()
        super.onDestroy()
    }

    private fun startForegroundSafe(notification: Notification) {
        ensureChannel()
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }.onFailure { runCatching { startForeground(NOTIFICATION_ID, notification) } }
    }

    private fun updateNotification(text: String) {
        ensureChannel()
        runCatching { getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, buildNotification(text)) }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "NodeDeck Mesh VPN", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun buildNotification(text: String): Notification {
        val openPi = PendingIntent.getActivity(
            this, 10, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopPi = PendingIntent.getService(
            this, 11, Intent(this, NodeDeckVpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("NodeDeck Mesh")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openPi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", stopPi)
            .build()
    }

    companion object {
        private const val TAG = "NodeDeckMeshVPN"
        private const val CHANNEL_ID = "nodedeck_mesh_vpn"
        private const val NOTIFICATION_ID = 2099
        const val ACTION_START = "com.nodedeck.android.mesh.START"
        const val ACTION_STOP = "com.nodedeck.android.mesh.STOP"
    }
}
