import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../ui/open_file.dart';

/// Bản cập nhật trên máy chủ (version.json).
class UpdateInfo {
  final int build;
  final String version;
  final String notes;
  final String? file; // tên tệp cho nền tảng đang chạy
  UpdateInfo(this.build, this.version, this.notes, this.file);
  String get label => '$version ($build)';
}

/// Tự cập nhật (Android, Windows, macOS, Linux). iPhone cập nhật qua TestFlight.
/// Bản mới đặt ở [base]: version.json + tệp cài từng nền tảng.
class Updater {
  static const base = 'https://chat.flygo.vn/static/plugins/flygo-update';

  /// Có bản mới hơn bản đang chạy (null nếu không có).
  static final available = ValueNotifier<UpdateInfo?>(null);

  /// Tiến độ tải (0..1), null khi không tải.
  static final progress = ValueNotifier<double?>(null);

  static int currentBuild = 0;
  static String currentVersion = '';
  static Timer? _timer;

  static String? get _platformKey => kIsWeb
      ? null
      : Platform.isAndroid
          ? 'android'
          : Platform.isWindows
              ? 'windows'
              : Platform.isMacOS
                  ? 'macos'
                  : Platform.isLinux
                      ? 'linux'
                      : null;

  static Future<void> start() async {
    if (_platformKey == null) return;
    final info = await PackageInfo.fromPlatform();
    currentBuild = int.tryParse(info.buildNumber) ?? 0;
    currentVersion = info.version;
    await check();
    _timer ??= Timer.periodic(const Duration(hours: 3), (_) => check());
  }

  static Future<UpdateInfo?> check() async {
    final key = _platformKey;
    if (key == null) return null;
    try {
      final r = await http.get(Uri.parse('$base/version.json?t=${DateTime.now().millisecondsSinceEpoch}'));
      if (r.statusCode != 200) return null;
      final j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      // Mỗi nền tảng có số bản riêng (builds); bản cũ của app chỉ đọc "build" chung.
      final build = ((j['builds'] as Map?)?[key] as num?)?.toInt() ?? (j['build'] as num?)?.toInt() ?? 0;
      final file = ((j['files'] as Map?)?[key]) as String?;
      final u = UpdateInfo(build, j['version'] as String? ?? '', j['notes'] as String? ?? '', file);
      available.value = build > currentBuild && file != null ? u : null;
      return available.value;
    } catch (e) {
      debugPrint('[update] check: $e');
      return null;
    }
  }

  static Future<File> _download(UpdateInfo u) async {
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}${Platform.pathSeparator}${u.file}');
    final req = http.Request('GET', Uri.parse('$base/${u.file}'));
    final res = await http.Client().send(req);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = out.openWrite();
    progress.value = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress.value = got / total;
    }
    await sink.close();
    return out;
  }

  /// Tải và cài bản mới. Máy tính: chạy đoạn lệnh chờ app thoát, thay tệp, mở lại app.
  static Future<void> install() async {
    final u = available.value;
    if (u == null) return;
    try {
      final f = await _download(u);
      progress.value = null;
      if (Platform.isAndroid) {
        // Mở trình cài đặt của Android (lần đầu hỏi cho phép cài ứng dụng từ Flygo Chat).
        await openLocalFile(f.path, mime: 'application/vnd.android.package-archive');
        return;
      }
      final exe = Platform.resolvedExecutable;
      final tmp = await getTemporaryDirectory();
      if (Platform.isWindows) {
        final dir = File(exe).parent.path;
        final unpack = '${tmp.path}\\flygo-update-${u.build}';
        final bat = File('${tmp.path}\\flygo-update.bat');
        await bat.writeAsString([
          '@echo off',
          'timeout /t 2 /nobreak >nul',
          ':wait',
          'tasklist /FI "PID eq $pid" | find "$pid" >nul && (timeout /t 1 /nobreak >nul & goto wait)',
          'powershell -NoProfile -Command "Expand-Archive -Force -LiteralPath \'${f.path}\' -DestinationPath \'$unpack\'"',
          'robocopy "$unpack" "$dir" /E /NFL /NDL /NJH /NJS >nul',
          'start "" "$exe"',
        ].join('\r\n'));
        await Process.start('cmd', ['/c', bat.path], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        // exe = /Applications/Flygo Chat.app/Contents/MacOS/Flygo Chat → thay cả gói .app.
        final app = File(exe).parent.parent.parent.path;
        final sh = File('${tmp.path}/flygo-update.sh');
        final work = '${tmp.path}/flygo-update-new';
        await sh.writeAsString('''#!/bin/sh
while kill -0 $pid 2>/dev/null; do sleep 1; done
rm -rf "$work" && mkdir -p "$work"
ditto -x -k "${f.path}" "$work" || exit 1
rm -rf "$app" && ditto "$work/Flygo Chat.app" "$app"
open "$app"
''');
        await Process.start('/bin/sh', [sh.path], mode: ProcessStartMode.detached);
      } else {
        // Linux: thư mục cài (/opt/flygo-chat) thuộc root → hỏi mật khẩu qua pkexec nếu cần.
        final dir = File(exe).parent.path;
        final sh = File('${tmp.path}/flygo-update.sh');
        await sh.writeAsString('''#!/bin/sh
while kill -0 $pid 2>/dev/null; do sleep 1; done
rm -rf "${tmp.path}/flygo-update-new" && mkdir -p "${tmp.path}/flygo-update-new"
tar -xzf "${f.path}" -C "${tmp.path}/flygo-update-new" || exit 1
SRC=\$(find "${tmp.path}/flygo-update-new" -maxdepth 2 -name flygo-chat -type f -exec dirname {} \\; | head -1)
if [ -w "$dir" ]; then cp -r "\$SRC"/. "$dir"/; else pkexec cp -r "\$SRC"/. "$dir"/; fi
nohup "$exe" >/dev/null 2>&1 &
''');
        await Process.start('/bin/sh', [sh.path], mode: ProcessStartMode.detached);
      }
      exit(0);
    } catch (e) {
      progress.value = null;
      debugPrint('[update] install: $e');
      rethrow;
    }
  }
}
