import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_config.dart';
import '../agent/agent_service.dart';
import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_page.dart' show BotAccessPage;
import 'common.dart';
import 'theme.dart';

/// Trạng thái trợ lý trên máy chủ (online + dòng "đang chạy trên …"), truyền từ trang danh sách.
typedef AgentRemote = ({String status, String text});

/// Trang chi tiết một trợ lý AI: bật / tắt, sửa tên, chọn mô hình, vai trò, kỹ năng, ai được gọi, máy chạy, xoá.
class AgentDetailPage extends StatefulWidget {
  final AgentBot bot;
  final AgentRemote? remote;
  const AgentDetailPage({super.key, required this.bot, this.remote});
  @override
  State<AgentDetailPage> createState() => _AgentDetailPageState();
}

class _AgentDetailPageState extends State<AgentDetailPage> {
  final svc = AgentService.instance;
  late AgentBot _bot = widget.bot;
  late final _roleCtl = TextEditingController(text: widget.bot.role);
  Map<String, dynamic>? _skills;
  bool _skillsLoading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  @override
  void dispose() {
    _roleCtl.dispose();
    super.dispose();
  }

  Future<void> _loadSkills() async {
    if (!AgentService.isHere(_bot)) return;
    setState(() => _skillsLoading = true);
    try {
      final s = await svc.skillsOf(_bot);
      if (mounted) setState(() => _skills = s);
    } catch (_) {}
    if (mounted) setState(() => _skillsLoading = false);
  }

  /// Tải lại trợ lý từ máy chủ (sau khi đổi tên / bật tắt / vai trò...).
  Future<void> _reload() async {
    final app = context.read<AppState>();
    try {
      final all = await svc.myBots(app);
      final b = all.where((x) => x.id == _bot.id).firstOrNull;
      if (b != null && mounted) setState(() => _bot = b);
    } catch (_) {}
  }

