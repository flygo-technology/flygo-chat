import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../i18n/i18n.dart';
import 'theme.dart';

/// Chụp màn hình (máy tính): ẩn cửa sổ, chụp màn hình đang có con trỏ chuột, biến cửa sổ thành lớp phủ
/// toàn màn hình (không viền, nằm trên cùng) để kéo chọn vùng, vẽ / ghi chú, rồi trả về ảnh PNG để đính kèm.
/// Phần native (kênh "flygo/screenshot"): macos/Runner/MainFlutterWindow.swift, windows/runner/flutter_window.cpp,
/// linux/runner/my_application.cc.
class ScreenGrab {
  static const _ch = MethodChannel('flygo/screenshot');
  static bool get supported => isDesktop;
  static bool _busy = false;

  /// Trả về đường dẫn ảnh PNG đã chụp; null khi hủy hoặc lỗi (lỗi thì đã báo cho người dùng).
  static Future<String?> take(BuildContext context) async {
    if (!supported || _busy) return null;
    _busy = true;
    final nav = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var hidden = false; // cửa sổ đã ẩn / đã thành lớp phủ: phải trả lại như cũ
    String? error;
    try {
      // macOS: cần quyền "Ghi màn hình" (không có quyền thì chỉ chụp được hình nền).
      if (Platform.isMacOS && await _ch.invokeMethod<bool>('permission') != true) {
        await _ch.invokeMethod('requestPermission');
        if (context.mounted) await _askPermission(context);
        return null;
      }
      await _ch.invokeMethod('hide');
      hidden = true;
      // Chờ cửa sổ ẩn hẳn (hiệu ứng ẩn của hệ điều hành) rồi mới chụp.
      await Future<void>.delayed(const Duration(milliseconds: 320));
      final image = await _capture();
      if (image == null) {
        error = Platform.isLinux
            ? tr('Không chụp được màn hình. Trên Linux cần xdg-desktop-portal hoặc một công cụ chụp (gnome-screenshot, grim, spectacle).')
            : tr('Không chụp được màn hình.');
        return null;
      }
      final done = nav.push(PageRouteBuilder<String>(
        opaque: true,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => ScreenshotOverlay(image: image),
      ));
      // Vẽ lớp phủ xong rồi mới hiện cửa sổ toàn màn hình (cửa sổ đang ẩn có thể không vẽ: không chờ mãi).
      await WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 150), onTimeout: () {});
      await _ch.invokeMethod('overlay');
      final path = await done;
      image.dispose();
      return path;
    } on PlatformException catch (e) {
      debugPrint('[screenshot] ${e.code}: ${e.message}');
      error = e.code == 'fullscreen'
          ? tr('Hãy thoát chế độ toàn màn hình của cửa sổ rồi chụp lại.')
          : tr('Không chụp được màn hình.');
      return null;
    } catch (e) {
      debugPrint('[screenshot] $e');
      error = tr('Không chụp được màn hình.');
      return null;
    } finally {
      if (hidden) {
        try {
          await _ch.invokeMethod('restore');
        } catch (_) {}
      }
      _busy = false;
      if (error != null) messenger?.showSnackBar(toast(Text(error)));
    }
  }

  static Future<void> _askPermission(BuildContext context) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Cần quyền ghi màn hình')),
          content: Text(tr(
              'Hãy bật Flygo Chat trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Ghi màn hình, sau đó thoát và mở lại ứng dụng.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Để sau'))),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                launchUrl(Uri.parse('x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'));
              },
              child: Text(tr('Mở Cài đặt hệ thống')),
            ),
          ],
        ),
      );

  static Future<ui.Image?> _capture() async {
    try {
      final r = await _ch.invokeMapMethod<String, Object?>('capture');
      if (r != null) return await _fromPixels(r);
    } on PlatformException {
      // Linux Wayland không chụp thẳng được: thử cách khác bên dưới. Máy khác: báo lỗi.
      if (!Platform.isLinux) rethrow;
    }
    if (!Platform.isLinux) return null;
    final png = await _linuxPortal() ?? await _linuxTools();
    if (png == null) return null;
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Điểm ảnh thô từ native: "bgra" (macOS, Windows) hoặc "rgba" (Linux X11), từ trên xuống, 4 byte / điểm.
  static Future<ui.Image> _fromPixels(Map<String, Object?> r) {
    final bgra = r['bgra'] as Uint8List?;
    final px = bgra ?? r['rgba'] as Uint8List;
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, r['width'] as int, r['height'] as int,
        bgra != null ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// Linux (Wayland): chụp qua xdg-desktop-portal (GNOME / KDE có thể hỏi cho phép lần đầu).
  static Future<Uint8List?> _linuxPortal() async {
    final client = DBusClient.session();
    try {
      final portal = DBusRemoteObject(client,
          name: 'org.freedesktop.portal.Desktop', path: DBusObjectPath('/org/freedesktop/portal/desktop'));
      // Gọi thử một lệnh để có tên của mình trên bus: đường dẫn Request của portal tính từ tên này.
      await client.callMethod(
          destination: 'org.freedesktop.DBus',
          path: DBusObjectPath('/org/freedesktop/DBus'),
          interface: 'org.freedesktop.DBus',
          name: 'GetId',
          replySignature: DBusSignature('s'));
      final sender = client.uniqueName.substring(1).replaceAll('.', '_');
      final token = 'shot${DateTime.now().millisecondsSinceEpoch}';
      final response = DBusSignalStream(client,
              interface: 'org.freedesktop.portal.Request',
              name: 'Response',
              path: DBusObjectPath('/org/freedesktop/portal/desktop/request/$sender/$token'),
              signature: DBusSignature('ua{sv}'))
          .first;
      // Đăng ký nghe tín hiệu trả lời trước khi gọi.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await portal.callMethod(
          'org.freedesktop.portal.Screenshot',
          'Screenshot',
          [
            const DBusString(''),
            DBusDict.stringVariant({'handle_token': DBusString(token), 'interactive': const DBusBoolean(false)}),
          ],
          replySignature: DBusSignature('o'));
      final sig = await response.timeout(const Duration(minutes: 2));
      if (sig.values[0].asUint32() != 0) return null;
      final uri = sig.values[1].asStringVariantDict()['uri']?.asString();
      if (uri == null) return null;
      final f = File(Uri.parse(uri).toFilePath());
      final bytes = await f.readAsBytes();
      // Portal tự lưu ảnh vào thư mục Ảnh: ảnh vừa tạo chỉ dùng để gửi, xoá đi cho gọn.
      try {
        if (DateTime.now().difference(await f.lastModified()).inMinutes < 3) await f.delete();
      } catch (_) {}
      return bytes;
    } catch (e) {
      debugPrint('[screenshot] portal: $e');
      return null;
    } finally {
      await client.close();
    }
  }

  /// Linux: các công cụ chụp màn hình thường có sẵn (GNOME, wlroots, KDE, X11).
  static Future<Uint8List?> _linuxTools() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/shot_${DateTime.now().millisecondsSinceEpoch}.png';
    final tools = [
      ['gnome-screenshot', '-f', path],
      ['grim', path],
      ['spectacle', '-b', '-n', '-f', '-o', path],
      ['scrot', '-o', path],
      ['import', '-window', 'root', path],
    ];
    for (final t in tools) {
      try {
        final r = await Process.run(t.first, t.sublist(1));
        final f = File(path);
        if (r.exitCode == 0 && f.existsSync()) {
          final bytes = await f.readAsBytes();
          await f.delete();
          if (bytes.isNotEmpty) return bytes;
        }
      } catch (_) {}
    }
    return null;
  }
}

