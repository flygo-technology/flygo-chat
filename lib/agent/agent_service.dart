import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../state/app_state.dart';

/// Bot trợ lý AI của mình (bot Mattermost có mốc "[flygo-agent engine=…]" trong mô tả).
class AgentBot {
  final String id; // user_id của bot
  final String username;
  final String displayName;
  final String engine; // codex | claude
  /// Người khác được gọi bot (ngoài chủ bot), lưu trong mốc mô tả: allow=id1,id2.
  final List<String> allow;
  /// Máy mà trợ lý gắn cố định (mốc host=…); null = chưa gắn máy nào.
  final String? host;
  AgentBot(this.id, this.username, this.displayName, this.engine, [this.allow = const [], this.host]);
}

/// Trạng thái runner chạy trong app cho một bot.
class RunnerState {
  String phase = 'stopped'; // stopped | starting | running | error
  String? errorCode;
  String? errorMessage;
  String? errorEngine;
  int activeRuns = 0;
  Process? process;
}

/// Điều khiển runner flygo-agent (máy tính): kiểm tra máy, bot của tôi, bật/tắt runner, dịch vụ nền.
/// Mỗi bot gắn cố định một engine; mỗi bot một tiến trình runner.
class AgentService extends ChangeNotifier {
  AgentService._();
  static final instance = AgentService._();

  /// Mốc trong mô tả bot: "[flygo-agent engine=codex allow=id1,id2]".
  static final _marker = RegExp(r'\[flygo-agent([^\]]*)\]');
  static String? _attr(String attrs, String key) => RegExp('$key=([\\w,]+)').firstMatch(attrs)?.group(1);
  static const downloadBase = 'https://chat.flygo.vn/static/plugins/flygo-agent';

  final Map<String, RunnerState> runners = {};
  Map<String, dynamic>? doctor;

  static String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  static String get _sep => Platform.pathSeparator;
  static String get binPath =>
      '$_home$_sep.local${_sep}share${_sep}flygo-agent${_sep}flygo-agent${Platform.isWindows ? '.exe' : ''}';
  static String configPath(String botUsername) => '$_home$_sep.config${_sep}flygo-agent${_sep}config-$botUsername.json';

  static Future<String> _platformName() async {
    if (Platform.isWindows) return 'windows-x64.exe';
    final arch = (await Process.run('uname', ['-m'])).stdout.toString().trim();
    final a = arch == 'arm64' || arch == 'aarch64' ? 'arm64' : 'x64';
    return '${Platform.isMacOS ? 'darwin' : 'linux'}-$a';
  }

  /// Đảm bảo có file chạy runner: bản đã cài → bản đi kèm app → tải về. Cập nhật bằng file tạm + đổi tên
  /// (chép đè lên file đang chạy trên macOS sẽ làm tiến trình bị giết).
  Future<String> ensureBinary({void Function(String)? onStatus}) async {
    if (File(binPath).existsSync()) return binPath;
    final dir = File(binPath).parent;
    await dir.create(recursive: true);
    final tmp = File('$binPath.tmp');
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = [
      '$exeDir${_sep}flygo-agent${Platform.isWindows ? '.exe' : ''}',
      if (Platform.isMacOS) '$exeDir$_sep..${_sep}Resources${_sep}flygo-agent',
    ].where((p) => File(p).existsSync()).firstOrNull;
    if (bundled != null) {
      await File(bundled).copy(tmp.path);
    } else {
      onStatus?.call('download');
      final r = await http.get(Uri.parse('$downloadBase/flygo-agent-${await _platformName()}'));
      if (r.statusCode != 200 || r.bodyBytes.length < 1000000) {
        throw Exception('Không tải được trình chạy trợ lý (HTTP ${r.statusCode}).');
      }
      await tmp.writeAsBytes(r.bodyBytes, flush: true);
    }
    if (!Platform.isWindows) await Process.run('chmod', ['755', tmp.path]);
    await tmp.rename(binPath);
    return binPath;
  }

