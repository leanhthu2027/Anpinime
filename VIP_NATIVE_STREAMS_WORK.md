# Anpinime VIP — native video, subtitles and PiP follow-up

Branch: `feature/vip-native-streams-pip`. Version: **2.9.4 (26)**.

## Playback changes

- Aether video now uses native Foundation stream extraction and the existing
  MPV renderer/PiP backend under `CinemaPlayerView`. The VIP controller has no
  WebView, iframe, site banner, or website controls. The old bridge and its DOM
  tests are archived outside the application target.
- `AetherStreams.swift` implements the KingLink provider actually shipped by
  Aether's current live bundle, including its request envelope in Swift. API
  headers and media headers remain separate: adding a browser user agent to
  these media URLs can cause upstream rejection. No TMDB credential goes to
  the stream host.
- Native quality options use the actual MP4 variants or HLS playlist levels.
  Changing quality retains position, pause intent and external subtitle files;
  the old decoder stops before another starts. PiP must finish before replacing
  the decoder. KingLink is the only verified native server in this version.
- `AetherSubtitles.swift` downloads provider captions to local files and exposes
  the external subtitle indices used by Aether, including OpenSubtitles.
  Vietnamese is preferred, otherwise English is selected and translated with
  the same Google Translate service used by Aether. English remains available
  during translation; failure retains the original. Cue timestamps are kept.
  Settings, subtitle style, audio tracks, playback speed and file import use
  the existing native controls. Index outages do not discard provider captions.
- Native Home/detail/search remain TMDB backed with Anpinime's existing design.
  The verified private default is bundled without a token field; a stale token
  from older versions no longer overrides it. No credential is committed.

## PiP and progress

- Automatic MPV startup uses the existing native preparation path, without
  requiring a pre-captured snapshot. Its attempt is tracked once per background
  visit, including manual and AVKit starts, so closing PiP does not reopen it.
- MPV/AVPlayer progress timers use common runloop modes and refresh immediately
  on foreground. An interrupted slider drag is cleared when scene state changes.
- The actual native player survives temporary presentation changes and retains
  its PiP owner. Explicit source changes shut it down. Native `pipStop` now uses
  the existing stop/restore completion path before replacing an episode.

## Validation

Live evidence on 2026-11-11:

- Aether/rentry/GitHub accessible; supplied TMDB default accepted, HTTP 200.
- Native Swift resolver: movie 550 HTTP 200 (360/480/720p, 15 captions),
  TV 1399 season 1 episode 1 HTTP 200 (up to 1080p, 13 captions).
- Both media URLs returned HTTP 206 and 1,024 bytes with MP4 `ftyp/isom`.
- Actual English subtitle downloaded, HTTP 200, 146,377 bytes. First three real
  cues translated to Vietnamese successfully with cue alignment preserved.
- Other Aether provider API hosts and the optional subtitle indices returned
  upstream Cloudflare/HTTP 403 during inspection; no inactive server controls
  or website fallback were added.

Offline: complete `Tests/local-regressions.sh`, including stream/token/transport
33 checks, subtitle 22 checks, native PiP policy 89 checks, metadata loaders,
RSA credential handoff, catalog/provider, Anime Home/cache, NguonC, KKPhim,
PineDrama, shared parser/player and bounded Range fixture suites. Production
Swift syntax parse and `git diff --check` pass. Syntax parsing is not an Apple
SDK typecheck.

One explicitly authorized light IPA build follows these checks. Its receipt
records the source commit, package identity, checksum and build result.

## Still requires a physical iPhone

Video decoding/rendering, audio track switching, subtitle positioning and timing,
full-movie translation, quality changes while paused, PiP Play/Pause/seek, automatic
Home gesture, background sound/video, return progress and close/restore behavior.
A successful IPA build does not establish any of those device results. Provider
endpoints and signed media delivery can change independently of the app.
