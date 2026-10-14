import CallKit
import CryptoKit
import Flutter
import PushKit
import UIKit
import UserNotifications
import flutter_callkit_incoming

/// Thông báo đẩy: lấy mã APNs (tin nhắn) và mã VoIP (cuộc gọi), báo cuộc gọi đến cho CallKit
/// ngay khi nhận VoIP push (iOS bắt buộc), chuyển thao tác bấm thông báo về Flutter qua kênh "flygo/push".
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  private var channel: FlutterMethodChannel?
  private var apnsToken: String?
  private var tokenWaiters: [FlutterResult] = []
  private var launchPayload: [String: Any]?
  private var voipRegistry: PKPushRegistry?
  /// Các cuộc gọi CallKit hiện có (để biết cuộc gọi của kênh đã được trả lời trên máy này chưa).
  private let callObserver = CXCallObserver()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
      DispatchQueue.main.async { application.registerForRemoteNotifications() }
    }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FlygoPush") else { return }
    let ch = FlutterMethodChannel(name: "flygo/push", binaryMessenger: registrar.messenger())
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "apnsToken":
        if let t = self.apnsToken { result(t) } else { self.tokenWaiters.append(result) }
      case "launchPayload":
        result(self.launchPayload)
        self.launchPayload = nil
      case "setRingtones":
        // Nhạc chuông theo nhóm: id kênh → tên tệp (Runner/<tên>.caf), đọc lại khi có cuộc gọi VoIP lúc app tắt.
        UserDefaults.standard.set(call.arguments as? [String: String] ?? [:], forKey: "flygo_ringtones")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  // MARK: APNs (tin nhắn)

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data) {
    let t = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsToken = t
    tokenWaiters.forEach { $0(t) }
    tokenWaiters.removeAll()
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    tokenWaiters.forEach { $0(nil) }
    tokenWaiters.removeAll()
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    var data: [String: Any] = [:]
    for (k, v) in response.notification.request.content.userInfo {
      if let key = k as? String, key != "aps" { data[key] = v }
    }
    if let ch = channel {
      ch.invokeMethod("onTap", arguments: data)
    } else {
      launchPayload = data
    }
    completionHandler()
  }

  // MARK: PushKit (cuộc gọi)

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else { return completion() }
    let p = payload.dictionaryPayload
    let caller = (p["sender_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Flygo Chat"
    let channel = p["channel_id"] as? String ?? ""
    // Mỗi kênh một mã cuộc gọi cố định: tin "cuộc gọi đã kết thúc" tắt đúng màn hình đang đổ chuông.
    // Gọi nhóm của Flygo Chat (tin đổ chuông trong nhóm/kênh): máy chủ đẩy báo thêm video = "1" / "0".
    let video = (p["video"] as? String) == "1"
    let data = flutter_callkit_incoming.Data(id: Self.callUUID(channel), nameCaller: caller, handle: "Flygo Chat", type: video ? 1 : 0)
    if (p["sub_type"] as? String) == "calls_ended" {
      // iOS bắt buộc báo CallKit cho mọi VoIP push: báo lại cuộc gọi cùng mã (đang đổ chuông / đang gọi thì trùng mã,
      // bị bỏ qua) rồi kết thúc. Máy chủ đẩy gửi tin này cho MỌI máy của mình khi mình vào cuộc gọi, kể cả máy vừa
      // trả lời: cuộc gọi của kênh này đã được trả lời trên máy này thì giữ nguyên, không kết thúc.
      data.appName = "Flygo Chat"
      let answeredHere = callObserver.calls.contains {
        $0.uuid.uuidString.uppercased() == Self.callUUID(channel) && $0.hasConnected && !$0.hasEnded
      }
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) {
        if !answeredHere { SwiftFlutterCallkitIncomingPlugin.sharedInstance?.endCall(data) }
        completion()
      }
      return
    }
    data.appName = "Flygo Chat"
    data.duration = 45000
    data.extra = [
      "channel_id": p["channel_id"] as? String ?? "", "server_id": p["server_id"] as? String ?? "",
      "video": video ? "1" : "0",
    ]
    if let ch = p["channel_id"] as? String,
       let ring = (UserDefaults.standard.dictionary(forKey: "flygo_ringtones") as? [String: String])?[ch] {
      data.ringtonePath = "\(ring).caf"
    }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) {
      completion()
    }
  }

  /// Mã cuộc gọi (UUID) suy ra từ id kênh.
  static func callUUID(_ channel: String) -> String {
    if channel.isEmpty { return UUID().uuidString }
    let h = Insecure.MD5.hash(data: Foundation.Data(channel.utf8)).map { String(format: "%02x", $0) }.joined()
    let a = Array(h)
    func s(_ i: Int, _ j: Int) -> String { String(a[i..<j]) }
    return "\(s(0, 8))-\(s(8, 12))-4\(s(13, 16))-a\(s(17, 20))-\(s(20, 32))".uppercased()
  }
}
