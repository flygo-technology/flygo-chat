import '../i18n/i18n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'attach_panel.dart' show pickChat;
import 'chat_page.dart' show ChatPage, ThreadPage;
import 'home_page.dart' show ChatHost;
import 'agents_view.dart' show noAgentNotice;
import 'common.dart';
import 'theme.dart';

/// Lịch hẹn giờ của một trợ lý (runner đăng lên tài khoản bot: props.flygo_schedules = {v, at, items:[…]}).
class AgentSchedule {
  final MmUser bot;
  final Map<String, dynamic> raw;
  AgentSchedule(this.bot, this.raw);
  String get id => raw['id'] as String? ?? '';
  String get title => (raw['title'] as String? ?? '').trim();
  String get prompt => raw['prompt'] as String? ?? '';
  bool get enabled => raw['enabled'] != false;
  String get kind => raw['kind'] as String? ?? 'once';
  Map<String, dynamic> get repeat => ((raw['repeat'] as Map?) ?? const {}).cast<String, dynamic>();
  Map<String, dynamic> get target => ((raw['target'] as Map?) ?? const {}).cast<String, dynamic>();
  String get channelId => target['channel_id'] as String? ?? '';
  String? get rootId => (target['root_id'] as String?)?.isNotEmpty == true ? target['root_id'] as String : null;
  DateTime? get nextRun => scheduleTime(raw['next_run_at']);
  Map<String, dynamic>? get lastRun => (raw['last_run'] as Map?)?.cast<String, dynamic>();
  List<Map<String, dynamic>> get history => [for (final h in (raw['history'] as List? ?? const [])) (h as Map).cast<String, dynamic>()];
  String get createdBy => raw['created_by'] as String? ?? '';
}

/// Thời điểm runner gửi về: mili giây hoặc chuỗi ISO.
DateTime? scheduleTime(dynamic v) {
  if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
  return null;
}

const _dayNames = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];

/// "Mỗi ngày 08:00", "T2, T4 · 08:00", "Một lần · 18/10 08:00"…
String scheduleText(AgentSchedule s) {
  final r = s.repeat;
  final time = r['time'] as String? ?? '';
  if (s.kind == 'once') {
    final at = scheduleTime(s.raw['at']);
    return at == null ? tr('Một lần') : tr('Một lần · {0}', ['${two(at.day)}/${two(at.month)} ${hhmm(at)}']);
  }
  switch (r['freq']) {
    case 'daily':
      return tr('Mỗi ngày {0}', [time]);
    case 'weekly':
      final ds = [for (final d in (r['days'] as List? ?? const [])) if (d is int && d >= 1 && d <= 7) _dayNames[d - 1]];
      return '${ds.isEmpty ? tr('Hằng tuần') : ds.join(', ')} · $time';
    case 'monthly':
      return tr('Ngày {0} hằng tháng · {1}', [r['day_of_month'] ?? 1, time]);
    case 'cron':
      return 'cron ${r['cron'] ?? ''}';
  }
  return time;
}

String _whenText(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final prefix = diff == 0 ? tr('Hôm nay') : diff == 1 ? tr('Ngày mai') : '${two(d.day)}/${two(d.month)}';
  return '$prefix ${hhmm(d)}';
}

/// Đường dẫn nơi gửi: Nhóm › Luồng bí mật › … › Luồng: "tin gốc".
List<String> targetPath(AppState app, AgentSchedule s) {
  final out = <String>[];
  var id = s.channelId;
  for (var i = 0; i < 8; i++) {
    final c = app.channels[id];
    if (c == null) {
      if (out.isEmpty) out.add(tr('(chat không có trên máy này)'));
      break;
    }
    if (c.isAi) {
      final g = app.channels[c.aiGroup];
      out.insert(0, '${tr('AI')} · ${aiTitleOf(c)}');
      if (g == null) break;
      id = g.id;
      continue;
    }
    out.insert(0, c.isSub ? '🔒 ${app.channelTitle(c)}' : app.channelTitle(c));
    final p = c.subParent;
    if (p == null) break;
    id = p;
  }
  final root = s.rootId;
  if (root != null) {
    final p = app.findPost(s.channelId, root);
    final t = p == null ? root : app.previewText(p).replaceAll('\n', ' ');
    out.add(tr('Luồng: "{0}"', [t.length > 40 ? '${t.substring(0, 40)}…' : t]));
  }
  return out;
}

