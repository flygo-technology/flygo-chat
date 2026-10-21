import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../calls/ringtones.dart';

/// Thông báo đẩy và cuộc gọi đến khi app tắt / máy khóa.
///
/// Máy chủ Mattermost gửi qua máy chủ đẩy flygo-push:
/// - Android: tin "data" của Firebase; app tự hiện thông báo, cuộc gọi hiện toàn màn hình.
/// - iPhone: tin nhắn là thông báo APNs thường (hệ điều hành tự hiện);
///   cuộc gọi là VoIP push, AppDelegate báo ngay cho CallKit.
class PushService {
  static final _local = FlutterLocalNotificationsPlugin();
  static const _ios = MethodChannel('flygo/push');

  /// Mở một cuộc trò chuyện khi bấm vào thông báo: id kênh. [openServerId] là máy chủ gửi
  /// thông báo (mã DiagnosticId), đặt trước khi đổi [openChannel].
  static final openChannel = ValueNotifier<String?>(null);
  static String? openServerId;
  /// Tin của thông báo vừa bấm (để mở thẳng vào luồng nếu tin nằm trong luồng).
  static String? openPostId;

  /// Máy tính: mở một luồng ở cột phải của chat chính (HomePage đăng ký).
  static void Function(String channelId, String rootId)? openThreadHook;

