package com.nodedeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.unit.dp
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.PortForwardDirection
import com.nodedeck.android.core.SSHPortForwardConfig

@Composable
fun PortForwardDialog(
    hostAlias: String,
    onSave: (SSHPortForwardConfig) -> Unit,
    onDismiss: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    var label by remember { mutableStateOf("Jupyter") }
    var direction by remember { mutableStateOf(PortForwardDirection.LOCAL) }
    var localPortText by remember { mutableStateOf("8888") }
    var remoteHost by remember { mutableStateOf("127.0.0.1") }
    var remotePortText by remember { mutableStateOf("8888") }
    var errorText by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(AppLocalization.t("新建 SSH 端口转发", "New SSH Port Forward", lang)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = label,
                    onValueChange = { label = it },
                    label = { Text(AppLocalization.t("名称", "Label", lang)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    PortForwardDirection.entries.forEach { dir ->
                        FilterChip(
                            selected = direction == dir,
                            onClick = { direction = dir },
                            label = { Text(dir.flag) }
                        )
                    }
                }
                OutlinedTextField(
                    value = localPortText,
                    onValueChange = { localPortText = it.filter { ch -> ch.isDigit() } },
                    label = {
                        Text(
                            if (direction == PortForwardDirection.DYNAMIC) {
                                AppLocalization.t("本地 SOCKS5 端口", "Local SOCKS5 Port", lang)
                            } else {
                                AppLocalization.t("本地端口", "Local Port", lang)
                            }
                        )
                    },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                if (direction != PortForwardDirection.DYNAMIC) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = remoteHost,
                            onValueChange = { remoteHost = it },
                            label = { Text(AppLocalization.t("远端地址", "Remote Host", lang)) },
                            singleLine = true,
                            modifier = Modifier.weight(1.4f)
                        )
                        OutlinedTextField(
                            value = remotePortText,
                            onValueChange = { remotePortText = it.filter { ch -> ch.isDigit() } },
                            label = { Text(AppLocalization.t("远端端口", "Remote Port", lang)) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
                errorText?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                val lp = localPortText.toIntOrNull()
                val rp = remotePortText.toIntOrNull() ?: 8888
                if (lp == null || lp !in 1..65535) {
                    errorText = AppLocalization.t("请输入有效端口 (1-65535)", "Enter a valid port (1-65535)", lang)
                    return@Button
                }
                onSave(
                    SSHPortForwardConfig(
                        hostAlias = hostAlias,
                        label = label.trim().ifBlank { "${direction.flag} $lp" },
                        direction = direction,
                        localPort = lp,
                        remoteHost = remoteHost.trim().ifBlank { "127.0.0.1" },
                        remotePort = rp.coerceIn(1, 65535)
                    )
                )
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
