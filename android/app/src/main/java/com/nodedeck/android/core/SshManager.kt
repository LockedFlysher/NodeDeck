package com.nodedeck.android.core

import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import com.jcraft.jsch.Session
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

data class SshExecResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String
)

data class RemoteFileEntry(
    val name: String,
    val fullPath: String,
    val isDirectory: Boolean,
    val sizeBytes: Long,
    val modifiedEpochSec: Long,
    val permissions: String
)

class InteractiveShellHandle(
    private val sessionChain: List<Session>,
    private val channel: ChannelShell,
    val inputStream: InputStream,
    val outputStream: OutputStream
) {
    fun resize(cols: Int, rows: Int) {
        runCatching { channel.setPtySize(cols, rows, cols * 8, rows * 16) }
    }

    fun isConnected(): Boolean = channel.isConnected && sessionChain.lastOrNull()?.isConnected == true

    fun close() {
        runCatching { channel.disconnect() }
        sessionChain.asReversed().forEach { runCatching { it.disconnect() } }
    }
}

class SshManager(private val store: SecureStore) {
    private val activeForwards = ConcurrentHashMap<String, ActiveForwardHandle>()

    private class ActiveForwardHandle(
        val sessionChain: List<Session>,
        val socksServer: ServerSocket? = null
    ) {
        @Volatile var stopped = false
        fun stop() {
            stopped = true
            runCatching { socksServer?.close() }
            sessionChain.asReversed().forEach { runCatching { it.disconnect() } }
        }
    }

    fun isForwardActive(id: String): Boolean {
        val h = activeForwards[id] ?: return false
        return !h.stopped && (h.sessionChain.lastOrNull()?.isConnected == true)
    }

    fun activeForwardIds(): Set<String> =
        activeForwards.entries.filter { isForwardActive(it.key) }.map { it.key }.toSet()

    /**
     * Ensures Android has a local SSH keypair in app-private storage (generating a new Ed25519 keypair
     * on first launch if none exists) and returns its single-line OpenSSH public key for account mesh exchange.
     */
    fun ensureLocalSshPublicKey(comment: String = "nodedeck-android"): String? {
        val jsch = JSch()
        for (name in listOf("id_ed25519", "id_rsa")) {
            val pem = store.readPrivateKey(name) ?: continue
            val pub = runCatching {
                val kp = KeyPair.load(jsch, pem.toByteArray(Charsets.UTF_8), null)
                try {
                    val out = ByteArrayOutputStream()
                    kp.writePublicKey(out, comment)
                    out.toString("UTF-8").trim()
                } finally {
                    kp.dispose()
                }
            }.getOrNull()
            if (!pub.isNullOrBlank() && (pub.startsWith("ssh-ed25519 ") || pub.startsWith("ssh-rsa ") || pub.startsWith("ecdsa-sha2-"))) {
                return pub
            }
        }
        return runCatching {
            val kp = KeyPair.genKeyPair(jsch, KeyPair.ED25519)
            try {
                val privOut = ByteArrayOutputStream()
                val pubOut = ByteArrayOutputStream()
                kp.writePrivateKey(privOut)
                kp.writePublicKey(pubOut, comment)
                store.savePrivateKey("id_ed25519", privOut.toString("UTF-8"))
                pubOut.toString("UTF-8").trim()
            } finally {
                kp.dispose()
            }
        }.getOrNull()
    }

