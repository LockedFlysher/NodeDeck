package com.nodedeck.android.stream

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.nodedeck.android.NodeDeckApp
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.core.StreamQualityMath
import com.nodedeck.android.core.StreamRefreshRate
import com.nodedeck.android.core.StreamResolutionPreset
import com.nodedeck.android.ui.theme.NodeDeckColors
import com.nodedeck.android.ui.theme.NodeDeckTheme
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

class StreamActivity : ComponentActivity() {
    private lateinit var session: StreamSession
    private var launchHost: SSHHost? = null
    private var allHosts: List<SSHHost> = emptyList()
    private var launchAddress: String = ""
    private var launchHttpPort: Int = 47989

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureImmersiveWindow()

        val app = NodeDeckApp.from(this)
        allHosts = app.store.loadHosts()
        val hostId = intent.getStringExtra(EXTRA_HOST_ID)
        launchHost = allHosts.firstOrNull { it.id == hostId }
        launchAddress = intent.getStringExtra(EXTRA_ADDRESS).orEmpty().ifBlank { launchHost?.hostName.orEmpty() }
        launchHttpPort = intent.getIntExtra(EXTRA_HTTP_PORT, 47989)
        val initialWidth = intent.getIntExtra(EXTRA_WIDTH, app.store.getStreamResolution().width)
        val initialHeight = intent.getIntExtra(EXTRA_HEIGHT, app.store.getStreamResolution().height)
        val initialFps = intent.getIntExtra(EXTRA_FPS, app.store.getStreamRefreshRate().fps)

        session = StreamSession(
            context = this,
            store = app.store,
            sshManager = app.sshManager,
            sunshineClient = app.sunshineClient,
            clipboardSyncManager = app.clipboardSyncManager
        )

        session.start(
            host = launchHost,
            hosts = allHosts,
            address = launchAddress,
            httpPort = launchHttpPort,
            width = initialWidth,
            height = initialHeight,
            fps = initialFps
        )

        setContent {
            NodeDeckTheme(darkTheme = true) {
                StreamScreen(
                    session = session,
                    onReconnect = {
                        session.start(
                            host = launchHost,
                            hosts = allHosts,
                            address = launchAddress,
                            httpPort = launchHttpPort,
                            width = session.targetWidth.value,
                            height = session.targetHeight.value,
                            fps = session.targetFps.value
                        )
                    },
                    onDisconnect = { quitApp ->
                        session.stop(quitRemoteApp = quitApp)
                        finish()
                    }
                )
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemBars()
        } else {
            MoonlightNative.releaseAllRemoteModifiers()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::session.isInitialized) {
            session.destroy()
        }
    }

    private fun configureImmersiveWindow() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        hideSystemBars()
    }

    private fun hideSystemBars() {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
    }

    companion object {
        private const val EXTRA_HOST_ID = "host_id"
        private const val EXTRA_ADDRESS = "address"
        private const val EXTRA_HTTP_PORT = "http_port"
        private const val EXTRA_WIDTH = "width"
        private const val EXTRA_HEIGHT = "height"
        private const val EXTRA_FPS = "fps"

        fun createIntent(
            context: Context,
            hostId: String?,
            address: String,
            httpPort: Int,
            width: Int,
            height: Int,
            fps: Int
        ): Intent = Intent(context, StreamActivity::class.java).apply {
            putExtra(EXTRA_HOST_ID, hostId)
            putExtra(EXTRA_ADDRESS, address)
            putExtra(EXTRA_HTTP_PORT, httpPort)
            putExtra(EXTRA_WIDTH, width)
            putExtra(EXTRA_HEIGHT, height)
            putExtra(EXTRA_FPS, fps)
        }
    }
}

