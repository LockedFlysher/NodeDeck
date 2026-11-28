package com.nodedeck.android

import com.nodedeck.android.core.ControlPlaneClient
import com.nodedeck.android.core.RemoteMetricsParser
import com.nodedeck.android.core.SshConfigParser
import com.nodedeck.android.core.StreamQualityMath
import com.nodedeck.android.core.StreamRefreshRate
import com.nodedeck.android.core.StreamResolutionPreset
import com.nodedeck.android.stream.ViewportTransformState
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

    @Test
    fun testViewportTransformZoomPanAndInverseMapping() {
        val vp = ViewportTransformState()
        // Landscape phone 2400x1080 displaying 16:9 video (1920x1080) with black pillarbox margins
        vp.updateBounds(containerW = 2400f, containerH = 1080f, baseSurfaceW = 1920f, baseSurfaceH = 1080f)

        // At 1.0x, screen center maps to exact video center (960, 540)
        val (cx1, cy1) = vp.screenToVideo(1200f, 540f, 1920, 1080)
        assertEquals(960, cx1)
        assertEquals(540, cy1)

        // Zoom to 2.0x centered on top-left quadrant of video (x=720 -> local 480, y=270 -> local 270)
        vp.applyZoomAndPan(newScale = 2.0f, focalX = 720f, focalY = 270f, panDeltaX = 0f, panDeltaY = 0f)
        assertEquals(2.0f, vp.zoomScale, 0.001f)
        // Focal point on screen should still map to the same video coordinate (480, 270)
        val (fx, fy) = vp.screenToVideo(720f, 270f, 1920, 1080)
        assertEquals(480, fx)
        assertEquals(270, fy)

        // Pan clamping: cannot pan past zoomed surface edges
        vp.applyPanOnly(panDeltaX = 10_000f, panDeltaY = -10_000f)
        val maxPanX = (1920f * 2.0f - 2400f) / 2f // 720
        val maxPanY = (1080f * 2.0f - 1080f) / 2f // 540
        assertEquals(maxPanX, vp.panX, 0.01f)
        assertEquals(-maxPanY, vp.panY, 0.01f)

        // Snap near unity resets cleanly
        vp.setPresetScale(1.03f)
        vp.snapIfNearUnity()
        assertEquals(1.0f, vp.zoomScale, 0.001f)
        assertEquals(0f, vp.panX, 0.001f)
        assertEquals(0f, vp.panY, 0.001f)
    }

    @Test
    fun testControlPlaneActivateAndCommandStatusJson() {
        val client = ControlPlaneClient()
        val actJson = """
            {
              "ok": true,
              "command_id": 42,
              "status": "pending",
              "target_device": {
                "device_id": "linux-box-1",
                "device_name": "ubuntu-desktop",
                "platform": "linux",
                "role": "both",
                "virtual_ip": "10.66.0.12",
                "sunshine_http_port": 47989,
                "sunshine_https_port": 47984,
                "sunshine_enabled": false,
                "online": true
              }
            }
        """.trimIndent()
        val act = client.decodeActivateResponse(actJson)
        assertTrue(act.ok)
        assertEquals(42, act.commandId)
        assertEquals("pending", act.status)
        assertEquals("10.66.0.12", act.targetDevice.virtualIp)
        assertEquals(47989, act.targetDevice.sunshineHttpPort)

        val statusJson = """
            {
              "id": 42,
              "target_device_id": "linux-box-1",
              "action": "activate_host",
              "status": "done",
              "result": {
                "sunshine_enabled": true,
                "sunshine_http_port": 48089,
                "sunshine_https_port": 48084
              },
              "updated_at": 1764300000
            }
        """.trimIndent()
        val st = client.decodeCommandStatus(statusJson)
        assertEquals(42, st.id)
        assertEquals("done", st.status)
        assertEquals(true, st.result.sunshineEnabled)
        assertEquals(48089, st.result.sunshineHttpPort)
        assertEquals(48084, st.result.sunshineHttpsPort)
    }
}
