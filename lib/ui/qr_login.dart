import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config.dart';
import '../data/servers.dart';
import '../state/app_state.dart';
import 'theme.dart';

// Đăng nhập máy tính bằng QR (cùng mạng LAN):
// 1. Máy tính mở một cổng TCP tạm trên LAN, hiện QR chứa: máy chủ chat, IP:cổng, mã dùng một lần (nonce),
//    khoá AES-256 dùng một lần, tên máy. QR hết hạn sau 2 phút.
// 2. Điện thoại (đã đăng nhập) quét QR, người dùng xác nhận → xin trạm đẩy tạo token đăng nhập riêng cho máy tính
//    (POST <trạm đẩy>/qr/token, trạm đẩy kiểm tra đúng người rồi tạo token cá nhân bằng quyền quản trị).
// 3. Điện thoại gửi token đã mã hoá AES-GCM thẳng tới máy tính qua LAN (TCP thô, một dòng JSON) → máy tính đăng nhập.
// Không cùng LAN thì điện thoại không tới được IP:cổng của máy tính.

const _scheme = 'flygochat-qr';
final _aes = AesGcm.with256bits();
String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
List<int> _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

class QrLoginPayload {
  final String server, host, nonce, device;
  final int port;
  final List<int> key;
  QrLoginPayload({required this.server, required this.host, required this.port, required this.nonce, required this.key, required this.device});

  String encode() => Uri(scheme: _scheme, path: 'login', queryParameters: {
        'v': '1',
        's': server,
        'h': host,
        'p': '$port',
        'n': nonce,
        'k': _b64(key),
        'd': device,
      }).toString();

  static QrLoginPayload? parse(String raw) {
    final u = Uri.tryParse(raw);
    if (u == null || u.scheme != _scheme || u.queryParameters['v'] != '1') return null;
    final q = u.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    if (port == null || [q['s'], q['h'], q['n'], q['k']].any((x) => x == null || x.isEmpty)) return null;
    return QrLoginPayload(server: q['s']!, host: q['h']!, port: port, nonce: q['n']!, key: _unb64(q['k']!), device: q['d'] ?? '');
  }
}

/// IP LAN của máy (ưu tiên 192.168.x, rồi 10.x, 172.16–31.x; bỏ loopback, 169.254, 100.64/10 của Tailscale…).
Future<String?> lanAddress() async {
  final ips = <InternetAddress>[];
  for (final n in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    ips.addAll(n.addresses);
  }
  int rank(InternetAddress a) {
    final b = a.rawAddress;
    if (b[0] == 192 && b[1] == 168) return 0;
    if (b[0] == 10) return 1;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return 2;
    return 9;
  }
  final ok = ips.where((a) => rank(a) < 9).toList()..sort((a, b) => rank(a) - rank(b));
  return ok.isEmpty ? null : ok.first.address;
}

