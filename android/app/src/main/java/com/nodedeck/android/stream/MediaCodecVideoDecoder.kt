package com.nodedeck.android.stream

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.view.Surface
import kotlin.concurrent.thread
import kotlin.math.roundToInt

data class StreamPerformanceStats(
    val codec: String = "HEVC (MediaCodec)",
    val resolution: String = "1920×1080",
    val videoAspectRatio: Float = 16f / 9f,
    val fps: Int = 0,
    val bitrateMbps: Double = 0.0,
    val hostLatencyMs: Double = 0.0,
    val networkRttMs: Int = 0,
    val networkJitterMs: Int = 0,
    val rendererStatus: String = "Ready"
)

class MediaCodecVideoDecoder(
    private val onStatsUpdate: (StreamPerformanceStats) -> Unit
) {
    private val lock = Any()
    @Volatile private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var outputThread: Thread? = null
    @Volatile private var running = false

    private var videoFormatMask = 0
    private var videoWidth = 1920
    private var videoHeight = 1080
    private var targetFps = 60
    private var codecLabel = "HEVC (MediaCodec)"
    private var hasSubmittedIdr = false

    private var frameCounter = 0
    private var bytesCounter = 0L
    private var hostLatencySumMs = 0.0
    private var hostLatencyCount = 0
    private var lastStatsTimeMs = SystemClock.elapsedRealtime()

    fun attachSurface(newSurface: Surface?) {
        synchronized(lock) {
            surface = newSurface
            if (newSurface != null && videoWidth > 0 && videoHeight > 0 && videoFormatMask != 0 && codec == null) {
                startCodecLocked()
            } else if (newSurface == null) {
                stopCodecLocked()
            }
        }
    }

    fun setup(videoFormat: Int, width: Int, height: Int, redrawRate: Int): Int {
        synchronized(lock) {
            stopCodecLocked()
            videoFormatMask = videoFormat
            videoWidth = width.coerceAtLeast(16)
            videoHeight = height.coerceAtLeast(16)
            targetFps = redrawRate.coerceAtLeast(30)
            val isHevc = (videoFormat and MoonlightNative.VIDEO_FORMAT_MASK_H265) != 0
            codecLabel = if (isHevc) "HEVC (MediaCodec)" else "H.264 (MediaCodec)"
            hasSubmittedIdr = false
            frameCounter = 0
            bytesCounter = 0L
            hostLatencySumMs = 0.0
            hostLatencyCount = 0
            lastStatsTimeMs = SystemClock.elapsedRealtime()

            onStatsUpdate(
                StreamPerformanceStats(
                    codec = codecLabel,
                    resolution = "${videoWidth}×${videoHeight}",
                    videoAspectRatio = videoWidth.toFloat() / videoHeight.toFloat(),
                    rendererStatus = if (surface != null) "Initializing" else "Waiting Surface"
                )
            )
            if (surface != null) {
                startCodecLocked()
            }
        }
        return 0
    }

    private fun startCodecLocked() {
        val activeSurface = surface ?: return
        val mime = if ((videoFormatMask and MoonlightNative.VIDEO_FORMAT_MASK_H265) != 0) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }
        try {
            val mc = MediaCodec.createDecoderByType(mime)
            val format = MediaFormat.createVideoFormat(mime, videoWidth, videoHeight).apply {
                setInteger(MediaFormat.KEY_FRAME_RATE, targetFps)
                setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
                setInteger(MediaFormat.KEY_PRIORITY, 0) // Real-time priority
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
            }
            mc.configure(format, activeSurface, null, 0)
            mc.start()
            codec = mc
            hasSubmittedIdr = false
            running = true
            outputThread = thread(isDaemon = true, name = "nd-mediacodec-out") {
                drainOutputLoop(mc)
            }
        } catch (t: Throwable) {
            onStatsUpdate(
                StreamPerformanceStats(
                    codec = codecLabel,
                    resolution = "${videoWidth}×${videoHeight}",
                    videoAspectRatio = videoWidth.toFloat() / videoHeight.toFloat(),
                    rendererStatus = "Codec err: ${t.message?.take(40)}"
                )
            )
        }
    }

    private fun drainOutputLoop(mc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running) {
            try {
                val outIdx = mc.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    mc.releaseOutputBuffer(outIdx, true)
                }
            } catch (_: Throwable) {
                if (!running) break
                try {
                    Thread.sleep(5)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
    }

    fun submitDecodeUnit(data: ByteArray, frameType: Int, hostLatencyTenthsMs: Int, presentationTimeUs: Long): Int {
        val isIdr = frameType == MoonlightNative.FRAME_TYPE_IDR
        synchronized(lock) {
            val mc = codec
            if (mc == null) {
                if (surface != null && videoFormatMask != 0) {
                    startCodecLocked()
                }
                return MoonlightNative.DR_NEED_IDR
            }
            if (!isIdr && !hasSubmittedIdr) {
                return MoonlightNative.DR_NEED_IDR
            }

            try {
                val inIdx = mc.dequeueInputBuffer(15_000)
                if (inIdx < 0) {
                    return if (isIdr) MoonlightNative.DR_NEED_IDR else MoonlightNative.DR_OK
                }
                val buf = mc.getInputBuffer(inIdx) ?: return MoonlightNative.DR_NEED_IDR
                buf.clear()
                if (buf.capacity() < data.size) {
                    mc.queueInputBuffer(inIdx, 0, 0, presentationTimeUs, 0)
                    return MoonlightNative.DR_NEED_IDR
                }
                buf.put(data)
                val flags = if (isIdr) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                mc.queueInputBuffer(inIdx, 0, data.size, presentationTimeUs, flags)
                if (isIdr) hasSubmittedIdr = true

                frameCounter++
                bytesCounter += data.size
                if (hostLatencyTenthsMs > 0) {
                    hostLatencySumMs += hostLatencyTenthsMs / 10.0
                    hostLatencyCount++
                }

                val now = SystemClock.elapsedRealtime()
                val elapsedMs = now - lastStatsTimeMs
                if (elapsedMs >= 1000L) {
                    val elapsedSec = elapsedMs / 1000.0
                    val fps = (frameCounter / elapsedSec).roundToInt()
                    val mbps = (bytesCounter * 8.0) / (elapsedSec * 1_000_000.0)
                    val avgHostMs = if (hostLatencyCount > 0) hostLatencySumMs / hostLatencyCount else 0.0
                    val (rtt, jitter) = MoonlightNative.getEstimatedRtt()
                    frameCounter = 0
                    bytesCounter = 0L
                    hostLatencySumMs = 0.0
                    hostLatencyCount = 0
                    lastStatsTimeMs = now

                    onStatsUpdate(
                        StreamPerformanceStats(
                            codec = codecLabel,
                            resolution = "${videoWidth}×${videoHeight}",
                            videoAspectRatio = videoWidth.toFloat() / videoHeight.toFloat(),
                            fps = fps,
                            bitrateMbps = mbps,
                            hostLatencyMs = avgHostMs,
                            networkRttMs = rtt,
                            networkJitterMs = jitter,
                            rendererStatus = "Hardware"
                        )
                    )
                }
                return MoonlightNative.DR_OK
            } catch (_: Throwable) {
                hasSubmittedIdr = false
                stopCodecLocked()
                if (surface != null) startCodecLocked()
                return MoonlightNative.DR_NEED_IDR
            }
        }
    }

    fun cleanup() {
        synchronized(lock) {
            stopCodecLocked()
            videoFormatMask = 0
        }
    }

    private fun stopCodecLocked() {
        running = false
        val mc = codec
        codec = null
        hasSubmittedIdr = false
        outputThread?.interrupt()
        outputThread = null
        if (mc != null) {
            runCatching { mc.stop() }
            runCatching { mc.release() }
        }
    }
}
