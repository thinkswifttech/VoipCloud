package com.thinkswift.softphoneapp

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.core.content.IntentCompat
import java.io.File
import java.util.UUID

/**
 * Reads what another app shared (ACTION_SEND / ACTION_SEND_MULTIPLE) into a
 * payload for Flutter. Photos are copied into app cache as small JPEGs so the
 * content URI permission is not needed after this call and every picture
 * (HEIC, PNG, WebP...) arrives in the one format carrier picture messages use.
 */
object ShareIntentReader {
    private const val TAG = "VoIPCloud/Share"
    private const val MAX_FILES = 10
    private const val MAX_SIDE_PX = 1600
    private const val JPEG_QUALITY = 80
    private const val MAX_TEXT_CHARS = 4000

    fun isShare(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    /** Blocking (copies files): call off the main thread. Returns null if nothing usable. */
    fun read(context: Context, intent: Intent): Map<String, Any>? {
        if (!isShare(intent)) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty().take(MAX_TEXT_CHARS)
        val uris: List<Uri> = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                .orEmpty()
        } else {
            listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
        }
        val directory = File(context.cacheDir, "shared_in")
        directory.mkdirs()
        // Only the latest share is ever needed.
        directory.listFiles()?.forEach { it.delete() }

        val files = uris.take(MAX_FILES).mapNotNull { uri ->
            val type = context.contentResolver.getType(uri).orEmpty()
            if (!type.startsWith("image/")) return@mapNotNull null
            runCatching { copyAsJpeg(context, uri, directory) }
                .onFailure { Log.w(TAG, "Could not read a shared image", it) }
                .getOrNull()
        }
        if (text.isEmpty() && files.isEmpty()) return null
        return mapOf("id" to UUID.randomUUID().toString(), "text" to text, "files" to files)
    }

    private fun copyAsJpeg(context: Context, uri: Uri, directory: File): Map<String, String> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (bounds.outWidth / sample > MAX_SIDE_PX * 2 || bounds.outHeight / sample > MAX_SIDE_PX * 2) {
            sample *= 2
        }
        val bitmap = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: error("unreadable image")
        val scale = MAX_SIDE_PX.toFloat() / maxOf(bitmap.width, bitmap.height)
        val scaled = if (scale < 1f) {
            Bitmap.createScaledBitmap(
                bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true
            )
        } else bitmap
        val name = "shared-${UUID.randomUUID()}.jpg"
        File(directory, name).outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it) }
        return mapOf(
            "path" to File(directory, name).absolutePath,
            "mimeType" to "image/jpeg",
            "name" to name
        )
    }
}
