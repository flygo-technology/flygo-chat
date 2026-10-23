import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';
import '../i18n/i18n.dart';

/// Mini app (mục "Ứng dụng"): danh sách tải lúc chạy từ registry của máy chủ chat, không hardcode trong app.
/// Mỗi app là một trang web ở origin riêng, mở trong webview bằng URL mở app dùng một lần (launch token 60 giây).
/// Token Mattermost chỉ gửi tới registry, không bao giờ tới app.
class MiniApp {
  final String id, version, minClient, origin;
  final Object? _name, _description;
  /// URL https của ảnh, hoặc một emoji.
  final String icon;
  final List<String> scanPrefixes;
  MiniApp._(this.id, this._name, this._description, this.icon, this.version, this.minClient, this.origin, this.scanPrefixes);

  factory MiniApp.fromJson(Map j) => MiniApp._(
        '${j['id']}',
        j['name'],
        j['description'],
        '${j['icon'] ?? ''}',
        '${j['version'] ?? ''}',
        '${j['min_client'] ?? ''}',
        '${j['origin'] ?? ''}',
        [for (final p in (j['scan_prefixes'] as List? ?? const [])) '$p'],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': _name,
        'description': _description,
        'icon': icon,
        'version': version,
        'min_client': minClient,
        'origin': origin,
        'scan_prefixes': scanPrefixes,
      };

  /// Chuỗi hoặc map theo ngôn ngữ ({vi, en}).
  static String _text(Object? v) {
    if (v is Map) return '${v[appLanguage.value] ?? v['vi'] ?? v['en'] ?? (v.values.isEmpty ? '' : v.values.first)}';
    return v == null ? '' : '$v';
  }

  String get name => _text(_name).isEmpty ? id : _text(_name);
  String get description => _text(_description);
  bool get iconIsUrl => icon.startsWith('https://');

  /// Phiên bản Flygo đang chạy thấp hơn min_client: hiện mờ, kèm "Cần cập nhật Flygo".
  bool get needsUpdate => minClient.isNotEmpty && _clientVersion != null && _cmpVersion(_clientVersion!, minClient) < 0;

  /// Trang cùng origin với app (chỉ điều hướng trong origin, cầu nối JS chỉ bật cho origin này).
  bool owns(Uri u) {
    final o = Uri.tryParse(origin);
    return o != null && u.scheme == o.scheme && u.host == o.host && u.port == o.port;
  }

  /// Đường dẫn (kèm query / fragment) mở app khi quét [raw], nếu khớp một scan_prefixes; không khớp: null.
  String? scanPath(String raw) {
    if (!scanPrefixes.any((p) => p.isNotEmpty && raw.startsWith(p))) return null;
    final u = Uri.tryParse(raw);
    if (u == null || !owns(u)) return null;
    final path = u.path.isEmpty ? '/' : u.path;
    return '$path${u.hasQuery ? '?${u.query}' : ''}${u.hasFragment ? '#${u.fragment}' : ''}';
  }
}

String? _clientVersion;

/// "1.0.0+232" so với "1.0.0" / "1.0.0+230": so từng số, phần build (sau +) chỉ so khi cả hai có.
int _cmpVersion(String a, String b) {
  List<int> parts(String s) => [for (final x in s.split('+').first.split('.')) int.tryParse(x) ?? 0];
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d;
  }
  if (a.contains('+') && b.contains('+')) return (int.tryParse(a.split('+').last) ?? 0) - (int.tryParse(b.split('+').last) ?? 0);
  return 0;
}

class MiniAppException implements Exception {
  final int status;
  final String message;
  MiniAppException(this.status, this.message);
  @override
  String toString() => message;
}

/// Registry, danh sách app và mở app của máy chủ chat đang dùng.
class MiniApps {
  /// Đặt khi build (`--dart-define=FLYGO_APPS_REGISTRY=…`) để chạy thử với registry local; khi đó dùng cho mọi máy chủ.
  static const _override = String.fromEnvironment('FLYGO_APPS_REGISTRY');
  static final _registry = <String, String>{}; // máy chủ chat -> registry ('' = không có)
  static final _apps = <String, (DateTime, List<MiniApp>)>{};
  static const _ttl = Duration(minutes: 10);