    private fun openSessionChain(
        host: SSHHost,
        allHosts: List<SSHHost>,
        timeoutMs: Int = 8_000,
        visited: MutableSet<String> = mutableSetOf()
    ): List<Session> {
        require(visited.add(host.alias.lowercase())) { "ProxyJump cycle detected at ${host.alias}" }

        val jsch = JSch()
        val sessions = mutableListOf<Session>()

        var targetHost = host.hostName
        var targetPort = host.port

        if (host.proxyJumpAlias.isNotBlank()) {
            val jumpHost = allHosts.firstOrNull {
                it.alias.equals(host.proxyJumpAlias, ignoreCase = true)
            } ?: throw IllegalStateException("ProxyJump host '${host.proxyJumpAlias}' not found")
            val jumpChain = openSessionChain(jumpHost, allHosts, timeoutMs, visited)
            sessions.addAll(jumpChain)
            val jumpSession = jumpChain.last()
            val localForwardedPort = jumpSession.setPortForwardingL("127.0.0.1", 0, host.hostName, host.port)
            targetHost = "127.0.0.1"
            targetPort = localForwardedPort
        }

        try {
            var loadedKey = false
            if (host.authType == SSHAuthType.PRIVATE_KEY && host.privateKeyName.isNotBlank()) {
                val pem = store.readPrivateKey(host.privateKeyName)
                    ?: throw IllegalStateException("Private key '${host.privateKeyName}' not found")
                val passBytes = host.privateKeyPassphrase.takeIf { it.isNotEmpty() }?.toByteArray(Charsets.UTF_8)
                jsch.addIdentity(host.privateKeyName, pem.toByteArray(Charsets.UTF_8), null, passBytes)
                loadedKey = true
            } else if (host.password.isEmpty()) {
                // OpenSSH-style fallback: try standard saved private keys automatically
                for (defaultKey in listOf("id_ed25519", "id_rsa", "id_ecdsa")) {
                    val pem = store.readPrivateKey(defaultKey) ?: continue
                    runCatching {
                        jsch.addIdentity(defaultKey, pem.toByteArray(Charsets.UTF_8), null, null)
                        loadedKey = true
                    }
                }
            }

            val session = jsch.getSession(host.user.ifBlank { "root" }, targetHost, targetPort)
            if (host.authType == SSHAuthType.PASSWORD && host.password.isNotEmpty()) {
                session.setPassword(host.password)
            }

            val config = Properties().apply {
                put("StrictHostKeyChecking", "no")
                put(
                    "PreferredAuthentications",
                    if (loadedKey || host.authType == SSHAuthType.PRIVATE_KEY) {
                        "publickey,password,keyboard-interactive"
                    } else {
                        "password,keyboard-interactive,publickey"
                    }
                )
            }
            session.setConfig(config)
            session.serverAliveInterval = 15_000
            session.serverAliveCountMax = 2
            session.connect(timeoutMs)
            sessions.add(session)
            return sessions
        } catch (t: Throwable) {
            sessions.asReversed().forEach { runCatching { it.disconnect() } }
            throw t
        }
    }

    suspend fun exec(
        host: SSHHost,
        allHosts: List<SSHHost>,
        command: String,
        stdinText: String? = null,
        timeoutMs: Int = 14_000
    ): SshExecResult = withContext(Dispatchers.IO) {
        val chain = openSessionChain(host, allHosts, timeoutMs.coerceAtMost(8_000))
        val session = chain.last()
        var channel: ChannelExec? = null
        try {
            val outBuf = ByteArrayOutputStream()
            val errBuf = ByteArrayOutputStream()
            val ch = session.openChannel("exec") as ChannelExec
            channel = ch
            ch.setCommand(command)
            ch.setErrStream(errBuf)
            val remoteStdout = ch.inputStream
            val remoteStdin = if (stdinText != null) ch.outputStream else null
            ch.connect(timeoutMs.coerceAtMost(8_000))

            if (stdinText != null && remoteStdin != null) {
                remoteStdin.write(stdinText.toByteArray(Charsets.UTF_8))
                remoteStdin.flush()
                remoteStdin.close()
            }

            val buf = ByteArray(8192)
            val deadline = System.currentTimeMillis() + timeoutMs
            while (true) {
                while (remoteStdout.available() > 0) {
                    val n = remoteStdout.read(buf)
                    if (n <= 0) break
                    outBuf.write(buf, 0, n)
                }
                if (ch.isClosed) {
                    if (remoteStdout.available() > 0) continue
                    break
                }
                if (System.currentTimeMillis() > deadline) {
                    ch.disconnect()
                    throw IllegalStateException("SSH command timed out")
                }
                Thread.sleep(25)
            }
            SshExecResult(
                exitCode = ch.exitStatus,
                stdout = outBuf.toString("UTF-8"),
                stderr = errBuf.toString("UTF-8")
            )
        } finally {
            runCatching { channel?.disconnect() }
            chain.asReversed().forEach { runCatching { it.disconnect() } }
        }
    }

