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
        title = { Text(AppLocalization.t("技术架构与安全透明说明", "Architecture & Security Model", lang)) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                GuideBlock(
                    title = AppLocalization.t("1. 端到端加密与 P2P 优先直连", "1. End-to-End Encrypted, P2P-First Mesh", lang),
                    body = AppLocalization.t(
                        "登录自建控制面账号后自动加入个人加密 EasyTier 私有组网（优先点对点 P2P 直连，仅在严格 NAT 下走自有种子节点中继）。SSH、SFTP 与 Moonlight 串流全程端到端加密，无任何第三方遥测。",
                        "Sign in to your self-hosted control plane to auto-join a private encrypted EasyTier mesh (P2P-first, falling back to your own seed relay only behind strict NAT). Zero third-party telemetry.",
                        lang
                    )
                )
                GuideBlock(
                    title = AppLocalization.t("2. Android 端纯主控定位", "2. Pure Controller Role on Android", lang),
                    body = AppLocalization.t(
                        "Android 版不包含被控端服务，专注于主控运维：SSH 节点监控、交互式终端、后台端口转发、SFTP 文件管理以及基于硬件 MediaCodec 解码的低延迟 Moonlight 远程桌面（支持 1080p/1440p/4K 与 60/120/144/165Hz）。",
                        "NodeDeck Android excludes the host server and focuses on control: SSH monitoring, interactive PTY terminal, foreground port forwarding, SFTP, and MediaCodec hardware-decoded Moonlight streaming up to 4K 165Hz.",
                        lang
                    )
                )
                GuideBlock(
                    title = AppLocalization.t("3. 私钥不出本地，账号仅同步公钥", "3. Private Keys Stay Local", lang),
                    body = AppLocalization.t(
                        "SSH 私钥与 Moonlight RSA-2048 客户端私钥始终留在手机应用私有沙箱内绝不上传；控制面仅同步公开证书/SSH 公钥用于同账号设备免 PIN 一键配对。",
                        "SSH private keys and your Moonlight RSA-2048 private key never leave app-private storage; the control plane only exchanges public certificates/keys for zero-PIN same-account pairing.",
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