  static Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'X-MM-Server': kServerUrl,
        'Content-Type': 'application/json',
        'User-Agent': kUserAgent,
      };

  /// Registry của máy chủ đang dùng: `https://<máy chủ chat>/.well-known/flygo-apps.json` → {"registry": "https://…"}.
  /// Không tìm thấy: null (ẩn mục Ứng dụng). Lỗi mạng thì lần sau dò lại.
  static Future<String?> registry() async {
    if (_override.isNotEmpty) return _override;
    final server = kServerUrl;
    final known = _registry[server];
    if (known != null) return known.isEmpty ? null : known;
    try {
      final r = await http
          .get(Uri.parse('$server/.well-known/flygo-apps.json'), headers: {'User-Agent': kUserAgent})
          .timeout(const Duration(seconds: 5));
      var reg = '';
      if (r.statusCode == 200) {
        final u = Uri.tryParse('${(jsonDecode(r.body) as Map)['registry'] ?? ''}');
        if (u != null && u.scheme == 'https' && u.host.isNotEmpty) reg = u.toString().replaceAll(RegExp(r'/+$'), '');
      }
      _registry[server] = reg;
      return reg.isEmpty ? null : reg;
    } on FormatException {
      _registry[server] = '';
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Danh sách app đã lọc theo quyền (thứ tự của registry). Có sẵn trong 10 phút thì dùng lại, trừ khi [refresh].
  /// Không có registry: rỗng.
  static Future<List<MiniApp>> list(String token, {bool refresh = false}) async {
    _clientVersion ??= await _version();
    final server = kServerUrl;
    final cached = _apps[server];
    if (!refresh && cached != null && DateTime.now().difference(cached.$1) < _ttl) return cached.$2;
    final reg = await registry();
    if (reg == null) return const [];
    try {
      final r = await http.get(Uri.parse('$reg/v1/apps'), headers: _headers(token)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw MiniAppException(r.statusCode, 'apps ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final apps = [
        for (final a in (j['apps'] as List? ?? const []))
          if (a is Map && '${a['id'] ?? ''}'.isNotEmpty && Uri.tryParse('${a['origin'] ?? ''}')?.host.isNotEmpty == true) MiniApp.fromJson(a),
      ];
      _apps[server] = (DateTime.now(), apps);
      return apps;
    } catch (_) {
      if (cached != null) return cached.$2;
      rethrow;
    }
  }

  /// Danh sách đã tải gần nhất của máy chủ đang dùng (không gọi mạng).
  static List<MiniApp> get cached => _apps[kServerUrl]?.$2 ?? const [];

  /// App có scan_prefixes khớp nội dung QR [raw], kèm đường dẫn để mở; không khớp: null.
  static Future<(MiniApp, String)?> forScan(String token, String raw) async {
    if (!raw.startsWith('https://') && !raw.startsWith('http://')) return null;
    List<MiniApp> apps;
    try {
      apps = await list(token);
    } catch (_) {
      apps = cached;
    }
    for (final a in apps) {
      final p = a.scanPath(raw);
      if (p != null) return (a, p);
    }
    return null;
  }

  /// URL mở app (dùng một lần, sống 60 giây): gọi ngay trước khi mở webview, không lưu lại.
  /// 401: phiên Mattermost hỏng; 404: app bị gỡ hoặc mất quyền (danh sách được tải lại lần sau).
  static Future<Uri> launch(String token, MiniApp app, {String? path}) async {
    final reg = await registry();
    if (reg == null) throw MiniAppException(404, tr('Máy chủ này chưa có ứng dụng.'));
    final r = await http
        .post(Uri.parse('$reg/v1/apps/${Uri.encodeComponent(app.id)}/launch'),
            headers: _headers(token), body: jsonEncode({if (path != null && path.startsWith('/')) 'path': path}))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 401) throw MiniAppException(401, tr('Phiên đăng nhập đã hết hạn, hãy đăng nhập lại.'));
    if (r.statusCode == 404) {
      _apps.remove(kServerUrl);
      throw MiniAppException(404, tr('Ứng dụng không còn hoặc bạn không còn quyền dùng.'));
    }
    if (r.statusCode != 200) throw MiniAppException(r.statusCode, tr('Không mở được ứng dụng ({0}).', ['${r.statusCode}']));
    final u = Uri.tryParse('${(jsonDecode(utf8.decode(r.bodyBytes)) as Map)['url'] ?? ''}');
    // URL mở app phải thuộc origin của app (registry không đưa webview đi chỗ khác).
    if (u == null || !app.owns(u)) throw MiniAppException(502, tr('Không mở được ứng dụng ({0}).', ['url']));
    return u;
  }

  static Future<String?> _version() async {
    try {
      final i = await PackageInfo.fromPlatform();
      return i.buildNumber.isEmpty ? i.version : '${i.version}+${i.buildNumber}';
    } catch (_) {
      return null;
    }
  }

  /// Webview trong app: Android, iOS, macOS. Windows / Linux: mở URL mở app bằng trình duyệt hệ thống.
  static bool get inAppWebView => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}