    private fun measureTcpRttMs(hostName: String, port: Int, timeoutMs: Int = 2_500): Double? {
        if (hostName.isBlank()) return null
        return runCatching {
            val addr = InetAddress.getByName(hostName)
            var best: Double? = null
            // Take 1 probe; if elevated (>120ms, e.g. cold NAT/VPN wakeup), take a 2nd warm probe
            val attempts = 2
            for (i in 0 until attempts) {
                val sock = Socket()
                try {
                    val t0 = System.nanoTime()
                    sock.connect(InetSocketAddress(addr, port.coerceIn(1, 65535)), timeoutMs)
                    val ms = ((System.nanoTime() - t0) / 1_000_000.0).coerceAtLeast(1.0)
                    best = if (best == null || ms < best!!) ms else best
                    if (ms <= 120.0) break
                } finally {
                    runCatching { sock.close() }
                }
            }
            best
        }.getOrNull()
    }

    suspend fun collectMetrics(host: SSHHost, allHosts: List<SSHHost>): Triple<HostMetrics?, Double, String?> =
        withContext(Dispatchers.IO) {
            val started = System.nanoTime()
            try {
                val res = exec(
                    host = host,
                    allHosts = allHosts,
                    command = "/bin/sh -s",
                    stdinText = RemoteMetricsParser.metricsScript,
                    timeoutMs = 15_000
                )
                val totalMs = (System.nanoTime() - started) / 1_000_000.0
                // Measure pure TCP SYN->SYN-ACK RTT AFTER exec succeeds so VPN/P2P route is already warm
                val warmTcpRtt = if (host.proxyJumpAlias.isBlank()) {
                    measureTcpRttMs(host.hostName, host.port)
                } else {
                    null
                }
                val parsed = RemoteMetricsParser.parse(res.stdout)
                if (parsed != null) {
                    val effectiveRtt = warmTcpRtt ?: (totalMs - (parsed.scriptDurationMs ?: 0.0)).coerceAtLeast(1.0)
                    Triple(parsed, effectiveRtt, null)
                } else {
                    val err = res.stderr.trim().ifBlank { "Exit ${res.exitCode}: metrics parse failed" }
                    Triple(null, warmTcpRtt ?: totalMs, err.take(180))
                }
            } catch (t: Throwable) {
                val totalMs = (System.nanoTime() - started) / 1_000_000.0
                Triple(null, totalMs, friendlyError(t))
            }
        }

    suspend fun openInteractiveShell(
        host: SSHHost,
        allHosts: List<SSHHost>,
        cols: Int = 80,
        rows: Int = 24
    ): InteractiveShellHandle = withContext(Dispatchers.IO) {
        val chain = openSessionChain(host, allHosts, 10_000)
        val session = chain.last()
        try {
            val channel = session.openChannel("shell") as ChannelShell
            channel.setPtyType("xterm-256color")
            channel.setPtySize(cols, rows, cols * 8, rows * 16)
            val input = channel.inputStream
            val output = channel.outputStream
            channel.connect(10_000)
            InteractiveShellHandle(chain, channel, input, output)
        } catch (t: Throwable) {
            chain.asReversed().forEach { runCatching { it.disconnect() } }
            throw t
        }
    }

