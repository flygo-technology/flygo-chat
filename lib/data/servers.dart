import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';

class ServerEntry {
  final String url;
  final String name;
  /// Mã máy chủ Mattermost (DiagnosticId), dùng để biết thông báo đẩy đến từ máy chủ nào.
  String serverId;
  ServerEntry(this.url, this.name, [this.serverId = '']);
  Map<String, dynamic> toJson() => {'url': url, 'name': name, if (serverId.isNotEmpty) 'server_id': serverId};
  String get host => Uri.parse(url).host;
}

/// Máy chủ chat tìm được theo tên miền email ([ServerList.discover]).
class FoundServer {
  final String url;
  final String name;
  /// Máy chủ bật đăng nhập Google / đăng nhập bằng mật khẩu.
  final bool google, password;
  const FoundServer(this.url, this.name, {required this.google, required this.password});
}

/// Danh sách máy chủ đã thêm và máy chủ đang dùng (lưu trên máy).
class ServerList {
  static List<ServerEntry> items = [ServerEntry(kDefaultServer, 'Flygo')];
  static String current = kDefaultServer;

  /// Máy được cấu hình sẵn cho một công ty (servers.json có "no_default": true):
  /// không tự thêm máy chủ Flygo mặc định vào danh sách.
  static bool noDefault = false;

  /// Máy tính: cửa sổ mở riêng cho một máy chủ (`--server=<url>`), không đổi máy chủ của cửa sổ chính.
  static String? pinned;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}servers.json');
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      items = [
        for (final e in j['items'] as List) ServerEntry(e['url'] as String, e['name'] as String, e['server_id'] as String? ?? ''),
      ];
      noDefault = j['no_default'] == true && items.isNotEmpty;
      if (!noDefault && !items.any((e) => e.url == kDefaultServer)) items.insert(0, ServerEntry(kDefaultServer, 'Flygo'));
      final first = items.first.url;
      current = j['current'] as String? ?? first;
      if (!items.any((e) => e.url == current)) current = noDefault ? first : kDefaultServer;
    } catch (_) {}
    if (pinned != null) current = pinned!;
    kServerUrl = current;
    for (final e in items) {
      discoverPush(e.url);
    }
  }

  static Future<void> save() async {
    final f = await _file();
    // Cửa sổ riêng của một máy chủ không ghi đè máy chủ đang dùng của cửa sổ chính.
    var cur = current;
    if (pinned != null) {
      try {
        cur = (jsonDecode(await f.readAsString()) as Map)['current'] as String? ?? kDefaultServer;
      } catch (_) {
        cur = kDefaultServer;
      }
    }
    await f.writeAsString(jsonEncode({'current': cur, if (noDefault) 'no_default': true, 'items': [for (final e in items) e.toJson()]}));
  }

  static Future<void> setServerId(String url, String id) async {
    final e = items.where((e) => e.url == url).firstOrNull;
    if (e == null || id.isEmpty || e.serverId == id) return;
    e.serverId = id;
    await save();
  }

  /// Địa chỉ máy chủ có mã [serverId] (thông báo đẩy), null nếu không biết.
  static String? urlForServerId(String serverId) =>
      serverId.isEmpty ? null : items.where((e) => e.serverId == serverId).firstOrNull?.url;

  static Future<void> use(String url) async {
    current = url;
    kServerUrl = url;
    await save();
  }

  static Future<void> add(String url, String name, {bool select = true}) async {
    items.removeWhere((e) => e.url == url);
    items.add(ServerEntry(url, name));
    select ? await use(url) : await save();
  }

  static Future<void> remove(String url) async {
    if (url == kDefaultServer) return;
    items.removeWhere((e) => e.url == url);
    if (current == url) current = kDefaultServer;
    kServerUrl = current;
    await save();
  }

  static ServerEntry get currentEntry => items.firstWhere((e) => e.url == current, orElse: () => items.first);

  /// Tên miền của một email (chữ thường), rỗng nếu không phải email.
  static String emailDomain(String email) {
    final at = email.trim().lastIndexOf('@');
    final d = at < 0 ? '' : email.trim().substring(at + 1).toLowerCase();
    return RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$').hasMatch(d) ? d : '';
  }

  /// Tìm máy chủ chat của công ty theo tên miền email, không cần biết trước địa chỉ máy chủ:
  /// 1. công ty tự khai báo ở `https://<tên miền>/.well-known/flygo-chat.json` (`{"server": "https://…"}`);
  /// 2. quy ước `https://chat.<tên miền>`.
  /// Chỉ nhận địa chỉ trả lời đúng kiểu máy chủ Mattermost. Không tìm thấy thì trả null.
  static Future<FoundServer?> discover(String email) async {
    final domain = emailDomain(email);
    if (domain.isEmpty) return null;
    const headers = {'User-Agent': kUserAgent};
    Future<String?> declared() async {
      try {
        final r = await http.get(Uri.parse('https://$domain/.well-known/flygo-chat.json'), headers: headers).timeout(const Duration(seconds: 5));
        final s = r.statusCode == 200 ? (jsonDecode(r.body) as Map)['server'] : null;
        return s is String && s.isNotEmpty ? normalize(s) : null;
      } catch (_) {
        return null;
      }
    }

    Future<FoundServer?> probe(String url) async {
      try {
        final r = await http.get(Uri.parse('$url/api/v4/config/client?format=old'), headers: headers).timeout(const Duration(seconds: 8));
        if (r.statusCode != 200) return null;
        final j = jsonDecode(r.body) as Map;
        if (!j.containsKey('EnableSignUpWithGoogle')) return null;
        final known = items.where((e) => e.url == url).firstOrNull?.name;
        return FoundServer(url, known ?? domain,
            google: j['EnableSignUpWithGoogle'] == 'true',
            password: j['EnableSignInWithEmail'] == 'true' || j['EnableSignInWithUsername'] == 'true');
      } catch (_) {
        return null;
      }
    }

    // Dò song song: địa chỉ công ty tự khai báo được ưu tiên.
    final conv = probe('https://chat.$domain');
    final d = await declared();
    if (d != null && d != 'https://chat.$domain') {
      final f = await probe(d);
      if (f != null) return f;
    }
    return conv;
  }

  /// Chuẩn hóa địa chỉ người dùng gõ: thêm https://, bỏ dấu / cuối.
  static String normalize(String input) {
    var u = input.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
