import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Lưu token phiên đăng nhập. Điện thoại dùng kho bảo mật của hệ điều hành,
/// máy tính dùng file riêng trong thư mục dữ liệu của app.
class TokenStore {
  static const _key = 'mm_token';
  static const _secure = FlutterSecureStorage();

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}session');
  }

  static Future<String?> read() async {
    if (!kIsWeb && Platform.isAndroid) await _importPreset();
    if (isMobile) return _secure.read(key: _key);
    final f = await _file();
    if (!await f.exists()) return null;
    final t = (await f.readAsString()).trim();
    return t.isEmpty ? null : t;
  }

  /// Quản trị viên có thể cấp sẵn phiên đăng nhập: đẩy file `preset_token`
  /// vào thư mục riêng của app qua ADB. App nhập vào kho bảo mật rồi xóa file.
  static Future<void> _importPreset() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final f = File('${dir.path}/preset_token');
      if (!await f.exists()) return;
      final t = (await f.readAsString()).trim();
      await f.delete();
      if (t.isNotEmpty) await _secure.write(key: _key, value: t);
    } catch (_) {}
  }

  static Future<void> write(String token) async {
    if (isMobile) return _secure.write(key: _key, value: token);
    final f = await _file();
    await f.writeAsString(token, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', f.path]);
    }
  }

  static Future<void> clear() async {
    if (isMobile) return _secure.delete(key: _key);
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

class LoginCancelled implements Exception {}

/// Đăng nhập Google qua luồng mobile_login của Mattermost.
/// Server chuyển về redirect_to kèm MMAUTHTOKEN sau khi Google xác thực xong.
class AuthService {
  static Future<String> loginWithGoogle() async {
    return isMobile ? _mobile() : _desktop();
  }

  static String _loginUrl(String redirect) =>
      '$kServerUrl/oauth/google/mobile_login?redirect_to=${Uri.encodeComponent(redirect)}';

  static Future<String> _mobile() async {
    final result = await FlutterWebAuth2.authenticate(
      url: _loginUrl('$kMobileScheme://callback'),
      callbackUrlScheme: kMobileScheme,
    );
    final token = Uri.parse(result).queryParameters['MMAUTHTOKEN'];
    if (token == null || token.isEmpty) throw Exception('Không nhận được phiên đăng nhập');
    return token;
  }

  /// Máy tính: mở trình duyệt, nhận kết quả qua một cổng tạm trên 127.0.0.1.
  static Future<String> _desktop() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final completer = Completer<String>();
    server.listen((req) async {
      final token = req.uri.queryParameters['MMAUTHTOKEN'];
      final ok = token != null && token.isNotEmpty;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_resultPage(ok));
      await req.response.close();
      if (ok && !completer.isCompleted) completer.complete(token);
    });
    try {
      final url = _loginUrl('http://127.0.0.1:${server.port}/callback');
      if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
        throw Exception('Không mở được trình duyệt');
      }
      return await completer.future.timeout(const Duration(minutes: 5), onTimeout: () => throw LoginCancelled());
    } finally {
      await server.close(force: true);
    }
  }

  static String _resultPage(bool ok) => '''<!doctype html><html lang="vi"><head><meta charset="utf-8">
<title>Flygo Chat</title><style>body{font-family:system-ui,sans-serif;background:#f0f2f5;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0}div{background:#fff;padding:40px 48px;
border-radius:12px;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.1)}h1{color:#008069;font-size:22px}
p{color:#667781}</style></head><body><div><h1>${ok ? 'Đăng nhập thành công' : 'Đăng nhập chưa xong'}</h1>
<p>${ok ? 'Bạn có thể đóng trang này và quay lại ứng dụng Flygo Chat.' : 'Vui lòng quay lại ứng dụng và thử lại.'}</p>
</div></body></html>''';
}
