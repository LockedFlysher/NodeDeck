package com.nodedeck.android

import com.nodedeck.android.core.RemoteMetricsParser
import com.nodedeck.android.core.SshConfigParser
import com.nodedeck.android.core.StreamQualityMath
import com.nodedeck.android.core.StreamRefreshRate
import com.nodedeck.android.core.StreamResolutionPreset
import com.nodedeck.android.ui.Vt100Emulator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NodeDeckCoreTest {

    @Test
    fun testStreamRefreshRatesAndBitrateScaling() {
        assertEquals(listOf(60, 120, 144, 165), StreamRefreshRate.entries.map { it.fps })
        assertEquals(16500, StreamRefreshRate.HZ_165.clientRefreshRateX100)

        val b1080p60 = StreamQualityMath.recommendedBitrateKbps(1920, 1080, 60)
        val b1080p165 = StreamQualityMath.recommendedBitrateKbps(1920, 1080, 165)
        val b4k165 = StreamQualityMath.recommendedBitrateKbps(3840, 2160, 165)

        assertEquals(20_000, b1080p60)
        assertTrue(b1080p165 > b1080p60)
        assertTrue(b4k165 >= b1080p165)
        assertTrue(b4k165 <= 120_000)
        assertEquals(StreamResolutionPreset.UHD_4K, StreamResolutionPreset.fromDimensions(3840, 2160))
    }

    @Test
    fun testSshConfigParser() {
        val raw = """
            Host *
              ServerAliveInterval 60

            Host gpu-node
              HostName 192.0.2.50
              User ubuntu
              Port 2222

            Host cluster-node
              HostName 198.51.100.12
              User researcher
              ProxyJump gpu-node
        """.trimIndent()

        val hosts = SshConfigParser.parseHosts(raw)
        assertEquals(2, hosts.size)
        assertEquals("gpu-node", hosts[0].alias)
        assertEquals("192.0.2.50", hosts[0].hostName)
        assertEquals("ubuntu", hosts[0].user)
        assertEquals(2222, hosts[0].port)
        assertEquals("cluster-node", hosts[1].alias)
        assertEquals("gpu-node", hosts[1].proxyJumpAlias)
    }

    @Test
    fun testRemoteMetricsParser() {
        val sample = """
            NODEDECK_BEGIN
            HOSTNAME=lab-gpu-01
            OS=Ubuntu 24.04.1 LTS
            KERNEL=6.8.0-45-generic
            ARCH=x86_64
            USER=ubuntu
            HOME_DIR=/home/ubuntu
            CANDIDATE_DIR=/home/ubuntu/workspace
            CPU_MODEL=Example CPU 32-Core
            CPU_CORES=32
            CPU_USAGE=18.5
            LOAD1=1.20
            LOAD5=0.95
            LOAD15=0.80
            UPTIME_SECONDS=86400
            MEM_TOTAL=137438953472
            MEM_AVAILABLE=100000000000
            SWAP_TOTAL=8589934592
            SWAP_FREE=8589934592
            DISK_TOTAL=2000000000000
            DISK_USED=500000000000
            DISK_AVAILABLE=1500000000000
            GPU=NVIDIA Example GPU, 42, 8192, 32768, 54, 210.5, active
            PROC=python3|120.5|14.2
            SCRIPT_MS=215
            NODEDECK_END
        """.trimIndent()

        val parsed = RemoteMetricsParser.parse(sample)
        assertNotNull(parsed)
        requireNotNull(parsed)
        assertEquals("lab-gpu-01", parsed.hostname)
        assertEquals(32, parsed.cpuCores)
        assertEquals(18.5, parsed.cpuUsage, 0.01)
        assertEquals(1, parsed.gpus.size)
        assertEquals("NVIDIA Example GPU", parsed.gpus[0].name)
        assertEquals(42.0, parsed.gpus[0].utilization ?: 0.0, 0.01)
        assertEquals(1, parsed.processes.size)
        assertEquals("python3", parsed.processes[0].command)
        assertEquals(listOf("/home/ubuntu/workspace"), parsed.candidateDirectories)
    }

    @Test
    fun testVt100EmulatorBackspaceAndEraseLine() {
        val emu = Vt100Emulator(initialCols = 40, initialRows = 10)
        emu.feed("hello world\b\b\b\b\b\u001B[Knodedeck".toByteArray(Charsets.UTF_8))
        val snap = emu.snapshot()
        val line0 = snap.lines[0].map { it.ch }.joinToString("").trimEnd()
        assertEquals("hello nodedeck", line0)
        assertEquals(0, snap.cursorRow)
        assertEquals(14, snap.cursorCol)
    }
}