  Future<void> _guard(Future<void> Function() f, String error) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await f();
      await _reload();
    } catch (_) {
      messenger.showSnackBar(toast(Text(error)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AgentOptions _options() =>
      agentOptionsOf(MmUser({'id': _bot.id, 'is_bot': true, 'bot_description': _bot.description})) ??
      agentOptionsOf(MmUser({'id': _bot.id, 'is_bot': true, 'bot_description': '[flygo-agent engine=${_bot.engine}]'}))!;

  // ---------------------------------------------------------------- thao tác
  Future<void> _rename() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final b = _bot;
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
            TextField(controller: nameCtl, autofocus: true, maxLength: 64, decoration: InputDecoration(labelText: tr('Tên hiển thị'))),
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
      await app.api.put('/bots/${b.id}', {'username': username, 'display_name': name.isEmpty ? b.displayName : name});
      await app.refreshUser(b.id);
      await _reload();
    } catch (e) {
      final taken = e.toString().contains('exists') || e.toString().contains('taken');
      messenger.showSnackBar(toast(
          Text(taken ? tr('Tên người dùng này đã có người dùng.') : tr('Không đổi được tên trợ lý. Kiểm tra kết nối mạng.'))));
    }
  }

  Future<void> _pickModel() async {
    final app = context.read<AppState>();
    final o = _options();
    final cur = app.agentConfig[_bot.id];
    final model = o.models.contains(cur?['model']) ? cur!['model']! : o.defModel;
    final effort = o.efforts.contains(cur?['effort']) ? cur!['effort']! : o.defEffort;
    final u = app.users[_bot.id] ?? MmUser({'id': _bot.id, 'is_bot': true, 'username': _bot.username, 'first_name': _bot.displayName});
    final r = await pickAgentConfig(context, u, o, model, effort);
    if (r == null) return;
    await app.setAgentConfig(_bot.id, r.$1, r.$2);
  }

  Future<void> _delete() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Xóa trợ lý?')),
        content: Text(tr('{0} sẽ ngừng chạy và không còn được gọi trong chat. Tin nhắn cũ vẫn giữ nguyên.', [_bot.displayName])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Xóa'), style: const TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await svc.deleteBot(app, _bot);
      nav.pop(true);
    } catch (e) {
      messenger.showSnackBar(toast(Text(tr('Không xóa được trợ lý: {0}', ['$e'.replaceFirst('Exception: ', '')]))));
    }
  }

  // ---------------------------------------------------------------- giao diện
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final b = _bot;
    final online = widget.remote?.status == 'online';
    final where = widget.remote?.text ?? '';
    final o = _options();
    final cfg = app.agentConfig[b.id];
    final model = o.models.contains(cfg?['model']) ? cfg!['model']! : o.defModel;
    final effort = o.efforts.contains(cfg?['effort']) ? cfg!['effort']! : o.defEffort;
    final engineLabel = b.engine == 'claude' ? 'Claude' : 'Codex';
    final skills = [for (final x in (_skills?['skills'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];

    Widget card(List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
          child: Column(children: children),
        );
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: .4, color: pal.sub, fontWeight: FontWeight.w600)),
        );
    Widget row(IconData icon, String title, {String? sub, Widget? trailing, VoidCallback? onTap}) => ListTile(
          onTap: onTap,
          leading: Icon(icon, color: pal.sub),
          title: Text(title, style: TextStyle(color: pal.text, fontSize: 15.5)),
          subtitle: sub == null ? null : Text(sub, style: TextStyle(color: pal.sub, fontSize: 13)),
          trailing: trailing ?? (onTap == null ? null : Icon(Icons.chevron_right, color: pal.sub)),
        );

    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Trợ lý'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          // Đầu trang: ảnh, tên, @username, nút sửa.
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(children: [
              EditableAvatar(
                size: 84,
                avatar: Avatar(userId: b.id, name: b.displayName, size: 84, icon: Icons.smart_toy_outlined, status: false),
                onPicked: (n, bytes) => app.setUserImage(b.id, n, bytes),
              ),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Flexible(
                  child: nameText(b.displayName,
                      bot: true, engine: b.engine, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: pal.text)),
                ),
                IconButton(
                  tooltip: tr('Đổi tên trợ lý'),
                  icon: Icon(Icons.edit_outlined, size: 20, color: pal.sub),
                  onPressed: _rename,
                ),
              ]),
              Text('@${b.username} · $engineLabel', style: TextStyle(color: pal.sub, fontSize: 14)),
            ]),
          ),

          // Bật / tắt.
          card([
            SwitchListTile(
              value: !b.paused,
              onChanged: _busy
                  ? null
                  : (v) => _guard(() => svc.setPaused(app, b, !v), tr('Không đổi được trạng thái trợ lý. Kiểm tra kết nối mạng.')),
              secondary: Icon(b.paused ? Icons.pause_circle_outline : Icons.play_circle_outline,
                  color: b.paused ? pal.sub : const Color(0xFF2E9D5B)),
              title: Text(b.paused ? tr('Đang tạm tắt') : tr('Đang bật'),
                  style: TextStyle(color: pal.text, fontSize: 15.5, fontWeight: FontWeight.w600)),
              subtitle: Text(
                  b.paused
                      ? tr('Trợ lý không nhận việc mới cho tới khi bật lại.')
                      : (online && where.isNotEmpty ? where : tr('Trợ lý nhận việc khi được gọi.')),
                  style: TextStyle(color: pal.sub, fontSize: 13)),
            ),
          ]),

          // Mô hình.
          label(tr('Mô hình')),
          card([
            row(Icons.memory_rounded, model,
                sub: tr('Mức suy nghĩ: {0}', [effortLabel(effort)]),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  EffortBars(effort: effort, color: pal.accentText),
                  const SizedBox(width: 6),
                  Icon(Icons.chevron_right, color: pal.sub),
                ]),
                onTap: _pickModel),
          ]),

          // Vai trò.
          label(tr('Vai trò / chuyên môn')),
          card([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _roleCtl,
                    minLines: 1,
                    maxLines: 3,
                    style: TextStyle(color: pal.text),
                    decoration: InputDecoration(border: InputBorder.none, hintText: tr('VD: Kế toán – xử lý hoá đơn VAT')),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (_roleCtl.text.trim() != b.role)
                  TextButton(
                    onPressed: () => _guard(() => svc.setRole(app, b, _roleCtl.text), tr('Không lưu được vai trò. Kiểm tra kết nối mạng.')),
                    child: Text(tr('Lưu')),
                  ),
              ]),
            ),
          ]),

          // Kỹ năng.
          label(tr('Kỹ năng')),
          card([
            if (!AgentService.isHere(b))
              row(Icons.info_outline, tr('Danh sách kỹ năng chỉ xem được trên máy đang chạy trợ lý ({0}).', [b.host ?? '?']))
            else if (_skillsLoading)
              const Padding(padding: EdgeInsets.all(18), child: Center(child: CircularProgressIndicator()))
            else if (skills.isEmpty)
              row(Icons.bolt_outlined, tr('Chưa có kỹ năng nào.'))
            else
              for (final k in skills)
                ListTile(
                  leading: Icon(k['source'] == 'base' ? Icons.folder_shared_outlined : Icons.bolt_outlined, color: pal.accentText),
                  title: Text('${k['name']}', style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
                  subtitle: Text('${k['description'] ?? ''}',
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13)),
                ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                  tr('Dạy kỹ năng mới: chat riêng với @{0}, ví dụ "lưu kỹ năng xử lý hoá đơn VAT: các bước…". Chỉ chủ trợ lý thêm / sửa / xoá được.',
                      [b.username]),
                  style: TextStyle(fontSize: 12.5, color: pal.sub)),
            ),
          ]),

          // Quyền và máy chạy.
          label(tr('Cài đặt khác')),
          card([
            row(Icons.group_outlined,
                b.allow.isEmpty ? tr('Ai được gọi bot: chỉ mình tôi') : tr('Ai được gọi bot: tôi và {0} người khác', [b.allow.length]),
                onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BotAccessPage(bot: b)));
              _reload();
            }),
            Divider(height: 1, indent: 56, color: pal.divider),
            row(
              Icons.computer_outlined,
              b.host == null
                  ? tr('Chưa gắn với máy nào')
                  : AgentService.isHere(b)
                      ? tr('Chạy nền trên máy này')
                      : tr('Chạy nền trên máy {0}', [b.host!]),
              sub: isDesktop && AgentService.isHere(b) ? null : tr('Trợ lý gắn cố định với máy tạo ra nó.'),
            ),
          ]),

          const SizedBox(height: 6),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              minimumSize: const Size.fromHeight(48),
              shape: const StadiumBorder(),
            ),
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('Xóa trợ lý')),
          ),
        ]),
      ),
    );
  }
}
