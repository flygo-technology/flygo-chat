#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Cửa sổ chính của bản đang chạy (FlutterWindow đánh dấu bằng prop này), kể cả khi đang ẩn dưới khay.
BOOL CALLBACK FindMainWindow(HWND hwnd, LPARAM out) {
  if (GetProp(hwnd, L"FlygoChatMainWindow")) {
    *reinterpret_cast<HWND*>(out) = hwnd;
    return FALSE;
  }
  return TRUE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Mở bình thường (không phải cửa sổ --chat= / --server= hay liên kết flygochat://) là cửa sổ chính.
  // Đã có bản chạy (có thể đang ẩn dưới khay) thì hiện bản đó lên rồi thoát, không mở bản thứ hai.
  bool start_hidden = false;
  bool is_main = true;
  for (const auto& a : command_line_arguments) {
    if (a == "--hidden") {
      start_hidden = true;
    } else {
      is_main = false;
    }
  }
  if (is_main) {
    HWND running = nullptr;
    EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&running));
    if (running) {
      if (!start_hidden) {
        ShowWindow(running, IsIconic(running) ? SW_RESTORE : SW_SHOW);
        SetForegroundWindow(running);
      }
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  if (is_main) window.SetMainWindow(start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Flygo Chat", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  // Mở to sẵn (phóng to cửa sổ) để thấy đủ 3 cột, khỏi phải kéo.
  if (!start_hidden) ::ShowWindow(window.GetHandle(), SW_MAXIMIZE);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
