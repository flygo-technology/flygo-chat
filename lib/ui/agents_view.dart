import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_page.dart';
import 'ai_panel.dart';
import 'common.dart';
import 'theme.dart';

/// Tab Agents: quản lý các cuộc trò chuyện với trợ lý AI theo DỰ ÁN (không tính chat AI cột phải của từng nhóm).
/// - Cấp 1: danh sách dự án + "Thêm dự án". Dự án "Chung" gom chat 1-1 với từng trợ lý và các phiên tách từ đó.
/// - Cấp 2 (bấm một dự án): các phiên trong dự án (mới nhất trước, phiên tách có "↳ tách từ …") + "Thêm phiên".
/// - Bấm giữ hoặc ⋮ ở một phiên: tách phiên, đổi tên, đánh dấu xong, lưu trữ, xoá phiên.
class AgentsView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final String? selectedId;
  final double bottomPadding;
  final Widget? header;
  const AgentsView({super.key, required this.onOpen, this.selectedId, this.bottomPadding = 0, this.header});
  @override
  State<AgentsView> createState() => _AgentsViewState();
}

/// Một phiên: chat 1-1 với trợ lý (dự án Chung) hoặc kênh AI của dự án.
class _Entry {
  final MmChannel channel;
  final MmUser bot;
  final bool session;
  _Entry(this.channel, this.bot, this.session);
}

/// Mã dự án "Chung" (không phải kênh thật).
const _general = '__general__';

