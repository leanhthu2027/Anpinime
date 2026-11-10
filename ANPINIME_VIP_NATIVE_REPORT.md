# Anpinime VIP: giao diện native và video Aether

Nhánh: `feature/anpinime-vip-native-aether`, tiếp nối mã đã sửa ở `0ffacc3`
(bản 2.9.4 build 24). `origin/main` đã được đối chiếu; thiết kế `HomeView`
so với main chỉ đổi mục nguồn Phim4K thành Anpinime VIP. Không sửa trực tiếp main.
IPA build 24 là web MVP cũ và **không chứa bản sửa này**.

## Hành vi hiện tại

- Nguồn 2 hiển thị **Anpinime VIP**. Home, tìm kiếm, thể loại, banner, poster,
  card, chi tiết và danh sách tập dùng giao diện Anpinime sẵn có. Browser MVP
  được chuyển khỏi target ứng dụng vào `Tools/archive/aether-web-mvp`.
- Metadata dùng TMDB theo tích hợp Streambert tại commit
  `270d5fa9fec9a846195b2e08df45c2d939863b64`. Không giả định Aether có API
  danh mục ổn định chưa được xác minh. Home có Thịnh hành, Phim mới, Phim lẻ,
  Phim bộ và hai hàng thể loại; Thể loại có nhóm phim lẻ/phim bộ. Chi tiết phim bộ tải toàn bộ
  phần có tập, kể cả ngoại truyện, giữ đúng số tập gốc.
- Nhập **TMDB API Read Access Token** tại **Cài đặt → Anpinime VIP** để tải
  danh mục. Token lưu trong Keychain, không ghi vào UserDefaults hoặc Git,
  chỉ gửi đến `api.themoviedb.org`. Không có token dùng chung được sao chép.
- Video dùng đường dẫn Aether `media/tmdb-movie-ID` hoặc
  `media/tmdb-tv-ID/PHẦN/TẬP` lấy từ Streambert. Tên miền tự tìm qua rentry,
  cache danh sách 6 giờ và miền hoạt động 1 giờ, có bốn miền dự phòng. Thay miền
  không đổi ID phim/tập và không di chuyển video đang phát.
- `AetherPlayerViewController` là backend WebKit riêng dưới
  `CinemaPlayerView`. Không dò stream URL, không chuyển Aether sang MPV.
  Lệnh native đồng bộ play/pause, tua, thời gian, tốc độ và track HTML5 mà
  video công bố. Âm lượng iPhone dùng điều khiển âm lượng hệ thống.
- `PlayerSettingsPanel` giữ bố cục/tab. Phụ đề HTML5 ưu tiên tiếng Việt, sau đó
  tiếng Anh. Nút chất lượng và nút **Máy chủ, chất lượng và dịch phụ đề** mở
  điều khiển Aether ngay trong trình phát. Dùng bảng đó để chọn server,
  chất lượng, OpenSubtitles, kiểu chữ và **Translate → Vietnamese** khi Aether
  hỗ trợ. Không có API server/chất lượng/translation giả và không xây dịch vụ
  dịch mới. Không thể bảo đảm phụ đề do Aether tự render sẽ xuất hiện trong
  `video.textTracks`; trường hợp này dùng bảng gốc.

## PiP: nguyên nhân và phạm vi sửa

Lỗi xác nhận được bằng mã: MPV bỏ qua yêu cầu PiP khi người dùng đang pause,
ở cả khâu nhận lệnh, chuẩn bị renderer và lấy frame đầu. Gate mới cho phép
yêu cầu **thủ công** từ video đã decode đang pause. PiP tự động vẫn cần video
đang phát, decoder sẵn sàng, view gắn vào cửa sổ, frame và output đã sẵn sàng.
Giữ `MPVPictureInPicture` và cơ chế AVKit native hiện có.

Aether dùng khả năng PiP do HTML5/WebKit thực sự báo. Session/request ID ngăn
iframe hoặc callback cũ ghi đè chủ sở hữu. Chuyển tập/tải lại chờ PiP cũ dừng;
không tạo hai backend cùng lúc. Chuyển ứng dụng không tự pause một phiên PiP
đang hoạt động. Đổi nguồn/thư viện kết thúc rõ phiên cũ. Từ chối/timeout PiP
hiển thị giới hạn, không báo thành công thay cho sự kiện hệ thống.

Khi mở một player mới, cả host native cũ và Aether cũ nhận lệnh kết thúc phiên;
tháo view tạm thời khi PiP đang chạy vẫn giữ decoder. Cleanup MPV bất đồng bộ
không còn được ghi đè trạng thái PiP của player kế tiếp dùng chung PlaybackState.
VIP dùng nút PiP thủ công; không hiển thị công tắc tự mở PiP khi rời app vì
WebKit chưa cung cấp cầu nối ổn định cho lựa chọn đó.

## Kiểm chứng và giới hạn

`Tests/local-regressions.sh` chạy thành công trên Swift 6.0.3/Linux và Node/jsdom.
Sau sửa ownership cuối, đã chạy lại PiP policy, hai bộ JS và parse các file
player liên quan, đều thành công. `git diff --check` sạch.

