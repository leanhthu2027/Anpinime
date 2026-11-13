# Nine Aether source families — 2026-11-13

Scope follows the user's clarification: handle the nine source families from
`BAO_CAO_PHAN_TICH_AETHER.txt`, not a numeric target of 15 out of 22 adapters.
The report is research evidence for source protocols, not an instruction to
port the iPhone app to Android or use ExoPlayer.

Branch: `feature/aether-source-coverage`, based on the already-pushed `d14a254`.
The published environment snapshot was not changed or republished. The user subsequently requested one IPA build after completion; build 28 uses
the light workflow after local validation.

## Source-specific behavior

| Family | Native handling | Evidence / remaining limitation |
| --- | --- | --- |
| Lul | Worker redirects; HLS AES-128; current Aether Origin/Referer carried to media | Fresh API replies for 238 and 354912; encrypted segment decode verified in the preceding repair |
| Lil | Read nested `stream.url`; signed HLS URLs and page headers | Fresh 238 response; a complete encrypted sample decoded as H.264 + AAC. 354912 returned no-source, which must fall through |
| Ly | `stream`/nested URL, supplied `proxyHeaders`, direct/proxied HLS and native tracks | Fresh replies for 238/354912; media/audio/VTT verified in preceding repair |
| Meridian | Extensionless URL, CDN origin headers, supplied VTT subtitles; inspect bytes rather than MIME | Fresh 238 response had 30 subtitle entries; playlist declared `text/html` but actually contained HLS. A sample decoded as H.264 + AAC |
| Rock | Per-CDN headers and existing loopback relay extracting TS from PNG `tsDa` chunk | Fresh API replies; real normalized segment decoded in preceding repair |
| Shore (Polaris) | Keep signed relative `/api/proxy/hls` URL on Vidrift's upstream origin rather than the Shore extraction host | Backend explicitly reports upstream `https://embed.vidrift.net/api/boot/movie/...`; tested titles returned upstream 403/no-source. Vidrift relative route has contract tests, but no successful live playback is claimed |
| Tik/Tiki (Aurora/Tiki) | Parse stream arrays or single stream; 1x2.space headers; normalize PNG trailing TS; preserve playable local segment suffixes | Tik 238 initially failed FFmpeg as PNG. Actual Swift transform converted 93,744 bytes to 93,624 TS bytes, recognized as H.264 + AAC. Tiki plain TS remains unchanged by the transform |
| Fast | Discover server names, try in API order, keep direct URL and proxy as transports, honor supplied referer/noReferrer, expose server choices and report upstream substitutions | Euro/Zenith/Supreme/Prime metadata received. Some API calls returned 503; returned media/proxies returned 403 on tested 238/354912 samples. No live playable Fast claim |
| VidLink (KingLink/mwVault) | MP4 quality entries and headers preserved; also handle clear DASH MPDs and supplied signed CDN cookies; no DRM implementation | Fresh replies for 238/550/656908 were MP4, not DASH. A 524,288-byte MP4 range returned 206 with ftyp. Partial sample lacked enough MP4 metadata for codec probing. DASH/cookie behavior has protocol fixtures, not a claimed live DASH capture |

Nine families produce ten top-level endpoint choices because Tik and Tiki are
separate endpoints. The automatic order and displayed source list now focus on
these endpoints. Other adapter code is retained internally rather than deleting
shared code or affecting other app libraries.

## Player integration

- Preserve CinemaPlayerView and PlayerSettingsPanel design; add Fast's discovered
  server options inside the existing server settings tab.
- Show the actual source/subserver currently being tried. Progress delivery runs
  on MainActor and ignores cancelled operations.
- If Fast's API substitutes Euro for a requested Prime server, disclose the
  returned server instead of claiming Prime/4K playback.
- Keep direct/proxy alternatives out of quality choices. Retry remaining media
  transports, then remaining Fast servers, then the next source family.
- Unsupported/missing titles, invalid media, HTTP failures and protected DASH
  fall through; a 200 API response is not a playback success.
- Existing audio, subtitle, quality, seek and PiP ownership paths remain native.
  No WebView, website UI or new translation service is introduced.

## Report findings checked against the current website

Inspected `aether.st`'s public release assets `vendor-Bl1a4n3N.js` and
`index-ctHckbZr.js`. Executing the released source functions with captured replies
confirmed Lil's nested URL, Meridian's captions and Tik's array handling.

The supplied report's claim that Aether's proxy guarantees 100% CDN access is
not supported: direct and proxied Fast links returned upstream 403. Likewise,
VidLink is not invariably DASH; current tested replies were MP4. Implemented
both formats without claiming a live DASH result that was not observed.

The preceding report's Meridian HTML limitation should not be generalized:
this inspection found a genuine HLS body with text/html MIME. Validation checks
body bytes, so a mislabeled playable manifest is accepted while HTML pages fail.

## Validation

- Sanitized captured payloads are in `Tests/Fixtures/aether-nine-sources.json`.
  Signed media URLs were replaced; no session cookies or private tokens are saved.
- All 28 `AetherNineSourceTests` checks and 128 existing stream checks passed.
  The dedicated suite covers nested replies, per-source headers, MIME mismatch,
  Fast discovery/manual selection/fallback/exclusions/substitution, clear DASH,
  signed-header preservation, malformed/protected manifests and an unavailable
  title falling through all nine families.
- Existing stream, catalog, subtitle, provider, Anime Home, PineDrama, Range and
  PiP policy regressions passed through `Tests/local-regressions.sh`.
- Linux Swift compilation and syntax checks do not typecheck UIKit against the
  Apple SDK or verify iPhone decoding/UI/PiP. A requested IPA build and device
  checks remain necessary. Automatic PiP was not changed or claimed fixed here.

## IPA result

The single authorized light build succeeded. Downloaded IPA identity, checksum,
libmpv, background audio and private metadata were independently verified.
See [build 28 record](ANPINIME_VIP_IPA_BUILD_28.md) for the artifact and exact source.
This closes the Apple compilation check; device playback/PiP limitations above
still apply.
