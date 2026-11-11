package org.localsend.localsend_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import java.io.File
import java.util.UUID

@Suppress("DEPRECATION")
internal fun importIncomingShare(context: Context, intent: Intent): Map<String, Any?> {
    val uris = linkedSetOf<Uri>()
    var text = runCatching { intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() }.getOrNull()
    var failed = 0
    try {
        when (intent.action) {
            Intent.ACTION_SEND -> intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
        }
    } catch (error: RuntimeException) {
        // A provider can supply the attachments in ClipData instead.
        Log.w("IncomingShare", "Could not read stream extras", error)
        failed++
    }
    if (uris.isEmpty()) {
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let(uris::add)
            }
        }
    }
    if (uris.isEmpty() && text.isNullOrBlank()) {
        text = intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
    }
    val paths = uris.mapNotNull { uri ->
        try {
            require(uri.scheme == "content")
            copyIncomingFile(context, uri, intent.type)
        } catch (error: Exception) {
            Log.w("IncomingShare", "Could not import a shared attachment", error)
            failed++
            null
        }
    }
    if (paths.isEmpty() && text.isNullOrBlank() && failed == 0) failed = 1
    return mapOf("paths" to paths, "text" to text, "failed" to failed)
}

private fun copyIncomingFile(context: Context, uri: Uri, fallbackMime: String?): String {
    val resolver = context.contentResolver
    val displayName = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }.getOrNull()
    val mime = runCatching { resolver.getType(uri) }.getOrNull() ?: fallbackMime
    val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
    val fallback = if (extension == null) "Shared file" else "Shared file.$extension"
    val name = displayName?.substringAfterLast('/')?.substringAfterLast('\\')
        ?.replace(Regex("[\\p{Cntrl}]"), "_")?.trim()
        ?.takeIf { it.isNotEmpty() && it != "." && it != ".." } ?: fallback
    val directory = File(context.cacheDir, "incoming-share/${UUID.randomUUID()}")
    check(directory.mkdirs())
    val file = File(directory, name)
    try {
        val input = resolver.openInputStream(uri) ?: error("No readable stream")
        input.use { stream -> file.outputStream().use { stream.copyTo(it) } }
        return file.absolutePath
    } catch (error: Exception) {
        file.delete()
        directory.delete()
        throw error
    }
}
