package com.nodedeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.LinuxHostDisplayMode
import com.nodedeck.android.core.LinuxHostProfile
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.core.SunshineClient
import com.nodedeck.android.core.SunshineHostConfig

@Composable
fun SunshinePairDialog(
    host: SSHHost,
    existingConfig: SunshineHostConfig?,
    viewModel: MainViewModel,
    onDismiss: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val accountSession by viewModel.accountSession.collectAsState()
    // 0 = 1-Tap Account Activation (Mode A, zero SSH/sudo/PIN), 1 = Zero-PIN SSH, 2 = 4-digit PIN
    var mode by remember { mutableIntStateOf(if (accountSession.isLoggedIn) 0 else 1) }
    var address by remember { mutableStateOf(existingConfig?.address ?: host.hostName) }
    var httpPortText by remember { mutableStateOf((existingConfig?.httpPort ?: 47989).toString()) }
    var pin by remember { mutableStateOf(SunshineClient.generateRandomPin()) }
    var busy by remember { mutableStateOf(false) }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(AppLocalization.t("配对远程桌面主机", "Pair Remote Desktop Host", lang)) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilterChip(
                        selected = mode == 0,
                        onClick = { if (!busy) { mode = 0; errorMsg = null } },
                        label = { Text(AppLocalization.t("账号激活", "Account", lang)) }
                    )
                    FilterChip(
                        selected = mode == 1,
                        onClick = { if (!busy) { mode = 1; errorMsg = null } },
                        label = { Text(AppLocalization.t("SSH 直配", "SSH", lang)) }
                    )
                    FilterChip(
                        selected = mode == 2,
                        onClick = { if (!busy) { mode = 2; errorMsg = null } },
                        label = { Text(AppLocalization.t("PIN 配对", "PIN", lang)) }
                    )
                }

                when (mode) {
                    0 -> {
                        Text(
                            text = if (accountSession.isLoggedIn) {
                                AppLocalization.t(
                                    "使用已登录账号（${accountSession.username}）自动同步手机证书并远程激活 ${host.alias} 的被控服务，全程免 SSH、免 sudo、免输入系统密码。",
                                    "Uses your signed-in NodeDeck account (${accountSession.username}) to push this phone's certificate and activate ${host.alias} automatically — no SSH, sudo, or PIN required.",
                                    lang
                                )
                            } else {
                                AppLocalization.t(
                                    "当前未登录 NodeDeck 账号。请先在首页右上角登录同一账号，或切换到 SSH / PIN 备用配对方式。",
                                    "Not signed in to a NodeDeck account. Sign in from the home screen first, or switch to SSH / PIN fallback.",
                                    lang
                                )
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    1 -> {
                        Text(
                            text = AppLocalization.t(
                                "复用当前 SSH 信任链，自动将本机生成的 RSA-2048 证书注入远端 sunshine_state.json 并重载 nodedeck-host / sunshine。",
                                "Reuses your trusted SSH session to inject this device's local RSA-2048 certificate into remote sunshine_state.json and reload the host service.",
                                lang
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        OutlinedTextField(
                            value = httpPortText,
                            onValueChange = { httpPortText = it.filter { ch -> ch.isDigit() } },
                            label = { Text(AppLocalization.t("默认端口 (会自动读取远端 conf 覆盖)", "Default HTTP Port", lang)) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                    else -> {
                        Text(
                            text = AppLocalization.t(
                                "请在远端 Sunshine / NodeDeck Host Web 控制台的 PIN 页面输入以下 4 位数字，然后点击“开始 PIN 配对”：",
                                "Enter this 4-digit PIN in the remote Sunshine Web UI, then tap Start PIN Pairing:",
                                lang
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = pin,
                            fontSize = 28.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.primary
                        )
                        OutlinedTextField(
                            value = address,
                            onValueChange = { address = it },
                            label = { Text(AppLocalization.t("主机地址", "Host Address", lang)) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedTextField(
                            value = httpPortText,
                            onValueChange = { httpPortText = it.filter { ch -> ch.isDigit() } },
                            label = { Text("HTTP Port") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }

                errorMsg?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            Button(
                enabled = !busy && (mode != 0 || accountSession.isLoggedIn),
                onClick = {
                    val port = httpPortText.toIntOrNull()?.coerceIn(1, 65535) ?: 47989
                    busy = true
                    errorMsg = null
                    when (mode) {
                        0 -> {
                            viewModel.pairViaAccount(host) { res ->
                                busy = false
                                res.onSuccess { onDismiss() }
                                    .onFailure { errorMsg = it.message ?: "Account activation failed" }
                            }
                        }
                        1 -> {
                            viewModel.pairZeroPinViaSsh(host, port) { res ->
                                busy = false
                                res.onSuccess { onDismiss() }
                                    .onFailure { errorMsg = it.message ?: "Zero-PIN pairing failed" }
                            }
                        }
                        else -> {
                            viewModel.pairWithPin(host.alias, address.trim(), port, pin) { res ->
                                busy = false
                                res.onSuccess { onDismiss() }
                                    .onFailure { errorMsg = it.message ?: "PIN pairing failed" }
                            }
                        }
                    }
                }
            ) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    when (mode) {
                        0 -> AppLocalization.t("账号一键激活配对", "1-Tap Activate", lang)
                        1 -> AppLocalization.t("一键 SSH 配对", "Pair via SSH", lang)
                        else -> AppLocalization.t("开始 PIN 配对", "Start PIN Pair", lang)
                    }
                )
            }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = onDismiss) {
                Text(AppLocalization.t("取消", "Cancel", lang))
            }
        }
    )
}

@Composable
fun LinuxHostProfileDialog(
    host: SSHHost,
    initialProfile: LinuxHostProfile,
    viewModel: MainViewModel,
    onDismiss: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    var mode by remember { mutableStateOf(initialProfile.mode) }
    var display by remember { mutableStateOf(initialProfile.display) }
    var basePort by remember { mutableStateOf(initialProfile.basePort.toString()) }
    var encoder by remember { mutableStateOf(initialProfile.encoder) }
    var drmNode by remember { mutableStateOf(initialProfile.drmRenderNode) }
    var virtualAudio by remember { mutableStateOf(initialProfile.virtualAudioSink) }
    var clipboardSync by remember { mutableStateOf(initialProfile.clipboardSync) }
    var busy by remember { mutableStateOf(false) }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(AppLocalization.t("Linux 多用户主机隔离配置", "Linux Host Isolation Profile", lang)) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = mode == LinuxHostDisplayMode.PHYSICAL_DESKTOP,
                        onClick = { mode = LinuxHostDisplayMode.PHYSICAL_DESKTOP },
                        label = { Text(AppLocalization.t("物理桌面", "Physical", lang)) }
                    )
                    FilterChip(
                        selected = mode == LinuxHostDisplayMode.ISOLATED_VIRTUAL_DESKTOP,
                        onClick = { mode = LinuxHostDisplayMode.ISOLATED_VIRTUAL_DESKTOP },
                        label = { Text(AppLocalization.t("虚拟隔离桌面", "Isolated Virtual", lang)) }
                    )
                }

                OutlinedTextField(
                    value = basePort,
                    onValueChange = { basePort = it.filter { ch -> ch.isDigit() } },
                    label = { Text(AppLocalization.t("起始端口 (Base Port)", "Base Port", lang)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = encoder,
                    onValueChange = { encoder = it },
                    label = { Text("Encoder (nvenc / vaapi / software)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                if (mode == LinuxHostDisplayMode.ISOLATED_VIRTUAL_DESKTOP) {
                    OutlinedTextField(
                        value = display,
                        onValueChange = { display = it },
                        label = { Text("X11 Display (:99)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = drmNode,
                        onValueChange = { drmNode = it },
                        label = { Text("DRM Render Node (/dev/dri/renderD128)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(AppLocalization.t("虚拟音频 Sink", "Virtual Audio Sink", lang), style = MaterialTheme.typography.bodySmall)
                    Switch(checked = virtualAudio, onCheckedChange = { virtualAudio = it })
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(AppLocalization.t("剪贴板同步", "Clipboard Sync", lang), style = MaterialTheme.typography.bodySmall)
                    Switch(checked = clipboardSync, onCheckedChange = { clipboardSync = it })
                }

                errorMsg?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            Button(
                enabled = !busy,
                onClick = {
                    val profile = initialProfile.copy(
                        mode = mode,
                        display = display.trim().ifBlank { ":99" },
                        basePort = basePort.toIntOrNull()?.coerceIn(1024, 65000) ?: 47989,
                        encoder = encoder.trim().ifBlank { "nvenc" },
                        drmRenderNode = drmNode.trim(),
                        virtualAudioSink = virtualAudio,
                        clipboardSync = clipboardSync
                    )
                    busy = true
                    errorMsg = null
                    viewModel.saveAndReconcileHostProfile(profile, host) { res ->
                        busy = false
                        res.onSuccess { onDismiss() }
                            .onFailure { errorMsg = it.message ?: "Sync failed" }
                    }
                }
            ) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(6.dp))
                }
                Text(AppLocalization.t("同步到远端", "Sync via SSH", lang))
            }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = onDismiss) {
                Text(AppLocalization.t("取消", "Cancel", lang))
            }
        }
    )
}