String aiTitleOf(MmChannel c) => c.aiTitle.isNotEmpty ? c.aiTitle : tr('Phiên chính');

/// Gửi lệnh quản lý lịch hẹn cho trợ lý qua máy chủ A2A (máy chủ kiểm tra quyền chủ / người được chia sẻ rồi chuyển
/// cho runner trên máy của trợ lý).
Future<Map<String, dynamic>> scheduleCommand(AppState app, String botId, String action,
    {String? id, Map<String, dynamic>? schedule}) async {
  // Tạo / sửa lịch: nội dung lịch được gửi cho trợ lý AI.
  if (schedule != null && !await app.ensureAiConsent()) throw const AiConsentDeclined();
  final r = await http
      .post(Uri.parse('$kPushUrl/a2a/schedules'),
          headers: {
            'Authorization': 'Bearer ${app.api.token}',
            'X-MM-Server': kServerUrl,
            'Content-Type': 'application/json',
            'User-Agent': kUserAgent,
          },
          body: jsonEncode({'bot_id': botId, 'action': action, 'id': ?id, 'schedule': ?schedule}))
      .timeout(const Duration(seconds: 20));
  final body = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
  if (r.statusCode != 200 || body['ok'] == false) {
    throw Exception(r.statusCode == 503 ? tr('Trợ lý đang tắt máy hoặc mất kết nối.') : (body['error'] ?? 'HTTP ${r.statusCode}'));
  }
  return body;
}

/// Tab "Hẹn giờ": lịch hẹn của các trợ lý mình là chủ hoặc được chia sẻ.
class SchedulesView extends StatefulWidget {
  final Widget header;
  final double bottomPadding;
  const SchedulesView({super.key, required this.header, this.bottomPadding = 0});
  @override
  State<SchedulesView> createState() => _SchedulesViewState();
}

class _SchedulesViewState extends State<SchedulesView> {
  List<AgentSchedule>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Trợ lý mình gọi được (chủ hoặc được chia sẻ): đọc lại tài khoản bot để có lịch mới nhất.
  Future<List<MmUser>> _bots(AppState app) async {
    final mine = await app.myBotIds();
    final ids = [for (final u in app.users.values) if (u.isBot && app.isAssistant(u.id) && app.canCallBot(u, mine)) u.id];
    try {
      for (final u in await app.api.usersByIds(ids)) {
        app.users[u.id] = u;
      }
    } catch (_) {}
    return [for (final id in ids) if (app.users[id] != null) app.users[id]!];
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final out = <AgentSchedule>[];
      for (final b in await _bots(app)) {
        dynamic raw = (b.raw['props'] as Map?)?['flygo_schedules'];
        if (raw is String && raw.isNotEmpty) raw = jsonDecode(raw);
        final items = raw is Map ? raw['items'] : raw;
        if (items is List) {
          for (final x in items) {
            if (x is Map) out.add(AgentSchedule(b, x.cast<String, dynamic>()));
          }
        }
      }
      out.sort((a, b) {
        if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
        final na = a.nextRun, nb = b.nextRun;
        if (na == null || nb == null) return na == null ? 1 : -1;
        return na.compareTo(nb);
      });
      if (mounted) setState(() => (_items = out, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = tr('Không tải được lịch hẹn.'));
    }
  }

