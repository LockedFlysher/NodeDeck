package com.nodedeck.android.stream

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
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
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.material.icons.filled.CenterFocusStrong
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ScreenRotation
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
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
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
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
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

enum class StreamOrientationMode(val activityOrientation: Int) {
    LANDSCAPE(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE),
    PORTRAIT(ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT),
    AUTO(ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR)
}

private enum class SidebarTab {
    CONTROL,
    DISPLAY,
    MORE
}

@Stable
internal class ViewportTransformState {
    var zoomScale by mutableFloatStateOf(1f)
    var panX by mutableFloatStateOf(0f)
    var panY by mutableFloatStateOf(0f)
    var isPinching by mutableStateOf(false)

    // Updated from BoxWithConstraints in pixels
    var containerW: Float = 1f
    var containerH: Float = 1f
    var baseSurfaceW: Float = 1f
    var baseSurfaceH: Float = 1f

    fun updateBounds(containerW: Float, containerH: Float, baseSurfaceW: Float, baseSurfaceH: Float) {
        this.containerW = containerW.coerceAtLeast(1f)
        this.containerH = containerH.coerceAtLeast(1f)
        this.baseSurfaceW = baseSurfaceW.coerceAtLeast(1f)
        this.baseSurfaceH = baseSurfaceH.coerceAtLeast(1f)
        clampPan()
    }

    fun reset() {
        zoomScale = 1f
        panX = 0f
        panY = 0f
        isPinching = false
    }

    fun setPresetScale(targetScale: Float) {
        val clamped = targetScale.coerceIn(MIN_ZOOM, MAX_ZOOM)
        if (clamped <= 1.01f) {
            reset()
            return
        }
        val ratio = clamped / zoomScale.coerceAtLeast(1f)
        zoomScale = clamped
        panX *= ratio
        panY *= ratio
        clampPan()
    }

    fun applyZoomAndPan(
        newScale: Float,
        focalX: Float,
        focalY: Float,
        panDeltaX: Float,
        panDeltaY: Float
    ) {
        val clamped = newScale.coerceIn(MIN_ZOOM, MAX_ZOOM)
        if (clamped <= 1.005f) {
            zoomScale = 1f
            panX = 0f
            panY = 0f
            return
        }
        val oldScale = zoomScale.coerceAtLeast(1f)
        val ratio = clamped / oldScale
        val relX = focalX - containerW / 2f
        val relY = focalY - containerH / 2f
        val rawX = (panX - relX) * ratio + relX + panDeltaX
        val rawY = (panY - relY) * ratio + relY + panDeltaY
        zoomScale = clamped
        panX = rawX
        panY = rawY
        clampPan()
    }

    fun applyPanOnly(panDeltaX: Float, panDeltaY: Float) {
        if (zoomScale <= 1.01f) return
        panX += panDeltaX
        panY += panDeltaY
        clampPan()
    }

    fun snapIfNearUnity() {
        if (zoomScale < 1.05f) {
            reset()
        }
    }

    fun screenToVideo(screenX: Float, screenY: Float, videoW: Int, videoH: Int): Pair<Int, Int> {
        val localX = (screenX - containerW / 2f - panX) / zoomScale.coerceAtLeast(1f) + baseSurfaceW / 2f
        val localY = (screenY - containerH / 2f - panY) / zoomScale.coerceAtLeast(1f) + baseSurfaceH / 2f
        val nx = (localX / baseSurfaceW.coerceAtLeast(1f)).coerceIn(0f, 1f)
        val ny = (localY / baseSurfaceH.coerceAtLeast(1f)).coerceIn(0f, 1f)
        return (nx * videoW).roundToInt() to (ny * videoH).roundToInt()
    }

    private fun clampPan() {
        val maxPanX = max(0f, (baseSurfaceW * zoomScale - containerW) / 2f)
        val maxPanY = max(0f, (baseSurfaceH * zoomScale - containerH) / 2f)
        panX = panX.coerceIn(-maxPanX, maxPanX)
        panY = panY.coerceIn(-maxPanY, maxPanY)
    }

    companion object {
        const val MIN_ZOOM = 1.0f
        const val MAX_ZOOM = 4.0f
    }
}