  // ---------------------------------------------------------------- kiểm tra máy
  Future<Map<String, dynamic>?> loadDoctor() async {
    try {
      final bin = await ensureBinary();
      final r = await Process.run(bin, ['doctor', '--json']).timeout(const Duration(seconds: 40));
      doctor = (jsonDecode(r.stdout.toString().trim().split('\n').last) as Map).cast<String, dynamic>();
    } catch (e) {
      debugPrint('[agent] doctor: $e');
      doctor = null;
    }
    notifyListeners();
    return doctor;
  }

  /// Đăng nhập Codex / Claude trên máy này (mở trình duyệt).
  Future<void> login(String engine) async {
    final args = engine == 'claude' ? ['auth', 'login'] : ['login'];
    final exe = (doctor?[engine] as Map?)?['path'] as String? ?? engine;
    await Process.start(exe, args, mode: ProcessStartMode.detached);
  }

  // ---------------------------------------------------------------- bot của tôi
  Future<List<AgentBot>> myBots(AppState app) async {
    final r = await app.api.get('/bots', {'per_page': '200'}) as List;
    final out = <AgentBot>[];
    for (final e in r) {
      final m = (e as Map).cast<String, dynamic>();
      if (m['owner_id'] != app.me?.id || (m['delete_at'] as num? ?? 0) != 0) continue;
      final mk = _marker.firstMatch(m['description'] as String? ?? '');
      if (mk == null) continue;
      final attrs = mk.group(1) ?? '';
      out.add(AgentBot(m['user_id'] as String, m['username'] as String, m['display_name'] as String? ?? '',
          _attr(attrs, 'engine') ?? 'codex', (_attr(attrs, 'allow') ?? '').split(',').where((s) => s.isNotEmpty).toList(),
          _attr(attrs, 'host')));
    }
    return out;
  }

