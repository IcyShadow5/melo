package app.melo.player.playback

import android.os.Looper
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.CacheDataSource
import androidx.test.core.app.ApplicationProvider
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.common.MediaItem
import androidx.media3.common.Timeline
import app.melo.player.data.model.ResolvedStream
import app.melo.player.data.model.Track
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class TrackMediaSourceFactoryTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    private val item = MediaItems.from(Track("id", "Title", "Artist", album = "Album"))
    private val manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.aac\n#EXT-X-ENDLIST\n"

    @Test
    fun `provider HLS flag selects an HLS source before opening media`() {
        checkStream(ResolvedStream.Remote("https://fixture.invalid/manifest", hls = true)) { selected, resolved ->
            assertTrue(selected is HlsMediaSource)
            assertEquals("application/x-mpegURL", resolved.localConfiguration?.mimeType)
            assertNull(resolved.localConfiguration?.customCacheKey)
        }
    }

    @Test
    fun `HLS extension is recognized with query fragment and mixed case`() {
        checkStream(ResolvedStream.Remote("https://fixture.invalid/list.M3U8?token=1#fragment")) { selected, _ ->
            assertTrue(selected is HlsMediaSource)
        }
    }

    @Test
    fun `progressive media keeps its stable cache key and resolved URL`() {
        val url = "https://fixture.invalid/audio.m4a?hint=list.m3u8"
        checkStream(ResolvedStream.Remote(url)) { selected, resolved ->
            assertTrue(selected is ProgressiveMediaSource)
            assertEquals(url, resolved.localConfiguration?.uri.toString())
            assertEquals("youtube:id", resolved.localConfiguration?.customCacheKey)
        }
    }

    @Test
    fun `existing local files remain file backed progressive media`() {
        val file = temporaryFolder.newFile("legacy audio.m4a")
        checkStream(ResolvedStream.Local(file.absolutePath)) { selected, resolved ->
            assertTrue(selected is ProgressiveMediaSource)
            assertEquals("file", resolved.localConfiguration?.uri?.scheme)
            assertEquals(file.absolutePath, resolved.localConfiguration?.uri?.path)
        }
        assertTrue(file.exists())
    }

    @Test
    fun `ordinary media items bypass track resolution`() {
        val defaultFactory = DefaultMediaSourceFactory { ByteArrayDataSource(byteArrayOf(0)) }
        val factory = TrackMediaSourceFactory(defaultFactory, { defaultFactory }) {
            throw AssertionError("Unexpected resolver call")
        }
        assertTrue(factory.createMediaSource(MediaItem.fromUri("file:///fixture.m4a")) is ProgressiveMediaSource)
    }

    @Test
    fun `provider failure and resolver exceptions surface as source errors`() {
        for (result in listOf<suspend (Track) -> ResolvedStream>(
            { ResolvedStream.Failure("Fixture unavailable") },
            { throw IOException("Fixture unavailable") },
        )) {
            val defaultFactory = DefaultMediaSourceFactory { ByteArrayDataSource(byteArrayOf(0)) }
            val factory = TrackMediaSourceFactory(defaultFactory, { defaultFactory }, resolve = result)
            val source = factory.createMediaSource(item)
            val caller = MediaSource.MediaSourceCaller { _, _ -> }
            try {
                source.prepareSource(caller, null, PlayerId.UNSET)
                var failure: IOException? = null
                await {
                    try { source.maybeThrowSourceInfoRefreshError() } catch (e: IOException) { failure = e }
                    failure != null
                }
                assertEquals("Fixture unavailable", failure?.message)
            } finally {
                source.releaseSource(caller)
            }
        }
    }

    @Test
    fun `release cancels pending resolution and prevents late child preparation`() {
        val entered = AtomicBoolean(false)
        val cancelled = AtomicBoolean(false)
        val gate = CompletableDeferred<ResolvedStream>()
        val defaultFactory = DefaultMediaSourceFactory { ByteArrayDataSource(byteArrayOf(0)) }
        val factory = TrackMediaSourceFactory(defaultFactory, { defaultFactory }) {
            entered.set(true)
            try { gate.await() } finally { cancelled.set(true) }
        }
        val source = factory.createMediaSource(item)
        var refreshed = false
        val caller = MediaSource.MediaSourceCaller { _, _ -> refreshed = true }
        source.prepareSource(caller, null, PlayerId.UNSET)
        await { entered.get() }
        source.releaseSource(caller)
        gate.complete(ResolvedStream.Remote("https://fixture.invalid/audio.m4a"))
        await { cancelled.get() }
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse(refreshed)
    }

    @Test
    fun `progressive opens refresh expired URLs on seeks while retaining cached bytes and track identity`() {
        val firstUrl = "https://fixture.invalid/audio.m4a?token=A"
        val nextUrl = "https://fixture.invalid/audio.m4a?token=B"
        val payload = "abcdefgh".toByteArray()
        var expired = false
        var resolutions = 0
        val opened = mutableListOf<DataSpec>()
        val upstream = DataSource.Factory {
            val bytes = ByteArrayDataSource(payload)
            object : DataSource by bytes {
                override fun open(dataSpec: DataSpec): Long {
                    opened += dataSpec
                    if (expired && dataSpec.uri.toString() == firstUrl) throw IOException("URL A expired")
                    return bytes.open(dataSpec)
                }
            }
        }
        val database = StandaloneDatabaseProvider(ApplicationProvider.getApplicationContext())
        val cache = SimpleCache(temporaryFolder.newFolder("cache"), NoOpCacheEvictor(), database)
        val cached = CacheDataSource.Factory().setCache(cache).setUpstreamDataSourceFactory(upstream)
        val resolve: suspend (Track) -> ResolvedStream = {
            resolutions++
            ResolvedStream.Remote(if (expired) nextUrl else firstUrl)
        }
        val progressive = progressiveDataSourceFactory(cached, checkNotNull(TrackCodec.fromUri(item.localConfiguration!!.uri)), resolve)
        val defaultFactory = DefaultMediaSourceFactory(cached)
        var selected: MediaItem? = null
        val recording = object : MediaSource.Factory by defaultFactory {
            override fun createMediaSource(mediaItem: MediaItem): MediaSource {
                selected = mediaItem
                return DefaultMediaSourceFactory(progressive).createMediaSource(mediaItem)
            }
        }
        val factory = TrackMediaSourceFactory(defaultFactory, { recording }, resolve = resolve)
        val source = factory.createMediaSource(item)
        val caller = MediaSource.MediaSourceCaller { _, _ -> }
        try {
            source.prepareSource(caller, null, PlayerId.UNSET)
            await { selected != null }
            val base = DataSpec.Builder().setUri(selected!!.localConfiguration!!.uri)
                .setKey(selected!!.localConfiguration!!.customCacheKey).setLength(4).build()
            assertEquals("abcd", String(read(progressive, base)))
            expired = true
            assertEquals("efgh", String(read(progressive, base.buildUpon().setPosition(4).build())))
            assertEquals(listOf(firstUrl, nextUrl), opened.map { it.uri.toString() })
            assertEquals(listOf(0L, 4L), opened.map { it.position })
            assertEquals(setOf(item.mediaId), cache.keys)
            assertEquals(3, resolutions)
            assertEquals("abcd", String(read(progressive, base)))
            assertEquals(2, opened.size)
            assertEquals(4, resolutions)
            assertEquals(item, source.mediaItem)
        } finally {
            source.releaseSource(caller)
            cache.release()
            database.close()
        }
    }

    @Test
    fun `HLS playlist reads bypass the persistent audio cache and see updated bytes`() {
        val url = "https://fixture.invalid/live.m3u8"
        val playlist = AtomicReference(manifest.replace("segment.aac", "segment-a.aac"))
        val requests = CopyOnWriteArrayList<String>()
        val upstream = DataSource.Factory {
            val bytes = ByteArrayDataSource(playlist.get().toByteArray())
            object : DataSource by bytes {
                override fun open(dataSpec: DataSpec): Long {
                    requests += dataSpec.uri.toString()
                    return bytes.open(dataSpec)
                }
            }
        }
        val database = StandaloneDatabaseProvider(ApplicationProvider.getApplicationContext())
        val cache = SimpleCache(temporaryFolder.newFolder("hls-cache"), NoOpCacheEvictor(), database)
        val cached = CacheDataSource.Factory().setCache(cache).setUpstreamDataSourceFactory(upstream)
        val track = checkNotNull(TrackCodec.fromUri(item.localConfiguration!!.uri))

        var selected: MediaSource? = null
        val hls = object : MediaSource.Factory by DefaultMediaSourceFactory(upstream) {
            override fun createMediaSource(mediaItem: MediaItem): MediaSource =
                DefaultMediaSourceFactory(upstream).createMediaSource(mediaItem).also { selected = it }
        }
        val factory = TrackMediaSourceFactory(
            DefaultMediaSourceFactory(cached),
            { DefaultMediaSourceFactory(cached) },
            hlsFactory = hls,
        ) {
            ResolvedStream.Remote(url, hls = true)
        }
        val source = factory.createMediaSource(item)
        val caller = MediaSource.MediaSourceCaller { _, _ -> }
        try {
            source.prepareSource(caller, null, PlayerId.UNSET)
            await { selected != null && requests.isNotEmpty() }
            assertTrue(selected is HlsMediaSource)

            val spec = DataSpec.Builder().setUri(url).setKey(track.key).build()
            val original = String(read(cached, spec))
            assertTrue(original.contains("segment-a.aac"))
            assertEquals(original, String(read(cached, spec)))

            playlist.set(playlist.get().replace("segment-a.aac", "segment-b.aac"))
            assertEquals(original, String(read(cached, spec)))
            val updated = String(read(upstream, spec))
            assertTrue(updated.contains("segment-b.aac"))
            assertNotEquals(original, updated)
        } finally {
            source.releaseSource(caller)
            cache.release()
            database.close()
        }
    }

    @Test
    fun `progressive reopening refuses an HLS format switch`() {
        var opened = false
        val upstream = DataSource.Factory {
            val bytes = ByteArrayDataSource(byteArrayOf(0))
            object : DataSource by bytes {
                override fun open(dataSpec: DataSpec): Long {
                    opened = true
                    return bytes.open(dataSpec)
                }
            }
        }
        val track = checkNotNull(TrackCodec.fromUri(item.localConfiguration!!.uri))
        val dataSources = progressiveDataSourceFactory(upstream, track) {
            ResolvedStream.Remote("https://fixture.invalid/manifest", hls = true)
        }
        val error = runCatching { read(dataSources, DataSpec.Builder().setUri("https://fixture.invalid/old.m4a").build()) }.exceptionOrNull()
        assertTrue(error is IOException)
        assertFalse(opened)
    }

    @Test
    fun `resolution errors are published only through the playback handler`() {
        val scheduler = TestCoroutineScheduler()
        val defaultFactory = DefaultMediaSourceFactory { ByteArrayDataSource(byteArrayOf(0)) }
        val factory = TrackMediaSourceFactory(defaultFactory, { defaultFactory }, StandardTestDispatcher(scheduler)) {
            throw IOException("Fixture unavailable")
        }
        val source = factory.createMediaSource(item)
        val caller = MediaSource.MediaSourceCaller { _, _ -> }
        try {
            source.prepareSource(caller, null, PlayerId.UNSET)
            scheduler.runCurrent()
            assertNull(runCatching { source.maybeThrowSourceInfoRefreshError() }.exceptionOrNull())
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("Fixture unavailable", runCatching { source.maybeThrowSourceInfoRefreshError() }.exceptionOrNull()?.message)
        } finally {
            source.releaseSource(caller)
        }
    }

    @Test
    fun `delayed old resolver error cannot poison release and reprepare of the same source`() {
        val scheduler = TestCoroutineScheduler()
        val gate = CompletableDeferred<Unit>()
        var resolutions = 0
        val defaultFactory = DefaultMediaSourceFactory { ByteArrayDataSource(byteArrayOf(0)) }
        val factory = TrackMediaSourceFactory(defaultFactory, { defaultFactory }, StandardTestDispatcher(scheduler)) {
            if (++resolutions == 1) withContext(NonCancellable) {
                gate.await()
                throw IOException("Old generation failed")
            }
            ResolvedStream.Remote("https://fixture.invalid/current.m4a")
        }
        val source = factory.createMediaSource(item)
        var refreshes = 0
        val caller = MediaSource.MediaSourceCaller { _, timeline ->
            refreshes++
            assertEquals(item, timeline.getWindow(0, Timeline.Window()).mediaItem)
        }
        source.prepareSource(caller, null, PlayerId.UNSET)
        scheduler.runCurrent()
        source.releaseSource(caller)
        try {
            source.prepareSource(caller, null, PlayerId.UNSET)
            scheduler.runCurrent()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, refreshes)
            gate.complete(Unit)
            scheduler.runCurrent()
            shadowOf(Looper.getMainLooper()).idle()
            source.maybeThrowSourceInfoRefreshError()
            assertEquals(2, resolutions)
            assertEquals(1, refreshes)
            assertEquals(item, source.mediaItem)
        } finally {
            source.releaseSource(caller)
        }
        source.prepareSource(caller, null, PlayerId.UNSET)
        try {
            scheduler.runCurrent()
            shadowOf(Looper.getMainLooper()).idle()
            source.maybeThrowSourceInfoRefreshError()
            assertEquals(3, resolutions)
            assertEquals(2, refreshes)
        } finally {
            source.releaseSource(caller)
        }
    }

    private fun read(factory: DataSource.Factory, spec: DataSpec): ByteArray {
        val source = factory.createDataSource()
        try {
            source.open(spec)
            val result = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16)
            while (true) {
                val count = source.read(buffer, 0, buffer.size)
                if (count == -1) break
                result.write(buffer, 0, count)
            }
            return result.toByteArray()
        } finally {
            source.close()
        }
    }

    private fun checkStream(stream: ResolvedStream, check: (MediaSource, MediaItem) -> Unit) {
        val defaultFactory = DefaultMediaSourceFactory { ByteArrayDataSource(manifest.toByteArray()) }
        var selected: MediaSource? = null
        var resolved: MediaItem? = null
        var timeline: Timeline? = null
        val recordingFactory = object : MediaSource.Factory by defaultFactory {
            override fun createMediaSource(mediaItem: MediaItem): MediaSource {
                resolved = mediaItem
                return defaultFactory.createMediaSource(mediaItem).also { selected = it }
            }
        }
        val factory = TrackMediaSourceFactory(recordingFactory, { recordingFactory }) { stream }
        val source = factory.createMediaSource(item)
        val caller = MediaSource.MediaSourceCaller { _, value -> timeline = value }
        try {
            source.prepareSource(caller, null, PlayerId.UNSET)
            await { selected != null && timeline != null }
            check(checkNotNull(selected), checkNotNull(resolved))
            assertEquals(item, source.mediaItem)
            assertEquals(item, checkNotNull(timeline).getWindow(0, Timeline.Window()).mediaItem)
            assertEquals(item.mediaMetadata, resolved?.mediaMetadata)
            assertEquals(listOf(Track("id", "Title", "Artist", album = "Album")), MediaItems.tracks(listOf(source.mediaItem)))
        } finally {
            source.releaseSource(caller)
        }
    }

    private fun await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (!condition() && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertTrue("Timed out waiting for media source", condition())
    }
}
