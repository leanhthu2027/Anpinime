# Aether migration và PiP recovery — AnPinime 2.9.4 (23)

> Cập nhật sau yêu cầu build: **[IPA 2.9.4 (24) đã build và kiểm tra gói](AETHER_IPA_BUILD_24.md)**. Source build `576260b`; chỉ một job macOS 264 giây, không Simulator/full suite/retry. Các mục SKIP build bên dưới mô tả thời điểm báo cáo migration ban đầu; PiP iPhone và Aether live vẫn cần kiểm chứng riêng.

Ngày kiểm tra: 10/11/2026. **Trạng thái: đã triển khai MVP duyệt/phát Aether bằng website và sửa các lỗi ownership/callback PiP xác định được trong mã. Aether live, Apple SDK build và cửa sổ PiP iPhone chưa được xác nhận. `NEEDS_PHYSICAL_IPHONE_TEST`.**

## 1. Baseline và nhánh

- Repository triển khai: `pythonltn2000/Anpinime`.
- Baseline: `ea2f8c0dff3df92d0042fe34380ffa6ad0ae1a85`.
- Đã fetch `origin/main` trước khi sửa; kiểm tra remote cuối phiên vẫn đúng baseline, không có thay đổi upstream cần hòa giải.
- Nhánh local: `feature/aether-migration-pip-recovery`. Không sửa/push/force-push main; không merge PR hoặc dispatch Actions.
- Cây ứng dụng đã kiểm tra: `ad19d7e116be184dec4c89d5eeb79da0e9a4665c` (`HEAD:AnyAnime` tại commit `3b659cf`).

## 2. Kiến trúc và dữ liệu

`ContentSource` hiện là `anime`, `film4k`, `aether`, `kkphim`. Nhãn lần lượt là AnimeVietsub, Anpinime Free, Aether và Anpinime dự phòng. `.film4k` vẫn là NguonC. `AppLibrary` giữ nguyên `anime`, `movie`, `aiDrama`; các key lựa chọn thư viện, loading/transition và accessibility identifier của các thư viện được giữ.

`MovieSourceProviding` thống nhất adapter trong `AnimeService`. `MovieProvider` chỉ phục vụ NguonC/KKPhim, không khởi tạo directory hay provider Phim4K. `AetherProvider` khai báo rõ chế độ website, không tạo danh mục/JSON hoặc route phát chưa được kiểm chứng. Aether có trang duyệt web và Settings; tìm kiếm/thể loại nằm trong website. Hai nguồn còn lại giữ các tab native.

`MovieSourceMigration` chỉ đổi `AnPinime.movieSource == "phim4k"` thành `"aether"`. Lịch sử Phim4K vẫn nằm dưới namespace cũ; không gán ID/tiến độ cũ cho Aether và không xóa UserDefaults. Unit test bảo vệ lựa chọn Phim AI, lịch sử các nguồn khác và vị trí tập AI. MVP không tạo thẻ phim native Aether nên không tự phát minh ID/TMDB mapping; phim, season và tập do website lựa chọn. Storage/cookie của website vẫn tuân theo từng origin.

## 3. File ra khỏi production và dependency được giữ

| Đường dẫn cũ | Xử lý và lý do |
| --- | --- |
| `AnyAnime/Phim4KProvider.swift` | Chuyển nguyên vẹn vào `Tools/archive/phim4k`: client Core/Free riêng đã ngừng dùng. |
| `AnyAnime/Phim4KCatalog.swift` | Archive nguyên vẹn: parser/ID Core riêng đã ngừng dùng. |
| `AnyAnime/Phim4KVIPResolver.swift` | Archive nguyên vẹn: resolver/gateway Core riêng. |
| `AnyAnime/MovieSourceDirectory.swift` | Archive nguyên vẹn: directory và cấu hình xác thực Phim4K. |
| `Tests/Phim4KResolverTests.swift` và script probe/live/Core cũ | Archive ngoài test target hiện hành. Bản combined tests/harness/workflow trước migration cũng được lưu để đối chiếu fixture. |