enum _Tool { pen, arrow, rect, text }

/// Một nét vẽ / ghi chú, toạ độ trên lớp phủ.
class _Mark {
  _Mark(this.tool, this.color, this.points, [this.text = '']);
  final _Tool tool;
  final Color color;

  /// Bút: mọi điểm; mũi tên / khung: điểm đầu + điểm cuối; chữ: góc trên trái.
  final List<Offset> points;
  final String text;
}

const _stroke = 3.0;
const _accent = Color(0xFF1E88E5);
const _colors = [Color(0xFFE53935), Color(0xFFFFC107), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFFFFFFFF), Color(0xFF212121)];

TextStyle _textStyle(Color c) => TextStyle(
      color: c,
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.2,
      shadows: [Shadow(color: c.computeLuminance() > .5 ? const Color(0x99000000) : const Color(0x66FFFFFF), blurRadius: 3)],
    );

void _paintMarks(Canvas canvas, Iterable<_Mark> marks) {
  for (final m in marks) {
    final p = Paint()
      ..color = m.color
      ..strokeWidth = _stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pts = m.points;
    if (pts.isEmpty) continue;
    switch (m.tool) {
      case _Tool.pen:
        if (pts.length == 1) {
          canvas.drawCircle(pts.first, _stroke / 2, p..style = PaintingStyle.fill);
          continue;
        }
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final q in pts.skip(1)) {
          path.lineTo(q.dx, q.dy);
        }
        canvas.drawPath(path, p);
      case _Tool.rect:
        if (pts.length > 1) canvas.drawRect(Rect.fromPoints(pts[0], pts[1]), p);
      case _Tool.arrow:
        if (pts.length < 2) continue;
        final a = pts[0], b = pts[1];
        final d = b - a;
        if (d.distance < 2) continue;
        const head = 16.0;
        final ang = d.direction;
        // Thân mũi tên dừng ở chân đầu mũi tên để đầu nhọn gọn.
        final neck = b - Offset.fromDirection(ang, math.min(head * .8, d.distance));
        canvas.drawLine(a, neck, p);
        final tip = Path()
          ..moveTo(b.dx, b.dy)
          ..lineTo(b.dx - head * math.cos(ang - .45), b.dy - head * math.sin(ang - .45))
          ..lineTo(b.dx - head * math.cos(ang + .45), b.dy - head * math.sin(ang + .45))
          ..close();
        canvas.drawPath(tip, Paint()..color = m.color);
      case _Tool.text:
        final tp = TextPainter(text: TextSpan(text: m.text, style: _textStyle(m.color)), textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, pts.first);
        tp.dispose();
    }
  }
}

