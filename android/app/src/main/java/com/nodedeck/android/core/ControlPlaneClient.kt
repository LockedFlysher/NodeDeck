package com.nodedeck.android.core

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.HttpURLConnection
import java.net.URL

@Serializable
data class AccountSession(
    val serverUrl: String = ControlPlaneClient.DEFAULT_SERVER_URL,
    val username: String = "",
    val token: String = "",
    val deviceId: String = "",
    val deviceName: String = "",
    val virtualIp: String = "",
    val virtualCidr: String = ""
) {
    val isLoggedIn: Boolean get() = token.isNotBlank() && username.isNotBlank()
}

@Serializable
data class ControlPlaneUser(val username: String = "")

@Serializable
data class ControlPlaneDevice(
    @SerialName("device_id") val deviceId: String = "",
    @SerialName("device_name") val deviceName: String = "",
    val platform: String = "",
    val role: String = "controller",
    @SerialName("virtual_ip") val virtualIp: String = "",
    @SerialName("virtual_cidr") val virtualCidr: String = "",
    @SerialName("ssh_user") val sshUser: String = "",
    @SerialName("ssh_port") val sshPort: Int = 22,
    @SerialName("sunshine_http_port") val sunshineHttpPort: Int = 47989,
    @SerialName("sunshine_https_port") val sunshineHttpsPort: Int = 47984,
    @SerialName("sunshine_enabled") val sunshineEnabled: Boolean = false,
    val online: Boolean = false,
    @SerialName("last_seen") val lastSeen: Long = 0L
)

@Serializable
data class ControlPlaneMeshInfo(
    @SerialName("network_name") val networkName: String = "",
    @SerialName("network_secret") val networkSecret: String = "",
    val subnet: String = "",
    @SerialName("seed_uri") val seedUri: String = "",
    @SerialName("listen_port") val listenPort: Int = 28443
)

@Serializable
data class ControlPlaneStateResponse(
    val token: String? = null,
    val user: ControlPlaneUser = ControlPlaneUser(),
    val device: ControlPlaneDevice = ControlPlaneDevice(),
    val mesh: ControlPlaneMeshInfo = ControlPlaneMeshInfo(),
    val devices: List<ControlPlaneDevice> = emptyList(),
    val error: String? = null
)

class ControlPlaneClient {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    @Serializable
    private data class RegisterBody(
        val username: String,
        val password: String,
        @SerialName("invite_code") val inviteCode: String,
        @SerialName("device_id") val deviceId: String,
        @SerialName("device_name") val deviceName: String,
        val platform: String = "android",
        val role: String = "controller"
    )

    @Serializable
    private data class LoginBody(
        val username: String,
        val password: String,
        @SerialName("device_id") val deviceId: String,
        @SerialName("device_name") val deviceName: String,
        val platform: String = "android",
        val role: String = "controller"
    )

    @Serializable
    private data class HeartbeatBody(
        @SerialName("device_name") val deviceName: String,
        val platform: String = "android",
        val role: String = "controller",
        @SerialName("lan_ips") val lanIps: List<String> = emptyList()
    )

    @Serializable
    private data class CertRegisterBody(
        @SerialName("device_name") val deviceName: String,
        @SerialName("unique_id") val uniqueId: String,
        @SerialName("cert_pem") val certPem: String
    )

    @Serializable
    private data class ErrorBody(val error: String? = null)

    suspend fun register(
        serverUrl: String,
        username: String,
        password: String,
        inviteCode: String,
        deviceId: String,
        deviceName: String = defaultDeviceName()
    ): ControlPlaneStateResponse = withContext(Dispatchers.IO) {
        val body = json.encodeToString(
            RegisterBody(
                username = username.trim(),
                password = password,
                inviteCode = inviteCode.trim(),
                deviceId = deviceId,
                deviceName = deviceName
            )
        )
        postJson(serverUrl, "/api/v1/auth/register", body, token = null)
    }

    suspend fun login(
        serverUrl: String,
        username: String,
        password: String,
        deviceId: String,
        deviceName: String = defaultDeviceName()
    ): ControlPlaneStateResponse = withContext(Dispatchers.IO) {
        val body = json.encodeToString(
            LoginBody(
                username = username.trim(),
                password = password,
                deviceId = deviceId,
                deviceName = deviceName
            )
        )
        postJson(serverUrl, "/api/v1/auth/login", body, token = null)
    }

    suspend fun fetchState(serverUrl: String, token: String): ControlPlaneStateResponse =
        withContext(Dispatchers.IO) {
            val base = serverUrl.trimEnd('/')
            val conn = (URL("$base/api/v1/state").openConnection() as HttpURLConnection).apply {
                connectTimeout = 10_000
                readTimeout = 10_000
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer $token")
            }
            parseResponse(conn)
        }

    suspend fun heartbeat(
        serverUrl: String,
        token: String,
        deviceName: String,
        lanIps: List<String>
    ): ControlPlaneStateResponse = withContext(Dispatchers.IO) {
        val body = json.encodeToString(HeartbeatBody(deviceName = deviceName, lanIps = lanIps))
        postJson(serverUrl, "/api/v1/devices/heartbeat", body, token = token)
    }

    suspend fun registerClientCert(
        serverUrl: String,
        token: String,
        deviceName: String,
        uniqueId: String,
        certPem: String
    ) = withContext(Dispatchers.IO) {
        val body = json.encodeToString(CertRegisterBody(deviceName, uniqueId, certPem))
        val base = serverUrl.trimEnd('/')
        val conn = (URL("$base/api/v1/certs/register").openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 10_000
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            setRequestProperty("Authorization", "Bearer $token")
        }
        try {
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            if (code !in 200..299) {
                val err = conn.errorStream?.bufferedReader()?.readText().orEmpty()
                throw IllegalStateException("Cert sync HTTP $code: $err")
            }
        } finally {
            conn.disconnect()
        }
    }

    suspend fun logout(serverUrl: String, token: String) = withContext(Dispatchers.IO) {
        runCatching {
            val base = serverUrl.trimEnd('/')
            val conn = (URL("$base/api/v1/auth/logout").openConnection() as HttpURLConnection).apply {
                connectTimeout = 5_000
                readTimeout = 5_000
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("Authorization", "Bearer $token")
            }
            try {
                conn.outputStream.use { it.write("{}".toByteArray()) }
                conn.responseCode
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun postJson(serverUrl: String, path: String, payload: String, token: String?): ControlPlaneStateResponse {
        val base = serverUrl.trimEnd('/')
        val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 12_000
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            if (!token.isNullOrBlank()) {
                setRequestProperty("Authorization", "Bearer $token")
            }
        }
        return try {
            conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
            parseResponse(conn)
        } finally {
            conn.disconnect()
        }
    }

    private fun parseResponse(conn: HttpURLConnection): ControlPlaneStateResponse {
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val raw = stream?.bufferedReader(Charsets.UTF_8)?.readText().orEmpty()
        if (code !in 200..299) {
            val errMsg = runCatching { json.decodeFromString<ErrorBody>(raw).error }.getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?: "HTTP $code: ${raw.take(140)}"
            throw IllegalStateException(errMsg)
        }
        return json.decodeFromString(raw)
    }

    companion object {
        const val DEFAULT_SERVER_URL = "https://lockedflysher.duckdns.org:8443/nodedeck-api"

        fun defaultDeviceName(): String {
            val model = Build.MODEL.orEmpty().trim().replace(Regex("[^A-Za-z0-9._-]"), "-")
            return if (model.isNotBlank()) "android-$model".lowercase().take(32) else "android"
        }
    }
}