  Future<void> _create() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ScheduleEditPage()));
    if (ok == true) {
      await Future.delayed(const Duration(seconds: 2));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final items = _items;
    return Scaffold(
      backgroundColor: pal.bg,
      floatingActionButton: !app.hasUsableAgents
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: widget.bottomPadding),
              child: FloatingActionButton.extended(
                onPressed: _create,
                icon: const Icon(Icons.alarm_add),
                label: Text(tr('Hẹn giờ mới')),
              ),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding + 90), children: [
          widget.header,
          if (!app.hasUsableAgents)
            Padding(padding: const EdgeInsets.only(top: 60), child: noAgentNotice(pal))
          else if (_error != null)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, style: TextStyle(color: pal.sub))))
          else if (items == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 60, 32, 20),
              child: Column(children: [
                Icon(Icons.alarm, size: 52, color: pal.sub),
                const SizedBox(height: 12),
                Text(tr('Chưa có lịch hẹn nào'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
                const SizedBox(height: 6),
                Text(
                    tr('Nhờ trợ lý làm việc theo giờ, ví dụ: "@trợ-lý mỗi sáng 8h tổng hợp đơn hàng rồi báo vào nhóm này", hoặc bấm "Hẹn giờ mới".'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: pal.sub)),
              ]),
            )
          else
            for (final s in items) _ScheduleTile(s: s, app: app, onChanged: _load),
        ]),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  final AgentSchedule s;
  final AppState app;
  final Future<void> Function() onChanged;
  const _ScheduleTile({required this.s, required this.app, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final last = s.lastRun?['status'] as String?;
    final path = targetPath(app, s);
    return InkWell(
      onTap: () async {
        final changed =
            await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ScheduleDetailPage(schedule: s)));
        if (changed == true) onChanged();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Opacity(
            opacity: s.enabled ? 1 : .45,
            child: Avatar(userId: s.bot.id, name: s.bot.displayName, size: 44, icon: Icons.smart_toy_outlined, status: false),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title.isNotEmpty ? s.title : s.prompt,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: s.enabled ? pal.text : pal.sub)),
              const SizedBox(height: 2),
              Text('${scheduleText(s)} · @${s.bot.username}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.accentText)),
              Text(path.join(' › '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
                !s.enabled
                    ? tr('Tạm dừng')
                    : s.nextRun == null
                        ? ''
                        : _whenText(s.nextRun!),
                style: TextStyle(fontSize: 12.5, color: s.enabled ? pal.text : pal.sub)),
            const SizedBox(height: 4),
            if (last != null)
              Icon(
                  last == 'done'
                      ? Icons.check_circle_rounded
                      : last == 'error'
                          ? Icons.error_rounded
                          : Icons.remove_circle_outline,
                  size: 18,
                  color: last == 'done' ? const Color(0xFF2E9D5B) : (last == 'error' ? Colors.redAccent : pal.sub)),
          ]),
        ]),
      ),
    );
  }
}

/// Chi tiết lịch hẹn: nội dung, lịch, nơi gửi (cấu trúc cha con), lịch sử chạy; tạm dừng / chạy ngay / sửa / xoá.
class ScheduleDetailPage extends StatefulWidget {
  final AgentSchedule schedule;
  const ScheduleDetailPage({super.key, required this.schedule});
  @override
  State<ScheduleDetailPage> createState() => _ScheduleDetailPageState();
}

class _ScheduleDetailPageState extends State<ScheduleDetailPage> {
  bool _busy = false;
  bool _changed = false;
  late bool _enabled = widget.schedule.enabled;

