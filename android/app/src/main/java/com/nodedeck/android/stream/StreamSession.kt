package com.nodedeck.android.stream

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.view.Surface
import com.nodedeck.android.core.ClipboardSyncManager
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.core.SecureStore
import com.nodedeck.android.core.SshManager
import com.nodedeck.android.core.StreamQualityMath
import com.nodedeck.android.core.StreamRefreshRate
import com.nodedeck.android.core.StreamResolutionPreset
import com.nodedeck.android.core.SunshineClient
import com.nodedeck.android.core.SunshineLaunchSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed class StreamConnectionState {
    data object Idle : StreamConnectionState()
    data class Connecting(val message: String) : StreamConnectionState()
    data object Streaming : StreamConnectionState()
    data class Disconnected(val reason: String?) : StreamConnectionState()
}

class StreamSession(
    private val context: Context,
    private val store: SecureStore,
    private val sshManager: SshManager,
    private val sunshineClient: SunshineClient,
    private val clipboardSyncManager: ClipboardSyncManager
) : MoonlightCallbackListener {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _state = MutableStateFlow<StreamConnectionState>(StreamConnectionState.Idle)
    val state: StateFlow<StreamConnectionState> = _state.asStateFlow()

    private val _stats = MutableStateFlow(StreamPerformanceStats())
    val stats: StateFlow<StreamPerformanceStats> = _stats.asStateFlow()

    private val _targetWidth = MutableStateFlow(store.getStreamResolution().width)
    val targetWidth: StateFlow<Int> = _targetWidth.asStateFlow()

    private val _targetHeight = MutableStateFlow(store.getStreamResolution().height)
    val targetHeight: StateFlow<Int> = _targetHeight.asStateFlow()

    private val _targetFps = MutableStateFlow(store.getStreamRefreshRate().fps)
    val targetFps: StateFlow<Int> = _targetFps.asStateFlow()

    private val _streamTitle = MutableStateFlow("")
    val streamTitle: StateFlow<String> = _streamTitle.asStateFlow()

    private val _showHud = MutableStateFlow(false)
    val showHud: StateFlow<Boolean> = _showHud.asStateFlow()

    private val _touchpadMode = MutableStateFlow(store.getTouchpadMode())
    val touchpadMode: StateFlow<Boolean> = _touchpadMode.asStateFlow()

    private val _privacyScreenEnabled = MutableStateFlow(false)
    val privacyScreenEnabled: StateFlow<Boolean> = _privacyScreenEnabled.asStateFlow()

    private val _clipboardStatus = MutableStateFlow<String?>(null)
    val clipboardStatus: StateFlow<String?> = _clipboardStatus.asStateFlow()

    private val videoDecoder = MediaCodecVideoDecoder { newStats ->
        _stats.value = newStats
    }
    private val audioPlayer = OpusAudioPlayer()

    private var launchJob: Job? = null
    private var currentHost: SSHHost? = null
    private var allHosts: List<SSHHost> = emptyList()
    private var currentAddress = ""
    private var currentHttpPort = 47989
    private var activeLaunch: SunshineLaunchSession? = null

    val hasSshHost: Boolean get() = currentHost != null

    fun attachSurface(surface: Surface?) {
        videoDecoder.attachSurface(surface)
    }

    fun setShowHud(show: Boolean) {
        _showHud.value = show
    }

    fun setTouchpadMode(enabled: Boolean) {
        _touchpadMode.value = enabled
        store.setTouchpadMode(enabled)
    }

    fun start(
        host: SSHHost?,
        hosts: List<SSHHost>,
        address: String,
        httpPort: Int,
        width: Int = store.getStreamResolution().width,
        height: Int = store.getStreamResolution().height,
        fps: Int = store.getStreamRefreshRate().fps
    ) {
        launchJob?.cancel()
        val gen = MoonlightNative.nextGeneration()
        MoonlightNative.interruptAndDisableInput()

        currentHost = host
        allHosts = hosts
        currentAddress = address
        currentHttpPort = httpPort
        _targetWidth.value = width
        _targetHeight.value = height
        _targetFps.value = fps
        _streamTitle.value = host?.alias ?: address

        StreamResolutionPreset.fromDimensions(width, height)?.let { store.setStreamResolution(it) }
        store.setStreamRefreshRate(StreamRefreshRate.fromFps(fps))

        val bitrateKbps = StreamQualityMath.recommendedBitrateKbps(width, height, fps)
        _state.value = StreamConnectionState.Connecting("Negotiating with $address:$httpPort…")

        launchJob = scope.launch(Dispatchers.IO) {
            try {
                MoonlightNative.stopConnectionBlocking()
                if (!MoonlightNative.isCurrent(gen)) return@launch

                val launched = sunshineClient.launchStream(
                    address = address,
                    httpPort = httpPort,
                    width = width,
                    height = height,
                    fps = fps
                )
                if (!MoonlightNative.isCurrent(gen)) return@launch
                activeLaunch = launched
                _streamTitle.value = "${host?.alias ?: address} · ${launched.appTitle}"
                _state.value = StreamConnectionState.Connecting("Starting ${width}×${height} @ ${fps}Hz…")

                val rc = MoonlightNative.startConnectionBlocking(
                    generation = gen,
                    listener = this@StreamSession,
                    address = launched.address,
                    appVersion = launched.appVersion,
                    gfeVersion = launched.gfeVersion,
                    rtspUrl = launched.rtspSessionUrl,
                    serverCodecModeSupport = launched.serverCodecModeSupport,
                    width = width,
                    height = height,
                    fps = fps,
                    bitrateKbps = bitrateKbps,
                    rikey = launched.rikey,
                    rikeyId = launched.rikeyId,
                    enableHevc = true
                ) ?: return@launch

                if (rc != 0 && MoonlightNative.isCurrent(gen)) {
                    _state.value = StreamConnectionState.Disconnected("LiStartConnection failed ($rc)")
                }
            } catch (t: Throwable) {
                if (MoonlightNative.isCurrent(gen)) {
                    _state.value = StreamConnectionState.Disconnected(t.message ?: "Connection failed")
                }
            }
        }
    }

    fun switchResolution(preset: StreamResolutionPreset) {
        if (preset.width == _targetWidth.value && preset.height == _targetHeight.value) return
        if (currentAddress.isBlank()) return
        start(currentHost, allHosts, currentAddress, currentHttpPort, preset.width, preset.height, _targetFps.value)
    }

    fun switchRefreshRate(rate: StreamRefreshRate) {
        if (rate.fps == _targetFps.value) return
        if (currentAddress.isBlank()) return
        start(currentHost, allHosts, currentAddress, currentHttpPort, _targetWidth.value, _targetHeight.value, rate.fps)
    }

    fun togglePrivacyScreen() {
        val host = currentHost ?: return
        val next = !_privacyScreenEnabled.value
        scope.launch(Dispatchers.IO) {
            val cmd = if (next) {
                "DISPLAY=:0 xset dpms force off 2>/dev/null || true"
            } else {
                "DISPLAY=:0 xset dpms force on 2>/dev/null || true"
            }
            val res = runCatching { sshManager.exec(host, allHosts, cmd, timeoutMs = 6_000) }.getOrNull()
            if (res != null && res.exitCode == 0) {
                _privacyScreenEnabled.value = next
            }
        }
    }

    fun pushAndroidClipboardToRemote() {
        val host = currentHost ?: return
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val text = cm.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
        if (text.isEmpty()) {
            _clipboardStatus.value = "Phone clipboard is empty"
            return
        }
        _clipboardStatus.value = "Pushing…"
        scope.launch(Dispatchers.IO) {
            runCatching { clipboardSyncManager.pushText(text, host, allHosts) }
                .onSuccess { _clipboardStatus.value = "Pushed (${text.length} chars)" }
                .onFailure { _clipboardStatus.value = it.message ?: "Push failed" }
        }
    }

    fun pullRemoteClipboardToAndroid() {
        val host = currentHost ?: return
        _clipboardStatus.value = "Pulling…"
        scope.launch(Dispatchers.IO) {
            runCatching { clipboardSyncManager.pullText(host, allHosts) }
                .onSuccess { text ->
                    scope.launch(Dispatchers.Main) {
                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        cm.setPrimaryClip(ClipData.newPlainText("NodeDeck", text))
                    }
                    _clipboardStatus.value = "Pulled (${text.length} chars)"
                }
                .onFailure { _clipboardStatus.value = it.message ?: "Pull failed" }
        }
    }

    fun stop(quitRemoteApp: Boolean) {
        MoonlightNative.nextGeneration()
        MoonlightNative.interruptAndDisableInput()
        launchJob?.cancel()
        launchJob = null
        val launched = activeLaunch
        activeLaunch = null
        val hostToRestore = if (_privacyScreenEnabled.value) currentHost else null
        _privacyScreenEnabled.value = false

        scope.launch(Dispatchers.IO) {
            MoonlightNative.stopConnectionBlocking()
            if (hostToRestore != null) {
                runCatching {
                    sshManager.exec(hostToRestore, allHosts, "DISPLAY=:0 xset dpms force on 2>/dev/null || true", timeoutMs = 5_000)
                }
            }
            if (quitRemoteApp && launched != null) {
                sunshineClient.cancelSession(launched.address, launched.httpsPort)
            }
        }
        videoDecoder.cleanup()
        audioPlayer.cleanup()
        _state.value = StreamConnectionState.Disconnected(null)
    }

    fun destroy() {
        stop(quitRemoteApp = false)
        scope.cancel()
    }

    // MARK: - MoonlightCallbackListener

    override fun onVideoSetup(videoFormat: Int, width: Int, height: Int, redrawRate: Int): Int =
        videoDecoder.setup(videoFormat, width, height, redrawRate)

    override fun onVideoCleanup() = videoDecoder.cleanup()

    override fun onSubmitDecodeUnit(data: ByteArray, frameType: Int, hostLatencyTenthsMs: Int, presentationTimeUs: Long): Int =
        videoDecoder.submitDecodeUnit(data, frameType, hostLatencyTenthsMs, presentationTimeUs)

    override fun onAudioInit(sampleRate: Int, channelCount: Int, samplesPerFrame: Int): Int =
        audioPlayer.init(sampleRate, channelCount, samplesPerFrame)

    override fun onAudioDecodeAndPlay(data: ByteArray) = audioPlayer.decodeAndPlay(data)

    override fun onAudioCleanup() = audioPlayer.cleanup()

    override fun onStageStarting(stageName: String) {
        _state.value = StreamConnectionState.Connecting("Connecting: $stageName…")
    }

    override fun onStageFailed(stageName: String, errorCode: Int) {
        _state.value = StreamConnectionState.Disconnected("$stageName failed (error $errorCode)")
    }

    override fun onConnectionStarted() {
        _state.value = StreamConnectionState.Streaming
    }

    override fun onConnectionTerminated(errorCode: Int) {
        val reason = if (errorCode == 0) null else "Stream terminated (error $errorCode)"
        _state.value = StreamConnectionState.Disconnected(reason)
    }
}
