package com.nodedeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.SSHAuthType
import com.nodedeck.android.core.SSHHost

@Composable
fun HostEditorDialog(
    initialHost: SSHHost?,
    existingKeys: List<String>,
    onSavePrivateKey: (name: String, pem: String) -> String,
    onSave: (SSHHost) -> Unit,
    onDismiss: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    var alias by remember { mutableStateOf(initialHost?.alias.orEmpty()) }
    var hostName by remember { mutableStateOf(initialHost?.hostName.orEmpty()) }
    var user by remember { mutableStateOf(initialHost?.user ?: "root") }
    var portText by remember { mutableStateOf((initialHost?.port ?: 22).toString()) }
    var authType by remember { mutableStateOf(initialHost?.authType ?: SSHAuthType.PASSWORD) }
    var password by remember { mutableStateOf(initialHost?.password.orEmpty()) }
    var keyName by remember { mutableStateOf(initialHost?.privateKeyName.orEmpty()) }
    var keyPem by remember { mutableStateOf("") }
    var keyPassphrase by remember { mutableStateOf(initialHost?.privateKeyPassphrase.orEmpty()) }
    var proxyJump by remember { mutableStateOf(initialHost?.proxyJumpAlias.orEmpty()) }
    var errorText by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                if (initialHost == null) {
                    AppLocalization.t("添加 SSH 节点", "Add SSH Host", lang)
                } else {
                    AppLocalization.t("激活主机 SSH / 编辑节点", "Activate Host SSH / Edit", lang)
                }
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = AppLocalization.t(
                        "输入目标电脑的 SSH 登录密码（或配置私钥）保存后，将立即激活 CPU/GPU 性能面板、终端与文件浏览。若提示 22 端口拒绝连接，请先在目标电脑 NodeDeck 点击「激活主机 SSH」。",
                        "Enter the target PC's SSH password (or private key) to unlock live CPU/GPU metrics, terminal, and SFTP. If port 22 is refused, click 'Activate Host SSH' on the target PC first.",
                        lang
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = alias,
                    onValueChange = { alias = it },
                    label = { Text(AppLocalization.t("节点别名 (Alias)", "Alias", lang)) },
                    placeholder = { Text("gpu-node / lab-server") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = hostName,
                    onValueChange = { hostName = it },
                    label = { Text(AppLocalization.t("主机地址 (IP 或域名)", "Hostname / IP", lang)) },
                    placeholder = { Text("192.168.1.100") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = user,
                        onValueChange = { user = it },
                        label = { Text(AppLocalization.t("用户名", "User", lang)) },
                        singleLine = true,
                        modifier = Modifier.weight(1.4f)
                    )
                    OutlinedTextField(
                        value = portText,
                        onValueChange = { portText = it.filter { ch -> ch.isDigit() } },
                        label = { Text(AppLocalization.t("端口", "Port", lang)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(1f)
                    )
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = authType == SSHAuthType.PASSWORD,
                        onClick = { authType = SSHAuthType.PASSWORD },
                        label = { Text(AppLocalization.t("密码认证", "Password", lang)) }
                    )
                    FilterChip(
                        selected = authType == SSHAuthType.PRIVATE_KEY,
                        onClick = { authType = SSHAuthType.PRIVATE_KEY },
                        label = { Text(AppLocalization.t("私钥认证", "Private Key", lang)) }
                    )
                }

                if (authType == SSHAuthType.PASSWORD) {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text(AppLocalization.t("SSH 密码", "SSH Password", lang)) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth()
                    )
                } else {
                    if (existingKeys.isNotEmpty()) {
                        Text(
                            text = AppLocalization.t("已有本地私钥：", "Saved keys:", lang),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            existingKeys.take(3).forEach { k ->
                                FilterChip(
                                    selected = keyName == k,
                                    onClick = { keyName = k },
                                    label = { Text(k) }
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value = keyName,
                        onValueChange = { keyName = it },
                        label = { Text(AppLocalization.t("私钥名称", "Key Name", lang)) },
                        placeholder = { Text("id_ed25519") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = keyPem,
                        onValueChange = { keyPem = it },
                        label = { Text(AppLocalization.t("粘贴私钥内容 (PEM/OpenSSH，留空则沿用已存私钥)", "Paste Private Key PEM (optional if saved)", lang)) },
                        minLines = 3,
                        maxLines = 5,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = keyPassphrase,
                        onValueChange = { keyPassphrase = it },
                        label = { Text(AppLocalization.t("私钥口令 (可选)", "Passphrase (optional)", lang)) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth()
                    )
                }

                OutlinedTextField(
                    value = proxyJump,
                    onValueChange = { proxyJump = it },
                    label = { Text("ProxyJump (${AppLocalization.t("跳板机别名，可选", "optional jump alias", lang)})") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                errorText?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                val cleanHost = hostName.trim()
                val cleanAlias = alias.trim().ifBlank { cleanHost }
                if (cleanHost.isBlank()) {
                    errorText = AppLocalization.t("请填写主机地址", "Hostname is required", lang)
                    return@Button
                }
                val port = portText.toIntOrNull()?.coerceIn(1, 65535) ?: 22
                var resolvedKeyName = keyName.trim()
                if (authType == SSHAuthType.PRIVATE_KEY && keyPem.isNotBlank()) {
                    resolvedKeyName = onSavePrivateKey(resolvedKeyName.ifBlank { "${cleanAlias}_key" }, keyPem)
                }
                val host = (initialHost ?: SSHHost(alias = cleanAlias, hostName = cleanHost)).copy(
                    alias = cleanAlias,
                    hostName = cleanHost,
                    user = user.trim().ifBlank { "root" },
                    port = port,
                    authType = authType,
                    password = password,
                    privateKeyName = resolvedKeyName,
                    privateKeyPassphrase = keyPassphrase,
                    proxyJumpAlias = proxyJump.trim()
                )
                onSave(host)
            }) {
                Text(AppLocalization.t("保存", "Save", lang))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(AppLocalization.t("取消", "Cancel", lang))
            }
        }
    )
}

@Composable
fun ImportSshConfigDialog(
    onImport: (String) -> Int,
    onDismiss: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    var rawText by remember { mutableStateOf("") }
    var statusText by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(AppLocalization.t("从 ~/.ssh/config 导入", "Import ~/.ssh/config", lang)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = AppLocalization.t(
                        "直接粘贴你的 SSH config 片段（支持 Host / HostName / User / Port / ProxyJump），导入后可在节点编辑中补充密码或私钥。",
                        "Paste SSH config blocks (Host, HostName, User, Port, ProxyJump). You can attach keys or passwords per node afterward.",
                        lang
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = rawText,
                    onValueChange = { rawText = it },
                    minLines = 6,
                    maxLines = 10,
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = {
                        Text("Host gpu-node\n  HostName 192.0.2.10\n  User ubuntu\n  Port 22")
                    }
                )
                statusText?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                val count = onImport(rawText)
                if (count > 0) {
                    onDismiss()
                } else {
                    statusText = AppLocalization.t("未解析到有效 Host 配置", "No valid Host entries found", lang)
                }
            }) {
                Text(AppLocalization.t("导入节点", "Import", lang))
            }
        },
        dismissButton = {
            OutlinedButton(onClick = onDismiss) {
                Text(AppLocalization.t("取消", "Cancel", lang))
            }
        }
    )
}
