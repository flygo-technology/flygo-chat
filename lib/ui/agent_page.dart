import '../i18n/i18n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_config.dart' show modelLabel;
import '../agent/agent_service.dart';
import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_detail_page.dart';
import 'bot_page.dart' show BotEditPage, copyBotToken;
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
  /// Bot tích hợp (bot của mình không phải trợ lý AI): chỉ có token để phần mềm khác gửi tin.
  List<Map<String, dynamic>> _plain = const [];
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

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final bots = await svc.myBots(app);
      final ids = {for (final b in bots) b.id};
      final all = await app.myBots();
      if (!mounted) return;
      setState(() {
        _bots = bots;
        _plain = [for (final b in all) if (!ids.contains(b['user_id'])) b];
      });
      _loadRemote(app, bots);
      if (isDesktop) {
        svc.loadDoctor();
        // Luôn chạy nền: trợ lý gắn với máy này mà chưa cài chạy nền thì cài luôn;
        // trợ lý chưa gắn máy nào nhưng đang chạy nền ở đây thì gắn với máy này.
        for (final b in bots) {
          svc.serviceInstalled(b).then((v) async {
            if (AgentService.isHere(b) && !v) {
              try {
                await svc.installService(app, b);
                v = await svc.serviceInstalled(b);
              } catch (_) {}
            } else if (b.host == null && v) {
              try {
                await svc.bindHost(app, b, true);
              } catch (_) {}
            }
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
    final me = app.me;
    final nameCtl = TextEditingController();
    final userCtl = TextEditingController();
    final roleCtl = TextEditingController();
    final re = RegExp(r'^[a-z][a-z0-9._-]{2,21}$');
    String engine = 'claude';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) {
        final pal = Pal.of(d);
        final un = userCtl.text.trim().toLowerCase();
        final unError = un.isEmpty || re.hasMatch(un) ? null : tr('3–22 ký tự, bắt đầu bằng chữ, chỉ gồm a-z, 0-9, dấu . - _');
        Widget engineCard(String id, String label) => Expanded(
              child: Material(
                color: engine == id ? pal.accent.withValues(alpha: .14) : pal.bg,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: engine == id ? pal.accent : pal.divider, width: engine == id ? 1.6 : 1)),
                child: InkWell(
                  customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  onTap: () => set(() => engine = id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(children: [
                      EngineIcon(id, size: 26, color: pal.text),
                      const SizedBox(height: 6),
                      Text(label, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            );
        return AlertDialog(
          title: Text(tr('Tạo trợ lý AI')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [engineCard('claude', 'Claude'), const SizedBox(width: 10), engineCard('codex', 'Codex (OpenAI)')]),
              const SizedBox(height: 14),
              TextField(
                controller: roleCtl,
                decoration: InputDecoration(
                    labelText: tr('Vai trò / chuyên môn'), hintText: tr('VD: Kế toán – xử lý hoá đơn VAT')),
              ),
              TextField(
                controller: nameCtl,
                decoration: InputDecoration(
                    labelText: tr('Tên hiển thị'), hintText: '${engine == 'claude' ? 'Claude' : 'Codex'} của ${me?.displayName ?? ''}'),
              ),
              TextField(
                controller: userCtl,
                autocorrect: false,
                onChanged: (_) => set(() {}),
                decoration: InputDecoration(
                    labelText: tr('Tên người dùng'), prefixText: '@', hintText: 'ketoan', errorText: unError),
              ),
              const SizedBox(height: 8),
              Text(tr('Một máy có thể có nhiều trợ lý cùng loại AI, mỗi trợ lý một chuyên môn và kỹ năng riêng. Chat riêng với trợ lý để dạy và lưu kỹ năng.'),
                  style: TextStyle(fontSize: 12.5, color: pal.sub)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
            FilledButton(onPressed: unError != null ? null : () => Navigator.pop(d, true), child: Text(tr('Tạo'))),
          ],
        );
      }),
    );
    final name = nameCtl.text, username = userCtl.text.trim().toLowerCase(), role = roleCtl.text;
    nameCtl.dispose();
    userCtl.dispose();
    roleCtl.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final b = await svc.createBot(app, engine, username: username, displayName: name, role: role);
      // Trợ lý gắn cứng với máy tạo ra nó và luôn chạy nền.
      if (isDesktop) {
        await svc.installService(app, b);
        await svc.bindHost(app, b, true);
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không tạo được trợ lý: {0}', ['$e']))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
          title: Text(tr('Trợ lý & bot'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
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
                            toast(Text(tr('Đăng nhập trong trình duyệt vừa mở, xong bấm Tải lại.'))));
                      }),
                      const SizedBox(height: 18),
                    ],
                    _section(pal, tr('Trợ lý của tôi')),
                    if (bots.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(tr('Bạn chưa có trợ lý AI nào.'), style: TextStyle(color: pal.sub)),
                      ),
                    if (bots.isNotEmpty)
                      Container(
                        decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: [
                          for (final (i, b) in bots.indexed) ...[
                            if (i > 0) Divider(height: 1, indent: 74, color: pal.divider),
                            _BotRow(
                              bot: b,
                              remote: _remote[b.id],
                              state: svc.runners[b.id],
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => AgentDetailPage(bot: b, remote: _remote[b.id])));
                                _load();
                              },
                            ),
                          ],
                        ]),
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
                    const SizedBox(height: 26),
                    _section(pal, tr('Bot tích hợp')),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(tr('Không có AI: dùng token để phần mềm khác (kho, kế toán, cảnh báo…) gửi tin vào chat.'),
                          style: TextStyle(color: pal.sub, fontSize: 13)),
                    ),
                    if (_plain.isNotEmpty)
                      Container(
                        decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: [
                          for (final (i, b) in _plain.indexed) ...[
                            if (i > 0) Divider(height: 1, indent: 74, color: pal.divider),
                            ListTile(
                              contentPadding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                              leading: Avatar(
                                  userId: b['user_id'] as String,
                                  name: b['display_name'] as String? ?? '',
                                  size: 46,
                                  icon: Icons.power_outlined,
                                  status: false),
                              title: Text(
                                  (b['display_name'] as String? ?? '').isEmpty ? b['username'] as String : b['display_name'] as String,
                                  style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
                              subtitle: Text('@${b['username']} · ${tr('Bot tích hợp')}', style: TextStyle(color: pal.sub, fontSize: 13)),
                              trailing: IconButton(
                                tooltip: tr('Sao chép token'),
                                icon: Icon(Icons.key_outlined, color: pal.accentText),
                                onPressed: () => copyBotToken(context, b['user_id'] as String),
                              ),
                              onTap: () async {
                                final changed = await Navigator.of(context)
                                    .push<bool>(MaterialPageRoute(builder: (_) => BotEditPage(bot: b)));
                                if (changed == true) _load();
                              },
                            ),
                          ],
                        ]),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const BotEditPage()));
                          if (changed == true) _load();
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(tr('Tạo bot tích hợp')),
                      ),
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