private class StreamTouchInputController(
    private val view: View,
    private val isTouchpadMode: () -> Boolean,
    private val getVideoDims: () -> Pair<Int, Int>
) : View.OnTouchListener {

    private val handler = Handler(Looper.getMainLooper())
    private val density = view.resources.displayMetrics.density
    private val tapSlopPx = 12f * density

    private var downTimeMs = 0L
    private var maxPointers = 0
    private var startX = 0f
    private var startY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var lastTwoX = 0f
    private var lastTwoY = 0f
    private var movedBeyondSlop = false
    private var longPressDragging = false
    private var scrollAccumY = 0f
    private var scrollAccumX = 0f

    private val longPressRunnable = Runnable {
        if (!movedBeyondSlop && maxPointers == 1 && isTouchpadMode()) {
            longPressDragging = true
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
        }
    }

    override fun onTouch(v: View, event: MotionEvent): Boolean {
        val touchpad = isTouchpadMode()
        return if (touchpad) handleTouchpad(event) else handleDirectTouch(event)
    }

    private fun handleTouchpad(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downTimeMs = event.eventTime
                maxPointers = 1
                startX = event.x
                startY = event.y
                lastX = event.x
                lastY = event.y
                movedBeyondSlop = false
                longPressDragging = false
                scrollAccumX = 0f
                scrollAccumY = 0f
                handler.removeCallbacks(longPressRunnable)
                handler.postDelayed(longPressRunnable, 380L)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                handler.removeCallbacks(longPressRunnable)
                maxPointers = maxOf(maxPointers, event.pointerCount)
                if (event.pointerCount >= 2) {
                    lastTwoX = (event.getX(0) + event.getX(1)) / 2f
                    lastTwoY = (event.getY(0) + event.getY(1)) / 2f
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (event.pointerCount >= 2) {
                    handler.removeCallbacks(longPressRunnable)
                    val cx = (event.getX(0) + event.getX(1)) / 2f
                    val cy = (event.getY(0) + event.getY(1)) / 2f
                    val dx = cx - lastTwoX
                    val dy = cy - lastTwoY
                    if (hypot(dx.toDouble(), dy.toDouble()) > tapSlopPx * 0.5) {
                        movedBeyondSlop = true
                    }
                    lastTwoX = cx
                    lastTwoY = cy
                    scrollAccumY += dy
                    scrollAccumX += dx
                    val stepPx = 10f * density
                    if (abs(scrollAccumY) >= stepPx) {
                        val units = ((scrollAccumY / stepPx) * 45f).roundToInt()
                        if (units != 0) MoonlightNative.sendScroll(units)
                        scrollAccumY = 0f
                    }
                    if (abs(scrollAccumX) >= stepPx * 1.4f) {
                        val units = ((-scrollAccumX / stepPx) * 40f).roundToInt()
                        if (units != 0) MoonlightNative.sendHScroll(units)
                        scrollAccumX = 0f
                    }
                } else if (event.pointerCount == 1 && maxPointers == 1) {
                    val dx = event.x - lastX
                    val dy = event.y - lastY
                    if (!movedBeyondSlop && hypot((event.x - startX).toDouble(), (event.y - startY).toDouble()) > tapSlopPx) {
                        movedBeyondSlop = true
                        handler.removeCallbacks(longPressRunnable)
                    }
                    lastX = event.x
                    lastY = event.y
                    if (movedBeyondSlop || longPressDragging) {
                        val gain = 1.4f
                        val mx = (dx * gain).roundToInt()
                        val my = (dy * gain).roundToInt()
                        if (mx != 0 || my != 0) {
                            MoonlightNative.sendMouseMove(mx, my)
                        }
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(longPressRunnable)
                val duration = event.eventTime - downTimeMs
                if (longPressDragging) {
                    MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                    longPressDragging = false
                } else if (event.actionMasked == MotionEvent.ACTION_UP && !movedBeyondSlop) {
                    if (maxPointers == 1 && duration < 260L) {
                        MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
                        MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                    } else if (maxPointers >= 2 && duration < 320L) {
                        MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_RIGHT)
                        MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_RIGHT)
                    }
                }
                maxPointers = 0
            }
        }
        return true
    }

    private fun handleDirectTouch(event: MotionEvent): Boolean {
        val (videoW, videoH) = getVideoDims()
        val viewW = view.width.coerceAtLeast(1).toFloat()
        val viewH = view.height.coerceAtLeast(1).toFloat()

        // touchView is sized identically to the aspect-ratio-fitted SurfaceView, so 1:1 normalized mapping is exact
        fun mapCoords(x: Float, y: Float): Pair<Int, Int> {
            val nx = (x / viewW).coerceIn(0f, 1f)
            val ny = (y / viewH).coerceIn(0f, 1f)
            return (nx * videoW).roundToInt() to (ny * videoH).roundToInt()
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                maxPointers = 1
                downTimeMs = event.eventTime
                val (rx, ry) = mapCoords(event.x, event.y)
                MoonlightNative.sendMousePosition(rx, ry, videoW, videoH)
                MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                maxPointers = maxOf(maxPointers, event.pointerCount)
                if (maxPointers == 2) {
                    MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                    val (rx, ry) = mapCoords(event.getX(0), event.getY(0))
                    MoonlightNative.sendMousePosition(rx, ry, videoW, videoH)
                    MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_RIGHT)
                    MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_RIGHT)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (event.pointerCount == 1 && maxPointers == 1) {
                    val (rx, ry) = mapCoords(event.x, event.y)
                    MoonlightNative.sendMousePosition(rx, ry, videoW, videoH)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (maxPointers == 1) {
                    MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                }
                maxPointers = 0
            }
        }
        return true
    }
}

