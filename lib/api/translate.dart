import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';

String get _home => Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';

bool? _hasAiCli;

/// Máy này có Claude Code hoặc Codex CLI không (nút "Dịch AI" chỉ hiện trên máy có): tìm trong PATH và các chỗ cài
/// thường gặp (app macOS không nhận PATH của shell). Điện thoại / web: không.
Future<bool> machineHasAiCli() async {
  if (_hasAiCli != null) return _hasAiCli!;
  if (!isDesktop) return _hasAiCli = false;
  final sep = Platform.pathSeparator;
  final names = Platform.isWindows ? ['claude.exe', 'claude.cmd', 'codex.exe', 'codex.cmd'] : ['claude', 'codex'];
  final dirs = <String>{
    ...(Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':').where((d) => d.isNotEmpty),
    '$_home$sep.local${sep}bin',
    '$_home$sep.claude${sep}local',
    '$_home$sep.bun${sep}bin',
    if (!Platform.isWindows) ...['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'],
    if (Platform.isWindows) ...['${Platform.environment['APPDATA']}${sep}npm', '${Platform.environment['LOCALAPPDATA']}${sep}Programs${sep}claude'],
  };
  for (final d in dirs) {
    for (final n in names) {
      if (File('$d$sep$n').existsSync()) return _hasAiCli = true;
    }
  }
  return _hasAiCli = false;
}

/// Runner trợ lý AI đang chạy trên máy này, của [myId], cùng máy chủ: tệp `~/.config/flygo-agent/local-<bot>.json`
/// ({port, key, server, owners, engine}) do runner ghi lúc chạy. Claude trước (nhanh hơn Codex).
List<Map<String, dynamic>> _localRunners(String myId) {
  final sep = Platform.pathSeparator;
  final dir = Directory('$_home$sep.config${sep}flygo-agent');
  if (!isDesktop || !dir.existsSync()) return const [];
  final out = <Map<String, dynamic>>[];
  for (final f in dir.listSync().whereType<File>().where((f) => RegExp(r'local-[^/\\]+\.json$').hasMatch(f.path))) {
    try {
      final j = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      if (j['server'] == kServerUrl && (j['owners'] as List? ?? const []).contains(myId)) out.add(j);
    } catch (_) {}
  }
  out.sort((a, b) => (a['engine'] == 'claude' ? 0 : 1) - (b['engine'] == 'claude' ? 0 : 1));
  return out;
}

/// Dịch [text] sang ngôn ngữ [to] (vi, en, ko, ja, th, zh…). Máy tính: gọi thẳng runner trợ lý AI của mình trên máy này
/// (Claude / Codex, tin không rời máy). Không được thì qua trạm đẩy (`POST /translate`): bot của chính mình đang chạy ở
/// máy khác, cuối cùng Google Dịch. Xác thực trạm bằng phiên Mattermost; chỉ dùng trạm của chính máy chủ đang chat.
/// Trả về bản dịch và mã ngôn ngữ gốc đoán được.
Future<({String text, String from})> translateText(String token, String text, String to, {String myId = ''}) async {
  for (final r in myId.isEmpty ? const <Map<String, dynamic>>[] : _localRunners(myId)) {
    try {
      final res = await http
          .post(Uri.parse('http://127.0.0.1:${r['port']}/translate'),
              headers: {'x-flygo-key': '${r['key']}', 'Content-Type': 'application/json'},
              body: jsonEncode({'text': text, 'to': to, 'user': myId}))
          .timeout(Duration(seconds: r['engine'] == 'claude' ? 35 : 70));
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      if (j['ok'] == true && '${j['text']}'.trim().isNotEmpty) return (text: '${j['text']}', from: '${j['from'] ?? ''}');
    } catch (_) {}
  }
  Future<http.Response> call(String base) => http
      .post(Uri.parse('$base/translate'),
          headers: {
            'Authorization': 'Bearer $token',
            'X-MM-Server': kServerUrl,
            'Content-Type': 'application/json',
            'User-Agent': kUserAgent,
          },
          body: jsonEncode({'text': text, 'to': to}))
      .timeout(const Duration(seconds: 25));
  final r = await call(pushUrlFor(kServerUrl));
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
  if (r.statusCode != 200) throw HttpException('${j['error'] ?? 'translate ${r.statusCode}'}');
  return (text: '${j['text']}', from: '${j['from'] ?? ''}');
}

/// Tin song ngữ (nút "Dịch AI"): props.flygo_bilingual = {v:1, langs:[gốc, dịch], texts:[bản gốc, bản dịch]}.
/// Nội dung tin (message) là bản gốc + dòng kẻ + bản dịch, để app khác vẫn đọc được cả hai.
const kBilingualRule = '───';

({List<String> langs, List<String> texts})? bilingualOf(Map<String, dynamic> props) {
  final b = props['flygo_bilingual'];
  if (b is! Map) return null;
  final langs = [for (final x in (b['langs'] as List? ?? const [])) '$x'];
  final texts = [for (final x in (b['texts'] as List? ?? const [])) '$x'];
  if (langs.length != 2 || texts.length != 2) return null;
  return (langs: langs, texts: texts);
}
