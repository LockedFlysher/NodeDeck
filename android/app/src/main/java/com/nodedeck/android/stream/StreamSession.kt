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
import kotlinx.coroutines.delay
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

data class RemoteDisplayInfo(
    val id: String,
    val label: String,
    val resolution: String,
    val isPrimary: Boolean,
    val isSelected: Boolean
)

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

    private val _audioMuted = MutableStateFlow(false)
    val audioMuted: StateFlow<Boolean> = _audioMuted.asStateFlow()

    private val _remoteDisplays = MutableStateFlow<List<RemoteDisplayInfo>>(emptyList())
    val remoteDisplays: StateFlow<List<RemoteDisplayInfo>> = _remoteDisplays.asStateFlow()

    private val _switchingDisplay = MutableStateFlow(false)
    val switchingDisplay: StateFlow<Boolean> = _switchingDisplay.asStateFlow()

    private val _displayStatus = MutableStateFlow<String?>(null)
    val displayStatus: StateFlow<String?> = _displayStatus.asStateFlow()

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

    fun setAudioMuted(muted: Boolean) {
        _audioMuted.value = muted
        audioPlayer.setMuted(muted)
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
        if (host != null && _remoteDisplays.value.isEmpty()) {
            loadRemoteDisplays()
        }

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

    fun loadRemoteDisplays() {
        val host = currentHost ?: return
        scope.launch(Dispatchers.IO) {
            val script = """
                python3 - <<'PY'
                import json, os, re, subprocess
                from pathlib import Path

                sysname = os.uname().sysname
                selected = ""
                if sysname == "Darwin":
                    conf = Path.home() / "Library/Application Support/NodeDeck/host/host.conf"
                    if conf.exists():
                        m = re.search(r"^\s*output_name\s*=\s*(.+)$", conf.read_text(errors="ignore"), re.M)
                        if m: selected = m.group(1).strip()
                    log_path = Path.home() / "Library/Logs/nodedeck-host.log"
                    displays = []
                    if log_path.exists():
                        txt = log_path.read_text(errors="ignore")
                        marker = "Currently available display devices:"
                        idx = txt.rfind(marker)
                        if idx >= 0:
                            chunk = txt[idx + len(marker):]
                            s = chunk.find("[")
                            if s >= 0:
                                depth, end = 0, -1
                                for i, ch in enumerate(chunk[s:]):
                                    if ch == "[": depth += 1
                                    elif ch == "]":
                                        depth -= 1
                                        if depth == 0:
                                            end = s + i + 1
                                            break
                                if end > s:
                                    arr = json.loads(chunk[s:end])
                                    for item in arr:
                                        name = str(item.get("display_name") or item.get("friendly_name") or "")
                                        info = item.get("info") or {}
                                        res = info.get("resolution") or {}
                                        w, h = res.get("width", 0), res.get("height", 0)
                                        prim = bool(info.get("primary"))
                                        displays.append((name, f"Display {name}", f"{w}x{h}" if w and h else "", prim))
                    for d_id, lbl, res_s, prim in displays:
                        sel = (selected == d_id) or (not selected and prim)
                        print(f"DISP|{d_id}|{lbl}|{res_s}|{1 if prim else 0}|{1 if sel else 0}")
                else:
                    for cpath in (Path.home() / ".config/nodedeck/host/host.conf", Path.home() / ".config/sunshine/sunshine.conf"):
                        if cpath.exists():
                            m = re.search(r"^\s*output_name\s*=\s*(.+)$", cpath.read_text(errors="ignore"), re.M)
                            if m:
                                selected = m.group(1).strip()
                                break
                    lines = []
                    for cand_disp in (os.environ.get("DISPLAY", ""), ":0", ":99", ":1"):
                        if not cand_disp:
                            continue
                        env = os.environ.copy()
                        env["DISPLAY"] = cand_disp
                        out = subprocess.run(["xrandr", "--listmonitors"], env=env, capture_output=True, text=True).stdout
                        found = [ln.strip() for ln in out.splitlines() if ":" in ln and not ln.startswith("Monitors:")]
                        if found:
                            lines = found
                            break
                    for idx, ln in enumerate(lines):
                        parts = ln.split()
                        if len(parts) >= 4:
                            d_id = parts[-1]
                            prim = "*" in parts[1]
                            geom = re.sub(r"/\d+", "", parts[2]).split("+")[0]
                            sel = (selected == d_id) or (selected == str(idx)) or (not selected and prim)
                            print(f"DISP|{d_id}|{d_id}|{geom}|{1 if prim else 0}|{1 if sel else 0}")
                PY
            """.trimIndent()

            val res = runCatching { sshManager.exec(host, allHosts, "/bin/sh -s", stdinText = script, timeoutMs = 8_000) }.getOrNull()
            if (res != null && res.exitCode == 0) {
                val parsed = res.stdout.lines()
                    .filter { it.startsWith("DISP|") }
                    .mapNotNull { line ->
                        val p = line.split("|")
                        if (p.size >= 6) {
                            RemoteDisplayInfo(
                                id = p[1],
                                label = p[2],
                                resolution = p[3],
                                isPrimary = p[4] == "1",
                                isSelected = p[5] == "1"
                            )
                        } else null
                    }
                _remoteDisplays.value = parsed
            }
        }
    }

    fun switchRemoteDisplay(display: RemoteDisplayInfo) {
        val host = currentHost ?: return
        if (_switchingDisplay.value) return
        _switchingDisplay.value = true
        _displayStatus.value = "Switching to ${display.label}…"
        scope.launch(Dispatchers.IO) {
            try {
                val safeId = display.id.replace("'", "").replace("\"", "").replace("\n", "")
                val script = """
                    python3 - <<'PY'
                    import os, re, subprocess
                    from pathlib import Path

                    target = "$safeId"
                    sysname = os.uname().sysname
                    if sysname == "Darwin":
                        conf = Path.home() / "Library/Application Support/NodeDeck/host/host.conf"
                    else:
                        c1 = Path.home() / ".config/nodedeck/host/host.conf"
                        c2 = Path.home() / ".config/sunshine/sunshine.conf"
                        conf = c1 if c1.exists() else c2

                    if not conf.exists():
                        raise SystemExit("Host config not found")

                    txt = conf.read_text(encoding="utf-8", errors="ignore")
                    if re.search(r"^\s*output_name\s*=", txt, re.M):
                        txt = re.sub(r"^\s*output_name\s*=.*$", f"output_name = {target}", txt, flags=re.M)
                    else:
                        if txt and not txt.endswith("\n"):
                            txt += "\n"
                        txt += f"output_name = {target}\n"
                    conf.write_text(txt, encoding="utf-8")

                    if sysname == "Darwin":
                        uid = os.getuid()
                        subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/io.nodedeck.host"], check=False)
                    else:
                        for svc in ("nodedeck-host", "foundation-sunshine", "sunshine"):
                            r = subprocess.run(["systemctl", "--user", "is-active", "--quiet", svc])
                            if r.returncode == 0:
                                subprocess.run(["systemctl", "--user", "restart", svc], check=False)
                                break
                    print("SWITCH_OK")
                    PY
                """.trimIndent()
                val res = sshManager.exec(host, allHosts, "/bin/sh -s", stdinText = script, timeoutMs = 10_000)
                if (res.exitCode == 0 && res.stdout.contains("SWITCH_OK")) {
                    _remoteDisplays.value = _remoteDisplays.value.map {
                        it.copy(isSelected = it.id == display.id)
                    }
                    _displayStatus.value = "Switched to ${display.label}, reconnecting…"
                    delay(1_800)
                    _displayStatus.value = null
                    _switchingDisplay.value = false
                    start(
                        host = currentHost,
                        hosts = allHosts,
                        address = currentAddress,
                        httpPort = currentHttpPort,
                        width = _targetWidth.value,
                        height = _targetHeight.value,
                        fps = _targetFps.value
                    )
                } else {
                    _displayStatus.value = res.stderr.trim().ifBlank { "Display switch failed" }
                    _switchingDisplay.value = false
                }
            } catch (t: Throwable) {
                _displayStatus.value = t.message ?: "Display switch failed"
                _switchingDisplay.value = false
            }
        }
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
