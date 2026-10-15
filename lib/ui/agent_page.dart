import '../i18n/i18n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Trang "Trợ lý AI": kiểm tra máy (Codex / Claude), bot trợ lý của tôi, công tắc
/// "Dùng máy này làm trợ lý" (máy tính) và "Chạy nền khi đăng nhập máy".
class AgentPage extends StatefulWidget {
  const AgentPage({super.key});
  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  final svc = AgentService.instance;
  List<AgentBot>? _bots;
  final Map<String, bool> _service = {};
  final Map<String, ({String status, String text})> _remote = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    svc.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    svc.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Đổi tên hiển thị và tên người dùng (@username) của trợ lý.
  Future<void> _renameBot(AgentBot b) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final nameCtl = TextEditingController(text: b.displayName);
    final userCtl = TextEditingController(text: b.username);
    final re = RegExp(r'^[a-z][a-z0-9._-]{2,21}$');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final un = userCtl.text.trim().toLowerCase();
        final unError = un.isEmpty || re.hasMatch(un) ? null : tr('3–22 ký tự, bắt đầu bằng chữ, chỉ gồm a-z, 0-9, dấu . - _');
        return AlertDialog(
          title: Text(tr('Đổi tên trợ lý')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              autofocus: true,
              maxLength: 64,
              decoration: InputDecoration(labelText: tr('Tên hiển thị')),
            ),
            TextField(
              controller: userCtl,
              maxLength: 22,
              autocorrect: false,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(labelText: tr('Tên người dùng'), prefixText: '@', errorText: unError),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Hủy'))),
            FilledButton(onPressed: un.isEmpty || unError != null ? null : () => Navigator.pop(ctx, true), child: Text(tr('Lưu'))),
          ],
        );
      }),
    );
    final name = nameCtl.text.trim(), username = userCtl.text.trim().toLowerCase();
    nameCtl.dispose();
    userCtl.dispose();
    if (ok != true || (name == b.displayName && username == b.username)) return;
    try {
      await app.api.put('/bots/${b.id}', {
        'username': username,
        'display_name': name.isEmpty ? b.displayName : name,
      });
      await app.refreshUser(b.id);
      await _load();
    } catch (e) {
      final taken = e.toString().contains('exists') || e.toString().contains('taken');
      messenger.showSnackBar(SnackBar(
          content: Text(taken ? tr('Tên người dùng này đã có người dùng.') : tr('Không đổi được tên trợ lý. Kiểm tra kết nối mạng.'))));
    }
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final bots = await svc.myBots(app);
      if (!mounted) return;
      setState(() => _bots = bots);
      _loadRemote(app, bots);
      if (isDesktop) {
        svc.loadDoctor();
        for (final b in bots) {
          svc.serviceInstalled(b).then((v) {
            if (mounted) setState(() => _service[b.id] = v);
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = tr('Không tải được danh sách trợ lý.'));
    }
  }

  /// Trạng thái bot trên máy chủ (đang chạy ở máy nào), xem được cả trên điện thoại.
  Future<void> _loadRemote(AppState app, List<AgentBot> bots) async {
    if (bots.isEmpty) return;
    try {
      final ids = [for (final b in bots) b.id];
      final st = await app.api.post('/users/status/ids', ids) as List;
      final users = await app.api.post('/users/ids', ids) as List;
      final statusById = {for (final e in st) (e as Map)['user_id'] as String: e['status'] as String};
      for (final u in users) {
        final m = (u as Map).cast<String, dynamic>();
        final raw = (m['props'] as Map?)?['customStatus'];
        var text = '';
        if (raw is String && raw.isNotEmpty) {
          try {
            final c = (jsonDecode(raw) as Map).cast<String, dynamic>();
            final exp = DateTime.tryParse(c['expires_at'] as String? ?? '');
            if (exp == null || exp.isAfter(DateTime.now()) || exp.year < 2000) text = c['text'] as String? ?? '';
          } catch (_) {}
        }
        _remote[m['id'] as String] = (status: statusById[m['id']] ?? 'offline', text: text);
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _create() async {
    final app = context.read<AppState>();
    final engine = await showDialog<String>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text(tr('Tạo trợ lý AI')),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(tr('Mỗi trợ lý chạy cố định một loại AI. Muốn dùng cả hai thì tạo hai trợ lý.'),
                style: TextStyle(color: Pal.of(d).sub, fontSize: 13.5)),
          ),
          SimpleDialogOption(onPressed: () => Navigator.pop(d, 'codex'), child: const Text('Codex (OpenAI)')),
          SimpleDialogOption(onPressed: () => Navigator.pop(d, 'claude'), child: const Text('Claude (Anthropic)')),
        ],
      ),
    );
    if (engine == null) return;
    setState(() => _busy = true);
    try {
      await svc.createBot(app, engine);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Không tạo được trợ lý: {0}', ['$e']))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleRun(AgentBot b, bool on) async {
    final app = context.read<AppState>();
    if (!on) return svc.stop(b.id);
    await svc.start(app, b);
    // Bot đang chạy ở dịch vụ nền / app khác: hỏi chuyển sang chạy trong app.
    await Future.delayed(const Duration(seconds: 2));
    final st = svc.stateOf(b.id);
    if (st.errorCode == 'already_running' && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr('Trợ lý đang chạy ở nơi khác')),
          content: Text(tr('{0} đang chạy bằng dịch vụ nền hoặc ở cửa sổ khác. Chuyển sang chạy trong app này?', [b.displayName])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
            TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Chuyển sang app'))),
          ],
        ),
      );
      if (ok == true) {
        await svc.start(app, b, takeover: true);
        if (mounted) setState(() => _service[b.id] = false);
      }
    }
  }

  Future<void> _toggleService(AgentBot b, bool on) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (on) {
        // Đang chạy trong app thì dừng trước, dịch vụ nền sẽ chạy thay.
        await svc.stop(b.id);
        await svc.installService(app, b);
      } else {
        await svc.uninstallService(b);
      }
      final v = await svc.serviceInstalled(b);
      if (mounted) setState(() => _service[b.id] = v);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final bots = _bots;
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Trợ lý AI'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          actions: [IconButton(tooltip: tr('Tải lại'), icon: Icon(Icons.refresh, color: pal.text), onPressed: _load)],
        ),
        body: _error != null
            ? Center(child: Text(_error!, style: TextStyle(color: pal.sub)))
            : bots == null
                ? Center(child: CircularProgressIndicator(color: pal.accent))
                : ListView(padding: const EdgeInsets.all(16), children: [
                    if (isDesktop) ...[
                      _section(pal, tr('Máy này')),
                      _DoctorCard(doctor: svc.doctor, onLogin: (e) async {
                        await svc.login(e);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(tr('Đăng nhập trong trình duyệt vừa mở, xong bấm Tải lại.'))));
                      }),
                      const SizedBox(height: 18),
                    ],
                    _section(pal, tr('Trợ lý của tôi')),
                    if (bots.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(tr('Bạn chưa có trợ lý AI nào.'), style: TextStyle(color: pal.sub)),
                      ),
                    for (final b in bots)
                      _BotCard(
                        bot: b,
                        remote: _remote[b.id],
                        state: svc.runners[b.id],
                        service: _service[b.id] ?? false,
                        engineReady: (svc.doctor?[b.engine] as Map?)?['loggedIn'] == true,
                        onRun: (v) => _toggleRun(b, v),
                        onService: (v) => _toggleService(b, v),
                        onLogin: () => svc.login(b.engine),
                        onShare: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BotAccessPage(bot: b)));
                          _load();
                        },
                        onRename: () => _renameBot(b),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: pal.accentText,
                        side: BorderSide(color: pal.accentText),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _busy ? null : _create,
                      icon: const Icon(Icons.add),
                      label: Text(tr('Tạo trợ lý AI mới')),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      tr('Gọi trợ lý trong chat bằng @tên-trợ-lý kèm việc cần làm. Trợ lý chạy trên máy đang bật công tắc, dùng tài khoản Codex / Claude đã đăng nhập trên máy đó.'),
                      style: TextStyle(color: pal.sub, fontSize: 13),
                    ),
                  ]),
      ),
    );
  }

  Widget _section(Pal pal, String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(t.toUpperCase(), style: TextStyle(fontSize: 13, color: pal.sub, letterSpacing: .3)),
      );
}