class StreamActivity : ComponentActivity() {
    private lateinit var session: StreamSession
    private var launchHost: SSHHost? = null
    private var allHosts: List<SSHHost> = emptyList()
    private var launchAddress: String = ""
    private var launchHttpPort: Int = 47989
    private val orientationModeState = mutableStateOf(StreamOrientationMode.LANDSCAPE)

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
                    orientationMode = orientationModeState.value,
                    onSelectOrientation = { mode ->
                        orientationModeState.value = mode
                        requestedOrientation = mode.activityOrientation
                        hideSystemBars()
                    },
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

private enum class TwoFingerGestureMode {
    NONE,
    UNDECIDED,
    PINCH_ZOOM,
    PAN_VIEWPORT,
    SCROLL
}

private class StreamTouchInputController(
    private val view: View,
    private val viewport: ViewportTransformState,
    private val isTouchpadMode: () -> Boolean,
    private val getPointerSensitivity: () -> Float,
    private val getScrollSensitivity: () -> Float,
    private val getVideoDims: () -> Pair<Int, Int>
) : View.OnTouchListener {

    private val handler = Handler(Looper.getMainLooper())
    private val density = view.resources.displayMetrics.density

    // Gesture thresholds (tuned to separate pinch-zoom cleanly from scroll & right-click)
    private val tapSlopPx = 12f * density
    private val directCommitMovePx = 6f * density
    private val pinchMinInitialSpanPx = 24f * density
    private val pinchThresholdPx = 28f * density
    private val pinchThresholdRatio = 0.14f
    private val scrollActivatePx = 16f * density
    private val directDownDelayMs = 60L

    private var downTimeMs = 0L
    private var twoFingerDownTimeMs = 0L
    private var maxPointers = 0
    private var suppressSingleUntilUp = false

    // Single-finger state
    private var startX = 0f
    private var startY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var movedBeyondSlop = false
    private var longPressDragging = false
    private var directLeftDownSent = false
    private var directPendingDown = false

    // Two-finger state (shared across Touchpad & Direct Touch)
    private var twoFingerMode = TwoFingerGestureMode.NONE
    private var initialSpan = 0f
    private var lastSpan = 0f
    private var initialMidX = 0f
    private var initialMidY = 0f
    private var lastMidX = 0f
    private var lastMidY = 0f
    private var scrollAccumX = 0f
    private var scrollAccumY = 0f

    private val touchpadLongPressRunnable = Runnable {
        if (!movedBeyondSlop && maxPointers == 1 && !suppressSingleUntilUp && isTouchpadMode()) {
            longPressDragging = true
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
        }
    }

    private val directDownCommitRunnable = Runnable {
        if (directPendingDown && maxPointers == 1 && !suppressSingleUntilUp && !isTouchpadMode()) {
            commitDirectLeftDown(lastX, lastY)
        }
    }

    private fun commitDirectLeftDown(screenX: Float, screenY: Float) {
        directPendingDown = false
        if (!directLeftDownSent) {
            val (videoW, videoH) = getVideoDims()
            val (rx, ry) = viewport.screenToVideo(screenX, screenY, videoW, videoH)
            MoonlightNative.sendMousePosition(rx, ry, videoW, videoH)
            MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
            directLeftDownSent = true
        }
    }

    private fun cancelSingleFingerPending() {
        handler.removeCallbacks(touchpadLongPressRunnable)
        handler.removeCallbacks(directDownCommitRunnable)
        directPendingDown = false
        if (directLeftDownSent) {
            MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
            directLeftDownSent = false
        }
        if (longPressDragging) {
            MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
            longPressDragging = false
        }
    }

    private fun beginTwoFingerGesture(event: MotionEvent) {
        cancelSingleFingerPending()
        suppressSingleUntilUp = true
        twoFingerDownTimeMs = event.eventTime
        twoFingerMode = TwoFingerGestureMode.UNDECIDED
        val x0 = event.getX(0)
        val y0 = event.getY(0)
        val x1 = event.getX(1)
        val y1 = event.getY(1)
        initialSpan = hypot((x1 - x0).toDouble(), (y1 - y0).toDouble()).toFloat()
        lastSpan = initialSpan
        initialMidX = (x0 + x1) / 2f
        initialMidY = (y0 + y1) / 2f
        lastMidX = initialMidX
        lastMidY = initialMidY
        scrollAccumX = 0f
        scrollAccumY = 0f
    }

    private fun handleTwoFingerMove(event: MotionEvent) {
        val x0 = event.getX(0)
        val y0 = event.getY(0)
        val x1 = event.getX(1)
        val y1 = event.getY(1)
        val span = hypot((x1 - x0).toDouble(), (y1 - y0).toDouble()).toFloat()
        val midX = (x0 + x1) / 2f
        val midY = (y0 + y1) / 2f
        val panDx = midX - lastMidX
        val panDy = midY - lastMidY

        val spanDeltaFromInit = abs(span - initialSpan)
        val spanRatioFromInit = if (initialSpan >= pinchMinInitialSpanPx) {
            abs(span / initialSpan - 1f)
        } else {
            0f
        }
        val midTravelFromInit = hypot((midX - initialMidX).toDouble(), (midY - initialMidY).toDouble()).toFloat()

        when (twoFingerMode) {
            TwoFingerGestureMode.UNDECIDED -> {
                val crossedPinchThreshold =
                    initialSpan >= pinchMinInitialSpanPx &&
                        spanDeltaFromInit >= pinchThresholdPx &&
                        spanRatioFromInit >= pinchThresholdRatio
                if (crossedPinchThreshold) {
                    twoFingerMode = TwoFingerGestureMode.PINCH_ZOOM
                    viewport.isPinching = true
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    lastSpan = span
                    lastMidX = midX
                    lastMidY = midY
                    return
                }
                if (midTravelFromInit >= scrollActivatePx && spanDeltaFromInit < pinchThresholdPx * 0.85f) {
                    twoFingerMode = if (viewport.zoomScale > 1.04f) {
                        TwoFingerGestureMode.PAN_VIEWPORT
                    } else {
                        TwoFingerGestureMode.SCROLL
                    }
                    lastSpan = span
                    lastMidX = midX
                    lastMidY = midY
                    return
                }
            }

            TwoFingerGestureMode.PAN_VIEWPORT -> {
                viewport.applyPanOnly(panDx, panDy)
                val upgradeToPinch =
                    initialSpan >= pinchMinInitialSpanPx &&
                        spanDeltaFromInit >= pinchThresholdPx * 1.15f &&
                        spanRatioFromInit >= pinchThresholdRatio
                if (upgradeToPinch) {
                    twoFingerMode = TwoFingerGestureMode.PINCH_ZOOM
                    viewport.isPinching = true
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                }
            }

            TwoFingerGestureMode.PINCH_ZOOM -> {
                val scaleFactor = if (lastSpan > 1f) (span / lastSpan).coerceIn(0.8f, 1.25f) else 1f
                viewport.applyZoomAndPan(
                    newScale = viewport.zoomScale * scaleFactor,
                    focalX = midX,
                    focalY = midY,
                    panDeltaX = panDx,
                    panDeltaY = panDy
                )
            }

            TwoFingerGestureMode.SCROLL -> {
                val scrollGain = getScrollSensitivity().coerceIn(0.5f, 2.5f)
                scrollAccumY += panDy
                scrollAccumX += panDx
                val stepPx = 10f * density
                if (abs(scrollAccumY) >= stepPx) {
                    val units = ((scrollAccumY / stepPx) * 45f * scrollGain).roundToInt()
                    if (units != 0) MoonlightNative.sendScroll(units)
                    scrollAccumY = 0f
                }
                if (abs(scrollAccumX) >= stepPx * 1.4f) {
                    val units = ((-scrollAccumX / stepPx) * 40f * scrollGain).roundToInt()
                    if (units != 0) MoonlightNative.sendHScroll(units)
                    scrollAccumX = 0f
                }
            }

            TwoFingerGestureMode.NONE -> Unit
        }

        lastSpan = span
        lastMidX = midX
        lastMidY = midY
    }

    override fun onTouch(v: View, event: MotionEvent): Boolean {
        val touchpad = isTouchpadMode()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downTimeMs = event.eventTime
                maxPointers = 1
                suppressSingleUntilUp = false
                twoFingerMode = TwoFingerGestureMode.NONE
                startX = event.x
                startY = event.y
                lastX = event.x
                lastY = event.y
                movedBeyondSlop = false
                longPressDragging = false
                directLeftDownSent = false
                directPendingDown = false
                scrollAccumX = 0f
                scrollAccumY = 0f
                handler.removeCallbacks(touchpadLongPressRunnable)
                handler.removeCallbacks(directDownCommitRunnable)
                if (touchpad) {
                    handler.postDelayed(touchpadLongPressRunnable, 380L)
                } else {
                    directPendingDown = true
                    handler.postDelayed(directDownCommitRunnable, directDownDelayMs)
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                maxPointers = maxOf(maxPointers, event.pointerCount)
                if (event.pointerCount == 2) {
                    beginTwoFingerGesture(event)
                } else {
                    cancelSingleFingerPending()
                    suppressSingleUntilUp = true
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (event.pointerCount >= 2) {
                    if (twoFingerMode == TwoFingerGestureMode.NONE) {
                        beginTwoFingerGesture(event)
                    } else {
                        handleTwoFingerMove(event)
                    }
                } else if (event.pointerCount == 1 && !suppressSingleUntilUp && maxPointers == 1) {
                    if (touchpad) {
                        val dx = event.x - lastX
                        val dy = event.y - lastY
                        if (!movedBeyondSlop &&
                            hypot((event.x - startX).toDouble(), (event.y - startY).toDouble()) > tapSlopPx
                        ) {
                            movedBeyondSlop = true
                            handler.removeCallbacks(touchpadLongPressRunnable)
                        }
                        lastX = event.x
                        lastY = event.y
                        if (movedBeyondSlop || longPressDragging) {
                            val gain = getPointerSensitivity().coerceIn(0.6f, 2.5f)
                            val mx = (dx * gain).roundToInt()
                            val my = (dy * gain).roundToInt()
                            if (mx != 0 || my != 0) {
                                MoonlightNative.sendMouseMove(mx, my)
                            }
                        }
                    } else {
                        lastX = event.x
                        lastY = event.y
                        if (directPendingDown &&
                            hypot((event.x - startX).toDouble(), (event.y - startY).toDouble()) >= directCommitMovePx
                        ) {
                            handler.removeCallbacks(directDownCommitRunnable)
                            commitDirectLeftDown(event.x, event.y)
                        } else if (directLeftDownSent) {
                            val (videoW, videoH) = getVideoDims()
                            val (rx, ry) = viewport.screenToVideo(event.x, event.y, videoW, videoH)
                            MoonlightNative.sendMousePosition(rx, ry, videoW, videoH)
                        }
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (twoFingerMode == TwoFingerGestureMode.PINCH_ZOOM) {
                    viewport.isPinching = false
                    viewport.snapIfNearUnity()
                }
                suppressSingleUntilUp = true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(touchpadLongPressRunnable)
                handler.removeCallbacks(directDownCommitRunnable)
                val isUp = event.actionMasked == MotionEvent.ACTION_UP
                if (twoFingerMode == TwoFingerGestureMode.PINCH_ZOOM) {
                    viewport.isPinching = false
                    viewport.snapIfNearUnity()
                } else if (isUp &&
                    maxPointers == 2 &&
                    twoFingerMode == TwoFingerGestureMode.UNDECIDED &&
                    (event.eventTime - twoFingerDownTimeMs) < 320L
                ) {
                    if (!touchpad) {
                        val (videoW, videoH) = getVideoDims()
                        val (rx, ry) = viewport.screenToVideo(initialMidX, initialMidY, videoW, videoH)
                        MoonlightNative.sendMousePosition(rx, ry, videoW, videoH)
                    }
                    MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_RIGHT)
                    MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_RIGHT)
                } else if (!suppressSingleUntilUp && maxPointers == 1) {
                    if (touchpad) {
                        val duration = event.eventTime - downTimeMs
                        if (longPressDragging) {
                            MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                            longPressDragging = false
                        } else if (isUp && !movedBeyondSlop && duration < 260L) {
                            MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
                            MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                        }
                    } else {
                        if (directPendingDown && isUp) {
                            commitDirectLeftDown(event.x, event.y)
                            MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                            directLeftDownSent = false
                        } else if (directLeftDownSent) {
                            MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                            directLeftDownSent = false
                        }
                        directPendingDown = false
                    }
                } else {
                    cancelSingleFingerPending()
                }
                twoFingerMode = TwoFingerGestureMode.NONE
                viewport.isPinching = false
                suppressSingleUntilUp = false
                maxPointers = 0
            }
        }
        return true
    }
}

@Composable
private fun StreamScreen(
    session: StreamSession,
    orientationMode: StreamOrientationMode,
    onSelectOrientation: (StreamOrientationMode) -> Unit,
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

    var showSidebar by remember { mutableStateOf(false) }
    var activeTab by remember { mutableStateOf(SidebarTab.CONTROL) }
    var showKeyboardDock by remember { mutableStateOf(false) }
    var showVirtualMouseButtons by remember { mutableStateOf(false) }
    var leftDragLocked by remember { mutableStateOf(false) }
    var fillCropMode by remember { mutableStateOf(false) }
    var pointerSensitivity by remember { mutableFloatStateOf(1.4f) }
    var scrollSensitivity by remember { mutableFloatStateOf(1.0f) }
    var orbInteractionTick by remember { mutableIntStateOf(0) }
    var orbIdleDocked by remember { mutableStateOf(false) }
    val viewport = remember { ViewportTransformState() }

    // Auto-close sidebar when disconnected so dialogs never collide
    LaunchedEffect(state) {
        if (state is StreamConnectionState.Disconnected) {
            showSidebar = false
            if (leftDragLocked) {
                MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                leftDragLocked = false
            }
        }
    }

    // UU-style edge-tucking floating orb: fades and tucks subtly to screen edge after 3s idle
    LaunchedEffect(orbInteractionTick, showSidebar) {
        if (showSidebar) {
            orbIdleDocked = false
        } else {
            orbIdleDocked = false
            delay(3000L)
            orbIdleDocked = true
        }
    }
    val orbAlpha by animateFloatAsState(
        targetValue = if (orbIdleDocked) 0.45f else 0.96f,
        animationSpec = tween(260),
        label = "orbAlpha"
    )

    val (videoW, videoH) = remember(stats.resolution, targetWidth, targetHeight) {
        val match = Regex("""(\d+)\s*[x×]\s*(\d+)""").find(stats.resolution)
        val w = match?.groupValues?.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 } ?: targetWidth.coerceAtLeast(1)
        val h = match?.groupValues?.getOrNull(2)?.toIntOrNull()?.takeIf { it > 0 } ?: targetHeight.coerceAtLeast(1)
        w to h
    }

