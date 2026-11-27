package com.nodedeck.android

import android.app.Application
import android.content.Context
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.ClipboardSyncManager
import com.nodedeck.android.core.ControlPlaneClient
import com.nodedeck.android.core.LinuxHostProfileManager
import com.nodedeck.android.core.SecureStore
import com.nodedeck.android.core.SshManager
import com.nodedeck.android.core.SunshineClient

class NodeDeckApp : Application() {
    lateinit var store: SecureStore
        private set
    lateinit var sshManager: SshManager
        private set
    lateinit var sunshineClient: SunshineClient
        private set
    lateinit var clipboardSyncManager: ClipboardSyncManager
        private set
    lateinit var hostProfileManager: LinuxHostProfileManager
        private set
    lateinit var controlPlaneClient: ControlPlaneClient
        private set

    override fun onCreate() {
        super.onCreate()
        store = SecureStore(this)
        AppLocalization.setLanguage(store.getLanguage())
        sshManager = SshManager(store)
        sunshineClient = SunshineClient(store, sshManager)
        clipboardSyncManager = ClipboardSyncManager(sshManager)
        hostProfileManager = LinuxHostProfileManager(sshManager)
        controlPlaneClient = ControlPlaneClient()
    }

    companion object {
        fun from(context: Context): NodeDeckApp = context.applicationContext as NodeDeckApp
    }
}