@Composable
private fun StreamScreen(
    session: StreamSession,
    onReconnect: () -> Unit,
    onDisconnect: (quitApp: Boolean) -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val state by session.state.collectAsState()
    val stats by session.stats.collectAsState()
    val targetWidth by session.targetWidth.collectAsState()
    val targetHeight by session.targetHeight.collectAsState()
    val targetFps by session.targetFps.collectAsState()
    val title by session.streamTitle.collectAsState()
    val showHud by session.showHud.collectAsState()
    val touchpadMode by session.touchpadMode.collectAsState()
    val privacyEnabled by session.privacyScreenEnabled.collectAsState()
    val clipboardStatus by session.clipboardStatus.collectAsState()
    val audioMuted by session.audioMuted.collectAsState()
    val remoteDisplays by session.remoteDisplays.collectAsState()
    val switchingDisplay by session.switchingDisplay.collectAsState()
    val displayStatus by session.displayStatus.collectAsState()

    var showControlMenu by remember { mutableStateOf(false) }
    var showKeyboardDock by remember { mutableStateOf(false) }
    var fillCropMode by remember { mutableStateOf(false) }
    var zoomScale by remember { mutableFloatStateOf(1f) }

    // Resolve actual decoded aspect ratio (falls back to target stream dimensions)
    val (videoW, videoH) = remember(stats.resolution, targetWidth, targetHeight) {
        val match = Regex("""(\d+)\s*[x×]\s*(\d+)""").find(stats.resolution)
        val w = match?.groupValues?.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 } ?: targetWidth.coerceAtLeast(1)
        val h = match?.groupValues?.getOrNull(2)?.toIntOrNull()?.takeIf { it > 0 } ?: targetHeight.coerceAtLeast(1)
        w to h
    }

    BackHandler {
        if (showControlMenu) {
            showControlMenu = false
        } else if (showKeyboardDock) {
            showKeyboardDock = false
        } else {
            showControlMenu = true
        }
    }

    val config = LocalConfiguration.current
    val density = LocalDensity.current
    val screenW = with(density) { config.screenWidthDp.dp.toPx() }
    val screenH = with(density) { config.screenHeightDp.dp.toPx() }
    var orbOffsetX by remember { mutableFloatStateOf(24f) }
    var orbOffsetY by remember { mutableFloatStateOf(120f) }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        val viewW = maxWidth
        val viewH = maxHeight
        val videoAspect = videoW.toFloat() / videoH.coerceAtLeast(1).toFloat()
        val viewAspect = viewW.value / viewH.value.coerceAtLeast(1f)
        val (surfaceW, surfaceH) = if (!fillCropMode) {
            // Original aspect ratio (Fit with black letterbox/pillarbox, zero horizontal stretch)
            if (viewAspect > videoAspect) {
                (viewH * videoAspect) to viewH
            } else {
                viewW to (viewW / videoAspect)
            }
        } else {
            // Uniform scale to cover full screen without aspect distortion
            if (viewAspect > videoAspect) {
                viewW to (viewW / videoAspect)
            } else {
                (viewH * videoAspect) to viewH
            }
        }

        // Aspect-ratio-exact SurfaceView + aligned multi-touch overlay
        AndroidView(
            modifier = Modifier
                .align(Alignment.Center)
                .size(surfaceW, surfaceH)
                .graphicsLayer(
                    scaleX = zoomScale,
                    scaleY = zoomScale
                ),
            factory = { ctx ->
                val container = FrameLayout(ctx)
                val surfaceView = SurfaceView(ctx).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            session.attachSurface(holder.surface)
                        }
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            session.attachSurface(holder.surface)
                        }
                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            session.attachSurface(null)
                        }
                    })
                }
                val touchView = View(ctx)
                touchView.setOnTouchListener(
                    StreamTouchInputController(
                        view = touchView,
                        isTouchpadMode = { session.touchpadMode.value },
                        getVideoDims = {
                            val m = Regex("""(\d+)\s*[x×]\s*(\d+)""").find(session.stats.value.resolution)
                            val w = m?.groupValues?.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 } ?: session.targetWidth.value
                            val h = m?.groupValues?.getOrNull(2)?.toIntOrNull()?.takeIf { it > 0 } ?: session.targetHeight.value
                            w to h
                        }
                    )
                )
                container.addView(
                    surfaceView,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                )
                container.addView(
                    touchView,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                )
                container
            }
        )

        // Pinned Telemetry HUD
        if (showHud && state is StreamConnectionState.Streaming) {
            Surface(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(14.dp),
                shape = RoundedCornerShape(10.dp),
                color = Color(0xBB0D1218)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "${stats.fps}/${targetFps} FPS",
                        color = NodeDeckColors.Online,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = String.format("%.1f Mbps", stats.bitrateMbps),
                        color = Color.White,
                        style = MaterialTheme.typography.labelSmall
                    )
                    Text(
                        text = "${stats.resolution} · ${stats.codec.substringBefore(" ")}",
                        color = Color(0xFFB8C7D4),
                        style = MaterialTheme.typography.labelSmall
                    )
                    Text(
                        text = "RTT ${stats.networkRttMs}ms (±${stats.networkJitterMs})",
                        color = Color(0xFF9ED5DC),
                        style = MaterialTheme.typography.labelSmall
                    )
                }
            }
        }

        // Connecting / Disconnected Overlay
        when (val s = state) {
            is StreamConnectionState.Connecting -> {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color(0xCC0A0F14)),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator(color = NodeDeckColors.AccentLight)
                        Text(
                            text = title.ifBlank { "NodeDeck Remote" },
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White
                        )
                        Text(
                            text = s.message,
                            style = MaterialTheme.typography.bodySmall,
                            color = Color(0xFFB0C0CC)
                        )
                        OutlinedButton(onClick = { onDisconnect(false) }) {
                            Text(AppLocalization.t("取消", "Cancel", lang))
                        }
                    }
                }
            }
            is StreamConnectionState.Disconnected -> {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color(0xDD0A0F14)),
                    contentAlignment = Alignment.Center
                ) {
                    Surface(
                        shape = RoundedCornerShape(16.dp),
                        color = NodeDeckColors.DarkSurface,
                        modifier = Modifier.widthIn(min = 280.dp, max = 420.dp)
                    ) {
                        Column(
                            modifier = Modifier.padding(20.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Text(
                                text = AppLocalization.t("远程桌面已断开", "Stream Disconnected", lang),
                                style = MaterialTheme.typography.titleMedium,
                                color = Color.White
                            )
                            if (!s.reason.isNullOrBlank()) {
                                Text(
                                    text = s.reason,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color(0xFFFF9B9B)
                                )
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Button(onClick = onReconnect) {
                                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text(AppLocalization.t("重连", "Reconnect", lang))
                                }
                                OutlinedButton(onClick = { onDisconnect(false) }) {
                                    Text(AppLocalization.t("返回", "Exit", lang))
                                }
                            }
                        }
                    }
                }
            }
            else -> Unit
        }

        // Draggable Floating Orb
        Box(
            modifier = Modifier
                .offset { IntOffset(orbOffsetX.roundToInt(), orbOffsetY.roundToInt()) }
                .size(46.dp)
                .clip(CircleShape)
                .background(Color(0xCC162028))
                .border(1.5.dp, NodeDeckColors.AccentLight.copy(alpha = 0.85f), CircleShape)
                .pointerInput(screenW, screenH) {
                    detectDragGestures(
                        onDragEnd = {
                            val orbPx = 46f * density.density
                            val snapLeft = orbOffsetX < (screenW - orbPx) / 2f
                            orbOffsetX = if (snapLeft) 16f else (screenW - orbPx - 16f).coerceAtLeast(16f)
                            orbOffsetY = orbOffsetY.coerceIn(24f, (screenH - orbPx - 24f).coerceAtLeast(24f))
                        }
                    ) { change, dragAmount ->
                        change.consume()
                        orbOffsetX = (orbOffsetX + dragAmount.x).coerceIn(8f, (screenW - 54f).coerceAtLeast(8f))
                        orbOffsetY = (orbOffsetY + dragAmount.y).coerceIn(8f, (screenH - 54f).coerceAtLeast(8f))
                    }
                }
                .clickable { showControlMenu = !showControlMenu },
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.Tune,
                contentDescription = "Controls",
                tint = NodeDeckColors.AccentLight,
                modifier = Modifier.size(22.dp)
            )
        }

        // Keyboard & Function Key Dock
        if (showKeyboardDock) {
            KeyboardAccessoryDock(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .imePadding(),
                onClose = { showKeyboardDock = false }
            )
        }

        // Right-Edge Slide-Over Control Sidebar
        if (showControlMenu) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0x55000000))
                    .clickable { showControlMenu = false },
                contentAlignment = Alignment.CenterEnd
            ) {
                Surface(
                    modifier = Modifier
                        .width(340.dp)
                        .fillMaxHeight()
                        .clickable(enabled = false) {},
                    shape = RoundedCornerShape(topStart = 20.dp, bottomStart = 20.dp),
                    color = Color(0xF5121820),
                    tonalElevation = 10.dp
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp, vertical = 14.dp)
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(11.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = title.ifBlank { "NodeDeck Stream" },
                                    style = MaterialTheme.typography.titleMedium,
                                    color = Color.White,
                                    maxLines = 1
                                )
                                Text(
                                    text = "${stats.fps}/${targetFps} FPS · ${String.format("%.1f", stats.bitrateMbps)} Mbps · RTT ${stats.networkRttMs}ms",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color(0xFF9EB3C2)
                                )
                            }
                            IconButton(onClick = { showControlMenu = false }) {
                                Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                            }
                        }

                        HorizontalDivider(color = Color(0xFF263340))

                        // Multi-Display Switcher (macOS & Linux hosts over SSH)
                        if (session.hasSshHost) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(
                                        Icons.Default.DesktopWindows,
                                        contentDescription = null,
                                        tint = NodeDeckColors.AccentLight,
                                        modifier = Modifier.size(15.dp)
                                    )
                                    Text(
                                        text = AppLocalization.t("多显示器切换", "Displays", lang),
                                        style = MaterialTheme.typography.labelMedium,
                                        color = Color(0xFF9EB3C2)
                                    )
                                }
                                IconButton(
                                    onClick = { session.loadRemoteDisplays() },
                                    modifier = Modifier.size(28.dp)
                                ) {
                                    Icon(
                                        Icons.Default.Refresh,
                                        contentDescription = "Refresh displays",
                                        tint = Color(0xFF9EB3C2),
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            if (remoteDisplays.isNotEmpty()) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .horizontalScroll(rememberScrollState()),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    remoteDisplays.forEach { disp ->
                                        val tag = buildString {
                                            append(disp.label)
                                            if (disp.isPrimary) append(AppLocalization.t(" (主)", " (Main)", lang))
                                            if (disp.resolution.isNotBlank()) append(" · ${disp.resolution}")
                                        }
                                        PillChoice(
                                            label = tag,
                                            selected = disp.isSelected,
                                            onClick = {
                                                if (!switchingDisplay && !disp.isSelected) {
                                                    session.switchRemoteDisplay(disp)
                                                }
                                            }
                                        )
                                    }
                                }
                            } else {
                                Text(
                                    text = AppLocalization.t("点击右侧刷新检测远端显示器", "Tap refresh to detect host displays", lang),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color(0xFF6F8496)
                                )
                            }
                            displayStatus?.let { msg ->
                                Text(
                                    text = msg,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = NodeDeckColors.AccentLight
                                )
                            }
                            HorizontalDivider(color = Color(0xFF263340))
                        }

                        // Aspect Ratio & Zoom Controls
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Default.AspectRatio,
                                    contentDescription = null,
                                    tint = NodeDeckColors.AccentLight,
                                    modifier = Modifier.size(15.dp)
                                )
                                Text(
                                    text = AppLocalization.t("画面比例与缩放", "Aspect & Zoom", lang),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = Color(0xFF9EB3C2)
                                )
                            }
                            Text(
                                text = "${videoW}×${videoH}",
                                style = MaterialTheme.typography.labelSmall,
                                color = Color(0xFF8AA2B5)
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PillChoice(
                                label = AppLocalization.t("原比例", "Original Fit", lang),
                                selected = !fillCropMode,
                                onClick = { fillCropMode = false }
                            )
                            PillChoice(
                                label = AppLocalization.t("铺满裁剪", "Fill Crop", lang),
                                selected = fillCropMode,
                                onClick = { fillCropMode = true }
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(1.0f to "1.0x", 1.25f to "1.25x", 1.5f to "1.5x", 2.0f to "2.0x").forEach { (scale, lbl) ->
                                PillChoice(
                                    label = lbl,
                                    selected = abs(zoomScale - scale) < 0.05f,
                                    onClick = { zoomScale = scale }
                                )
                            }
                        }

                        HorizontalDivider(color = Color(0xFF263340))

                        // Resolution Selector
                        Text(
                            text = AppLocalization.t("分辨率", "Resolution", lang),
                            style = MaterialTheme.typography.labelMedium,
                            color = Color(0xFF9EB3C2)
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            StreamResolutionPreset.entries.forEach { preset ->
                                val selected = preset.width == targetWidth && preset.height == targetHeight
                                PillChoice(
                                    label = preset.label,
                                    selected = selected,
                                    onClick = {
                                        session.switchResolution(preset)
                                        showControlMenu = false
                                    }
                                )
                            }
                        }

                        // Refresh Rate Selector
                        val autoMbps = StreamQualityMath.recommendedBitrateKbps(targetWidth, targetHeight, targetFps) / 1000
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = AppLocalization.t("刷新率", "Refresh Rate", lang),
                                style = MaterialTheme.typography.labelMedium,
                                color = Color(0xFF9EB3C2)
                            )
                            Text(
                                text = "${AppLocalization.t("自动码率", "Auto Bitrate", lang)} ${autoMbps} Mbps",
                                style = MaterialTheme.typography.labelSmall,
                                color = NodeDeckColors.AccentLight
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            StreamRefreshRate.entries.forEach { rate ->
                                PillChoice(
                                    label = rate.label,
                                    selected = rate.fps == targetFps,
                                    onClick = {
                                        session.switchRefreshRate(rate)
                                        showControlMenu = false
                                    }
                                )
                            }
                        }

                        HorizontalDivider(color = Color(0xFF263340))

                        // Input, Audio & HUD Controls
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            ControlTileButton(
                                modifier = Modifier.weight(1f),
                                icon = Icons.Default.TouchApp,
                                label = if (touchpadMode) {
                                    AppLocalization.t("触控板", "Touchpad", lang)
                                } else {
                                    AppLocalization.t("直接触控", "Direct", lang)
                                },
                                active = touchpadMode,
                                onClick = { session.setTouchpadMode(!touchpadMode) }
                            )
                            ControlTileButton(
                                modifier = Modifier.weight(1f),
                                icon = Icons.Default.Keyboard,
                                label = AppLocalization.t("键盘", "Keyboard", lang),
                                active = showKeyboardDock,
                                onClick = {
                                    showKeyboardDock = !showKeyboardDock
                                    showControlMenu = false
                                }
                            )
                            ControlTileButton(
                                modifier = Modifier.weight(1f),
                                icon = if (audioMuted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                label = if (audioMuted) AppLocalization.t("已静音", "Muted", lang) else AppLocalization.t("声音", "Audio", lang),
                                active = !audioMuted,
                                onClick = { session.setAudioMuted(!audioMuted) }
                            )
                            ControlTileButton(
                                modifier = Modifier.weight(1f),
                                icon = Icons.Default.Speed,
                                label = AppLocalization.t("浮窗", "HUD", lang),
                                active = showHud,
                                onClick = { session.setShowHud(!showHud) }
                            )
                        }

                        // Quick Hotkeys Bar
                        Text(
                            text = AppLocalization.t("常用快捷键", "Quick Hotkeys", lang),
                            style = MaterialTheme.typography.labelMedium,
                            color = Color(0xFF9EB3C2)
                        )
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            fun tapCombo(modVk: Int, modFlag: Byte, keyVk: Int, extMod: Boolean = false) {
                                MoonlightNative.sendVirtualKey(modVk, true, extended = extMod)
                                MoonlightNative.sendVirtualKey(keyVk, true, modifiers = modFlag)
                                MoonlightNative.sendVirtualKey(keyVk, false, modifiers = modFlag)
                                MoonlightNative.sendVirtualKey(modVk, false, extended = extMod)
                            }
                            KeyChip("⌘/Win+Tab") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x09, extMod = true) }
                            KeyChip("Alt+Tab") { tapCombo(0xA4, MoonlightNative.MODIFIER_ALT, 0x09) }
                            KeyChip("⌘+Space") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x20, extMod = true) }
                            KeyChip("Ctrl+C") { tapCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x43) }
                            KeyChip("Ctrl+V") { tapCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x56) }
                            KeyChip("⌘+C") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x43, extMod = true) }
                            KeyChip("⌘+V") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x56, extMod = true) }
                            KeyChip("Esc") {
                                MoonlightNative.sendVirtualKey(0x1B, true)
                                MoonlightNative.sendVirtualKey(0x1B, false)
                            }
                        }

                        // SSH Clipboard & Privacy Screen
                        if (session.hasSshHost) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                ControlTileButton(
                                    modifier = Modifier.weight(1f),
                                    icon = Icons.Default.ContentPaste,
                                    label = AppLocalization.t("推送剪贴板", "Push Clip", lang),
                                    active = false,
                                    onClick = { session.pushAndroidClipboardToRemote() }
                                )
                                ControlTileButton(
                                    modifier = Modifier.weight(1f),
                                    icon = Icons.Default.ContentCopy,
                                    label = AppLocalization.t("拉取剪贴板", "Pull Clip", lang),
                                    active = false,
                                    onClick = { session.pullRemoteClipboardToAndroid() }
                                )
                                ControlTileButton(
                                    modifier = Modifier.weight(1f),
                                    icon = if (privacyEnabled) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                    label = AppLocalization.t("防窥黑屏", "Privacy", lang),
                                    active = privacyEnabled,
                                    onClick = { session.togglePrivacyScreen() }
                                )
                            }
                            clipboardStatus?.let { msg ->
                                Text(
                                    text = msg,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = NodeDeckColors.AccentLight
                                )
                            }
                        }

                        // Release stuck keys & Session Actions
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                onClick = {
                                    MoonlightNative.releaseAllRemoteModifiers()
                                    showControlMenu = false
                                }
                            ) {
                                Text(AppLocalization.t("重置按键", "Reset Keys", lang), fontSize = 12.sp)
                            }
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                onClick = {
                                    showControlMenu = false
                                    onReconnect()
                                }
                            ) {
                                Text(AppLocalization.t("重连", "Reconnect", lang), fontSize = 12.sp)
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Button(
                                modifier = Modifier.weight(1f),
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF344352)),
                                onClick = { onDisconnect(false) }
                            ) {
                                Text(AppLocalization.t("断开连接", "Disconnect", lang), fontSize = 12.sp)
                            }
                            Button(
                                modifier = Modifier.weight(1f),
                                colors = ButtonDefaults.buttonColors(containerColor = NodeDeckColors.Offline),
                                onClick = { onDisconnect(true) }
                            ) {
                                Icon(Icons.Default.PowerSettingsNew, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(Modifier.width(4.dp))
                                Text(AppLocalization.t("退出应用", "Quit App", lang), fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PillChoice(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = if (selected) NodeDeckColors.Accent else Color(0xFF222D38),
        modifier = Modifier.clickable(onClick = onClick)
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) Color.White else Color(0xFFC2D0DC)
        )
    }
}