    BackHandler {
        when {
            showSidebar -> showSidebar = false
            showKeyboardDock -> showKeyboardDock = false
            else -> showSidebar = true
        }
    }

    val density = LocalDensity.current
    var orbInitialized by remember { mutableStateOf(false) }
    var orbOffsetX by remember { mutableFloatStateOf(24f) }
    var orbOffsetY by remember { mutableFloatStateOf(160f) }
    var orbOnRightEdge by remember { mutableStateOf(true) }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        val viewW = maxWidth
        val viewH = maxHeight
        val screenW = with(density) { maxWidth.toPx() }
        val screenH = with(density) { maxHeight.toPx() }
        val orbPx = with(density) { 46.dp.toPx() }
        val edgeMarginPx = with(density) { 10.dp.toPx() }
        val tuckShiftPx = with(density) { 14.dp.toPx() }

        LaunchedEffect(screenW, screenH) {
            if (!orbInitialized && screenW > 100f && screenH > 100f) {
                orbOnRightEdge = true
                orbOffsetX = (screenW - orbPx - edgeMarginPx).coerceAtLeast(edgeMarginPx)
                orbOffsetY = (screenH * 0.36f).coerceIn(24f, (screenH - orbPx - 24f).coerceAtLeast(24f))
                orbInitialized = true
            } else if (orbInitialized && screenW > 100f && screenH > 100f) {
                orbOffsetX = if (orbOnRightEdge) {
                    (screenW - orbPx - edgeMarginPx).coerceAtLeast(edgeMarginPx)
                } else {
                    edgeMarginPx
                }
                orbOffsetY = orbOffsetY.coerceIn(24f, (screenH - orbPx - 24f).coerceAtLeast(24f))
            }
        }

