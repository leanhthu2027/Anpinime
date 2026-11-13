> Follow-up: [nine source families and current evidence](AETHER_NINE_SOURCES.md) supersedes the 22-source roster and earlier Meridian limitation below.

# Native Aether source repair — 2026-11-12

Branch: `feature/vip-fallback-updates`. These changes are **not yet in an IPA**.
No GitHub Actions build was dispatched for this repair.

## Confirmed failures and changes

- The additional source APIs were called without the browser's Aether Origin,
  Referer and User-Agent. A fresh Ly/Coco request without those headers returned
  403; a request with the Aether context returned the source JSON. The native
  client now supplies the resolved Aether page origin to source API requests,
  separately from each CDN's media headers. TMDB credentials remain separate.
- Source order remains descending Aether scraper rank, not KingLink-first:
  Lul, Nebula, Lil, Ly, Meridian, Rock, Polaris, Aurora, Tiki, Link, Fast, Vidy,
  then the remaining supported language-specific sources, KingLink and Animetsu.
  Website user preferences can override its default order.
- Extraction HTTP 200 is no longer sufficient: a bounded media prefix must be
  HLS or a recognized video container. A 200 HTML response falls through. A
  server ignoring Range cannot cause a complete movie download during this check.
- Preserve relative provider URLs and signed queries, explicit subtitle formats,
  per-track headers and per-variant headers. Reject structured provider errors.
- Keep alternate media transports separate from quality choices. Try direct
  media and then the same public HLS proxies configured by Aether (`just` and
  `justice`) with the original CDN headers. A decoder failure can try remaining
  candidates within that source before the next ranked source. Fast also tries
  its next server when extraction succeeds but the first media URL fails.
- Rock's live segment was a PNG containing MPEG-TS in a `tsDa` chunk. Direct
  probing identified it as PNG, not the movie. Reuse the existing loopback
  FilmMediaRelay, extending FilmMediaTransform to extract only validated TS
  packets from this chunk. Rock gets suitable `.ts`/`.m3u8` local paths. Other
  backends keep their existing relay naming defaults. This is native byte
  normalization: no WebView, remote page or website controls are introduced.
- Preserve visible extraction failures during decoder polling and allow retrying
  the current failed server. Source changes stop the old decoder and relay;
  active PiP still uses the existing stop/retention policy.

## Live evidence and limits

The current `aether.cx` bundle (`vendor-3q_8TQIr.js`) and the user's screenshots
were inspected. In the screenshot the selected Ly request is **404** and Shore
is **200**; that 200 alone does not identify the final playing source.

Real network checks in this workspace (not fabricated success fixtures):

- Coco / TMDB 354912: Ly returned source JSON, an HLS master, video segments,
  English audio and English WebVTT. The video sample was recognized as H.264.
- Coco: Lul returned a master and encrypted HLS segments. The standard HLS key
  and one bounded segment were read successfully as H.264 + AAC by ffprobe.
- TMDB 9387: Tiki returned HLS and a sample recognized as H.264 + AAC.
- TMDB 9387: Rock's complete 517,832-byte wrapped segment was processed by the
  actual Swift FilmMediaTransform. Its 517,752-byte result was recognized by
  ffprobe as H.264 + AAC. The same chunk shape has regression tests.
- Shore/Polaris returned a relative `/api/proxy/hls?...` value. On the source
  origin that route returned 404; wrapping the relative value exactly as the
  upstream scraper does returned 502. The app now preserves the URL but rejects
  an unusable stream and proceeds. We do **not** claim Polaris is working.
- Some sources returned 404/no-source for these titles; Meridian's returned URL
  yielded HTML, and Link's direct media returned 403. These are failure cases,
  not verified playable sources. No claim that every source serves every film.

Provider/movie/TV route tests cover the 22 existing native adapters; this is not
proof that every endpoint is operational. No new source names were fabricated.
The six other scrapers exposed by the raw vendor library have not been ported
or claimed as supported by this change.

## Validation

- Full offline regression suite passed, including catalog/search, Anime Home,
  NguonC/KKPhim parsing/providers, PineDrama, subtitles, credentials, Range and
  native PiP policy. These checks are not device playback tests.
- After final source changes: 128 native stream/token/transport assertions passed,
  using sanitized live response shapes plus specific failure scenarios.
- Six local HTTP transport checks passed, including bounded reads when Range is
  ignored on a virtual 12 GB resource, redirects, cancellation and JSON size caps.
- Swift syntax parsing and `git diff --check` passed. Swift/Foundation stream code
  was compiled on Linux; UIKit/Network/MPV integration still needs an Apple build.
- Direct live Swift URLSession checks in the reused Linux container could not
  connect (its proxy configuration is stale). Live HTTP evidence above used the
  workspace's inherited proxy; it does not prove iOS networking or playback.

A new IPA and iPhone checks are still required: automatic ranked selection for
Coco, manual Ly/Rock/Tiki selection, recovery after a media error, audio/subtitle
selection, seeking, and automatic Home PiP. PiP code was not changed in this
repair, and no claim is made that automatic PiP has passed on a physical phone.
The user's ESign setup remains unchanged; direct self-updating stays omitted.
