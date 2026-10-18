# Flygo Chat: hướng dẫn build cho đối tác

Flygo Chat là app nhắn tin, gọi thoại/video viết bằng Flutter. Một mã nguồn build được cho **Windows, macOS, Linux, Android và iOS**.

Tài liệu gồm 3 phần:

- **Phần A** (mục 1–5): build app dùng **máy chủ Flygo** (`https://chat.flygo.vn`). Đây là cách đơn giản nhất: không phải sửa code, không cần dựng máy chủ gì.
- **Phần B** (mục 6): chạy ẩn và nhận thông báo trên Windows.
- **Phần C** (mục 7): khi đối tác muốn đổi tên app hoặc dùng máy chủ riêng.

---

## Phần A. Build app dùng máy chủ Flygo

### 1. Cài môi trường

| Thành phần | Phiên bản |
|---|---|
| Flutter | **3.47.6** (kênh stable). Nên dùng đúng bản này. |
| Git | bản bất kỳ |

Thêm công cụ theo nền tảng cần build:

| Build cho | Cần thêm |
|---|---|
| Windows | Windows 10/11 + **Visual Studio 2022**, chọn workload "Desktop development with C++" |
| macOS | máy Mac + Xcode + CocoaPods (`brew install cocoapods`) |
| Linux | Ubuntu 22.04+ và các gói: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpulse-dev` |
| Android | Android Studio (hoặc Android SDK) + JDK **17** |
| iOS | máy Mac + Xcode + CocoaPods + tài khoản Apple Developer |

Chạy `flutter doctor` để kiểm tra, mục nào báo ✗ thì cài cho đủ.

### 2. Lấy mã nguồn

```sh
git clone https://github.com/flygo-technology/flygo-chat.git
cd flygo-chat
flutter pub get
```

### 3. Build

App đã trỏ sẵn về máy chủ Flygo, nên **không phải sửa gì** trước khi build.

#### Windows

```powershell
flutter build windows --release
```

Kết quả nằm trong `build\windows\x64\runner\Release\`. Phải chép **cả thư mục** này cho người dùng, không chỉ tệp `flygo_chat.exe`, vì app cần các tệp `.dll` và thư mục `data` đi kèm. Thường thì nén cả thư mục thành `.zip`, người dùng giải nén rồi chạy `flygo_chat.exe`.

Nếu không có máy Windows, có thể build trên GitHub Actions: fork repo, vào tab **Actions**, chạy workflow **windows**, rồi tải tệp `flygo-chat-windows.zip` ở mục Artifacts.

> Lần đầu chạy, Windows SmartScreen có thể báo "Windows protected your PC" vì bản tự build chưa ký số. Bấm **More info → Run anyway**. Muốn hết cảnh báo thì phải ký tệp `.exe` bằng chứng thư Code Signing của công ty.

#### macOS

```sh
cd macos && pod install && cd ..
flutter build macos --release
```

Kết quả là `build/macos/Build/Products/Release/Flygo Chat.app`. Muốn đưa cho máy khác thì phải ký bằng Developer ID và notarize, nếu không macOS sẽ chặn. Dùng nội bộ thì người dùng chuột phải vào app → **Open** ở lần mở đầu.

#### Linux

```sh
flutter build linux --release
```

Kết quả nằm trong `build/linux/x64/release/bundle/`. Chép cả thư mục này cho người dùng, rồi chạy tệp `flygo-chat` bên trong.

#### Android

Android **bắt buộc** chọn flavor bằng `--flavor`:

```sh
flutter build apk --release --flavor sideload
```

Kết quả là `build/app/outputs/flutter-apk/app-sideload-release.apk`, cài trực tiếp lên điện thoại được. Flavor `play` dành riêng cho Google Play (xem mục 7).

> Thông báo đẩy trên Android chỉ đến đúng bản do Flygo ký và phát hành, vì nó gắn với Firebase của Flygo. Bản APK đối tác tự build vẫn nhắn tin, gọi điện được khi app đang mở, nhưng có thể không nhận thông báo khi app đã tắt. Muốn có đầy đủ thông báo, nên cài app Flygo Chat từ Google Play. Bản tự build cũng không cài đè lên được bản từ Google Play (khác chữ ký), phải gỡ bản kia trước.

#### iOS

iOS chỉ cài được bản đã ký bằng tài khoản Apple Developer. Người dùng chỉ cần nhắn tin nên cài **Flygo Chat trên App Store** hoặc qua TestFlight. Đối tác chỉ build iOS khi phát hành app riêng (mục 7).

```sh
cd ios && pod install && cd ..
flutter build ipa --release
```

Bước này cần mở `ios/Runner.xcworkspace` trong Xcode và chọn Team của mình ở **Signing & Capabilities** trước.

### 4. Đăng nhập vào máy chủ Flygo

1. Mở app. Màn hình đăng nhập mặc định là máy chủ **Flygo** (`chat.flygo.vn`).
2. Đăng nhập bằng tài khoản Flygo đã cấp: tên đăng nhập/mật khẩu, hoặc **Đăng nhập bằng Google** nếu tài khoản dùng Google.
3. Chưa có tài khoản thì liên hệ quản trị Flygo để được cấp.

Nếu người dùng lỡ chọn sang máy chủ khác: bấm nút chọn máy chủ ở đầu màn hình đăng nhập (hoặc tab **Bạn**), rồi chọn lại **Flygo**.

**Cấu hình sẵn cho máy tính trong công ty (tuỳ chọn).** Tạo tệp `servers.json` trong thư mục dữ liệu của app trước khi mở app lần đầu:

| Hệ điều hành | Thư mục |
|---|---|
| Windows | `%APPDATA%\Flygo\Flygo Chat\` |
| macOS | `~/Library/Application Support/vn.flygo.chat/` |
| Linux | `~/.local/share/vn.flygo.chat/` |

```json
{
  "current": "https://chat.flygo.vn",
  "no_default": true,
  "items": [{ "url": "https://chat.flygo.vn", "name": "Flygo" }]
}
```

### 5. Tự cập nhật

Bản Windows, macOS, Linux và APK Android tự kiểm tra bản mới trên máy chủ Flygo rồi đề nghị cập nhật.

- **Đối tác build nguyên trạng, không sửa code:** cứ để tự cập nhật. Người dùng sẽ nhận bản chính thức mới nhất của Flygo.
- **Đối tác có sửa code:** build với `--dart-define=NO_SELF_UPDATE=true` để bản của mình không bị bản chính thức ghi đè. Ví dụ:

  ```sh
  flutter build windows --release --dart-define=NO_SELF_UPDATE=true
  ```

---

## Phần B. Windows: chạy ẩn và nhận thông báo

Bản Windows nhận tin nhắn, cuộc gọi trực tiếp từ máy chủ, **không cần** Firebase hay máy chủ đẩy. Điều kiện là **app phải đang chạy**. Để app không bị tắt nhầm, bản Windows có sẵn chế độ chạy ẩn:

- **Bấm X không thoát app.** Cửa sổ thu xuống **khay hệ thống** (góc phải thanh taskbar, có khi nằm trong mũi tên ˄), app vẫn nhận tin và cuộc gọi. Lần đầu sẽ có thông báo nhỏ báo app vẫn đang chạy.
- **Mở lại:** bấm vào biểu tượng Flygo Chat ở khay, hoặc mở app như bình thường. App chỉ chạy một bản, mở lại sẽ hiện đúng cửa sổ đang ẩn.
- **Thoát hẳn:** chuột phải vào biểu tượng ở khay → **Thoát**.
- **Mở cùng Windows:** app tự chạy ẩn dưới khay mỗi khi đăng nhập Windows, nên không bỏ lỡ tin nào.
- **Có tin nhắn:** hiện thông báo của Windows. Bấm vào thông báo thì app mở đúng cuộc trò chuyện.
- **Có cuộc gọi đến:** cửa sổ app tự hiện lên và đổ chuông.

Hai chế độ "chạy ẩn" và "mở cùng Windows" mặc định **bật**. Người dùng tắt được trong tab **Bạn → Chạy ẩn khi đóng cửa sổ / Mở cùng Windows**.

Người dùng cũng nên kiểm tra: **Windows Settings → System → Notifications** đang cho phép Flygo Chat hiện thông báo, và chế độ **Do not disturb / Focus** không chặn thông báo.

> macOS và Linux chưa có chế độ chạy ẩn: đóng cửa sổ là app thoát. Người dùng thu nhỏ cửa sổ thay vì đóng để vẫn nhận thông báo.

---

## Phần C. Tuỳ biến hoặc dùng máy chủ riêng

Chỉ cần đọc phần này khi đối tác muốn phát hành app mang tên riêng, hoặc dùng máy chủ Mattermost của riêng mình.

> Theo [LICENSE](../LICENSE), đổi thương hiệu, dùng máy chủ riêng hoặc phân phối app cần **thoả thuận bằng văn bản với Flygo Technology** trước.

### 7.1. Những chỗ cần thay

| Hạng mục | Vị trí | Giá trị hiện tại |
|---|---|---|
| Máy chủ mặc định | `lib/config.dart` `kDefaultServer` | `https://chat.flygo.vn` |
| Tên hiển thị máy chủ mặc định | `lib/data/servers.dart` | `Flygo` |
| Trạm đẩy chung | `lib/config.dart` `kFlygoPush` | `https://push.flygo.vn` |
| Chuyển giọng nói thành chữ | `lib/api/stt.dart` `kSttUrl` | `https://stt.flygo.vn` |
| Nơi tải bản cập nhật | `lib/update/updater.dart` `base` | máy chủ Flygo |
| Nơi tải runner trợ lý AI | `lib/agent/agent_service.dart` `downloadBase` | máy chủ Flygo |
| Trang chính sách / hỗ trợ | `lib/config.dart` `kPrivacyUrl`, `kSupportUrl` | trang của Flygo |
| Tên app | `macos/Runner/Configs/AppInfo.xcconfig`, `ios/Runner/Info.plist`, `android/app/src/main/AndroidManifest.xml`, `windows/runner/Runner.rc`, `windows/runner/main.cpp`, `linux/` | `Flygo Chat` |
| Bundle id / package | `android/app/build.gradle.kts`, `ios/Runner.xcodeproj`, `macos/Runner/Configs/AppInfo.xcconfig`, `linux/CMakeLists.txt` | `vn.flygo.chat` |
| Apple Team ID | `ios/Runner.xcodeproj/project.pbxproj` (`DEVELOPMENT_TEAM`) | team của Flygo |
| Firebase (Android) | `android/app/google-services.json` | project của Flygo |
| Scheme đăng nhập Google | `lib/config.dart` `kMobileScheme`, `macos/Runner/Info.plist`, AndroidManifest | `flygochat` |
| Biểu tượng, màu | `assets/icon/`, `flutter_launcher_icons.yaml`, `lib/config.dart` `WaColors` | nhận diện Flygo |