XcodeGen chỉ lấy source trong `AnyAnime`, nên archive không vào app. Không xóa fixture dùng chung. `Phim4KFormat` được đổi tên thành `MovieAPIFormat`, vẫn giữ hai schema công khai NguonC/KKPhim. `FilmMediaRelay`, `FilmMediaTransform`, `Phim4KMediaProbe`, `Phim4KTransportPolicy`, `Phim4KRelayNaming` được giữ; các tệp này có SHA256 bằng baseline. Tên lịch sử của ba helper media còn lại không đại diện cho một nguồn Phim4K đang hoạt động.

HLS smoke dùng adapter JSON KKPhim fixture qua flag DEBUG `--relay-hls-smoke`. Nó vẫn kiểm tra relay thật, suffix HLS/segment, header bắt buộc và mpv khi có Simulator. Các bài MKV, hai audio/hai subtitle, cache, Range, anime và AI vẫn được giữ. Xem [audit dependency](Tools/aether-dependency-audit.md) và [archive](Tools/archive/phim4k/README.md).

## 4. Domain resolver

`AetherDomainResolver` đọc `https://rentry.co/aetherdomains`, nhận liên kết HTTPS trong Markdown/plain text/HTML mà không cần cấu trúc bảng. Các seed `aether.st`, `aether.ist`, `aether.cx`, `aether.bar` là snapshot lịch sử người dùng cung cấp; trạng thái hiện tại chưa xác minh.

Chỉ chấp nhận origin dạng `aether.<ASCII TLD>`, HTTPS, không userinfo, không port khác 443. Host mới phải xuất hiện trong tài liệu chính thức và vượt cùng policy. Địa chỉ thủ công phải nằm trong danh sách đó hoặc seed; setting không cho đường dẫn/query/fragment. Không tự nới ATS, security setting hoặc hostname policy theo JSON/website. Domain dạng nhiều nhãn mới cần cập nhật policy rõ ràng trong một thay đổi mã.

Directory TTL 6 giờ, offline grace tối đa 7 ngày; domain hoạt động TTL 1 giờ. Request timeout 6 giây/resource timeout 8 giây, tối đa 3 redirect/request và 8 probe mỗi lần resolve. Redirect được chặn trước khi theo nếu host chưa xác minh, downgrade hoặc userinfo/port không hợp lệ. Phản hồi cuối được kiểm tra lại. Lỗi toàn bộ trả thông báo có thể thử lại. Khi chỉ còn một trang xác minh nhận diện được, mở nó trong WebKit để người dùng thao tác và không cache nó thành domain hoạt động.

Domain được resolve trước phiên, rồi pin cho navigation chính và response chính. Iframe/media của website tiếp tục dùng decoder/controls của nó; host iframe không trở thành domain app. Thay Settings không reload phim đang xem. **Kết thúc phiên → Mở Aether** tạo phiên và browsing history mới; fullscreen, chuyển tab và PiP giữ WKWebView hiện tại. Đổi nguồn/mở bộ chọn thư viện sẽ kết thúc rõ ràng owner Aether cũ. Back theo dõi `canGoBack` qua KVO cho navigation của SPA.

## 5. Khảo sát catalog/search và P-Stream

**Aether live: BLOCKED.** Request HTTPS trực tiếp tới Rentry và `aether.st` trả proxy **CONNECT 403**. Policy môi trường hiện không cho các domain này. Đề xuất thêm `rentry.co`, `aether.st`, `aether.ist`, `aether.cx`, `aether.bar` bằng công cụ draft trả `INVALID_ARGUMENT`; việc lưu cấu hình mạng chưa được xác nhận. Không đổi proxy hoặc bỏ TLS verification để vượt giới hạn.

Vì vậy nguồn dữ liệu catalog/search, API công khai, trend/popular/movie/TV/genre/season/episode, poster/backdrop và khả năng phát thực của Aether đều **UNVERIFIED**. Không có TMDB fallback âm thầm và không hardcode `/media/tmdb-movie-*` hoặc `/media/tmdb-tv-*` vào production. MVP mở root đã resolve rồi sử dụng các liên kết và điều khiển thực trong website, gồm cả search/detail/tập.

