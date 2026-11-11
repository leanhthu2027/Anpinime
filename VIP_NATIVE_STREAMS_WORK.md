# Native playback follow-up — chưa hoàn tất chuyển Aether

Nhánh `feature/vip-native-streams-pip` tiếp nối IPA build 25. Không có IPA mới
và không chạy Actions cho lần sửa này.

## Đã sửa và kiểm thử offline

- MPV tự mở PiP khi vào nền không còn phụ thuộc hoàn toàn vào việc lấy sẵn
  snapshot thành công. Dùng đường chuẩn bị/start native hiện có, tối đa một
  yêu cầu mỗi lần vào nền; timeout/cleanup không tạo vòng lặp thử lại.
- Giữ ý định pause của người dùng. Cinema không gửi pause khi host native
  tạm biến mất trong chuyển tiếp hệ thống; đóng thật vẫn teardown controller.
- Timer MPV/AVPlayer dùng common runloop mode, đọc lại thời gian ngay khi trở
  về foreground. Hủy trạng thái kéo slider nếu chuyển app giữa thao tác kéo.
- Danh mục đọc credential mặc định từ resource riêng; bỏ ô nhập/hiển thị
  token trong Settings. Credential được cung cấp đã được chuẩn bị trong
  `AnyAnime/Private/MetadataCredentials.plist`, bị Git ignore, không nằm trong
  commit. `Tools/prepare-metadata-credentials.py` tạo resource từ build secret
  hoặc private plist và không in giá trị.
- Workflow nhẹ chuẩn bị resource trước XcodeGen từ secret `TMDB_API_KEY` hoặc
  `TMDB_READ_TOKEN`. Chưa cấu hình được secret trên GitHub; remote build sẽ
  dừng với lỗi cấu hình nếu thiếu secret. Local workspace đã có resource.

PASS: toàn bộ `Tests/local-regressions.sh`: domain 35, migration/bridge 28,
catalog/provider 31, credential loader 9, credential preparation 4, PiP policy
83; các nhóm JS player, parser, provider, Home/cache, PineDrama, Range fixture.
Swift production parse và diff-check PASS. Thay đổi slider cuối được parse lại.
Chưa chạy Apple SDK build hoặc kiểm tra PiP/render/âm thanh trên iPhone.

## Việc chưa làm được

**Aether vẫn còn WebKit trong nhánh này.** Các sửa native trên không được xem
là bằng chứng đã sửa PiP WebKit trong ảnh chụp. Chưa thay stream resolver,
subtitle/translation/server API và chưa bỏ bảng điều khiển website. Chưa có
giao thức Aether được xác minh để thực hiện việc đó mà vẫn phát đúng phim/sub.

Đối chiếu Streambert: chỉ có route `/media/tmdb-movie-ID` và
`/media/tmdb-tv-ID/SEASON/EPISODE` để embed trang, không phải URL stream.
Đã đọc P-stream: resolver dùng thư viện provider, cấu hình proxy và token riêng;
chưa có bằng chứng đó là backend của bản Aether đang chạy. Một repo bên thứ ba
tên `aether-streaming-proxy` chỉ chuyển tiếp URL stream do người gọi cung cấp,
không giải quyết bước lấy stream nên không được tích hợp.

Truy cập Aether và rentry từ workspace bị proxy trả CONNECT 403. Công cụ đọc
draft môi trường trả INVALID_ARGUMENT hai lần. Không thể xác minh endpoint
stream, playlist chất lượng/audio, phụ đề hay dịch bằng nguồn live hiện tại.

Cần cho phép `aether.st`, `aether.ist`, `aether.cx`, `aether.bar`, `rentry.co`,
`api.themoviedb.org`, `image.tmdb.org` trong cài đặt mạng môi trường, sau đó
kiểm tra request thật của trang phát. Các host stream/API phát hiện tiếp theo
phải được kiểm chứng trước khi thêm. Không dùng proxy ngoài hoặc CI để vượt
chặn mạng. Không giả định một API chưa xác minh rồi tuyên bố native hoàn tất.
