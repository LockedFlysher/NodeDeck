package com.nodedeck.android.stream

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class OpusAudioPlayer {
    private val lock = Any()
    private var codec: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var outputThread: Thread? = null
    @Volatile private var running = false
    @Volatile private var muted = false
    private var ptsUs = 0L

    fun setMuted(muted: Boolean) {
        this.muted = muted
        synchronized(lock) {
            runCatching { audioTrack?.setVolume(if (muted) 0f else 1f) }
        }
    }

    fun init(sampleRate: Int, channelCount: Int, samplesPerFrame: Int): Int {
        synchronized(lock) {
            cleanupLocked()
            val sr = sampleRate.coerceAtLeast(8000)
            val ch = channelCount.coerceIn(1, 2)
            try {
                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, sr, ch)
                format.setByteBuffer("csd-0", buildOpusHead(sr, ch))
                format.setByteBuffer("csd-1", longLittleEndianBuffer(0L))
                format.setByteBuffer("csd-2", longLittleEndianBuffer(80_000_000L))

                val mc = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
                mc.configure(format, null, null, 0)
                mc.start()

                val chMask = if (ch == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                val minBuf = AudioTrack.getMinBufferSize(sr, chMask, AudioFormat.ENCODING_PCM_16BIT)
                    .coerceAtLeast(samplesPerFrame * ch * 2 * 4)
                val trackBuilder = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sr)
                            .setChannelMask(chMask)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build()
                    )
                    .setBufferSizeInBytes(minBuf)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    trackBuilder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                }
                val track = trackBuilder.build()
                track.setVolume(if (muted) 0f else 1f)
                track.play()

                codec = mc
                audioTrack = track
                ptsUs = 0L
                running = true
                outputThread = thread(isDaemon = true, name = "nd-opus-out") {
                    drainAudioLoop(mc, track)
                }
                return 0
            } catch (_: Throwable) {
                cleanupLocked()
                return -1
            }
        }
    }

    fun decodeAndPlay(packet: ByteArray) {
        synchronized(lock) {
            val mc = codec ?: return
            if (!running) return
            try {
                val idx = mc.dequeueInputBuffer(5_000)
                if (idx >= 0) {
                    val buf = mc.getInputBuffer(idx) ?: return
                    buf.clear()
                    if (buf.capacity() >= packet.size) {
                        buf.put(packet)
                        mc.queueInputBuffer(idx, 0, packet.size, ptsUs, 0)
                        ptsUs += 5_000L
                    }
                }
            } catch (_: Throwable) {
                // Ignore transient packet errors
            }
        }
    }

    private fun drainAudioLoop(mc: MediaCodec, track: AudioTrack) {
        val info = MediaCodec.BufferInfo()
        val scratch = ByteArray(16384)
        while (running) {
            try {
                val outIdx = mc.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    val outBuf = mc.getOutputBuffer(outIdx)
                    if (outBuf != null && info.size > 0) {
                        outBuf.position(info.offset)
                        var remaining = info.size
                        while (remaining > 0 && running) {
                            val chunk = minOf(remaining, scratch.size)
                            outBuf.get(scratch, 0, chunk)
                            track.write(scratch, 0, chunk)
                            remaining -= chunk
                        }
                    }
                    mc.releaseOutputBuffer(outIdx, false)
                }
            } catch (_: Throwable) {
                if (!running) break
            }
        }
    }

    fun cleanup() {
        synchronized(lock) { cleanupLocked() }
    }

    private fun cleanupLocked() {
        running = false
        outputThread?.interrupt()
        outputThread = null
        val mc = codec
        codec = null
        val tr = audioTrack
        audioTrack = null
        if (mc != null) {
            runCatching { mc.stop() }
            runCatching { mc.release() }
        }
        if (tr != null) {
            runCatching { tr.stop() }
            runCatching { tr.release() }
        }
    }

    private fun buildOpusHead(sampleRate: Int, channels: Int): ByteBuffer {
        val bb = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
        bb.put("OpusHead".toByteArray(Charsets.US_ASCII))
        bb.put(1) // Version
        bb.put(channels.toByte())
        bb.putShort(0) // Pre-skip
        bb.putInt(sampleRate)
        bb.putShort(0) // Output gain
        bb.put(0) // Channel mapping family 0 (mono/stereo)
        bb.flip()
        return bb
    }

    private fun longLittleEndianBuffer(value: Long): ByteBuffer {
        val bb = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        bb.putLong(value)
        bb.flip()
        return bb
    }
}
