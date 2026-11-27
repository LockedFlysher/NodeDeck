package com.nodedeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nodedeck.android.core.AppLocalization

@Composable
fun ArchitectureGuideDialog(onDismiss: () -> Unit) {
    val lang by AppLocalization.language.collectAsState()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(AppLocalization.t("零云端架构与安全透明说明", "Zero-Cloud Architecture & Security", lang)) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                GuideBlock(
                    title = AppLocalization.t("1. 100% 本地直连，无中继无遥测", "1. 100% Local Direct, Zero Relay", lang),
                    body = AppLocalization.t(
                        "所有 SSH 会话、SFTP 文件传输、端口转发和远程桌面串流均直接在本机与您的计算节点之间建立点对点连接，不经过任何云端服务器，不收集任何遥测数据。",
                        "All SSH sessions, SFTP transfers, port forwards, and remote desktop streams connect directly between your phone and your compute nodes with zero cloud relay or telemetry.",
                        lang
                    )
                )
                GuideBlock(
                    title = AppLocalization.t("2. Android 端纯主控定位", "2. Pure Controller Role on Android", lang),
                    body = AppLocalization.t(
                        "Android 版不包含 Sunshine 被控端服务，专注于主控运维：SSH 节点监控、交互式终端、后台端口转发、SFTP 文件管理以及基于硬件 MediaCodec 解码的低延迟 Moonlight 远程桌面（支持 1080p/1440p/4K 与 60/120/144/165Hz）。",
                        "NodeDeck Android excludes the Sunshine host server and focuses on control: SSH monitoring, interactive PTY terminal, foreground port forwarding, SFTP, and MediaCodec hardware-decoded Moonlight streaming up to 4K 165Hz.",
                        lang
                    )
                )
                GuideBlock(
                    title = AppLocalization.t("3. 凭据与证书仅存本地沙箱", "3. Local Sandbox Credential Storage", lang),
                    body = AppLocalization.t(
                        "SSH 节点列表、私钥以及 Moonlight 本地自签 RSA-2048 客户端证书仅保存在应用私有目录内；Zero-PIN 配对仅复用您已授权的 SSH 连接写入远端 sunshine_state.json。",
                        "SSH hosts, private keys, and your locally generated RSA-2048 Moonlight client certificate stay strictly inside app-private storage.",
                        lang
                    )
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(AppLocalization.t("知道了", "Got It", lang))
            }
        }
    )
}

@Composable
private fun GuideBlock(title: String, body: String) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        Text(body, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
