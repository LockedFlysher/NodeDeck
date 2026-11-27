package com.nodedeck.android.mesh

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object MeshRuntimeController {
    private val _snapshot = MutableStateFlow(MeshRuntimeSnapshot())
    val snapshot: StateFlow<MeshRuntimeSnapshot> = _snapshot.asStateFlow()

    internal fun update(next: MeshRuntimeSnapshot) {
        _snapshot.value = next
    }

    fun prepareVpnIntent(context: Context): Intent? = VpnService.prepare(context)

    fun start(context: Context) {
        val intent = Intent(context, NodeDeckVpnService::class.java).apply {
            action = NodeDeckVpnService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stop(context: Context) {
        val intent = Intent(context, NodeDeckVpnService::class.java).apply {
            action = NodeDeckVpnService.ACTION_STOP
        }
        runCatching { context.startService(intent) }
    }
}