/// Lớp phủ toàn màn hình: ảnh vừa chụp làm mờ, kéo chọn vùng (vùng chọn sáng rõ, có kích thước),
/// thanh công cụ cạnh vùng chọn: vẽ tự do, mũi tên, khung, chữ, màu, hoàn tác, hủy, gửi.
/// Enter: đưa ảnh vào ô nhắn tin (chưa chọn vùng: cả màn hình). Esc: hủy. Trả về đường dẫn PNG.
class ScreenshotOverlay extends StatefulWidget {
  const ScreenshotOverlay({super.key, required this.image});
  final ui.Image image;

  @override
  State<ScreenshotOverlay> createState() => _ScreenshotOverlayState();
}

class _ScreenshotOverlayState extends State<ScreenshotOverlay> {
  final _keys = FocusNode();
  final _textCtl = TextEditingController();
  final _textFocus = FocusNode();
  final _marks = <_Mark>[];

  /// Vùng chọn (toạ độ lớp phủ, nằm trong [_img]).
  Rect? _sel;
  Offset? _start;
  bool _selecting = false;
  _Mark? _drawing;
  _Tool? _tool;
  Color _color = _colors.first;

  /// Đang gõ chữ ở vị trí này.
  Offset? _textAt;
  bool _saving = false;

  /// Vị trí ảnh trên lớp phủ (giữ tỉ lệ, giữa màn hình).
  Rect _img = Rect.zero;

