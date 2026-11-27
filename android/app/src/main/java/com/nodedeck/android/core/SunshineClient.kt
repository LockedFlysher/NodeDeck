package com.nodedeck.android.core

import android.os.Build
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.openssl.PEMKeyPair
import org.bouncycastle.openssl.PEMParser
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter
import org.bouncycastle.openssl.jcajce.JcaPEMWriter
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.w3c.dom.Element
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.StringReader
import java.io.StringWriter
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import javax.xml.parsers.DocumentBuilderFactory

class SunshineClient(
    private val store: SecureStore,
    private val sshManager: SshManager
) {
    private data class ClientIdentity(
        val certPem: String,
        val cert: X509Certificate,
        val privateKey: PrivateKey,
        val uniqueId: String,
        val sslContext: SSLContext
    )

    @Volatile
    private var cachedIdentity: ClientIdentity? = null
    private val identityLock = Any()

    /**
     * Returns this Android device's public Moonlight identity (uniqueId, X.509 cert PEM).
     * Never exposes the private key.
     */
    fun getPublicIdentity(): Pair<String, String> {
        val id = ensureIdentity()
        return id.uniqueId to id.certPem
    }

    private fun ensureIdentity(): ClientIdentity {
        cachedIdentity?.let { return it }
        synchronized(identityLock) {
            cachedIdentity?.let { return it }
            val dir = store.moonlightDir
            val certFile = File(dir, "client.crt")
            val keyFile = File(dir, "client.key")
            val uidFile = File(dir, "uniqueid.txt")

            val uid = if (uidFile.exists()) {
                uidFile.readText().trim().ifBlank { generateUniqueId() }
            } else {
                generateUniqueId().also { uidFile.writeText(it) }
            }

            val cert: X509Certificate
            val privateKey: PrivateKey
            val certPem: String

            if (certFile.exists() && keyFile.exists()) {
                certPem = certFile.readText()
                cert = parseCertPem(certPem)
                privateKey = parsePrivateKeyPem(keyFile.readText())
            } else {
                val kpGen = KeyPairGenerator.getInstance("RSA")
                kpGen.initialize(2048, SecureRandom())
                val kp = kpGen.generateKeyPair()
                val now = System.currentTimeMillis()
                val subject = X500Name("CN=NVIDIA GameStream Client")
                val builder = JcaX509v3CertificateBuilder(
                    subject,
                    BigInteger.valueOf(now),
                    Date(now - 86_400_000L),
                    Date(now + 20L * 365 * 86_400_000L),
                    subject,
                    kp.public
                )
                val signer = JcaContentSignerBuilder("SHA256WithRSA")
                    .setProvider(BouncyCastleProvider())
                    .build(kp.private)
                cert = JcaX509CertificateConverter()
                    .setProvider(BouncyCastleProvider())
                    .getCertificate(builder.build(signer))
                privateKey = kp.private
                certPem = toPem(cert)
                val keyPem = toPem(kp.private)
                certFile.writeText(certPem)
                keyFile.writeText(keyPem)
            }

            // Convert key to platform-native KeyFactory RSA PrivateKey so Android Conscrypt/BoringSSL
            // can sign TLS 1.2/1.3 CertificateVerify without BouncyCastle provider mismatch.
            val nativePrivateKey = KeyFactory.getInstance("RSA")
                .generatePrivate(PKCS8EncodedKeySpec(privateKey.encoded))

            // Always present our Moonlight client certificate regardless of server CertificateRequest issuers
            val keyManagers = arrayOf<KeyManager>(object : X509ExtendedKeyManager() {
                override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> =
                    arrayOf("client")

                override fun chooseClientAlias(
                    keyType: Array<out String>?,
                    issuers: Array<out Principal>?,
                    socket: Socket?
                ): String {
                    Log.i(TAG, "chooseClientAlias called: keyTypes=${keyType?.joinToString()}")
                    return "client"
                }

                override fun chooseEngineClientAlias(
                    keyType: Array<out String>?,
                    issuers: Array<out Principal>?,
                    engine: SSLEngine?
                ): String {
                    Log.i(TAG, "chooseEngineClientAlias called: keyTypes=${keyType?.joinToString()}")
                    return "client"
                }

                override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> =
                    emptyArray()

                override fun chooseServerAlias(
                    keyType: String?,
                    issuers: Array<out Principal>?,
                    socket: Socket?
                ): String? = null

                override fun getCertificateChain(alias: String?): Array<X509Certificate> =
                    arrayOf(cert)

                override fun getPrivateKey(alias: String?): PrivateKey = nativePrivateKey
            })
            val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
                override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            })
            val sslCtx = SSLContext.getInstance("TLS").apply {
                init(keyManagers, trustAll, SecureRandom())
            }

            return ClientIdentity(certPem, cert, nativePrivateKey, uid, sslCtx).also {
                cachedIdentity = it
            }
        }
    }

    suspend fun fetchServerInfo(address: String, httpPort: Int = 47989): SunshineServerInfo =
        withContext(Dispatchers.IO) {
            val id = ensureIdentity()
            val query = mapOf(
                "uniqueid" to id.uniqueId,
                "uuid" to UUID.randomUUID().toString().replace("-", "")
            )
            val httpsPortGuess = (httpPort - 5).coerceAtLeast(1)
            val xml = runCatching {
                requestXml(id, "https", address, httpsPortGuess, "/serverinfo", query, 6_000)
            }.getOrElse {
                requestXml(id, "http", address, httpPort, "/serverinfo", query, 8_000)
            }
            val root = parseXml(xml)
            SunshineServerInfo(
                hostname = root.firstText("hostname") ?: address,
                appVersion = root.firstText("appversion") ?: "7.1.431.0",
                gfeVersion = root.firstText("GfeVersion") ?: "3.23.0.74",
                httpsPort = root.firstText("HttpsPort")?.toIntOrNull() ?: httpsPortGuess,
                pairStatus = root.firstText("PairStatus") == "1",
                currentGame = root.firstText("currentgame")?.toIntOrNull() ?: 0,
                serverCodecModeSupport = root.firstText("ServerCodecModeSupport")?.toIntOrNull() ?: 0
            )
        }

    suspend fun fetchAppList(address: String, httpsPort: Int): List<SunshineApp> =
        withContext(Dispatchers.IO) {
            val id = ensureIdentity()
            val xml = requestXml(
                id,
                "https",
                address,
                httpsPort,
                "/applist",
                mapOf("uniqueid" to id.uniqueId, "uuid" to UUID.randomUUID().toString().replace("-", "")),
                10_000
            )
            val root = parseXml(xml)
            val apps = mutableListOf<SunshineApp>()
            val nodes = root.getElementsByTagName("App")
            for (i in 0 until nodes.length) {
                val el = nodes.item(i) as? Element ?: continue
                val appId = el.firstText("ID")?.toIntOrNull() ?: continue
                val title = el.firstText("AppTitle") ?: "App $appId"
                apps.add(SunshineApp(appId, title))
            }
            apps
        }

    suspend fun launchStream(
        address: String,
        httpPort: Int = 47989,
        preferredAppTitle: String = "Desktop",
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60
    ): SunshineLaunchSession = withContext(Dispatchers.IO) {
        val id = ensureIdentity()
        val info = fetchServerInfo(address, httpPort)
        val apps = fetchAppList(address, info.httpsPort)
        val app = apps.firstOrNull { it.title.equals(preferredAppTitle, ignoreCase = true) }
            ?: apps.firstOrNull { it.title.contains("desktop", ignoreCase = true) }
            ?: apps.firstOrNull()
            ?: throw IllegalStateException("No applications found on Sunshine host")

        val rikey = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val rikeyId = (SecureRandom().nextInt() and 0x7FFFFFFF).coerceAtLeast(1)
        val actionPath = if (info.currentGame == app.id && info.currentGame != 0) "/resume" else "/launch"

        val xml = requestXml(
            id,
            "https",
            address,
            info.httpsPort,
            actionPath,
            mapOf(
                "uniqueid" to id.uniqueId,
                "uuid" to UUID.randomUUID().toString().replace("-", ""),
                "appid" to app.id.toString(),
                "mode" to "${width}x${height}x$fps",
                "additionalStates" to "1",
                "sops" to "0",
                "rikey" to toHex(rikey),
                "rikeyid" to rikeyId.toString(),
                "localAudioPlayMode" to "0",
                "surroundAudioInfo" to "196610",
                "remoteControllersBitmap" to "0",
                "gcmap" to "0",
                "gcpersist" to "0",
                "corever" to "1"
            ),
            20_000
        )

        val root = parseXml(xml)
        val sessionUrl = root.firstText("sessionUrl0") ?: "rtsp://$address:48010"
        val launched = root.firstText("gamesession") == "1" ||
            root.firstText("resume") == "1" ||
            root.firstText("sessionUrl0") != null
        if (!launched) {
            val msg = root.getAttribute("status_message").ifBlank { "Sunshine declined stream launch" }
            throw IllegalStateException(msg)
        }

        SunshineLaunchSession(
            address = address,
            httpPort = httpPort,
            httpsPort = info.httpsPort,
            appVersion = info.appVersion,
            gfeVersion = info.gfeVersion,
            serverCodecModeSupport = info.serverCodecModeSupport,
            rtspSessionUrl = sessionUrl,
            rikey = rikey,
            rikeyId = rikeyId,
            appId = app.id,
            appTitle = app.title
        )
    }

    suspend fun cancelSession(address: String, httpsPort: Int) = withContext(Dispatchers.IO) {
        val id = runCatching { ensureIdentity() }.getOrNull() ?: return@withContext
        runCatching {
            requestXml(
                id,
                "https",
                address,
                httpsPort,
                "/cancel",
                mapOf("uniqueid" to id.uniqueId, "uuid" to UUID.randomUUID().toString().replace("-", "")),
                5_000
            )
        }
    }

    /**
     * Zero-PIN pairing over the user's trusted SSH connection:
     * injects this Android device's local RSA-2048 certificate into remote sunshine_state.json
     * and reloads nodedeck-host / sunshine.
     */
    suspend fun pairViaSsh(
        host: SSHHost,
        allHosts: List<SSHHost>,
        httpPort: Int = 47989
    ): SunshineHostConfig = withContext(Dispatchers.IO) {
        val id = ensureIdentity()
        val certB64 = Base64.encodeToString(id.certPem.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val deviceName = "NodeDeck-${Build.MODEL}".replace("\"", "").replace("'", "")
        val remotePy = """
import base64, json, os, re, subprocess, sys, time, uuid

cert_pem = base64.b64decode("$certB64").decode("utf-8")
client_name = "$deviceName"
client_uid = "${id.uniqueId}"

nd_host_dir = os.path.expanduser("~/.config/nodedeck/host")
legacy_dir = os.path.expanduser("~/.config/sunshine")
if os.path.exists(os.path.join(nd_host_dir, "host.conf")) or os.path.exists("/opt/nodedeck/host/bin/nodedeck-host") or os.path.exists(os.path.expanduser("~/.local/share/nodedeck/host/bin/nodedeck-host")):
    conf_dir = nd_host_dir
    conf_path = os.path.join(conf_dir, "host.conf")
else:
    conf_dir = legacy_dir
    conf_path = os.path.join(conf_dir, "sunshine.conf")
os.makedirs(conf_dir, exist_ok=True)
state_path = os.path.join(conf_dir, "sunshine_state.json")

detected_port = $httpPort
if os.path.exists(conf_path):
    txt = open(conf_path, "r", encoding="utf-8", errors="ignore").read()
    m = re.search(r"^\s*port\s*=\s*(\d+)", txt, re.M)
    if m:
        detected_port = int(m.group(1))

state = {}
if os.path.exists(state_path):
    try:
        state = json.load(open(state_path, "r", encoding="utf-8"))
    except Exception:
        state = {}

root = state.setdefault("root", {})
if not root.get("uniqueid"):
    root["uniqueid"] = str(uuid.uuid4()).upper()
devices = root.setdefault("named_devices", [])
devices = [d for d in devices if d.get("cert") != cert_pem and d.get("name") != client_name]
devices.append({
    "name": client_name,
    "uuid": str(uuid.uuid5(uuid.NAMESPACE_DNS, "nodedeck-android-" + client_uid)).upper(),
    "cert": cert_pem
})
root["named_devices"] = devices

with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)

restarted = False
for svc in ["nodedeck-host", "foundation-sunshine", "sunshine"]:
    if subprocess.run(["systemctl", "--user", "is-active", "--quiet", svc]).returncode == 0:
        subprocess.run(["systemctl", "--user", "restart", svc], check=False)
        restarted = True
        break

print(f"OK:{detected_port}:{int(restarted)}")
        """.trimIndent()

        val res = sshManager.exec(host, allHosts, "python3 -", stdinText = remotePy, timeoutMs = 18_000)
        if (res.exitCode != 0) {
            throw IllegalStateException(res.stderr.trim().ifBlank { "SSH cert injection failed (exit ${res.exitCode})" })
        }

        var resolvedPort = httpPort
        res.stdout.lines().lastOrNull { it.startsWith("OK:") }?.let { okLine ->
            val parts = okLine.split(":")
            if (parts.size >= 2) parts[1].toIntOrNull()?.let { resolvedPort = it }
        }

        delay(1500)
        val info = fetchServerInfo(host.hostName, resolvedPort)
        SunshineHostConfig(
            hostAlias = host.alias,
            address = host.hostName,
            httpPort = resolvedPort,
            httpsPort = info.httpsPort,
            serverName = info.hostname,
            isPaired = true
        )
    }

    /**
     * Standard Moonlight 4-digit PIN pairing flow (for hosts where SSH cert injection is not used).
     */
    suspend fun pairWithPin(
        hostAlias: String,
        address: String,
        httpPort: Int,
        pin: String
    ): SunshineHostConfig = withContext(Dispatchers.IO) {
        val id = ensureIdentity()
        val info = fetchServerInfo(address, httpPort)
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val aesKey = sha256(salt + pin.toByteArray(Charsets.UTF_8)).copyOf(16)
        val clientCertHex = toHex(id.certPem.toByteArray(Charsets.UTF_8))

        val step1 = parseXml(
            requestXml(
                id, "http", address, httpPort, "/pair",
                mapOf(
                    "uniqueid" to id.uniqueId,
                    "uuid" to UUID.randomUUID().toString().replace("-", ""),
                    "devicename" to "roth",
                    "updateState" to "1",
                    "phrase" to "getservercert",
                    "salt" to toHex(salt),
                    "clientcert" to clientCertHex
                ),
                45_000
            )
        )
        if (step1.firstText("paired") != "1") {
            throw IllegalStateException("Host declined pairing step 1 (check PIN entry on host)")
        }
        val serverCertHex = step1.firstText("plaincert")
            ?: throw IllegalStateException("Missing server certificate in pairing response")
        val serverCert = parseCertPem(String(fromHex(serverCertHex), Charsets.UTF_8))

        val clientChallenge = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val step2 = parseXml(
            requestXml(
                id, "http", address, httpPort, "/pair",
                mapOf(
                    "uniqueid" to id.uniqueId,
                    "uuid" to UUID.randomUUID().toString().replace("-", ""),
                    "devicename" to "roth",
                    "updateState" to "1",
                    "clientchallenge" to toHex(aes128EcbEncrypt(aesKey, clientChallenge))
                ),
                15_000
            )
        )
        if (step2.firstText("paired") != "1") throw IllegalStateException("Pairing step 2 failed")
        val encResp = fromHex(step2.firstText("challengeresponse") ?: throw IllegalStateException("Missing challengeresponse"))
        val decResp = aes128EcbDecrypt(aesKey, encResp)
        val serverChallenge = decResp.copyOfRange(32, 48)

        val clientSecret = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val hashInput = serverChallenge + id.cert.signature + clientSecret
        val clientHash = sha256(hashInput)
        val step3 = parseXml(
            requestXml(
                id, "http", address, httpPort, "/pair",
                mapOf(
                    "uniqueid" to id.uniqueId,
                    "uuid" to UUID.randomUUID().toString().replace("-", ""),
                    "devicename" to "roth",
                    "updateState" to "1",
                    "serverchallengeresp" to toHex(aes128EcbEncrypt(aesKey, clientHash))
                ),
                15_000
            )
        )
        if (step3.firstText("paired") != "1") throw IllegalStateException("Pairing step 3 failed")

        val sig = Signature.getInstance("SHA256withRSA").apply {
            initSign(id.privateKey)
            update(clientSecret)
        }.sign()
        val step4 = parseXml(
            requestXml(
                id, "http", address, httpPort, "/pair",
                mapOf(
                    "uniqueid" to id.uniqueId,
                    "uuid" to UUID.randomUUID().toString().replace("-", ""),
                    "devicename" to "roth",
                    "updateState" to "1",
                    "clientpairingsecret" to toHex(clientSecret + sig)
                ),
                15_000
            )
        )
        if (step4.firstText("paired") != "1") throw IllegalStateException("Pairing step 4 failed")

        val step5 = parseXml(
            requestXml(
                id, "https", address, info.httpsPort, "/pair",
                mapOf(
                    "uniqueid" to id.uniqueId,
                    "uuid" to UUID.randomUUID().toString().replace("-", ""),
                    "devicename" to "roth",
                    "updateState" to "1",
                    "phrase" to "pairchallenge"
                ),
                15_000
            )
        )
        if (step5.firstText("paired") != "1") throw IllegalStateException("HTTPS pairchallenge failed")

        // serverCert parsed & verified above
        SunshineHostConfig(
            hostAlias = hostAlias.ifBlank { info.hostname },
            address = address,
            httpPort = httpPort,
            httpsPort = info.httpsPort,
            serverName = serverCert.subjectX500Principal.name.ifBlank { info.hostname },
            isPaired = true
        )
    }

    private fun requestXml(
        id: ClientIdentity,
        scheme: String,
        address: String,
        port: Int,
        path: String,
        query: Map<String, String>,
        timeoutMs: Int
    ): String {
        val qs = query.entries.sortedBy { it.key }.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        val requestTarget = if (qs.isEmpty()) path else "$path?$qs"
        val rawTcp = Socket()
        rawTcp.connect(InetSocketAddress(address, port), timeoutMs)
        rawTcp.soTimeout = timeoutMs

        val socket: Socket = if (scheme.equals("https", ignoreCase = true)) {
            val ssl = id.sslContext.socketFactory.createSocket(rawTcp, address, port, true) as SSLSocket
            ssl.soTimeout = timeoutMs
            // Prefer TLSv1.2 for broadest compatibility with Sunshine Boost.Asio mutual TLS
            val supported = ssl.supportedProtocols.toSet()
            if ("TLSv1.2" in supported) {
                ssl.enabledProtocols = arrayOf("TLSv1.2")
            }
            ssl.startHandshake()
            Log.i(TAG, "TLS connected $address:$port $path proto=${ssl.session.protocol} cipher=${ssl.session.cipherSuite} localCerts=${ssl.session.localCertificates?.size ?: 0}")
            ssl
        } else {
            rawTcp
        }

        return socket.use { s ->
            val req = "GET $requestTarget HTTP/1.1\r\n" +
                "Host: $address:$port\r\n" +
                "User-Agent: NodeDeck-Android\r\n" +
                "Accept: */*\r\n" +
                "Connection: close\r\n\r\n"
            val out = s.getOutputStream()
            out.write(req.toByteArray(Charsets.US_ASCII))
            out.flush()

            val inp = BufferedInputStream(s.getInputStream())
            val rawBytes = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            while (true) {
                val n = inp.read(buf)
                if (n <= 0) break
                rawBytes.write(buf, 0, n)
            }
            val full = rawBytes.toByteArray()
            val sep = findHeaderEnd(full)
            if (sep < 0) {
                throw IllegalStateException("Malformed HTTP response from $address:$port$path")
            }
            val headerText = String(full, 0, sep, Charsets.ISO_8859_1)
            val statusLine = headerText.lineSequence().firstOrNull().orEmpty()
            val statusCode = statusLine.split(" ").getOrNull(1)?.toIntOrNull() ?: 0
            val bodyBytes = full.copyOfRange(sep + 4, full.size)
            val isChunked = headerText.lines().any {
                it.startsWith("Transfer-Encoding:", ignoreCase = true) && it.contains("chunked", ignoreCase = true)
            }
            val decodedBody = if (isChunked) decodeChunked(bodyBytes) else bodyBytes
            val bodyStr = String(decodedBody, Charsets.UTF_8)
            Log.i(TAG, "HTTP $statusCode $scheme://$address:$port$path (${bodyStr.length} bytes)")
            if (statusCode !in 200..299) {
                throw IllegalStateException("HTTP $statusCode: ${bodyStr.take(120)}")
            }
            bodyStr
        }
    }

    private fun findHeaderEnd(data: ByteArray): Int {
        for (i in 0 until data.size - 3) {
            if (data[i] == '\r'.code.toByte() &&
                data[i + 1] == '\n'.code.toByte() &&
                data[i + 2] == '\r'.code.toByte() &&
                data[i + 3] == '\n'.code.toByte()
            ) {
                return i
            }
        }
        return -1
    }

    private fun decodeChunked(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        var pos = 0
        while (pos < data.size) {
            var lineEnd = pos
            while (lineEnd < data.size - 1 && !(data[lineEnd] == '\r'.code.toByte() && data[lineEnd + 1] == '\n'.code.toByte())) {
                lineEnd++
            }
            val sizeHex = String(data, pos, (lineEnd - pos).coerceAtLeast(0), Charsets.US_ASCII)
                .substringBefore(';').trim()
            val chunkLen = sizeHex.toIntOrNull(16) ?: break
            pos = lineEnd + 2
            if (chunkLen <= 0 || pos + chunkLen > data.size) break
            out.write(data, pos, chunkLen)
            pos += chunkLen + 2
        }
        return out.toByteArray()
    }

    private fun parseXml(xml: String): Element {
        val factory = DocumentBuilderFactory.newInstance()
        val doc = factory.newDocumentBuilder().parse(ByteArrayInputStream(xml.toByteArray(Charsets.UTF_8)))
        return doc.documentElement
    }

    private fun Element.firstText(tag: String): String? {
        val nodes = getElementsByTagName(tag)
        if (nodes.length == 0) return null
        return nodes.item(0)?.textContent?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun parseCertPem(pem: String): X509Certificate {
        val cf = CertificateFactory.getInstance("X.509")
        return cf.generateCertificate(ByteArrayInputStream(pem.toByteArray(Charsets.UTF_8))) as X509Certificate
    }

    private fun parsePrivateKeyPem(pem: String): PrivateKey {
        val parser = PEMParser(StringReader(pem))
        val obj = parser.readObject()
        val converter = JcaPEMKeyConverter().setProvider(BouncyCastleProvider())
        return when (obj) {
            is PEMKeyPair -> converter.getKeyPair(obj).private
            is org.bouncycastle.asn1.pkcs.PrivateKeyInfo -> converter.getPrivateKey(obj)
            else -> throw IllegalStateException("Unsupported private key format: ${obj?.javaClass?.name}")
        }
    }

    private fun toPem(obj: Any): String {
        val sw = StringWriter()
        JcaPEMWriter(sw).use { it.writeObject(obj) }
        return sw.toString()
    }

    private fun generateUniqueId(): String {
        val b = ByteArray(8).also { SecureRandom().nextBytes(it) }
        return toHex(b)
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    private fun aes128EcbEncrypt(key: ByteArray, data: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        return cipher.doFinal(data)
    }

    private fun aes128EcbDecrypt(key: ByteArray, data: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"))
        return cipher.doFinal(data)
    }

    companion object {
        private const val TAG = "NodeDeckSunshine"
        fun generateRandomPin(): String =
            (1000 + SecureRandom().nextInt(9000)).toString()

        fun toHex(bytes: ByteArray): String =
            bytes.joinToString("") { "%02x".format(it) }

        fun fromHex(hex: String): ByteArray {
            val clean = hex.trim()
            val out = ByteArray(clean.length / 2)
            for (i in out.indices) {
                out[i] = clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
            return out
        }
    }
}
