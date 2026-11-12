# VIP sources and automatic PiP follow-up

Branch: `feature/vip-fallback-updates`. Changes have not been built into a new IPA.

The native source roster now covers the 22 sources advertised in the inspected
Aether release: KingLink, Ly, Lul, Nebula, Lil, Meridian, Rock, Polaris, Aurora,
Tiki, Link, Fast, Vidy, Subtitulado, Latino, Castellano, Vine, Gallic, Baguette,
Poyraz, Yıldız and Animetsu. Settings includes a Máy chủ tab. Sources are filtered
by supported movie/TV types, as in the upstream scraper.

KingLink and Ly form the preferred path. Failed extraction falls through to
bounded batches of at most four other sources. Cancellation stops abandoned
requests. A native decoder failure also tries an untried source. Manual selections
request that source explicitly. No website player is used.

Contracts were inspected by executing Aether's actual source and embed functions
with instrumented fetchers. Tests/Fixtures/aether-native-routes.json records
independently captured movie/TV routes. Native code handles Fast's server lookup,
Spanish status/URL data, Baguette's vidzy entries, other direct stream variants,
and Animetsu's TMDB→AniList→backend sequence. Animetsu requires an exact title/year
match and rejects ambiguous matches instead of guessing another anime.

Live limitation: Coco/354912 KingLink returns HTTP 200 with JSON null. The other
20 direct source APIs return HTTP 403 from this environment. Native adapters and
fallback have fixture verification, not successful playback verification for all
22 servers. They must be tested on the user's connection; website behavior and
provider contracts can change independently.

Automatic PiP: the old inline source could remain without a real frame until
background, and its sample display host was behind the opaque app window. On
resign-active, the existing renderer now starts delivering real samples without
requesting a PiP window. Its sample host moves into the visible player when CPU
output activates. AVKit can evaluate automatic inline entry before suspension.
The explicit Home fallback retains playback intent through transient buffering.
Returning from Control Center/foreground restores the GPU renderer. The manual
PiP path and per-background attempt limit remain in place.

The user uses ESign and explicitly allowed omitting direct app updates. The
unfinished update-check section has been removed. No self-install claim or IPA
signing automation is included.

Validation: complete offline regression suite passed, including native catalog,
provider, Anime Home/cache, subtitle, credential, parser, Range and PiP policy
checks. Additional stream tests cover all adapter IDs, independently recorded
movie/TV paths, metadata isolation and fallback. Swift syntax parsing passed.
Apple SDK build, source playback and automatic Home PiP on an iPhone are pending.
