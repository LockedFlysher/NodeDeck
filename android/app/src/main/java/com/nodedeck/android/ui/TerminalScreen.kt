package com.nodedeck.android.ui

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.text.InputType
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.InteractiveShellHandle
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.ui.theme.NodeDeckColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Interactive character-by-character terminal View with direct IME InputConnection,
 * ANSI color rendering, visible cursor, scrollback touch drag, and automatic PTY sizing.
 */
private class InteractiveTerminalView(
    context: Context,
    private val emulator: Vt100Emulator,
    private val onSendBytes: (ByteArray) -> Unit,
    private val onGridResized: (cols: Int, rows: Int) -> Unit,
    private val consumeStickyCtrl: () -> Boolean,
    private val consumeStickyAlt: () -> Boolean
) : View(context) {

    private val density = resources.displayMetrics.density
    private val scaledDensity = resources.displayMetrics.scaledDensity

    private val bgPaint = Paint().apply { color = Vt100Emulator.DEFAULT_BG }
    private val cellBgPaint = Paint()
    private val cursorPaint = Paint().apply { color = 0xAA39A3AE.toInt() }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        color = Vt100Emulator.DEFAULT_FG
    }
    private val boldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        color = Vt100Emulator.DEFAULT_FG
    }

    private var fontSizeSp = 10.5f
    private var charWidth = 10f
    private var lineHeight = 20f
    private var textBaselineOffset = 15f
    private val padH = 6f * density
    private val padV = 6f * density

    // 0 = pinned to live bottom; >0 = scrolled up by N lines
    private var scrollOffsetLines = 0f

    private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onSingleTapUp(e: MotionEvent): Boolean {
            requestFocusAndShowKeyboard()
            return true
        }

        override fun onScroll(
            e1: MotionEvent?,
            e2: MotionEvent,
            distanceX: Float,
            distanceY: Float
        ): Boolean {
            val snap = emulator.snapshot()
            scrollOffsetLines = (scrollOffsetLines - (distanceY / lineHeight))
                .coerceIn(0f, snap.scrollbackSize.toFloat())
            invalidate()
            return true
        }
    })

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        applyFontSize(fontSizeSp)
        emulator.onScreenChanged = {
            post {
                if (scrollOffsetLines < 0.5f) scrollOffsetLines = 0f
                invalidate()
            }
        }
    }

    fun applyFontSize(sp: Float) {
        fontSizeSp = sp.coerceIn(9f, 22f)
        val px = fontSizeSp * scaledDensity
        textPaint.textSize = px
        boldPaint.textSize = px
        charWidth = max(4f, textPaint.measureText("M"))
        val fm = textPaint.fontMetrics
        lineHeight = max(8f, (fm.descent - fm.ascent) + 3f * density)
        textBaselineOffset = -fm.ascent + 1.5f * density
        recalculateGridSize()
        invalidate()
    }

    fun requestFocusAndShowKeyboard() {
        requestFocus()
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }

    fun scrollToBottom() {
        scrollOffsetLines = 0f
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        recalculateGridSize()
    }

    private fun recalculateGridSize() {
        if (width <= 0 || height <= 0) return
        val usableW = (width - padH * 2f).coerceAtLeast(charWidth)
        val usableH = (height - padV * 2f).coerceAtLeast(lineHeight)
        val newCols = floor(usableW / charWidth).toInt().coerceIn(24, 200)
        val newRows = floor(usableH / lineHeight).toInt().coerceIn(8, 100)
        if (emulator.resize(newCols, newRows)) {
            onGridResized(newCols, newRows)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        gestureDetector.onTouchEvent(event)
        return true
    }

    private var activeComposing = ""

    fun resetImeComposing() {
        activeComposing = ""
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.restartInput(this)
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        activeComposing = ""
        // TYPE_NULL matches Termux: disables Pinyin/autocorrect interception AND avoids OEM password-screen blackout
        outAttrs.inputType = InputType.TYPE_NULL
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
        return object : BaseInputConnection(this, false) {
            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                val next = text?.toString().orEmpty()
                applyComposingDiff(activeComposing, next)
                activeComposing = next
                return true
            }

            override fun finishComposingText(): Boolean {
                activeComposing = ""
                return true
            }

            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                val committed = text?.toString().orEmpty()
                if (activeComposing.isNotEmpty()) {
                    applyComposingDiff(activeComposing, committed)
                    activeComposing = ""
                } else if (committed.isNotEmpty()) {
                    emitTypedString(committed)
                }
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (beforeLength > 0) {
                    if (activeComposing.isNotEmpty()) {
                        activeComposing = activeComposing.dropLast(min(beforeLength, activeComposing.length))
                    }
                    repeat(beforeLength) {
                        scrollOffsetLines = 0f
                        onSendBytes(byteArrayOf(0x7F))
                    }
                }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    activeComposing = ""
                    if (handleKeyDownEvent(event)) return true
                }
                return super.sendKeyEvent(event)
            }
        }
    }

    private fun applyComposingDiff(prev: String, next: String) {
        var common = 0
        val limit = min(prev.length, next.length)
        while (common < limit && prev[common] == next[common]) {
            common++
        }
        val toDelete = prev.length - common
        if (toDelete > 0) {
            scrollOffsetLines = 0f
            onSendBytes(ByteArray(toDelete) { 0x7F })
        }
        val toInsert = next.substring(common)
        if (toInsert.isNotEmpty()) {
            emitTypedString(toInsert)
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (handleKeyDownEvent(event)) return true
        return super.onKeyDown(keyCode, event)
    }

    private fun emitTypedString(s: String) {
        scrollOffsetLines = 0f
        if (s.length == 1) {
            val ch = s[0]
            if (consumeStickyCtrl()) {
                val ctrlByte = toCtrlByte(ch)
                if (ctrlByte != null) {
                    onSendBytes(byteArrayOf(ctrlByte))
                    return
                }
            }
            if (consumeStickyAlt()) {
                onSendBytes(byteArrayOf(0x1B) + s.toByteArray(Charsets.UTF_8))
                return
            }
        }
        val normalized = s.replace("\n", "\r")
        onSendBytes(normalized.toByteArray(Charsets.UTF_8))
    }

    private fun handleKeyDownEvent(event: KeyEvent): Boolean {
        scrollOffsetLines = 0f
        return when (event.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                onSendBytes(byteArrayOf('\r'.code.toByte()))
                true
            }
            KeyEvent.KEYCODE_DEL -> {
                onSendBytes(byteArrayOf(0x7F))
                true
            }
            KeyEvent.KEYCODE_FORWARD_DEL -> {
                onSendBytes("\u001B[3~".toByteArray(Charsets.US_ASCII))
                true
            }
            KeyEvent.KEYCODE_TAB -> {
                onSendBytes(byteArrayOf(0x09))
                true
            }
            KeyEvent.KEYCODE_ESCAPE -> {
                onSendBytes(byteArrayOf(0x1B))
                true
            }
            KeyEvent.KEYCODE_DPAD_UP -> {
                onSendBytes("\u001B[A".toByteArray(Charsets.US_ASCII)); true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                onSendBytes("\u001B[B".toByteArray(Charsets.US_ASCII)); true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                onSendBytes("\u001B[C".toByteArray(Charsets.US_ASCII)); true
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                onSendBytes("\u001B[D".toByteArray(Charsets.US_ASCII)); true
            }
            else -> {
                val u = event.unicodeChar
                if (u != 0 && !event.isSystem) {
                    val ch = u.toChar()
                    if (event.isCtrlPressed || consumeStickyCtrl()) {
                        val ctrlByte = toCtrlByte(ch)
                        if (ctrlByte != null) {
                            onSendBytes(byteArrayOf(ctrlByte))
                            return true
                        }
                    }
                    if (event.isAltPressed || consumeStickyAlt()) {
                        onSendBytes(byteArrayOf(0x1B) + ch.toString().toByteArray(Charsets.UTF_8))
                        return true
                    }
                    onSendBytes(ch.toString().toByteArray(Charsets.UTF_8))
                    true
                } else {
                    false
                }
            }
        }
    }

    private fun toCtrlByte(ch: Char): Byte? {
        val lower = ch.lowercaseChar()
        return when {
            lower in 'a'..'z' -> (lower.code - 'a'.code + 1).toByte()
            ch == '@' || ch == ' ' -> 0x00
            ch == '[' -> 0x1B
            ch == '\\' -> 0x1C
            ch == ']' -> 0x1D
            ch == '^' -> 0x1E
            ch == '_' -> 0x1F
            else -> null
        }
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), bgPaint)

        val snap = emulator.snapshot()
        val totalLines = snap.lines.size
        val scrollInt = scrollOffsetLines.toInt().coerceIn(0, snap.scrollbackSize)
        val firstLineIdx = (totalLines - snap.rows - scrollInt).coerceAtLeast(0)

        for (screenRow in 0 until snap.rows) {
            val lineIdx = firstLineIdx + screenRow
            if (lineIdx >= totalLines) break
            val rowCells = snap.lines[lineIdx]
            val yTop = padV + screenRow * lineHeight
            val yBaseline = yTop + textBaselineOffset

            for (col in 0 until min(snap.cols, rowCells.size)) {
                val cell = rowCells[col]
                val x = padH + col * charWidth
                val fg = if (cell.inverse) cell.bg else cell.fg
                val bg = if (cell.inverse) cell.fg else cell.bg

                if (bg != Vt100Emulator.DEFAULT_BG) {
                    cellBgPaint.color = bg
                    canvas.drawRect(x, yTop, x + charWidth + 0.5f, yTop + lineHeight, cellBgPaint)
                }
                if (cell.ch != ' ') {
                    val p = if (cell.bold) boldPaint else textPaint
                    p.color = fg
                    canvas.drawText(cell.ch.toString(), x, yBaseline, p)
                }
            }
        }

        // Draw cursor when pinned to live bottom
        if (scrollInt == 0) {
            val cx = padH + snap.cursorCol * charWidth
            val cy = padV + snap.cursorRow * lineHeight
            canvas.drawRect(cx, cy, cx + charWidth, cy + lineHeight, cursorPaint)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    host: SSHHost,
    allHosts: List<SSHHost>,
    viewModel: MainViewModel,
    onBack: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val emulator = remember(host.id) { Vt100Emulator(initialCols = 80, initialRows = 28) }
    var terminalViewRef by remember { mutableStateOf<InteractiveTerminalView?>(null) }
    var shellHandle by remember { mutableStateOf<InteractiveShellHandle?>(null) }
    var connecting by remember { mutableStateOf(true) }
    var errorMsg by remember { mutableStateOf<String?>(null) }
    var reconnectTick by remember { mutableIntStateOf(0) }
    var fontSizeSp by remember { mutableFloatStateOf(10.5f) }
    var ctrlSticky by remember { mutableStateOf(false) }
    var altSticky by remember { mutableStateOf(false) }

    fun sendRawBytes(bytes: ByteArray) {
        val handle = shellHandle ?: return
        scope.launch(Dispatchers.IO) {
            runCatching {
                handle.outputStream.write(bytes)
                handle.outputStream.flush()
            }
        }
    }

    fun sendString(text: String) = sendRawBytes(text.toByteArray(Charsets.UTF_8))

    LaunchedEffect(host.id, reconnectTick) {
        shellHandle?.close()
        shellHandle = null
        connecting = true
        errorMsg = null
        emulator.clearAll()
        emulator.feed("Connecting to ${host.loginTarget}...\r\n".toByteArray(Charsets.UTF_8))
        try {
            val handle = viewModel.sshManager.openInteractiveShell(
                host = host,
                allHosts = allHosts,
                cols = emulator.cols,
                rows = emulator.rows
            )
            shellHandle = handle
            connecting = false
            emulator.clearAll()
            terminalViewRef?.post { terminalViewRef?.requestFocusAndShowKeyboard() }
            withContext(Dispatchers.IO) {
                val buf = ByteArray(4096)
                while (isActive && handle.isConnected()) {
                    val n = runCatching { handle.inputStream.read(buf) }.getOrDefault(-1)
                    if (n <= 0) break
                    emulator.feed(buf, n)
                }
            }
            if (isActive) {
                emulator.feed("\r\n[Session closed]\r\n".toByteArray(Charsets.UTF_8))
            }
        } catch (t: Throwable) {
            connecting = false
            errorMsg = t.message ?: "Connection failed"
            emulator.feed("\r\nError: $errorMsg\r\n".toByteArray(Charsets.UTF_8))
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            shellHandle?.close()
        }
    }

    Scaffold(
        containerColor = Color(0xFF0A0F14),
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color(0xFF10171F),
                    titleContentColor = Color.White,
                    navigationIconContentColor = Color.White,
                    actionIconContentColor = Color.White
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                title = {
                    Column {
                        Text("${host.alias} · SSH", fontSize = 16.sp)
                        Text(
                            text = if (connecting) {
                                AppLocalization.t("连接中…", "Connecting…", lang)
                            } else if (shellHandle?.isConnected() == true) {
                                "${host.loginTarget} (${emulator.cols}×${emulator.rows})"
                            } else {
                                errorMsg ?: AppLocalization.t("已断开", "Disconnected", lang)
                            },
                            style = MaterialTheme.typography.labelSmall,
                            color = if (shellHandle?.isConnected() == true) NodeDeckColors.Online else Color(0xFF9EB3C2)
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { terminalViewRef?.requestFocusAndShowKeyboard() }) {
                        Icon(Icons.Default.Keyboard, contentDescription = "Keyboard")
                    }
                    IconButton(onClick = { emulator.clearAll() }) {
                        Icon(Icons.Default.DeleteSweep, contentDescription = "Clear")
                    }
                    IconButton(onClick = { reconnectTick++ }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Reconnect")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .background(Color(0xFF0A0F14))
            ) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        InteractiveTerminalView(
                            context = ctx,
                            emulator = emulator,
                            onSendBytes = { bytes -> sendRawBytes(bytes) },
                            onGridResized = { cols, rows ->
                                scope.launch(Dispatchers.IO) {
                                    shellHandle?.resize(cols, rows)
                                }
                            },
                            consumeStickyCtrl = {
                                val was = ctrlSticky
                                if (was) ctrlSticky = false
                                was
                            },
                            consumeStickyAlt = {
                                val was = altSticky
                                if (was) altSticky = false
                                was
                            }
                        ).also { view ->
                            view.applyFontSize(fontSizeSp)
                            terminalViewRef = view
                        }
                    }
                )
                if (connecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.align(Alignment.Center),
                        color = NodeDeckColors.AccentLight
                    )
                }
            }

            // Direct real-time SSH extra keys bar (Tab / Esc / Ctrl / Alt / Arrows / Paste)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color(0xFF121A22))
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 8.dp, vertical = 7.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TermKey("Tab") {
                    terminalViewRef?.resetImeComposing()
                    terminalViewRef?.scrollToBottom()
                    sendRawBytes(byteArrayOf(0x09))
                }
                TermKey("Esc") {
                    terminalViewRef?.resetImeComposing()
                    terminalViewRef?.scrollToBottom()
                    sendRawBytes(byteArrayOf(0x1B))
                }
                TermKey("Ctrl", active = ctrlSticky) { ctrlSticky = !ctrlSticky }
                TermKey("Alt", active = altSticky) { altSticky = !altSticky }
                TermKey("Ctrl+C") {
                    terminalViewRef?.resetImeComposing()
                    sendRawBytes(byteArrayOf(0x03))
                }
                TermKey("Ctrl+D") {
                    terminalViewRef?.resetImeComposing()
                    sendRawBytes(byteArrayOf(0x04))
                }
                TermKey("Ctrl+R") {
                    terminalViewRef?.resetImeComposing()
                    sendRawBytes(byteArrayOf(0x12))
                }
                TermKey("Ctrl+L") {
                    terminalViewRef?.resetImeComposing()
                    sendRawBytes(byteArrayOf(0x0C))
                }
                TermKey("↑") { terminalViewRef?.resetImeComposing(); sendString("\u001B[A") }
                TermKey("↓") { terminalViewRef?.resetImeComposing(); sendString("\u001B[B") }
                TermKey("←") { terminalViewRef?.resetImeComposing(); sendString("\u001B[D") }
                TermKey("→") { terminalViewRef?.resetImeComposing(); sendString("\u001B[C") }
                TermKey("Home") { terminalViewRef?.resetImeComposing(); sendString("\u001B[H") }
                TermKey("End") { terminalViewRef?.resetImeComposing(); sendString("\u001B[F") }
                TermKey("|") { sendString("|") }
                TermKey("~") { sendString("~") }
                TermKey("/") { sendString("/") }
                TermKey("-") { sendString("-") }
                TermKey("A-") {
                    fontSizeSp = (fontSizeSp - 1f).coerceAtLeast(9f)
                    terminalViewRef?.applyFontSize(fontSizeSp)
                }
                TermKey("A+") {
                    fontSizeSp = (fontSizeSp + 1f).coerceAtMost(20f)
                    terminalViewRef?.applyFontSize(fontSizeSp)
                }
                Surface(
                    shape = RoundedCornerShape(6.dp),
                    color = Color(0xFF23303D),
                    modifier = Modifier.clickable {
                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = cm.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
                        if (clip.isNotEmpty()) {
                            terminalViewRef?.scrollToBottom()
                            sendString(clip.replace("\n", "\r"))
                        }
                    }
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 9.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Default.ContentPaste, contentDescription = "Paste", tint = Color.White, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(AppLocalization.t("粘贴", "Paste", lang), style = MaterialTheme.typography.labelSmall, color = Color.White)
                    }
                }
            }
        }
    }
}

@Composable
private fun TermKey(label: String, active: Boolean = false, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = if (active) NodeDeckColors.Accent else Color(0xFF23303D),
        modifier = Modifier.clickable(onClick = onClick)
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 11.dp, vertical = 7.dp),
            style = MaterialTheme.typography.labelSmall,
            color = Color.White
        )
    }
}
