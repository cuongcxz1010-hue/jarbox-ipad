# Bảng tương thích JarBox

Bảng này chỉ ghi những gì đã thực sự chạy thử. Mục chưa thử được ghi rõ là chưa thử.

## Cách kiểm thử

| Công cụ | Làm gì | Chạy ở đâu |
|---|---|---|
| `tools/hostrun` | Chạy game thật trên máy ảo thật và lõi MIDP thật, có kịch bản bấm phím và chụp màn hình. Âm thanh, 3D và màn hình native là bản giả | Windows |
| `test_midlet/selftest` | Kiểm tra tự động: máy ảo, MIDP, quy tắc vẽ từng điểm ảnh, luồng, RMS, mạng | Windows, iOS Simulator |
| `test_midlet/demo` | Cảnh động có sprite, ô nền, chữ, đo FPS | Windows, iOS Simulator |
| `.github/workflows/simulator-test.yml` | Build rồi chạy thử trên iPad và iPhone ảo, lưu ảnh chụp và nhật ký | GitHub Actions |
| `tools/ApiCheck.java` | So API của JarBox với API MIDP 2.0 / CLDC thật theo từng phương thức | Windows, CI |

## Kết quả game thật

| Game | Loại | Nơi thử | Kết quả | Ghi chú |
|---|---|---|---|---|
| Ninja School (client NSO của bạn) | Online, MIDP 2.0, Socket, cảm ứng | Windows host | Chạy tới menu chính, RMS và chạm hoạt động, 29–31 FPS đúng nhịp game | Chưa đăng nhập vào máy chủ, chưa thử trên máy thật |

Bảng này cần bổ sung khi thử thêm game trên thiết bị. Các nhóm game trong yêu cầu chưa có mẫu để thử: game Nokia cổ điển, MIDP 1.0 thật, game 3D thật.

## Kiểm tra tự động (SelfTest)

Tổng cộng 231 mục, đạt 230, không đạt 1 (`ArrayStoreException`).

| Nhóm | Nội dung |
|---|---|
| Máy ảo | Số học, ngoại lệ, kế thừa, switch, đệ quy, `StackOverflowError`, chuyển đổi số thực |
| Bytecode cũ | File class phiên bản 45, lệnh `jsr`/`ret` |
| Chuỗi | UTF-8, tiếng Việt, DataInput/Output |
| Luồng và bộ nhớ | join, wait/notify, synchronized, Timer, sleep, GC |
| RMS | Tạo, ghi, đọc, sửa, xóa, liệt kê, lưu bền |
| Ảnh | PNG, RGB, cắt vùng, trong suốt |
| Graphics | Từng điểm ảnh của hình chữ nhật, đường, cung, tam giác, góc bo, clip, translate, anchor, copyArea |
| Transform | Cả 8 kiểu của drawRegion và createImage |
| Game API | GameCanvas, Sprite, TiledLayer, LayerManager |
| Font, MMAPI | Đo chữ, vẽ chữ, vòng đời Player, âm lượng |
| Mạng | TCP, UDP, HTTP qua loopback; HTTPS tới example.com |
| Sự kiện | Luồng paint, showNotify, serviceRepaints, mã phím, hàm trùng tên với nền tảng |
| Màn hình | Form, các Item, List, TextBox, Alert |
| Khác | MD5, SHA-1, thuộc tính hệ thống |

Âm thanh trong SelfTest chỉ kiểm tra vòng đời Player. Chưa có phép đo nào nghe được âm thanh thật.

## Độ phủ API

Đối chiếu với `midp_2.0.jar` và `cldc_1.0.jar` thật theo từng phương thức: 1.491 mục, thiếu 1 (`Hashtable.rehash`, phương thức protected không game nào gọi).

| Nhóm API | Trạng thái | Ghi chú |
|---|---|---|
| CLDC 1.0, 1.1 | Có | |
| MIDP 1.0, 2.0 | Có | |
| MIDlet, lcdui, game, rms | Có | |
| Form và mọi Item | Có | `CustomItem` chỉ hiển thị, chưa nhận thao tác |
| GCF: Socket, ServerSocket, Datagram, HTTP, HTTPS | Có | |
| MMAPI: WAV, MP3, MIDI, tone | Có | Trên Windows là bản giả. AMR tùy iOS có giải được không |
| java.security: MD5, SHA-1 | Có | Không có SHA-256 |
| M3G (JSR-184) | Có mã, chưa thử | OpenGL ES |
| MascotCapsule v3 | Có mã, chưa thử | OpenGL ES |
| Nokia UI (FullCanvas, DirectGraphics, Sound) | Có mã, chưa thử | `DirectUtils` một phần |
| Siemens, Samsung, Motorola, Sony Ericsson, Vodafone, JBlend, KDDI | Có mã, chưa thử | Lớp từ J2ME Loader |
| SMS (`javax.wireless.messaging`) | Một phần | Mở app Tin nhắn để người dùng tự gửi. Không nhận được tin |

## Chưa có hoặc chỉ là lớp rỗng

Game gọi các API này sẽ không bị lỗi thiếu lớp, nhưng không có chức năng thật.

| API | Lý do |
|---|---|
| Bluetooth (JSR-82), OBEX | Chưa nối với CoreBluetooth; báo không có thiết bị |
| Vị trí (JSR-179) | Chưa nối với CoreLocation |
| PIM (JSR-75) | Không truy cập danh bạ |
| FileConnection (JSR-75) | `file://` chưa triển khai |
| Cảm biến (JSR-256), AMMS (JSR-234) | Lớp rỗng |
| PushRegistry | iOS không cho game tự chạy khi có tin đến |
| `CustomItem` tương tác | Chỉ vẽ một lần |
| Nokia M3D, Clipboard; Vodafone ImageEncoder | Lớp rỗng |

## iPhone và iPad

| Mục | Trạng thái |
|---|---|
| iPad và iPhone, dọc và ngang | Đã xem ảnh chụp trên Simulator. Phím và hình game không đè nhau |
| Safe Area, Dynamic Island | Bố cục theo Safe Area, đã xem trên iPhone Simulator |
| Khóa xoay màn hình theo từng game | Có |
| Chia đôi màn hình iPad | Chưa bật. Bật thì iPadOS bỏ qua khóa xoay: chọn "Luôn nằm ngang" không còn tác dụng |

## Giới hạn đã biết của máy ảo

- `ArrayStoreException` không được ném khi gán sai kiểu vào mảng đối tượng. Game thật gần như không dựa vào điều này.
- Không có JIT vì iOS không cho phép. Game nặng sẽ chậm hơn J2ME Loader trên Android.
