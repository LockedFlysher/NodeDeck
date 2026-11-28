package com.nodedeck.android.ui

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.ControlPlaneClient
import com.nodedeck.android.core.DisplayFormat
import com.nodedeck.android.mesh.MeshConnectionState
import com.nodedeck.android.mesh.MeshPeerStatus
import com.nodedeck.android.mesh.MeshRuntimeController
import com.nodedeck.android.ui.theme.NodeDeckColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(
    viewModel: MainViewModel,
    onBack: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val context = LocalContext.current
    val session by viewModel.accountSession.collectAsState()
    val accountDevices by viewModel.accountDevices.collectAsState()
    val meshSnapshot by viewModel.meshSnapshot.collectAsState()

    var authTab by remember { mutableIntStateOf(0) } // 0 = Login, 1 = Register
    var username by remember { mutableStateOf(session.username) }
    var password by remember { mutableStateOf("") }
    var inviteCode by remember { mutableStateOf("") }
    var serverUrl by remember { mutableStateOf(session.serverUrl.ifBlank { ControlPlaneClient.DEFAULT_SERVER_URL }) }
    var showServerField by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    val vpnPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            MeshRuntimeController.start(context)
        } else {
            viewModel.postFeedback(AppLocalization.t("未授予系统 VPN 权限", "VPN permission denied", lang))
        }
    }

    fun startBuiltInMesh() {
        val prepareIntent = MeshRuntimeController.prepareVpnIntent(context)
        if (prepareIntent != null) {
            vpnPermissionLauncher.launch(prepareIntent)
        } else {
            MeshRuntimeController.start(context)
        }
    }

    LaunchedEffect(meshSnapshot.state) {
        if (meshSnapshot.state == MeshConnectionState.CONNECTED) {
            viewModel.refreshAllHosts()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                title = {
                    Column {
                        Text(AppLocalization.t("账号与内置组网", "Account & Mesh", lang), fontWeight = FontWeight.Bold)
                        Text(
                            text = if (session.isLoggedIn) {
                                "${session.username} · ${session.virtualCidr.ifBlank { session.virtualIp }}"
                            } else {
                                AppLocalization.t("登录后自动加入个人加密组网，无需手动配置 EasyTier", "Sign in to auto-join your private mesh", lang)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            )
        }
    ) { padding ->
        if (!session.isLoggedIn) {
            // Unified Login + Register View
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            TabRow(selectedTabIndex = authTab) {
                                Tab(
                                    selected = authTab == 0,
                                    onClick = { authTab = 0; errorMsg = null },
                                    text = { Text(AppLocalization.t("登录", "Sign In", lang)) }
                                )
                                Tab(
                                    selected = authTab == 1,
                                    onClick = { authTab = 1; errorMsg = null },
                                    text = { Text(AppLocalization.t("邀请码注册", "Register", lang)) }
                                )
                            }

                            OutlinedTextField(
                                value = username,
                                onValueChange = { username = it },
                                label = { Text(AppLocalization.t("用户名", "Username", lang)) },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )

                            OutlinedTextField(
                                value = password,
                                onValueChange = { password = it },
                                label = { Text(AppLocalization.t("密码", "Password", lang)) },
                                singleLine = true,
                                visualTransformation = PasswordVisualTransformation(),
                                modifier = Modifier.fillMaxWidth()
                            )

                            if (authTab == 1) {
                                OutlinedTextField(
                                    value = inviteCode,
                                    onValueChange = { inviteCode = it },
                                    label = { Text(AppLocalization.t("邀请码", "Invite Code", lang)) },
                                    singleLine = true,
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }

                            TextButton(
                                onClick = { showServerField = !showServerField },
                                contentPadding = PaddingValues(0.dp)
                            ) {
                                Text(
                                    text = AppLocalization.t("控制服务器设置", "Control Server", lang),
                                    style = MaterialTheme.typography.labelMedium
                                )
                                Icon(
                                    imageVector = if (showServerField) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp)
                                )
                            }

                            if (showServerField) {
                                OutlinedTextField(
                                    value = serverUrl,
                                    onValueChange = { serverUrl = it },
                                    label = { Text("Server URL") },
                                    singleLine = true,
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }

                            errorMsg?.let { err ->
                                Text(err, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                            }

                            Button(
                                modifier = Modifier.fillMaxWidth(),
                                enabled = !busy,
                                onClick = {
                                    busy = true
                                    errorMsg = null
                                    val onDone: (Result<Unit>) -> Unit = { res ->
                                        busy = false
                                        res.onSuccess {
                                            password = ""
                                            startBuiltInMesh()
                                        }.onFailure {
                                            errorMsg = it.message ?: "Authentication failed"
                                        }
                                    }
                                    if (authTab == 0) {
                                        viewModel.loginAccount(serverUrl.trim(), username.trim(), password, onDone)
                                    } else {
                                        viewModel.registerAccount(serverUrl.trim(), username.trim(), password, inviteCode.trim(), onDone)
                                    }
                                }
                            ) {
                                if (busy) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                                    Spacer(Modifier.width(8.dp))
                                }
                                Text(
                                    if (authTab == 0) {
                                        AppLocalization.t("登录并自动组网", "Sign In & Connect Mesh", lang)
                                    } else {
                                        AppLocalization.t("注册并自动组网", "Register & Connect Mesh", lang)
                                    }
                                )
                            }

                            Text(
                                text = AppLocalization.t(
                                    "每个账号拥有独立的加密私有组网密钥与固定虚拟 IP，登录即自动同步名下计算节点与远程桌面证书，无需手动配置 EasyTier。",
                                    "Each account gets an isolated private EasyTier mesh, sticky virtual IP, automatic node discovery, and Moonlight cert pairing.",
                                    lang
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        } else {
            // Logged-in Account + Built-in Mesh Status View
            val isRunning = meshSnapshot.state == MeshConnectionState.CONNECTED || meshSnapshot.state == MeshConnectionState.CONNECTING
            val dotColor = when (meshSnapshot.state) {
                MeshConnectionState.CONNECTED -> NodeDeckColors.Online
                MeshConnectionState.CONNECTING -> NodeDeckColors.Warning
                MeshConnectionState.ERROR -> NodeDeckColors.Offline
                MeshConnectionState.STOPPED -> MaterialTheme.colorScheme.outline
            }

            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // Account + Built-in Mesh Control Card
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(12.dp)
                                        .clip(CircleShape)
                                        .background(dotColor)
                                )
                                Spacer(Modifier.width(10.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "${session.username} · ${
                                            when (meshSnapshot.state) {
                                                MeshConnectionState.CONNECTED -> AppLocalization.t("内置组网在线", "Mesh Online", lang)
                                                MeshConnectionState.CONNECTING -> AppLocalization.t("正在组网…", "Connecting…", lang)
                                                MeshConnectionState.ERROR -> AppLocalization.t("组网异常", "Mesh Error", lang)
                                                MeshConnectionState.STOPPED -> AppLocalization.t("组网已暂停", "Mesh Paused", lang)
                                            }
                                        }",
                                        style = MaterialTheme.typography.titleSmall,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    Text(
                                        text = "${session.deviceName} · ${session.virtualCidr.ifBlank { session.virtualIp }}",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Icon(Icons.Default.CloudDone, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            }

                            meshSnapshot.errorMessage?.let { err ->
                                Text(err, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                            }

                            val store = remember(context) { com.nodedeck.android.NodeDeckApp.from(context).store }
                            var alwaysOn by remember { mutableStateOf(store.isMeshAlwaysOn()) }
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = AppLocalization.t("常驻自动组网", "Always-On Mesh", lang),
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        text = AppLocalization.t("保持后台与开机自动连接加密私有网", "Keep private mesh connected automatically", lang),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Switch(
                                    checked = alwaysOn,
                                    onCheckedChange = { checked ->
                                        alwaysOn = checked
                                        store.setMeshAlwaysOn(checked)
                                        if (checked) {
                                            startBuiltInMesh()
                                        } else {
                                            MeshRuntimeController.stop(context)
                                        }
                                    }
                                )
                            }

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Button(
                                    modifier = Modifier.weight(1f),
                                    onClick = {
                                        alwaysOn = true
                                        store.setMeshAlwaysOn(true)
                                        startBuiltInMesh()
                                    }
                                ) {
                                    Icon(
                                        if (isRunning) Icons.Default.Refresh else Icons.Default.PlayArrow,
                                        contentDescription = null,
                                        modifier = Modifier.size(16.dp)
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        if (isRunning) {
                                            AppLocalization.t("重连组网", "Reconnect Mesh", lang)
                                        } else {
                                            AppLocalization.t("立即开启组网", "Connect Mesh", lang)
                                        }
                                    )
                                }
                                OutlinedButton(onClick = { viewModel.syncAccountState() }) {
                                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text(AppLocalization.t("同步", "Sync", lang))
                                }
                            }
                        }
                    }
                }

                // Account Devices Card
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(14.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Icon(Icons.Default.Devices, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                                Text(
                                    text = AppLocalization.t("账号下设备 (${accountDevices.size})", "Account Devices (${accountDevices.size})", lang),
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                            if (accountDevices.isEmpty()) {
                                Text(
                                    text = AppLocalization.t("暂无其他设备登录本账号", "No other devices signed in yet", lang),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            } else {
                                accountDevices.forEachIndexed { idx, dev ->
                                    if (idx > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(8.dp)
                                                .clip(CircleShape)
                                                .background(if (dev.online) NodeDeckColors.Online else MaterialTheme.colorScheme.outline)
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Column(modifier = Modifier.weight(1f)) {
                                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                                                Text(dev.deviceName, style = MaterialTheme.typography.titleSmall)
                                                BadgeChip(dev.platform, MaterialTheme.colorScheme.surfaceVariant)
                                                if (dev.sunshineEnabled) {
                                                    BadgeChip("Remote", MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.onPrimaryContainer)
                                                }
                                            }
                                            Text(
                                                text = dev.virtualIp + if (dev.sshUser.isNotBlank()) " · ${dev.sshUser}:${dev.sshPort}" else "",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Live P2P Mesh Peers Card
                if (meshSnapshot.peers.isNotEmpty()) {
                    item {
                        Card(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(14.dp),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                        ) {
                            Column(
                                modifier = Modifier.padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Icon(Icons.Default.Hub, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                                    Text(
                                        text = AppLocalization.t("P2P 组网链路 (${meshSnapshot.peers.size})", "P2P Mesh Links (${meshSnapshot.peers.size})", lang),
                                        style = MaterialTheme.typography.titleSmall,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                                meshSnapshot.peers.forEachIndexed { idx, peer ->
                                    if (idx > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
                                    MeshPeerItem(peer)
                                }
                            }
                        }
                    }
                }

                // Sign Out Button
                item {
                    OutlinedButton(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = {
                            MeshRuntimeController.stop(context)
                            viewModel.logoutAccount()
                        }
                    ) {
                        Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(AppLocalization.t("退出登录并断开组网", "Sign Out & Disconnect Mesh", lang), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }
}

@Composable
private fun MeshPeerItem(peer: MeshPeerStatus) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(peer.hostname, style = MaterialTheme.typography.titleSmall)
                BadgeChip(
                    text = if (peer.isDirect) "p2p" else "relay(${peer.cost})",
                    containerColor = if (peer.isDirect) NodeDeckColors.Online.copy(alpha = 0.18f) else MaterialTheme.colorScheme.surfaceVariant,
                    contentColor = if (peer.isDirect) NodeDeckColors.Online else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Text(
                text = "${peer.virtualIpv4} · RX ${DisplayFormat.bytes(peer.rxBytes)} / TX ${DisplayFormat.bytes(peer.txBytes)}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Text(
            text = if (peer.latencyMs > 0) String.format("%.1f ms", peer.latencyMs) else "—",
            style = MaterialTheme.typography.labelSmall,
            color = NodeDeckColors.Online,
            fontWeight = FontWeight.Medium
        )
    }
}
