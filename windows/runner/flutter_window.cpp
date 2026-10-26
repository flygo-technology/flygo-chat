#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <shobjidl.h>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

#include <cstdio>
#include <cstdlib>
#include <string>

// Nhật ký khởi động phía native: %TEMP%\flygo-init.log (cùng tệp với phía Dart).
static void InitLog(const char* step) {
  wchar_t dir[MAX_PATH];
  DWORD len = GetTempPathW(MAX_PATH, dir);
  if (len == 0 || len >= MAX_PATH) return;
  std::wstring path = std::wstring(dir) + L"flygo-init.log";
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"a") != 0 || f == nullptr) return;
  SYSTEMTIME t;
  GetLocalTime(&t);
  fprintf(f, "%04d-%02d-%02dT%02d:%02d:%02d.%03d [native %lu] %s\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
          t.wMilliseconds, GetCurrentProcessId(), step);
  fclose(f);
}

namespace {

// Tin nhắn từ biểu tượng khay và lệnh trong menu khay.
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuOpen = 1001;
constexpr UINT kMenuQuit = 1002;

// Đánh dấu cửa sổ chính để bản chạy sau (main.cpp) tìm thấy.
constexpr wchar_t kMainWindowProp[] = L"FlygoChatMainWindow";

std::wstring Utf16FromUtf8(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

std::wstring StringArg(const flutter::EncodableMap& m, const char* key) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return std::wstring();
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? Utf16FromUtf8(*s) : std::wstring();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  if (is_main_) SetProp(GetHandle(), kMainWindowProp, reinterpret_cast<HANDLE>(1));

  taskbar_created_msg_ = RegisterWindowMessage(L"TaskbarButtonCreated");
  badge_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "flygo/badge",
      &flutter::StandardMethodCodec::GetInstance());
  badge_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "set") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    HICON icon = nullptr;
    if (args) {
      auto rgba_it = args->find(flutter::EncodableValue("rgba"));
      auto size_it = args->find(flutter::EncodableValue("size"));
      if (rgba_it != args->end() && size_it != args->end()) {
        const auto* rgba = std::get_if<std::vector<uint8_t>>(&rgba_it->second);
        const auto* size = std::get_if<int32_t>(&size_it->second);
        if (rgba && size && *size > 0 && rgba->size() == static_cast<size_t>(*size * *size * 4)) {
          const int n = *size;
          BITMAPV5HEADER bi = {};
          bi.bV5Size = sizeof(bi);
          bi.bV5Width = n;
          bi.bV5Height = -n;  // từ trên xuống
          bi.bV5Planes = 1;
          bi.bV5BitCount = 32;
          bi.bV5Compression = BI_BITFIELDS;
          bi.bV5RedMask = 0x00FF0000;
          bi.bV5GreenMask = 0x0000FF00;
          bi.bV5BlueMask = 0x000000FF;
          bi.bV5AlphaMask = 0xFF000000;
          void* bits = nullptr;
          HDC dc = GetDC(nullptr);
          HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
          ReleaseDC(nullptr, dc);
          if (color && bits) {
            auto* dst = static_cast<uint8_t*>(bits);
            for (int i = 0; i < n * n; ++i) {  // RGBA → BGRA
              dst[i * 4 + 0] = (*rgba)[i * 4 + 2];
              dst[i * 4 + 1] = (*rgba)[i * 4 + 1];
              dst[i * 4 + 2] = (*rgba)[i * 4 + 0];
              dst[i * 4 + 3] = (*rgba)[i * 4 + 3];
            }
            HBITMAP mask = CreateBitmap(n, n, 1, 1, nullptr);
            ICONINFO ii = {};
            ii.fIcon = TRUE;
            ii.hbmColor = color;
            ii.hbmMask = mask;
            icon = CreateIconIndirect(&ii);
            DeleteObject(mask);
          }
          if (color) DeleteObject(color);
        }
      }
    }
    if (badge_icon_) DestroyIcon(badge_icon_);
    badge_icon_ = icon;
    ApplyBadge();
    result->Success();
  });
  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "flygo/tray",
      &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "show") {
      ShowMain();
      result->Success();
      return;
    }
    if (call.method_name() != "config") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args && is_main_) {
      auto it = args->find(flutter::EncodableValue("enabled"));
      const bool* enabled = it == args->end() ? nullptr : std::get_if<bool>(&it->second);
      close_to_tray_ = enabled && *enabled;
      if (auto v = StringArg(*args, "tooltip"); !v.empty()) tray_tooltip_ = v;
      if (auto v = StringArg(*args, "open"); !v.empty()) tray_open_label_ = v;
      if (auto v = StringArg(*args, "quit"); !v.empty()) tray_quit_label_ = v;
      tray_hint_ = StringArg(*args, "hint");
      if (close_to_tray_) {
        RemoveTray();  // cập nhật chữ (đổi ngôn ngữ)
        AddTray();
      } else {
        RemoveTray();
        // Đang ẩn mà tắt chạy ẩn thì hiện lại, không để app chạy mà không thấy đâu.
        if (!IsWindowVisible(GetHandle())) ShowMain();
      }
    }
    result->Success();
  });

  InitLog("engine + view đã tạo");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    InitLog("khung hình đầu tiên (native)");
    if (start_hidden_) return;  // mở thẳng xuống khay
    shown_once_ = true;
    this->Show();
  });
  // FLYGO_SHOW=1: hiện cửa sổ ngay, không chờ khung hình đầu (để thấy app kẹt ở đâu khi màn trắng).
  {
    char* v = nullptr;
    size_t n = 0;
    if (_dupenv_s(&v, &n, "FLYGO_SHOW") == 0 && v != nullptr && std::string(v) == "1") {
      shown_once_ = true;
      this->Show();
      InitLog("FLYGO_SHOW=1: hiện cửa sổ ngay");
    }
    free(v);
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ApplyBadge() {
  ITaskbarList3* taskbar = nullptr;
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar)))) return;
  if (SUCCEEDED(taskbar->HrInit())) {
    taskbar->SetOverlayIcon(GetHandle(), badge_icon_, badge_icon_ ? L"Unread" : L"");
  }
  taskbar->Release();
}

