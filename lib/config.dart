import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const kDefaultServer = 'https://chat.flygo.vn';

/// Máy chủ đang dùng; đổi khi người dùng chọn máy chủ khác trong tab Bạn.
String kServerUrl = kDefaultServer;

/// Khóa phân biệt dữ liệu theo máy chủ (máy chủ mặc định giữ khóa cũ 'main').
String get serverKey => serverKeyOf(kServerUrl);

/// Tên khóa (phiên đăng nhập, bộ nhớ đệm) của một máy chủ.
String serverKeyOf(String url) =>
    url == kDefaultServer ? 'main' : Uri.parse(url).host.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
const kTeamName = 'team';

/// Máy tính: cửa sổ phụ mở riêng một cuộc trò chuyện (chạy app với `--chat=<id kênh>`).
String? kWindowChannel;
/// Cửa sổ riêng của cột trợ lý AI (`--ai=<nhóm>[#<luồng>]`): kWindowChannel là nhóm, [kWindowAiThread] là luồng (nếu có).
bool kWindowAi = false;
String? kWindowAiThread;
/// Cửa sổ riêng của cuộc họp (`--call=<kênh>`, kèm `--call-video` / `--call-meeting`): kWindowChannel là kênh họp.
bool kWindowCall = false;
bool kWindowCallVideo = false, kWindowCallMeeting = false;
const kUserAgent = 'FlygoChat/1.0 (Flutter)';

/// Trạm đẩy chung của Flygo (sổ thiết bị để dừng đổ chuông máy khác, TURN cho cuộc gọi, lưu sticker, A2A).
const kFlygoPush = 'https://push.flygo.vn';

/// Trạm đẩy của từng máy chủ chat: công ty tự dựng trạm đẩy ở `push.<tên miền>` (vd. chat.congty.vn →
/// push.congty.vn) thì dùng trạm đó, không có thì dùng [kFlygoPush]. Kết quả dò ([discoverPush]) giữ theo tên máy.
final _pushByHost = <String, String>{};
final _pushProbe = <String, Future<void>>{};

String pushUrlFor(String server) => _pushByHost[Uri.tryParse(server)?.host.toLowerCase()] ?? kFlygoPush;

/// Dò trạm đẩy riêng của [server] (một lần mỗi lần chạy app; lỗi mạng thì lần sau dò lại).
Future<void> discoverPush(String server) {
  final host = Uri.tryParse(server)?.host.toLowerCase() ?? '';
  if (host.isEmpty || InternetAddress.tryParse(host) != null || !host.contains('.')) return Future.value();
  final labels = host.split('.');
  final candidate = 'https://push.${(labels.length > 2 ? labels.skip(1) : labels).join('.')}';
  if (candidate == kFlygoPush) return Future.value();
  return _pushProbe[host] ??= () async {
    try {
      final r = await http
          .get(Uri.parse('$candidate/health'), headers: {'User-Agent': kUserAgent})
          .timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && r.body.contains('"OK"')) _pushByHost[host] = candidate;
    } catch (_) {
      _pushProbe.remove(host);
    }
  }();
}

String get kPushUrl => pushUrlFor(kServerUrl);
const kMobileScheme = 'flygochat';

/// Bảng màu theo phong cách WhatsApp.
class WaColors {
  static const teal = Color(0xFF0A66D9);
  static const tealDark = Color(0xFF0B4A9E);
  static const green = Color(0xFF1E7BFF);
  static const chatBg = Color(0xFFE8EEF6);
  static const outBubble = Color(0xFFD6E9FF);
  static const inBubble = Colors.white;
  static const tickBlue = Color(0xFF53BDEB);
  static const subtle = Color(0xFF667781);
  static const divider = Color(0xFFE9EDEF);
  static const panelBg = Color(0xFFF0F2F5);

  // Màu tên người gửi trong nhóm, giống WhatsApp.
  static const senderColors = [
    Color(0xFF1F7AEC), Color(0xFFE542A3), Color(0xFF02A698), Color(0xFFD3396D),
    Color(0xFF7F66FF), Color(0xFFFA6533), Color(0xFF06CF9C), Color(0xFFC4532D),
  ];
  static Color sender(String userId) =>
      senderColors[userId.codeUnits.fold<int>(0, (a, b) => a + b) % senderColors.length];
}

/// Bản máy tính (macOS, Linux, Windows).
bool get isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

/// Trang chính sách quyền riêng tư và hỗ trợ (App Store yêu cầu).
const kPrivacyUrl = 'https://chat.flygo.vn/static/plugins/flygo-update/privacy.html';
const kSupportUrl = 'https://chat.flygo.vn/static/plugins/flygo-update/support.html';
