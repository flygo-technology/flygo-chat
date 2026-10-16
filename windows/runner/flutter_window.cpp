#include "flutter_window.h"

#include <optional>
#include <shobjidl.h>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

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

void FlutterWindow::OnDestroy() {
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
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