  Future<void> _run(String action, {String? done}) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await scheduleCommand(app, widget.schedule.bot.id, action, id: widget.schedule.id);
      _changed = true;
      if (action == 'pause') _enabled = false;
      if (action == 'resume') _enabled = true;
      if (done != null) messenger.showSnackBar(toast(Text(done)));
      if (action == 'delete' && mounted) Navigator.pop(context, true);
    } catch (e) {
      messenger.showSnackBar(toast(Text(tr('Không thực hiện được: {0}', ['$e'.replaceFirst('Exception: ', '')]))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final s = widget.schedule;
    final path = targetPath(app, s);
    final creator = app.users[s.createdBy]?.displayName ?? '';
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: .4, color: pal.sub, fontWeight: FontWeight.w600)),
        );
    Widget card(List<Widget> c) => Container(
          decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: c),
        );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Lịch hẹn'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 30), children: [
          Row(children: [
            Avatar(userId: s.bot.id, name: s.bot.displayName, size: 46, icon: Icons.smart_toy_outlined, status: false),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.title.isNotEmpty ? s.title : tr('Lịch hẹn'),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
                Text('@${s.bot.username}${creator.isEmpty ? '' : ' · ${tr('tạo bởi {0}', [creator])}'}',
                    style: TextStyle(color: pal.sub, fontSize: 13)),
              ]),
            ),
          ]),
          label(tr('Lịch')),
          card([
            Text(scheduleText(s), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
            if (_enabled && s.nextRun != null)
              Text(tr('Lần tới: {0}', [_whenText(s.nextRun!)]), style: TextStyle(color: pal.sub))
            else if (!_enabled)
              Text(tr('Đang tạm dừng'), style: const TextStyle(color: Colors.orange)),
          ]),
          label(tr('Việc cần làm')),
          card([SelectableText(s.prompt, style: TextStyle(fontSize: 15, color: pal.text, height: 1.4))]),
          label(tr('Gửi vào')),
          card([
            for (final (i, p) in path.indexed)
              Padding(
                padding: EdgeInsets.only(left: 14.0 * i, bottom: 4),
                child: Row(children: [
                  Icon(i == 0 ? Icons.groups_outlined : Icons.subdirectory_arrow_right, size: 18, color: pal.sub),
                  const SizedBox(width: 6),
                  Expanded(child: Text(p, style: TextStyle(color: pal.text, fontSize: 14.5))),
                ]),
              ),
            if (app.channels[s.channelId] != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => openChatWith(context, s.channelId, rootId: s.rootId),
                  child: Text(tr('Mở chat')),
                ),
              ),
          ]),
          if (s.history.isNotEmpty || s.lastRun != null) ...[
            label(tr('Các lần chạy')),
            card([
              for (final h in (s.history.isNotEmpty ? s.history.reversed.take(10) : [s.lastRun!]))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      h['status'] == 'done'
                          ? Icons.check_circle_rounded
                          : h['status'] == 'error'
                              ? Icons.error_rounded
                              : Icons.remove_circle_outline,
                      color: h['status'] == 'done' ? const Color(0xFF2E9D5B) : (h['status'] == 'error' ? Colors.redAccent : pal.sub)),
                  title: Text(scheduleTime(h['at']) == null ? '${h['at'] ?? ''}' : _whenText(scheduleTime(h['at'])!),
                      style: TextStyle(color: pal.text)),
                  subtitle: (h['error'] as String?)?.isNotEmpty == true
                      ? Text(h['error'] as String, style: const TextStyle(color: Colors.redAccent))
                      : null,
                  onTap: h['post_id'] is String && app.channels[s.channelId] != null
                      ? () => openChatWith(context, s.channelId, rootId: s.rootId)
                      : null,
                ),
            ]),
          ],
          const SizedBox(height: 18),
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _run('run_now', done: tr('Đã nhờ trợ lý chạy ngay')),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(tr('Chạy ngay')),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_enabled ? 'pause' : 'resume'),
              icon: Icon(_enabled ? Icons.pause_rounded : Icons.play_circle_outline),
              label: Text(_enabled ? tr('Tạm dừng') : tr('Tiếp tục')),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await Navigator.of(context)
                          .push<bool>(MaterialPageRoute(builder: (_) => ScheduleEditPage(existing: s)));
                      if (ok == true && context.mounted) Navigator.pop(context, true);
                    },
              icon: const Icon(Icons.edit_outlined),
              label: Text(tr('Sửa')),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: Text(tr('Xoá lịch hẹn?')),
                          content: Text(tr('Trợ lý sẽ không làm việc này theo giờ nữa.')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
                            TextButton(
                                onPressed: () => Navigator.pop(d, true),
                                child: Text(tr('Xóa'), style: const TextStyle(color: Colors.redAccent))),
                          ],
                        ),
                      );
                      if (ok == true) _run('delete');
                    },
              icon: const Icon(Icons.delete_outline),
              label: Text(tr('Xóa')),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Mở chat (và luồng nếu có) từ trang lịch hẹn.
