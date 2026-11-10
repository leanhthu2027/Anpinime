# Aether migration dependency audit

Baseline and fetched main: `ea2f8c0dff3df92d0042fe34380ffa6ad0ae1a85`.
Implementation branch: `feature/aether-migration-pip-recovery`.

| Component | Real dependencies / disposition |
| --- | --- |
| Phim4KProvider, Phim4KCatalog, Phim4KVIPResolver, MovieSourceDirectory | Phim4K Core/Free directory, authentication and catalog only; archive outside AnyAnime after detaching router/debug harness. |
| MovieCatalog / Phim4KFormat | JSON schemas also used by NguonC and KKPhim; preserve parser behavior, rename shared format, remove Core-only helper. |
| Phim4KTransportPolicy, Phim4KMediaProbe | General HTTP redirect/Range probe coverage; retain with tests, despite historical filenames. |
| Phim4KRelayNaming | FilmMediaRelay dependency; retain with suffix regression coverage. |
| FilmMediaRelay, FilmMediaTransform | Shared wrapped HLS, Range, quality parsing and native fixture; retain. |
| MPVPlaybackController, MPVPictureInPicture, NativePiPPolicy | Native Anime/Movie/AI ownership, GPU/software output, tracks and restore handshake; repair in place. |
| PlayerView fallback JS | Anime/embedded provider DOM isolation and native handoff; Aether must not execute these modifications. Extract only existing WebKit PiP protocol for shared use. |
| RootView.AppLibrary / AIDrama | Three independent libraries and AI ownership; preserve enum, preference keys and AI controllers. |
| SearchHistory | Partitioned by source raw value. Migrate only saved source selection, retain old phim4k history under old key without importing it into Aether. |

Direct HTTPS probes of Rentry and aether.st on 2026-11-10 returned proxy CONNECT 403.
No live catalog API, media route, subtitle translation implementation or current mirror status is verified.
Network draft update also failed INVALID_ARGUMENT. Do not invent TMDB/API contracts.
The website browsing MVP uses its root and links selected inside its own UI.
