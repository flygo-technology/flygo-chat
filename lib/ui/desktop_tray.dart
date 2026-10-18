import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../data/servers.dart';
import '../i18n/i18n.dart';

/// Windows: chạy ẩn dưới khay hệ thống để vẫn nhận tin nhắn / cuộc gọi khi đã đóng cửa sổ.
/// Bấm X thì cửa sổ ẩn đi, biểu tượng ở khay giữ app chạy (bấm để mở lại, chuột phải → Thoát).
/// "Mở cùng Windows" ghi app vào HKCU\...\Run với `--hidden` (khởi động thẳng xuống khay).
/// Phần native: windows/runner/flutter_window.cpp (kênh "flygo/tray").
class DesktopTray {
  static const _ch = MethodChannel('flygo/tray');
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runName = 'Flygo Chat';

  /// Chỉ cửa sổ chính (không phải cửa sổ riêng một cuộc trò chuyện / một máy chủ).
  static bool get supported => !kIsWeb && Platform.isWindows && kWindowChannel == null && ServerList.pinned == null;

  /// Đóng cửa sổ thì ẩn xuống khay (mặc định bật).
  static final closeToTray = ValueNotifier<bool>(true);

  /// Tự mở (ẩn dưới khay) khi đăng nhập Windows (mặc định bật).
  static final autostart = ValueNotifier<bool>(true);
  static bool _hinted = false;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}desktop.json');
  }

  static Future<void> init() async {
    if (!supported) return;
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map;
        closeToTray.value = j['close_to_tray'] as bool? ?? true;
        autostart.value = j['autostart'] as bool? ?? true;
        _hinted = j['hinted'] == true;
      }
    } catch (_) {}
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'hinted') {
        _hinted = true;
        await _save();
      }
    });
    appLanguage.addListener(_apply);
    await _apply();
    await _applyAutostart();
  }

  static Future<void> setCloseToTray(bool v) async {
    closeToTray.value = v;
    await _save();
    await _apply();
  }

  static Future<void> setAutostart(bool v) async {
    autostart.value = v;
    await _save();
    await _applyAutostart();
  }

  /// Hiện cửa sổ chính (đang ẩn dưới khay hoặc thu nhỏ) lên trước.
  static Future<void> show() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('show');
    } catch (_) {}
  }

  static Future<void> _apply() async {
    try {
      await _ch.invokeMethod('config', {
        'enabled': closeToTray.value,
        'tooltip': 'Flygo Chat',
        'open': tr('Mở Flygo Chat'),
        'quit': tr('Thoát'),
        // Lần đầu ẩn xuống khay: báo cho người dùng biết app vẫn chạy.
        'hint': _hinted ? '' : tr('Flygo Chat vẫn chạy dưới khay hệ thống để nhận tin nhắn và cuộc gọi.'),
      });
    } catch (e) {
      debugPrint('[tray] $e');
    }
  }

  static Future<void> _applyAutostart() async {
    // Bản chạy thử (flutter run) không ghi vào danh sách khởi động.
    if (!kReleaseMode) return;
    final args = autostart.value
        ? ['add', _runKey, '/v', _runName, '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --hidden', '/f']
        : ['delete', _runKey, '/v', _runName, '/f'];
    try {
      await Process.run('reg', args);
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(
          jsonEncode({'close_to_tray': closeToTray.value, 'autostart': autostart.value, 'hinted': _hinted}));
    } catch (_) {}
  }
}
