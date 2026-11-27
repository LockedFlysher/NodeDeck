package com.nodedeck.android.mesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.nodedeck.android.NodeDeckApp

/**
 * Automatically resumes built-in EasyTier split-tunnel VPN after device reboot or app update
 * when the user is signed in, always-on mesh is enabled, and VPN consent was already granted.
 */
class MeshBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        val app = NodeDeckApp.from(context)
        val session = app.store.loadAccountSession()
        val cfg = app.store.loadMeshConfig()
        if (session.isLoggedIn &&
            app.store.isMeshAlwaysOn() &&
            cfg.isConfigured &&
            MeshRuntimeController.prepareVpnIntent(context) == null
        ) {
            MeshRuntimeController.start(context)
        }
    }
}
