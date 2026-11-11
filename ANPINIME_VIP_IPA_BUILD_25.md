# AnPinime 2.9.4 (25) — IPA Anpinime VIP native

**[Tải AnPinime_UNSIGNED](https://github.com/pythonltn2000/Anpinime/actions/runs/42954536411/artifacts/13827010297)**.
Artifact là ZIP chứa IPA chưa ký, checksum và manifest. Giải nén, ký bằng
chứng chỉ hợp lệ rồi cài trên iPhone. Hết hạn **10:44 ngày 14/11/2026 (UTC+7)**.

Bản này chứa Home/tìm kiếm/thể loại/chi tiết native, backend video Aether riêng
và sửa PiP đã mô tả trong [báo cáo VIP](ANPINIME_VIP_NATIVE_REPORT.md).
IPA build 24 trước đó là web MVP cũ.

## Build và kiểm tra gói

- [Build IPA only](https://github.com/pythonltn2000/Anpinime/actions/runs/42954536411): **thành công**, đúng một job macOS
  **124 giây (2 phút 4 giây)**, giới hạn 20 phút; không retry/Simulator/full suite.
- Source: `62721a303d910308737c7b02fde22fdc0218ae62`, nhánh `feature/anpinime-vip-native-aether`.
- Cây app: `8cf2246034987801e1fcf8eca2ca613891a6a39c`. Source chỉ tăng build counter sau commit
  sửa native `b735f90`; không sửa main hoặc merge PR.
- Phiên bản **2.9.4 (25)**, bundle ID `com.xemphim.aipinime`, minimum iOS 15.0.
- [Helper Linux](https://github.com/pythonltn2000/Anpinime/actions/runs/42954524813) đã tải artifact và kiểm tra độc lập:
  digest ZIP, SHA256 IPA, manifest/commit/cây app, Info.plist, executable,
  framework mpv, background audio và trạng thái unsigned. Receipt được đối chiếu
  lại trong workspace. Helper chỉ gọi đúng workflow/source đã duyệt và từ chối
  duplicate dispatch; tổng thời gian script gồm chờ build và kiểm tra gói là
  165.81 giây. Không truy cập nguồn phim live.
- SHA256 IPA: `072b8cfe1a27eee9c21227d3a7d4e328741416e56365bcdc55148ea94ebfadb8`.

Các kiểm thử offline production provider/JS/parser/Home/PineDrama/Range đã PASS
ở bản sửa native trước khi build; sau đó chỉ tăng `CFBundleVersion` từ 24 lên 25.
`xcodebuild` Release xác nhận biên dịch và liên kết Apple SDK. Workflow không
chạy playback, Keychain, XCTest UI hay kiểm tra PiP hệ thống trên iPhone.

## Khi test trên iPhone

1. Chọn **Anpinime VIP**. Bản hiện tại vẫn cần nhập **TMDB API Read Access Token**
   tại **Cài đặt → Anpinime VIP** để tải danh mục native; video Aether không dùng
   token này. Kiểm tra Home, search, thể loại, phim lẻ và phim bộ nhiều phần.
2. Mở video, thử native play/pause, tua, tốc độ, chuyển tập. Dùng nút chất lượng
   hoặc **Máy chủ, chất lượng và dịch phụ đề** để chọn chức năng Aether thật;
   thử phụ đề Việt hoặc English → Translate → Vietnamese khi Aether hỗ trợ.
3. PiP: thử MPV đang pause, AVPlayer và Aether đang phát; chuyển app, play/pause,
   tua và khôi phục. Với Aether, mở PiP thủ công trước khi rời app. Kiểm tra
   chuyển tập/nguồn không phát hai phiên và kiểm tra lại Anime/Phim AI.

**PiP iPhone và phát/dịch Aether live chưa được xác nhận.** Build thành công
không chứng minh các chức năng đó hoạt động trên máy thật. Gói Release không
có telemetry DEBUG.

Bằng chứng: [summary](Tools/evidence/2026-11-11-vip-build25/summary.json),
[build/budget](Tools/evidence/2026-11-11-vip-build25/release-and-budget.json),
[IPA identity](Tools/evidence/2026-11-11-vip-build25/ipa-identity.json).
