package com.nodedeck.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.stream.StreamActivity
import com.nodedeck.android.ui.AccountScreen
import com.nodedeck.android.ui.ArchitectureGuideDialog
import com.nodedeck.android.ui.HostDetailScreen
import com.nodedeck.android.ui.HostEditorDialog
import com.nodedeck.android.ui.HostListScreen
import com.nodedeck.android.ui.ImportSshConfigDialog
import com.nodedeck.android.ui.MainViewModel
import com.nodedeck.android.ui.SftpBrowserScreen
import com.nodedeck.android.ui.TerminalScreen
import com.nodedeck.android.ui.theme.NodeDeckTheme

private sealed class AppScreen {
    data object HostList : AppScreen()
    data object Account : AppScreen()
    data class HostDetail(val hostId: String) : AppScreen()
    data class Terminal(val hostId: String, val returnToDetail: Boolean) : AppScreen()
    data class Sftp(val hostId: String, val initialPath: String) : AppScreen()
}

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            NodeDeckTheme {
                val hosts by viewModel.hosts.collectAsState()
                val resolution by viewModel.streamResolution.collectAsState()
                val refreshRate by viewModel.streamRefreshRate.collectAsState()

                var screen by remember { mutableStateOf<AppScreen>(AppScreen.HostList) }
                var editingHost by remember { mutableStateOf<SSHHost?>(null) }
                var showAddEditor by remember { mutableStateOf(false) }
                var showImportDialog by remember { mutableStateOf(false) }
                var showGuideDialog by remember { mutableStateOf(false) }

                BackHandler(enabled = screen !is AppScreen.HostList) {
                    screen = when (val s = screen) {
                        is AppScreen.HostList -> AppScreen.HostList
                        is AppScreen.Account -> AppScreen.HostList
                        is AppScreen.HostDetail -> AppScreen.HostList
                        is AppScreen.Terminal -> if (s.returnToDetail) AppScreen.HostDetail(s.hostId) else AppScreen.HostList
                        is AppScreen.Sftp -> AppScreen.HostDetail(s.hostId)
                    }
                }

                when (val s = screen) {
                    is AppScreen.HostList -> {
                        HostListScreen(
                            viewModel = viewModel,
                            onSelectHost = { host -> screen = AppScreen.HostDetail(host.id) },
                            onQuickTerminal = { host -> screen = AppScreen.Terminal(host.id, returnToDetail = false) },
                            onQuickStream = { host, sunshine ->
                                startActivity(
                                    StreamActivity.createIntent(
                                        context = this,
                                        hostId = host.id,
                                        address = sunshine.address,
                                        httpPort = sunshine.httpPort,
                                        width = resolution.width,
                                        height = resolution.height,
                                        fps = refreshRate.fps
                                    )
                                )
                            },
                            onAddHost = {
                                editingHost = null
                                showAddEditor = true
                            },
                            onImportSshConfig = { showImportDialog = true },
                            onOpenAccount = { screen = AppScreen.Account },
                            onOpenGuide = { showGuideDialog = true }
                        )
                    }

                    is AppScreen.Account -> {
                        AccountScreen(
                            viewModel = viewModel,
                            onBack = { screen = AppScreen.HostList }
                        )
                    }

                    is AppScreen.HostDetail -> {
                        HostDetailScreen(
                            hostId = s.hostId,
                            viewModel = viewModel,
                            onBack = { screen = AppScreen.HostList },
                            onOpenTerminal = { host -> screen = AppScreen.Terminal(host.id, returnToDetail = true) },
                            onOpenSftp = { host, path -> screen = AppScreen.Sftp(host.id, path) },
                            onLaunchStream = { host, sunshine, res, rate ->
                                startActivity(
                                    StreamActivity.createIntent(
                                        context = this,
                                        hostId = host.id,
                                        address = sunshine.address,
                                        httpPort = sunshine.httpPort,
                                        width = res.width,
                                        height = res.height,
                                        fps = rate.fps
                                    )
                                )
                            },
                            onEditHost = { host ->
                                editingHost = host
                                showAddEditor = true
                            }
                        )
                    }

                    is AppScreen.Terminal -> {
                        val host = hosts.firstOrNull { it.id == s.hostId }
                        if (host == null) {
                            screen = AppScreen.HostList
                        } else {
                            TerminalScreen(
                                host = host,
                                allHosts = hosts,
                                viewModel = viewModel,
                                onBack = {
                                    screen = if (s.returnToDetail) AppScreen.HostDetail(s.hostId) else AppScreen.HostList
                                }
                            )
                        }
                    }

                    is AppScreen.Sftp -> {
                        val host = hosts.firstOrNull { it.id == s.hostId }
                        if (host == null) {
                            screen = AppScreen.HostList
                        } else {
                            SftpBrowserScreen(
                                host = host,
                                allHosts = hosts,
                                initialPath = s.initialPath,
                                viewModel = viewModel,
                                onBack = { screen = AppScreen.HostDetail(s.hostId) }
                            )
                        }
                    }
                }

                if (showAddEditor) {
                    HostEditorDialog(
                        initialHost = editingHost,
                        existingKeys = viewModel.listPrivateKeys(),
                        onSavePrivateKey = { name, pem -> viewModel.savePrivateKey(name, pem) },
                        onSave = { host ->
                            viewModel.upsertHost(host)
                            showAddEditor = false
                            editingHost = null
                        },
                        onDismiss = {
                            showAddEditor = false
                            editingHost = null
                        }
                    )
                }

                if (showImportDialog) {
                    ImportSshConfigDialog(
                        onImport = { raw -> viewModel.importSshConfigText(raw) },
                        onDismiss = { showImportDialog = false }
                    )
                }

                if (showGuideDialog) {
                    ArchitectureGuideDialog(onDismiss = { showGuideDialog = false })
                }
            }
        }
    }
}
