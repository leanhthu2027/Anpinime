# VIP fallback and update discovery

Branch `feature/vip-fallback-updates` builds on native IPA 26.

Coco (TMDB 354912) reproduced live: KingLink HTTP 200 with body `null`.
The native resolver now tries KingLink then Ly on missing/malformed/failed data.
Manual server selection remains explicit. Native decoder failure also requests
an untried server while preserving playback position; no web player is opened.

Ly's movie/TV route, response URL fields, subtitle fields, media Origin/Referer
and `proxyHeaders` override were confirmed by executing the actual Aether
provider implementation with deterministic inputs. The environment still gets
HTTP 403 from Ly's API; successful live Coco playback through Ly is unverified.

39 stream/transport checks pass, including Coco's null response falling through,
Ly URL/header/caption decoding, and manual selection not silently switching.
Swift syntax parsing passes for changed UI/controller files. No iOS build has
been run for this branch and no physical-device results are claimed.

Settings now checks successful GitHub IPA workflow runs and compares their
source bundle build numbers, providing a link to a newer build. It never embeds
a GitHub access token. This is update discovery, not an OTA installer. Direct
installation needs the user's existing signing/install tool (AltStore,
SideStore, TrollStore, ESign, etc.). That detail has been requested and is pending.
GitHub artifact links expire and may require login; they are not permanent OTA
package URLs. No binary self-replacement or automatic installation is claimed.
