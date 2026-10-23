import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Máy chủ đang dùng; đổi khi người dùng chọn máy chủ khác trong tab Bạn. App không có máy chủ mặc định: rỗng khi chưa
/// đăng nhập máy chủ nào (màn đăng nhập tìm máy chủ theo tên miền email).
String kServerUrl = '';

/// Máy chủ giữ khóa dữ liệu cũ 'main' (bản cũ có một máy chủ mặc định, phiên đăng nhập và bộ nhớ đệm của nó lưu dưới
/// khóa 'main'). Ghi trong servers.json ("main_key") để người đang dùng không bị đăng xuất.
String legacyMainServer = '';

/// Khóa phân biệt dữ liệu theo máy chủ.
String get serverKey => serverKeyOf(kServerUrl);

/// Tên khóa (phiên đăng nhập, bộ nhớ đệm) của một máy chủ.
String serverKeyOf(String url) => url.isEmpty
    ? 'none'
    : url == legacyMainServer
        ? 'main'
        : Uri.parse(url).host.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
const kTeamName = 'team';

/// Máy tính: cửa sổ phụ mở riêng một cuộc trò chuyện (chạy app với `--chat=<id kênh>`).
String? kWindowChannel;
/// Cửa sổ riêng của cột trợ lý AI (`--ai=<nhóm>[#<luồng>]`): kWindowChannel là nhóm, [kWindowAiThread] là luồng (nếu có).
bool kWindowAi = false;
String? kWindowAiThread;
/// Cửa sổ riêng của cuộc họp (`--call=<kênh>`, kèm `--call-video` / `--call-meeting`): kWindowChannel là kênh họp.
bool kWindowCall = false;
/// Cửa sổ riêng của một luồng (`--thread=<kênh>#<tin gốc>`): kWindowChannel là kênh, [kWindowThread] là tin gốc.
String? kWindowThread;
/// Cửa sổ "Thêm máy chủ mới" (`--add-server`, máy tính): mở thẳng màn đăng nhập, máy chủ theo email người dùng nhập.
bool kWindowAddServer = false;
bool kWindowCallVideo = false, kWindowCallMeeting = false;
const kUserAgent = 'FlygoChat/1.0 (Flutter)';

/// Trạm của từng máy chủ chat (đẩy thông báo, sổ thiết bị, TURN, sticker, A2A cho bot, phòng họp, dịch AI, QR…):
/// luôn là `push.<tên miền>` của chính máy chủ đó (chat.congty.vn → push.congty.vn). Không bao giờ mượn trạm của máy chủ
/// khác: máy chủ chưa dựng trạm thì các tính năng cần trạm không dùng được, chat vẫn bình thường.
final _pushByHost = <String, String>{};
final _pushProbe = <String, Future<void>>{};

String _pushCandidate(String host) {
  if (host.isEmpty || InternetAddress.tryParse(host) != null || !host.contains('.')) return '';
  final labels = host.split('.');
  return 'https://push.${(labels.length > 2 ? labels.skip(1) : labels).join('.')}';
}

/// Địa chỉ trạm của [server] (rỗng nếu máy chủ là IP / tên nội bộ, không có trạm).
String pushUrlFor(String server) {
  final host = Uri.tryParse(server)?.host.toLowerCase() ?? '';
  return _pushByHost[host] ?? _pushCandidate(host);
}

/// Dò trạm đẩy riêng của [server] (một lần mỗi lần chạy app; lỗi mạng thì lần sau dò lại).
Future<void> discoverPush(String server) {
  final host = Uri.tryParse(server)?.host.toLowerCase() ?? '';
  final candidate = _pushCandidate(host);
  if (candidate.isEmpty) return Future.value();
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
/// Tệp tĩnh của máy chủ đang dùng (Mattermost phục vụ `client/plugins/<tên>/` ở `/static/plugins/<tên>/`):
/// flygo-update (bản cập nhật, âm thanh, nhạc, sticker, mô hình giọng nói, trang chính sách), flygo-agent (runner).
/// Đăng nhập máy chủ nào thì dùng tệp của máy chủ đó, không mượn máy chủ khác.
String staticBase(String plugin, [String? server]) => '${server ?? kServerUrl}/static/plugins/$plugin';
String get kPrivacyUrl => '${staticBase('flygo-update')}/privacy.html';
String get kSupportUrl => '${staticBase('flygo-update')}/support.html';

/// Dịch vụ nhận giọng nói (Whisper) của máy chủ: `stt.<tên miền>` (chat.congty.vn → stt.congty.vn).
String get kSttUrl {
  final host = Uri.tryParse(kServerUrl)?.host.toLowerCase() ?? '';
  final labels = host.split('.');
  return labels.length < 2 ? '' : 'https://stt.${(labels.length > 2 ? labels.skip(1) : labels).join('.')}';
}
