package com.nodedeck.android.ui

import kotlin.math.max
import kotlin.math.min

/**
 * Lightweight, fast VT100 / xterm-256color terminal emulator supporting:
 * - Real-time character-by-character editing, Backspace, Tab completion, Ctrl+R
 * - Cursor positioning, erase line/screen (CSI K / J), scroll regions (CSI r)
 * - Alternate screen buffer (?1049h / ?1049l) for vim, htop, less, tmux
 * - 16-color, 256-color, and 24-bit TrueColor SGR attributes + bold/inverse
 * - Scrollback history ring buffer
 */
class Vt100Emulator(
    initialCols: Int = 80,
    initialRows: Int = 24,
    private val maxScrollback: Int = 2000
) {
    data class Cell(
        var ch: Char = ' ',
        var fg: Int = DEFAULT_FG,
        var bg: Int = DEFAULT_BG,
        var bold: Boolean = false,
        var inverse: Boolean = false
    )

    private val lock = Any()

    var cols: Int = initialCols.coerceAtLeast(20)
        private set
    var rows: Int = initialRows.coerceAtLeast(8)
        private set

    private var grid: Array<Array<Cell>> = createGrid(rows, cols)
    private var altGrid: Array<Array<Cell>>? = null
    private var scrollback: ArrayDeque<Array<Cell>> = ArrayDeque()

    var cursorRow: Int = 0
        private set
    var cursorCol: Int = 0
        private set
    private var savedRow: Int = 0
    private var savedCol: Int = 0
    private var altSavedRow: Int = 0
    private var altSavedCol: Int = 0
    private var inAltScreen: Boolean = false

    private var scrollTop: Int = 0
    private var scrollBottom: Int = rows - 1
    private var pendingWrap: Boolean = false

    private var curFg: Int = DEFAULT_FG
    private var curBg: Int = DEFAULT_BG
    private var curBold: Boolean = false
    private var curInverse: Boolean = false

    private enum class ParseState { GROUND, ESC, CSI, OSC, OSC_ESC, CHARSET }
    private var state: ParseState = ParseState.GROUND
    private val csiBuf = StringBuilder()

    // UTF-8 byte decoder state
    private val utf8Buf = ByteArray(4)
    private var utf8Len = 0
    private var utf8Expected = 0

    @Volatile
    var onScreenChanged: (() -> Unit)? = null

    fun resize(newCols: Int, newRows: Int): Boolean {
        val c = newCols.coerceIn(20, 240)
        val r = newRows.coerceIn(6, 120)
        var changed = false
        synchronized(lock) {
            if (c == cols && r == rows) return false
            val newGrid = createGrid(r, c)
            val copyRows = min(rows, r)
            val copyCols = min(cols, c)
            for (row in 0 until copyRows) {
                for (col in 0 until copyCols) {
                    val src = grid[row][col]
                    newGrid[row][col] = Cell(src.ch, src.fg, src.bg, src.bold, src.inverse)
                }
            }
            grid = newGrid
            if (altGrid != null) {
                altGrid = createGrid(r, c)
            }
            cols = c
            rows = r
            scrollTop = 0
            scrollBottom = r - 1
            cursorRow = cursorRow.coerceIn(0, r - 1)
            cursorCol = cursorCol.coerceIn(0, c - 1)
            pendingWrap = false
            changed = true
        }
        if (changed) onScreenChanged?.invoke()
        return changed
    }

    fun clearAll() {
        synchronized(lock) {
            grid = createGrid(rows, cols)
            scrollback.clear()
            cursorRow = 0
            cursorCol = 0
            pendingWrap = false
        }
        onScreenChanged?.invoke()
    }

    fun feed(bytes: ByteArray, length: Int = bytes.size) {
        synchronized(lock) {
            for (i in 0 until length) {
                val b = bytes[i].toInt() and 0xFF
                if (utf8Expected > 0) {
                    if ((b and 0xC0) == 0x80) {
                        utf8Buf[utf8Len++] = b.toByte()
                        if (utf8Len == utf8Expected) {
                            val s = String(utf8Buf, 0, utf8Len, Charsets.UTF_8)
                            utf8Len = 0
                            utf8Expected = 0
                            for (ch in s) processChar(ch)
                        }
                        continue
                    } else {
                        utf8Len = 0
                        utf8Expected = 0
                    }
                }
                when {
                    b < 0x80 -> processChar(b.toChar())
                    (b and 0xE0) == 0xC0 -> {
                        utf8Buf[0] = b.toByte(); utf8Len = 1; utf8Expected = 2
                    }
                    (b and 0xF0) == 0xE0 -> {
                        utf8Buf[0] = b.toByte(); utf8Len = 1; utf8Expected = 3
                    }
                    (b and 0xF8) == 0xF0 -> {
                        utf8Buf[0] = b.toByte(); utf8Len = 1; utf8Expected = 4
                    }
                }
            }
        }
        onScreenChanged?.invoke()
    }

    data class Snapshot(
        val cols: Int,
        val rows: Int,
        val lines: List<Array<Cell>>,
        val scrollbackSize: Int,
        val cursorRow: Int,
        val cursorCol: Int
    )

    fun snapshot(): Snapshot = synchronized(lock) {
        val total = ArrayList<Array<Cell>>(scrollback.size + rows)
        if (!inAltScreen) {
            for (line in scrollback) total.add(line)
        }
        for (r in 0 until rows) {
            total.add(Array(cols) { c ->
                val cell = grid[r][c]
                Cell(cell.ch, cell.fg, cell.bg, cell.bold, cell.inverse)
            })
        }
        Snapshot(
            cols = cols,
            rows = rows,
            lines = total,
            scrollbackSize = if (inAltScreen) 0 else scrollback.size,
            cursorRow = cursorRow,
            cursorCol = cursorCol
        )
    }

    private fun processChar(ch: Char) {
        when (state) {
            ParseState.GROUND -> handleGround(ch)
            ParseState.ESC -> handleEsc(ch)
            ParseState.CSI -> handleCsi(ch)
            ParseState.OSC -> {
                if (ch == '\u0007') state = ParseState.GROUND
                else if (ch == '\u001B') state = ParseState.OSC_ESC
            }
            ParseState.OSC_ESC -> {
                state = if (ch == '\\') ParseState.GROUND else ParseState.OSC
            }
            ParseState.CHARSET -> {
                state = ParseState.GROUND
            }
        }
    }

    private fun handleGround(ch: Char) {
        when (ch) {
            '\u001B' -> state = ParseState.ESC
            '\r' -> {
                cursorCol = 0
                pendingWrap = false
            }
            '\n', '\u000B', '\u000C' -> {
                pendingWrap = false
                lineFeed()
            }
            '\b' -> {
                pendingWrap = false
                if (cursorCol > 0) cursorCol--
            }
            '\t' -> {
                pendingWrap = false
                val nextStop = ((cursorCol / 8) + 1) * 8
                cursorCol = min(nextStop, cols - 1)
            }
            '\u0007', '\u0000', '\u000E', '\u000F' -> Unit
            else -> {
                if (ch.code >= 0x20) putChar(ch)
            }
        }
    }

    private fun handleEsc(ch: Char) {
        when (ch) {
            '[' -> {
                csiBuf.clear()
                state = ParseState.CSI
            }
            ']' -> state = ParseState.OSC
            '(', ')', '*', '+' -> state = ParseState.CHARSET
            '7' -> {
                savedRow = cursorRow; savedCol = cursorCol; state = ParseState.GROUND
            }
            '8' -> {
                cursorRow = savedRow.coerceIn(0, rows - 1)
                cursorCol = savedCol.coerceIn(0, cols - 1)
                pendingWrap = false
                state = ParseState.GROUND
            }
            'M' -> {
                pendingWrap = false
                reverseIndex()
                state = ParseState.GROUND
            }
            'D' -> {
                pendingWrap = false
                lineFeed()
                state = ParseState.GROUND
            }
            'E' -> {
                pendingWrap = false
                cursorCol = 0
                lineFeed()
                state = ParseState.GROUND
            }
            'c' -> {
                resetState()
                state = ParseState.GROUND
            }
            else -> state = ParseState.GROUND
        }
    }

    private fun handleCsi(ch: Char) {
        if (ch.code in 0x40..0x7E) {
            dispatchCsi(csiBuf.toString(), ch)
            state = ParseState.GROUND
        } else {
            if (csiBuf.length < 64) csiBuf.append(ch)
        }
    }

    private fun dispatchCsi(rawParams: String, cmd: Char) {
        val isPrivate = rawParams.startsWith("?")
        val clean = if (isPrivate || rawParams.startsWith(">") || rawParams.startsWith("!")) {
            rawParams.substring(1)
        } else {
            rawParams
        }
        val params = if (clean.isEmpty()) emptyList() else clean.split(";").map { it.toIntOrNull() ?: 0 }
        fun p(idx: Int, default: Int): Int = params.getOrNull(idx)?.takeIf { it > 0 } ?: default
        fun pZero(idx: Int): Int = params.getOrNull(idx) ?: 0

        if (isPrivate) {
            if (cmd == 'h' || cmd == 'l') {
                val enable = (cmd == 'h')
                for (mode in params) {
                    if (mode == 1049 || mode == 47 || mode == 1047) {
                        setAltScreen(enable)
                    }
                }
            }
            return
        }

        when (cmd) {
            'A' -> { pendingWrap = false; cursorRow = max(scrollTop, cursorRow - p(0, 1)) }
            'B' -> { pendingWrap = false; cursorRow = min(scrollBottom, cursorRow + p(0, 1)) }
            'C' -> { pendingWrap = false; cursorCol = min(cols - 1, cursorCol + p(0, 1)) }
            'D' -> { pendingWrap = false; cursorCol = max(0, cursorCol - p(0, 1)) }
            'E' -> { pendingWrap = false; cursorCol = 0; cursorRow = min(scrollBottom, cursorRow + p(0, 1)) }
            'F' -> { pendingWrap = false; cursorCol = 0; cursorRow = max(scrollTop, cursorRow - p(0, 1)) }
            'G', '`' -> { pendingWrap = false; cursorCol = (p(0, 1) - 1).coerceIn(0, cols - 1) }
            'd' -> { pendingWrap = false; cursorRow = (p(0, 1) - 1).coerceIn(0, rows - 1) }
            'H', 'f' -> {
                pendingWrap = false
                cursorRow = (p(0, 1) - 1).coerceIn(0, rows - 1)
                cursorCol = (p(1, 1) - 1).coerceIn(0, cols - 1)
            }
            'J' -> eraseDisplay(pZero(0))
            'K' -> eraseLine(pZero(0))
            'X' -> {
                val n = p(0, 1)
                for (c in cursorCol until min(cols, cursorCol + n)) clearCell(grid[cursorRow][c])
            }
            'P' -> { // Delete characters
                val n = p(0, 1)
                val line = grid[cursorRow]
                for (c in cursorCol until cols) {
                    val src = c + n
                    if (src < cols) copyCell(line[src], line[c]) else clearCell(line[c])
                }
            }
            '@' -> { // Insert blank characters
                val n = p(0, 1)
                val line = grid[cursorRow]
                for (c in cols - 1 downTo cursorCol) {
                    val src = c - n
                    if (src >= cursorCol) copyCell(line[src], line[c]) else clearCell(line[c])
                }
            }
            'L' -> insertLines(p(0, 1))
            'M' -> deleteLines(p(0, 1))
            'S' -> repeat(p(0, 1)) { scrollUp(scrollTop, scrollBottom, saveToHistory = false) }
            'T' -> repeat(p(0, 1)) { scrollDown(scrollTop, scrollBottom) }
            'r' -> {
                val top = (p(0, 1) - 1).coerceIn(0, rows - 1)
                val bot = (p(1, rows) - 1).coerceIn(0, rows - 1)
                if (top < bot) {
                    scrollTop = top
                    scrollBottom = bot
                } else {
                    scrollTop = 0
                    scrollBottom = rows - 1
                }
                cursorRow = 0
                cursorCol = 0
                pendingWrap = false
            }
            's' -> { savedRow = cursorRow; savedCol = cursorCol }
            'u' -> {
                cursorRow = savedRow.coerceIn(0, rows - 1)
                cursorCol = savedCol.coerceIn(0, cols - 1)
                pendingWrap = false
            }
            'm' -> applySgr(if (params.isEmpty()) listOf(0) else params)
        }
    }

    private fun putChar(ch: Char) {
        if (pendingWrap) {
            pendingWrap = false
            cursorCol = 0
            lineFeed()
        }
        val cell = grid[cursorRow][cursorCol]
        cell.ch = ch
        cell.fg = curFg
        cell.bg = curBg
        cell.bold = curBold
        cell.inverse = curInverse

        if (cursorCol + 1 >= cols) {
            pendingWrap = true
        } else {
            cursorCol++
        }
    }

    private fun lineFeed() {
        if (cursorRow == scrollBottom) {
            scrollUp(scrollTop, scrollBottom, saveToHistory = (!inAltScreen && scrollTop == 0 && scrollBottom == rows - 1))
        } else if (cursorRow < rows - 1) {
            cursorRow++
        }
    }

    private fun reverseIndex() {
        if (cursorRow == scrollTop) {
            scrollDown(scrollTop, scrollBottom)
        } else if (cursorRow > 0) {
            cursorRow--
        }
    }

    private fun scrollUp(top: Int, bottom: Int, saveToHistory: Boolean) {
        if (saveToHistory) {
            scrollback.addLast(grid[top])
            if (scrollback.size > maxScrollback) scrollback.removeFirst()
        }
        for (r in top until bottom) {
            grid[r] = grid[r + 1]
        }
        grid[bottom] = createRow(cols)
    }

    private fun scrollDown(top: Int, bottom: Int) {
        for (r in bottom downTo top + 1) {
            grid[r] = grid[r - 1]
        }
        grid[top] = createRow(cols)
    }

    private fun insertLines(n: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        repeat(min(n, scrollBottom - cursorRow + 1)) {
            scrollDown(cursorRow, scrollBottom)
        }
    }

    private fun deleteLines(n: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        repeat(min(n, scrollBottom - cursorRow + 1)) {
            scrollUp(cursorRow, scrollBottom, saveToHistory = false)
        }
    }

    private fun eraseDisplay(mode: Int) {
        when (mode) {
            0 -> {
                eraseLine(0)
                for (r in cursorRow + 1 until rows) grid[r] = createRow(cols)
            }
            1 -> {
                for (r in 0 until cursorRow) grid[r] = createRow(cols)
                eraseLine(1)
            }
            2, 3 -> {
                for (r in 0 until rows) grid[r] = createRow(cols)
                if (mode == 3) scrollback.clear()
            }
        }
    }

    private fun eraseLine(mode: Int) {
        val line = grid[cursorRow]
        when (mode) {
            0 -> for (c in cursorCol until cols) clearCell(line[c])
            1 -> for (c in 0..cursorCol) clearCell(line[c])
            2 -> for (c in 0 until cols) clearCell(line[c])
        }
    }

    private fun setAltScreen(enable: Boolean) {
        if (enable && !inAltScreen) {
            altGrid = grid
            altSavedRow = cursorRow
            altSavedCol = cursorCol
            grid = createGrid(rows, cols)
            cursorRow = 0
            cursorCol = 0
            scrollTop = 0
            scrollBottom = rows - 1
            pendingWrap = false
            inAltScreen = true
        } else if (!enable && inAltScreen) {
            altGrid?.let { grid = it }
            altGrid = null
            cursorRow = altSavedRow.coerceIn(0, rows - 1)
            cursorCol = altSavedCol.coerceIn(0, cols - 1)
            scrollTop = 0
            scrollBottom = rows - 1
            pendingWrap = false
            inAltScreen = false
        }
    }

    private fun applySgr(params: List<Int>) {
        var i = 0
        while (i < params.size) {
            when (val code = params[i]) {
                0 -> { curFg = DEFAULT_FG; curBg = DEFAULT_BG; curBold = false; curInverse = false }
                1 -> curBold = true
                22 -> curBold = false
                7 -> curInverse = true
                27 -> curInverse = false
                in 30..37 -> curFg = ANSI_COLORS[code - 30]
                39 -> curFg = DEFAULT_FG
                in 40..47 -> curBg = ANSI_COLORS[code - 40]
                49 -> curBg = DEFAULT_BG
                in 90..97 -> curFg = ANSI_BRIGHT_COLORS[code - 90]
                in 100..107 -> curBg = ANSI_BRIGHT_COLORS[code - 100]
                38, 48 -> {
                    val isFg = (code == 38)
                    val mode = params.getOrNull(i + 1)
                    if (mode == 5 && i + 2 < params.size) {
                        val color = xterm256Color(params[i + 2])
                        if (isFg) curFg = color else curBg = color
                        i += 2
                    } else if (mode == 2 && i + 4 < params.size) {
                        val r = params[i + 2].coerceIn(0, 255)
                        val g = params[i + 3].coerceIn(0, 255)
                        val b = params[i + 4].coerceIn(0, 255)
                        val color = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                        if (isFg) curFg = color else curBg = color
                        i += 4
                    }
                }
            }
            i++
        }
    }

    private fun resetState() {
        grid = createGrid(rows, cols)
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
        curFg = DEFAULT_FG
        curBg = DEFAULT_BG
        curBold = false
        curInverse = false
        inAltScreen = false
        altGrid = null
    }

    private fun clearCell(c: Cell) {
        c.ch = ' '
        c.fg = curFg
        c.bg = curBg
        c.bold = false
        c.inverse = false
    }

    private fun copyCell(src: Cell, dst: Cell) {
        dst.ch = src.ch
        dst.fg = src.fg
        dst.bg = src.bg
        dst.bold = src.bold
        dst.inverse = src.inverse
    }

    private fun createRow(c: Int): Array<Cell> = Array(c) { Cell() }
    private fun createGrid(r: Int, c: Int): Array<Array<Cell>> = Array(r) { createRow(c) }

    companion object {
        const val DEFAULT_FG: Int = 0xFFDCE8F2.toInt()
        const val DEFAULT_BG: Int = 0xFF0A0F14.toInt()

        private val ANSI_COLORS = intArrayOf(
            0xFF1C252E.toInt(), // black
            0xFFE06C75.toInt(), // red
            0xFF98C379.toInt(), // green
            0xFFE5C07B.toInt(), // yellow
            0xFF61AFEF.toInt(), // blue
            0xFFC678DD.toInt(), // magenta
            0xFF56B6C2.toInt(), // cyan
            0xFFABB2BF.toInt()  // white
        )

        private val ANSI_BRIGHT_COLORS = intArrayOf(
            0xFF5C6370.toInt(),
            0xFFFF7B86.toInt(),
            0xFFB5E890.toInt(),
            0xFFFFD68A.toInt(),
            0xFF7CC4FF.toInt(),
            0xFFE091FF.toInt(),
            0xFF6CE5F0.toInt(),
            0xFFFFFFFF.toInt()
        )

        private fun xterm256Color(n: Int): Int {
            val idx = n.coerceIn(0, 255)
            return when {
                idx < 8 -> ANSI_COLORS[idx]
                idx < 16 -> ANSI_BRIGHT_COLORS[idx - 8]
                idx < 232 -> {
                    val v = idx - 16
                    val r = (v / 36) * 51
                    val g = ((v / 6) % 6) * 51
                    val b = (v % 6) * 51
                    (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                }
                else -> {
                    val gray = (idx - 232) * 10 + 8
                    (0xFF shl 24) or (gray shl 16) or (gray shl 8) or gray
                }
            }
        }
    }
}
