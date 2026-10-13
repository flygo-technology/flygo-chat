import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config.dart';

class ServerEntry {
  final String url;
  final String name;
  ServerEntry(this.url, this.name);
  Map<String, dynamic> toJson() => {'url': url, 'name': name};
  String get host => Uri.parse(url).host;
}

/// Danh sách máy chủ đã thêm và máy chủ đang dùng (lưu trên máy).
class ServerList {
  static List<ServerEntry> items = [ServerEntry(kDefaultServer, 'Flygo')];
  static String current = kDefaultServer;

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
      items = [for (final e in j['items'] as List) ServerEntry(e['url'] as String, e['name'] as String)];
      if (!items.any((e) => e.url == kDefaultServer)) items.insert(0, ServerEntry(kDefaultServer, 'Flygo'));
      current = j['current'] as String? ?? kDefaultServer;
      if (!items.any((e) => e.url == current)) current = kDefaultServer;
    } catch (_) {}
    kServerUrl = current;
  }

  static Future<void> save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode({'current': current, 'items': [for (final e in items) e.toJson()]}));
  }

  static Future<void> use(String url) async {
    current = url;
    kServerUrl = url;
    await save();
  }

  static Future<void> add(String url, String name) async {
    items.removeWhere((e) => e.url == url);
    items.add(ServerEntry(url, name));
    await use(url);
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
