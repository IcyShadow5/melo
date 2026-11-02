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

    private val url = "https://example.com/audio?mime=audio%2Fmp4"

    private fun track(id: String) = Track(id = id, title = "Same title", artist = "Same artist")

    @Before
    fun setUp() {
        val context = object : ContextWrapper(null) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = temporaryFolder.root
            override fun getExternalFilesDir(type: String?): File = temporaryFolder.root
        }
        dao = FakeDownloadDao()
        val settings = SettingsRepository(context)
        resolver = StreamResolver(dao, settings)
        manager = DownloadManager(context, dao, settings, resolver)
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