class _DoctorCard extends StatelessWidget {
  final Map<String, dynamic>? doctor;
  final void Function(String engine) onLogin;
  const _DoctorCard({required this.doctor, required this.onLogin});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget row(String engine, String label) {
      final d = (doctor?[engine] as Map?)?.cast<String, dynamic>();
      final installed = d?['installed'] == true;
      final logged = d?['loggedIn'] == true;
      return ListTile(
        leading: Icon(logged ? Icons.check_circle : Icons.error_outline,
            color: logged ? const Color(0xFF2E9D5B) : (installed ? const Color(0xFFF5A623) : pal.sub)),
        title: Text(label, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
        subtitle: Text(
          doctor == null
              ? tr('Đang kiểm tra...')
              : !installed
                  ? tr('Chưa cài trên máy này')
                  : logged
                      ? '${d?['version'] ?? ''} · ${d?['account'] ?? ''}'
                      : tr('Chưa đăng nhập'),
          style: TextStyle(color: pal.sub, fontSize: 13),
        ),
        trailing: installed && !logged ? TextButton(onPressed: () => onLogin(engine), child: Text(tr('Đăng nhập'))) : null,
      );
    }

    return Container(
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
      child: Column(children: [row('codex', 'Codex'), Divider(height: 1, color: pal.divider), row('claude', 'Claude')]),
    );
  }
}

