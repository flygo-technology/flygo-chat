import 'dart:convert';
import 'dart:io';

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

/// Danh sách máy chủ đã thêm và máy chủ đang dùng (lưu trên máy).
class ServerList {
  static List<ServerEntry> items = [ServerEntry(kDefaultServer, 'Flygo')];
  static String current = kDefaultServer;

  /// Máy được cấu hình sẵn cho một công ty (servers.json có "no_default": true, vd. máy của một công ty):
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
