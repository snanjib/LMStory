package com.lmstory.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * MainActivity：外部"打开方式/分享"导入桥接（与 iOS 端 AppDelegate.swift 对称）。
 *
 * MethodChannel `lmstory/incoming_file`：
 * - Dart → 原生：`getInitialFile`（返回并清除冷启动暂存的 pending 文件）
 * - 原生 → Dart：`onIncomingFile({path, fileName, mime})`
 *
 * 接收路径：ACTION_VIEW（"使用 LMStory 打开"）/ ACTION_SEND（"分享"）的
 * content:// 复制到 cacheDir/incoming/（单槽）后交付 Dart。
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "lmstory/incoming_file"
    }

    /// Dart 侧就绪前的暂存（冷启动；Dart init 时经 getInitialFile 取走）
    private var pendingFile: Map<String, Any?>? = null

    /// Dart 侧就绪后的 channel（null = engine 尚未配置）
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialFile" -> {
                        val file = pendingFile
                        pendingFile = null
                        result.success(file)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // 冷启动竞态：此处 invoke 时 Dart 侧 handler 可能尚未注册（推送会被
        // 静默丢弃），真正的兜底是 pendingFile —— Dart init 时会调 getInitialFile。
    }

    override fun onDestroy() {
        channel = null
        super.onDestroy()
    }

    /** 从 VIEW/SEND intent 提取文件：content:// 复制到 cacheDir 后交付 Dart */
    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return

        val uri: Uri? = when (action) {
            Intent.ACTION_SEND -> intent.getStreamExtraCompat(Intent.EXTRA_STREAM)
            else -> intent.data
        }
        if (uri == null) return

        val file = try {
            copyToCache(uri, intent.type)
        } catch (e: Exception) {
            return // 复制失败（来源已失效等）：静默忽略，避免打断启动
        }
        deliver(file)
    }

    /** 交付：始终暂存 pending（供 Dart getInitialFile 兜底），channel 就绪时
     *  额外推送（app 运行中收到 onNewIntent 的常规路径）。 */
    private fun deliver(file: Map<String, Any?>) {
        pendingFile = file
        channel?.invokeMethod("onIncomingFile", file)
    }

    /** Single-slot cache file: the newest arrival deletes the previous one.
     *  The copy is size-capped (same 10MB limit as the Dart-side
     *  ResourceImportService.maxImportBytes) — previously an arbitrarily
     *  large file was fully copied into cacheDir before Dart rejected it,
     *  bloating the cache and wasting IO. On overflow we abort, delete the
     *  partial file, and take the existing silent-ignore path in
     *  handleIncomingIntent. */
    private fun copyToCache(uri: Uri, mime: String?): Map<String, Any?> {
        val maxImportBytes = 10L * 1024 * 1024
        val dir = File(cacheDir, "incoming").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // 清理旧文件（单槽）

        val displayName = queryDisplayName(uri) ?: "import.png"
        val target = File(dir, System.currentTimeMillis().toString() + "_" + displayName)
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output ->
                var copied = 0L
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    copied += n
                    if (copied > maxImportBytes) {
                        output.close()
                        target.delete()
                        throw IllegalStateException("import exceeds 10MB limit")
                    }
                    output.write(buffer, 0, n)
                }
            }
        } ?: throw IllegalStateException("无法读取来源文件")

        return mapOf(
            "path" to target.absolutePath,
            "fileName" to displayName,
            "mime" to (mime ?: "application/octet-stream"),
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) name = cursor.getString(idx)
            }
        }
        // file:// 协议无 DISPLAY_NAME 列时回退到路径末段
        return name ?: uri.lastPathSegment
    }
}

/** EXTRA_STREAM 兼容读取（TIRAMISU 前 getParcelableExtra，之后类型安全版本） */
private fun Intent.getStreamExtraCompat(name: String): Uri? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(name, Uri::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(name)
    }
}