class _BotCard extends StatelessWidget {
  final AgentBot bot;
  final ({String status, String text})? remote;
  final RunnerState? state;
  final bool service;
  final bool engineReady;
  final ValueChanged<bool> onRun;
  final ValueChanged<bool> onService;
  final VoidCallback onLogin;
  final VoidCallback onShare;
  final VoidCallback onRename;
  const _BotCard({
    required this.onShare,
    required this.onRename,
    required this.bot,
    required this.remote,
    required this.state,
    required this.service,
    required this.engineReady,
    required this.onRun,
    required this.onService,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final st = state;
    final runningHere = st?.process != null && st?.phase != 'error';
    final online = remote?.status == 'online';
    final where = remote?.text ?? '';
    String line;
    if (runningHere) {
      line = st!.phase == 'starting'
          ? tr('Đang khởi động trên máy này...')
          : st.activeRuns > 0
              ? tr('Đang chạy trên máy này · đang làm {0} việc', [st.activeRuns])
              : tr('Đang chạy trên máy này');
    } else if (online && where.isNotEmpty) {
      line = where;
    } else {
      line = tr('Đang tắt');
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          EditableAvatar(
            size: 44,
            avatar: Avatar(userId: bot.id, name: bot.displayName, size: 44, icon: Icons.smart_toy_outlined, status: false),
            onPicked: (n, b) => context.read<AppState>().setUserImage(bot.id, n, b),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Tên trợ lý + nút sửa (đổi tên hiển thị và tên người dùng).
              Row(children: [
                Flexible(
                  child: nameText(bot.displayName, bot: true, engine: bot.engine, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
                ),
                IconButton(
                  tooltip: tr('Đổi tên trợ lý'),
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  icon: Icon(Icons.edit_outlined, size: 18, color: pal.sub),
                  onPressed: onRename,
                ),
              ]),
              Text('@${bot.username} · ${bot.engine == 'claude' ? 'Claude' : 'Codex'}',
                  style: TextStyle(color: pal.sub, fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onShare,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(Icons.group_outlined, size: 17, color: pal.sub),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bot.allow.isEmpty ? tr('Ai được gọi bot: chỉ mình tôi') : tr('Ai được gọi bot: tôi và {0} người khác', [bot.allow.length]),
                  style: TextStyle(color: pal.text, fontSize: 13.5),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: pal.sub),
            ]),
          ),
        ),
        Row(children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: runningHere || online ? const Color(0xFF2E9D5B) : pal.sub),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(line, style: TextStyle(color: pal.text, fontSize: 13.5))),
        ]),
        if (st?.phase == 'error' && st?.errorCode != 'already_running')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Expanded(
                child: Text(
                  st!.errorCode == 'no_engine'
                      ? tr('Máy này chưa đăng nhập {0}.', [bot.engine == 'claude' ? 'Claude' : 'Codex'])
                      : st.errorCode == 'auth'
                          ? tr('Token của trợ lý không hợp lệ.')
                          : (st.errorMessage ?? tr('Lỗi không rõ')),
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              ),
              if (st.errorCode == 'no_engine') TextButton(onPressed: onLogin, child: Text(tr('Đăng nhập'))),
            ]),
          ),
        if (isDesktop) ...[
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: runningHere,
            activeTrackColor: pal.accent,
            title: Text(tr('Dùng máy này làm trợ lý'), style: TextStyle(color: pal.text, fontSize: 14.5)),
            subtitle: !engineReady
                ? Text(tr('Cần đăng nhập {0} trên máy này', [bot.engine == 'claude' ? 'Claude' : 'Codex']),
                    style: TextStyle(color: pal.sub, fontSize: 12.5))
                : null,
            onChanged: onRun,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: service,
            activeTrackColor: pal.accent,
            title: Text(tr('Chạy nền khi đăng nhập máy'), style: TextStyle(color: pal.text, fontSize: 14.5)),
            subtitle: Text(tr('Trợ lý vẫn chạy khi đóng app'), style: TextStyle(color: pal.sub, fontSize: 12.5)),
            onChanged: onService,
          ),
        ],
      ]),
    );
  }
}