@Composable
private fun ControlTileButton(
    modifier: Modifier = Modifier,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit
) {
    Surface(
        modifier = modifier.clickable(onClick = onClick),
        shape = RoundedCornerShape(10.dp),
        color = if (active) NodeDeckColors.Accent.copy(alpha = 0.35f) else Color(0xFF1F2A35)
    ) {
        Column(
            modifier = Modifier.padding(vertical = 8.dp, horizontal = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = if (active) NodeDeckColors.AccentLight else Color(0xFFC2D0DC),
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.SansSerif,
                color = Color.White,
                maxLines = 1
            )
        }
    }
}

@Composable
private fun KeyboardAccessoryDock(
    modifier: Modifier = Modifier,
    onClose: () -> Unit
) {
    var ctrlSticky by remember { mutableStateOf(false) }
    var altSticky by remember { mutableStateOf(false) }
    var shiftSticky by remember { mutableStateOf(false) }
    var winSticky by remember { mutableStateOf(false) }
    var textInput by remember { mutableStateOf("") }

    fun currentModifierFlags(): Byte {
        var m = 0
        if (shiftSticky) m = m or MoonlightNative.MODIFIER_SHIFT.toInt()
        if (ctrlSticky) m = m or MoonlightNative.MODIFIER_CTRL.toInt()
        if (altSticky) m = m or MoonlightNative.MODIFIER_ALT.toInt()
        if (winSticky) m = m or MoonlightNative.MODIFIER_META.toInt()
        return m.toByte()
    }

    fun sendTapVk(vk: Int, extended: Boolean = false) {
        val mods = currentModifierFlags()
        if (ctrlSticky) MoonlightNative.sendVirtualKey(0xA2, true)
        if (altSticky) MoonlightNative.sendVirtualKey(0xA4, true)
        if (shiftSticky) MoonlightNative.sendVirtualKey(0xA0, true)
        if (winSticky) MoonlightNative.sendVirtualKey(0x5B, true, extended = true)

        MoonlightNative.sendVirtualKey(vk, true, extended = extended, modifiers = mods)
        MoonlightNative.sendVirtualKey(vk, false, extended = extended, modifiers = mods)

        if (winSticky) MoonlightNative.sendVirtualKey(0x5B, false, extended = true)
        if (shiftSticky) MoonlightNative.sendVirtualKey(0xA0, false)
        if (altSticky) MoonlightNative.sendVirtualKey(0xA4, false)
        if (ctrlSticky) MoonlightNative.sendVirtualKey(0xA2, false)

        ctrlSticky = false
        altSticky = false
        shiftSticky = false
        winSticky = false
    }

    fun sendCombo(modVk: Int, modFlag: Byte, keyVk: Int) {
        MoonlightNative.sendVirtualKey(modVk, true)
        MoonlightNative.sendVirtualKey(keyVk, true, modifiers = modFlag)
        MoonlightNative.sendVirtualKey(keyVk, false, modifiers = modFlag)
        MoonlightNative.sendVirtualKey(modVk, false)
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 6.dp),
        shape = RoundedCornerShape(14.dp),
        color = Color(0xEE131A22)
    ) {
        Column(
            modifier = Modifier.padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                KeyChip("Esc") { sendTapVk(0x1B) }
                KeyChip("Tab") { sendTapVk(0x09) }
                KeyChip("Ctrl", active = ctrlSticky) { ctrlSticky = !ctrlSticky }
                KeyChip("Alt", active = altSticky) { altSticky = !altSticky }
                KeyChip("Shift", active = shiftSticky) { shiftSticky = !shiftSticky }
                KeyChip("Super", active = winSticky) { winSticky = !winSticky }
                KeyChip("Ctrl+C") { sendCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x43) }
                KeyChip("Ctrl+V") { sendCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x56) }
                KeyChip("Ctrl+Z") { sendCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x5A) }
                KeyChip("←") { sendTapVk(0x25, extended = true) }
                KeyChip("↑") { sendTapVk(0x26, extended = true) }
                KeyChip("↓") { sendTapVk(0x28, extended = true) }
                KeyChip("→") { sendTapVk(0x27, extended = true) }
                KeyChip("Bksp") { sendTapVk(0x08) }
                KeyChip("Enter") { sendTapVk(0x0D) }
                KeyChip("Del") { sendTapVk(0x2E, extended = true) }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                OutlinedTextField(
                    value = textInput,
                    onValueChange = { textInput = it },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    placeholder = { Text("Type text to send to remote…", fontSize = 13.sp) },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = {
                        if (textInput.isNotEmpty()) {
                            MoonlightNative.sendUtf8Text(textInput)
                            textInput = ""
                        }
                    }),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = NodeDeckColors.AccentLight,
                        unfocusedBorderColor = Color(0xFF334454)
                    )
                )
                IconButton(onClick = {
                    if (textInput.isNotEmpty()) {
                        MoonlightNative.sendUtf8Text(textInput)
                        textInput = ""
                    } else {
                        sendTapVk(0x0D)
                    }
                }) {
                    Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send", tint = NodeDeckColors.AccentLight)
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color(0xFF9EB3C2))
                }
            }
        }
    }
}

@Composable
private fun KeyChip(label: String, active: Boolean = false, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = if (active) NodeDeckColors.Accent else Color(0xFF23303D),
        modifier = Modifier.clickable(onClick = onClick)
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelSmall,
            color = Color.White
        )
    }
}