  /// Payload thông báo: `server_id|channel_id[|post_id]`.
  static void _openFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final parts = payload.split('|');
    if (parts.length == 1) {
      openServerId = null;
      openPostId = null;
      openChannel.value = null;
      openChannel.value = parts[0];
      return;
    }
    openServerId = parts[0].isEmpty ? null : parts[0];
    openPostId = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;
    openChannel.value = null;
    openChannel.value = parts[1];
  }

  /// Máy tính: cửa sổ đang được dùng (để không báo khi người dùng đang xem đúng cuộc trò chuyện).
  static bool appFocused = true;

  /// Máy tính: mở cuộc trò chuyện trong bố cục nhiều cột (HomePage đăng ký).
  static void Function(String channelId)? openChatHook;

  /// Bấm "Từ chối" trên màn hình cuộc gọi của hệ điều hành (main.dart gắn vào CallService).
  static void Function(String channelId)? onSystemDecline;

  /// Nhận cuộc gọi từ màn hình cuộc gọi của hệ điều hành: id kênh.
  static final acceptCall = ValueNotifier<String?>(null);
  /// Cuộc gọi vừa nhận từ màn hình hệ điều hành là gọi video (gọi nhóm có báo trong tin đẩy).
  static bool acceptVideo = false;

  static void _accepted(Map<String, dynamic>? extra) {
    final id = extra?['channel_id'] as String?;
    if (id == null) return;
    acceptVideo = '${extra?['video']}' == '1' || extra?['video'] == true;
    acceptCall.value = id;
  }

  /// Kênh của cuộc gọi máy này đang gọi đi / đang vào / đang trong (CallService cập nhật).
  static String? inCallChannel;

  /// Kênh đang mở trong app (không hiện thông báo cho kênh đó).
  static String? activeChannel;

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<void> init() async {
    if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return _initDesktop();
    if (!supported) return;
    if (Platform.isAndroid) {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_onBackground);
      FirebaseMessaging.onMessage.listen((m) => _handle(m.data, foreground: true));
      await _initLocal();
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) _openFromPayload(launch?.notificationResponse?.payload);
    } else {
      _ios.setMethodCallHandler((call) async {
        if (call.method == 'onTap') {
          final m = call.arguments as Map?;
          final id = m?['channel_id'] as String?;
          if (id != null && id.isNotEmpty) _openFromPayload('${m?['server_id'] ?? ''}|$id|${m?['post_id'] ?? ''}');
        }
      });
      final launched = await _ios.invokeMethod<Map>('launchPayload');
      final id = launched?['channel_id'] as String?;
      if (id != null && id.isNotEmpty) _openFromPayload('${launched?['server_id'] ?? ''}|$id|${launched?['post_id'] ?? ''}');
    }
    FlutterCallkitIncoming.onEvent.listen((e) {
      if (e is CallEventActionCallAccept) _accepted(e.callKitParams.extra?.cast<String, dynamic>());
      if (e is CallEventActionCallDecline) {
        final ch = e.callKitParams.extra?['channel_id'];
        if (ch is String && ch.isNotEmpty) onSystemDecline?.call(ch);
      }
    });
    // App mở lại từ màn hình cuộc gọi đã bấm "Trả lời" lúc app còn tắt.
    for (final c in await FlutterCallkitIncoming.activeCalls()) {
      if (c.isAccepted) _accepted(c.extra?.cast<String, dynamic>());
    }
  }

  static Future<void> _initLocal() async {
    await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) => _openFromPayload(r.payload),
    );
  }

  /// Mã thiết bị gửi cho Mattermost (`PUT /users/sessions/device`), null nếu chưa lấy được.
  static Future<String?> deviceId() async {
    if (!supported) return null;
    try {
      if (Platform.isAndroid) {
        await FirebaseMessaging.instance.requestPermission();
        await _local
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        if (!await FlutterCallkitIncoming.canUseFullScreenIntent()) {
          await FlutterCallkitIncoming.requestFullIntentPermission();
        }
        final t = await FirebaseMessaging.instance.getToken();
        return t == null ? null : 'android_rn-v2:flygo.${t.replaceAll(':', '~')}';
      }
      final apns = await _ios.invokeMethod<String>('apnsToken');
      final String? voip = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      if (apns == null || apns.isEmpty) return null;
      // Mattermost chỉ nhận loại thiết bị của app chính thức; "flygo." đánh dấu app này cho máy chủ đẩy.
      final env = kReleaseMode ? 'apple_rn-v2' : 'apple_rnbeta-v2';
      return '$env:flygo.$apns${voip == null || voip.isEmpty ? '' : '-$voip'}';
    } catch (e) {
      debugPrint('[push] token: $e');
      return null;
    }
  }

  static Stream<String> get tokenRefresh => supported && Platform.isAndroid
      ? FirebaseMessaging.instance.onTokenRefresh.map((t) => 'android_rn-v2:flygo.${t.replaceAll(':', '~')}')
      : const Stream.empty();

  /// Xử lý tin đẩy trên Android (cả khi app đang chạy lẫn khi tắt).
  static Future<void> _handle(Map<String, dynamic> d, {required bool foreground}) async {
    final type = d['type'] as String? ?? 'message';
    final sub = d['sub_type'] as String? ?? '';
    final channel = d['channel_id'] as String? ?? '';
    if (sub == 'calls') {
      // App đang mở thì đã tự đổ chuông qua kết nối trực tiếp.
      // Gọi nhóm (tin đổ chuông của Flygo Chat): máy chủ đẩy thêm video = "1" / "0".
      if (!foreground) await showIncomingCall(channel, d['sender_name'] as String? ?? 'Flygo Chat', video: d['video'] == '1');
      return;
    }
    if (sub == 'calls_ended') {
      // Máy chủ đẩy gửi tin này cho mọi máy của mình khi mình vào cuộc gọi (ended_reason "answered" /
      // "declined"), kể cả máy vừa trả lời: máy này đang trong / đang vào cuộc gọi của kênh đó thì bỏ qua.
      if (channel.isNotEmpty && channel == inCallChannel) return;
      try {
        for (final c in await FlutterCallkitIncoming.activeCalls()) {
          if (c.isAccepted && '${c.extra?['channel_id']}' == channel) return;
        }
      } catch (_) {}
      await FlutterCallkitIncoming.endAllCalls();
      return;
    }
    if (type == 'clear') {
      await _local.cancel(id: channel.hashCode);
      return;
    }
    if (type != 'message') return;
    if (foreground && channel == activeChannel) return;
    final sender = d['sender_name'] as String? ?? '';
    final chName = d['channel_name'] as String? ?? '';
    final title = chName.isNotEmpty && chName != sender ? chName : (sender.isEmpty ? 'Flygo Chat' : sender);
    final body = chName.isNotEmpty && chName != sender && sender.isNotEmpty ? '$sender: ${d['message']}' : '${d['message'] ?? ''}';
    // Tin khẩn cấp (máy chủ đẩy gửi kèm priority = "urgent"): thông báo toàn màn hình (bật màn hình, đè màn hình khoá)
    // như cuộc gọi đến; mở app thì hiện màn hình "Tin khẩn cấp". App đang mở thì đã tự hiện qua kết nối trực tiếp.
    if (d['priority'] == 'urgent') {
      if (foreground) return;
      await _local.show(
        id: '${d['post_id']}'.hashCode,
        title: '🚨 ${tr('TIN KHẨN CẤP')} · $title',
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'urgent',
            tr('Tin khẩn cấp'),
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            fullScreenIntent: true,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT: kêu tới khi người dùng xem
            color: const Color(0xFFE53935),
          ),
        ),
        payload: '${d['server_id'] ?? ''}|$channel|${d['post_id'] ?? ''}',
      );
      return;
    }
    await _local.show(
      id: channel.hashCode,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          r'Tin nhắn',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
      ),
      payload: '${d['server_id'] ?? ''}|$channel|${d['post_id'] ?? ''}',
    );
  }

  // ---------------------------------------------------------------- thông báo trên máy tính
  static bool _desktopReady = false;

  static Future<void> _initDesktop() async {
    try {
      await _local.initialize(
        settings: InitializationSettings(
          macOS: const DarwinInitializationSettings(),
          linux: const LinuxInitializationSettings(defaultActionName: r'Mở'),
          windows: WindowsInitializationSettings(
            appName: 'Flygo Chat',
            appUserModelId: 'vn.flygo.chat',
            guid: 'b6a1c3e2-5f4d-4e7a-9c1b-2d3e4f5a6b7c',
          ),
        ),
        onDidReceiveNotificationResponse: (r) => _openFromPayload(r.payload),
      );
      if (Platform.isMacOS) {
        await _local
            .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, sound: true, badge: true);
      }
      _desktopReady = true;
    } catch (e) {
      debugPrint('[notify] init: $e');
    }
  }

  /// Hiện thông báo tin nhắn trên máy tính (macOS, Linux, Windows).
  static Future<void> showDesktop({required String channelId, required String title, required String body, String postId = ''}) async {
    if (!_desktopReady) return;
    try {
      await _local.show(
        id: channelId.hashCode,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          macOS: DarwinNotificationDetails(presentSound: true),
          linux: LinuxNotificationDetails(category: LinuxNotificationCategory.imReceived),
        ),
        payload: '|$channelId|$postId',
      );
    } catch (e) {
      debugPrint('[notify] show: $e');
    }
  }

  /// Màn hình cuộc gọi đến của hệ điều hành (Android toàn màn hình, iPhone CallKit).
  static Future<void> showIncomingCall(String channelId, String caller, {bool video = false}) async {
    await Ringtones.loadLocal();
    final ring = Ringtones.of(channelId);
    await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
        id: _uuid(),
        nameCaller: caller,
        appName: 'Flygo Chat',
        handle: 'Flygo Chat',
        type: video ? 1 : 0,
        duration: 45000,
        extra: {'channel_id': channelId, 'video': video ? '1' : '0'},
        android: AndroidParams(
          ringtonePath: ring ?? 'system_ringtone_default',
          textAccept: r'Trả lời',
          textDecline: r'Từ chối',
          isCustomNotification: true,
          isShowLogo: false,
          backgroundColor: '#0A66D9',
          actionColor: '#1E7BFF',
          incomingCallNotificationChannelName: r'Cuộc gọi đến',
          missedCallNotificationChannelName: r'Cuộc gọi nhỡ',
          isShowFullLockedScreen: true,
        ),
        ios: IOSParams(
            handleType: 'generic',
            supportsVideo: true,
            maximumCallGroups: 1,
            maximumCallsPerCallGroup: 1,
            ringtonePath: ring == null ? 'system_ringtone_default' : '$ring.caf'),
      ));
  }

  static Future<void> endCalls() => supported ? FlutterCallkitIncoming.endAllCalls() : Future.value();

  static String _uuid() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0');
    final h = (DateTime.now().millisecondsSinceEpoch ^ r.hashCode).toRadixString(16).padLeft(20, '0');
    final s = (h + r).substring(0, 32);
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-4${s.substring(13, 16)}-a${s.substring(17, 20)}-${s.substring(20, 32)}';
  }
}

@pragma('vm:entry-point')
Future<void> _onBackground(RemoteMessage m) async {
  await Firebase.initializeApp();
  await PushService._initLocal();
  await PushService._handle(m.data, foreground: false);
}
