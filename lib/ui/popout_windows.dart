import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path_provider/path_provider.dart';
import 'package:window_to_front/window_to_front.dart';

import '../config.dart';
import '../i18n/i18n.dart';
import 'panes/pane_layout.dart';

/// Kết quả khi tách một ô ra cửa sổ riêng.
enum PopoutResult { opened, alreadyOpen, limit, failed }

/// Câu báo cho người dùng theo kết quả mở cửa sổ riêng (null = không cần báo).
String? popoutNotice(PopoutResult r) => switch (r) {
      PopoutResult.limit => tr('Đã mở tối đa {0} cửa sổ riêng. Đóng bớt một cửa sổ rồi thử lại.', [PopoutWindows.maxWindows]),
      PopoutResult.failed => tr('Không mở được cửa sổ riêng.'),
      _ => null,
    };

/// Cửa sổ riêng (máy tính) tách ra từ màn chia ô: mỗi cửa sổ là một tiến trình app khác chạy với `--chat=<kênh>` hoặc
/// `--section=<mục>` kèm `--server=<máy chủ>`, tự mở phiên đã lưu của máy chủ đó (không truyền token qua tham số,
/// không ghi token ra tệp nào thêm). Cửa sổ chính giữ khay, thông báo, âm báo, cập nhật và runner trợ lý AI.
///
/// Theo dõi bằng tệp trong `<app support>/popouts/<máy chủ>/`:
/// - `main.lock`: cửa sổ chính khoá suốt lúc chạy. Cửa sổ phụ thấy khoá này được nhả (cửa sổ chính đã thoát) thì tự
///   đóng, giữ nguyên dấu "đang mở" để lần mở app sau mở lại đúng chỗ cũ.
/// - `<tên>.lock`: cửa sổ phụ khoá suốt lúc chạy (biết cửa sổ còn sống, không mở trùng).
/// - `<tên>.json`: nội dung, còn mở hay không, vị trí / kích thước cửa sổ (cửa sổ phụ tự ghi khi kéo / đổi cỡ).
/// - `<tên>.focus`: cửa sổ chính nhờ cửa sổ phụ đưa mình lên trước (mở lại một cửa sổ đang mở).
/// Người dùng bấm X đóng cửa sổ phụ: cửa sổ chính thấy khoá được nhả trong lúc mình còn chạy → bỏ dấu "đang mở".
class PopoutWindows {
  static const maxWindows = 4;
  static const _ch = MethodChannel('flygo/window');

