import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
const kUserAgent = 'FlygoChat/1.0 (Flutter)';

/// Máy chủ đẩy (sổ thiết bị để dừng đổ chuông máy khác, TURN cho cuộc gọi, lưu sticker): công ty có
/// trạm đẩy riêng thì dùng trạm đó (DND: push.dnd-global.com trên hn-maychu), còn lại dùng của Flygo.
const _pushByHost = {'chat.dnd-global.com': 'https://push.dnd-global.com'};
String pushUrlFor(String server) => _pushByHost[Uri.tryParse(server)?.host.toLowerCase()] ?? 'https://push.flygo.vn';
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
