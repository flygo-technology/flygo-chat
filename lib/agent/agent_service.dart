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
  /// Vai trò / chuyên môn (phần đầu mô tả bot, trước " · chạy …"), vd. "Kế toán – xử lý hoá đơn VAT".
  final String role;
  AgentBot(this.id, this.username, this.displayName, this.engine, [this.allow = const [], this.host, this.role = '']);
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

  /// File chạy runner đóng gói sẵn trong app (cạnh file chạy của app; macOS: Contents/Resources) và file
  /// ghi phiên bản đi kèm "flygo-agent.version". null nếu bản app này không đóng gói runner.
  static String? get bundledPath {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final name = 'flygo-agent${Platform.isWindows ? '.exe' : ''}';
    return [
      '$exeDir$_sep$name',
      if (Platform.isMacOS) '$exeDir$_sep..${_sep}Resources$_sep$name',
      if (Platform.isLinux) '$exeDir${_sep}lib$_sep$name',
    ].where((p) => File(p).existsSync()).firstOrNull;
  }

  static String? _readVersion(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync().trim() : null;
    } catch (_) {
      return null;
    }
  }

  static String _bundledVersionOf(String bin) =>
      _readVersion('${File(bin).parent.path}${_sep}flygo-agent.version') ?? '';

  /// So sánh phiên bản "a.b.c": > 0 nếu [a] mới hơn [b].
  static int _cmpVer(String a, String b) {
    List<int> p(String v) => v.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  /// Đảm bảo có file chạy runner ở chỗ cố định (dịch vụ nền chạy từ đây). Ưu tiên bản đóng gói trong app:
  /// chưa có hoặc bản đóng gói mới hơn bản đã cài thì chép sang (file tạm + đổi tên — chép đè lên file đang chạy
  /// trên macOS sẽ làm tiến trình bị giết). App không đóng gói runner thì mới tải về.
  /// Trả về đường dẫn; [onUpdated] được gọi nếu vừa thay bằng bản mới hơn.
  Future<String> ensureBinary({void Function(String)? onStatus, void Function()? onUpdated}) async {
    final installed = File(binPath);
    final verFile = '$binPath.version';
    final bundled = bundledPath;
    final bVer = bundled == null ? '' : _bundledVersionOf(bundled);
    final iVer = _readVersion(verFile) ?? '';
    final needCopy = bundled != null && (!installed.existsSync() || (bVer.isNotEmpty && _cmpVer(bVer, iVer) > 0));
    if (installed.existsSync() && !needCopy) return binPath;
    await installed.parent.create(recursive: true);
    final tmp = File('$binPath.tmp');
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
    final existed = installed.existsSync();
    if (Platform.isWindows && existed) {
      // Windows không đổi tên đè lên file đang chạy: dời file cũ sang bên cạnh trước.
      final old = File('$binPath.old');
      try {
        if (old.existsSync()) old.deleteSync();
        installed.renameSync(old.path);
      } catch (_) {}
    }
    await tmp.rename(binPath);
    if (bVer.isNotEmpty) await File(verFile).writeAsString(bVer);
    if (existed) onUpdated?.call();
    return binPath;
  }

  /// Mở app (máy tính): runner đóng gói trong app mới hơn bản đang cài → thay, rồi khởi động lại các trợ lý
  /// đang chạy nền trên máy này để dùng bản mới. Không cần cài gì bên ngoài.
  Future<void> syncBundledRunner() async {
    if (!isDesktop || bundledPath == null) return;
    var updated = false;
    try {
      await ensureBinary(onUpdated: () => updated = true);
    } catch (e) {
      debugPrint('[agent] sync runner: $e');
      return;
    }
    if (!updated) return;
    final dir = Directory('$_home$_sep.config${_sep}flygo-agent');
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>().where((f) => RegExp(r'config-.+\.json$').hasMatch(f.path))) {
      try {
        final st = await Process.run(binPath, ['service-status', '--config', f.path]);
        final j = jsonDecode(st.stdout.toString().trim().split('\n').last);
        if (j is Map && j['installed'] == true) await Process.run(binPath, ['install-service', '--config', f.path]);
      } catch (_) {}
    }
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
          _attr(attrs, 'host'), _roleOf(m['description'] as String? ?? '')));
    }
    app.setMyAgents(out.map((b) => b.id));
    return out;
  }

  static String _roleOf(String desc) {
    final i = desc.indexOf(' · chạy ');
    if (i <= 0) return '';
    final r = desc.substring(0, i).trim();
    return r == 'Trợ lý AI' ? '' : r;
  }

  /// Kỹ năng của trợ lý trên máy này (CLI `flygo-agent skills --bot <id> --json`); null nếu không đọc được.
  Future<Map<String, dynamic>?> skillsOf(AgentBot bot) async {
    if (!isDesktop) return null;
    try {
      final bin = await ensureBinary();
      final cfg = File(configPath(bot.username));
      final r = await Process.run(bin, ['skills', '--bot', bot.id, if (cfg.existsSync()) ...['--config', cfg.path], '--json'])
          .timeout(const Duration(seconds: 20));
      return (jsonDecode(r.stdout.toString().trim().split('\n').last) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Đặt vai trò của trợ lý: phần đầu mô tả bot (trước " · chạy …") + mốc `role=<slug>`.
  Future<void> setRole(AppState app, AgentBot bot, String role) async {
    final b = (await app.api.get('/bots/${bot.id}') as Map).cast<String, dynamic>();
    final desc = b['description'] as String? ?? '';
    final r = role.trim();
    final i = desc.indexOf(' · chạy ');
    final rest = i > 0 ? desc.substring(i) : ' · ${desc.replaceAll(_marker, '').trim()}';
    final next = '${r.isEmpty ? 'Trợ lý AI' : r}$rest'.replaceAll(_marker, '').trim();
    final m = _marker.firstMatch(desc);
    await app.api.put('/bots/${bot.id}', {'description': '$next ${m?.group(0) ?? '[flygo-agent engine=${bot.engine}]'}'});
    final slug = r.isEmpty
        ? ''
        : r.split(RegExp(r'[—:,–-]')).first.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    await _setMarkerAttrs(app, bot, {'role': slug.length > 24 ? slug.substring(0, 24) : slug});
  }

  /// Tạo trợ lý: một máy có thể có nhiều trợ lý cùng loại AI, mỗi trợ lý một vai trò / kỹ năng riêng
  /// (vd. @ketoan xử lý hoá đơn, @android-dev phát hành APK). [role] ghi vào mốc `role=` và mô tả bot.
  Future<AgentBot> createBot(AppState app, String engine, {String? username, String? displayName, String? role}) async {
    final me = app.me!;
    final label = engine == 'claude' ? 'Claude' : 'Codex';
    var un = (username?.trim().isNotEmpty == true ? username! : '${me.username}-$engine')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]'), '-');
    if (un.length > 22) un = un.substring(0, 22);
    final name = displayName?.trim().isNotEmpty == true ? displayName!.trim() : '$label của ${me.displayName}';
    final r = role?.trim() ?? '';
    final slug = r.isEmpty
        ? ''
        : r.toLowerCase().replaceAll(RegExp(r'[^a-z0-9à-ỹđ]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final desc = '${r.isEmpty ? 'Trợ lý AI' : r} · chạy $label trên máy của ${me.displayName} '
        '[flygo-agent engine=$engine${slug.isEmpty ? '' : ' role=$slug'}]';
    final res = (await app.api.post('/bots', {'username': un, 'display_name': name, 'description': desc}) as Map)
        .cast<String, dynamic>();
    return AgentBot(res['user_id'] as String, un, name, engine);
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

  /// Chuẩn hoá tên máy giống runner (normHost): bỏ khoảng trắng hai đầu, chữ thường, bỏ đuôi ".local",
  /// khoảng trắng / "]" thành "-".
  static String normHost(String h) =>
      h.trim().toLowerCase().replaceFirst(RegExp(r'\.local$'), '').replaceAll(RegExp(r'[\s\]]'), '-');

  /// Tên máy này dùng để gắn trợ lý.
  static String get thisHost => normHost(Platform.localHostname);

  /// Trợ lý gắn với máy này?
  static bool isHere(AgentBot b) => b.host != null && normHost(b.host!) == thisHost;

  /// Xoá trợ lý: gỡ chạy nền ở máy này (nếu có) rồi tắt bot trên máy chủ (Mattermost không xoá hẳn bot).
  Future<void> deleteBot(AppState app, AgentBot bot) async {
    if (isDesktop && await serviceInstalled(bot)) {
      try {
        await uninstallService(bot);
      } catch (_) {}
    }
    await app.api.post('/bots/${bot.id}/disable', {});
  }

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
  /// Có runner đang chạy cho bot này trên máy (khoá `runner-<id bot>.lock` còn tiến trình sống)?
  /// Dùng id thay vì tên: đổi tên bot thì dịch vụ cũ (đặt theo tên cũ) vẫn được nhận ra, không cài trùng.
  static bool runningLocally(AgentBot bot) {
    try {
      final f = File('$_home$_sep.config${_sep}flygo-agent${_sep}runner-${bot.id}.lock');
      if (!f.existsSync()) return false;
      final pid = int.tryParse(f.readAsStringSync().trim());
      if (pid == null) return false;
      if (Platform.isWindows) {
        final r = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
        return r.stdout.toString().contains('$pid');
      }
      return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> serviceInstalled(AgentBot bot) async {
    if (runningLocally(bot)) return true;
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