void FlutterWindow::SetMainWindow(bool start_hidden) {
  is_main_ = true;
  start_hidden_ = start_hidden;
}

void FlutterWindow::AddTray() {
  if (tray_added_ || !is_main_) return;
  NOTIFYICONDATA nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayMessage;
  nid.hIcon = static_cast<HICON>(LoadImage(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
                                           GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  wcsncpy_s(nid.szTip, tray_tooltip_.c_str(), _TRUNCATE);
  tray_added_ = Shell_NotifyIcon(NIM_ADD, &nid) == TRUE;
  if (nid.hIcon) DestroyIcon(nid.hIcon);
}

void FlutterWindow::RemoveTray() {
  if (!tray_added_) return;
  NOTIFYICONDATA nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  Shell_NotifyIcon(NIM_DELETE, &nid);
  tray_added_ = false;
}

void FlutterWindow::ShowMain() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (!shown_once_) {
    // Lần đầu hiện (sau khi mở thẳng xuống khay): phóng to như khi mở bình thường.
    shown_once_ = true;
    ShowWindow(hwnd, SW_MAXIMIZE);
  } else if (IsIconic(hwnd) || !IsWindowVisible(hwnd)) {
    ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  }
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenu(menu, MF_STRING, kMenuOpen, tray_open_label_.c_str());
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kMenuQuit, tray_quit_label_.c_str());
  SetMenuDefaultItem(menu, kMenuOpen, FALSE);
  POINT pt;
  GetCursorPos(&pt);
  // Cần đưa cửa sổ lên trước thì menu mới tự đóng khi bấm ra ngoài.
  SetForegroundWindow(GetHandle());
  UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (cmd == kMenuOpen) {
    ShowMain();
  } else if (cmd == kMenuQuit) {
    quitting_ = true;
    PostMessage(GetHandle(), WM_CLOSE, 0, 0);
  }
}

void FlutterWindow::OnDestroy() {
  RemoveTray();
  if (is_main_) RemoveProp(GetHandle(), kMainWindowProp);
  tray_channel_ = nullptr;
  badge_channel_ = nullptr;
  if (badge_icon_) {
    DestroyIcon(badge_icon_);
    badge_icon_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Chạy ẩn: bấm X thì giấu cửa sổ xuống khay thay vì thoát (trước khi Flutter xử lý yêu cầu thoát).
  if (message == WM_CLOSE && close_to_tray_ && tray_added_ && !quitting_) {
    ShowWindow(hwnd, SW_HIDE);
    if (!tray_hint_.empty()) {
      NOTIFYICONDATA nid = {};
      nid.cbSize = sizeof(nid);
      nid.hWnd = hwnd;
      nid.uID = kTrayIconId;
      nid.uFlags = NIF_INFO;
      nid.dwInfoFlags = NIIF_INFO;
      wcsncpy_s(nid.szInfoTitle, tray_tooltip_.c_str(), _TRUNCATE);
      wcsncpy_s(nid.szInfo, tray_hint_.c_str(), _TRUNCATE);
      Shell_NotifyIcon(NIM_MODIFY, &nid);
      tray_hint_.clear();
      if (tray_channel_) tray_channel_->InvokeMethod("hinted", nullptr);
    }
    return 0;
  }
  if (message == kTrayMessage && LOWORD(lparam) != 0) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowMain();
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        break;
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Explorer khởi động lại (hoặc nút taskbar vừa tạo): gắn lại chấm số.
  if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_) {
    ApplyBadge();
    // Explorer khởi động lại thì biểu tượng khay mất: gắn lại.
    if (tray_added_) {
      tray_added_ = false;
      AddTray();
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
