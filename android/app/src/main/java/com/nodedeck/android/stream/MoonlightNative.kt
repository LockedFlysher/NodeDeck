package com.nodedeck.android.stream

import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

interface MoonlightCallbackListener {
    fun onVideoSetup(videoFormat: Int, width: Int, height: Int, redrawRate: Int): Int
    fun onVideoCleanup()
    fun onSubmitDecodeUnit(data: ByteArray, frameType: Int, hostLatencyTenthsMs: Int, presentationTimeUs: Long): Int
    fun onAudioInit(sampleRate: Int, channelCount: Int, samplesPerFrame: Int): Int
    fun onAudioDecodeAndPlay(data: ByteArray)
    fun onAudioCleanup()
    fun onStageStarting(stageName: String)
    fun onStageFailed(stageName: String, errorCode: Int)
    fun onConnectionStarted()
    fun onConnectionTerminated(errorCode: Int)
}

object MoonlightNative {
    const val DR_OK = 0
    const val DR_NEED_IDR = -1

    const val FRAME_TYPE_IDR = 1

    const val VIDEO_FORMAT_MASK_H265 = 0xFF00

    const val BUTTON_ACTION_PRESS: Byte = 0x07
    const val BUTTON_ACTION_RELEASE: Byte = 0x08
    const val BUTTON_LEFT = 0x01
    const val BUTTON_MIDDLE = 0x02
    const val BUTTON_RIGHT = 0x03

    const val KEY_ACTION_DOWN: Byte = 0x03
    const val KEY_ACTION_UP: Byte = 0x04
    const val MODIFIER_SHIFT: Byte = 0x01
    const val MODIFIER_CTRL: Byte = 0x02
    const val MODIFIER_ALT: Byte = 0x04
    const val MODIFIER_META: Byte = 0x08
    const val MODIFIER_EXTENDED: Byte = 0x10

    init {
        System.loadLibrary("nodedeck_moonlight")
    }