  Future<AgentBot> createBot(AppState app, String engine) async {
    final me = app.me!;
    final label = engine == 'claude' ? 'Claude' : 'Codex';
    var username = '${me.username}-$engine'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]'), '-');
    if (username.length > 22) username = username.substring(0, 22);
    final r = (await app.api.post('/bots', {
      'username': username,
      'display_name': '$label của ${me.displayName}',
      'description': 'Trợ lý AI chạy $label trên máy của ${me.displayName} [flygo-agent engine=$engine]',
    }) as Map).cast<String, dynamic>();
    return AgentBot(r['user_id'] as String, username, '$label của ${me.displayName}', engine);
  }

  /// Sửa một vài thuộc tính trong mốc [flygo-agent …] của mô tả bot, giữ nguyên các thuộc tính khác
  /// (models, efforts, default…). Giá trị null/rỗng = bỏ thuộc tính.
  Future<void> _setMarkerAttrs(AppState app, AgentBot bot, Map<String, String?> attrs) async {
    final b = (await app.api.get('/bots/${bot.id}') as Map).cast<String, dynamic>();
    final desc = b['description'] as String? ?? '';
    final m = _marker.firstMatch(desc);
    final cur = <String, String>{'engine': bot.engine};
    for (final x in RegExp(r'([a-z_]+)=([^\s\]]+)').allMatches(m?.group(1) ?? '')) {
      cur[x.group(1)!] = x.group(2)!;
    }
    attrs.forEach((k, v) => v == null || v.isEmpty ? cur.remove(k) : cur[k] = v);
    final marker = '[flygo-agent ${cur.entries.map((e) => '${e.key}=${e.value}').join(' ')}]';
    final next = m != null ? desc.replaceFirst(_marker, marker) : '$desc $marker'.trim();
    await app.api.put('/bots/${bot.id}', {'description': next});
  }

  /// Đặt danh sách người được gọi bot (ngoài chủ bot): ghi vào mốc trong mô tả bot.
  Future<void> setAllowed(AppState app, AgentBot bot, List<String> userIds) =>
      _setMarkerAttrs(app, bot, {'allow': userIds.join(',')});

  /// Tên máy này dùng để gắn trợ lý (không dấu cách).
  static String get thisHost => Platform.localHostname.replaceAll(RegExp(r'[\s\]]'), '-');

  /// Gắn cứng trợ lý với máy này (hoặc bỏ gắn khi [bind] = false).
  Future<void> bindHost(AppState app, AgentBot bot, bool bind) => _setMarkerAttrs(app, bot, {'host': bind ? thisHost : null});

  // Token của bot trên máy này (mỗi máy một token), lưu trong thư mục dữ liệu của app.
  Future<File> _tokenFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${_sep}agent_tokens_$serverKey.json');
  }

  Future<String> botToken(AppState app, AgentBot bot) async {
    final f = await _tokenFile();
    final all = f.existsSync() ? (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>() : <String, dynamic>{};
    final saved = all[bot.id] as String?;
    if (saved != null) return saved;
    final host = Platform.localHostname;
    final t = (await app.api.post('/users/${bot.id}/tokens', {'description': 'flygo-agent $host'}) as Map)
        .cast<String, dynamic>();
    all[bot.id] = t['token'] as String;
    await f.writeAsString(jsonEncode(all), flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
    return t['token'] as String;
  }

  Map<String, dynamic> _config(AppState app, AgentBot bot, String token) =>
      {'serverUrl': kServerUrl, 'botToken': token, 'ownerUserIds': [app.me!.id], 'engine': bot.engine};

  // ---------------------------------------------------------------- chạy trong app
  RunnerState stateOf(String botId) => runners.putIfAbsent(botId, RunnerState.new);

  Future<void> start(AppState app, AgentBot bot, {bool takeover = false}) async {
    final st = stateOf(bot.id);
    if (st.process != null) return;
    st
      ..phase = 'starting'
      ..errorCode = null
      ..errorMessage = null;
    notifyListeners();
    try {
      final bin = await ensureBinary();
      final token = await botToken(app, bot);
      final p = await Process.start(bin, ['run', '--config-stdin', '--json', if (takeover) '--takeover']);
      st.process = p;
      p.stdin.write(jsonEncode(_config(app, bot, token)));
      await p.stdin.close();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) => _onEvent(st, line));
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => debugPrint('[agent ${bot.username}] $l'));
      p.exitCode.then((_) {
        st.process = null;
        if (st.phase != 'error') st.phase = 'stopped';
        st.activeRuns = 0;
        notifyListeners();
      });
    } catch (e) {
      st
        ..phase = 'error'
        ..errorCode = 'fatal'
        ..errorMessage = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  void _onEvent(RunnerState st, String line) {
    Map<String, dynamic> e;
    try {
      e = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (e['event'] ?? e['type']) {
      case 'ready' || 'connected' || 'took_over':
        st.phase = 'running';
      case 'run_started':
        st.activeRuns++;
      case 'run_finished':
        st.activeRuns = (st.activeRuns - 1).clamp(0, 999);
      case 'stopped':
        st.phase = 'stopped';
      case 'error':
        st
          ..phase = 'error'
          ..errorCode = e['code'] as String?
          ..errorMessage = e['message'] as String?
          ..errorEngine = e['engine'] as String?;
    }
    notifyListeners();
  }

  Future<void> stop(String botId) async {
    final p = runners[botId]?.process;
    if (p == null) return;
    Platform.isWindows ? p.kill() : p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 8), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }

  /// Thoát app: dừng mọi runner đang chạy trong app (runner tự đưa bot về offline).
  Future<void> stopAll() => Future.wait([for (final id in runners.keys) stop(id)]);

  // ---------------------------------------------------------------- chạy nền khi đăng nhập máy
  Future<bool> serviceInstalled(AgentBot bot) async {
    try {
      final r = await Process.run(await ensureBinary(), ['service-status', '--config', configPath(bot.username)]);
      final j = jsonDecode(r.stdout.toString().trim().split('\n').last);
      return j is Map && (j['installed'] == true || j['running'] == true);
    } catch (_) {
      return false;
    }
  }

  Future<void> installService(AppState app, AgentBot bot) async {
    final bin = await ensureBinary();
    final f = File(configPath(bot.username));
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(_config(app, bot, await botToken(app, bot))), flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
    final r = await Process.run(bin, ['install-service', '--config', f.path]);
    if (r.exitCode != 0) throw Exception(r.stderr.toString().trim().split('\n').last);
  }

  Future<void> uninstallService(AgentBot bot) async {
    final r = await Process.run(await ensureBinary(), ['uninstall-service', '--config', configPath(bot.username)]);
    if (r.exitCode != 0) throw Exception(r.stderr.toString().trim().split('\n').last);
  }
}
