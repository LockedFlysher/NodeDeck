package com.nodedeck.android.core

object SshConfigParser {
    fun parseHosts(configText: String): List<SSHHost> {
        val results = mutableListOf<SSHHost>()
        var currentAliases: List<String> = emptyList()
        var hostName = ""
        var user = ""
        var port = 22
        var proxyJump = ""
        var identityFile = ""

        fun flush() {
            val primary = currentAliases.firstOrNull { !it.contains('*') && !it.contains('?') && !it.startsWith('!') }
            if (primary != null) {
                val resolvedHost = hostName.ifBlank { primary }
                results.add(
                    SSHHost(
                        alias = primary,
                        hostName = resolvedHost,
                        user = user.ifBlank { "root" },
                        port = port,
                        authType = if (identityFile.isNotBlank()) SSHAuthType.PRIVATE_KEY else SSHAuthType.PASSWORD,
                        privateKeyName = identityFile.substringAfterLast('/'),
                        proxyJumpAlias = proxyJump
                    )
                )
            }
            currentAliases = emptyList()
            hostName = ""
            user = ""
            port = 22
            proxyJump = ""
            identityFile = ""
        }

        for (rawLine in configText.lines()) {
            val line = rawLine.substringBefore('#').trim()
            if (line.isEmpty()) continue
            val parts = line.split(Regex("\\s+"), limit = 2)
            if (parts.size < 2) continue
            val key = parts[0].lowercase()
            val value = parts[1].trim()
            when (key) {
                "host" -> {
                    flush()
                    currentAliases = value.split(Regex("\\s+")).filter { it.isNotBlank() }
                }
                "hostname" -> if (hostName.isBlank()) hostName = value
                "user" -> if (user.isBlank()) user = value
                "port" -> port = value.toIntOrNull() ?: 22
                "proxyjump" -> if (proxyJump.isBlank()) proxyJump = value
                "identityfile" -> if (identityFile.isBlank()) identityFile = value.trim('"')
            }
        }
        flush()
        return results
    }
}
