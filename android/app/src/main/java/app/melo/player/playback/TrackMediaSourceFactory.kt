package app.melo.player.playback

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.source.CompositeMediaSource
import androidx.media3.exoplayer.source.ForwardingTimeline
import androidx.media3.exoplayer.source.MediaPeriod
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.Allocator
import app.melo.player.data.model.ResolvedStream
import app.melo.player.data.model.Track
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.IOException

@OptIn(UnstableApi::class)
internal class TrackMediaSourceFactory(
    private val delegate: MediaSource.Factory,
    private val progressiveFactory: (Track) -> MediaSource.Factory,
    private val resolutionDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val hlsFactory: MediaSource.Factory = delegate,
    private val resolve: suspend (Track) -> ResolvedStream,
) : MediaSource.Factory by delegate {
    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val track = mediaItem.localConfiguration?.uri?.let(TrackCodec::fromUri)
            ?: return delegate.createMediaSource(mediaItem)
        return TrackMediaSource(
            mediaItem,
            track,
            delegate,
            progressiveFactory,
            resolutionDispatcher,
            hlsFactory,
            resolve,
        )
    }
}

/** Resolves lazily off the playback thread, before the child source type is chosen. */
@OptIn(UnstableApi::class)
private class TrackMediaSource(
    private val original: MediaItem,
    private val track: Track,
    private val factory: MediaSource.Factory,
    private val progressiveFactory: (Track) -> MediaSource.Factory,
    private val resolutionDispatcher: CoroutineDispatcher,
    private val hlsFactory: MediaSource.Factory,
    private val resolve: suspend (Track) -> ResolvedStream,
) : CompositeMediaSource<Unit>() {
    private var child: MediaSource? = null
    private var scope: CoroutineScope? = null
    private var handler: Handler? = null
    private var error: IOException? = null
    private var generation = 0L

    override fun getMediaItem(): MediaItem = original

    override fun prepareSourceInternal(mediaTransferListener: TransferListener?) {
        super.prepareSourceInternal(mediaTransferListener)
        val preparedGeneration = ++generation
        error = null
        val callback = Handler(checkNotNull(Looper.myLooper()))
        val work = CoroutineScope(SupervisorJob() + resolutionDispatcher)
        handler = callback
        scope = work
        work.launch {
            try {
                val stream = resolve(track)
                val item = when (stream) {
                    is ResolvedStream.Remote -> original.buildUpon()
                        .setUri(stream.url)
                        .setMimeType(if (stream.isHls) MimeTypes.APPLICATION_M3U8 else null)
                        // HLS manifests, keys and segments must have separate cache identities.
                        .setCustomCacheKey(if (stream.isHls) null else track.key)
                        .build()
                    is ResolvedStream.Local -> original.buildUpon()
                        .setUri(Uri.fromFile(File(stream.path)))
                        .setMimeType(null)
                        .setCustomCacheKey(track.key)
                        .build()
                    is ResolvedStream.Failure -> throw IOException(stream.message)
                }
                callback.post {
                    if (generation == preparedGeneration && scope === work && work.isActive) {
                        try {
                            val selectedFactory = when {
                                stream is ResolvedStream.Remote && stream.isHls -> hlsFactory
                                stream is ResolvedStream.Remote -> progressiveFactory(track)
                                else -> factory
                            }
                            child = selectedFactory.createMediaSource(item)
                            prepareChildSource(Unit, checkNotNull(child))
                        } catch (e: Exception) {
                            error = IOException("Could not prepare this stream.", e)
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val failure = e as? IOException ?: IOException("Could not resolve this stream.", e)
                callback.post {
                    if (generation == preparedGeneration && scope === work && work.isActive) error = failure
                }
            }
        }
    }

    override fun maybeThrowSourceInfoRefreshError() {
        error?.let { throw it }
        super.maybeThrowSourceInfoRefreshError()
    }

    override fun onChildSourceInfoRefreshed(id: Unit, mediaSource: MediaSource, newTimeline: Timeline) {
        if (mediaSource !== child) return
        // Controllers decode the original URI for queue state, history and resume.
        refreshSourceInfo(object : ForwardingTimeline(newTimeline) {
            override fun getWindow(index: Int, window: Timeline.Window, projectionUs: Long): Timeline.Window =
                super.getWindow(index, window, projectionUs).apply { mediaItem = original }
        })
    }

    override fun createPeriod(id: MediaSource.MediaPeriodId, allocator: Allocator, startPositionUs: Long): MediaPeriod =
        checkNotNull(child).createPeriod(id, allocator, startPositionUs)

    override fun releasePeriod(mediaPeriod: MediaPeriod) = checkNotNull(child).releasePeriod(mediaPeriod)

    override fun releaseSourceInternal() {
        generation++
        scope?.cancel()
        scope = null
        handler?.removeCallbacksAndMessages(null)
        handler = null
        super.releaseSourceInternal()
        child = null
        error = null
    }
}

internal fun progressiveDataSourceFactory(
    upstream: DataSource.Factory,
    track: Track,
    resolve: suspend (Track) -> ResolvedStream,
): DataSource.Factory = ResolvingDataSource.Factory(upstream) { dataSpec ->
    val uri = when (val stream = runBlocking { resolve(track) }) {
        is ResolvedStream.Remote -> {
            if (stream.isHls) throw IOException("This stream changed to HLS. Prepare the track again.")
            Uri.parse(stream.url)
        }
        is ResolvedStream.Local -> Uri.fromFile(File(stream.path))
        is ResolvedStream.Failure -> throw IOException(stream.message)
    }
    dataSpec.withUri(uri).buildUpon().setKey(track.key).build()
}
