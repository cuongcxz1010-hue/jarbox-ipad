# Treo game và chạy nền trên iOS

iOS quyết định khi nào một ứng dụng được chạy. KUONTPL chỉ dùng các API được Apple cho phép và không dùng âm thanh giả, GPS giả hay cách lách nào khác.

## Từng tình huống

| Tình huống | Điều xảy ra | Game có tiếp tục không |
|---|---|---|
| Ứng dụng đang mở | Chạy bình thường | Có |
| Mở Trung tâm điều khiển, thông báo | Ứng dụng vẫn chạy | Có |
| Chuyển sang ứng dụng khác | iOS cho khoảng 30 giây rồi tạm dừng | Khoảng 30 giây |
| Khóa màn hình | Như trên | Khoảng 30 giây |
| Ứng dụng bị tạm dừng | Mọi luồng Java dừng | Không |
| iOS đóng ứng dụng để lấy bộ nhớ | Máy ảo mất hoàn toàn | Không |

Con số 30 giây chỉ là ước lượng; iOS có thể cho ít hơn.

## Khi kết nối máy chủ bị ảnh hưởng

Khi ứng dụng bị tạm dừng, game không gửi và nhận được gì. Máy chủ sẽ tự ngắt kết nối theo thời gian chờ của nó. KUONTPL không thể giữ kết nối thay game, vì như vậy phải thay đổi giao thức của game.

Khi quay lại ứng dụng, socket báo lỗi `IOException` và game tự chạy mã kết nối lại của nó, nếu game có. NSO có đoạn này: khi mất kết nối, game báo và cho đăng nhập lại.

## KUONTPL làm được gì

- **Treo máy ổn định (Menu ≡ → Treo game).** Giữ ứng dụng ở nền trước, tắt tự khóa, làm tối màn hình, chặn chạm, giảm FPS và tự giảm thêm khi máy nóng. Đây là cách treo lâu nhất mà iOS cho phép.
- **Truy cập được hướng dẫn của iOS.** Giữ máy luôn ở trong game. KUONTPL có hướng dẫn trong menu.
- **Theo dõi mạng.** Hiện nhãn "Mất mạng" khi thiết bị mất kết nối.
- **Không tự khởi động lại game khi chuyển ứng dụng.** Mặc định chỉ gửi `hideNotify` và `showNotify`. Có thể bật `pauseApp`/`startApp` trong cài đặt nếu game cần.
- **Khôi phục sau khi iOS đóng ứng dụng.** Lần mở sau KUONTPL đề nghị mở lại game. Game chạy lại từ đầu và dùng dữ liệu RMS đã lưu.
- **Lưu dữ liệu.** RMS được ghi vào đĩa ngay khi game ghi. Có thể tạo bản sao dữ liệu và khôi phục sau.

## Không làm được

- Treo 24/7 khi khóa màn hình.
- Lưu nguyên trạng thái máy ảo đang chạy rồi khôi phục. Máy ảo giữ các luồng, kết nối mạng và đối tượng gốc, không thể ghi ra đĩa.
- `BGContinuedProcessingTask` của iOS 26 chỉ dành cho tác vụ do người dùng khởi động và có điểm kết thúc, như xuất video. Game trực tuyến không thuộc loại này.

## Nếu thật sự cần treo 24/7

Cách khả thi là chạy game trên một máy luôn bật, như máy tính hoặc máy chủ có giả lập, rồi điều khiển từ xa. Việc này nằm ngoài ứng dụng iOS.