    suspend fun listDirectory(
        host: SSHHost,
        allHosts: List<SSHHost>,
        path: String
    ): Pair<String, List<RemoteFileEntry>> = withContext(Dispatchers.IO) {
        val chain = openSessionChain(host, allHosts, 10_000)
        val session = chain.last()
        var sftp: ChannelSftp? = null
        try {
            sftp = session.openChannel("sftp") as ChannelSftp
            sftp.connect(10_000)
            val resolvedPath = if (path.isBlank() || path == "~") sftp.home else path
            @Suppress("UNCHECKED_CAST")
            val entries = (sftp.ls(resolvedPath) as java.util.Vector<ChannelSftp.LsEntry>)
                .filter { it.filename != "." && it.filename != ".." }
                .map { item ->
                    val full = if (resolvedPath.endsWith("/")) "$resolvedPath${item.filename}" else "$resolvedPath/${item.filename}"
                    RemoteFileEntry(
                        name = item.filename,
                        fullPath = full,
                        isDirectory = item.attrs.isDir,
                        sizeBytes = item.attrs.size,
                        modifiedEpochSec = item.attrs.mTime.toLong(),
                        permissions = item.attrs.permissionsString
                    )
                }
                .sortedWith(compareByDescending<RemoteFileEntry> { it.isDirectory }.thenBy { it.name.lowercase() })
            resolvedPath to entries
        } finally {
            runCatching { sftp?.disconnect() }
            chain.asReversed().forEach { runCatching { it.disconnect() } }
        }
    }

    suspend fun readRemoteFileBytes(
        host: SSHHost,
        allHosts: List<SSHHost>,
        remotePath: String,
        maxBytes: Int = 512 * 1024
    ): ByteArray = withContext(Dispatchers.IO) {
        val chain = openSessionChain(host, allHosts, 10_000)
        val session = chain.last()
        var sftp: ChannelSftp? = null
        try {
            sftp = session.openChannel("sftp") as ChannelSftp
            sftp.connect(10_000)
            val out = ByteArrayOutputStream()
            sftp.get(remotePath).use { input ->
                val buf = ByteArray(8192)
                var total = 0
                while (total < maxBytes) {
                    val toRead = minOf(buf.size, maxBytes - total)
                    val n = input.read(buf, 0, toRead)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    total += n
                }
            }
            out.toByteArray()
        } finally {
            runCatching { sftp?.disconnect() }
            chain.asReversed().forEach { runCatching { it.disconnect() } }
        }
    }

    suspend fun uploadRemoteFile(
        host: SSHHost,
        allHosts: List<SSHHost>,
        remotePath: String,
        inputStream: InputStream
    ) = withContext(Dispatchers.IO) {
        val chain = openSessionChain(host, allHosts, 10_000)
        val session = chain.last()
        var sftp: ChannelSftp? = null
        try {
            sftp = session.openChannel("sftp") as ChannelSftp
            sftp.connect(10_000)
            sftp.put(inputStream, remotePath, ChannelSftp.OVERWRITE)
        } finally {
            runCatching { sftp?.disconnect() }
            chain.asReversed().forEach { runCatching { it.disconnect() } }
        }
    }

