import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Liên kết flygochat://callback?MMAUTHTOKEN=... (đăng nhập Google) mở vào chính app đang chạy:
  /// chuyển cho Flutter qua kênh "flygo/link".
  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let vc = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "flygo/link", binaryMessenger: vc.engine.binaryMessenger)
    for url in urls {
      channel.invokeMethod("open", arguments: url.absoluteString)
    }
  }
}