    private val lifecycleExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "nd-limelight-lifecycle").apply { isDaemon = true }
    }
    private val inputLock = ReentrantLock()
    @Volatile private var inputAllowed = false
    private var hasActiveConnection = false // lifecycleExecutor thread only
    private val generationCounter = AtomicLong(0L)

    @Volatile private var activeListener: MoonlightCallbackListener? = null
    @Volatile private var activeGeneration: Long = 0L

    fun nextGeneration(): Long = generationCounter.incrementAndGet()
    fun isCurrent(gen: Long): Boolean = generationCounter.get() == gen

    fun interruptAndDisableInput() {
        inputLock.withLock { inputAllowed = false }
        nativeInterruptConnection()
    }

    fun sendInput(block: () -> Unit) {
        inputLock.withLock {
            if (!inputAllowed) return
            block()
        }
    }

    fun releaseAllRemoteModifiers() {
        val mods = listOf(
            0xA0 to false, 0xA1 to true,
            0xA2 to false, 0xA3 to true,
            0xA4 to false, 0xA5 to true,
            0x5B to true, 0x5C to true
        )
        sendInput {
            for ((vk, ext) in mods) {
                val encoded = (0x8000 or (vk and 0xFF)).toShort()
                val flags: Byte = if (ext) MODIFIER_EXTENDED else 0
                nativeSendKeyboardEvent2(encoded, KEY_ACTION_UP, flags, 0)
            }
            nativeSendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
            nativeSendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT)
            nativeSendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_MIDDLE)
        }
    }

    fun stopConnectionBlocking() {
        interruptAndDisableInput()
        lifecycleExecutor.submit {
            inputLock.withLock { inputAllowed = false }
            if (hasActiveConnection) {
                nativeStopConnection()
                hasActiveConnection = false
            }
            activeListener = null
        }.get()
    }

    fun startConnectionBlocking(
        generation: Long,
        listener: MoonlightCallbackListener,
        address: String,
        appVersion: String,
        gfeVersion: String,
        rtspUrl: String,
        serverCodecModeSupport: Int,
        width: Int,
        height: Int,
        fps: Int,
        bitrateKbps: Int,
        rikey: ByteArray,
        rikeyId: Int,
        enableHevc: Boolean
    ): Int? {
        return lifecycleExecutor.submit<Int?> {
            inputLock.withLock { inputAllowed = false }
            if (hasActiveConnection) {
                nativeStopConnection()
                hasActiveConnection = false
            }
            if (!isCurrent(generation)) return@submit null

            activeGeneration = generation
            activeListener = listener
            hasActiveConnection = true

            val rc = nativeStartConnection(
                address, appVersion, gfeVersion, rtspUrl,
                serverCodecModeSupport, width, height, fps, bitrateKbps,
                rikey, rikeyId, enableHevc
            )
            if (rc == 0) {
                if (isCurrent(generation)) {
                    inputLock.withLock { inputAllowed = true }
                    releaseAllRemoteModifiers()
                    0
                } else {
                    inputLock.withLock { inputAllowed = false }
                    nativeStopConnection()
                    hasActiveConnection = false
                    null
                }
            } else {
                inputLock.withLock { inputAllowed = false }
                hasActiveConnection = false
                rc
            }
        }.get()
    }

    fun getEstimatedRtt(): Pair<Int, Int> {
        val packed = nativeGetEstimatedRttPacked()
        val rtt = (packed ushr 32).toInt()
        val jitter = (packed and 0xFFFFFFFFL).toInt()
        return rtt to jitter
    }

    fun sendMouseMove(dx: Int, dy: Int) = sendInput {
        nativeSendMouseMove(
            dx.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort(),
            dy.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        )
    }

    fun sendMousePosition(x: Int, y: Int, w: Int, h: Int) = sendInput {
        nativeSendMousePosition(
            x.coerceIn(0, Short.MAX_VALUE.toInt()).toShort(),
            y.coerceIn(0, Short.MAX_VALUE.toInt()).toShort(),
            w.coerceIn(1, Short.MAX_VALUE.toInt()).toShort(),
            h.coerceIn(1, Short.MAX_VALUE.toInt()).toShort()
        )
    }

    fun sendMouseButton(pressed: Boolean, button: Int) = sendInput {
        nativeSendMouseButton(if (pressed) BUTTON_ACTION_PRESS else BUTTON_ACTION_RELEASE, button)
    }

    fun sendScroll(amount: Int) = sendInput {
        nativeSendHighResScroll(amount.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
    }

    fun sendHScroll(amount: Int) = sendInput {
        nativeSendHighResHScroll(amount.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
    }

    fun sendVirtualKey(vk: Int, down: Boolean, extended: Boolean = false, modifiers: Byte = 0) = sendInput {
        val mods = if (extended) (modifiers.toInt() or MODIFIER_EXTENDED.toInt()).toByte() else modifiers
        val encoded = (0x8000 or (vk and 0xFF)).toShort()
        nativeSendKeyboardEvent2(encoded, if (down) KEY_ACTION_DOWN else KEY_ACTION_UP, mods, 0)
    }

    fun sendUtf8Text(text: String) = sendInput {
        if (text.isNotEmpty()) nativeSendUtf8Text(text)
    }

    // MARK: - JNI Native Methods

    @JvmStatic private external fun nativeStartConnection(
        address: String,
        appVersion: String,
        gfeVersion: String,
        rtspUrl: String,
        serverCodecModeSupport: Int,
        width: Int,
        height: Int,
        fps: Int,
        bitrateKbps: Int,
        rikey: ByteArray,
        rikeyId: Int,
        enableHevc: Boolean
    ): Int

    @JvmStatic private external fun nativeStopConnection()
    @JvmStatic private external fun nativeInterruptConnection()
    @JvmStatic private external fun nativeGetEstimatedRttPacked(): Long
    @JvmStatic private external fun nativeSendMouseMove(dx: Short, dy: Short): Int
    @JvmStatic private external fun nativeSendMousePosition(x: Short, y: Short, w: Short, h: Short): Int
    @JvmStatic private external fun nativeSendMouseButton(action: Byte, button: Int): Int
    @JvmStatic private external fun nativeSendHighResScroll(amount: Short): Int
    @JvmStatic private external fun nativeSendHighResHScroll(amount: Short): Int
    @JvmStatic private external fun nativeSendKeyboardEvent2(keyCode: Short, keyAction: Byte, modifiers: Byte, flags: Byte): Int
    @JvmStatic private external fun nativeSendUtf8Text(text: String): Int

    // MARK: - JNI Callbacks (invoked from C threads)

    @JvmStatic fun onVideoSetup(videoFormat: Int, width: Int, height: Int, redrawRate: Int): Int =
        activeListener?.onVideoSetup(videoFormat, width, height, redrawRate) ?: 0

    @JvmStatic fun onVideoCleanup() {
        activeListener?.onVideoCleanup()
    }

    @JvmStatic fun onSubmitDecodeUnit(data: ByteArray, frameType: Int, hostLatencyTenthsMs: Int, presentationTimeUs: Long): Int =
        activeListener?.onSubmitDecodeUnit(data, frameType, hostLatencyTenthsMs, presentationTimeUs) ?: DR_OK

    @JvmStatic fun onAudioInit(sampleRate: Int, channelCount: Int, samplesPerFrame: Int): Int =
        activeListener?.onAudioInit(sampleRate, channelCount, samplesPerFrame) ?: 0

    @JvmStatic fun onAudioDecodeAndPlay(data: ByteArray) {
        activeListener?.onAudioDecodeAndPlay(data)
    }

    @JvmStatic fun onAudioCleanup() {
        activeListener?.onAudioCleanup()
    }

    @JvmStatic fun onStageStarting(stageName: String) {
        if (!isCurrent(activeGeneration)) return
        activeListener?.onStageStarting(stageName)
    }

    @JvmStatic fun onStageFailed(stageName: String, errorCode: Int) {
        if (!isCurrent(activeGeneration)) return
        activeListener?.onStageFailed(stageName, errorCode)
    }

    @JvmStatic fun onConnectionStarted() {
        if (!isCurrent(activeGeneration)) return
        activeListener?.onConnectionStarted()
    }

    @JvmStatic fun onConnectionTerminated(errorCode: Int) {
        inputLock.withLock { inputAllowed = false }
        if (!isCurrent(activeGeneration)) return
        activeListener?.onConnectionTerminated(errorCode)
    }
}