        val videoAspect = videoW.toFloat() / videoH.coerceAtLeast(1).toFloat()
        val viewAspect = viewW.value / viewH.value.coerceAtLeast(1f)
        val (surfaceW, surfaceH) = if (!fillCropMode) {
            if (viewAspect > videoAspect) {
                (viewH * videoAspect) to viewH
            } else {
                viewW to (viewW / videoAspect)
            }
        } else {
            if (viewAspect > videoAspect) {
                viewW to (viewW / videoAspect)
            } else {
                (viewH * videoAspect) to viewH
            }
        }

        val surfaceWPx = with(density) { surfaceW.toPx() }
        val surfaceHPx = with(density) { surfaceH.toPx() }
        viewport.updateBounds(
            containerW = screenW,
            containerH = screenH,
            baseSurfaceW = surfaceWPx,
            baseSurfaceH = surfaceHPx
        )

        // 1. Aspect-ratio-exact SurfaceView with smooth zoom + focal pan transform
        AndroidView(
            modifier = Modifier
                .align(Alignment.Center)
                .size(surfaceW, surfaceH)
                .graphicsLayer(
                    scaleX = viewport.zoomScale,
                    scaleY = viewport.zoomScale,
                    translationX = viewport.panX,
                    translationY = viewport.panY
                ),
            factory = { ctx ->
                SurfaceView(ctx).apply {
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
            }
        )

        // 2. Full-screen untransformed multi-touch receiver
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                View(ctx).apply {
                    setOnTouchListener(
                        StreamTouchInputController(
                            view = this,
                            viewport = viewport,
                            isTouchpadMode = { session.touchpadMode.value },
                            getPointerSensitivity = { pointerSensitivity },
                            getScrollSensitivity = { scrollSensitivity },
                            getVideoDims = {
                                val m = Regex("""(\d+)\s*[x×]\s*(\d+)""").find(session.stats.value.resolution)
                                val w = m?.groupValues?.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 } ?: session.targetWidth.value
                                val h = m?.groupValues?.getOrNull(2)?.toIntOrNull()?.takeIf { it > 0 } ?: session.targetHeight.value
                                w to h
                            }
                        )
                    )
                }
            }
        )

        // 3. Pinned Telemetry HUD (color-coded latency, tap to hide)
        if (showHud && state is StreamConnectionState.Streaming) {
            val rttColor = when {
                stats.networkRttMs <= 35 -> NodeDeckColors.Online
                stats.networkRttMs <= 80 -> NodeDeckColors.Warning
                else -> NodeDeckColors.Offline
            }
            Surface(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(14.dp)
                    .clickable { session.setShowHud(false) },
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
                        text = "RTT ${stats.networkRttMs}ms",
                        color = rttColor,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }

        // 4. Floating Zoom Indicator & 1-Tap Reset Pill
        AnimatedVisibility(
            visible = state is StreamConnectionState.Streaming && (viewport.zoomScale > 1.02f || viewport.isPinching),
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 12.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(20.dp),
                color = Color(0xD9101820),
                modifier = Modifier
                    .border(1.dp, NodeDeckColors.AccentLight.copy(alpha = 0.55f), RoundedCornerShape(20.dp))
                    .clickable { viewport.reset() }
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.CenterFocusStrong,
                        contentDescription = null,
                        tint = NodeDeckColors.AccentLight,
                        modifier = Modifier.size(15.dp)
                    )
                    Text(
                        text = String.format("%.2f×", viewport.zoomScale),
                        color = Color.White,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = AppLocalization.t("双指拖动 · 点此复位", "2-Finger Pan · Tap Reset", lang),
                        color = Color(0xFFAEC4D6),
                        style = MaterialTheme.typography.labelSmall
                    )
                }
            }
        }

        // 5. Optional Floating Virtual Mouse Buttons (Left Drag-Lock / Left / Right)
        AnimatedVisibility(
            visible = showVirtualMouseButtons && state is StreamConnectionState.Streaming && !showKeyboardDock && !showSidebar,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 18.dp, bottom = 18.dp)
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                VirtualMousePill(
                    label = if (leftDragLocked) AppLocalization.t("松开左键", "Drop L", lang) else AppLocalization.t("左键拖选", "Drag L", lang),
                    active = leftDragLocked,
                    onClick = {
                        leftDragLocked = !leftDragLocked
                        MoonlightNative.sendMouseButton(pressed = leftDragLocked, button = MoonlightNative.BUTTON_LEFT)
                    }
                )
                VirtualMousePill(
                    label = AppLocalization.t("左键", "L-Click", lang),
                    active = false,
                    onClick = {
                        MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_LEFT)
                        MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_LEFT)
                    }
                )
                VirtualMousePill(
                    label = AppLocalization.t("右键", "R-Click", lang),
                    active = false,
                    onClick = {
                        MoonlightNative.sendMouseButton(pressed = true, button = MoonlightNative.BUTTON_RIGHT)
                        MoonlightNative.sendMouseButton(pressed = false, button = MoonlightNative.BUTTON_RIGHT)
                    }
                )
            }
        }

        // 6. Connecting / Disconnected Overlay
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

        // 7. UU-Remote-Style Edge-Tucking Floating Orb (1 tap directly opens categorized Sidebar)
        if ((state is StreamConnectionState.Streaming || state is StreamConnectionState.Connecting) && !showSidebar) {
            val tuckedDeltaX by animateFloatAsState(
                targetValue = if (orbIdleDocked) {
                    if (orbOnRightEdge) tuckShiftPx else -tuckShiftPx
                } else {
                    0f
                },
                animationSpec = tween(260),
                label = "orbTuck"
            )
            val rttDotColor = when {
                state !is StreamConnectionState.Streaming -> NodeDeckColors.AccentLight
                stats.networkRttMs <= 35 -> NodeDeckColors.Online
                stats.networkRttMs <= 80 -> NodeDeckColors.Warning
                else -> NodeDeckColors.Offline
            }

            Box(
                modifier = Modifier
                    .offset { IntOffset((orbOffsetX + tuckedDeltaX).roundToInt(), orbOffsetY.roundToInt()) }
                    .size(46.dp)
                    .alpha(orbAlpha)
                    .clip(CircleShape)
                    .background(Color(0xDD131C26))
                    .border(1.5.dp, NodeDeckColors.AccentLight.copy(alpha = 0.85f), CircleShape)
                    .pointerInput(screenW, screenH) {
                        detectDragGestures(
                            onDragStart = { orbInteractionTick++ },
                            onDragEnd = {
                                orbInteractionTick++
                                val snapRight = orbOffsetX >= (screenW - orbPx) / 2f
                                orbOnRightEdge = snapRight
                                orbOffsetX = if (snapRight) {
                                    (screenW - orbPx - edgeMarginPx).coerceAtLeast(edgeMarginPx)
                                } else {
                                    edgeMarginPx
                                }
                                orbOffsetY = orbOffsetY.coerceIn(20f, (screenH - orbPx - 20f).coerceAtLeast(20f))
                            }
                        ) { change, dragAmount ->
                            change.consume()
                            orbOffsetX = (orbOffsetX + dragAmount.x).coerceIn(4f, (screenW - orbPx - 4f).coerceAtLeast(4f))
                            orbOffsetY = (orbOffsetY + dragAmount.y).coerceIn(20f, (screenH - orbPx - 20f).coerceAtLeast(20f))
                        }
                    }
                    .clickable {
                        orbInteractionTick++
                        showSidebar = true
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Tune,
                    contentDescription = "Open Control Sidebar",
                    tint = NodeDeckColors.AccentLight,
                    modifier = Modifier.size(21.dp)
                )
                // Tiny live latency status dot on the orb corner
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 7.dp, end = 7.dp)
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(rttDotColor)
                )
            }
        }

        // 8. Auto-Focused Keyboard & Function Key Dock
        if (showKeyboardDock) {
            KeyboardAccessoryDock(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .imePadding(),
                onClose = { showKeyboardDock = false }
            )
        }

        // 9. UU-Remote-Style Categorized Right-Edge Slide-Over Sidebar
        AnimatedVisibility(
            visible = showSidebar,
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(180))
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0x66000000))
                    .clickable { showSidebar = false },
                contentAlignment = Alignment.CenterEnd
            ) {
                Surface(
                    modifier = Modifier
                        .width(356.dp)
                        .fillMaxHeight()
                        .animateEnterExit(
                            enter = slideInHorizontally(tween(220)) { it },
                            exit = slideOutHorizontally(tween(200)) { it }
                        )
                        .clickable(enabled = false) {},
                    shape = RoundedCornerShape(topStart = 20.dp, bottomStart = 20.dp),
                    color = Color(0xF5111821),
                    tonalElevation = 12.dp
                ) {
                    Column(modifier = Modifier.fillMaxSize()) {
                        // A. Compact Top Header (Host + Live Telemetry + HUD + Close)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(start = 16.dp, end = 10.dp, top = 12.dp, bottom = 8.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .size(8.dp)
                                            .clip(CircleShape)
                                            .background(
                                                when {
                                                    stats.networkRttMs <= 35 -> NodeDeckColors.Online
                                                    stats.networkRttMs <= 80 -> NodeDeckColors.Warning
                                                    else -> NodeDeckColors.Offline
                                                }
                                            )
                                    )
                                    Text(
                                        text = title.ifBlank { "NodeDeck" },
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.SemiBold,
                                        color = Color.White,
                                        maxLines = 1
                                    )
                                }
                                Text(
                                    text = "${stats.fps}/${targetFps} FPS · ${String.format("%.1f", stats.bitrateMbps)} Mbps · ${stats.networkRttMs}ms",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color(0xFF9EB3C2),
                                    maxLines = 1
                                )
                            }
                            IconButton(
                                onClick = { session.setShowHud(!showHud) },
                                modifier = Modifier.size(36.dp)
                            ) {
                                Icon(
                                    Icons.Default.Speed,
                                    contentDescription = "HUD",
                                    tint = if (showHud) NodeDeckColors.AccentLight else Color(0xFF7D92A4),
                                    modifier = Modifier.size(19.dp)
                                )
                            }
                            IconButton(
                                onClick = { showSidebar = false },
                                modifier = Modifier.size(36.dp)
                            ) {
                                Icon(
                                    Icons.Default.Close,
                                    contentDescription = "Close",
                                    tint = Color.White,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        }

                        // B. UU-Style 3-Segment Category Switcher (Control / Display / More)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp, vertical = 4.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color(0xFF1A232E))
                                .padding(3.dp),
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            SidebarTabChip(
                                modifier = Modifier.weight(1f),
                                label = AppLocalization.t("常用", "Control", lang),
                                selected = activeTab == SidebarTab.CONTROL,
                                onClick = { activeTab = SidebarTab.CONTROL }
                            )
                            SidebarTabChip(
                                modifier = Modifier.weight(1f),
                                label = AppLocalization.t("画面", "Display", lang),
                                selected = activeTab == SidebarTab.DISPLAY,
                                onClick = { activeTab = SidebarTab.DISPLAY }
                            )
                            SidebarTabChip(
                                modifier = Modifier.weight(1f),
                                label = AppLocalization.t("更多", "More", lang),
                                selected = activeTab == SidebarTab.MORE,
                                onClick = { activeTab = SidebarTab.MORE }
                            )
                        }

                        HorizontalDivider(
                            color = Color(0xFF23303D),
                            modifier = Modifier.padding(top = 6.dp)
                        )

                        // C. Scrollable Tab Body (clean, concise per-category view)
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth()
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            when (activeTab) {
                                SidebarTab.CONTROL -> {
                                    // 2x3 Tactile Control Tiles (1-tap access to core controls)
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
                                            label = AppLocalization.t("弹出键盘", "Keyboard", lang),
                                            active = showKeyboardDock,
                                            onClick = {
                                                showKeyboardDock = !showKeyboardDock
                                                showSidebar = false
                                            }
                                        )
                                        ControlTileButton(
                                            modifier = Modifier.weight(1f),
                                            icon = Icons.Default.Mouse,
                                            label = AppLocalization.t("虚拟鼠标", "Mouse", lang),
                                            active = showVirtualMouseButtons,
                                            onClick = {
                                                showVirtualMouseButtons = !showVirtualMouseButtons
                                                showSidebar = false
                                            }
                                        )
                                    }

                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                                    ) {
                                        ControlTileButton(
                                            modifier = Modifier.weight(1f),
                                            icon = if (audioMuted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                            label = if (audioMuted) AppLocalization.t("已静音", "Muted", lang) else AppLocalization.t("声音开", "Audio", lang),
                                            active = !audioMuted,
                                            onClick = { session.setAudioMuted(!audioMuted) }
                                        )
                                        if (session.hasSshHost) {
                                            ControlTileButton(
                                                modifier = Modifier.weight(1f),
                                                icon = if (privacyEnabled) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                                label = AppLocalization.t("防窥黑屏", "Privacy", lang),
                                                active = privacyEnabled,
                                                onClick = { session.togglePrivacyScreen() }
                                            )
                                            ControlTileButton(
                                                modifier = Modifier.weight(1f),
                                                icon = Icons.Default.DesktopWindows,
                                                label = if (remoteDisplays.size > 1) {
                                                    AppLocalization.t("切换屏幕", "Switch Disp", lang)
                                                } else {
                                                    AppLocalization.t("多屏设置", "Displays", lang)
                                                },
                                                active = switchingDisplay,
                                                onClick = {
                                                    if (remoteDisplays.size > 1 && !switchingDisplay) {
                                                        val idx = remoteDisplays.indexOfFirst { it.isSelected }
                                                        val next = remoteDisplays[(idx + 1) % remoteDisplays.size]
                                                        showSidebar = false
                                                        session.switchRemoteDisplay(next)
                                                    } else {
                                                        activeTab = SidebarTab.DISPLAY
                                                    }
                                                }
                                            )
                                        } else {
                                            ControlTileButton(
                                                modifier = Modifier.weight(1f),
                                                icon = Icons.Default.Speed,
                                                label = AppLocalization.t("性能浮窗", "HUD", lang),
                                                active = showHud,
                                                onClick = { session.setShowHud(!showHud) }
                                            )
                                            ControlTileButton(
                                                modifier = Modifier.weight(1f),
                                                icon = Icons.Default.CenterFocusStrong,
                                                label = AppLocalization.t("画面复位", "Reset Zoom", lang),
                                                active = viewport.zoomScale > 1.02f,
                                                onClick = { viewport.reset() }
                                            )
                                        }
                                    }

                                    // Pinch-Zoom quick presets row
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Text(
                                            text = AppLocalization.t("双指缩放倍率", "Pinch Zoom", lang),
                                            style = MaterialTheme.typography.labelMedium,
                                            color = Color(0xFF9EB3C2)
                                        )
                                        Text(
                                            text = String.format("%.2f×", viewport.zoomScale),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = NodeDeckColors.AccentLight,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                    }
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        listOf(1.0f to "1.0×", 1.5f to "1.5×", 2.0f to "2.0×", 3.0f to "3.0×").forEach { (scale, lbl) ->
                                            PillChoice(
                                                label = lbl,
                                                selected = abs(viewport.zoomScale - scale) < 0.08f,
                                                onClick = { viewport.setPresetScale(scale) }
                                            )
                                        }
                                    }

                                    // Quick Hotkeys
                                    Text(
                                        text = AppLocalization.t("常用组合键", "Quick Hotkeys", lang),
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
                                        KeyChip("⌘+C") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x43, extMod = true) }
                                        KeyChip("⌘+V") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x56, extMod = true) }
                                        KeyChip("⌘+W") { tapCombo(0x5B, MoonlightNative.MODIFIER_META, 0x57, extMod = true) }
                                        KeyChip("Ctrl+C") { tapCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x43) }
                                        KeyChip("Ctrl+V") { tapCombo(0xA2, MoonlightNative.MODIFIER_CTRL, 0x56) }
                                        KeyChip("Esc") {
                                            MoonlightNative.sendVirtualKey(0x1B, true)
                                            MoonlightNative.sendVirtualKey(0x1B, false)
                                        }
                                    }
                                }

                                SidebarTab.DISPLAY -> {
                                    // Multi-Display Switcher
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
                                                                showSidebar = false
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
                                    }

                                    // Aspect Ratio
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
                                                text = AppLocalization.t("画面适配", "Aspect Mode", lang),
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
                                            onClick = {
                                                fillCropMode = false
                                                viewport.reset()
                                            }
                                        )
                                        PillChoice(
                                            label = AppLocalization.t("铺满裁剪", "Fill Crop", lang),
                                            selected = fillCropMode,
                                            onClick = {
                                                fillCropMode = true
                                                viewport.reset()
                                            }
                                        )
                                    }

                                    // Screen Orientation
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Icon(
                                            Icons.Default.ScreenRotation,
                                            contentDescription = null,
                                            tint = NodeDeckColors.AccentLight,
                                            modifier = Modifier.size(15.dp)
                                        )
                                        Text(
                                            text = AppLocalization.t("屏幕方向", "Orientation", lang),
                                            style = MaterialTheme.typography.labelMedium,
                                            color = Color(0xFF9EB3C2)
                                        )
                                    }
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        PillChoice(
                                            label = AppLocalization.t("横屏", "Landscape", lang),
                                            selected = orientationMode == StreamOrientationMode.LANDSCAPE,
                                            onClick = { onSelectOrientation(StreamOrientationMode.LANDSCAPE) }
                                        )
                                        PillChoice(
                                            label = AppLocalization.t("竖屏", "Portrait", lang),
                                            selected = orientationMode == StreamOrientationMode.PORTRAIT,
                                            onClick = { onSelectOrientation(StreamOrientationMode.PORTRAIT) }
                                        )
                                        PillChoice(
                                            label = AppLocalization.t("自动", "Auto", lang),
                                            selected = orientationMode == StreamOrientationMode.AUTO,
                                            onClick = { onSelectOrientation(StreamOrientationMode.AUTO) }
                                        )
                                    }

                                    // Resolution Selector
                                    Text(
                                        text = AppLocalization.t("串流分辨率", "Resolution", lang),
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
                                                    showSidebar = false
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
                                            text = "${AppLocalization.t("自动码率", "Auto", lang)} ${autoMbps} Mbps",
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
                                                    showSidebar = false
                                                }
                                            )
                                        }
                                    }
                                }

                                SidebarTab.MORE -> {
                                    // Touchpad Sensitivity Slider
                                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween
                                        ) {
                                            Text(
                                                text = AppLocalization.t("触控板灵敏度", "Pointer Speed", lang),
                                                style = MaterialTheme.typography.labelMedium,
                                                color = Color(0xFF9EB3C2)
                                            )
                                            Text(
                                                text = String.format("%.1f×", pointerSensitivity),
                                                style = MaterialTheme.typography.labelSmall,
                                                color = NodeDeckColors.AccentLight
                                            )
                                        }
                                        Slider(
                                            value = pointerSensitivity,
                                            onValueChange = { pointerSensitivity = it },
                                            valueRange = 0.6f..2.5f,
                                            colors = SliderDefaults.colors(
                                                thumbColor = NodeDeckColors.AccentLight,
                                                activeTrackColor = NodeDeckColors.Accent
                                            )
                                        )
                                    }

                                    // Scroll Sensitivity Slider
                                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween
                                        ) {
                                            Text(
                                                text = AppLocalization.t("双指滚轮速度", "Scroll Speed", lang),
                                                style = MaterialTheme.typography.labelMedium,
                                                color = Color(0xFF9EB3C2)
                                            )
                                            Text(
                                                text = String.format("%.1f×", scrollSensitivity),
                                                style = MaterialTheme.typography.labelSmall,
                                                color = NodeDeckColors.AccentLight
                                            )
                                        }
                                        Slider(
                                            value = scrollSensitivity,
                                            onValueChange = { scrollSensitivity = it },
                                            valueRange = 0.5f..2.5f,
                                            colors = SliderDefaults.colors(
                                                thumbColor = NodeDeckColors.AccentLight,
                                                activeTrackColor = NodeDeckColors.Accent
                                            )
                                        )
                                    }

                                    // Clipboard Sync
                                    if (session.hasSshHost) {
                                        Text(
                                            text = AppLocalization.t("剪贴板同步", "Clipboard Sync", lang),
                                            style = MaterialTheme.typography.labelMedium,
                                            color = Color(0xFF9EB3C2)
                                        )
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                                        ) {
                                            ControlTileButton(
                                                modifier = Modifier.weight(1f),
                                                icon = Icons.Default.ContentPaste,
                                                label = AppLocalization.t("手机 → 电脑", "Push Clip", lang),
                                                active = false,
                                                onClick = { session.pushAndroidClipboardToRemote() }
                                            )
                                            ControlTileButton(
                                                modifier = Modifier.weight(1f),
                                                icon = Icons.Default.ContentCopy,
                                                label = AppLocalization.t("电脑 → 手机", "Pull Clip", lang),
                                                active = false,
                                                onClick = { session.pullRemoteClipboardToAndroid() }
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

                                    // Reset stuck keys
                                    OutlinedButton(
                                        modifier = Modifier.fillMaxWidth(),
                                        onClick = {
                                            MoonlightNative.releaseAllRemoteModifiers()
                                            showSidebar = false
                                        }
                                    ) {
                                        Text(AppLocalization.t("释放卡住的修饰键 (Ctrl/Alt/⌘)", "Reset Stuck Modifier Keys", lang), fontSize = 12.sp)
                                    }

                                    // Compact Gesture Quick-Guide
                                    Surface(
                                        shape = RoundedCornerShape(10.dp),
                                        color = Color(0xFF1A242E)
                                    ) {
                                        Text(
                                            text = AppLocalization.t(
                                                "手势速查：双指捏合超过防误触阈值后缩放（最高 4×），放大后双指拖动漫游；双指轻点右键；1× 下双指滑动滚轮；触控板长按拖拽。",
                                                "Gestures: Pinch past deadzone to zoom (up to 4×) & 2-finger pan; 2-finger tap = right-click; 2-finger drag at 1× = scroll; long-press to drag in Touchpad.",
                                                lang
                                            ),
                                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = Color(0xFF93AABF)
                                        )
                                    }
                                }
                            }
                        }

                        // D. Pinned Bottom Session Actions (always 1 tap away without scrolling)
                        HorizontalDivider(color = Color(0xFF23303D))
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 8.dp),
                                onClick = {
                                    showSidebar = false
                                    onReconnect()
                                }
                            ) {
                                Text(AppLocalization.t("重连", "Reconnect", lang), fontSize = 12.sp, maxLines = 1, softWrap = false)
                            }
                            Button(
                                modifier = Modifier.weight(1f),
                                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 8.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF344352)),
                                onClick = { onDisconnect(false) }
                            ) {
                                Text(AppLocalization.t("断开", "Disconnect", lang), fontSize = 12.sp, maxLines = 1, softWrap = false)
                            }
                            Button(
                                modifier = Modifier.weight(0.9f),
                                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 8.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = NodeDeckColors.Offline),
                                onClick = { onDisconnect(true) }
                            ) {
                                Icon(Icons.Default.PowerSettingsNew, contentDescription = null, modifier = Modifier.size(14.dp))
                                Spacer(Modifier.width(3.dp))
                                Text(AppLocalization.t("退出", "Quit", lang), fontSize = 12.sp, maxLines = 1, softWrap = false)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SidebarTabChip(
    modifier: Modifier = Modifier,
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) NodeDeckColors.Accent else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(vertical = 7.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Color.White else Color(0xFFA6B9C9),
            maxLines = 1,
            softWrap = false
        )
    }
}