/// Một dòng trợ lý: ảnh (chấm trạng thái), tên + logo nền tảng, @tên · mô hình · vai trò; bấm để mở chi tiết.
class _BotRow extends StatelessWidget {
  final AgentBot bot;
  final ({String status, String text})? remote;
  final RunnerState? state;
  final VoidCallback onTap;
  const _BotRow({required this.bot, required this.remote, required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final online = remote?.status == 'online';
    final error = state?.phase == 'error' && state?.errorCode != 'already_running';
    final model = app.agentConfig[bot.id]?['model'];
    final dot = bot.paused
        ? pal.sub
        : error
            ? Colors.redAccent
            : online
                ? const Color(0xFF2E9D5B)
                : const Color(0xFFF5A623);
    final status = bot.paused
        ? tr('Đang tạm tắt')
        : error
            ? tr('Lỗi')
            : online
                ? tr('Đang chạy')
                : tr('Ngoại tuyến');
    final sub = [
      '@${bot.username}',
      if (model != null) modelLabel(model),
      if (bot.role.isNotEmpty) bot.role,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            Opacity(
              opacity: bot.paused ? .5 : 1,
              child: Avatar(userId: bot.id, name: bot.displayName, size: 46, icon: Icons.smart_toy_outlined, status: false),
            ),
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle, border: Border.all(color: pal.surface, width: 2.5)),
              ),
            ),
          ]),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              nameText(bot.displayName,
                  bot: true,
                  engine: bot.engine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: bot.paused ? pal.sub : pal.text)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(status, style: TextStyle(fontSize: 12.5, color: dot, fontWeight: FontWeight.w600)),
          Icon(Icons.chevron_right, color: pal.sub),
        ]),
      ),
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
    messenger.showSnackBar(toast(Text(tr('Không tải được danh sách trợ lý.'))));
    return;
  }
  if (!context.mounted) return;
  if (bots.isEmpty) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage()));
    return;
  }
  final bot = bots.length == 1 ? bots.first : await pickAssistant(context, bots, title: tr('Thêm trợ lý của tôi'));
  if (bot == null) return;
  try {
    await app.addMember(ch.id, bot.id);
    messenger.showSnackBar(toast(Text(tr('Đã thêm {0} vào nhóm. Gọi bằng @{1}.', [bot.displayName, bot.username]))));
  } on OneAssistantException catch (e) {
    messenger.showSnackBar(toast(Text(e.toString())));
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không thêm được trợ lý. Bạn có thể không có quyền thêm thành viên.'))));
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
      messenger.showSnackBar(toast(Text(tr('Đã lưu quyền gọi bot.'))));
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không lưu được quyền gọi bot.'))));
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


/// Hộp chọn trợ lý AI: mỗi trợ lý là một ô rõ ràng (ảnh / logo Claude-OpenAI, tên, @username · loại AI),
/// giống danh sách chọn thành viên — dễ bấm trên điện thoại.
Future<AgentBot?> pickAssistant(BuildContext context, List<AgentBot> bots, {required String title}) {
  return showDialog<AgentBot>(
    context: context,
    builder: (d) {
      final pal = Pal.of(d);
      return Dialog(
        backgroundColor: pal.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 12),
                child: Text(title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: pal.text)),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: bots.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final b = bots[i];
                    return Material(
                      color: pal.bg,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14), side: BorderSide(color: pal.divider)),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.pop(d, b),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(children: [
                            Avatar(userId: b.id, name: b.displayName, size: 44, status: false),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                nameText(b.displayName,
                                    bot: true,
                                    engine: b.engine,
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
                                const SizedBox(height: 2),
                                Text('@${b.username} · ${b.engine == 'claude' ? 'Claude' : 'Codex'}${b.role.isEmpty ? '' : ' · ${b.role}'}',
                                    maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
                              ]),
                            ),
                            Icon(Icons.chevron_right_rounded, color: pal.sub),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
              ),
            ]),
          ),
        ),
      );
    },
  );
}
