import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Mở to sẵn (90% vùng màn hình, giữa màn hình) để thấy đủ 3 cột, khỏi phải kéo.
    if let screen = NSScreen.main ?? NSScreen.screens.first {
      let area = screen.visibleFrame
      let w = max(1000, area.width * 0.9), h = max(700, area.height * 0.9)
      let frame = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: min(w, area.width), height: min(h, area.height))
      self.setFrame(frame, display: true)
    }
    self.minSize = NSSize(width: 420, height: 560)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Số tin chưa đọc trên biểu tượng ở Dock (Dart: lib/ui/app_badge.dart).
    let badge = FlutterMethodChannel(name: "flygo/badge", binaryMessenger: flutterViewController.engine.binaryMessenger)
    badge.setMethodCallHandler { call, result in
      guard call.method == "set", let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      let n = args["count"] as? Int ?? 0
      NSApp.dockTile.badgeLabel = n <= 0 ? nil : (n > 99 ? "99+" : String(n))
      result(nil)
    }

    super.awakeFromNib()
  }
}
