package com.nodedeck.android.core

import android.content.Context
import com.nodedeck.android.mesh.MeshConfig
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

class SecureStore(context: Context) {
    private val appContext = context.applicationContext
    private val rootDir = File(appContext.filesDir, "nodedeck").apply { mkdirs() }
    val keysDir = File(rootDir, "ssh_keys").apply { mkdirs() }
    val moonlightDir = File(rootDir, "moonlight").apply { mkdirs() }

    private val prefs = appContext.getSharedPreferences("nodedeck_prefs", Context.MODE_PRIVATE)
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val hostsFile = File(rootDir, "hosts.json")
    private val sunshineFile = File(rootDir, "sunshine_hosts.json")
    private val forwardsFile = File(rootDir, "port_forwards.json")
    private val profilesFile = File(rootDir, "host_profiles.json")
    private val meshConfigFile = File(rootDir, "mesh_config.json")
    private val accountFile = File(rootDir, "account_session.json")

    fun loadHosts(): List<SSHHost> = readJsonFile(hostsFile) ?: emptyList()
    fun saveHosts(hosts: List<SSHHost>) = writeJsonFile(hostsFile, hosts)

    fun loadSunshineHosts(): List<SunshineHostConfig> = readJsonFile(sunshineFile) ?: emptyList()
    fun saveSunshineHosts(configs: List<SunshineHostConfig>) = writeJsonFile(sunshineFile, configs)

    fun loadPortForwards(): List<SSHPortForwardConfig> = readJsonFile(forwardsFile) ?: emptyList()
    fun savePortForwards(configs: List<SSHPortForwardConfig>) = writeJsonFile(forwardsFile, configs)

    fun loadHostProfiles(): List<LinuxHostProfile> = readJsonFile(profilesFile) ?: emptyList()
    fun saveHostProfiles(profiles: List<LinuxHostProfile>) = writeJsonFile(profilesFile, profiles)

    fun loadMeshConfig(): MeshConfig = readJsonFile(meshConfigFile) ?: MeshConfig()
    fun saveMeshConfig(config: MeshConfig) = writeJsonFile(meshConfigFile, config)

    fun loadAccountSession(): AccountSession = readJsonFile(accountFile) ?: AccountSession()
    fun saveAccountSession(session: AccountSession) = writeJsonFile(accountFile, session)

    fun getOrCreateDeviceId(): String {
        val existing = prefs.getString("device_id", null)
        if (!existing.isNullOrBlank()) return existing
        val created = "android-" + UUID.randomUUID().toString().replace("-", "").take(12)
        prefs.edit().putString("device_id", created).apply()
        return created
    }

    fun savePrivateKey(name: String, pemContent: String): String {
        val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_").ifBlank { "id_key" }
        val file = File(keysDir, safeName)
        file.writeText(pemContent.trim() + "\n")
        return safeName
    }

    fun readPrivateKey(name: String): String? {
        if (name.isBlank()) return null
        val file = File(keysDir, name)
        return if (file.exists()) file.readText() else null
    }

    fun listPrivateKeys(): List<String> =
        keysDir.listFiles()?.filter { it.isFile }?.map { it.name }?.sorted() ?: emptyList()

    fun getPinnedAliases(): Set<String> =
        prefs.getStringSet("pinned_aliases", emptySet())?.toSet() ?: emptySet()

    fun setPinnedAliases(aliases: Set<String>) {
        prefs.edit().putStringSet("pinned_aliases", aliases).apply()
    }

    fun getLanguage(): AppLanguage =
        AppLanguage.fromStorage(prefs.getString("language", AppLanguage.SYSTEM.storageValue))

    fun setLanguage(lang: AppLanguage) {
        prefs.edit().putString("language", lang.storageValue).apply()
    }

    fun getStreamResolution(): StreamResolutionPreset =
        StreamResolutionPreset.fromLabel(prefs.getString("stream_resolution", StreamResolutionPreset.HD_1080.label))

    fun setStreamResolution(preset: StreamResolutionPreset) {
        prefs.edit().putString("stream_resolution", preset.label).apply()
    }

    fun getStreamRefreshRate(): StreamRefreshRate =
        StreamRefreshRate.fromFps(prefs.getInt("stream_fps", StreamRefreshRate.HZ_60.fps))

    fun setStreamRefreshRate(rate: StreamRefreshRate) {
        prefs.edit().putInt("stream_fps", rate.fps).apply()
    }

    fun getRefreshIntervalSec(): Int = prefs.getInt("refresh_interval_sec", 30)

    fun setRefreshIntervalSec(sec: Int) {
        prefs.edit().putInt("refresh_interval_sec", sec).apply()
    }

    fun getTouchpadMode(): Boolean = prefs.getBoolean("stream_touchpad_mode", true)

    fun setTouchpadMode(enabled: Boolean) {
        prefs.edit().putBoolean("stream_touchpad_mode", enabled).apply()
    }

    fun getClipboardAutoSync(): Boolean = prefs.getBoolean("clipboard_auto_sync", true)

    fun setClipboardAutoSync(enabled: Boolean) {
        prefs.edit().putBoolean("clipboard_auto_sync", enabled).apply()
    }

    private inline fun <reified T> readJsonFile(file: File): T? {
        if (!file.exists()) return null
        return runCatching { json.decodeFromString<T>(file.readText()) }.getOrNull()
    }

    private inline fun <reified T> writeJsonFile(file: File, value: T) {
        runCatching {
            val tmp = File(file.parentFile, "${file.name}.tmp")
            tmp.writeText(json.encodeToString(value))
            if (!tmp.renameTo(file)) {
                file.writeText(tmp.readText())
                tmp.delete()
            }
        }
    }
}