class _AgentsViewState extends State<AgentsView> {
  Set<String> _mine = const {};
  bool _busy = false;
  bool _showDone = false;
  bool _showArchived = false;
  String? _project;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().myBotIds().then((v) {
      if (mounted) setState(() => _mine = v);
    }).catchError((_) {});
  }

  List<MmUser> _bots(AppState app) => app.users.values
      .where((u) => u.isBot && u.deleteAt == 0 && app.isAssistant(u.id) && app.canCallBot(u, _mine))
      .toList()
    ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

  int _at(AppState app, MmChannel c) => app.latest[c.id]?.createAt ?? (c.lastPostAt > 0 ? c.lastPostAt : c.createAt);

  /// Trợ lý của một phiên AI (thành viên bot đã biết, hoặc bên kia của chat 1-1 gốc).
  MmUser? _botOf(AppState app, MmChannel c) {
    final me = app.me?.id ?? '';
    final g = app.channels[c.aiGroup];
    if (g != null && g.isDirect) return app.users[g.otherUserId(me)];
    for (final id in app.knownMemberIds(c.id) ?? const <String>[]) {
      final u = app.users[id];
      if (u != null && u.isBot && app.isAssistant(id)) return u;
    }
    return null;
  }

  /// Các phiên của một dự án ("Chung" = chat 1-1 với trợ lý + phiên tách từ chat 1-1).
  List<_Entry> _entries(AppState app, String project) {
    final me = app.me?.id;
    final out = <_Entry>[];
    for (final c in app.channels.values) {
      if (c.deleteAt != 0) continue;
      if (project == _general && app.isAgentDm(c)) {
        final bot = app.users[c.otherUserId(me ?? '')];
        if (bot != null) out.add(_Entry(c, bot, false));
      } else if (c.isAi && c.aiOwner == me) {
        final g = app.channels[c.aiGroup];
        if (g == null) continue;
        final inProject = project == _general ? app.isAgentDm(g) : g.id == project;
        if (!inProject) continue;
        final bot = _botOf(app, c);
        if (bot != null) out.add(_Entry(c, bot, true));
      }
    }
    out.sort((a, b) => _at(app, b.channel).compareTo(_at(app, a.channel)));
    return out;
  }

  Future<void> _guard(Future<void> Function() f) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await f();
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _ask(String title, String initial, {String? hint}) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
          FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text(tr('Xong'))),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- dự án
  Future<void> _addProject(AppState app) async {
    final name = await _ask(tr('Thêm dự án'), '', hint: tr('VD: Báo cáo thuế 2026'));
    if (name == null || name.trim().isEmpty) return;
    await _guard(() async {
      final p = await app.createAgentProject(name);
      setState(() => _project = p.id);
    });
  }

  Future<void> _projectMenu(AppState app, MmChannel p) async {
    final a = await _sheet(app.channelTitle(p), [
      ('rename', Icons.edit_outlined, tr('Đổi tên dự án')),
      ('delete', Icons.delete_outline, tr('Xoá dự án')),
    ]);
    if (a == 'rename') {
      final t = await _ask(tr('Đổi tên dự án'), app.channelTitle(p));
      if (t != null && t.trim().isNotEmpty) await _guard(() => app.renameChannel(p.id, t.trim()));
    } else if (a == 'delete') {
      final n = _entries(app, p.id).length;
      final ok = await _confirm(tr('Xoá dự án "{0}"?', [app.channelTitle(p)]),
          n == 0 ? tr('Dự án chưa có phiên nào.') : tr('Cả {0} phiên trong dự án cũng bị xoá, không khôi phục được.', [n]));
      if (ok != true) return;
      await _guard(() async {
        for (final e in _entries(app, p.id)) {
          await app.archiveChannel(e.channel.id);
        }
        await app.archiveChannel(p.id);
        if (_project == p.id) setState(() => _project = null);
      });
    }
  }

  // ---------------------------------------------------------------- phiên
  Future<MmUser?> _pickBot(List<MmUser> bots) async {
    if (bots.length == 1) return bots.first;
    final pal = Pal.of(context);
    return showModalBottomSheet<MmUser>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: pal.surface,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(tr('Chọn trợ lý'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          for (final b in bots)
            ListTile(
              leading: Avatar(userId: b.id, name: b.displayName, size: 40),
              title: Text(b.displayName, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
              trailing: EngineIcon(engineOf(b) ?? '', size: 18, color: pal.sub),
              onTap: () => Navigator.pop(ctx, b),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// "Thêm phiên": chọn trợ lý, đặt tên (không bắt buộc), tạo phiên trong dự án đang mở rồi vào chat.
  Future<void> _addSession(AppState app) async {
    final bots = _bots(app);
    if (bots.isEmpty) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage()));
      return;
    }
    final bot = await _pickBot(bots);
    if (bot == null || !mounted) return;
    final title = await _ask(tr('Phiên mới với {0}', [bot.displayName]), '', hint: tr('Tên phiên (không bắt buộc)'));
    if (title == null) return;
    await _guard(() async {
      final project = _project;
      final group = project == null || project == _general ? app.channels[await app.openDirect(bot.id)]! : app.channels[project]!;
      final c = await app.createAiChannel(group, [bot.id], title: title.trim().isEmpty ? tr('Phiên mới') : title.trim());
      widget.onOpen(c.id);
    });
  }

  Future<void> _sessionMenu(AppState app, _Entry e) async {
    final c = e.channel;
    final a = await _sheet(e.session ? aiSessionLabel(c) : e.bot.displayName, [
      ('fork', Icons.call_split, tr('Tách phiên (fork)')),
      if (e.session) ('rename', Icons.edit_outlined, tr('Đổi tên phiên')),
      if (e.session)
        c.aiDone
            ? ('undone', Icons.replay_rounded, tr('Mở lại phiên'))
            : ('done', Icons.check_circle_outline_rounded, tr('Đánh dấu là xong')),
      if (e.session)
        c.aiArchived
            ? ('unarchive', Icons.unarchive_outlined, tr('Bỏ lưu trữ'))
            : ('archive', Icons.archive_outlined, tr('Lưu trữ phiên')),
      if (e.session) ('delete', Icons.delete_outline, tr('Xoá phiên')),
    ]);
    if (a == null || !mounted) return;
    switch (a) {
      case 'fork':
        final t = await _ask(tr('Tách phiên'), tr('{0} (tách)', [e.session ? aiSessionLabel(c) : e.bot.displayName]));
        if (t == null) return;
        await _guard(() async {
          // Tách từ chat 1-1: phiên mới gắn với chat 1-1; tách từ phiên: cùng dự án với phiên gốc.
          final f = e.session ? await app.forkAiSession(c, t) : await app.createAiChannel(c, [e.bot.id], title: t, forkFrom: c.id);
          widget.onOpen(f.id);
        });
      case 'rename':
        final t = await _ask(tr('Đổi tên phiên'), c.aiTitle);
        if (t != null) await _guard(() => app.renameAiSession(c, t));
      case 'done' || 'undone':
        await _guard(() => app.setAiDone(c, a == 'done'));
      case 'archive' || 'unarchive':
        await _guard(() => app.setAiArchived(c, a == 'archive'));
      case 'delete':
        final ok = await _confirm(tr('Xoá phiên "{0}"?', [aiSessionLabel(c)]), tr('Phiên bị xoá khỏi danh sách, trợ lý dừng làm việc ở phiên này.'));
        if (ok == true) await _guard(() => app.archiveChannel(c.id));
    }
  }

  // ---------------------------------------------------------------- giao diện chung
  Future<String?> _sheet(String title, List<(String, IconData, String)> actions) {
    final pal = Pal.of(context);
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: pal.surface,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          for (final (v, i, t) in actions)
            ListTile(
              leading: Icon(i, color: v == 'delete' ? Colors.redAccent : pal.sub),
              title: Text(t, style: TextStyle(color: v == 'delete' ? Colors.redAccent : pal.text)),
              onTap: () => Navigator.pop(ctx, v),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
            TextButton(
                onPressed: () => Navigator.pop(d, true),
                child: Text(tr('Xoá'), style: const TextStyle(color: Colors.redAccent))),
          ],
        ),
      );

  Widget _fab(String label, VoidCallback onTap) => Positioned(
        right: 16,
        bottom: widget.bottomPadding + 16,
        child: FloatingActionButton.extended(
          heroTag: 'agents-fab',
          onPressed: _busy ? null : onTap,
          icon: const Icon(Icons.add),
          label: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    var project = _project;
    // Dự án đã bị xoá (ở máy khác): quay về danh sách dự án.
    if (project != null && project != _general && (app.channels[project]?.deleteAt ?? 1) != 0) project = null;
    return project == null ? _projects(app, pal) : _sessions(app, pal, project);
  }

  // ---------------------------------------------------------------- cấp 1: dự án
  Widget _projects(AppState app, Pal pal) {
    final general = _entries(app, _general);
    final projects = app.agentProjects;
    Widget row({required String id, required String name, required IconData icon, required List<_Entry> items, MmChannel? channel}) {
      final open = items.where((e) => !e.channel.aiArchived && !e.channel.aiDone).length;
      final running = items.where((e) => aiSessionRunning(app, e.channel.id)).length;
      final unread = items.fold<int>(0, (n, e) => n + app.unreadAllOf(e.channel.id));
      final last = items.isEmpty ? (channel?.createAt ?? 0) : _at(app, items.first.channel);
      return ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: pal.accent.withValues(alpha: .14), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: pal.accentText),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
        subtitle: Text(
          [
            tr('{0} phiên', [open]),
            if (running > 0) tr('{0} đang chạy', [running]),
            if (last > 0) listTime(last),
          ].join(' · '),
          style: TextStyle(color: running > 0 ? pal.accentText : pal.sub, fontSize: 13),
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(12)),
              child: Text(unread > 99 ? '99+' : '$unread', style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          if (channel != null)
            IconButton(icon: Icon(Icons.more_vert, color: pal.sub), onPressed: () => _projectMenu(app, channel))
          else
            Icon(Icons.chevron_right, color: pal.sub),
        ]),
        onTap: () => setState(() => _project = id),
        onLongPress: channel == null ? null : () => _projectMenu(app, channel),
      );
    }

    return Stack(children: [
      Column(children: [
        ?widget.header,
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding + 72), children: [
            row(id: _general, name: tr('Chung'), icon: Icons.forum_outlined, items: general),
            for (final p in projects) row(id: p.id, name: app.channelTitle(p), icon: Icons.folder_outlined, items: _entries(app, p.id), channel: p),
            if (projects.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Text(tr('Tạo dự án để gom các phiên làm việc với trợ lý theo từng việc lớn.'),
                    textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
              ),
          ]),
        ),
      ]),
      _fab(tr('Thêm dự án'), () => _addProject(app)),
    ]);
  }

  // ---------------------------------------------------------------- cấp 2: phiên trong dự án
  Widget _sessions(AppState app, Pal pal, String project) {
    final all = _entries(app, project);
    final open = all.where((e) => !e.channel.aiArchived && !(e.session && e.channel.aiDone)).toList();
    final done = all.where((e) => !e.channel.aiArchived && e.session && e.channel.aiDone).toList();
    final archived = all.where((e) => e.channel.aiArchived).toList();
    final p = app.channels[project];
    final name = project == _general ? tr('Chung') : (p == null ? '' : app.channelTitle(p));
    // Dự án Chung: trợ lý chưa có chat 1-1 nào.
    final withChat = {for (final e in all) if (!e.session) e.bot.id};
    final idle = project == _general ? _bots(app).where((b) => !withChat.contains(b.id)).toList() : const <MmUser>[];

    Widget section(String label, bool openFlag, VoidCallback onTap) => ListTile(
          dense: true,
          leading: Icon(openFlag ? Icons.expand_less : Icons.expand_more, color: pal.sub),
          title: Text(label, style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600)),
          onTap: onTap,
        );

    return Stack(children: [
      Column(children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
            child: Row(children: [
              IconButton(icon: Icon(Icons.arrow_back, color: pal.text), onPressed: () => setState(() => _project = null)),
              Expanded(
                child: Text(name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              if (p != null) IconButton(icon: Icon(Icons.more_vert, color: pal.text), onPressed: () => _projectMenu(app, p)),
            ]),
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: all.isEmpty && idle.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(tr('Chưa có phiên nào. Bấm "Thêm phiên" để bắt đầu làm việc với trợ lý.'),
                        textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
                  ),
                )
              : ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding + 72), children: [
                  for (final e in open) _tile(app, pal, e),
                  if (done.isNotEmpty) section(tr('Đã xong ({0})', [done.length]), _showDone, () => setState(() => _showDone = !_showDone)),
                  if (_showDone) for (final e in done) _tile(app, pal, e),
                  if (archived.isNotEmpty)
                    section(tr('Đã lưu trữ ({0})', [archived.length]), _showArchived, () => setState(() => _showArchived = !_showArchived)),
                  if (_showArchived) for (final e in archived) _tile(app, pal, e),
                  if (idle.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                      child: Text(tr('Chưa trò chuyện'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.sub)),
                    ),
                    for (final u in idle)
                      ListTile(
                        leading: Avatar(userId: u.id, name: u.displayName),
                        title: Text(u.displayName, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
                        subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
                        trailing: EngineIcon(engineOf(u) ?? '', size: 18, color: pal.sub),
                        onTap: _busy ? null : () => _guard(() async => widget.onOpen(await app.openDirect(u.id))),
                      ),
                  ],
                ]),
        ),
      ]),
      _fab(tr('Thêm phiên'), () => _addSession(app)),
    ]);
  }

  Widget _tile(AppState app, Pal pal, _Entry e) {
    final c = e.channel;
    final last = app.latest[c.id];
    final unread = app.unreadAllOf(c.id);
    final parent = c.aiForkOf == null ? null : app.channels[c.aiForkOf];
    final parentName = parent == null ? null : (parent.isAi ? aiSessionLabel(parent) : app.channelTitle(parent));
    final title = e.session ? aiSessionLabel(c) : e.bot.displayName;
    final preview = last == null ? '' : app.previewText(last).replaceAll('\n', ' ');
    final selected = c.id == widget.selectedId;
    return Material(
      color: selected ? pal.accent.withValues(alpha: .12) : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onOpen(c.id),
        onLongPress: () => _sessionMenu(app, e),
        onSecondaryTap: () => _sessionMenu(app, e),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              Avatar(userId: e.bot.id, name: e.bot.displayName, size: 48),
              if (e.session)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: pal.chatBg, shape: BoxShape.circle),
                    child: AiStatusIcon(aiSessionState(app, c), size: 16),
                  ),
                ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  EngineIcon(engineOf(e.bot) ?? '', size: 15, color: pal.text),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(title,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
                  ),
                  Text(listTime(_at(app, c)), style: TextStyle(fontSize: 12.5, color: unread > 0 ? pal.accentText : pal.sub)),
                ]),
                if (e.session)
                  Text(
                    parentName != null ? '↳ ${tr('tách từ {0}', [parentName])} · ${e.bot.displayName}' : e.bot.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: pal.sub),
                  ),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: pal.sub))),
                  if (unread > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(12)),
                      child: Text(unread > 99 ? '99+' : '$unread',
                          style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                ]),
              ]),
            ),
            IconButton(icon: Icon(Icons.more_vert, color: pal.sub), onPressed: () => _sessionMenu(app, e)),
          ]),
        ),
      ),
    );
  }
}
