# AnPinime 2.9.4 (24) — IPA để test Aether và PiP

**[Tải AnPinime_UNSIGNED](https://github.com/pythonltn2000/Anpinime/actions/runs/42795441404/artifacts/13755390351)**.
Artifact là ZIP chứa IPA chưa ký, checksum và manifest. Giải nén, ký IPA bằng chứng chỉ hợp lệ rồi cài trên iPhone. Hết hạn **17:04 ngày 13/11/2026 (UTC+7)**.

## Build đã xác nhận

- [Build IPA only](https://github.com/pythonltn2000/Anpinime/actions/runs/42795441404): thành công, đúng một job macOS **264 giây (4 phút 24 giây)**; giới hạn 20 phút, không retry.
- Source: `576260bac7012a0d96ef6f300c67d10537d0e601`, nhánh `feature/aether-migration-pip-recovery`.
- Cây app: `5a4eb728fb9006516886e3b881ea3e95dc1a6c44`.
- Phiên bản **2.9.4**, build **24**, bundle ID `com.xemphim.aipinime`, minimum iOS 15.0.
- Đã kiểm tra độc lập artifact ở [helper Linux](https://github.com/pythonltn2000/Anpinime/actions/runs/42795418482): digest ZIP, SHA256 IPA, commit/cây nguồn, Info.plist, executable, framework mpv, background audio và trạng thái unsigned khớp manifest. Receipt được đối chiếu lại trong workspace.
- SHA256 IPA: `1b834c3dd19aecd4a24b22c6a20ec31eeeb148790cd0ce79e3ffee52f56afb81`.

API GitHub từ workspace bị proxy chặn nên dùng helper trên nhánh riêng `automation/ipa-aether-20261110`. Helper chỉ dispatch đúng workflow nhẹ/source đã duyệt, từ chối duplicate dispatch, theo dõi và kiểm tra artifact. Tổng workflow Linux 5 phút 6 giây, gồm thời gian chờ macOS và tải/kiểm tra gói. Không thay workflow trên main, không Simulator, live test, full suite hoặc dịch vụ trả phí khác. Không merge PR. Các thời gian trên là thời gian thực thi quan sát được, không phải hóa đơn.

Local regressions đã đạt trước khi gửi build: domain Aether 35, migration/bridge 30, native PiP policy 56, parser 117, public provider/transport 37, Home 26, provider AI 143, JS player/Aether và Range fixtures. Sau đó chỉ tăng `CFBundleVersion` từ 23 lên 24 và kiểm tra lại identity cấu hình.

## Test trên iPhone

1. Trong Phim, chọn **Aether**; kiểm tra tìm kiếm, danh mục, mở một phim lẻ và một phim bộ/season/tập bằng website. Thử lỗi server và quay lại detail.
2. Chọn phụ đề Vietnamese hoặc English → nút dịch của Aether → Vietnamese nếu website hỗ trợ. Kiểm tra tua, pause/resume, fullscreen và chuyển tập; bảo đảm không trùng âm thanh.
3. PiP: thử nút website và nút app khi có video đang phát; thử Home → app khác → trở lại hai lần. Làm riêng cho Aether, Anime và Phim AI; kiểm tra audio, pause/seek và khôi phục fullscreen. Bật PiP trong iOS/app cho bài tự động.
4. Phim AI Shorts/Book: lướt tiếp → tiếp → ngược, phát qua giây 6, đổi tập và kiểm tra lịch sử. Kiểm tra lại Anpinime Free/Anpinime dự phòng và chuyển giữa ba thư viện.

Build này dùng cấu hình **Release**, không có telemetry DEBUG. Kết quả compile/đóng gói không xác nhận PiP thật hoặc phát/dịch Aether live. Tình trạng máy thật vẫn là **`NEEDS_PHYSICAL_IPHONE_TEST`**.

Chi tiết source/giới hạn: [migration report](AETHER_PIP_MIGRATION_REPORT.md). Bằng chứng build: [summary](Tools/evidence/2026-11-10-aether-build24/summary.json), [release/budget](Tools/evidence/2026-11-10-aether-build24/release-and-budget.json), [IPA identity](Tools/evidence/2026-11-10-aether-build24/ipa-identity.json).
