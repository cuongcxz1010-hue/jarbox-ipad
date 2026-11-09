# Tiến độ theo từng giai đoạn

Ghi lại những gì đã làm, đã kiểm tra bằng cách nào, và những gì còn thiếu.

| Giai đoạn | Trạng thái | Kiểm tra bằng |
|---|---|---|
| 1. Nghiên cứu mã nguồn | Xong | Đọc J2ME-Loader, JL-Mod, JarBox, miniJVM. Đối chiếu API bằng `tools/ApiCheck.java` |
| 2. miniJVM chạy MIDlet | Xong | Chạy được trên Windows (`tools/hostrun`) và iOS Simulator |
| 3. MIDP 2.0, CLDC 1.1 | Xong | ApiCheck: 1.491 mục, thiếu 1 phương thức protected không dùng tới. SelfTest |
| 4. Đồ họa, âm thanh, mạng, RMS | Xong, âm thanh mới có kiểm tra vòng đời | SelfTest, ảnh chụp, NSO trên Windows |
| 5. Bàn phím và tùy chỉnh | Xong | Ảnh chụp bố cục. Thao tác thật cần thử trên máy |
| 6. Giao diện quản lý game | Xong | Ảnh chụp iPad, iPhone |
| 7. iPhone, iPad, vòng đời | Xong phần chạy được trên Simulator | Ảnh chụp dọc, ngang. Khóa màn hình và chuyển app cần thử trên máy |
| 8. Kiểm thử game thật | Một phần | NSO tới màn đăng nhập trên Windows. Chưa vào trận, chưa thử trên máy thật |
| 9. Build IPA | Xong | GitHub Actions |

## Việc đã làm trong đợt làm lại

**Lõi MIDP.** MIDlet chạy trên luồng riêng. Mọi callback chạy trên một luồng sự kiện. Kích thước màn hình có ngay khi game khởi tạo; trước đây game đọc `getWidth()` trong hàm tạo luôn nhận 240×320 dù đặt độ phân giải khác.

**Vẽ 2D.** Bộ vẽ phần mềm mới theo đúng quy tắc MIDP. Đã kiểm tra từng điểm ảnh cho hình chữ nhật, đường, cung, tam giác, clip, anchor và 8 kiểu transform.

**Form đầy đủ.** ChoiceGroup, Gauge, DateField, ImageItem, Spacer, lệnh theo từng item. Trước đây các mục này chỉ hiện chữ và không bấm được, kể cả trong các Form của NSO.

**Mạng.** TCP có thời gian chờ, chạy được trên mạng chỉ có IPv6, UDP, server socket. Đọc qua bộ đệm thay vì một lần gọi hệ thống cho mỗi byte. Bỏ qua SIGPIPE, trước đây ghi vào socket đã đóng có thể làm app bị tắt.

**Chạy nền.** Gỡ âm thanh câm và quyền chạy nền bằng âm thanh. Xem `CHAY_NEN.md`.

**Bàn phím.** Cần điều khiển 8 hướng, độ trễ và tốc độ lặp, khoảng cách, màu từng phím, bộ mã phím theo hãng, xuất nhập cấu hình.

**Quản lý game.** Trạng thái, độ phân giải, thời gian chơi, kiểm tra MIDlet-Class, sao lưu và khôi phục.

## Lỗi của nền tảng tìm ra nhờ kiểm thử

| Lỗi | Hậu quả | Đã sửa |
|---|---|---|
| Trùng tên hàm nội bộ `show()`, `hide()`, `refresh()` với hàm của game | Máy ảo gọi nhầm hàm của game, màn hình không đổi | Có, đổi tên hàm nội bộ |
| `SHA1.digest(byte[], int, int)` của thư viện máy ảo trả về rỗng | Game băm SHA-1 nhận kết quả sai | Có |
| Ép NaN sang số nguyên trên x86 sai | Chỉ ảnh hưởng Simulator Intel và bản Windows | Có |
| `getImage` mutable, RGB, transform mất độ trong suốt | Ảnh cắt từ ảnh có nền trong bị nền trắng | Có |
| Mã biên dịch theo thư viện JDK, gọi hàm máy ảo không có | Lỗi `NoSuchMethodError` trên máy | Có, nay biên dịch theo đúng thư viện máy ảo |
| `ArrayStoreException` không được ném | Game thật gần như không dựa vào | Chưa, ghi là giới hạn |

## Còn lại

- Chưa thử trên iPad thật, nên chưa đo được FPS thật và độ trễ phím.
- Chưa thử NSO khi đã đăng nhập, chưa vào bản đồ.
- Chưa thử game 3D (M3G, MascotCapsule).
- Chưa có FileConnection, Bluetooth, vị trí. Danh sách ở `TUONG_THICH.md`.