/// Cài đặt nhóm: thêm một trợ lý AI của tôi vào cuộc trò chuyện.
Future<void> addMyAssistant(BuildContext context, AppState app, MmChannel ch) async {
  final messenger = ScaffoldMessenger.of(context);
  List<AgentBot> bots;
  try {
    bots = await AgentService.instance.myBots(app);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Không tải được danh sách trợ lý.'))));
    return;
  }
  if (!context.mounted) return;
  if (bots.isEmpty) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage()));
    return;
  }
  final bot = bots.length == 1
      ? bots.first
      : await showDialog<AgentBot>(
          context: context,
          builder: (d) => SimpleDialog(title: Text(tr('Thêm trợ lý của tôi')), children: [
            for (final b in bots)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, b),
                child: Text('${b.displayName} (${b.engine == 'claude' ? 'Claude' : 'Codex'})'),
              ),
          ]),
        );
  if (bot == null) return;
  try {
    await app.addMember(ch.id, bot.id);
    messenger.showSnackBar(SnackBar(content: Text(tr('Đã thêm {0} vào nhóm. Gọi bằng @{1}.', [bot.displayName, bot.username]))));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Không thêm được trợ lý. Bạn có thể không có quyền thêm thành viên.'))));
  }
}

/// Phân quyền gọi bot: chủ bot luôn gọi được; thêm / bỏ người khác.
/// Người được thêm gọi bot bằng @tên-bot; bot chạy trên máy và tài khoản AI của chủ bot.
class BotAccessPage extends StatefulWidget {
  final AgentBot bot;
  const BotAccessPage({super.key, required this.bot});
  @override
  State<BotAccessPage> createState() => _BotAccessPageState();
}

class _BotAccessPageState extends State<BotAccessPage> {
  late final List<String> _allow = [...widget.bot.allow];
  bool _busy = false;

  Future<void> _save() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await AgentService.instance.setAllowed(app, widget.bot, _allow);
      messenger.showSnackBar(SnackBar(content: Text(tr('Đã lưu quyền gọi bot.'))));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Không lưu được quyền gọi bot.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final app = context.read<AppState>();
    final picked = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => _PickUserPage(exclude: {..._allow, app.me!.id})));
    if (picked == null) return;
    setState(() => _allow.add(picked));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final me = app.me!;
    Widget row(String id, {bool owner = false}) {
      final u = app.users[id];
      return ListTile(
        leading: Avatar(userId: id, name: u?.displayName ?? '?', size: 40),
        title: Text(u?.displayName ?? id, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
        subtitle: Text(owner ? tr('Chủ bot') : '@${u?.username ?? ''}', style: TextStyle(color: pal.sub)),
        trailing: owner
            ? null
            : IconButton(
                tooltip: tr('Bỏ quyền'),
                icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _allow.remove(id));
                        await _save();
                      },
              ),
      );
    }

    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Ai được gọi {0}', [widget.bot.displayName]), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(
            tr('Người trong danh sách gọi được bot bằng @{0}. Bot chạy trên máy và dùng tài khoản AI ({1}) của chủ bot.',
                [widget.bot.username, widget.bot.engine == 'claude' ? 'Claude' : 'Codex']),
            style: TextStyle(color: pal.sub, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              row(me.id, owner: true),
              for (final id in _allow) row(id),
              ListTile(
                leading: Icon(Icons.person_add_alt_1_outlined, color: pal.accentText),
                title: Text(tr('Thêm người được gọi bot'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
                onTap: _busy ? null : _add,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PickUserPage extends StatefulWidget {
  final Set<String> exclude;
  const _PickUserPage({required this.exclude});
  @override
  State<_PickUserPage> createState() => _PickUserPageState();
}

class _PickUserPageState extends State<_PickUserPage> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final q = _q.toLowerCase();
    final people = app.people
        .where((u) => !widget.exclude.contains(u.id))
        .where((u) => q.isEmpty || u.displayName.toLowerCase().contains(q) || u.username.contains(q))
        .toList();
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        surfaceTintColor: Colors.transparent,
        title: TextField(
          autofocus: true,
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(hintText: tr('Tìm theo tên hoặc email'), border: InputBorder.none),
        ),
      ),
      body: ListView(children: [
        for (final u in people)
          ListTile(
            leading: Avatar(userId: u.id, name: u.displayName, size: 40),
            title: Text(u.displayName, style: TextStyle(color: pal.text)),
            subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
            onTap: () => Navigator.pop(context, u.id),
          ),
      ]),
    );
  }
}
