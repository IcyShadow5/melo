package app.melo.player.playback

import android.app.PendingIntent
import android.content.Intent
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.melo.player.MainActivity
import app.melo.player.data.remote.Api
import app.melo.player.di.ServiceLocator
import kotlinx.coroutines.runBlocking
import java.io.File

/**
 * Foreground playback service.
 *
 * Media3 owns the notification, the lock-screen controls, audio focus, headphone
 * unplug handling and the media button receiver, so playback keeps running when the
 * activity is destroyed, the screen is off or another app is in front. There is
 * exactly one ExoPlayer instance per process.
 */
@OptIn(UnstableApi::class)
class MeloPlaybackService : MediaSessionService() {

    private var player: ExoPlayer? = null
    private var session: MediaSession? = null
    private var audioCache: SimpleCache? = null

    override fun onCreate() {
        super.onCreate()
        ServiceLocator.init(this)

        val router = buildHostRoutingDataSourceFactory()
        val dataSources = buildCachedDataSourceFactory(router)
        val resolve = ServiceLocator.resolver::resolve
        val mediaSourceFactory = TrackMediaSourceFactory(
            DefaultMediaSourceFactory(dataSources),
            progressiveFactory = { track ->
                DefaultMediaSourceFactory(progressiveDataSourceFactory(dataSources, track, resolve))
            },
            // Live HLS playlists change behind an unchanged URL, so they must not
            // reuse the persistent progressive-audio cache.
            hlsFactory = DefaultMediaSourceFactory(router),
            resolve = resolve,
        )
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs = */ 30_000,
                /* maxBufferMs = */ 120_000,
                /* bufferForPlaybackMs = */ 1_500,
                /* bufferForPlaybackAfterRebufferMs = */ 3_000,
            )
            .build()

        val exo = ExoPlayer.Builder(this)
            .setMediaSourceFactory(mediaSourceFactory)
            .setLoadControl(loadControl)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()

        exo.repeatMode = Player.REPEAT_MODE_OFF

        val sessionActivity = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        session = MediaSession.Builder(this, exo)
            .setSessionActivity(sessionActivity)
            .setCallback(MeloSessionCallback())
            .build()

        player = exo
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /**
     * Keep playing when the user swipes the app away, unless nothing is playing —
     * then let the service go so the notification does not linger.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val exo = player
        if (exo == null || !exo.playWhenReady || exo.mediaItemCount == 0) {
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        player = null
        audioCache?.release()
        audioCache = null
        super.onDestroy()
    }

    private inner class MeloSessionCallback : MediaSession.Callback {
        override fun onPlaybackResumption(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): com.google.common.util.concurrent.ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            // Hand the session the last thing the user played so headset/Bluetooth
            // "resume" works after the process was killed.
            val future = com.google.common.util.concurrent.SettableFuture
                .create<MediaSession.MediaItemsWithStartPosition>()
            Thread {
                runCatching {
                    val settings = runBlocking { ServiceLocator.settings.current() }
                    val last = runBlocking { ServiceLocator.library.lastPlayed() }
                    if (!settings.resumeOnStart || last == null) {
                        future.set(
                            MediaSession.MediaItemsWithStartPosition(emptyList(), 0, 0L),
                        )
                    } else {
                        future.set(
                            MediaSession.MediaItemsWithStartPosition(
                                listOf(MediaItems.from(last)),
                                0,
                                0L,
                            ),
                        )
                    }
                }.onFailure {
                    future.set(MediaSession.MediaItemsWithStartPosition(emptyList(), 0, 0L))
                }
            }.start()
            return future
        }
    }

    /**
     * Host-aware HTTP/File routing shared by cached progressive audio and
     * uncached HLS playback. Google's CDN and ordinary hosts need different
     * client identities, and local downloads stay plain files.
     */
    private fun buildHostRoutingDataSourceFactory(): DataSource.Factory {
        val googleHttp = OkHttpDataSource.Factory(Api.streamingClient)
            .setDefaultRequestProperties(mapOf("User-Agent" to Api.ANDROID_VR_UA))
        val otherHttp = OkHttpDataSource.Factory(Api.streamingClient)
            .setDefaultRequestProperties(mapOf("User-Agent" to Api.WEB_UA))
        val fileFactory = DefaultDataSource.Factory(this)

        return HostRoutingDataSource.Factory(googleHttp, otherHttp, fileFactory)
    }

    /**
     * Cache -> HTTP/File for progressive audio and local files. HLS deliberately
     * uses the uncached router so playlist refreshes always reach the provider.
     */
    private fun buildCachedDataSourceFactory(router: DataSource.Factory): DataSource.Factory {
        val cacheDir = File(cacheDir, "audio")
        val limitMb = runCatching { runBlocking { ServiceLocator.settings.current().cacheLimitMb } }
            .getOrDefault(512)
        val cache = SimpleCache(
            cacheDir,
            LeastRecentlyUsedCacheEvictor(limitMb.toLong() * 1024 * 1024),
            StandaloneDatabaseProvider(this),
        )
        audioCache = cache

        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(router)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }
}

/**
 * Routes each request to the right upstream: Google's CDN needs the client identity
 * the stream URL was issued to, everything else is a normal web request, and local
 * downloads are plain files.
 */
@OptIn(UnstableApi::class)
class HostRoutingDataSource private constructor(
    private val google: DataSource.Factory,
    private val web: DataSource.Factory,
    private val files: DataSource.Factory,
) : DataSource {

    private var delegate: DataSource? = null
    private var transferListener: androidx.media3.datasource.TransferListener? = null

    class Factory(
        private val google: DataSource.Factory,
        private val web: DataSource.Factory,
        private val files: DataSource.Factory,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource = HostRoutingDataSource(google, web, files)
    }

    override fun open(dataSpec: DataSpec): Long {
        val host = dataSpec.uri.host.orEmpty()
        val scheme = dataSpec.uri.scheme.orEmpty()
        val chosen = when {
            scheme == "file" || scheme == "content" -> files
            host.contains("googlevideo") || host.contains("youtube") || host.contains("ytimg") -> google
            else -> web
        }
        val source = chosen.createDataSource()
        transferListener?.let(source::addTransferListener)
        delegate = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        delegate?.read(buffer, offset, length) ?: -1

    override fun addTransferListener(transferListener: androidx.media3.datasource.TransferListener) {
        this.transferListener = transferListener
        delegate?.addTransferListener(transferListener)
    }

    override fun getUri(): android.net.Uri? = delegate?.uri

    override fun close() {
        delegate?.close()
        delegate = null
    }
}

/** Builds the MediaItem for a track, keeping metadata for the notification and lock screen. */
object MediaItems {
    @OptIn(UnstableApi::class)
    fun from(track: app.melo.player.data.model.Track): androidx.media3.common.MediaItem {
        val metadata = androidx.media3.common.MediaMetadata.Builder()
            .setTitle(track.title)
            .setArtist(track.artist)
            .setAlbumTitle(track.album.takeIf { it.isNotBlank() })
            .setArtworkUri(track.artwork.takeIf { it.isNotBlank() }?.let { android.net.Uri.parse(it) })
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .build()
        return androidx.media3.common.MediaItem.Builder()
            .setUri(TrackCodec.uriFor(track))
            .setMediaId(track.key)
            .setMediaMetadata(metadata)
            .build()
    }

    fun tracks(items: List<androidx.media3.common.MediaItem>): List<app.melo.player.data.model.Track> =
        items.mapNotNull { item -> item.localConfiguration?.uri?.let(TrackCodec::fromUri) }
}