Đã đọc mã tham khảo công khai [p-stream/p-stream tại `b3a2f72`](https://github.com/p-stream/p-stream/tree/b3a2f72aa4dde43ea68b969791fb302de10e9021): `TranslateSubtitleView.tsx`, `LanguageSubtitlesView.tsx`, `src/utils/translation/index.ts`, `googletranslate.ts`. Reference có danh sách ngôn ngữ gồm `vi`, hành động dịch theo caption, giữ cấu trúc SRT và cache bản dịch. Đây chỉ là đối chiếu hệ sinh thái: chưa xác minh Aether dùng bản đó. Không sao chép translation client/API key của reference vào app và không tạo dịch vụ dịch native mới. Reference chỉ nằm trong `/tmp`, không thành repository triển khai hay dependency.

## 6. Player Aether, Vietsub và dịch

`AetherBrowserSession` sở hữu một browser đang phát; proxy message handler giữ owner weak. Chỉ có observer HTML5 và phần PiP đã tách từ player 2.9.4. Không cài script CSS/DOM repair của AnimeVietsub, không intercept network, không gửi `videoFound`/`iframeFound`, không sửa track/style/decoder, không autoplay bằng script, không handoff sang MPV. `requiresWebsitePlayback` cũng chặn native handoff nếu item Aether lọt vào player chung.

Website giữ controls, caption renderer, lựa chọn server, ngôn ngữ và nút dịch. Fixture kiểm tra hành động dịch gốc vẫn gọi được và markup không đổi, kể cả khi dùng PiP. **Phụ đề Vietnamese/OpenSubtitles, dịch English → Vietnamese, đồng bộ sau tua/fullscreen trên Aether thật vẫn UNVERIFIED.** Spinner của app có deadline; HTTP lỗi/process termination có trạng thái lỗi và nút mở lại. Các lỗi không có nguồn phát bên trong website vẫn cần khảo sát live.

## 7. Chẩn đoán PiP thực tế và phần đã sửa

**Chưa có trace iPhone để xác định nguyên nhân đầy đủ của sự cố người dùng báo.** Không coi các cấu hình đã có (`audio` background mode, `allowsPictureInPictureMediaPlayback`, automatic-inline flags) là bị thiếu.

Các lỗi/đường lỗi xác định được trong mã:

1. Nhánh AVPlayer dùng `AVPlayerViewController` với `showsPlaybackControls = false`; app cũng không có API public để tự gọi startPiP trên controller này. Đường điều khiển PiP thủ công bị ẩn. Đã bật controls hệ thống, cho AVKit nhận gesture, thêm delegate start/fail/stop/restore và vẫn cung cấp đóng/retry của app. Luồng hiện tại chọn AVPlayer chủ yếu bằng smoke DEBUG; production mặc định MPV có đường riêng.
2. Delegate lifecycle MPV `willStart/didStart/failedToStart/didStop` trước đây không kiểm tra identity/controller đã stopped. Callback đến muộn có thể viết lại state của playback đã thay owner. Đã thêm guard dùng chung và unit test tái hiện late start/stop. Guard cho thao tác Play/Pause/Seek, generation, restore handshake, frame gate và GPU/software output vẫn giữ.
3. Representable của player chung gọi shutdown vô điều kiện. Đã defer teardown khi PiP pending/active, giữ controller/browser/delegate tới completion của đúng backend; tránh pause/giải phóng decoder trong chuyển presentation tạm thời.

Giải thích rõ **prepared nhưng không có didStart**: `automaticReady` biểu diễn các gate frame/output/source/playing và cờ automatic; nó không đồng nghĩa `isPictureInPicturePossible`. `startIfPossible` còn yêu cầu AVKit báo possible. Cần trace thật để biết gate nào thay đổi hoặc AVKit từ chối lý do gì. Đã đọc lại việc `background()` gọi `updateAutomaticPiPReadiness()`; không thay/latch trạng thái window dựa trên phỏng đoán khi chưa có trace thiết bị.

## 8. Logging DEBUG và bằng chứng backend

Log `[PiP]` là JSON có session/backend, trigger, app/scene state, source window và actual bridge attachment, frame/output readiness, native possible/prepared khi API cung cấp, request/willStart/didStart/fail(code)/didStop, restore và playback time. WebKit/AVPlayerViewController ghi `supported` riêng, không giả nó là `isPictureInPicturePossible`. MPV ghi trước/sau cập nhật readiness ở background. Không ghi URL media, signed query, cookie, header hoặc token.

| Backend | Bằng chứng trong phiên này | Cửa sổ PiP thật |
| --- | --- | --- |
| MPV/sample buffer | 56 policy/ownership/restore/frame-gate checks; pipeline Metal/software được giữ | `NEEDS_PHYSICAL_IPHONE_TEST` |
| AVPlayer | Đã sửa controls/delegate/restore/lifetime; Apple SDK compilation và runtime chưa chạy | `SKIP` / `NEEDS_PHYSICAL_IPHONE_TEST` |
| WebKit Anime/embed | 9 nhóm regression JS gốc đạt, dùng lại core PiP | `NEEDS_PHYSICAL_IPHONE_TEST` |
| WebKit Aether | Shared session/request protocol, rejection/timeout, website-owned state và controls fixture đạt | Live/HTML5/WebKit iPhone `SKIP` |
| Phim AI | Provider/cache offline đạt; toàn bộ source AI không đổi | UI/shorts/book/automatic PiP trên iOS `SKIP` |

Chưa backend nào được xác nhận cửa sổ PiP thật trong phiên này. Điều kiện nghiệm thu vẫn là callback `didStart` **và quan sát cửa sổ hệ thống thật**, theo từng backend và từng manual/automatic cycle. Aether không gửi JS sau background để hứa tự mở PiP; nút website và nút app chỉ hoạt động khi video/WebKit cho phép, với lỗi/timeout rõ ràng.

## 9. PASS / FAIL / SKIP

| Kiểm tra đã thực thi | Kết quả |
| --- | --- |
| Aether domain/redirect/TTL/manual/verification/cancellation | **PASS — 35 checks**, URLSession giả lập và redirect delegate production |
| Source migration, history isolation, web-only adapter, Swift PiP session/request state | **PASS — 30 checks** |
| Native PiP policy/restore/concurrency/late callback/lifetime gates | **PASS — 56 checks**, gồm các tổ hợp gate và producer đồng thời |
| Parser anime, JSON hai nguồn, episode/server isolation, wrapped HLS, history, relay suffix | **PASS — 117 checks** |
| NguonC/KKPhim provider và transport | **PASS — 37 checks**; URLSession mock và redirect HTTP loopback thực |
| Anime Home/cache/domain recovery/cancellation | **PASS — 26 checks** |
| PineDrama provider/complete-playlist/filter isolation | **PASS — 143 checks** |
| AI media cache | **PASS — 18 checks + 1 kiểm tra server xác nhận đủ 10 MP4 hoàn chỉnh**; byte/cache scope |
| JS player 2.9.4 | **PASS — 9 nhóm**, gồm anime resume, ads/decoder, tracks và PiP |
| Aether observer/translation controls/no native handoff/PiP fixture | **PASS**, JSDOM; không phải website live |
| Swift media probe + virtual Range HTTP | **PASS**, 206/200/redirect/403/JSON và 9 request semantics |
| Shared JSON/HLS fixture | **PASS**, PID/health, catalog/detail, header rejection, playlist và byte MPEG-TS thật |
| Swift app syntax, YAML, shell/Python syntax, diff check | **PASS**; cú pháp Swift không thay Apple SDK typecheck |
| 27 protected files và enum `AppLibrary` | **PASS**, byte/hash bằng baseline |
| Local FAIL chưa xử lý | **Không còn** |
| Aether live catalog/player/translation | **BLOCKED**, proxy CONNECT 403 |
| XcodeGen/Apple SDK typecheck/build IPA | **SKIP**, Linux không có Apple SDK; chưa được yêu cầu chạy macOS |
| AIDramaStoreTests (SwiftUI/Combine), AIDrama/MovieSearch UI tests, Simulator/MKV decode/software PiP render | **SKIP**, cần runtime Apple; các test được giữ |
| PiP/âm thanh/fullscreen restore trên iPhone | **NEEDS_PHYSICAL_IPHONE_TEST** |

Swift 6.0.3 chạy trong image chính thức `swift:6.0.3-jammy`, digest `sha256:95f6ef898992dc840b35517e780f6f6db9661432775ab0b33cc0a531ea749bdb`, network disabled cho container test. Node 24.22.1, jsdom 26.1.0, Python 3. FFmpeg tạo fixture local. Với cache AI, bước FFmpeg thực chạy trên host; phần server/compiler/tests/đối chiếu thống kê của harness chạy trong container bằng cùng test source. Rendering/swipe iOS có kết quả SKIP riêng.

Log và manifest tại [evidence](Tools/evidence/2026-11-10-aether-migration/summary.json). Hướng dẫn chạy lại: [local validation](Tools/local-validation.md).

## 10. CI, build và chi phí

Giữ đúng hai workflow `workflow_dispatch`, không trigger push. Workflow nhẹ không thay đổi. Full verification dùng local regression runner mới, bỏ các bước Core/directory/gateway đã archive và giữ test MKV, shared relay HLS, anime và AI. Không tạo job trả phí bổ sung, không chạy Actions/macOS/Simulator, không retry remote build, không dùng dịch vụ trả phí thay thế.

**Không có IPA mới hoặc kết quả Apple SDK build cho thay đổi này.** Phiên bản/bundle/background mode và MPVKit pin giữ nguyên baseline. Publication/push/PR/merge cũng chưa thực hiện.

## 11. Kiểm tra iPhone bắt buộc trước nghiệm thu

1. Chạy bản DEBUG ký hợp lệ trên iPhone, kiểm tra cài đặt PiP của iOS/app. Thu `[PiP]` qua device console và ghi riêng thao tác manual/Home.
2. MPV: phim MKV và nhiều audio/subtitle, frame đầu, software output, pause/seek trong PiP, Home → app khác → trở lại hai lần; kiểm tra didStart, cửa sổ thật, một audio owner, GPU/geometry/fullscreen restore và callback cũ.
3. AVPlayer: dùng smoke/fallback AVPlayer riêng, controls PiP hệ thống, video ready, automatic flag, audio/background và restore completion khi UI đã attach. Không gộp kết quả với MPV.
4. Aether: xác nhận Rentry/domain hiện hành và website catalog/search/genre/detail; mở một movie và một series, đúng season/tập, chuyển tập rồi quay lại detail. Kiểm tra server lỗi, mạng yếu, HTTP/challenge và explicit session/domain restart.
5. Aether captions: Vietnamese có sẵn, hoặc English → nút dịch website → Vietnamese; kiểm tra đồng bộ khi tua, pause/resume, fullscreen, PiP và quay lại. Ghi rõ nếu website/iOS không hỗ trợ.
6. WebKit: thử nút PiP của website và app bằng gesture thật, từ chối/timeout/retry, iframe cross-origin, Home và trở lại; giữ nguyên decoder/caption state, không duplicate audio. Automatic WebKit có thể không được hỗ trợ.
7. AI Shorts/Book: lướt đầu → tiếp → tiếp → ngược, phát qua giây 6, prefetch, chọn tập cuối, xoay fullscreen, transient inactive, Home/PiP và history. Chạy các XCTest đang giữ, ghi SKIP nếu Simulator không có system PiP.
8. AnimeVietsub/NguonC/KKPhim live và chuyển qua cả ba thư viện; xác nhận source/history/settings/loading không regression.

## 12. Giới hạn và bước tiếp theo

Cần mở truy cập các domain ở mục 5 trong environment settings để tiếp tục khảo sát Aether live; công cụ draft hiện lỗi nên chưa thể áp dụng/lưu tự động. Những API/CDN/translation host phát hiện sau đó cần được kiểm tra bằng request thực trước khi thêm cấu hình. Không yêu cầu secret mới hoặc token GitHub: Git read của repository đang hoạt động bằng proxy sẵn có.

Cần macOS/Apple SDK để typecheck/build và iPhone để xác minh PiP/âm thanh/video. Chỉ chạy workflow IPA nhẹ hoặc kiểm chứng macOS sau yêu cầu riêng theo `Tools/build-cost-policy.md`. Không tuyên bố PiP iPhone đã sửa hoàn toàn hoặc dịch Aether live đã hoạt động dựa trên các unit/fixture checks.

## 13. Commit triển khai

| Commit local | Nội dung |
| --- | --- |
| `6d853a40ee42004d433427c120e3b17c44e2f432` | Domain policy/resolver và fixture/unit tests ban đầu, audit dependency |
| `4e2a0d3fcb6a2332f8cefae734bf379005b08cf8` | Thay nguồn/router/migration, website MVP, archive và cập nhật tests/CI |
| `4c0181cc72a95f5618a52272368fed6462c1de4e` | Native stale-callback guards, AVPlayer controls/delegates, PiP lifetime và logging |
| `9426d3372b76c7fcba2eb5726c91a49a6ab3cb24` | Explicit library/session end và browsing history mới khi mở lại Aether |
| `96a12916f5733fdaaf1f1a69105ebe4378706802` | Phân biệt attachment của bridge với window trong log PiP |
| `3b659cf590f4662032a1002968a8d010ff33513b` | Chặn iframe idle/stale sửa state của video đang sở hữu PiP, clear capability khi video rời DOM và chặn controller anime cho Aether |

Báo cáo/evidence được commit riêng sau các commit mã. Lấy SHA bằng `git log -1 -- AETHER_PIP_MIGRATION_REPORT.md`. Tất cả commit hiện ở nhánh local.

## 14. Danh sách file thay đổi

Danh sách source/test/config và các rename nguyên vẹn so với baseline nằm dưới đây. Báo cáo này, `Tools/local-validation.md` và evidence là các tài liệu bổ sung cuối phiên.

```text
M	.github/workflows/build-ipa.yml
A	AnyAnime/Aether/AetherBrowserView.swift
A	AnyAnime/Aether/AetherDomainResolver.swift
A	AnyAnime/Aether/AetherProvider.swift
A	AnyAnime/Aether/AetherSettingsSection.swift
M	AnyAnime/AnimeService.swift
M	AnyAnime/AppSettingsView.swift
M	AnyAnime/CinemaPlayerView.swift
M	AnyAnime/InterfacePreview.swift
M	AnyAnime/MPVPictureInPicture.swift
M	AnyAnime/MPVPlaybackController.swift
M	AnyAnime/Models.swift
M	AnyAnime/MovieCatalog.swift
M	AnyAnime/MovieProvider.swift
A	AnyAnime/MovieSourceMigration.swift
A	AnyAnime/MovieSourceProviding.swift
M	AnyAnime/NativePiPPolicy.swift
A	AnyAnime/PiPDiagnostics.swift
M	AnyAnime/PlaybackSmokeTest.swift
M	AnyAnime/PlayerView.swift
M	AnyAnime/RootView.swift
A	AnyAnime/WebPiPSessionState.swift
A	AnyAnime/WebPictureInPictureScript.swift
M	README.md
M	Tests/AIDramaUITests.swift
A	Tests/AetherDomainResolverTests.swift
A	Tests/AetherIntegrationTests.swift
M	Tests/AnimeHomeTests.swift
A	Tests/Fixtures/aether-domains.html
M	Tests/MovieSearchUITests.swift
M	Tests/NativePiPPolicyTests.swift
M	Tests/ProviderTests.swift
A	Tests/aether-player.test.cjs
A	Tests/aether-smoke.sh
M	Tests/anime-home-smoke.sh
A	Tests/local-regressions.sh
M	Tests/main.swift
M	Tests/player.test.cjs
A	Tests/relay-hls-smoke.sh
A	Tests/relay_fixture_test.py
M	Tests/serve_player.py
A	Tools/aether-dependency-audit.md
R100	AnyAnime/MovieSourceDirectory.swift	Tools/archive/phim4k/MovieSourceDirectory.swift
R100	AnyAnime/Phim4KCatalog.swift	Tools/archive/phim4k/Phim4KCatalog.swift
R100	AnyAnime/Phim4KProvider.swift	Tools/archive/phim4k/Phim4KProvider.swift
R100	Tests/Phim4KResolverTests.swift	Tools/archive/phim4k/Phim4KResolverTests.swift
R100	AnyAnime/Phim4KVIPResolver.swift	Tools/archive/phim4k/Phim4KVIPResolver.swift
A	Tools/archive/phim4k/README.md
A	Tools/archive/phim4k/historical-PlaybackSmokeTest.swift
A	Tools/archive/phim4k/historical-ProviderTests.swift
A	Tools/archive/phim4k/historical-build-ipa.yml.txt
A	Tools/archive/phim4k/historical-main.swift
R100	Tests/phim4k-live-smoke.sh	Tools/archive/phim4k/phim4k-live-smoke.sh
R100	Tests/serve_core_metadata.py	Tools/archive/phim4k/serve_core_metadata.py
R100	Tests/source2_live_probe.py	Tools/archive/phim4k/source2_live_probe.py
```