Tuyệt đối không dùng lại chứng chỉ, khoá ký, Team ID hay project Firebase của Flygo.

### 7.2. Máy chủ riêng

- **Mattermost:** bật đăng nhập bằng mật khẩu và/hoặc Google SSO. Bật plugin Calls nếu cần gọi điện. Người dùng tự thêm máy chủ trong app được, hoặc đối tác đổi `kDefaultServer` rồi build lại.
- **Trạm đẩy:** app tự tìm `https://push.<tên miền máy chủ>/health`. Ví dụ máy chủ là `chat.congty.vn` thì app tìm `push.congty.vn`. Nếu tìm thấy, app dùng trạm đó cho các việc sau:
  - sổ thiết bị;
  - tắt chuông máy khác khi đã nghe;
  - TURN cho cuộc gọi;
  - lưu sticker.

  Không tìm thấy thì app dùng trạm chung của Flygo.
- **Thông báo đẩy trên điện thoại:**
  - App gửi mã thiết bị cho Mattermost dạng `android_rn-v2:flygo.<token FCM>` hoặc `apple_rn-v2:flygo.<apns>-<voip>`.
  - Máy chủ đẩy phải hiểu tiền tố `flygo.` rồi gửi tin qua FCM/APNs bằng khoá của đối tác. Cuộc gọi trên iOS dùng VoIP push, topic là `<bundle id>.voip`.
  - Mã nguồn máy chủ đẩy không nằm trong repo này. Liên hệ Flygo nếu cần.
- **Trợ lý AI, chuyển giọng nói thành chữ:** cần dịch vụ riêng. Không có thì app vẫn chạy, chỉ ẩn hoặc tắt các tính năng này.

### 7.3. Ký và phát hành

- **Google Play:** build `flutter build appbundle --release --flavor play`. Khoá upload khai báo trong `android/key.properties`. Tệp này không đưa vào git:

  ```properties
  storeFile=/đường/dẫn/upload.jks
  storePassword=...
  keyAlias=upload
  keyPassword=...
  ```

- **App Store:** dùng `flutter build ipa`, rồi upload bằng Xcode Organizer hoặc Transporter.
- `tool/publish_update.sh` đăng bản tự cập nhật lên máy chủ qua SSH. Trước khi dùng, khai báo `FLYGO_UPDATE_HOST` và `FLYGO_UPDATE_DIR` trong biến môi trường hoặc tệp `tool/local.env` (không đưa vào git).
