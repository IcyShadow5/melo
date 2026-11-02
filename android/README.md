# melo for Android

melo is the Android build of this repository's music player. It keeps the desktop
app's idea — a fast, telemetry-free player that unifies YouTube Music, SoundCloud and
offline listening — and rebuilds it as a native Kotlin / Jetpack Compose application
with a real Media3 background playback service.

- **Package:** `app.melo.player`
- **Minimum Android:** 8.0 (API 26), target API 35
- **Language / UI:** Kotlin, Jetpack Compose, Material 3
- **Audio:** AndroidX Media3 (ExoPlayer) with a `MediaSessionService`

The Electron desktop app in the repository root is untouched and still builds
separately. This folder is a self-contained Gradle project.

---

## 1. Quick start

```bash
cd android
./gradlew assembleDebug        # debug APK
./gradlew testDebugUnitTest    # JVM test suite
./gradlew assembleRelease      # release APK (signed when the env vars below are set)
```

Artifacts:

| Build | Path |
|---|---|
| Debug | `app/build/outputs/apk/debug/app-debug.apk` |
| Release (signed) | `app/build/outputs/apk/release/app-release.apk` |
| Release (no signing config) | `app/build/outputs/apk/release/app-release-unsigned.apk` |

`local.properties` needs `sdk.dir=/path/to/Android/sdk` (or set `ANDROID_HOME`).
Nothing else is required; the Gradle wrapper pins Gradle 8.11.1 and every dependency
version is fixed in `build.gradle.kts`.

### Release signing environment variables

`app/build.gradle.kts` reads signing material **only** from the environment. There is
no keystore path, password or alias in any committed file.

| Variable | Meaning |
|---|---|
| `MELO_KEYSTORE_PATH` | absolute path to the `.jks` file |
| `MELO_KEYSTORE_PASSWORD` | keystore password |
| `MELO_KEY_ALIAS` | key alias |
| `MELO_KEY_PASSWORD` | key password |
| `MELO_VERSION_NAME` | version name (default `1.0.0`) |
| `MELO_VERSION_CODE` | version code (default `1`) |

If the four signing values are absent the release build still succeeds but produces an
**unsigned** APK, which is deliberate: local builds work without secrets, while the
CI workflow hard-fails before building if any secret is missing.

---

## 2. Create your permanent release keystore

Do this once. **Keep the `.jks` file and both passwords backed up somewhere safe.** If
you lose them you can never publish an update that installs over an existing melo
version — Android requires the same signing identity for updates.

> Never generate the keystore with an online "APK signer" website, and never paste the
> passwords into a chat, issue or commit. Anyone with the keystore + passwords can
> publish updates as you.

### Option A — a computer with a JDK (recommended)

```bash
keytool -genkeypair -v \
  -keystore melo-release.jks \
  -alias melo \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=melo, O=melo, C=US"
```

`keytool` asks for a keystore password and a key password. Use the **same** password
for both unless you have a reason not to; the workflow accepts either.

Check it, then encode it:

```bash
keytool -list -keystore melo-release.jks -alias melo
base64 -w0 melo-release.jks > melo-release.jks.b64     # macOS: base64 -i melo-release.jks -o melo-release.jks.b64
```

Store `melo-release.jks` and the passwords in a password manager, and keep an offline
copy of the `.jks`.

### Option B — phone only, with Termux

No computer needed. Termux is a terminal for Android (install it from F-Droid, not the
Play Store build).

Install Git, a JDK and the GitHub CLI once:

```bash
pkg update && pkg install git openjdk-17 gh -y
```

Get the intended repository and open it (signing secrets belong to **hakosworld-blip/melo**,
not to a fork):

```bash
git clone https://github.com/hakosworld-blip/melo.git
cd melo
```

If melo has already been released, **restore the original `melo-release.jks` from your
backup** instead of creating a new key. Termux can read shared storage after
`termux-setup-storage`, for example:

```bash
termux-setup-storage
cp ~/storage/downloads/melo-release.jks ~/melo-release.jks
```

Create the key only if you have never published a release:

```bash
keytool -genkeypair -v \
  -keystore ~/melo-release.jks \
  -alias melo \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=melo, O=melo, C=US"
```

**Never create a second key to "fix" an upload problem.** Android only installs an
update signed by the same key, so keep the existing `melo-release.jks` and repair the
secret instead.

Authenticate `gh` once, then verify the existing key and upload all four secrets:

