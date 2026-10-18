#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Gọi trước Create(). Cửa sổ chính (không phải cửa sổ --chat= / --server=): có biểu tượng khay, bản chạy
  // sau tìm thấy nó. [start_hidden]: mở thẳng xuống khay (`--hidden`, khi khởi động cùng Windows).
  void SetMainWindow(bool start_hidden);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Số tin chưa đọc: chấm đỏ có số đè lên biểu tượng ở taskbar (Dart: lib/ui/app_badge.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> badge_channel_;
  HICON badge_icon_ = nullptr;
  UINT taskbar_created_msg_ = 0;
  void ApplyBadge();

  // Chạy ẩn dưới khay hệ thống (Dart: lib/ui/desktop_tray.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  bool is_main_ = false;
  bool start_hidden_ = false;
  bool shown_once_ = false;
  bool close_to_tray_ = false;
  bool tray_added_ = false;
  bool quitting_ = false;
  std::wstring tray_tooltip_ = L"Flygo Chat";
  std::wstring tray_open_label_ = L"Open Flygo Chat";
  std::wstring tray_quit_label_ = L"Quit";
  std::wstring tray_hint_;
  void AddTray();
  void RemoveTray();
  void ShowMain();
  void ShowTrayMenu();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