@Composable
private fun VirtualMousePill(
    label: String,
    active: Boolean,
    onClick: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = if (active) NodeDeckColors.Accent.copy(alpha = 0.85f) else Color(0xB8141D26),
        modifier = Modifier
            .border(
                1.dp,
                if (active) NodeDeckColors.AccentLight else Color(0x668EA8BD),
                RoundedCornerShape(18.dp)
            )
            .clickable(onClick = onClick)
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 13.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelMedium,
            color = Color.White,
            maxLines = 1,
            softWrap = false
        )
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
            color = if (selected) Color.White else Color(0xFFC2D0DC),
            maxLines = 1,
            softWrap = false
        )
    }
}

@Composable
private fun ControlTileButton(
    modifier: Modifier = Modifier,
    icon: ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit
) {
    Surface(
        modifier = modifier.clickable(onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = if (active) NodeDeckColors.Accent.copy(alpha = 0.34f) else Color(0xFF1B2530)
    ) {
        Column(
            modifier = Modifier
                .border(
                    width = 1.dp,
                    color = if (active) NodeDeckColors.AccentLight.copy(alpha = 0.5f) else Color(0xFF273442),
                    shape = RoundedCornerShape(12.dp)
                )
                .padding(vertical = 10.dp, horizontal = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = if (active) NodeDeckColors.AccentLight else Color(0xFFC2D0DC),
                modifier = Modifier.size(19.dp)
            )
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.SansSerif,
                color = Color.White,
                maxLines = 1,
                softWrap = false
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
    var showFnRow by remember { mutableStateOf(false) }
    var textInput by remember { mutableStateOf("") }

    val focusRequester = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current

    LaunchedEffect(Unit) {
        delay(80L)
        runCatching { focusRequester.requestFocus() }
        keyboardController?.show()
    }

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

    fun sendCombo(modVk: Int, modFlag: Byte, keyVk: Int, extMod: Boolean = false) {
        MoonlightNative.sendVirtualKey(modVk, true, extended = extMod)
        MoonlightNative.sendVirtualKey(keyVk, true, modifiers = modFlag)
        MoonlightNative.sendVirtualKey(keyVk, false, modifiers = modFlag)
        MoonlightNative.sendVirtualKey(modVk, false, extended = extMod)
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 6.dp),
        shape = RoundedCornerShape(14.dp),
        color = Color(0xF0131A22)
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
                KeyChip("⌘/Win", active = winSticky) { winSticky = !winSticky }
                KeyChip("Fn", active = showFnRow) { showFnRow = !showFnRow }
                KeyChip("⌘+C") { sendCombo(0x5B, MoonlightNative.MODIFIER_META, 0x43, extMod = true) }
                KeyChip("⌘+V") { sendCombo(0x5B, MoonlightNative.MODIFIER_META, 0x56, extMod = true) }
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

            if (showFnRow) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    KeyChip("Home") { sendTapVk(0x24, extended = true) }
                    KeyChip("End") { sendTapVk(0x23, extended = true) }
                    KeyChip("PgUp") { sendTapVk(0x21, extended = true) }
                    KeyChip("PgDn") { sendTapVk(0x22, extended = true) }
                    for (fn in 1..12) {
                        KeyChip("F$fn") { sendTapVk(0x6F + fn) }
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                OutlinedTextField(
                    value = textInput,
                    onValueChange = { textInput = it },
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(focusRequester),
                    singleLine = true,
                    placeholder = { Text("输入文本发送到远端…", fontSize = 13.sp) },
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
                IconButton(onClick = {
                    keyboardController?.hide()
                    onClose()
                }) {
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
            color = Color.White,
            maxLines = 1,
            softWrap = false
        )
    }
}