void openChatWith(BuildContext context, String channelId, {String? rootId}) {
  final host = ChatHost.of(context);
  if (host != null) {
    host.openChat(channelId);
    if (rootId != null) host.openThread(channelId, rootId);
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => rootId == null ? ChatPage(channelId: channelId) : ThreadPage(channelId: channelId, rootId: rootId)));
}

/// Tạo / sửa lịch hẹn: chọn trợ lý, nơi gửi, việc cần làm, giờ (một lần / hằng ngày / hằng tuần / hằng tháng).
class ScheduleEditPage extends StatefulWidget {
  final AgentSchedule? existing;
  const ScheduleEditPage({super.key, this.existing});
  @override
  State<ScheduleEditPage> createState() => _ScheduleEditPageState();
}

class _ScheduleEditPageState extends State<ScheduleEditPage> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _prompt = TextEditingController(text: widget.existing?.prompt ?? '');
  late String? _botId = widget.existing?.bot.id;
  late String? _channelId = widget.existing?.channelId;
  late String? _rootId = widget.existing?.rootId;
  late String _freq = widget.existing == null
      ? 'daily'
      : (widget.existing!.kind == 'once' ? 'once' : (widget.existing!.repeat['freq'] as String? ?? 'daily'));
  late TimeOfDay _time = () {
    final t = (widget.existing?.repeat['time'] as String?)?.split(':');
    if (t != null && t.length == 2) return TimeOfDay(hour: int.tryParse(t[0]) ?? 8, minute: int.tryParse(t[1]) ?? 0);
    return const TimeOfDay(hour: 8, minute: 0);
  }();
  late DateTime _date = scheduleTime(widget.existing?.raw['at']) ??
      DateTime.now().add(const Duration(days: 1));
  late final Set<int> _days = {for (final d in (widget.existing?.repeat['days'] as List? ?? const [1])) if (d is int) d};
  late int _dom = (widget.existing?.repeat['day_of_month'] as num?)?.toInt() ?? 1;
  bool _busy = false;
  List<MmUser> _bots = const [];

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.myBotIds().then((mine) {
      if (!mounted) return;
      setState(() {
        _bots = [for (final u in app.users.values) if (u.isBot && app.isAssistant(u.id) && app.canCallBot(u, mine)) u];
        _botId ??= _bots.firstOrNull?.id;
      });
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (_botId == null || _channelId == null || _prompt.text.trim().isEmpty) {
      messenger.showSnackBar(toast(Text(tr('Chọn trợ lý, nơi gửi và nhập việc cần làm.'))));
      return;
    }
    final time = '${two(_time.hour)}:${two(_time.minute)}';
    final at = DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);
    final schedule = <String, dynamic>{
      'title': _title.text.trim(),
      'prompt': _prompt.text.trim(),
      'kind': _freq == 'once' ? 'once' : 'repeat',
      if (_freq == 'once') 'at': at.toUtc().toIso8601String(),
      if (_freq != 'once')
        'repeat': {
          'freq': _freq,
          'time': time,
          if (_freq == 'weekly') 'days': (_days.toList()..sort()),
          if (_freq == 'monthly') 'day_of_month': _dom,
        },
      'tz': 'Asia/Ho_Chi_Minh',
      'target': {'channel_id': _channelId, 'root_id': ?_rootId},
    };
    setState(() => _busy = true);
    try {
      await scheduleCommand(app, _botId!, widget.existing == null ? 'create' : 'update',
          id: widget.existing?.id, schedule: schedule);
      messenger.showSnackBar(toast(Text(tr('Đã lưu lịch hẹn')), icon: Icons.alarm_on));
      nav.pop(true);
    } catch (e) {
      messenger.showSnackBar(toast(Text(tr('Không lưu được: {0}', ['$e'.replaceFirst('Exception: ', '')]))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final ch = _channelId == null ? null : app.channels[_channelId];
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: .4, color: pal.sub, fontWeight: FontWeight.w600)),
        );
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.existing == null ? tr('Hẹn giờ mới') : tr('Sửa lịch hẹn'),
            style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: Text(tr('Lưu'))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 30), children: [
        label(tr('Trợ lý')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final b in _bots)
            ChoiceChip(
              selected: _botId == b.id,
              showCheckmark: false,
              avatar: EngineIcon(engineOf(b) ?? '', size: 16, color: pal.text),
              label: Text('@${b.username}'),
              onSelected: widget.existing != null ? null : (_) => setState(() => _botId = b.id),
            ),
          if (_bots.isEmpty) Text(tr('Bạn chưa có trợ lý nào.'), style: TextStyle(color: pal.sub)),
        ]),
        label(tr('Gửi vào')),
        ListTile(
          tileColor: pal.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: Icon(Icons.forum_outlined, color: pal.sub),
          title: Text(ch == null ? tr('Chọn nhóm / chat') : app.channelTitle(ch), style: TextStyle(color: pal.text)),
          subtitle: _rootId == null ? null : Text(tr('Trong một luồng'), style: TextStyle(color: pal.sub)),
          trailing: Icon(Icons.chevron_right, color: pal.sub),
          onTap: () async {
            final id = await pickChat(context, title: tr('Gửi kết quả vào'));
            if (id != null) setState(() => (_channelId = id, _rootId = null));
          },
        ),
        label(tr('Tên lịch (không bắt buộc)')),
        TextField(
          controller: _title,
          decoration: InputDecoration(hintText: tr('VD: Tổng hợp đơn hàng buổi sáng'), filled: true, fillColor: pal.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none)),
        ),
        label(tr('Việc cần làm')),
        TextField(
          controller: _prompt,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(
              hintText: tr('VD: Kiểm tra các đơn chạy lỗi từ hôm qua, tóm tắt và báo vào đây'),
              filled: true,
              fillColor: pal.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none)),
        ),
        label(tr('Lặp lại')),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'once', label: Text(tr('Một lần'))),
            ButtonSegment(value: 'daily', label: Text(tr('Hằng ngày'))),
            ButtonSegment(value: 'weekly', label: Text(tr('Hằng tuần'))),
            ButtonSegment(value: 'monthly', label: Text(tr('Hằng tháng'))),
          ],
          selected: {_freq == 'cron' ? 'daily' : _freq},
          onSelectionChanged: (v) => setState(() => _freq = v.first),
        ),
        const SizedBox(height: 10),
        if (_freq == 'weekly')
          Wrap(spacing: 6, children: [
            for (var d = 1; d <= 7; d++)
              FilterChip(
                label: Text(_dayNames[d - 1]),
                selected: _days.contains(d),
                onSelected: (v) => setState(() => v ? _days.add(d) : _days.remove(d)),
              ),
          ]),
        if (_freq == 'monthly')
          Row(children: [
            Text(tr('Ngày'), style: TextStyle(color: pal.text)),
            const SizedBox(width: 10),
            DropdownButton<int>(
              value: _dom,
              items: [for (var d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text('$d'))],
              onChanged: (v) => setState(() => _dom = v ?? 1),
            ),
          ]),
        Row(children: [
          if (_freq == 'once')
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text('${two(_date.day)}/${two(_date.month)}/${_date.year}'),
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 366)));
                  if (d != null) setState(() => _date = d);
                },
              ),
            ),
          if (_freq == 'once') const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.schedule),
              label: Text('${two(_time.hour)}:${two(_time.minute)}'),
              onPressed: () async {
                final t = await showTimePicker(context: context, initialTime: _time);
                if (t != null) setState(() => _time = t);
              },
            ),
          ),
        ]),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(tr('Lưu lịch hẹn'))),
        ),
      ]),
    );
  }
}
