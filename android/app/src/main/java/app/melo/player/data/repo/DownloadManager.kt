package app.melo.player.data.repo

import android.content.Context
import app.melo.player.data.db.DownloadDao
import app.melo.player.data.db.DownloadEntity
import app.melo.player.data.db.toData
import app.melo.player.data.model.ResolvedStream
import app.melo.player.data.model.Track
import app.melo.player.data.prefs.SettingsRepository
import app.melo.player.data.remote.Api
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Offline downloads.
 *
 * Files live in the app's own external files directory, so no storage permission is
 * needed and uninstalling removes them. Only catalog streams are stored; nothing here
 * circumvents DRM or a provider restriction, and a track the provider refuses to serve
 * is reported as failed instead of being written.
 */
class DownloadManager(
    private val context: Context,
    private val dao: DownloadDao,
    private val settings: SettingsRepository,
    private val resolver: StreamResolver,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val jobs = ConcurrentHashMap<String, Job>()

    private val _progress = MutableStateFlow<Map<String, Float>>(emptyMap())
    val progress: StateFlow<Map<String, Float>> = _progress.asStateFlow()

    private val _errors = MutableStateFlow<Map<String, String>>(emptyMap())
    val errors: StateFlow<Map<String, String>> = _errors.asStateFlow()

    private fun dir(): File {
        val d = File(context.getExternalFilesDir(null) ?: context.filesDir, "downloads")
        if (!d.exists()) d.mkdirs()
        return d
    }

    fun isDownloading(key: String): Boolean = jobs[key]?.isActive == true

    suspend fun enqueue(track: Track) {
        if (jobs[track.key]?.isActive == true) return
        val existing = dao.byKey(track.key)
        if (existing != null && existing.status == "DONE" && File(existing.filePath).exists()) return

        dao.upsert(
            DownloadEntity(
                trackKey = track.key,
                track = track.toData(),
                filePath = "",
                bytes = 0,
                quality = settings.current().downloadQuality,
                status = "QUEUED",
                createdAt = System.currentTimeMillis(),
            ),
        )
        jobs[track.key] = scope.launch { run(track) }
    }

    private suspend fun run(track: Track) {
        val key = track.key
        dao.setStatus(key, "RUNNING")
        setProgress(key, 0f)

        val resolved = resolver.resolve(track)
        if (resolved !is ResolvedStream.Remote) {
            fail(key, (resolved as? ResolvedStream.Local)?.let { "Already available offline." }
                ?: "Could not resolve this track for download.")
            return
        }

        val target = File(dir(), fileName(track, resolved.url))
        val tmp = File(dir(), target.name + ".part")

        try {
            withContext(Dispatchers.IO) {
                val request = Request.Builder()
                    .url(resolved.url)
                    .header("User-Agent", if (resolved.url.contains("googlevideo")) Api.ANDROID_VR_UA else Api.WEB_UA)
                    .build()

                val response = Api.streamingClient.newCall(request).execute()
                if (!response.isSuccessful) {
                    response.close()
                    throw IllegalStateException("HTTP ${response.code}")
                }
                val body = response.body ?: throw IllegalStateException("Empty response")
                val total = body.contentLength().takeIf { it > 0 } ?: -1L
                var written = 0L

                body.byteStream().use { input ->
                    tmp.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var read: Int
                        var lastUpdate = 0L
                        while (input.read(buffer).also { read = it } > 0) {
                            output.write(buffer, 0, read)
                            written += read
                            val now = System.currentTimeMillis()
                            if (now - lastUpdate > 250) {
                                lastUpdate = now
                                setProgress(key, if (total > 0) written.toFloat() / total else 0f)
                                dao.setBytes(key, written)
                            }
                        }
                    }
                }
                if (tmp.length() < 16 * 1024) throw IllegalStateException("Downloaded file looks invalid")
                if (target.exists()) target.delete()
                if (!tmp.renameTo(target)) throw IllegalStateException("Could not finalise file")
                dao.complete(key, target.absolutePath, target.length())
                setProgress(key, 1f)
            }
        } catch (e: Exception) {
            runCatching { tmp.delete() }
            fail(key, e.message ?: "Download failed")
        } finally {
            jobs.remove(key)
        }
    }

    private suspend fun fail(key: String, message: String) {
        dao.setStatus(key, "FAILED", message)
        _errors.value = _errors.value + (key to message)
        setProgress(key, -1f)
    }

    fun cancel(key: String) {
        jobs[key]?.cancel()
        jobs.remove(key)
        scope.launch {
            dao.setStatus(key, "CANCELLED")
            _progress.value = _progress.value - key
        }
    }

    suspend fun delete(trackKey: String) {
        dao.byKey(trackKey)?.let { entry ->
            // Older versions could store the same path for multiple completed tracks.
            if (entry.filePath.isNotBlank() && dao.completedOnce().none {
                    it.trackKey != trackKey && it.filePath == entry.filePath
                }) {
                runCatching { File(entry.filePath).delete() }
            }
        }
        dao.delete(trackKey)
        _progress.value = _progress.value - trackKey
    }

    suspend fun clearAll() {
        dao.completedOnce().forEach { entry ->
            if (entry.filePath.isNotBlank()) runCatching { File(entry.filePath).delete() }
        }
        dao.clear()
        _progress.value = emptyMap()
    }

    /** Remove rows whose file disappeared (user cleared storage, OS evicted, etc.). */
    suspend fun pruneMissing() {
        dao.completedOnce().forEach { entry ->
            if (!File(entry.filePath).exists()) dao.delete(entry.trackKey)
        }
    }

    private fun setProgress(key: String, value: Float) {
        _progress.value = _progress.value + (key to value)
    }

    internal fun fileName(track: Track, url: String): String {
        val base = MessageDigest.getInstance("SHA-256")
            .digest(track.key.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val ext = when {
            url.contains(".m3u8") -> "m3u8"
            url.contains("mime=audio%2Fmp4") -> "m4a"
            url.contains("mime=audio/mp4") -> "m4a"
            else -> "m4a"
        }
        return "$base.$ext"
    }
}
