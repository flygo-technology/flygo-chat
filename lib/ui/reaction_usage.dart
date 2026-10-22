import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'common.dart' show quickReactions;

/// Thanh cảm xúc nhanh (nhấn giữ / nháy phải vào tin) theo thói quen trên máy này, tối đa [max] cảm xúc:
/// - cảm xúc mới dùng lần đầu (chưa có trên thanh) hiện ngay lên đầu;
/// - cảm xúc dùng nhiều dần nhảy lên trước các cảm xúc dùng ít hơn;
/// - đầy thanh thì bỏ cảm xúc ở cuối.
class ReactionUsage {
  static const max = 8;
  static List<(String, int)> _list = [for (final e in quickReactions) (e, 0)];
  static bool _loaded = false;

  static List<String> get quick => [for (final (e, _) in _list) e];

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}reactions.json');
  }

  static Future<void> load() async {
    if (_loaded || kIsWeb) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as List;
      final l = [for (final e in j) ((e as Map)['e'] as String, (e['n'] as num).toInt())];
      if (l.isNotEmpty) _list = l.take(max).toList();
    } catch (_) {}
  }

  /// Vừa thả cảm xúc [name].
  static void used(String name) {
    final i = _list.indexWhere((x) => x.$1 == name);
    if (i < 0) {
      _list.insert(0, (name, 1));
      if (_list.length > max) _list.removeLast();
    } else {
      var j = i;
      final n = _list[i].$2 + 1;
      _list.removeAt(i);
      // Nhảy lên trước các cảm xúc dùng ít hơn.
      while (j > 0 && _list[j - 1].$2 < n) {
        j--;
      }
      _list.insert(j, (name, n));
    }
    _save();
  }

  static Future<void> _save() async {
    if (kIsWeb) return;
    try {
      await (await _file()).writeAsString(jsonEncode([for (final (e, n) in _list) {'e': e, 'n': n}]));
    } catch (_) {}
  }
}