    suspend fun startPortForward(
        config: SSHPortForwardConfig,
        host: SSHHost,
        allHosts: List<SSHHost>
    ) = withContext(Dispatchers.IO) {
        stopPortForward(config.id)
        val chain = openSessionChain(host, allHosts, 10_000)
        val session = chain.last()
        try {
            when (config.direction) {
                PortForwardDirection.LOCAL -> {
                    session.setPortForwardingL(config.localHost, config.localPort, config.remoteHost, config.remotePort)
                    activeForwards[config.id] = ActiveForwardHandle(chain)
                }
                PortForwardDirection.REMOTE -> {
                    session.setPortForwardingR(config.remoteHost, config.remotePort, config.localHost, config.localPort)
                    activeForwards[config.id] = ActiveForwardHandle(chain)
                }
                PortForwardDirection.DYNAMIC -> {
                    val server = ServerSocket(config.localPort, 32, InetAddress.getByName(config.localHost))
                    val handle = ActiveForwardHandle(chain, server)
                    activeForwards[config.id] = handle
                    thread(isDaemon = true, name = "nd-socks5-${config.localPort}") {
                        while (!handle.stopped && session.isConnected) {
                            val client = runCatching { server.accept() }.getOrNull() ?: break
                            thread(isDaemon = true) { handleSocks5Client(client, session) }
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            chain.asReversed().forEach { runCatching { it.disconnect() } }
            throw t
        }
    }

    fun stopPortForward(id: String) {
        activeForwards.remove(id)?.stop()
    }

    private fun handleSocks5Client(client: Socket, session: Session) {
        var channel: ChannelDirectTCPIP? = null
        try {
            client.soTimeout = 30_000
            val inp = client.getInputStream()
            val out = client.getOutputStream()
            val ver = inp.read()
            if (ver != 0x05) return
            val nMethods = inp.read()
            if (nMethods < 0) return
            val methods = ByteArray(nMethods)
            readFully(inp, methods)
            out.write(byteArrayOf(0x05, 0x00))
            out.flush()

            val header = ByteArray(4)
            readFully(inp, header)
            if (header[0].toInt() != 0x05 || header[1].toInt() != 0x01) {
                out.write(byteArrayOf(0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
                return
            }
            val destHost = when (header[3].toInt() and 0xFF) {
                0x01 -> {
                    val addr = ByteArray(4)
                    readFully(inp, addr)
                    InetAddress.getByAddress(addr).hostAddress ?: return
                }
                0x03 -> {
                    val len = inp.read()
                    if (len <= 0) return
                    val dom = ByteArray(len)
                    readFully(inp, dom)
                    String(dom, Charsets.UTF_8)
                }
                0x04 -> {
                    val addr = ByteArray(16)
                    readFully(inp, addr)
                    InetAddress.getByAddress(addr).hostAddress ?: return
                }
                else -> return
            }
            val portBytes = ByteArray(2)
            readFully(inp, portBytes)
            val destPort = ((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF)

            channel = session.openChannel("direct-tcpip") as ChannelDirectTCPIP
            channel.setHost(destHost)
            channel.setPort(destPort)
            val chIn = channel.inputStream
            val chOut = channel.outputStream
            channel.connect(8_000)

            out.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            out.flush()
            client.soTimeout = 0

            val t1 = thread(isDaemon = true) {
                runCatching { inp.copyTo(chOut) }
                runCatching { chOut.close() }
            }
            runCatching { chIn.copyTo(out) }
            runCatching { out.flush() }
            t1.join(500)
        } catch (_: Throwable) {
            // Connection closed
        } finally {
            runCatching { channel?.disconnect() }
            runCatching { client.close() }
        }
    }

    private fun readFully(inp: InputStream, dst: ByteArray) {
        var off = 0
        while (off < dst.size) {
            val n = inp.read(dst, off, dst.size - off)
            if (n < 0) throw IllegalStateException("EOF")
            off += n
        }
    }

    private fun friendlyError(t: Throwable): String {
        val msg = t.message.orEmpty()
        return when {
            msg.contains("Auth fail", ignoreCase = true) || msg.contains("USERAUTH", ignoreCase = true) ->
                "Authentication failed (check key or password)"
            msg.contains("timeout", ignoreCase = true) || msg.contains("timed out", ignoreCase = true) ->
                "Connection timed out"
            msg.contains("Connection refused", ignoreCase = true) ->
                "Connection refused"
            msg.contains("UnknownHost", ignoreCase = true) ->
                "Could not resolve hostname"
            msg.isNotBlank() -> msg.take(180)
            else -> t.javaClass.simpleName
        }
    }
}