```bash
gh auth login                     # GitHub.com, HTTPS, browser
bash android/scripts/setup-termux-signing.sh --keystore ~/melo-release.jks
```

The helper shows the resolved `owner/name` and asks you to confirm it before uploading
anything. It refuses to upload from a checkout that resolves to any repository other
than `hakosworld-blip/melo`. If you are working from a fork, pass
`--repo hakosworld-blip/melo` (you need permission to set that repository's secrets).
Only when a different repository is deliberate, add `--allow-non-target-repo` and type
the repository name when prompted; `--yes` never skips that check. It never generates
or overwrites a key and never starts a release.

The helper:

- uses the `--keystore` path, then `./melo-release.jks`, then `~/melo-release.jks`;
- never generates or overwrites a key;
- verifies the keystore password, alias and private-key access locally;
- prompts for passwords without echoing them;
- uploads `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` through standard input, so no `.b64`
  copy or plaintext password file is left behind;
- checks that `gh` is installed and authenticated, and prints the `pkg install gh` /
  `gh auth login` steps if not;
- if an upload fails, names the secret that failed, says whether the repository was
  partially updated, and explains that rerunning the helper is safe;
- refuses any repository except `hakosworld-blip/melo` unless the target is passed
  explicitly with `--repo` and `--allow-non-target-repo`, then typed back to confirm;
- does **not** start a release.

Copy `melo-release.jks` to encrypted storage and keep a second encrypted copy; keep both
passwords in a password manager. Termux home directories are wiped when the app is
reinstalled. Losing the key means you cannot publish updates that install over existing
melo versions.

### Option C — GitHub Codespaces from a browser

Open the repository → **Code → Codespaces → Create codespace**, then run Option A's
commands in the terminal, download `melo-release.jks` from the file explorer, and add
the secrets with `gh secret set` or through the web UI. Delete the codespace
afterwards; do not commit the keystore.

### Adding the four secrets

On Termux, prefer `bash android/scripts/setup-termux-signing.sh` (Option B). Otherwise,
GitHub → `hakosworld-blip/melo` → **Settings → Secrets and variables → Actions →
New repository secret**:

| Secret name | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Base64 of `melo-release.jks`, one line (no `.b64` file needed) |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `melo` (whatever alias you chose) |
| `ANDROID_KEY_PASSWORD` | key password |

These names are fixed; the workflow and the Gradle file both expect them.

---

## 3. Releasing

`.github/workflows/android-release.yml` runs on:

- **a tag push** (`v1.0.0`, `v1.0.1`, …) → builds, signs, verifies, publishes a GitHub
  Release with the APK and its SHA-256 attached;
- **manual dispatch** → same build and verification, APK uploaded as a workflow
  artifact (no release);
- **manual dispatch with `release_tag` filled in** → also publishes a Release with that
  tag, which is the easiest path if you only have a phone.

The workflow:

1. sets up JDK 21, then runs
   `android/scripts/android-signing-preflight.sh validate` **before** the Android SDK
   and unit tests. It checks all four secrets, the Base64 payload, the decoded
   keystore, the keystore password, the alias and private-key access without building
   an APK, then always deletes the decoded keystore and never exports its path;
2. sets up the Android SDK (platform 35, build-tools 35.0.0) and Gradle caches, and
   runs the unit tests and their report **without any decoded keystore on disk**;
3. immediately before the build, runs
   `android/scripts/android-signing-preflight.sh prepare-signing`, which decodes and
   validates again, keeps the keystore in `$RUNNER_TEMP` with mode `600`, and exports
   `MELO_KEYSTORE_PATH` for signing only;
4. builds `assembleRelease` with `MELO_*` variables from the secrets, then immediately
   deletes the temporary keystore in an `if: always()` step — before verification,
   artifact upload and release publishing;
5. verifies with `apksigner` that the APK is signed **and not with a debug key**, and
   with `aapt2` that the package is `app.melo.player` and the version matches;
6. writes `melo-<version>.apk` plus a `.sha256`, uploads both, and publishes the
   Release.

Signing preflight failures use stable categories so the cause is obvious in the
Actions annotation: `missing-secret`, `invalid-base64`, `invalid-keystore`,
`cannot-open-keystore`, `missing-alias`, `wrong-key-password` and
`unusable-private-key` (plus `keytool-missing`, `base64-missing`, `tempfile-error` and
`usage-error` for runner problems). `cannot-open-keystore` covers both possibilities
because keytool reports the same error for a wrong password and for a corrupted or
incomplete keystore. Passwords, the Base64 payload, raw keystore data and raw keytool
output are never printed.

Version code is `github.run_number`, so every build is installable over the previous
one. Bump the version name by tagging, e.g.:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

### Verifying a downloaded APK yourself

```bash
sha256sum -c melo-1.0.0.apk.sha256
$ANDROID_HOME/build-tools/35.0.0/apksigner verify --print-certs melo-1.0.0.apk
$ANDROID_HOME/build-tools/35.0.0/aapt2 dump badging melo-1.0.0.apk | head -3
```

---

## 4. What is implemented

### Playback

- `MediaSessionService` + ExoPlayer: one player per process, owned by the service, so
  audio continues when the activity is destroyed, the screen is off, the user switches
  apps or swipes the app away.
- Media session with lock-screen/notification artwork, title, artist, play/pause,
  previous/next and seek; media button and Bluetooth/headset events are handled by
  Media3.
- Audio focus (`handleAudioFocus = true`) and `setHandleAudioBecomingNoisy(true)` so
  unplugging headphones pauses instead of blasting the speaker.
- Just-in-time stream resolution through `TrackMediaSourceFactory`: queue items carry
  a `melo://track/...` URI. Resolution runs off the playback thread before Media3
  chooses an HLS or progressive source. Expiring provider URLs stay out of the queue.
- LRU disk cache (`SimpleCache`) sized by the "streaming cache limit" setting.
- Wake lock, `onTaskRemoved` handling, and `onPlaybackResumption` so system resume
  works after the process is killed.

### Catalog

| Capability | Source |
|---|---|
| Song search, album/playlist browse, stream URLs | YouTube Music InnerTube (`WEB_REMIX`, `ANDROID_VR`/`IOS` player clients) |
| SoundCloud search + progressive stream resolution | `api-v2.soundcloud.com` with a client id read from the public site bundle |
| Charts / new releases | iTunes RSS |
| Artist art, discography, related artists, bios | Deezer + iTunes + Wikipedia |
| Monthly listeners (artist-level only) | YouTube Music artist page, hidden when absent |
| Lyrics (line + word sync) | LRCLIB, NetEase YRC, local custom text |

Word-level timing is real data, never invented: it is used only when the provider
returns YRC or enhanced-LRC timestamps. Otherwise the lyrics screen says so and falls
back to line sync.

### App

- Home: continue listening, downloaded, most played, recently played, your playlists,
  followed artists, provider recommendations ("Because you listen to …", derived from
  your own history through Deezer related artists), trending, new releases.
- Search: debounced live results, suggestions, filters (all/songs/artists/albums/
  playlists), per-track overflow actions.
- Track menu everywhere: play now, play next, add to queue, add to playlist, create
  playlist, favourite, download, go to artist, go to album.
- Library: playlists (create/rename/reorder/remove/delete/download all), favourites,
  followed artists, downloads with storage usage, listening history.
- Artist pages: portrait, monthly listeners (labelled, when available), follow/unfollow,
  popular tracks, albums, singles, related artists, biography.
- Album pages: artwork, metadata, full track list, play/shuffle/download/save-as-playlist.
- Player: artwork, seek with elapsed/remaining, shuffle, repeat off/all/one, favourite,
  queue, lyrics, download.
- Queue screen: reorder, remove, clear, jump to track.
- Lyrics screen: blurred artwork backdrop with adjustable blur/dim, word / line / plain
  modes, karaoke word fill, auto-follow that yields to manual scrolling, tap a line to
  seek, ±0.5 s offset, text size/font/alignment/spacing.
- Settings: theme (dark/light/system), six accent palettes, background style (solid,
  gradient, artwork, or a photo you pick from the device), corner radius, compact
  layout, all lyrics options, playback quality/behaviour, downloads, privacy and data
  controls, licences. Every setting is read by real code.
- Spotify import: public playlist link → matched/unmatched preview → create playlist
  (re-importing the same name reuses the existing playlist instead of duplicating it).

### Data

Room (`melo.db`) for playlists, playlist tracks, favourites, history, followed artists,
downloads and recent searches. DataStore for preferences. Downloads go to the app's own
external files directory, so no storage permission is required and uninstalling removes
them.

---

## 5. Permissions, and why

| Permission | Why |
|---|---|
| `INTERNET` | catalog, streams, artwork, lyrics |
| `ACCESS_NETWORK_STATE` | honour "stream on mobile data" / "Wi-Fi only downloads" |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | background playback |
| `POST_NOTIFICATIONS` | media controls on Android 13+ |
| `WAKE_LOCK` | keep audio running with the screen off |

No storage, contacts, location, camera, microphone or advertising permission. No
analytics or telemetry of any kind, and no account is required.

---

## 6. Tests

`./gradlew testDebugUnitTest` runs 46 JVM tests, including a Robolectric-backed suite
against a real in-memory Room database:

| Suite | Covers |
|---|---|
| `LyricsParserTest` (11) | LRC, multi-timestamp lines, enhanced-LRC words, NetEase YRC, plain-text fallback, offset tag, capability downgrades |
| `LyricsSyncTest` (9) | active line/word lookup, progress clamping, time formatting, mode defaults |
| `TextRulesTest` (7) | title cleaning, key normalisation, similarity, explicit detection |
| `SpotifyImportTest` (7) | playlist link/id parsing, junk rejection, duplicate-name handling |
| `LibraryRepositoryTest` (12) | playlist CRUD + ordering, duplicate guard, covers, favourites, history counts, follows, cross-source keys, full wipe |

The signing scripts have their own synthetic tests (no real credentials):

```bash
bash android/scripts/tests/run.sh
```

They generate throwaway keystores, mock `gh`, and cover every preflight failure category,
redaction, unique temporary-file cleanup and isolation between repeated runs.

Not covered by automated tests (needs a device or emulator): actual audio output,
notification rendering, lock-screen controls, Bluetooth/headset events, process-death
recovery, and Compose screenshot behaviour.

---

## 7. Known limitations

- **Spotify import uses the public playlist page.** Playlists that are private,
  region-locked or behind a Spotify login cannot be read. Full Web API access needs a
  Spotify developer app and an OAuth PKCE flow; that is intentionally not shipped
  because it would require an app-level client id/secret story in the binary and a
  registered redirect URI. If you want it: create a Spotify app, add
  `melo://spotify-callback` as a redirect URI, and wire the PKCE exchange into
  `SpotifyImport`. Never embed a client secret in the APK.
- **Monthly listeners exist only at artist level.** melo never shows an artist's number
  on a song and never fabricates counters.
- **Crossfade and gapless toggles are not offered.** ExoPlayer handles gapless playback
  automatically where the format allows and has no true crossfade; shipping a switch
  that did nothing would be dishonest. Volume-normalisation/EQ from the desktop audio
  suite is likewise absent: Android offers no equivalent that works across the app's
  streaming formats without shipping a DSP chain.
- **Desktop-only features that have no Android equivalent** are not ported: Discord Rich
  Presence, the Last.fm scrobbler and its API keys, the yt-dlp/ffmpeg download pipeline
  (replaced by direct stream downloads), the audio editor/trimmer, the CSS editor, and
  system-wide media key injection (Android routes media buttons through the session
  instead).
- **Provider endpoints are unofficial.** YouTube Music InnerTube and SoundCloud
  `api-v2` are the same public endpoints the desktop app uses; providers can change
  them without notice. Failures degrade to an error message with a retry, never a crash.
- **Downloads are subject to provider terms.** melo stores the audio stream the provider
  serves to it, exactly as the desktop app's download feature does. Whether that is
  permitted is between you and the provider; nothing here bypasses DRM, paywalls or
  access controls, and a provider refusal is reported as a failed download. HLS is
  supported for streaming; offline HLS downloads are rejected with an explicit error
  because storing a manifest alone does not store its audio. Existing completed
  download paths are preserved.
- **Not Play Store ready.** The release APK is signed and installable, but Play requires
  a privacy policy, a data-safety declaration and content-rights attestation — none of
  which are done here.

---

## 8. Attribution and licence

This project is distributed under the MIT licence (see `LICENSE` at the repository
root). melo is derived from **Riff** by rootscripts, which is MIT licensed; the original
copyright notice is preserved in that file. The melo name, icon and interface are new.

Third-party runtime libraries: AndroidX / Jetpack Compose / Media3, Kotlin and its
coroutines and serialization libraries, OkHttp, Coil, Room and Guava — all Apache
License 2.0. The in-app *Open source licences* dialog lists them.

melo is not affiliated with YouTube, Google, SoundCloud, Spotify, Apple, Deezer, LRCLIB
or NetEase.