  static bool get supported => !kIsWeb && isDesktop;

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}popouts${Platform.pathSeparator}$serverKey');
    await d.create(recursive: true);
    return d;
  }

  static String slug(PaneContent c) => '${c.kind}_${c.id}'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String _path(Directory d, String name) => '${d.path}${Platform.pathSeparator}$name';

  /// Tệp [name] đang bị tiến trình khác khoá (cửa sổ đó còn chạy)?
  static Future<bool> _locked(Directory d, String name) async {
    final f = File(_path(d, name));
    if (!f.existsSync()) return false;
    RandomAccessFile? r;
    try {
      r = await f.open(mode: FileMode.append);
      await r.lock(FileLock.exclusive, 0, 1);
      await r.unlock(0, 1);
      return false;
    } catch (_) {
      return true;
    } finally {
      try {
        await r?.close();
      } catch (_) {}
    }
  }

  static Future<RandomAccessFile?> _hold(Directory d, String name) async {
    RandomAccessFile? r;
    try {
      r = await File(_path(d, name)).open(mode: FileMode.append);
      await r.lock(FileLock.exclusive, 0, 1);
      return r;
    } catch (_) {
      try {
        await r?.close();
      } catch (_) {}
      return null;
    }
  }

  static Map<String, dynamic> _read(Directory d, String s) {
    try {
      final f = File(_path(d, '$s.json'));
      if (f.existsSync()) return (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  static void _write(Directory d, String s, Map<String, dynamic> j) {
    try {
      final f = File(_path(d, '$s.json'));
      final tmp = File('${f.path}.$pid.tmp');
      tmp.writeAsStringSync(jsonEncode(j), flush: true);
      tmp.renameSync(f.path);
    } catch (_) {}
  }

  /// Các cửa sổ phụ được đánh dấu đang mở (tên tệp, nội dung).
  static List<(String, PaneContent)> _openEntries(Directory d) {
    final out = <(String, PaneContent)>[];
    try {
      for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
        final s = f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), '');
        final j = _read(d, s);
        final c = PaneContent.parse(j['content']);
        if (j['open'] == true && c != null) out.add((s, c));
      }
    } catch (_) {}
    return out;
  }

  // ---------------------------------------------------------------- cửa sổ chính
  static RandomAccessFile? _mainLock;
  static final Map<String, DateTime> _spawned = {};
  static Timer? _sweep;
  static AppLifecycleListener? _waitShow;

  /// Cửa sổ chính vừa vào app: giữ khoá `main.lock`, mở lại các cửa sổ phụ còn đánh dấu "đang mở" (lần trước thoát app
  /// khi chúng đang mở), rồi định kỳ xem cửa sổ phụ nào đã bị đóng.
  static Future<void> startMain() async {
    if (!supported || isChildWindow) return;
    try {
      final d = await _dir();
      _mainLock ??= await _hold(d, 'main.lock');
      // Có cửa sổ chính khác của cùng máy chủ đang giữ khoá: để cửa sổ đó quản lý.
      if (_mainLock == null) return;
      // Mở cùng Windows (ẩn dưới khay): chờ cửa sổ chính hiện lên mới mở lại các cửa sổ riêng.
      if (kStartHidden) {
        _waitShow ??= AppLifecycleListener(onResume: () {
          _waitShow?.dispose();
          _waitShow = null;
          kStartHidden = false;
          startMain();
        });
        return;
      }
      var n = 0;
      for (final (s, c) in _openEntries(d)) {
        if (await _locked(d, '$s.lock')) {
          n++;
          continue;
        }
        if (n >= maxWindows) {
          _write(d, s, {..._read(d, s), 'open': false});
          continue;
        }
        n++;
        await _spawn(s, c);
      }
      _sweep ??= Timer.periodic(const Duration(seconds: 4), (_) => _sweepClosed());
    } catch (e) {
      debugPrint('[popout] $e');
    }
  }

  /// Đăng xuất: không mở lại các cửa sổ phụ cho lần đăng nhập sau.
  static Future<void> forgetAll() async {
    if (!supported || isChildWindow) return;
    try {
      final d = await _dir();
      for (final (s, _) in _openEntries(d)) {
        _write(d, s, {..._read(d, s), 'open': false});
      }
    } catch (_) {}
  }

  static Future<void> _sweepClosed() async {
    try {
      final d = await _dir();
      for (final (s, _) in _openEntries(d)) {
        final t = _spawned[s];
        // Cửa sổ vừa mở còn đang khởi động (chưa kịp giữ khoá).
        if (t != null && DateTime.now().difference(t).inSeconds < 25) continue;
        if (!await _locked(d, '$s.lock')) _write(d, s, {..._read(d, s), 'open': false});
      }
    } catch (_) {}
  }

  static Future<void> _spawn(String s, PaneContent c) async {
    _spawned[s] = DateTime.now();
    await Process.start(
        Platform.resolvedExecutable,
        [
          c.isChat ? '--chat=${c.id}' : '--section=${c.id}',
          '--popout',
          if (kServerUrl.isNotEmpty) '--server=$kServerUrl',
        ],
        mode: ProcessStartMode.detached);
  }

  /// Mở [c] trong cửa sổ riêng. Đang mở rồi thì đưa cửa sổ đó lên trước; tối đa [maxWindows] cửa sổ.
  static Future<PopoutResult> open(PaneContent c) async {
    if (!supported) return PopoutResult.failed;
    try {
      final d = await _dir();
      final s = slug(c);
      if (await _locked(d, '$s.lock')) {
        File(_path(d, '$s.focus')).writeAsStringSync('$pid');
        return PopoutResult.alreadyOpen;
      }
      var n = 0;
      for (final (o, _) in _openEntries(d)) {
        if (o != s && (await _locked(d, '$o.lock') || _spawned.containsKey(o))) n++;
      }
      if (n >= maxWindows) return PopoutResult.limit;
      _write(d, s, {..._read(d, s), 'content': c.key, 'open': true});
      await _spawn(s, c);
      return PopoutResult.opened;
    } catch (e) {
      debugPrint('[popout] $e');
      return PopoutResult.failed;
    }
  }

  // ---------------------------------------------------------------- cửa sổ phụ
  /// Khoá của chính cửa sổ phụ, giữ tới khi tiến trình thoát.
  static RandomAccessFile? _selfLock;

  /// Cửa sổ phụ khởi động (trước runApp): giữ khoá của mình (đã có cửa sổ y hệt thì nhờ nó hiện lên rồi thoát), đặt lại
  /// vị trí / kích thước lần trước, rồi định kỳ lưu vị trí, nghe yêu cầu đưa lên trước và tự đóng khi cửa sổ chính thoát.
  static Future<void> startChild(PaneContent c) async {
    if (!supported) return;
    final Directory d;
    try {
      d = await _dir();
    } catch (_) {
      return;
    }
    final s = slug(c);
    _selfLock = await _hold(d, '$s.lock');
    if (_selfLock == null) {
      try {
        File(_path(d, '$s.focus')).writeAsStringSync('$pid');
      } catch (_) {}
      exit(0);
    }
    final saved = _read(d, s);
    _write(d, s, {...saved, 'content': c.key, 'open': true});
    final frame = saved['frame'];
    try {
      // Màn hình cũ đã rút / lần đầu mở: cửa sổ gọn ở giữa màn hình (cửa sổ app mặc định mở to hết màn hình).
      final restored = frame is List &&
          frame.length == 4 &&
          await _ch.invokeMethod<bool>('setFrame', [for (final v in frame) (v as num).toDouble()]) == true;
      if (!restored) await _ch.invokeMethod('center', [c.isChat ? 560.0 : 460.0, 820.0]);
    } catch (_) {}
    var last = frame is List ? frame.join(',') : '';
    var ticks = 0;
    Timer.periodic(const Duration(seconds: 2), (_) async {
      ticks++;
      // Cửa sổ chính đã thoát (khoá được nhả): đóng theo, giữ dấu "đang mở" để lần sau mở lại.
      if (ticks >= 3 && !await _locked(d, 'main.lock')) exit(0);
      final focus = File(_path(d, '$s.focus'));
      if (focus.existsSync()) {
        try {
          focus.deleteSync();
        } catch (_) {}
        WindowToFront.activate();
      }
      try {
        final f = await _ch.invokeMethod<List<Object?>>('getFrame');
        if (f != null && f.length == 4) {
          final v = [for (final x in f) (x as num).toDouble()];
          final k = v.join(',');
          if (k != last) {
            last = k;
            _write(d, s, {..._read(d, s), 'content': c.key, 'open': true, 'frame': v});
          }
        }
      } catch (_) {}
    });
  }
}
