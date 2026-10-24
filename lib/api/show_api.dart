import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../i18n/i18n.dart';
import 'mini_apps.dart';

/// Lỗi của app Trình chiếu: [message] là câu tiếng Việt cho người dùng (server trả {error}).
class ShowException implements Exception {
  final int status;
  final String message;
  ShowException(this.status, this.message);
  @override
  String toString() => message;
}

/// Gọi app Trình chiếu (mini app có màn hình native "show"):
/// launch token của registry → `POST <base_url>/api/session` lấy token phiên (2 giờ) → `POST /api/call/<tool>` với Bearer.
/// Đây đúng là bộ tool AI dùng qua MCP, nên người và AI cùng chức năng, cùng quyền. Token phiên chỉ giữ trong bộ nhớ.
class ShowClient {
  final MiniApp app;
  final String mmToken;
  ShowClient(this.app, this.mmToken);

  String? _session;
  Future<String>? _opening;
  /// Quyền trong Show (view, edit, present, admin…) và tên người dùng, có sau lần mở phiên đầu.
  Set<String> perms = {};
  String userName = '';

  String get base => app.baseUrl;
  /// Token phiên đang dùng (null: chưa mở); đổi khi phiên được làm mới.
  String? get current => _session;
  bool can(String p) => perms.contains(p) || perms.contains('admin');

  /// Token phiên (mở phiên mới nếu chưa có hoặc [renew]).
  Future<String> session({bool renew = false}) {
    if (!renew && _session != null) return Future.value(_session);
    return _opening ??= () async {
      try {
        final u = Uri.parse('$base/api/session');
        // base_url phải cùng origin với app (registry không đưa token phiên đi chỗ khác).
        if (!app.owns(u)) throw ShowException(502, tr('Không mở được ứng dụng ({0}).', ['base_url']));
        final launch = await MiniApps.launchToken(mmToken, app);
        final r = await http
            .post(u, headers: {'Content-Type': 'application/json', 'User-Agent': kUserAgent}, body: jsonEncode({'launch_token': launch}))
            .timeout(const Duration(seconds: 15));
        final j = _json(r);
        if (r.statusCode != 200) throw ShowException(r.statusCode, '${j['error'] ?? 'session ${r.statusCode}'}');
        perms = {for (final p in (j['perms'] as List? ?? const [])) '$p'};
        userName = '${(j['user'] as Map?)?['name'] ?? ''}';
        return _session = '${j['token']}';
      } finally {
        _opening = null;
      }
    }();
  }

  static Map _json(http.Response r) {
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map ? j : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Gọi tool [name] với [params]. Phiên hết hạn (401) thì mở phiên mới (im lặng) rồi gọi lại một lần.
  Future<Map<String, dynamic>> call(String name, [Map<String, dynamic> params = const {}]) async {
    for (var attempt = 0;; attempt++) {
      final t = await session(renew: attempt > 0);
      final r = await http
          .post(Uri.parse('$base/api/call/$name'),
              headers: {'Authorization': 'Bearer $t', 'Content-Type': 'application/json', 'User-Agent': kUserAgent},
              body: jsonEncode(params))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 401 && attempt == 0) continue;
      final j = _json(r);
      if (r.statusCode != 200) throw ShowException(r.statusCode, '${j['error'] ?? '$name ${r.statusCode}'}');
      return j.cast<String, dynamic>();
    }
  }

  /// Trang HTML của bộ slide [deckId] (1920×1080) để xem trước trong webview; điều khiển bằng flygoGo(frame, step, live).
  /// Có [pid] (buổi đang chiếu): màn chờ hiện người trình bày và QR link khách.
  /// [lang]: bản dịch cần hiện (null = ngôn ngữ gốc).
  Future<Uri> renderUrl(String deckId, {String? pid, String? lang}) async => Uri.parse('$base/render/${Uri.encodeComponent(deckId)}')
      .replace(queryParameters: {'s': await session(), 'pid': ?pid, 'lang': ?lang});

  /// Trạng thái realtime của buổi [pid]: tin `{type: state, …}` mỗi lần đổi trang (người, AI, autopilot).
  /// Tự nối lại (1s → 15s), làm mới phiên khi bị từ chối; đóng bằng [ShowLive.close].
  ShowLive live(String pid) => ShowLive._(this, pid);

  /// Trang phát nhạc nền + giọng đọc của buổi [pid] cho máy điều khiển (nạp trong WebView ẩn); bắt đầu ở trạng thái tắt.
  Future<Uri> audioUrl(String pid) async =>
      Uri.parse('$base/audio').replace(queryParameters: {'pid': pid, 's': await session(), 'on': '0'});
}

class ShowLive {
  final ShowClient _c;
  final String pid;
  final _out = StreamController<Map<String, dynamic>>.broadcast();
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _ping, _retry;
  bool _closed = false;
  int _backoff = 1;
  bool _renew = false;

  ShowLive._(this._c, this.pid) {
    _connect();
  }

  Stream<Map<String, dynamic>> get states => _out.stream;

  Future<void> _connect() async {
    if (_closed) return;
    try {
      final t = await _c.session(renew: _renew);
      _renew = false;
      final u = Uri.parse(_c.base);
      final ws = WebSocketChannel.connect(u.replace(
          scheme: u.scheme == 'https' ? 'wss' : 'ws', path: '/ws', queryParameters: {'pid': pid, 's': t}));
      await ws.ready;
      if (_closed) {
        ws.sink.close();
        return;
      }
      _ws = ws;
      _backoff = 1;
      _ping = Timer.periodic(const Duration(seconds: 25), (_) => ws.sink.add('ping'));
      _sub = ws.stream.listen((m) {
        if (m is! String || m == 'pong') return;
        try {
          final j = jsonDecode(m);
          if (j is Map && j['type'] == 'state') _out.add(j.cast<String, dynamic>());
        } catch (_) {}
      }, onDone: _again, onError: (_) => _again());
    } catch (e) {
      // Bị từ chối khi bắt tay (403: phiên hết hạn hoặc mất quyền) → lần sau mở phiên mới.
      _renew = '$e'.contains('403') || '$e'.contains('401');
      _again();
    }
  }

  void _again() {
    _ping?.cancel();
    _sub?.cancel();
    _ws = null;
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(1, 15);
  }

  void close() {
    _closed = true;
    _ping?.cancel();
    _retry?.cancel();
    _sub?.cancel();
    _ws?.sink.close();
    _out.close();
  }
}