// ---------------------------------------------------------------- máy tính: hiện QR, chờ token
class QrLoginPage extends StatefulWidget {
  final String server;
  /// Token đăng nhập + máy chủ của điện thoại (máy tính tự chuyển sang máy chủ đó) + tên máy chủ.
  final void Function(String token, String server, String serverName) onToken;
  const QrLoginPage({super.key, required this.server, required this.onToken});
  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  static const _ttl = 120;
  ServerSocket? _sock;
  String? _host;
  QrLoginPayload? _payload;
  int _left = _ttl;
  Timer? _timer;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _host = await lanAddress();
      if (_host == null) {
        setState(() => _error = tr('Máy tính chưa kết nối mạng LAN (Wi-Fi hoặc dây mạng).'));
        return;
      }
      _sock = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      _sock!.listen(_onClient);
      _renew();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _left--);
        if (_left <= 0) _renew();
      });
    } catch (e) {
      if (mounted) setState(() => _error = tr('Không mở được cổng nhận trên máy tính: {0}', ['$e']));
    }
  }

  /// Mã mới (nonce + khoá mới) mỗi 2 phút; mã cũ hết hiệu lực.
  void _renew() {
    final r = Random.secure();
    setState(() {
      _left = _ttl;
      _payload = QrLoginPayload(
        server: widget.server,
        host: _host!,
        port: _sock!.port,
        nonce: _b64(List.generate(16, (_) => r.nextInt(256))),
        key: List.generate(32, (_) => r.nextInt(256)),
        device: Platform.localHostname,
      );
    });
  }

  Future<void> _onClient(Socket s) async {
    String reply(Map<String, dynamic> m) => '${jsonEncode(m)}\n';
    try {
      final line = await utf8.decoder.bind(s).transform(const LineSplitter()).first.timeout(const Duration(seconds: 10));
      final m = (jsonDecode(line) as Map).cast<String, dynamic>();
      final p = _payload;
      if (_done || p == null || m['n'] != p.nonce) {
        s.write(reply({'ok': false, 'error': 'expired'}));
        return;
      }
      final box = SecretBox(_unb64(m['ct'] as String), nonce: _unb64(m['iv'] as String), mac: Mac(_unb64(m['mac'] as String)));
      final clear = await _aes.decrypt(box, secretKey: SecretKey(p.key));
      final data = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
      final token = data['token'] as String?;
      if (token == null || token.isEmpty) {
        s.write(reply({'ok': false, 'error': 'bad'}));
        return;
      }
      _done = true;
      s.write(reply({'ok': true, 'device': p.device}));
      await s.flush();
      _timer?.cancel();
      await _sock?.close();
      if (mounted) {
        Navigator.of(context).pop();
        final server = (data['server'] as String?) ?? widget.server;
        widget.onToken(token, server, (data['server_name'] as String?) ?? Uri.parse(server).host);
      }
    } catch (_) {
      try {
        s.write(reply({'ok': false, 'error': 'bad'}));
      } catch (_) {}
    } finally {
      await s.close().catchError((_) => s);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sock?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final p = _payload;
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text(tr('Đăng nhập bằng QR'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_error != null)
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent))
            else if (p == null)
              const CircularProgressIndicator()
            else ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: QrImageView(data: p.encode(), size: 260, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 20),
              Text(tr('Mở Flygo Chat trên điện thoại → Apps → "QR login" rồi quét mã này.'),
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: pal.text)),
              const SizedBox(height: 8),
              Text(tr('Điện thoại và máy tính phải cùng mạng LAN. Mã đổi sau {0} giây.', [_left]),
                  textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
              const SizedBox(height: 4),
              Text('${Uri.parse(widget.server).host} · ${p.host}', style: TextStyle(fontSize: 12.5, color: pal.sub)),
            ],
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- điện thoại: quét QR, xác nhận, gửi token
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _ctl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _handling = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_handling) return;
    final raw = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    final p = raw == null ? null : QrLoginPayload.parse(raw);
    if (p == null) return;
    _handling = true;
    await _ctl.stop();
    final ok = await _confirmAndSend(p);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      _handling = false;
      await _ctl.start();
    }
  }

  Future<bool> _confirmAndSend(QrLoginPayload p) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final pal = Pal.of(context);
    final me = app.me;
    if (me == null) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: Icon(Icons.computer_rounded, color: pal.accentText, size: 36),
        title: Text(tr('Đăng nhập trên máy tính?')),
        content: Text(tr('Máy: {0}\nĐịa chỉ: {1}\nTài khoản: {2} (@{3})\nMáy chủ: {4}\n\nChỉ xác nhận nếu chính bạn đang đứng trước máy tính này.',
            [p.device.isEmpty ? tr('(không rõ tên)') : p.device, p.host, me.displayName, me.username, Uri.parse(kServerUrl).host])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Xác nhận'))),
        ],
      ),
    );
    if (go != true) return false;
    try {
      // 1. Trạm đẩy tạo token đăng nhập riêng cho máy tính.
      final r = await http
          .post(Uri.parse('${pushUrlFor(kServerUrl)}/qr/token'),
              headers: {
                'Authorization': 'Bearer ${app.token}',
                'X-MM-Server': kServerUrl,
                'Content-Type': 'application/json',
                'User-Agent': kUserAgent,
              },
              body: jsonEncode({'device': p.device, 'ip': p.host}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        // Trạm đẩy trả lỗi tiếng Việt {"error": "..."} (quá 5 token, quá nhiều lần, …): hiện nguyên văn.
        String? msg;
        try {
          msg = (jsonDecode(r.body) as Map)['error'] as String?;
        } catch (_) {}
        messenger.showSnackBar(toast(Text(msg ?? tr('Không đăng nhập được. Kiểm tra kết nối mạng và thử lại.'))));
        return false;
      }
      final token = (jsonDecode(r.body) as Map)['token'] as String;
      // 2. Mã hoá rồi gửi thẳng tới máy tính qua LAN (TCP, một dòng JSON).
      // Gửi kèm máy chủ của điện thoại: máy tính tự chuyển sang máy chủ này rồi đăng nhập (không phải chọn tay).
      final box = await _aes.encrypt(
          utf8.encode(jsonEncode({'token': token, 'server': kServerUrl, 'server_name': ServerList.currentEntry.name})),
          secretKey: SecretKey(p.key));
      final s = await Socket.connect(p.host, p.port, timeout: const Duration(seconds: 6));
      s.write('${jsonEncode({'n': p.nonce, 'iv': _b64(box.nonce), 'ct': _b64(box.cipherText), 'mac': _b64(box.mac.bytes)})}\n');
      await s.flush();
      final line = await utf8.decoder.bind(s).transform(const LineSplitter()).first.timeout(const Duration(seconds: 10));
      s.destroy();
      final res = (jsonDecode(line) as Map).cast<String, dynamic>();
      if (res['ok'] != true) {
        if (mounted) await _showError(tr('Mã QR đã hết hạn. Quét lại mã mới trên máy tính.'), 'pc: ${res['error']}');
        return false;
      }
      messenger.showSnackBar(toast(Text(tr('Đã đăng nhập trên {0}.', [p.device])), icon: Icons.check_circle_rounded));
      return true;
    } on SocketException catch (e) {
      // Ghi rõ lỗi (vd. "No route to host" = Wi-Fi chặn máy với máy, "Operation not permitted" = Android chặn mạng nội bộ).
      if (mounted) {
        await _showError(tr('Không kết nối được tới máy tính {0}:{1}. Điện thoại và máy tính phải cùng mạng LAN.', [p.host, p.port]),
            '${e.osError?.message ?? e.message} (${e.osError?.errorCode ?? '-'})');
      }
      return false;
    } on TimeoutException {
      if (mounted) {
        await _showError(tr('Máy tính {0}:{1} không trả lời. Có thể Wi-Fi đang chặn các máy kết nối với nhau.', [p.host, p.port]), 'timeout');
      }
      return false;
    } catch (e) {
      if (mounted) await _showError(tr('Không đăng nhập được. Kiểm tra kết nối mạng và thử lại.'), '$e');
      return false;
    }
  }

  Future<void> _showError(String msg, String detail) => showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr('Đăng nhập bằng QR không thành công')),
          content: SelectableText('$msg\n\n$detail'),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Đóng')))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(tr('QR login')), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Stack(children: [
        MobileScanner(controller: _ctl, onDetect: _onDetect),
        Center(
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(24)),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(tr('Quét mã QR trên màn đăng nhập của máy tính (cùng mạng LAN).'),
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      ]),
    );
  }
}
