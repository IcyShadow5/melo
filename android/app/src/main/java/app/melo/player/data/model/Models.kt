package app.melo.player.data.model

import kotlinx.serialization.Serializable

/**
 * Where a track can be resolved from. The desktop app supported YouTube Music,
 * YouTube, SoundCloud and local files; Android mirrors that set.
 */
enum class Source {
    YOUTUBE, SOUNDCLOUD, LOCAL;

    val label: String
        get() = when (this) {
            YOUTUBE -> "YouTube Music"
            SOUNDCLOUD -> "SoundCloud"
            LOCAL -> "Offline"
        }
}

@Serializable
data class Track(
    val id: String,
    val title: String,
    val artist: String,
    val album: String = "",
    val durationMs: Long = 0L,
    val artwork: String = "",
    val source: Source = Source.YOUTUBE,
    val explicit: Boolean = false,
    /** Direct, short-lived media URL when a provider already handed one over. */
    val streamUrl: String = "",
    /** Provider page URL, used as a hint for resolution. */
    val webUrl: String = "",
    /**
     * Catalog tracks that are only known by metadata (imports, third-party album pages)
     * carry a query instead of an id and are resolved against the provider on demand.
     */
    val searchQuery: String = "",
) {
    /** Stable identity across duplicates, used for favourites/history/downloads. */
    val key: String
        get() = if (id.isNotBlank()) {
            "${source.name.lowercase()}:$id"
        } else {
            "query:" + searchQuery.lowercase().replace(Regex("[^\\p{L}\\p{N}]"), "").take(80)
        }

    fun displayLine(): String = if (album.isBlank()) artist else "$artist · $album"
}

@Serializable
data class Album(
    val id: String,
    val title: String,
    val artist: String,
    val artwork: String = "",
    val year: String = "",
    val trackCount: Int = 0,
)

@Serializable
data class Artist(
    val id: String,
    val name: String,
    val artwork: String = "",
    val banner: String = "",
    val monthlyListeners: Long = 0L,
    val bio: String = "",
    val verified: Boolean = false,
)

data class ArtistPage(
    val artist: Artist,
    val topTracks: List<Track> = emptyList(),
    val albums: List<Album> = emptyList(),
    val singles: List<Album> = emptyList(),
    val related: List<Artist> = emptyList(),
)

data class AlbumPage(
    val album: Album,
    val tracks: List<Track> = emptyList(),
)

data class Playlist(
    val id: Long,
    val name: String,
    val trackCount: Int,
    val createdAt: Long,
    val updatedAt: Long,
    val coverArtwork: String = "",
    val isFavorites: Boolean = false,
)

data class SearchResults(
    val tracks: List<Track> = emptyList(),
    val artists: List<Artist> = emptyList(),
    val albums: List<Album> = emptyList(),
    val playlists: List<SearchPlaylist> = emptyList(),
)

/** A playlist as returned by a provider (not yet a user playlist). */
data class SearchPlaylist(
    val id: String,
    val title: String,
    val owner: String = "",
    val artwork: String = "",
    val trackCount: Int = 0,
    val source: Source = Source.YOUTUBE,
)

data class HomeSection(
    val id: String,
    val title: String,
    val subtitle: String = "",
    val tracks: List<Track> = emptyList(),
    val albums: List<Album> = emptyList(),
    val artists: List<Artist> = emptyList(),
    val kind: Kind = Kind.TRACKS,
) {
    enum class Kind { TRACKS, ALBUMS, ARTISTS }
    val isEmpty: Boolean
        get() = tracks.isEmpty() && albums.isEmpty() && artists.isEmpty()
}

/** Result of resolving a playable URL for [Track]. */
sealed interface ResolvedStream {
    data class Remote(val url: String, val hls: Boolean = false) : ResolvedStream {
        val isHls: Boolean
            get() = hls || runCatching {
                java.net.URI(url).path.orEmpty().endsWith(".m3u8", ignoreCase = true)
            }.getOrDefault(false)
    }
    data class Local(val path: String) : ResolvedStream
    data class Failure(val message: String) : ResolvedStream
}

enum class StreamQuality(val label: String, val id: String) {
    NORMAL("Normal", "normal"),
    HIGH("High", "high"),
    BEST("Best available", "best"),
}
