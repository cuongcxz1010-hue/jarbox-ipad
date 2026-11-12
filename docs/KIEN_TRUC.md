# Kiến trúc KUONTPL

KUONTPL chạy game Java ME (.jar, .jad) trên iPhone và iPad bằng một máy ảo Java thật. Tài liệu này mô tả các lớp của hệ thống, phần nào tái sử dụng từ dự án khác và cách các thành phần gọi nhau.

## Sơ đồ tổng thể

```
┌──────────────────────────────────────────────────────────────────┐
│ Application UI (Swift, SwiftUI, UIKit)                 UI/       │
│ Thư viện game · Màn hình game · Cài đặt từng game · Trình sửa phím│
├──────────────────────────────────────────────────────────────────┤
│ Input Engine        Config Manager        RMS Storage            │
│ Bàn phím ảo,        Cài đặt, hồ sơ phím   Sao lưu, khôi phục     │
│ cần điều khiển      (theo từng game)      dữ liệu từng game      │
├──────────────────────────────────────────────────────────────────┤
│ Emulator Core (C)                                                │
│ Khởi động và dừng máy ảo, truyền thuộc tính, hàng đợi sự kiện    │
├─────────────┬─────────────┬─────────────┬────────────────────────┤
│ Graphics    │ Audio       │ Network     │ 3D                     │
│ Vẽ 2D       │ AVFoundation│ POSIX socket│ M3G, MascotCapsule     │
│ bằng phần   │ WAV, MP3,   │ TCP, UDP,   │ (OpenGL ES)            │
│ mềm, C      │ MIDI, tone  │ IPv6        │                        │
├─────────────┴─────────────┴─────────────┴────────────────────────┤
│ J2ME API (Java, j2me_api.jar)                                    │
│ CLDC / MIDP · lcdui · game · rms · io · media · API các hãng     │
├──────────────────────────────────────────────────────────────────┤
│ Java Virtual Machine (miniJVM, C)                                │
│ Bộ thông dịch bytecode · GC · Luồng · Nạp lớp · HTTP/HTTPS       │
└──────────────────────────────────────────────────────────────────┘
```

## Luồng chạy của một game

1. `GameViewController` đọc cài đặt của game và gọi `jvm_bridge_init` trên một luồng nền.
2. `MIDletRunner.main` đọc manifest và JAD, bật luồng sự kiện rồi tạo luồng `MidletMain`.
3. `MidletMain` tạo đối tượng MIDlet và gọi `startApp()`. Nếu `startApp()` không trả về thì màn hình và phím vẫn hoạt động.
4. Luồng chính của máy ảo chờ sự kiện từ iOS. Nó ngủ khi không có sự kiện, nên không tốn CPU khi đứng yên.
5. Mọi callback vào game (`paint`, `keyPressed`, `commandAction`, `showNotify`, `callSerially`) chạy trên một luồng sự kiện duy nhất, đúng quy định MIDP và cách J2ME Loader làm.

## Bản đồ thư mục

| Module theo yêu cầu | Vị trí |
|---|---|
| Application UI | `J2MEEmulator/UI/` |
| Emulator Core | `J2MEEmulator/Core/` |
| Java Virtual Machine | `J2MEEmulator/minijvm/` |
| J2ME API | `j2me_api/src/` |
| Graphics Engine | `J2MEEmulator/Graphics/` |
| Audio Engine | `J2MEEmulator/Audio/` |
| Network Engine | `J2MEEmulator/Network/`, `j2me_api/src/org/jarbox/net/` |
| Input Engine | `J2MEEmulator/Input/` |
| RMS Storage | `j2me_api/src/javax/microedition/rms/`, `J2MEEmulator/Storage/` |
| Configuration Manager | `J2MEEmulator/Config/` |
| Công cụ kiểm thử | `tools/hostrun/`, `tools/ApiCheck.java`, `test_midlet/` |

## Phần tái sử dụng

| Thành phần | Nguồn | Giấy phép | Ghi chú |
|---|---|---|---|
| Máy ảo miniJVM | digitalgust/miniJVM, qua JarBox | MIT | Giữ nguyên bộ thông dịch, GC, luồng. Đã tắt JIT vì iOS không cho cấp phát mã thực thi |
| Lớp J2ME API | J2ME-Loader, qua JarBox (ccbkv) | Apache 2.0 | Phần thuần Java giữ lại, phần Android đã thay |
| M3G, MascotCapsule | J2ME-Loader, qua JarBox | Apache 2.0 | Dùng OpenGL ES |
| mbedTLS, miniz | Thư viện đi kèm miniJVM | Apache 2.0, MIT | HTTPS, đọc JAR, sao lưu ZIP |
| Hàng đợi sự kiện, `KeyMapper` | Viết theo logic J2ME-Loader | Apache 2.0 | `EventQueue` giữ nguyên, `KeyMapper` viết lại không dùng Android |

## Phần viết mới

- **Bộ vẽ 2D (`gfx_core.c`, `gfx_text.c`, `gfx_png.c`).** Vẽ bằng phần mềm trên bộ đệm điểm ảnh theo đúng quy tắc MIDP, thay cho Core Graphics. Không dùng cấp phát bộ nhớ cho mỗi lần vẽ. Chữ được dựng một lần cho mỗi ký tự rồi lưu lại.
- **Lõi MIDP (`Display`, `Canvas`, `MIDletRunner` và các lớp màn hình).** Luồng sự kiện đúng chuẩn, kích thước màn hình có sẵn ngay khi game khởi tạo, đầy đủ Form và các Item.
- **Mạng (`net_natives.c`, `org.jarbox.net`).** TCP có thời gian chờ, UDP, server socket, đọc qua bộ đệm. Dùng `getaddrinfo` để chạy được trên mạng di động chỉ có IPv6.
- **Màn hình cấp cao (`ScreenView.swift`).** Form, List, TextBox dựng bằng view của iOS từ mô tả JSON.

## Khác biệt so với iOS và Android

| Vấn đề | J2ME Loader (Android) | KUONTPL (iOS) |
|---|---|---|
| Chạy mã Java | Chuyển sang DEX, chạy trên ART | Thông dịch bytecode, vì iOS không cho JIT |
| Vẽ | Android Canvas, OpenGL | Bộ vẽ phần mềm riêng |
| Chạy nền | Dịch vụ nền được phép | iOS tạm dừng ứng dụng, xem `CHAY_NEN.md` |
