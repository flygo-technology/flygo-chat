import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'en.dart';
import 'ja.dart';
import 'ko.dart';
import 'th.dart';
import 'zh.dart';

/// Ngôn ngữ giao diện. Câu gốc viết bằng tiếng Việt ngay trong mã; các ngôn ngữ
/// khác tra theo câu gốc. Chỗ trống {0}, {1}... thay bằng tham số.
const appLanguages = {
  'vi': 'Tiếng Việt',
  'en': 'English',
  'ko': '한국어',
  'ja': '日本語',
  'th': 'ไทย',
  'zh': '中文',
};

final appLanguage = ValueNotifier<String>('vi');

const Map<String, Map<String, String>> _tables = {'en': en, 'ko': ko, 'ja': ja, 'th': th, 'zh': zh};

String tr(String vi, [List<Object?> args = const []]) {
  var s = appLanguage.value == 'vi' ? vi : (_tables[appLanguage.value]?[vi] ?? vi);
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}

Future<File> _prefs() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return File('${dir.path}${Platform.pathSeparator}prefs.json');
}

Future<void> loadLanguage() async {
  try {
    final f = await _prefs();
    if (await f.exists()) {
      final lang = (jsonDecode(await f.readAsString()) as Map)['language'] as String?;
      if (lang != null && appLanguages.containsKey(lang)) appLanguage.value = lang;
    }
  } catch (_) {}
}

Future<void> setLanguage(String lang) async {
  appLanguage.value = lang;
  try {
    final f = await _prefs();
    await f.writeAsString(jsonEncode({'language': lang}));
  } catch (_) {}
}
