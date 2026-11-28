package com.nodedeck.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nodedeck.android.core.AppLanguage
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.DisplayFormat
import com.nodedeck.android.core.GPUInfo
import com.nodedeck.android.core.HostConnectionState
import com.nodedeck.android.core.HostSnapshot
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.core.SSHPortForwardConfig
import com.nodedeck.android.core.StreamQualityMath
import com.nodedeck.android.core.StreamRefreshRate
import com.nodedeck.android.core.StreamResolutionPreset
import com.nodedeck.android.core.SunshineHostConfig
import com.nodedeck.android.ui.theme.NodeDeckColors
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostDetailScreen(
    hostId: String,
    viewModel: MainViewModel,
    onBack: () -> Unit,
    onOpenTerminal: (SSHHost) -> Unit,
    onOpenSftp: (SSHHost, String) -> Unit,
    onLaunchStream: (SSHHost, SunshineHostConfig, StreamResolutionPreset, StreamRefreshRate) -> Unit,
    onEditHost: (SSHHost) -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val hosts by viewModel.hosts.collectAsState()
    val snapshots by viewModel.snapshots.collectAsState()
    val sunshineConfigs by viewModel.sunshineConfigs.collectAsState()
    val portForwards by viewModel.portForwards.collectAsState()
    val activeForwardIds by viewModel.activeForwardIds.collectAsState()
    val resolution by viewModel.streamResolution.collectAsState()
    val refreshRate by viewModel.streamRefreshRate.collectAsState()
    val accountSession by viewModel.accountSession.collectAsState()

    val host = hosts.firstOrNull { it.id == hostId }
    if (host == null) {
        onBack()
        return
    }
    val snapshot = snapshots[host.id] ?: HostSnapshot(host = host)
    val sunshine = sunshineConfigs.firstOrNull {
        it.hostAlias.equals(host.alias, ignoreCase = true) ||
            it.address.equals(host.hostName, ignoreCase = true)
    }
    val hostForwards = portForwards.filter { it.hostAlias.equals(host.alias, ignoreCase = true) }

    var selectedTab by remember { mutableIntStateOf(0) }
    var showPairDialog by remember { mutableStateOf(false) }
    var showProfileDialog by remember { mutableStateOf(false) }
    var showAddForwardDialog by remember { mutableStateOf(false) }
    var isAccountActivating by remember { mutableStateOf(false) }
    var accountActivateError by remember { mutableStateOf<String?>(null) }

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
                        Text(host.alias, fontWeight = FontWeight.Bold)
                        Text(
                            text = host.loginTarget,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { onEditHost(host) }) {
                        Icon(Icons.Default.Edit, contentDescription = "Edit")
                    }
                    IconButton(onClick = { viewModel.refreshHost(host.id) }) {
                        if (snapshot.state == HostConnectionState.CHECKING) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                        }
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            TabRow(selectedTabIndex = selectedTab) {
                Tab(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    text = {
                        Text(
                            text = AppLocalization.t("总览", "Overview", lang),
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                )
                Tab(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    text = {
                        Text(
                            text = AppLocalization.t("远控与网络", "Remote", lang),
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                )
                Tab(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    text = {
                        Text(
                            text = AppLocalization.t("终端与文件", "Files", lang),
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                )
            }

            when (selectedTab) {
                0 -> OverviewTab(
                    snapshot = snapshot,
                    lang = lang,
                    onRefresh = { viewModel.refreshHost(host.id) },
                    onOpenRemoteTab = { selectedTab = 1 }
                )
                1 -> RemoteAndNetworkTab(
                    host = host,
                    sunshine = sunshine,
                    accountLoggedIn = accountSession.isLoggedIn,
                    accountUsername = accountSession.username,
                    isAccountActivating = isAccountActivating,
                    accountActivateError = accountActivateError,
                    resolution = resolution,
                    refreshRate = refreshRate,
                    forwards = hostForwards,
                    activeForwardIds = activeForwardIds,
                    lang = lang,
                    onSelectResolution = { viewModel.setStreamResolution(it) },
                    onSelectRefreshRate = { viewModel.setStreamRefreshRate(it) },
                    onLaunchStream = { cfg -> onLaunchStream(host, cfg, resolution, refreshRate) },
                    onQuickAccountActivate = {
                        isAccountActivating = true
                        accountActivateError = null
                        viewModel.pairViaAccount(host) { res ->
                            isAccountActivating = false
                            res.onFailure { accountActivateError = it.message ?: "Account activation failed" }
                        }
                    },
                    onOpenPair = { showPairDialog = true },
                    onUnpair = { viewModel.removeSunshineConfig(host.alias) },
                    onOpenProfile = { showProfileDialog = true },
                    onAddForward = { showAddForwardDialog = true },
                    onToggleForward = { cfg -> viewModel.togglePortForward(cfg, host) },
                    onDeleteForward = { id -> viewModel.deletePortForward(id) }
                )
                2 -> FilesAndToolsTab(
                    host = host,
                    snapshot = snapshot,
                    lang = lang,
                    onOpenTerminal = { onOpenTerminal(host) },
                    onOpenSftp = { path -> onOpenSftp(host, path) },
                    onEditHost = { onEditHost(host) },
                    onDeleteHost = {
                        viewModel.deleteHost(host.id)
                        onBack()
                    }
                )
            }
        }
    }

    if (showPairDialog) {
        SunshinePairDialog(
            host = host,
            existingConfig = sunshine,
            viewModel = viewModel,
            onDismiss = { showPairDialog = false }
        )
    }

    if (showProfileDialog) {
        LinuxHostProfileDialog(
            host = host,
            initialProfile = viewModel.profileForHost(host.alias),
            viewModel = viewModel,
            onDismiss = { showProfileDialog = false }
        )
    }

    if (showAddForwardDialog) {
        PortForwardDialog(
            hostAlias = host.alias,
            onSave = { cfg ->
                viewModel.savePortForward(cfg)
                showAddForwardDialog = false
            },
            onDismiss = { showAddForwardDialog = false }
        )
    }
}

@Composable
private fun OverviewTab(
    snapshot: HostSnapshot,
    lang: AppLanguage,
    onRefresh: () -> Unit,
    onOpenRemoteTab: () -> Unit
) {
    val metrics = snapshot.metrics
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (metrics == null) {
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = when (snapshot.state) {
                                HostConnectionState.CHECKING -> AppLocalization.t("正在探测节点状态…", "Probing node status…", lang)
                                HostConnectionState.ONLINE -> AppLocalization.t("远程桌面已在线（未启用 SSH 指标）", "Remote Desktop Online (SSH metrics off)", lang)
                                HostConnectionState.OFFLINE -> AppLocalization.t("节点当前离线或认证失败", "Node offline or auth failed", lang)
                                else -> AppLocalization.t("尚未采集指标", "Metrics not fetched yet", lang)
                            },
                            style = MaterialTheme.typography.titleSmall
                        )
                        if (snapshot.state == HostConnectionState.ONLINE) {
                            Text(
                                text = AppLocalization.t(
                                    "该设备已通过 NodeDeck 账号就绪，可直接切换到「远控与网络」连接桌面，无需安装或配置 SSH。",
                                    "This host is ready for remote desktop via your NodeDeck account — no SSH required.",
                                    lang
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        } else {
                            snapshot.errorMessage?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (snapshot.state == HostConnectionState.ONLINE) {
                                Button(onClick = onOpenRemoteTab) {
                                    Text(AppLocalization.t("前往远控桌面", "Open Remote Tab", lang))
                                }
                            }
                            OutlinedButton(onClick = onRefresh) {
                                Text(AppLocalization.t("立即刷新", "Probe Now", lang))
                            }
                        }
                    }
                }
            }
            return@LazyColumn
        }

        // System summary card
        item {
            SectionCard(title = AppLocalization.t("系统信息", "System Info", lang)) {
                KeyValueRow(AppLocalization.t("主机名", "Hostname", lang), metrics.hostname)
                KeyValueRow(AppLocalization.t("系统", "OS", lang), "${metrics.os} (${metrics.arch})")
                KeyValueRow(AppLocalization.t("内核", "Kernel", lang), metrics.kernel)
                KeyValueRow(AppLocalization.t("运行时长", "Uptime", lang), DisplayFormat.uptime(metrics.uptimeSeconds))
                snapshot.latencyMs?.let {
                    KeyValueRow("SSH RTT", DisplayFormat.latency(it))
                }
            }
        }

        // CPU / RAM / Disk
        item {
            SectionCard(title = AppLocalization.t("算力与存储", "Compute & Storage", lang)) {
                MetricProgressRow(
                    title = "CPU (${metrics.cpuCores} cores)",
                    detail = "${metrics.cpuUsage.roundToInt()}% · Load ${String.format("%.2f / %.2f / %.2f", metrics.load1, metrics.load5, metrics.load15)}",
                    fraction = (metrics.cpuUsage / 100.0).toFloat().coerceIn(0f, 1f),
                    color = MaterialTheme.colorScheme.primary
                )
                if (metrics.cpuModel.isNotBlank()) {
                    Text(metrics.cpuModel, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.height(6.dp))
                MetricProgressRow(
                    title = AppLocalization.t("内存", "Memory", lang),
                    detail = "${DisplayFormat.bytes(metrics.memUsedBytes)} / ${DisplayFormat.bytes(metrics.memTotalBytes)}",
                    fraction = metrics.memoryFraction.toFloat(),
                    color = MaterialTheme.colorScheme.secondary
                )
                if (metrics.swapTotalBytes > 0) {
                    val swapUsed = (metrics.swapTotalBytes - metrics.swapFreeBytes).coerceAtLeast(0L)
                    Text(
                        text = "Swap: ${DisplayFormat.bytes(swapUsed)} / ${DisplayFormat.bytes(metrics.swapTotalBytes)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.height(6.dp))
                MetricProgressRow(
                    title = AppLocalization.t("根磁盘 /", "Disk /", lang),
                    detail = "${DisplayFormat.bytes(metrics.diskUsedBytes)} / ${DisplayFormat.bytes(metrics.diskTotalBytes)}",
                    fraction = metrics.diskFraction.toFloat(),
                    color = NodeDeckColors.Warning
                )
            }
        }

        // GPUs
        if (metrics.gpus.isNotEmpty()) {
            item {
                SectionCard(title = "GPU (${metrics.gpus.size})") {
                    metrics.gpus.forEachIndexed { idx, gpu ->
                        if (idx > 0) HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        GpuRow(gpu)
                    }
                }
            }
        }

        // Slurm cluster nodes
        if (metrics.slurmNodes.isNotEmpty()) {
            item {
                SectionCard(title = "Slurm (${metrics.slurmNodes.size})") {
                    metrics.slurmNodes.take(12).forEach { node ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("${node.name} (${node.partition})", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
                            Text(
                                text = "${node.state} · CPU ${node.cpusAllocated}/${node.cpusTotal}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        }

        // Top Processes
        if (metrics.processes.isNotEmpty()) {
            item {
                SectionCard(title = AppLocalization.t("高负载进程", "Top Processes", lang)) {
                    metrics.processes.forEach { proc ->
                        val shortName = proc.command
                            .trim()
                            .substringBefore(' ')
                            .substringAfterLast('/')
                            .ifBlank { proc.command.trim() }
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = shortName,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Text(
                                text = "CPU ${String.format("%.1f", proc.cpuPercent)}% · MEM ${String.format("%.1f", proc.memPercent)}%",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GpuRow(gpu: GPUInfo) {
    val accent = if (gpu.isAMD) NodeDeckColors.GpuAmd else NodeDeckColors.GpuNvidia
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(gpu.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            if (gpu.isSleeping) {
                BadgeChip("Sleep", MaterialTheme.colorScheme.surfaceVariant)
            } else {
                val stats = buildList {
                    gpu.temperatureC?.let { add("${it.roundToInt()}°C") }
                    gpu.powerW?.let { add("${it.roundToInt()}W") }
                }.joinToString(" · ")
                if (stats.isNotEmpty()) {
                    Text(stats, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        gpu.utilization?.let { util ->
            MetricProgressRow(
                title = "Core",
                detail = "${util.roundToInt()}%",
                fraction = (util / 100.0).toFloat().coerceIn(0f, 1f),
                color = accent
            )
        }
        gpu.memoryFraction?.let { frac ->
            val usedGb = (gpu.memoryUsedMB ?: 0.0) / 1024.0
            val totalGb = (gpu.memoryTotalMB ?: 0.0) / 1024.0
            MetricProgressRow(
                title = "VRAM",
                detail = String.format("%.1f / %.1f GB", usedGb, totalGb),
                fraction = frac.toFloat(),
                color = accent.copy(alpha = 0.78f)
            )
        }
    }
}

@Composable
private fun RemoteAndNetworkTab(
    host: SSHHost,
    sunshine: SunshineHostConfig?,
    accountLoggedIn: Boolean,
    accountUsername: String,
    isAccountActivating: Boolean,
    accountActivateError: String?,
    resolution: StreamResolutionPreset,
    refreshRate: StreamRefreshRate,
    forwards: List<SSHPortForwardConfig>,
    activeForwardIds: Set<String>,
    lang: AppLanguage,
    onSelectResolution: (StreamResolutionPreset) -> Unit,
    onSelectRefreshRate: (StreamRefreshRate) -> Unit,
    onLaunchStream: (SunshineHostConfig) -> Unit,
    onQuickAccountActivate: () -> Unit,
    onOpenPair: () -> Unit,
    onUnpair: () -> Unit,
    onOpenProfile: () -> Unit,
    onAddForward: () -> Unit,
    onToggleForward: (SSHPortForwardConfig) -> Unit,
    onDeleteForward: (String) -> Unit
) {
    val context = LocalContext.current
    val autoMbps = StreamQualityMath.recommendedBitrateKbps(resolution.width, resolution.height, refreshRate.fps) / 1000

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Remote Desktop Client Card
        item {
            SectionCard(title = AppLocalization.t("远程桌面客户端 (Moonlight)", "Remote Desktop Client (Moonlight)", lang)) {
                Text(
                    text = AppLocalization.t(
                        "Android 端作为纯主控客户端，通过硬件 MediaCodec 解码直连远端 Sunshine / NodeDeck Host（不含本机被控服务）。",
                        "Android acts as a pure hardware-accelerated Moonlight controller connecting directly to remote Sunshine / NodeDeck Host.",
                        lang
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(8.dp))

                // Resolution & Refresh Rate selectors
                Text(AppLocalization.t("目标分辨率", "Resolution", lang), style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StreamResolutionPreset.entries.forEach { preset ->
                        ChoiceChip(
                            label = preset.label,
                            selected = preset == resolution,
                            onClick = { onSelectResolution(preset) }
                        )
                    }
                }

                Spacer(Modifier.height(6.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(AppLocalization.t("目标刷新率", "Refresh Rate", lang), style = MaterialTheme.typography.labelMedium)
                    Text(
                        text = "${AppLocalization.t("自动码率", "Auto", lang)} ${autoMbps} Mbps",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StreamRefreshRate.entries.forEach { rate ->
                        ChoiceChip(
                            label = rate.label,
                            selected = rate == refreshRate,
                            onClick = { onSelectRefreshRate(rate) }
                        )
                    }
                }

                Spacer(Modifier.height(10.dp))

                if (sunshine != null) {
                    KeyValueRow(
                        AppLocalization.t("已配对目标", "Paired Endpoint", lang),
                        "${sunshine.address}:${sunshine.httpPort} (${sunshine.serverName.ifBlank { host.alias }})"
                    )
                    Spacer(Modifier.height(6.dp))
                    Button(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { onLaunchStream(sunshine) }
                    ) {
                        Icon(Icons.Default.Computer, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(AppLocalization.t("连接远程桌面", "Stream Remote Desktop", lang))
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                            onClick = onOpenPair
                        ) {
                            Text(
                                text = AppLocalization.t("重新配对", "Re-pair", lang),
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                            onClick = onOpenProfile
                        ) {
                            Icon(Icons.Default.Settings, contentDescription = null, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = AppLocalization.t("多用户配置", "Profile", lang),
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        IconButton(onClick = onUnpair) {
                            Icon(Icons.Default.Delete, contentDescription = "Unpair", tint = MaterialTheme.colorScheme.error)
                        }
                    }
                } else {
                    if (accountLoggedIn) {
                        Button(
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !isAccountActivating,
                            onClick = onQuickAccountActivate
                        ) {
                            if (isAccountActivating) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = MaterialTheme.colorScheme.onPrimary
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(AppLocalization.t("正在激活远控并同步证书…", "Activating host & syncing cert…", lang))
                            } else {
                                Icon(Icons.Default.Link, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    AppLocalization.t(
                                        "账号一键激活远控（免 SSH / 免密码）",
                                        "1-Tap Account Activate (No SSH / No Password)",
                                        lang
                                    ),
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        Text(
                            text = AppLocalization.t(
                                "使用当前账号（$accountUsername）直接下发手机证书并唤起电脑端被控服务。",
                                "Uses signed-in account ($accountUsername) to sync this phone's cert and start remote host automatically.",
                                lang
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        accountActivateError?.let { err ->
                            Text(
                                text = err,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                enabled = !isAccountActivating,
                                onClick = onOpenPair
                            ) {
                                Text(
                                    AppLocalization.t("更多配对方式", "More Options", lang),
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                enabled = !isAccountActivating,
                                onClick = onOpenProfile
                            ) {
                                Text(
                                    AppLocalization.t("多用户配置", "Host Profile", lang),
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Button(modifier = Modifier.weight(1f), onClick = onOpenPair) {
                                Icon(Icons.Default.Link, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(AppLocalization.t("配对远程桌面", "Pair Remote Host", lang))
                            }
                            OutlinedButton(onClick = onOpenProfile) {
                                Text(AppLocalization.t("多用户配置", "Host Profile", lang))
                            }
                        }
                    }
                }
            }
        }

        // Port Forwards Card
        item {
            SectionCard(
                title = AppLocalization.t("SSH 端口转发 (-L / -R / -D)", "SSH Port Forwards", lang),
                trailing = {
                    OutlinedButton(
                        onClick = onAddForward,
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(15.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(AppLocalization.t("新建", "Add", lang), style = MaterialTheme.typography.labelMedium)
                    }
                }
            ) {
                if (forwards.isEmpty()) {
                    Text(
                        text = AppLocalization.t(
                            "暂无转发规则。可一键映射 Jupyter / TensorBoard / WebUI 或启动本地 SOCKS5 代理。",
                            "No tunnels yet. Forward Jupyter / TensorBoard / WebUI or start a local SOCKS5 proxy.",
                            lang
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    forwards.forEachIndexed { idx, fwd ->
                        if (idx > 0) HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        val active = activeForwardIds.contains(fwd.id)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    BadgeChip(fwd.direction.flag, MaterialTheme.colorScheme.surfaceVariant)
                                    Text(fwd.label, style = MaterialTheme.typography.titleSmall)
                                }
                                Text(
                                    text = fwd.specSummary,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (active) NodeDeckColors.Online else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            if (active && fwd.openableUrl != null) {
                                IconButton(onClick = {
                                    runCatching {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(fwd.openableUrl)))
                                    }
                                }) {
                                    Icon(Icons.Default.OpenInBrowser, contentDescription = "Open")
                                }
                            }
                            IconButton(onClick = { onToggleForward(fwd) }) {
                                Icon(
                                    imageVector = if (active) Icons.Default.Stop else Icons.Default.PlayArrow,
                                    contentDescription = if (active) "Stop" else "Start",
                                    tint = if (active) NodeDeckColors.Offline else NodeDeckColors.Online
                                )
                            }
                            IconButton(onClick = { onDeleteForward(fwd.id) }) {
                                Icon(Icons.Default.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FilesAndToolsTab(
    host: SSHHost,
    snapshot: HostSnapshot,
    lang: AppLanguage,
    onOpenTerminal: () -> Unit,
    onOpenSftp: (String) -> Unit,
    onEditHost: () -> Unit,
    onDeleteHost: () -> Unit
) {
    val home = snapshot.metrics?.homeDirectory?.ifBlank { "~" } ?: "~"
    val candidateDirs = snapshot.metrics?.candidateDirectories.orEmpty()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            SectionCard(title = AppLocalization.t("交互式 SSH 终端", "Interactive SSH Terminal", lang)) {
                Button(modifier = Modifier.fillMaxWidth(), onClick = onOpenTerminal) {
                    Icon(Icons.Default.Terminal, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(AppLocalization.t("打开 PTY 终端", "Open PTY Terminal", lang))
                }
            }
        }

        item {
            SectionCard(title = AppLocalization.t("SFTP 远程文件浏览", "SFTP File Browser", lang)) {
                Button(modifier = Modifier.fillMaxWidth(), onClick = { onOpenSftp(home) }) {
                    Icon(Icons.Default.Folder, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("${AppLocalization.t("浏览主目录", "Browse Home", lang)} ($home)")
                }
                if (candidateDirs.isNotEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = AppLocalization.t("快速跳转目录", "Detected Directories", lang),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    candidateDirs.forEach { dir ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { onOpenSftp(dir) }
                                .padding(vertical = 8.dp, horizontal = 6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(dir, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }

        item {
            SectionCard(title = AppLocalization.t("节点管理", "Node Management", lang)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(modifier = Modifier.weight(1f), onClick = onEditHost) {
                        Icon(Icons.Default.Edit, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(AppLocalization.t("编辑节点", "Edit Node", lang))
                    }
                    OutlinedButton(modifier = Modifier.weight(1f), onClick = onDeleteHost) {
                        Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(AppLocalization.t("删除节点", "Delete", lang), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionCard(
    title: String,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                trailing?.invoke()
            }
            content()
        }
    }
}

@Composable
private fun KeyValueRow(key: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(key, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun MetricProgressRow(title: String, detail: String, fraction: Float, color: Color) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(title, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
            Text(detail, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LinearProgressIndicator(
            progress = { fraction },
            modifier = Modifier
                .fillMaxWidth()
                .height(7.dp)
                .clip(RoundedCornerShape(4.dp)),
            color = color,
            trackColor = MaterialTheme.colorScheme.surfaceVariant
        )
    }
}

@Composable
private fun ChoiceChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.clickable(onClick = onClick)
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
