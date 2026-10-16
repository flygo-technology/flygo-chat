import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';

/// Số tin chưa đọc trên biểu tượng app (máy tính): macOS hiện badge ở Dock, Windows hiện chấm đỏ có số
/// đè lên biểu tượng ở thanh taskbar. Linux chưa có cách chung nên bỏ qua.
class AppBadge {
  static const _ch = MethodChannel('flygo/badge');
  static AppState? _app;
  static Timer? _debounce;
  static int _shown = -1;

  static bool get _supported => !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// Theo dõi [app]: mỗi lần trạng thái đổi thì tính lại (gộp các lần đổi liên tiếp trong 400 ms).
  static void attach(AppState app) {
    if (!_supported) return;
    _app?.removeListener(_schedule);
    _app = app;
    app.addListener(_schedule);
    _schedule();
  }

  static void detach(AppState app) {
    if (_app != app) return;
    app.removeListener(_schedule);
    _app = null;
    _debounce?.cancel();
    _set(0);
  }

  static void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final app = _app;
      if (app != null) _set(count(app));
    });
  }

  /// Tổng tin chưa đọc như số trên danh sách chat; chat đã tắt thông báo chỉ tính tin nhắc tên mình.
  static int count(AppState app) {
    var n = 0;
    for (final s in app.chats) {
      n += app.isMuted(s.channel.id) ? s.mentions : s.unread;
    }
    return n;
  }

  static Future<void> _set(int n) async {
    if (n == _shown) return;
    _shown = n;
    try {
      if (Platform.isMacOS) {
        await _ch.invokeMethod('set', {'count': n});
      } else if (Platform.isWindows) {
        await _ch.invokeMethod('set', {'count': n, 'rgba': n > 0 ? await _render(n) : null, 'size': _size});
      }
    } catch (_) {
      _shown = -1;
    }
  }

  static const _size = 32;

  /// Chấm đỏ có số (32×32, RGBA) cho biểu tượng phủ ở taskbar Windows.
  static Future<Uint8List> _render(int n) async {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final s = _size.toDouble();
    canvas.drawCircle(ui.Offset(s / 2, s / 2), s / 2, ui.Paint()..color = const ui.Color(0xFFE53935));
    final label = n > 99 ? '99+' : '$n';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
            color: const ui.Color(0xFFFFFFFF),
            fontWeight: FontWeight.w700,
            fontSize: label.length == 1 ? 22 : (label.length == 2 ? 18 : 13)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, ui.Offset((s - tp.width) / 2, (s - tp.height) / 2));
    final img = await rec.endRecording().toImage(_size, _size);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    return data!.buffer.asUint8List();
  }
}
