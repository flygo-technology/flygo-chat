import Cocoa
import FlutterMacOS
import ScreenCaptureKit

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

    // Chụp màn hình để đính kèm vào tin nhắn (Dart: lib/ui/screen_grab.dart).
    let shot = FlutterMethodChannel(name: "flygo/screenshot", binaryMessenger: flutterViewController.engine.binaryMessenger)
    shot.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handleShot(call, result)
    }

    super.awakeFromNib()
  }

  // MARK: Chụp màn hình

  /// Màn hình đang có con trỏ chuột lúc bấm chụp.
  private var shotScreen: NSScreen?
  /// Cửa sổ trước khi thành lớp phủ toàn màn hình (để trả lại như cũ).
  private var shotSaved: (frame: NSRect, style: NSWindow.StyleMask, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior)?

  // Cửa sổ không viền (lớp phủ chọn vùng) vẫn nhận bàn phím (Esc, Enter, gõ chữ).
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  private func handleShot(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "permission":
      result(CGPreflightScreenCaptureAccess())
    case "requestPermission":
      result(CGRequestScreenCaptureAccess())
    case "hide":
      // Cửa sổ đang toàn màn hình (Space riêng): ẩn đi sẽ chỉ còn Space trống, không chụp được gì.
      if styleMask.contains(.fullScreen) {
        result(FlutterError(code: "fullscreen", message: "window is in full screen", details: nil))
        return
      }
      let mouse = NSEvent.mouseLocation
      shotScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screen ?? NSScreen.main
      orderOut(nil)
      result(nil)
    case "capture":
      captureShot(result)
    case "overlay":
      guard let s = shotScreen else {
        result(nil)
        return
      }
      if shotSaved == nil { shotSaved = (frame, styleMask, level, collectionBehavior) }
      styleMask = [.borderless]
      level = .screenSaver  // trên cả thanh menu và Dock
      collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      setFrame(s.frame, display: true)
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    case "restore":
      if let v = shotSaved {
        orderOut(nil)
        styleMask = v.style
        level = v.level
        collectionBehavior = v.behavior
        setFrame(v.frame, display: true)
        shotSaved = nil
      }
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Chụp màn hình [shotScreen] đủ độ phân giải (Retina), trả về điểm ảnh BGRA từ trên xuống.
  private func captureShot(_ result: @escaping FlutterResult) {
    guard let s = shotScreen ?? NSScreen.main,
          let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
      result(FlutterError(code: "failed", message: "no screen", details: nil))
      return
    }
    let id = CGDirectDisplayID(num.uint32Value)
    let pw = Int(s.frame.width * s.backingScaleFactor), ph = Int(s.frame.height * s.backingScaleFactor)
    let done: (CGImage?) -> Void = { img in
      DispatchQueue.main.async {
        guard let img = img, let px = Self.bgraPixels(img) else {
          result(FlutterError(code: "failed", message: "capture failed", details: nil))
          return
        }
        result(["bgra": FlutterStandardTypedData(bytes: px.data), "width": px.width, "height": px.height])
      }
    }
    if #available(macOS 14.0, *) {
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
        guard let d = content?.displays.first(where: { $0.displayID == id }) else {
          done(nil)
          return
        }
        let cfg = SCStreamConfiguration()
        cfg.width = pw
        cfg.height = ph
        cfg.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
          done(img)
        }
      }
    } else {
      done(CGDisplayCreateImage(id))
    }
  }

  private static func bgraPixels(_ img: CGImage) -> (data: Data, width: Int, height: Int)? {
    let w = img.width, h = img.height
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let p = ctx.data else { return nil }
    return (Data(bytes: p, count: w * h * 4), w, h)
  }
}
