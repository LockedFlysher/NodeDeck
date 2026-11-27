package com.nodedeck.android.ui

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nodedeck.android.core.AppLocalization
import com.nodedeck.android.core.DisplayFormat
import com.nodedeck.android.core.RemoteFileEntry
import com.nodedeck.android.core.SSHHost
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SftpBrowserScreen(
    host: SSHHost,
    allHosts: List<SSHHost>,
    initialPath: String,
    viewModel: MainViewModel,
    onBack: () -> Unit
) {
    val lang by AppLocalization.language.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    var currentPath by remember { mutableStateOf(initialPath.ifBlank { "~" }) }
    var entries by remember { mutableStateOf<List<RemoteFileEntry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var errorMsg by remember { mutableStateOf<String?>(null) }
    var previewTitle by remember { mutableStateOf<String?>(null) }
    var previewText by remember { mutableStateOf<String?>(null) }

    fun loadDirectory(path: String) {
        scope.launch {
            loading = true
            errorMsg = null
            runCatching { viewModel.sshManager.listDirectory(host, allHosts, path) }
                .onSuccess { (resolved, items) ->
                    currentPath = resolved
                    entries = items
                }
                .onFailure {
                    errorMsg = it.message ?: "Failed to list directory"
                }
            loading = false
        }
    }

    val uploadLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val fileName = runCatching {
                context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (c.moveToFirst() && idx >= 0) c.getString(idx) else null
                }
            }.getOrNull() ?: "upload_${System.currentTimeMillis()}"
            val remoteDest = if (currentPath.endsWith("/")) "$currentPath$fileName" else "$currentPath/$fileName"
            loading = true
            runCatching {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { stream ->
                        viewModel.sshManager.uploadRemoteFile(host, allHosts, remoteDest, stream)
                    } ?: throw IllegalStateException("Unable to read selected file")
                }
            }.onSuccess {
                snackbarHostState.showSnackbar(AppLocalization.t("已上传 $fileName", "Uploaded $fileName", lang))
                loadDirectory(currentPath)
            }.onFailure {
                loading = false
                snackbarHostState.showSnackbar(it.message ?: "Upload failed")
            }
        }
    }

    LaunchedEffect(host.id, initialPath) {
        loadDirectory(initialPath.ifBlank { "~" })
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                title = {
                    Column {
                        Text("${host.alias} · SFTP", maxLines = 1)
                        Text(
                            text = currentPath,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                },
                actions = {
                    IconButton(onClick = {
                        val parent = currentPath.trimEnd('/').substringBeforeLast('/', "/")
                        loadDirectory(parent.ifBlank { "/" })
                    }) {
                        Icon(Icons.Default.ArrowUpward, contentDescription = "Parent")
                    }
                    IconButton(onClick = { uploadLauncher.launch(arrayOf("*/*")) }) {
                        Icon(Icons.Default.Upload, contentDescription = "Upload")
                    }
                    IconButton(onClick = { loadDirectory(currentPath) }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                loading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                errorMsg != null -> {
                    Column(
                        modifier = Modifier.align(Alignment.Center).padding(20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(errorMsg!!, color = MaterialTheme.colorScheme.error)
                        TextButton(onClick = { loadDirectory(currentPath) }) {
                            Text(AppLocalization.t("重试", "Retry", lang))
                        }
                    }
                }
                entries.isEmpty() -> {
                    Text(
                        text = AppLocalization.t("空目录", "Empty directory", lang),
                        modifier = Modifier.align(Alignment.Center),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(vertical = 4.dp)
                    ) {
                        items(entries, key = { it.fullPath }) { item ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        if (item.isDirectory) {
                                            loadDirectory(item.fullPath)
                                        } else {
                                            scope.launch {
                                                runCatching {
                                                    viewModel.sshManager.readRemoteFileBytes(host, allHosts, item.fullPath, maxBytes = 128 * 1024)
                                                }.onSuccess { bytes ->
                                                    previewTitle = item.name
                                                    previewText = String(bytes, Charsets.UTF_8)
                                                }.onFailure {
                                                    snackbarHostState.showSnackbar(it.message ?: "Preview failed")
                                                }
                                            }
                                        }
                                    }
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    imageVector = if (item.isDirectory) Icons.Default.Folder else Icons.Default.Description,
                                    contentDescription = null,
                                    tint = if (item.isDirectory) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(22.dp)
                                )
                                Spacer(Modifier.width(12.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = item.name,
                                        style = MaterialTheme.typography.bodyMedium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = "${item.permissions} · ${if (item.isDirectory) "DIR" else DisplayFormat.bytes(item.sizeBytes)}",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                if (!item.isDirectory) {
                                    IconButton(onClick = {
                                        scope.launch {
                                            runCatching {
                                                val bytes = viewModel.sshManager.readRemoteFileBytes(
                                                    host, allHosts, item.fullPath, maxBytes = 25 * 1024 * 1024
                                                )
                                                withContext(Dispatchers.IO) {
                                                    saveToDownloads(context, item.name, bytes)
                                                }
                                            }.onSuccess { savedPath ->
                                                snackbarHostState.showSnackbar(
                                                    AppLocalization.t("已保存到 $savedPath", "Saved to $savedPath", lang)
                                                )
                                            }.onFailure {
                                                snackbarHostState.showSnackbar(it.message ?: "Download failed")
                                            }
                                        }
                                    }) {
                                        Icon(Icons.Default.Download, contentDescription = "Download")
                                    }
                                }
                            }
                            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
                        }
                    }
                }
            }
        }
    }

    if (previewTitle != null && previewText != null) {
        AlertDialog(
            onDismissRequest = {
                previewTitle = null
                previewText = null
            },
            title = { Text(previewTitle!!, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            text = {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant
                ) {
                    Text(
                        text = previewText!!,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(10.dp)
                            .verticalScroll(rememberScrollState()),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.5.sp
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    previewTitle = null
                    previewText = null
                }) {
                    Text(AppLocalization.t("关闭", "Close", lang))
                }
            }
        )
    }
}

private fun saveToDownloads(context: android.content.Context, fileName: String, bytes: ByteArray): String {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/NodeDeck")
        }
        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Cannot create download entry")
        context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
            ?: throw IllegalStateException("Cannot write download file")
        return "Downloads/NodeDeck/$fileName"
    } else {
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "NodeDeck").apply { mkdirs() }
        val file = File(dir, fileName)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}
