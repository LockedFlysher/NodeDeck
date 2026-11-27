package com.nodedeck.android.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nodedeck.android.NodeDeckApp
import com.nodedeck.android.core.AccountSession
import com.nodedeck.android.core.AppLanguage
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.ControlPlaneClient
import com.nodedeck.android.core.ControlPlaneDevice
import com.nodedeck.android.core.ControlPlaneStateResponse
import com.nodedeck.android.core.HostConnectionState
import com.nodedeck.android.core.HostFilter
import com.nodedeck.android.core.HostSnapshot
import com.nodedeck.android.core.LinuxHostProfile
import com.nodedeck.android.core.PortForwardService
import com.nodedeck.android.core.SSHAuthType
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.core.SSHPortForwardConfig
import com.nodedeck.android.core.SshConfigParser
import com.nodedeck.android.core.StreamRefreshRate
import com.nodedeck.android.core.StreamResolutionPreset
import com.nodedeck.android.core.SunshineHostConfig
import com.nodedeck.android.mesh.MeshConfig
import com.nodedeck.android.mesh.MeshConfigCodec
import com.nodedeck.android.mesh.MeshConnectionState
import com.nodedeck.android.mesh.MeshRuntimeController
import com.nodedeck.android.mesh.MeshRuntimeSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as NodeDeckApp
    val store = app.store
    val sshManager = app.sshManager
    val sunshineClient = app.sunshineClient
    val hostProfileManager = app.hostProfileManager
    val controlPlaneClient = app.controlPlaneClient

    private val _hosts = MutableStateFlow<List<SSHHost>>(emptyList())
    val hosts: StateFlow<List<SSHHost>> = _hosts.asStateFlow()

    private val _snapshots = MutableStateFlow<Map<String, HostSnapshot>>(emptyMap())
    val snapshots: StateFlow<Map<String, HostSnapshot>> = _snapshots.asStateFlow()

    private val _sunshineConfigs = MutableStateFlow<List<SunshineHostConfig>>(emptyList())
    val sunshineConfigs: StateFlow<List<SunshineHostConfig>> = _sunshineConfigs.asStateFlow()

    private val _portForwards = MutableStateFlow<List<SSHPortForwardConfig>>(emptyList())
    val portForwards: StateFlow<List<SSHPortForwardConfig>> = _portForwards.asStateFlow()

    private val _activeForwardIds = MutableStateFlow<Set<String>>(emptySet())
    val activeForwardIds: StateFlow<Set<String>> = _activeForwardIds.asStateFlow()

    private val _hostProfiles = MutableStateFlow<List<LinuxHostProfile>>(emptyList())
    val hostProfiles: StateFlow<List<LinuxHostProfile>> = _hostProfiles.asStateFlow()

    private val _pinnedAliases = MutableStateFlow<Set<String>>(emptySet())
    val pinnedAliases: StateFlow<Set<String>> = _pinnedAliases.asStateFlow()

    private val _filter = MutableStateFlow(HostFilter.ALL)
    val filter: StateFlow<HostFilter> = _filter.asStateFlow()

    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    private val _streamResolution = MutableStateFlow(store.getStreamResolution())
    val streamResolution: StateFlow<StreamResolutionPreset> = _streamResolution.asStateFlow()

    private val _streamRefreshRate = MutableStateFlow(store.getStreamRefreshRate())
    val streamRefreshRate: StateFlow<StreamRefreshRate> = _streamRefreshRate.asStateFlow()

    private val _refreshIntervalSec = MutableStateFlow(store.getRefreshIntervalSec())
    val refreshIntervalSec: StateFlow<Int> = _refreshIntervalSec.asStateFlow()

    private val _isRefreshingAll = MutableStateFlow(false)
    val isRefreshingAll: StateFlow<Boolean> = _isRefreshingAll.asStateFlow()

    private val _feedbackMessage = MutableStateFlow<String?>(null)
    val feedbackMessage: StateFlow<String?> = _feedbackMessage.asStateFlow()

    private val _accountSession = MutableStateFlow(AccountSession())
    val accountSession: StateFlow<AccountSession> = _accountSession.asStateFlow()

    private val _accountDevices = MutableStateFlow<List<ControlPlaneDevice>>(emptyList())
    val accountDevices: StateFlow<List<ControlPlaneDevice>> = _accountDevices.asStateFlow()

    val meshSnapshot: StateFlow<MeshRuntimeSnapshot> = MeshRuntimeController.snapshot

    private val refreshSemaphore = Semaphore(4)
    private var autoRefreshJob: Job? = null
    private var accountHeartbeatJob: Job? = null
    private val meshTriggeredHostIds = mutableSetOf<String>()

    init {
        loadFromStore()
        observeMeshPeersForRefresh()
        if (_hosts.value.isNotEmpty()) {
            refreshAllHosts()
        }
        if (_accountSession.value.isLoggedIn) {
            syncAccountState()
            startAccountHeartbeatLoop()
        }
        restartAutoRefreshLoop()
    }

    private fun observeMeshPeersForRefresh() {
        viewModelScope.launch {
            MeshRuntimeController.snapshot.collect { snap ->
                if (snap.state != MeshConnectionState.CONNECTED) {
                    meshTriggeredHostIds.clear()
                    return@collect
                }
                val peerIps = snap.peers.mapNotNull { p ->
                    p.virtualIpv4.takeIf { it.isNotBlank() && it != "—" }
                }.toSet()
                if (peerIps.isEmpty()) return@collect

                for (host in _hosts.value) {
                    if (host.hostName !in peerIps) continue
                    val current = _snapshots.value[host.id]
                    val needsRefresh = current == null ||
                        current.state == HostConnectionState.OFFLINE ||
                        (current.state == HostConnectionState.ONLINE && (current.latencyMs ?: 0.0) > 500.0)
                    if (needsRefresh && meshTriggeredHostIds.add(host.id)) {
                        refreshHost(host.id)
                    }
                }
            }
        }
    }

    private fun loadFromStore() {
        val loadedHosts = store.loadHosts()
        _hosts.value = loadedHosts
        _snapshots.value = loadedHosts.associate { it.id to HostSnapshot(host = it) }
        _sunshineConfigs.value = store.loadSunshineHosts()
        _portForwards.value = store.loadPortForwards()
        _hostProfiles.value = store.loadHostProfiles()
        _pinnedAliases.value = store.getPinnedAliases()
        _activeForwardIds.value = sshManager.activeForwardIds()
        _accountSession.value = store.loadAccountSession()
    }

    // MARK: - Unified Account & Built-in Mesh

    fun registerAccount(
        serverUrl: String,
        username: String,
        password: String,
        inviteCode: String,
        onResult: (Result<Unit>) -> Unit
    ) {
        viewModelScope.launch {
            val deviceId = store.getOrCreateDeviceId()
            val res = runCatching {
                val resp = controlPlaneClient.register(
                    serverUrl = serverUrl,
                    username = username,
                    password = password,
                    inviteCode = inviteCode,
                    deviceId = deviceId
                )
                applyControlPlaneAuth(serverUrl, resp)
            }
            onResult(res)
        }
    }

    fun loginAccount(
        serverUrl: String,
        username: String,
        password: String,
        onResult: (Result<Unit>) -> Unit
    ) {
        viewModelScope.launch {
            val deviceId = store.getOrCreateDeviceId()
            val res = runCatching {
                val resp = controlPlaneClient.login(
                    serverUrl = serverUrl,
                    username = username,
                    password = password,
                    deviceId = deviceId
                )
                applyControlPlaneAuth(serverUrl, resp)
            }
            onResult(res)
        }
    }

    fun syncAccountState() {
        val sess = _accountSession.value
        if (!sess.isLoggedIn) return
        viewModelScope.launch {
            runCatching {
                val lanIps = MeshConfigCodec.discoverLanIps(sess.virtualCidr)
                val resp = controlPlaneClient.heartbeat(
                    serverUrl = sess.serverUrl,
                    token = sess.token,
                    deviceName = sess.deviceName.ifBlank { ControlPlaneClient.defaultDeviceName() },
                    lanIps = lanIps
                )
                applyControlPlaneAuth(sess.serverUrl, resp, keepToken = sess.token)
            }.onFailure { err ->
                postFeedback(err.message ?: "Account sync failed")
            }
        }
    }

    fun logoutAccount() {
        val sess = _accountSession.value
        accountHeartbeatJob?.cancel()
        accountHeartbeatJob = null
        viewModelScope.launch {
            if (sess.isLoggedIn) {
                controlPlaneClient.logout(sess.serverUrl, sess.token)
            }
        }
        val cleared = AccountSession(serverUrl = sess.serverUrl.ifBlank { ControlPlaneClient.DEFAULT_SERVER_URL })
        _accountSession.value = cleared
        _accountDevices.value = emptyList()
        store.saveAccountSession(cleared)
        store.saveMeshConfig(MeshConfig())
        postFeedback(AppLocalization.t("已退出登录", "Signed out"))
    }

    private suspend fun applyControlPlaneAuth(
        serverUrl: String,
        resp: ControlPlaneStateResponse,
        keepToken: String? = null
    ) {
        val token = resp.token?.takeIf { it.isNotBlank() } ?: keepToken.orEmpty()
        val session = AccountSession(
            serverUrl = serverUrl.trimEnd('/'),
            username = resp.user.username,
            token = token,
            deviceId = resp.device.deviceId,
            deviceName = resp.device.deviceName,
            virtualIp = resp.device.virtualIp,
            virtualCidr = resp.device.virtualCidr.ifBlank { "${resp.device.virtualIp}/24" }
        )
        _accountSession.value = session
        _accountDevices.value = resp.devices
        store.saveAccountSession(session)

        // Persist built-in EasyTier mesh config automatically (invisible to the user)
        val meshCfg = MeshConfig(
            hostname = resp.device.deviceName.ifBlank { "android" },
            ipv4 = session.virtualCidr,
            networkName = resp.mesh.networkName,
            networkSecret = resp.mesh.networkSecret,
            seedUri = resp.mesh.seedUri,
            port = resp.mesh.listenPort
        )
        store.saveMeshConfig(meshCfg)

        // Upload this phone's public Moonlight client cert AND local SSH public key so all user's hosts auto-trust it
        if (token.isNotBlank()) {
            val devName = session.deviceName.ifBlank { ControlPlaneClient.defaultDeviceName() }
            runCatching {
                val (uid, certPem) = withContext(Dispatchers.IO) { sunshineClient.getPublicIdentity() }
                controlPlaneClient.registerClientCert(
                    serverUrl = session.serverUrl,
                    token = token,
                    deviceName = devName,
                    uniqueId = uid,
                    certPem = certPem
                )
            }
            runCatching {
                val sshPub = withContext(Dispatchers.IO) { sshManager.ensureLocalSshPublicKey("nodedeck-$devName") }
                if (!sshPub.isNullOrBlank()) {
                    controlPlaneClient.registerSshPublicKey(
                        serverUrl = session.serverUrl,
                        token = token,
                        deviceName = devName,
                        publicKey = sshPub
                    )
                }
            }
        }

        // Auto-sync host devices from this account into SSH host list + Sunshine remote desktop configs
        mergeAccountHostDevices(resp.devices, selfDeviceId = session.deviceId)
        startAccountHeartbeatLoop()
    }

    private fun mergeAccountHostDevices(devices: List<ControlPlaneDevice>, selfDeviceId: String) {
        val hostDevices = devices.filter {
            it.deviceId != selfDeviceId &&
                (it.role == "host" || it.role == "both") &&
                it.virtualIp.isNotBlank()
        }
        if (hostDevices.isEmpty()) return

        val nextHosts = _hosts.value.toMutableList()
        val nextSunshine = _sunshineConfigs.value.toMutableList()
        val defaultKey = store.listPrivateKeys().firstOrNull { it == "id_ed25519" || it == "id_rsa" }.orEmpty()

        for (dev in hostDevices) {
            val idx = nextHosts.indexOfFirst {
                it.alias.equals(dev.deviceName, ignoreCase = true) ||
                    it.hostName.equals(dev.virtualIp, ignoreCase = true)
            }
            if (idx >= 0) {
                val old = nextHosts[idx]
                nextHosts[idx] = old.copy(
                    hostName = dev.virtualIp,
                    user = dev.sshUser.ifBlank { old.user },
                    port = if (dev.sshPort > 0) dev.sshPort else old.port
                )
            } else {
                nextHosts.add(
                    SSHHost(
                        alias = dev.deviceName,
                        hostName = dev.virtualIp,
                        user = dev.sshUser.ifBlank { "root" },
                        port = if (dev.sshPort > 0) dev.sshPort else 22,
                        authType = if (defaultKey.isNotBlank()) SSHAuthType.PRIVATE_KEY else SSHAuthType.PASSWORD,
                        privateKeyName = defaultKey
                    )
                )
            }

            if (dev.sunshineEnabled) {
                val sIdx = nextSunshine.indexOfFirst {
                    it.hostAlias.equals(dev.deviceName, ignoreCase = true) ||
                        it.address.equals(dev.virtualIp, ignoreCase = true)
                }
                val cfg = SunshineHostConfig(
                    hostAlias = dev.deviceName,
                    address = dev.virtualIp,
                    httpPort = dev.sunshineHttpPort,
                    httpsPort = dev.sunshineHttpsPort,
                    serverName = dev.deviceName,
                    isPaired = true
                )
                if (sIdx >= 0) nextSunshine[sIdx] = cfg.copy(id = nextSunshine[sIdx].id) else nextSunshine.add(cfg)
            }
        }

        _hosts.value = nextHosts
        store.saveHosts(nextHosts)
        _snapshots.update { map ->
            nextHosts.associate { h -> h.id to (map[h.id]?.copy(host = h) ?: HostSnapshot(host = h)) }
        }
        _sunshineConfigs.value = nextSunshine
        store.saveSunshineHosts(nextSunshine)
    }

    private fun startAccountHeartbeatLoop() {
        accountHeartbeatJob?.cancel()
        accountHeartbeatJob = viewModelScope.launch {
            while (isActive && _accountSession.value.isLoggedIn) {
                delay(45_000L)
                val sess = _accountSession.value
                if (!sess.isLoggedIn) break
                runCatching {
                    val lanIps = MeshConfigCodec.discoverLanIps(sess.virtualCidr)
                    val resp = controlPlaneClient.heartbeat(
                        serverUrl = sess.serverUrl,
                        token = sess.token,
                        deviceName = sess.deviceName.ifBlank { ControlPlaneClient.defaultDeviceName() },
                        lanIps = lanIps
                    )
                    _accountDevices.value = resp.devices
                    mergeAccountHostDevices(resp.devices, selfDeviceId = sess.deviceId)
                }
            }
        }
    }

    fun clearFeedback() {
        _feedbackMessage.value = null
    }

    fun postFeedback(msg: String) {
        _feedbackMessage.value = msg
    }

    fun setFilter(f: HostFilter) {
        _filter.value = f
    }

    fun setSearchQuery(q: String) {
        _searchQuery.value = q
    }

    fun setLanguage(lang: AppLanguage) {
        store.setLanguage(lang)
        AppLocalization.setLanguage(lang)
    }

    fun cycleLanguage() {
        val next = when (AppLocalization.language.value) {
            AppLanguage.SYSTEM -> AppLanguage.ZH_HANS
            AppLanguage.ZH_HANS -> AppLanguage.EN
            AppLanguage.EN -> AppLanguage.SYSTEM
        }
        setLanguage(next)
    }

    fun setStreamResolution(preset: StreamResolutionPreset) {
        _streamResolution.value = preset
        store.setStreamResolution(preset)
    }

    fun setStreamRefreshRate(rate: StreamRefreshRate) {
        _streamRefreshRate.value = rate
        store.setStreamRefreshRate(rate)
    }

    fun setRefreshIntervalSec(sec: Int) {
        _refreshIntervalSec.value = sec
        store.setRefreshIntervalSec(sec)
        restartAutoRefreshLoop()
    }

    fun togglePinned(alias: String) {
        val next = _pinnedAliases.value.toMutableSet()
        if (!next.add(alias)) next.remove(alias)
        _pinnedAliases.value = next
        store.setPinnedAliases(next)
    }

    fun upsertHost(host: SSHHost) {
        val list = _hosts.value.toMutableList()
        val idx = list.indexOfFirst { it.id == host.id }
        if (idx >= 0) list[idx] = host else list.add(host)
        _hosts.value = list
        store.saveHosts(list)
        _snapshots.update { current ->
            val existing = current[host.id]
            current + (host.id to (existing?.copy(host = host) ?: HostSnapshot(host = host)))
        }
        refreshHost(host.id)
    }

    fun deleteHost(hostId: String) {
        val target = _hosts.value.firstOrNull { it.id == hostId } ?: return
        val nextHosts = _hosts.value.filterNot { it.id == hostId }
        _hosts.value = nextHosts
        store.saveHosts(nextHosts)
        _snapshots.update { it - hostId }

        // Stop and remove associated forwards
        val forwardsToStop = _portForwards.value.filter { it.hostAlias == target.alias }
        forwardsToStop.forEach { sshManager.stopPortForward(it.id) }
        if (forwardsToStop.isNotEmpty()) {
            val remainingForwards = _portForwards.value.filterNot { it.hostAlias == target.alias }
            _portForwards.value = remainingForwards
            store.savePortForwards(remainingForwards)
            syncForwardService()
        }
    }

    fun importSshConfigText(rawConfig: String): Int {
        val parsed = SshConfigParser.parseHosts(rawConfig)
        if (parsed.isEmpty()) return 0
        val current = _hosts.value.toMutableList()
        var addedOrUpdated = 0
        for (item in parsed) {
            val idx = current.indexOfFirst { it.alias.equals(item.alias, ignoreCase = true) }
            if (idx >= 0) {
                val old = current[idx]
                current[idx] = item.copy(
                    id = old.id,
                    authType = old.authType,
                    password = old.password,
                    privateKeyName = old.privateKeyName,
                    privateKeyPassphrase = old.privateKeyPassphrase
                )
            } else {
                current.add(item)
            }
            addedOrUpdated++
        }
        _hosts.value = current
        store.saveHosts(current)
        _snapshots.update { map ->
            current.associate { h -> h.id to (map[h.id]?.copy(host = h) ?: HostSnapshot(host = h)) }
        }
        refreshAllHosts()
        return addedOrUpdated
    }

    fun savePrivateKey(name: String, pem: String): String = store.savePrivateKey(name, pem)
    fun listPrivateKeys(): List<String> = store.listPrivateKeys()

    private fun resolveBestLatencyMs(host: SSHHost, measuredRtt: Double): Double {
        val meshPeerLat = MeshRuntimeController.snapshot.value.peers
            .firstOrNull { it.virtualIpv4.equals(host.hostName, ignoreCase = true) }
            ?.latencyMs
            ?.takeIf { it > 0.5 && it < 5_000.0 }
        return if (meshPeerLat != null && (measuredRtt > meshPeerLat * 2.5 || measuredRtt > 500.0)) {
            meshPeerLat
        } else {
            measuredRtt
        }
    }

    fun refreshHost(hostId: String) {
        val host = _hosts.value.firstOrNull { it.id == hostId } ?: return
        viewModelScope.launch {
            _snapshots.update { map ->
                val cur = map[hostId] ?: HostSnapshot(host = host)
                map + (hostId to cur.copy(host = host, state = HostConnectionState.CHECKING, errorMessage = null))
            }
            val (metrics, rtt, err) = refreshSemaphore.withPermit {
                sshManager.collectMetrics(host, _hosts.value)
            }
            val displayRtt = resolveBestLatencyMs(host, rtt)
            _snapshots.update { map ->
                val cur = map[hostId] ?: HostSnapshot(host = host)
                if (metrics != null) {
                    map + (hostId to cur.copy(
                        host = host,
                        state = HostConnectionState.ONLINE,
                        metrics = metrics,
                        latencyMs = displayRtt,
                        errorMessage = null,
                        lastUpdatedMs = System.currentTimeMillis()
                    ))
                } else {
                    map + (hostId to cur.copy(
                        host = host,
                        state = HostConnectionState.OFFLINE,
                        latencyMs = displayRtt,
                        errorMessage = err ?: "Offline",
                        lastUpdatedMs = System.currentTimeMillis()
                    ))
                }
            }
        }
    }

    fun refreshAllHosts() {
        val list = _hosts.value
        if (list.isEmpty()) return
        viewModelScope.launch {
            _isRefreshingAll.value = true
            try {
                val jobs = list.map { host ->
                    launch {
                        _snapshots.update { map ->
                            val cur = map[host.id] ?: HostSnapshot(host = host)
                            map + (host.id to cur.copy(host = host, state = HostConnectionState.CHECKING))
                        }
                        val (metrics, rtt, err) = refreshSemaphore.withPermit {
                            sshManager.collectMetrics(host, _hosts.value)
                        }
                        val displayRtt = resolveBestLatencyMs(host, rtt)
                        _snapshots.update { map ->
                            val cur = map[host.id] ?: HostSnapshot(host = host)
                            if (metrics != null) {
                                map + (host.id to cur.copy(
                                    host = host,
                                    state = HostConnectionState.ONLINE,
                                    metrics = metrics,
                                    latencyMs = displayRtt,
                                    errorMessage = null,
                                    lastUpdatedMs = System.currentTimeMillis()
                                ))
                            } else {
                                map + (host.id to cur.copy(
                                    host = host,
                                    state = HostConnectionState.OFFLINE,
                                    latencyMs = displayRtt,
                                    errorMessage = err ?: "Offline",
                                    lastUpdatedMs = System.currentTimeMillis()
                                ))
                            }
                        }
                    }
                }
                jobs.forEach { it.join() }
            } finally {
                _isRefreshingAll.value = false
            }
        }
    }

    private fun restartAutoRefreshLoop() {
        autoRefreshJob?.cancel()
        val intervalSec = _refreshIntervalSec.value
        if (intervalSec <= 0) return
        autoRefreshJob = viewModelScope.launch {
            while (isActive) {
                delay(intervalSec * 1000L)
                if (_hosts.value.isNotEmpty() && !_isRefreshingAll.value) {
                    refreshAllHosts()
                }
            }
        }
    }

    // MARK: - Port Forwards

    fun savePortForward(config: SSHPortForwardConfig) {
        val list = _portForwards.value.toMutableList()
        val idx = list.indexOfFirst { it.id == config.id }
        if (idx >= 0) list[idx] = config else list.add(config)
        _portForwards.value = list
        store.savePortForwards(list)
    }

    fun deletePortForward(id: String) {
        sshManager.stopPortForward(id)
        val next = _portForwards.value.filterNot { it.id == id }
        _portForwards.value = next
        store.savePortForwards(next)
        syncForwardService()
    }

    fun togglePortForward(config: SSHPortForwardConfig, host: SSHHost) {
        if (sshManager.isForwardActive(config.id)) {
            sshManager.stopPortForward(config.id)
            syncForwardService()
            postFeedback(AppLocalization.t("已停止转发: ${config.label}", "Stopped forward: ${config.label}"))
        } else {
            viewModelScope.launch {
                runCatching { sshManager.startPortForward(config, host, _hosts.value) }
                    .onSuccess {
                        syncForwardService()
                        postFeedback(AppLocalization.t("端口转发已开启: ${config.specSummary}", "Forward active: ${config.specSummary}"))
                    }
                    .onFailure {
                        syncForwardService()
                        postFeedback(it.message ?: "Failed to start forward")
                    }
            }
        }
    }

    private fun syncForwardService() {
        val active = sshManager.activeForwardIds()
        _activeForwardIds.value = active
        PortForwardService.update(getApplication(), active.size)
    }

    // MARK: - Sunshine / Moonlight Remote Desktop Pairing & Profiles

    fun sunshineForHost(host: SSHHost): SunshineHostConfig? =
        _sunshineConfigs.value.firstOrNull {
            it.hostAlias.equals(host.alias, ignoreCase = true) ||
                it.address.equals(host.hostName, ignoreCase = true)
        }

    fun upsertSunshineConfig(config: SunshineHostConfig) {
        val list = _sunshineConfigs.value.toMutableList()
        val idx = list.indexOfFirst {
            it.hostAlias.equals(config.hostAlias, ignoreCase = true) ||
                it.address.equals(config.address, ignoreCase = true)
        }
        if (idx >= 0) list[idx] = config else list.add(config)
        _sunshineConfigs.value = list
        store.saveSunshineHosts(list)
    }

    fun removeSunshineConfig(hostAlias: String) {
        val next = _sunshineConfigs.value.filterNot { it.hostAlias.equals(hostAlias, ignoreCase = true) }
        _sunshineConfigs.value = next
        store.saveSunshineHosts(next)
    }

    fun pairZeroPinViaSsh(
        host: SSHHost,
        httpPort: Int,
        onResult: (Result<SunshineHostConfig>) -> Unit
    ) {
        viewModelScope.launch {
            val res = runCatching { sunshineClient.pairViaSsh(host, _hosts.value, httpPort) }
            res.onSuccess { cfg ->
                upsertSunshineConfig(cfg)
                postFeedback(AppLocalization.t("SSH 免 PIN 配对成功 (${cfg.address}:${cfg.httpPort})", "Zero-PIN SSH paired (${cfg.address}:${cfg.httpPort})"))
            }
            onResult(res)
        }
    }

    fun pairWithPin(
        hostAlias: String,
        address: String,
        httpPort: Int,
        pin: String,
        onResult: (Result<SunshineHostConfig>) -> Unit
    ) {
        viewModelScope.launch {
            val res = runCatching { sunshineClient.pairWithPin(hostAlias, address, httpPort, pin) }
            res.onSuccess { cfg ->
                upsertSunshineConfig(cfg)
                postFeedback(AppLocalization.t("PIN 配对成功 (${cfg.address}:${cfg.httpPort})", "PIN paired (${cfg.address}:${cfg.httpPort})"))
            }
            onResult(res)
        }
    }

    fun profileForHost(alias: String): LinuxHostProfile =
        _hostProfiles.value.firstOrNull { it.hostAlias.equals(alias, ignoreCase = true) }
            ?: LinuxHostProfile(hostAlias = alias)

    fun saveAndReconcileHostProfile(
        profile: LinuxHostProfile,
        host: SSHHost,
        onResult: (Result<Boolean>) -> Unit
    ) {
        val list = _hostProfiles.value.toMutableList()
        val idx = list.indexOfFirst { it.hostAlias.equals(profile.hostAlias, ignoreCase = true) }
        if (idx >= 0) list[idx] = profile else list.add(profile)
        _hostProfiles.value = list
        store.saveHostProfiles(list)

        viewModelScope.launch {
            val res = runCatching { hostProfileManager.reconcile(profile, host, _hosts.value) }
            res.onSuccess { restarted ->
                val msg = if (restarted) {
                    AppLocalization.t("配置已同步并重启远端服务", "Profile synced & remote host reloaded")
                } else {
                    AppLocalization.t("配置已写入 ~/.config/nodedeck/host/host.conf", "Profile written to host.conf")
                }
                postFeedback(msg)
            }
            onResult(res)
        }
    }

    override fun onCleared() {
        super.onCleared()
        autoRefreshJob?.cancel()
        accountHeartbeatJob?.cancel()
    }
}