  @override
  void dispose() {
    _keys.dispose();
    _textCtl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Offset _clamp(Offset p, Rect r) => Offset(p.dx.clamp(r.left, r.right), p.dy.clamp(r.top, r.bottom));

  void _commitText() {
    final at = _textAt;
    if (at == null) return;
    final t = _textCtl.text.trim();
    setState(() {
      if (t.isNotEmpty) _marks.add(_Mark(_Tool.text, _color, [at], t));
      _textAt = null;
      _textCtl.clear();
    });
    _keys.requestFocus();
  }

  void _cancelText() {
    setState(() {
      _textAt = null;
      _textCtl.clear();
    });
    _keys.requestFocus();
  }

  void _undo() {
    if (_textAt != null) return _cancelText();
    setState(() {
      if (_marks.isNotEmpty) {
        _marks.removeLast();
      } else {
        _sel = null;
      }
    });
  }

  void _panStart(DragStartDetails d) {
    if (_saving) return;
    _commitText();
    final p = _clamp(d.localPosition, _img);
    final sel = _sel;
    if (sel != null && _tool != null && _tool != _Tool.text && sel.contains(d.localPosition)) {
      setState(() => _drawing = _Mark(_tool!, _color, _tool == _Tool.pen ? [p] : [p, p]));
    } else if (_marks.isEmpty) {
      // Chưa vẽ gì: kéo ở đâu cũng là chọn lại vùng.
      setState(() {
        _start = p;
        _sel = Rect.fromPoints(p, p);
        _selecting = true;
      });
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    if (_selecting && _start != null) {
      setState(() => _sel = Rect.fromPoints(_start!, _clamp(d.localPosition, _img)));
    } else if (_drawing != null && _sel != null) {
      final p = _clamp(d.localPosition, _sel!);
      setState(() {
        if (_drawing!.tool == _Tool.pen) {
          _drawing!.points.add(p);
        } else {
          _drawing!.points[1] = p;
        }
      });
    }
  }

  void _panEnd([DragEndDetails? _]) {
    setState(() {
      if (_selecting) {
        _selecting = false;
        if (_sel != null && (_sel!.width < 4 || _sel!.height < 4)) _sel = null;
      }
      if (_drawing != null) {
        _marks.add(_drawing!);
        _drawing = null;
      }
    });
  }

  void _tapUp(TapUpDetails d) {
    if (_saving) return;
    final sel = _sel;
    if (_textAt != null) return _commitText();
    if (_tool == _Tool.text && sel != null && sel.contains(d.localPosition)) {
      setState(() => _textAt = d.localPosition - const Offset(0, 12));
      WidgetsBinding.instance.addPostFrameCallback((_) => _textFocus.requestFocus());
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      if (_textAt != null) {
        _cancelText();
      } else if (!_saving) {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    // Đang gõ chữ: Enter / Cmd+Z thuộc về ô chữ.
    if (_textAt != null) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _finish();
      return KeyEventResult.handled;
    }
    final mod = HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;
    if (mod && k == LogicalKeyboardKey.keyZ) {
      _undo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Cắt vùng chọn từ ảnh gốc (đủ độ phân giải màn hình), vẽ ghi chú lên, lưu PNG.
  Future<void> _finish() async {
    if (_saving || _img.isEmpty) return;
    _commitText();
    final sel = (_sel ?? _img).intersect(_img);
    if (sel.width < 2 || sel.height < 2) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    try {
      final img = widget.image;
      final s = img.width / _img.width;
      final l = ((sel.left - _img.left) * s).floor().clamp(0, img.width - 1);
      final t = ((sel.top - _img.top) * s).floor().clamp(0, img.height - 1);
      final r = ((sel.right - _img.left) * s).ceil().clamp(l + 1, img.width);
      final b = ((sel.bottom - _img.top) * s).ceil().clamp(t + 1, img.height);
      final w = r - l, h = b - t;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImageRect(img, Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()),
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.none);
      c.scale(w / sel.width, h / sel.height);
      c.translate(-sel.left, -sel.top);
      _paintMarks(c, _marks);
      final out = await rec.endRecording().toImage(w, h);
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      if (png == null) return nav.pop();
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}screenshot_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png.buffer.asUint8List());
      nav.pop(f.path);
    } catch (e) {
      debugPrint('[screenshot] save: $e');
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(builder: (context, box) {
          final size = box.biggest;
          final iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
          final k = math.min(size.width / iw, size.height / ih);
          _img = Rect.fromCenter(center: size.center(Offset.zero), width: iw * k, height: ih * k);
          final sel = _sel;
          final px = widget.image.width / _img.width;
          return Stack(children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: _tool == _Tool.text && sel != null ? SystemMouseCursors.text : SystemMouseCursors.precise,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Vùng chọn bắt đầu đúng chỗ nhấn chuột (không lệch theo ngưỡng kéo).
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: _panStart,
                  onPanUpdate: _panUpdate,
                  onPanEnd: _panEnd,
                  onPanCancel: _panEnd,
                  onTapUp: _tapUp,
                  child: CustomPaint(
                    painter: _ShotPainter(widget.image, _img, sel, [..._marks, ?_drawing]),
                  ),
                ),
              ),
            ),
            if (sel == null)
              Positioned(
                top: 28,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: _Pill(
                      child: Text(tr('Kéo để chọn vùng cần chụp · Enter: cả màn hình · Esc: hủy'),
                          style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ),
                  ),
                ),
              ),
            if (sel != null)
              Positioned(
                left: sel.left,
                top: sel.top >= 30 ? sel.top - 28 : sel.top + 4,
                child: IgnorePointer(
                  child: _Pill(
                    dense: true,
                    child: Text('${(sel.width * px).round()} × ${(sel.height * px).round()}',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [ui.FontFeature.tabularFigures()])),
                  ),
                ),
              ),
            if (sel != null && !_selecting) _toolbar(size, sel),
            if (_textAt != null)
              Positioned(
                left: _textAt!.dx,
                top: _textAt!.dy,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: 60, maxWidth: math.max(60, (sel?.right ?? size.width) - _textAt!.dx)),
                  child: IntrinsicWidth(
                    child: TextField(
                      controller: _textCtl,
                      focusNode: _textFocus,
                      style: _textStyle(_color),
                      cursorColor: _color,
                      decoration: InputDecoration.collapsed(
                          hintText: tr('Nhập chữ…'), hintStyle: _textStyle(_color.withValues(alpha: .55))),
                      onSubmitted: (_) => _commitText(),
                    ),
                  ),
                ),
              ),
            if (_saving) const Center(child: CircularProgressIndicator()),
          ]);
        }),
      ),
    );
  }

  Widget _toolbar(Size size, Rect sel) {
    const w = 486.0, h = 44.0;
    final left = (sel.right - w).clamp(8.0, math.max(8.0, size.width - w - 8)).toDouble();
    final top = sel.bottom + 8 + h <= size.height
        ? sel.bottom + 8
        : (sel.top - 8 - h >= 0 ? sel.top - 8 - h : sel.bottom - h - 8);
    Widget tool(_Tool t, IconData icon, String tip) => _Btn(
          icon: icon,
          tooltip: tip,
          on: _tool == t,
          onTap: () {
            _commitText();
            setState(() => _tool = _tool == t ? null : t);
          },
        );
    Widget sep() => Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: Colors.white24);
    return Positioned(
      left: left,
      top: top,
      child: Container(
        height: h,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xF0202124),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 10)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          tool(_Tool.pen, Icons.edit_rounded, tr('Vẽ tự do')),
          tool(_Tool.arrow, Icons.north_east_rounded, tr('Mũi tên')),
          tool(_Tool.rect, Icons.crop_square_rounded, tr('Hình chữ nhật')),
          tool(_Tool.text, Icons.text_fields_rounded, tr('Chữ')),
          sep(),
          for (final c in _colors)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                setState(() => _color = c);
                if (_textAt != null) _textFocus.requestFocus();
              },
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(color: _color == c ? Colors.white : Colors.white38, width: _color == c ? 2.5 : 1),
                  ),
                ),
              ),
            ),
          sep(),
          _Btn(icon: Icons.undo_rounded, tooltip: tr('Hoàn tác'), onTap: _undo),
          _Btn(icon: Icons.close_rounded, tooltip: tr('Hủy (Esc)'), onTap: () => Navigator.of(context).pop()),
          _Btn(icon: Icons.send_rounded, tooltip: tr('Đưa vào ô nhắn tin (Enter)'), color: _accent, onTap: _finish),
        ]),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({required this.icon, required this.tooltip, required this.onTap, this.on = false, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool on;
  final Color? color;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? _accent.withValues(alpha: .35) : null, borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 20, color: color ?? Colors.white),
          ),
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child, this.dense = false});
  final Widget child;
  final bool dense;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 14, vertical: dense ? 3 : 8),
        decoration: BoxDecoration(color: const Color(0xCC202124), borderRadius: BorderRadius.circular(dense ? 6 : 20)),
        child: child,
      );
}

class _ShotPainter extends CustomPainter {
  _ShotPainter(this.image, this.dst, this.sel, this.marks);
  final ui.Image image;
  final Rect dst;
  final Rect? sel;
  final List<_Mark> marks;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), dst,
        Paint()..filterQuality = FilterQuality.medium);
    // Làm tối cả màn hình trừ vùng chọn.
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(full);
    if (sel != null) dim.addRect(sel!);
    canvas.drawPath(dim, Paint()..color = const Color(0x99000000));
    final s = sel;
    if (s == null) return;
    canvas.save();
    canvas.clipRect(s);
    _paintMarks(canvas, marks);
    canvas.restore();
    canvas.drawRect(
        s,
        Paint()
          ..color = _accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    final dot = Paint()..color = _accent;
    for (final c in [s.topLeft, s.topRight, s.bottomLeft, s.bottomRight, s.topCenter, s.bottomCenter, s.centerLeft, s.centerRight]) {
      canvas.drawRect(Rect.fromCenter(center: c, width: 6, height: 6), dot);
    }
  }

  @override
  bool shouldRepaint(covariant _ShotPainter old) => true;
}