| Kiểm tra | Kết quả |
| --- | --- |
| Resolver miền: discovery, cache, fallback, redirect, challenge, cancellation | PASS, 35 kiểm tra |
| Migration và WebPiP session/request, stale iframe/callback | PASS, 28 kiểm tra |
| Production catalog/provider TMDB: Home và thể loại, search, detail, toàn bộ phần/tập, route, cache/token thay đổi giữa request | PASS, 31 kiểm tra |
| Native PiP policy, bao gồm MPV pause thủ công và teardown khi chuyển player | PASS, 79 kiểm tra |
| Player Anime hiện có | PASS, 9 nhóm JavaScript |
| Bridge Aether: native commands/state, vi/en, caption DOM/dịch gốc, nguồn thay thế, PiP pending/cancel/late start, viewport và blocked play | PASS, JavaScript DOM fixtures |
| Parser, source isolation, NguonC/KKPhim provider, Anime Home/cache, PineDrama provider | PASS, các suite hiện có |
| HTTP Range/probe, redirect và tài nguyên ảo 12 GB | PASS |
| Cú pháp toàn bộ Swift production và các file player sửa cuối | PASS, parse; không phải Apple SDK typecheck |
| XCTest UI, playback/PiP trên iOS, Keychain thật | CHƯA CHẠY: cần Apple runtime/iPhone |

Các kiểm tra dùng production provider/bridge cùng HTTP/DOM fixture; không phải
bằng chứng Aether trực tiếp hoặc PiP iPhone hoạt động. Log local nằm trong
`/workspace/.anpinime-tools/vip-native-regressions.log` và
`vip-final-ownership-checks.log`.

Môi trường Linux không có Apple SDK/Xcode/Simulator. Chưa chạy iOS typecheck,
build IPA hoặc GitHub Actions cho nhánh này. Proxy hiện chặn Aether, rentry
và TMDB; không có TMDB credential được cấu hình. Đường dẫn phát đối chiếu
Streambert chưa được xác nhận với máy chủ đang hoạt động.

Trên iPhone cần kiểm tra:

1. Nhập token TMDB, Home/tìm kiếm/thể loại, chi tiết phim lẻ và phim nhiều phần.
2. Mở Aether: phát/tạm dừng/tua/tốc độ, đổi server/chất lượng/âm thanh; track Việt,
   OpenSubtitles và dịch Anh → Vietnamese bằng chức năng Aether.
3. PiP AVPlayer, MPV và WebKit: mở từ video đang phát, MPV đang pause, đổi app,
   play/pause/tua trong PiP, đóng và khôi phục, chuyển tập/nguồn khi đang PiP.
4. AnimeVietsub, NguonC, KKPhim và PineDrama vẫn phát; không có hai nguồn phát
   cùng lúc. Renderer, âm thanh nền và khả năng website cho PiP cần thiết bị thật.

Nếu Aether/WebKit không cho PiP với video cụ thể, ứng dụng báo chưa mở được
PiP và cung cấp điều khiển gốc. Không cam kết PiP vượt giới hạn của website/iOS.

## File thay đổi

| Nhóm | File |
| --- | --- |
| Danh mục native | `AnyAnime/Aether/AetherProvider.swift`, `AetherCatalog.swift`, `AetherMetadataSettings.swift`, `AetherDomainResolver.swift` |
| Video Aether | `AnyAnime/Aether/AetherPlayerViewController.swift`, `AetherPlayerScript.swift`, `AnyAnime/PlayerView.swift` |
| Nguồn và UI | `AnyAnime/Models.swift`, `MovieProvider.swift`, `MovieSourceProviding.swift`, `RootView.swift`, `AppSettingsView.swift`, `CinemaPlayerView.swift`, `PlayerSettingsPanel.swift`, `AnyAnime/Aether/AetherSettingsSection.swift` |
| PiP | `AnyAnime/MPVPlaybackController.swift`, `MPVPictureInPicture.swift`, `NativePiPPolicy.swift` |
| Kiểm thử | `Tests/AetherCatalogTests.swift`, `AetherIntegrationTests.swift`, `NativePiPPolicyTests.swift`, `aether-native-player.test.cjs`, `AIDramaUITests.swift`, `aether-smoke.sh`, `anime-home-smoke.sh`, `local-regressions.sh` |
| Lưu mã lịch sử | Chuyển `AnyAnime/Aether/AetherBrowserView.swift` và `Tests/aether-player.test.cjs` sang `Tools/archive/aether-web-mvp/`, thêm README archive |
| Tài liệu | `README.md`, báo cáo này; đánh dấu lịch sử tại `AETHER_IPA_BUILD_24.md`, `AETHER_PIP_MIGRATION_REPORT.md` |

Migration cài đặt Phim4K và lịch sử riêng nguồn được giữ, có fixture kiểm tra.
Parser JSON, relay, transport/probe và các phần dùng chung khác không bị xóa.

## Môi trường cloud

Node/jsdom, Python và Swift 6.0.3 Linux trong container đã cài để chạy kiểm thử
offline; không cần dịch vụ chạy lâu dài. Dùng checkout hiện có, không tạo worktree.
Việc lưu `install_script`, `start_skill`, domain và yêu cầu token vào draft
onboarding vẫn **chưa được xác nhận**: công cụ trả `INVALID_ARGUMENT`.
Các hướng dẫn local hiện ở `/workspace/.anpinime-tools/START.md` và `install.sh`.
Chưa xác nhận khôi phục môi trường ở task mới.

Để kiểm tra live trong cloud, cần thêm vào môi trường các domain `rentry.co`,
`aether.st`, `aether.ist`, `aether.cx`, `aether.bar`, `api.themoviedb.org`,
`image.tmdb.org`, `www.themoviedb.org`; nhập token ở phần secret môi trường nếu
cần chạy API trực tiếp. Đây là cấu hình môi trường; token thử app nhập riêng
trong Cài đặt của app. Không gửi token qua chat.
