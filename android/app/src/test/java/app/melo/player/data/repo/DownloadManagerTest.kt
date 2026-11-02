package app.melo.player.data.repo

import android.content.Context
import android.content.ContextWrapper
import app.melo.player.data.db.DownloadDao
import app.melo.player.data.db.DownloadEntity
import app.melo.player.data.db.toData
import app.melo.player.data.model.ResolvedStream
import app.melo.player.data.model.Source
import app.melo.player.data.model.Track
import app.melo.player.data.prefs.SettingsRepository
import java.io.File
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.ResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DownloadManagerTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    private lateinit var dao: FakeDownloadDao
    private lateinit var resolver: StreamResolver
    private lateinit var manager: DownloadManager
    private lateinit var context: Context
    private lateinit var settings: SettingsRepository

    private val url = "https://example.com/audio?mime=audio%2Fmp4"

    private fun track(id: String) = Track(id = id, title = "Same title", artist = "Same artist")

    @Before
    fun setUp() {
        context = object : ContextWrapper(null) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = temporaryFolder.root
            override fun getExternalFilesDir(type: String?): File = temporaryFolder.root
        }
        dao = FakeDownloadDao()
        settings = SettingsRepository(context)
        resolver = StreamResolver(dao, settings)
        manager = DownloadManager(context, dao, settings, resolver)
    }

    @Test
    fun `HLS streams fail without requesting or writing the manifest`() = runTest {
        var requests = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            requests++
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK")
                .body(("#EXTM3U\n" + "# fixture\n".repeat(3000)).toResponseBody("application/vnd.apple.mpegurl".toMediaType()))
                .build()
        }.build()
        val download = DownloadManager(context, dao, settings, resolver,
            resolveStream = { ResolvedStream.Remote("https://fixture.invalid/manifest", hls = true) },
            client = client)
        val track = track("hls")

        finish(download, track)

        assertEquals("FAILED", dao.byKey(track.key)?.status)
        assertEquals(0, requests)
        assertTrue(download.errors.value[track.key].orEmpty().contains("HLS"))
        assertFalse(File(temporaryFolder.root, "downloads").exists())
    }

    @Test
    fun `m3u8 URL is rejected even without the provider HLS flag`() = runTest {
        val client = OkHttpClient.Builder().addInterceptor { throw AssertionError("HLS must not be requested") }.build()
        val download = DownloadManager(context, dao, settings, resolver,
            resolveStream = { ResolvedStream.Remote("https://fixture.invalid/list.M3U8?token=1") }, client = client)
        val track = track("hls-url")
        finish(download, track)
        assertEquals("FAILED", dao.byKey(track.key)?.status)
        assertTrue(download.errors.value[track.key].orEmpty().contains("HLS"))
    }

    @Test
    fun `manifest MIME content and redirect URL cannot become completed audio`() = runTest {
        val legacy = temporaryFolder.newFile("existing.m4a").apply { writeText("keep existing audio") }
        val manifest = ("#EXTM3U\n" + "# fixture\n".repeat(3000)).toByteArray()
        val cases = listOf(
            Triple(ByteArray(20_000), "application/vnd.apple.mpegurl", url),
            Triple(ByteArray(20_000), "audio/x-mpegurl", url),
            Triple(manifest, "audio/mp4", url),
            Triple(ByteArray(20_000), "audio/mp4", "https://fixture.invalid/list.m3u8"),
        )
        cases.forEachIndexed { index, (bytes, mime, finalUrl) ->
            val download = fixtureDownload(ResolvedStream.Remote(url), bytes, mime, finalUrl = finalUrl)
            val track = track("manifest-$index")
            finish(download, track)
            assertEquals("FAILED", dao.byKey(track.key)?.status)
            assertEquals("", dao.byKey(track.key)?.filePath)
            assertTrue(download.errors.value[track.key].orEmpty().contains("HLS"))
        }
        assertEquals("keep existing audio", legacy.readText())
        assertTrue(File(temporaryFolder.root, "downloads").listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `progressive audio completes with its hashed path and original bytes`() = runTest {
        val bytes = ByteArray(20_000) { (it % 251).toByte() }
        val download = fixtureDownload(ResolvedStream.Remote(url), bytes)
        val track = track("progressive")
        finish(download, track)
        val saved = checkNotNull(dao.byKey(track.key))
        assertEquals("DONE", saved.status)
        assertEquals(download.fileName(track, url), File(saved.filePath).name)
        assertTrue(bytes.contentEquals(File(saved.filePath).readBytes()))
        assertEquals(bytes.size.toLong(), saved.bytes)
        assertFalse(File(saved.filePath + ".part").exists())
        assertEquals(ResolvedStream.Local(saved.filePath), resolver.resolve(track))
    }

    @Test
    fun `truncated progressive response fails and removes only its partial file`() = runTest {
        val track = track("truncated")
        val existing = File(temporaryFolder.root, "downloads").apply { mkdirs() }
            .resolve(manager.fileName(track, url)).apply { writeText("preserve target") }
        val download = fixtureDownload(ResolvedStream.Remote(url), ByteArray(20_000), declaredLength = 30_000)
        finish(download, track)
        assertEquals("FAILED", dao.byKey(track.key)?.status)
        assertEquals("", dao.byKey(track.key)?.filePath)
        assertEquals("preserve target", existing.readText())
        assertFalse(File(existing.absolutePath + ".part").exists())
    }

    @Test
    fun `partial 206 coverage fails without replacing the existing target`() = runTest {
        val track = track("partial-range")
        val target = File(temporaryFolder.root, "downloads").apply { mkdirs() }
            .resolve(manager.fileName(track, url)).apply { writeText("preserve existing audio") }
        val download = fixtureDownload(ResolvedStream.Remote(url), ByteArray(20_000), status = 206,
            contentRange = "bytes 0-19999/100000")
        finish(download, track)
        assertEquals("FAILED", dao.byKey(track.key)?.status)
        assertEquals("", dao.byKey(track.key)?.filePath)
        assertEquals("preserve existing audio", target.readText())
        assertFalse(File(target.absolutePath + ".part").exists())
    }

    @Test
    fun `complete 206 coverage is permitted with known or unknown body length`() = runTest {
        val bytes = ByteArray(20_000) { (it % 251).toByte() }
        for (length in listOf(20_000L, -1L)) {
            val track = track("complete-range-$length")
            val download = fixtureDownload(ResolvedStream.Remote(url), bytes, declaredLength = length,
                status = 206, contentRange = "bytes 0-19999/20000")
            finish(download, track)
            val saved = checkNotNull(dao.byKey(track.key))
            assertEquals("DONE", saved.status)
            assertEquals(20_000L, saved.bytes)
            assertTrue(bytes.contentEquals(File(saved.filePath).readBytes()))
        }
    }

    @Test
    fun `206 responses require valid full coverage and matching actual bytes`() = runTest {
        val cases = listOf(
            null to 20_000L,
            "bytes 0-19999/*" to 20_000L,
            "bytes 1-20000/20001" to 20_000L,
            "bytes 0-19999/20000" to 30_000L,
            "bytes 0-29999/30000" to -1L,
            "bytes 0-19999/999999999999999999999" to 20_000L,
            "bytes 0-19999/0" to 20_000L,
            "invalid" to 20_000L,
        )
        cases.forEachIndexed { index, (range, length) ->
            val track = track("bad-range-$index")
            val download = fixtureDownload(ResolvedStream.Remote(url), ByteArray(20_000),
                declaredLength = length, status = 206, contentRange = range)
            finish(download, track)
            assertEquals("FAILED", dao.byKey(track.key)?.status)
            assertEquals("", dao.byKey(track.key)?.filePath)
        }
        assertTrue(File(temporaryFolder.root, "downloads").listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `provider failure and HTTP rejection cannot complete a download`() = runTest {
        val failure = fixtureDownload(ResolvedStream.Failure("Fixture unavailable"), ByteArray(0))
        val missing = track("missing")
        finish(failure, missing)
        assertEquals("FAILED", dao.byKey(missing.key)?.status)
        assertEquals("Fixture unavailable", failure.errors.value[missing.key])

        val denied = fixtureDownload(ResolvedStream.Remote(url), ByteArray(20_000), status = 403)
        val forbidden = track("forbidden")
        finish(denied, forbidden)
        assertEquals("FAILED", dao.byKey(forbidden.key)?.status)
        assertEquals("HTTP 403", denied.errors.value[forbidden.key])
        assertTrue(File(temporaryFolder.root, "downloads").listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `local source resolution preserves existing files and reports missing files`() = runTest {
        val file = temporaryFolder.newFile("local.m4a").apply { writeText("local audio") }
        val track = track("local").copy(source = Source.LOCAL, streamUrl = file.absolutePath)
        assertEquals(ResolvedStream.Local(file.absolutePath), resolver.resolve(track))
        assertEquals("local audio", file.readText())
        val missing = track.copy(streamUrl = File(temporaryFolder.root, "missing.m4a").absolutePath)
        assertEquals(ResolvedStream.Failure("This file is no longer available."), resolver.resolve(missing))
    }

    @Test
    fun `different tracks with identical artist and title have distinct filenames`() {
        val first = track("first")
        val second = track("second")

        assertNotEquals(first.key, second.key)
        assertNotEquals(manager.fileName(first, url), manager.fileName(second, url))
    }

    @Test
    fun `the source is part of the file identity`() {
        val youtube = track("same-id")
        val soundCloud = youtube.copy(source = Source.SOUNDCLOUD)

        assertNotEquals(manager.fileName(youtube, url), manager.fileName(soundCloud, url))
    }

    @Test
    fun `filenames are deterministic across metadata and stream URL changes`() {
        val original = track("stable-id")
        val updated = original.copy(title = "Updated title", artist = "Updated artist", album = "New album")

        assertEquals("2c39ef388211159226aa272bbd470250c743fa43bde0cb96b5fa4abac17ce091.m4a", manager.fileName(original, url))
        assertEquals(manager.fileName(original, url), manager.fileName(updated, "https://example.com/new-url"))
    }

    @Test
    fun `the complete key is used without truncation or filename sanitization collisions`() {
        val prefix = "x".repeat(200)
        val tracks = listOf(track(prefix + "a"), track(prefix + "b"), track("a/b"), track("a:b"))

        assertEquals(tracks.size, tracks.map { manager.fileName(it, url) }.toSet().size)
        tracks.forEach {
            assertTrue(manager.fileName(it, url).matches(Regex("[a-f0-9]{64}\\.m4a")))
        }
    }

    @Test
    fun `unicode keys and unsafe metadata produce a bounded safe basename`() {
        val unsafe = track("音楽/🎵:1").copy(artist = "../artist", title = "a\\b:*?\"<>|")
        val name = manager.fileName(unsafe, url)

        assertTrue(name.matches(Regex("[a-f0-9]{64}\\.m4a")))
        assertEquals(name, File(name).name)
    }

    @Test
    fun `existing extension selection is preserved`() {
        val track = track("extension")
        val audioName = manager.fileName(track, url)

        assertEquals(audioName, manager.fileName(track, "https://example.com/audio?mime=audio/mp4"))
        assertEquals(audioName, manager.fileName(track, "https://example.com/audio"))
        assertEquals(audioName.removeSuffix(".m4a") + ".m3u8", manager.fileName(track, "https://example.com/list.m3u8"))
    }

    @Test
    fun `an interrupted track has a separate part file from another track`() {
        val first = File(temporaryFolder.root, manager.fileName(track("first"), url))
        val firstPart = File(temporaryFolder.root, first.name + ".part")
        val second = File(temporaryFolder.root, manager.fileName(track("second"), url))
        val secondPart = File(temporaryFolder.root, second.name + ".part")
        first.writeText("completed first")
        firstPart.writeText("interrupted first")
        secondPart.writeText("second in progress")

        assertNotEquals(firstPart, secondPart)
        assertTrue(secondPart.renameTo(second))
        assertEquals("completed first", first.readText())
        assertEquals("interrupted first", firstPart.readText())
        assertEquals("second in progress", second.readText())
    }

    @Test
    fun `completed legacy paths remain unchanged when enqueued and resolved`() = runTest {
        val track = track("legacy")
        val file = temporaryFolder.newFile("Same artist - Same title.m4a").apply { writeText("legacy audio") }
        val saved = completed(track, file).copy(quality = "normal", createdAt = 123L)
        dao.upsert(saved)

        manager.enqueue(track)

        assertEquals(saved, dao.byKey(track.key))
        assertEquals(ResolvedStream.Local(file.absolutePath), resolver.resolve(track))
        assertEquals("legacy audio", file.readText())
        assertEquals(listOf(file.name), temporaryFolder.root.listFiles()!!.map { it.name })
        assertFalse(manager.isDownloading(track.key))
    }

    @Test
    fun `deleting one completed track preserves another with identical metadata`() = runTest {
        val first = track("first")
        val second = track("second")
        val firstFile = File(temporaryFolder.root, manager.fileName(first, url)).apply { writeText("first audio") }
        val secondFile = File(temporaryFolder.root, manager.fileName(second, url)).apply { writeText("second audio") }
        dao.upsert(completed(first, firstFile))
        dao.upsert(completed(second, secondFile))

        manager.delete(first.key)

        assertEquals(null, dao.byKey(first.key))
        assertFalse(firstFile.exists())
        assertEquals("second audio", secondFile.readText())
        assertEquals(ResolvedStream.Local(secondFile.absolutePath), resolver.resolve(second))
    }

    @Test
    fun `deleting a legacy row preserves its shared file until the last reference is deleted`() = runTest {
        val first = track("first")
        val second = track("second")
        val file = temporaryFolder.newFile("Same artist - Same title.m4a").apply { writeText("legacy audio") }
        dao.upsert(completed(first, file))
        val secondEntry = completed(second, file)
        dao.upsert(secondEntry)

        manager.delete(first.key)

        assertEquals(null, dao.byKey(first.key))
        assertEquals(secondEntry, dao.byKey(second.key))
        assertEquals("legacy audio", file.readText())
        assertEquals(ResolvedStream.Local(file.absolutePath), resolver.resolve(second))

        manager.delete(second.key)

        assertEquals(null, dao.byKey(second.key))
        assertFalse(file.exists())
    }

    private suspend fun finish(download: DownloadManager, track: Track) {
        download.enqueue(track)
        withContext(Dispatchers.IO) {
            withTimeout(5000) { while (download.isDownloading(track.key)) delay(5) }
        }
        assertFalse(download.isDownloading(track.key))
    }

    private fun fixtureDownload(
        stream: ResolvedStream,
        bytes: ByteArray,
        mime: String = "audio/mp4",
        finalUrl: String = url,
        declaredLength: Long = bytes.size.toLong(),
        status: Int = 200,
        contentRange: String? = null,
    ): DownloadManager {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val body = bytes.toResponseBody(mime.toMediaType())
            Response.Builder().request(chain.request().newBuilder().url(finalUrl).build())
                .protocol(Protocol.HTTP_1_1).code(status).message("Fixture")
                .apply { contentRange?.let { header("Content-Range", it) } }
                .body(object : ResponseBody() {
                    override fun contentType() = body.contentType()
                    override fun contentLength() = declaredLength
                    override fun source() = body.source()
                }).build()
        }.build()
        return DownloadManager(context, dao, settings, resolver, resolveStream = { stream }, client = client)
    }

    private fun completed(track: Track, file: File) = DownloadEntity(
        trackKey = track.key,
        track = track.toData(),
        filePath = file.absolutePath,
        bytes = file.length(),
        quality = "best",
        status = "DONE",
        createdAt = 1L,
    )

    private class FakeDownloadDao : DownloadDao {
        private val entries = linkedMapOf<String, DownloadEntity>()

        override fun all(): Flow<List<DownloadEntity>> = flowOf(entries.values.toList())
        override fun completed(): Flow<List<DownloadEntity>> = flowOf(completedEntries())
        override suspend fun byKey(key: String): DownloadEntity? = entries[key]
        override suspend fun completedOnce(): List<DownloadEntity> = completedEntries()
        override suspend fun upsert(entity: DownloadEntity) { entries[entity.trackKey] = entity }
        override suspend fun setStatus(key: String, status: String, error: String) {
            entries[key]?.let { entries[key] = it.copy(status = status, error = error) }
        }
        override suspend fun setBytes(key: String, bytes: Long) {
            entries[key]?.let { entries[key] = it.copy(bytes = bytes) }
        }
        override suspend fun complete(key: String, path: String, bytes: Long, status: String) {
            entries[key]?.let { entries[key] = it.copy(filePath = path, bytes = bytes, status = status, error = "") }
        }
        override suspend fun delete(key: String) { entries.remove(key) }
        override suspend fun clear() { entries.clear() }
        override fun totalBytes(): Flow<Long?> = flowOf(completedEntries().sumOf { it.bytes })

        private fun completedEntries() = entries.values.filter { it.status == "DONE" }
    }
}
