package com.nodedeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nodedeck.android.core.AppLanguage
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.DisplayFormat
import com.nodedeck.android.core.HostConnectionState
import com.nodedeck.android.core.HostFilter
import com.nodedeck.android.core.HostSnapshot
import com.nodedeck.android.core.SSHHost
import com.nodedeck.android.core.SunshineHostConfig
import com.nodedeck.android.mesh.MeshConnectionState
import com.nodedeck.android.ui.theme.NodeDeckColors
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostListScreen(
    viewModel: MainViewModel,
    onSelectHost: (SSHHost) -> Unit,
    onQuickTerminal: (SSHHost) -> Unit,
    onQuickStream: (SSHHost, SunshineHostConfig) -> Unit,
    onAddHost: () -> Unit,
    onImportSshConfig: () -> Unit,
    onOpenAccount: () -> Unit,
    onOpenGuide: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val hosts by viewModel.hosts.collectAsState()
    val snapshots by viewModel.snapshots.collectAsState()
    val sunshineConfigs by viewModel.sunshineConfigs.collectAsState()
    val pinnedAliases by viewModel.pinnedAliases.collectAsState()
    val filter by viewModel.filter.collectAsState()
    val searchQuery by viewModel.searchQuery.collectAsState()
    val isRefreshingAll by viewModel.isRefreshingAll.collectAsState()
    val feedback by viewModel.feedbackMessage.collectAsState()
    val accountSession by viewModel.accountSession.collectAsState()
    val meshSnapshot by viewModel.meshSnapshot.collectAsState()

    val snackbarHostState = remember { SnackbarHostState() }
    LaunchedEffect(feedback) {
        feedback?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearFeedback()
        }
    }

    val onlineCount = snapshots.values.count { it.state == HostConnectionState.ONLINE }
    val filteredHosts = remember(hosts, snapshots, pinnedAliases, filter, searchQuery) {
        hosts.filter { host ->
            val snap = snapshots[host.id]
            val matchesFilter = when (filter) {
                HostFilter.ALL -> true
                HostFilter.ONLINE -> snap?.state == HostConnectionState.ONLINE
                HostFilter.GPU -> (snap?.metrics?.gpus?.isNotEmpty() == true)
            }
            val q = searchQuery.trim().lowercase()
            val matchesQuery = q.isEmpty() ||
                host.alias.lowercase().contains(q) ||
                host.hostName.lowercase().contains(q) ||
                host.user.lowercase().contains(q)
            matchesFilter && matchesQuery
        }.sortedWith(
            compareByDescending<SSHHost> { pinnedAliases.contains(it.alias) }
                .thenBy { it.alias.lowercase() }
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("NodeDeck", fontWeight = FontWeight.Bold)
                        Text(
                            text = "${onlineCount}/${hosts.size} ${AppLocalization.t("在线 · 零云端本地直连", "online · Zero-Cloud", lang)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                actions = {
                    val meshOnline = meshSnapshot.state == MeshConnectionState.CONNECTED
                    val meshConnecting = meshSnapshot.state == MeshConnectionState.CONNECTING
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = if (meshOnline) NodeDeckColors.Online.copy(alpha = 0.18f) else MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.clickable(onClick = onOpenAccount)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(7.dp)
                                    .clip(CircleShape)
                                    .background(
                                        when {
                                            meshOnline -> NodeDeckColors.Online
                                            meshConnecting -> NodeDeckColors.Warning
                                            else -> MaterialTheme.colorScheme.outline
                                        }
                                    )
                            )
                            Text(
                                text = if (accountSession.isLoggedIn) {
                                    accountSession.username
                                } else {
                                    AppLocalization.t("登录", "Sign In", lang)
                                },
                                style = MaterialTheme.typography.labelSmall,
                                color = if (meshOnline) NodeDeckColors.Online else MaterialTheme.colorScheme.onSurface,
                                maxLines = 1
                            )
                        }
                    }
                    Spacer(Modifier.width(6.dp))
                    val badge = when (lang) {
                        AppLanguage.SYSTEM -> "Auto"
                        AppLanguage.ZH_HANS -> "中"
                        AppLanguage.EN -> "EN"
                    }
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.clickable { viewModel.cycleLanguage() }
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                Icons.Default.Language,
                                contentDescription = "Language",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(16.dp)
                            )
                            Text(
                                text = badge,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                    IconButton(onClick = onOpenGuide) {
                        Icon(Icons.Default.Security, contentDescription = "Architecture & Security")
                    }
                    IconButton(onClick = { viewModel.refreshAllHosts() }, enabled = !isRefreshingAll) {
                        if (isRefreshingAll) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh All")
                        }
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = onAddHost,
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary
            ) {
                Icon(Icons.Default.Add, contentDescription = "Add Host")
            }
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
        ) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { viewModel.setSearchQuery(it) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                placeholder = { Text(AppLocalization.t("搜索节点别名、IP 或用户名…", "Search alias, IP, or user…", lang)) }
            )

            Spacer(Modifier.height(8.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                FilterChip(
                    selected = filter == HostFilter.ALL,
                    onClick = { viewModel.setFilter(HostFilter.ALL) },
                    label = { Text("${AppLocalization.t("全部", "All", lang)} (${hosts.size})") }
                )
                FilterChip(
                    selected = filter == HostFilter.ONLINE,
                    onClick = { viewModel.setFilter(HostFilter.ONLINE) },
                    label = { Text("${AppLocalization.t("在线", "Online", lang)} ($onlineCount)") }
                )
                FilterChip(
                    selected = filter == HostFilter.GPU,
                    onClick = { viewModel.setFilter(HostFilter.GPU) },
                    label = { Text("GPU") }
                )
                Spacer(Modifier.weight(1f))
                OutlinedButton(
                    onClick = onImportSshConfig,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                ) {
                    Text(AppLocalization.t("导入配置", "Import", lang), style = MaterialTheme.typography.labelMedium)
                }
            }

            Spacer(Modifier.height(8.dp))

            if (hosts.isEmpty()) {
                EmptyHostsView(
                    lang = lang,
                    onAddHost = onAddHost,
                    onImportSshConfig = onImportSshConfig
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(bottom = 84.dp)
                ) {
                    items(filteredHosts, key = { it.id }) { host ->
                        val snap = snapshots[host.id] ?: HostSnapshot(host = host)
                        val sunshine = sunshineConfigs.firstOrNull {
                            it.hostAlias.equals(host.alias, ignoreCase = true) ||
                                it.address.equals(host.hostName, ignoreCase = true)
                        }
                        HostCard(
                            host = host,
                            snapshot = snap,
                            sunshine = sunshine,
                            isPinned = pinnedAliases.contains(host.alias),
                            lang = lang,
                            onClick = { onSelectHost(host) },
                            onTogglePin = { viewModel.togglePinned(host.alias) },
                            onRefresh = { viewModel.refreshHost(host.id) },
                            onTerminal = { onQuickTerminal(host) },
                            onStream = sunshine?.let { cfg -> { onQuickStream(host, cfg) } }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyHostsView(
    lang: AppLanguage,
    onAddHost: () -> Unit,
    onImportSshConfig: () -> Unit
) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(24.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Memory,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(56.dp)
            )
            Text(
                text = AppLocalization.t("还没有添加计算节点", "No Compute Nodes Yet", lang),
                style = MaterialTheme.typography.titleMedium
            )
            Text(
                text = AppLocalization.t(
                    "添加 SSH 主机或直接粘贴 ~/.ssh/config，即可查看实时指标、打开终端、浏览 SFTP 并直连 Moonlight 远程桌面。",
                    "Add an SSH host or paste ~/.ssh/config to inspect metrics, open PTY terminals, browse SFTP files, and stream remote desktops.",
                    lang
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = onImportSshConfig,
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp)
                ) {
                    Text(AppLocalization.t("粘贴 SSH Config", "Paste SSH Config", lang), maxLines = 1)
                }
                androidx.compose.material3.Button(
                    onClick = onAddHost,
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 10.dp)
                ) {
                    Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(AppLocalization.t("添加节点", "Add Host", lang), maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun HostCard(
    host: SSHHost,
    snapshot: HostSnapshot,
    sunshine: SunshineHostConfig?,
    isPinned: Boolean,
    lang: AppLanguage,
    onClick: () -> Unit,
    onTogglePin: () -> Unit,
    onRefresh: () -> Unit,
    onTerminal: () -> Unit,
    onStream: (() -> Unit)?
) {
    val dotColor = when (snapshot.state) {
        HostConnectionState.ONLINE -> NodeDeckColors.Online
        HostConnectionState.OFFLINE -> NodeDeckColors.Offline
        HostConnectionState.CHECKING -> NodeDeckColors.Warning
        HostConnectionState.IDLE -> MaterialTheme.colorScheme.outline
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(dotColor)
                )
                Spacer(Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            text = host.alias,
                            modifier = Modifier.weight(1f, fill = false),
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        BadgeChip(host.routeKind.shortBadge, MaterialTheme.colorScheme.surfaceVariant)
                        if (sunshine != null) {
                            BadgeChip("Remote", MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.onPrimaryContainer)
                        }
                    }
                    Text(
                        text = host.loginTarget + if (host.proxyJumpAlias.isNotBlank()) " via ${host.proxyJumpAlias}" else "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                snapshot.latencyMs?.takeIf { snapshot.state == HostConnectionState.ONLINE }?.let { ms ->
                    Text(
                        text = DisplayFormat.latency(ms),
                        style = MaterialTheme.typography.labelSmall,
                        color = NodeDeckColors.Online
                    )
                }
                IconButton(onClick = onTogglePin, modifier = Modifier.size(32.dp)) {
                    Icon(
                        imageVector = if (isPinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                        contentDescription = "Pin",
                        tint = if (isPinned) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp)
                    )
                }
            }

            // Metrics preview row
            val m = snapshot.metrics
            if (m != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    MiniMetricBar(
                        modifier = Modifier.weight(1f),
                        label = "CPU ${m.cpuUsage.roundToInt()}%",
                        fraction = (m.cpuUsage / 100.0).toFloat().coerceIn(0f, 1f),
                        color = MaterialTheme.colorScheme.primary
                    )
                    MiniMetricBar(
                        modifier = Modifier.weight(1f),
                        label = "RAM ${(m.memoryFraction * 100).roundToInt()}%",
                        fraction = m.memoryFraction.toFloat(),
                        color = MaterialTheme.colorScheme.secondary
                    )
                    m.gpus.firstOrNull()?.let { gpu ->
                        val gpuFrac = ((gpu.utilization ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
                        MiniMetricBar(
                            modifier = Modifier.weight(1f),
                            label = if (gpu.isSleeping) "GPU Zzz" else "GPU ${(gpu.utilization ?: 0.0).roundToInt()}%",
                            fraction = gpuFrac,
                            color = if (gpu.isAMD) NodeDeckColors.GpuAmd else NodeDeckColors.GpuNvidia
                        )
                    }
                }
            } else if (!snapshot.errorMessage.isNullOrBlank()) {
                Text(
                    text = snapshot.errorMessage,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            // Quick Actions Row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedButton(
                    onClick = onTerminal,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                ) {
                    Icon(Icons.Default.Terminal, contentDescription = null, modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(AppLocalization.t("终端", "Terminal", lang), style = MaterialTheme.typography.labelMedium)
                }
                if (onStream != null) {
                    androidx.compose.material3.Button(
                        onClick = onStream,
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                    ) {
                        Icon(Icons.Default.Computer, contentDescription = null, modifier = Modifier.size(15.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(AppLocalization.t("远程桌面", "Remote", lang), style = MaterialTheme.typography.labelMedium)
                    }
                }
                Spacer(Modifier.weight(1f))
                if (snapshot.state == HostConnectionState.CHECKING) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = onRefresh, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh", modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
    }
}

@Composable
fun BadgeChip(
    text: String,
    containerColor: Color,
    contentColor: Color = MaterialTheme.colorScheme.onSurfaceVariant
) {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = containerColor
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            color = contentColor,
            maxLines = 1,
            softWrap = false
        )
    }
}

@Composable
private fun MiniMetricBar(
    modifier: Modifier = Modifier,
    label: String,
    fraction: Float,
    color: Color
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(text = label, style = MaterialTheme.typography.labelSmall, maxLines = 1)
        LinearProgressIndicator(
            progress = { fraction },
            modifier = Modifier
                .fillMaxWidth()
                .height(5.dp)
                .clip(RoundedCornerShape(3.dp)),
            color = color,
            trackColor = MaterialTheme.colorScheme.surfaceVariant
        )
    }
}
