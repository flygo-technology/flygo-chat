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
    let data = flutter_callkit_incoming.Data(id: UUID().uuidString, nameCaller: caller, handle: "Flygo Chat", type: 0)
    data.appName = "Flygo Chat"
    data.duration = 45000
    data.extra = ["channel_id": p["channel_id"] as? String ?? "", "server_id": p["server_id"] as? String ?? ""]
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) {
      completion()
    }
  }
}
