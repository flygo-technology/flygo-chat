import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_page.dart';
import 'ai_panel.dart';
import 'attach_panel.dart' show pickChat;
import 'common.dart';
import 'folder_picker.dart';
import 'home_page.dart' show ChatHost;
import 'schedules_view.dart';
import 'skills_view.dart';
import 'theme.dart';

/// Tab Agents ("Các trợ lý"), 4 tab con:
/// - "Dự án": phiên AI theo DỰ ÁN. Dự án "Chung" gom các phiên với từng trợ lý (chat 1-1); mỗi dự án thu gọn được,
///   bên trong là phiên đang mở / đã xong / đã lưu trữ, "+" tạo phiên, bấm giữ dự án để đổi tên / xoá.
/// - "Chat": phiên AI của các cuộc trò chuyện thường (nhóm, kênh, chat với người, luồng bí mật…), mỗi cuộc một mục như
///   dự án; bấm phiên thì mở như ở cột AI của cuộc đó. Mỗi phiên nằm ở đúng một trong hai tab "Dự án" / "Chat".
/// - "Hẹn giờ": lịch hẹn của các trợ lý ([SchedulesView]).
/// - "Skill": kỹ năng của các trợ lý của mình ([SkillsView]).
/// Bấm giữ hoặc chuột phải ở một phiên: tách phiên, đổi tên, đánh dấu xong, lưu trữ, xoá phiên.
class AgentsView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final String? selectedId;
  final double bottomPadding;
  final Widget? header;
  const AgentsView({super.key, required this.onOpen, this.selectedId, this.bottomPadding = 0, this.header});
  @override
  State<AgentsView> createState() => _AgentsViewState();
}

/// Một phiên: chat 1-1 với trợ lý (dự án Chung) hoặc kênh AI của dự án / của cuộc trò chuyện.
/// [bot] có thể chưa biết (chưa tải thành viên phiên): phiên vẫn hiện, để danh sách khớp số chưa đọc trên tab.
class _Entry {
  final MmChannel channel;
  final MmUser? bot;
  final bool session;
  _Entry(this.channel, this.bot, this.session);
}

/// Mã dự án "Chung" (không phải kênh thật).
const _general = '__general__';

/// Tab con đang chọn: giữ khi rời tab Agents rồi quay lại.
int _lastTab = 0;

class _AgentsViewState extends State<AgentsView> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this, initialIndex: _lastTab)
    ..addListener(() => _lastTab = _tabs.index);
  Set<String> _mine = const {};
  bool _busy = false;
  String? _project;
  /// Dự án đang mở (danh sách thu gọn / mở rộng). "Chung" mở sẵn.
  final Set<String> _expanded = {_general};
  /// Dự án đang xem phiên đã xong / đã lưu trữ.
  final Set<String> _doneOpen = {}, _archivedOpen = {};

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

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
      // Chat 1-1 với bot ("Chat chính") không hiện: chỉ các phiên.
      if (c.isAi && c.aiOwner == me) {
        final g = app.channels[c.aiGroup];
        if (g == null) continue;
        final inProject = project == _general ? app.isAgentDm(g) && !app.isForeignAgentDm(g) : g.id == project;
        if (!inProject) continue;
        out.add(_Entry(c, _botOf(app, c), true));
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
  /// Tạo dự án: tên + 2 lựa chọn "Tạo dự án trống" / "Chọn thư mục" (thư mục làm việc trên máy chạy bot).
  Future<void> _addProject(AppState app) async {
    final ctl = TextEditingController();
    final choice = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) {
        final ok = ctl.text.trim().isNotEmpty;
        return AlertDialog(
          title: Text(tr('Thêm dự án')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: ctl,
              autofocus: true,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(hintText: tr('VD: Báo cáo thuế 2026')),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: ok ? () => Navigator.pop(d, 'empty') : null,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(tr('Tạo dự án trống')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: ok ? () => Navigator.pop(d, 'folder') : null,
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(tr('Chọn thư mục')),
            ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy')))],
        );
      }),
    );
    final name = ctl.text.trim();
    if (choice == null || name.isEmpty || !mounted) return;
    String? path;
    if (choice == 'folder') {
      // Duyệt thư mục trên máy của trợ lý của mình (ưu tiên Claude).
      final bots = _bots(app).where((u) => app.isMyBot(u.id)).toList()
        ..sort((a, b) => (engineOf(a) == 'claude' ? 0 : 1).compareTo(engineOf(b) == 'claude' ? 0 : 1));
      if (bots.isEmpty) return;
      path = await pickAgentFolder(context, app, bots.first.id);
      if (path == null || !mounted) return;
    }
    await _guard(() async {
      final p = await app.createAgentProject(name, path: path);
      setState(() {
        _project = p.id;
        _expanded.add(p.id);
      });
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
  Future<void> _addSession(AppState app, [String? inProject]) async {
    if (inProject != null) _project = inProject;
    final bots = _bots(app);
    if (bots.isEmpty) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage()));
      return;
    }
    final bot = await _pickBot(bots);
    if (bot == null || !mounted) return;
    // Vào chat luôn với tên tạm "Phiên mới"; trợ lý tự đặt tên theo tin đầu tiên (runner, props flygo_auto_title).
    await _guard(() async {
      final project = _project;
      final group = project == null || project == _general ? app.channels[await app.openDirect(bot.id)]! : app.channels[project]!;
      final c = await app.createAiChannel(group, [bot.id], title: tr('Phiên mới'));
      _openSession(app, c);
    });
  }

  Future<void> _sessionMenu(AppState app, _Entry e) async {
    final c = e.channel;
    final a = await _sheet(e.session ? aiSessionLabel(c) : e.bot?.displayName ?? '', [
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
      // Chat chính (chat 1-1 với trợ lý): xoá đoạn chat khỏi danh sách (trợ lý vẫn còn, nhắn lại là hiện lại).
      if (!e.session) ('hide', Icons.delete_outline, tr('Xoá đoạn chat')),
    ]);
    if (a == null || !mounted) return;
    switch (a) {
      case 'fork':
        final t = await _ask(tr('Tách phiên'), tr('{0} (tách)', [e.session ? aiSessionLabel(c) : e.bot?.displayName ?? '']));
        if (t == null) return;
        await _guard(() async {
          // Tách từ chat 1-1: phiên mới gắn với chat 1-1; tách từ phiên: cùng dự án (cùng cuộc trò chuyện) với phiên gốc.
          final f = e.session ? await app.forkAiSession(c, t) : await app.createAiChannel(c, [?e.bot?.id], title: t, forkFrom: c.id);
          _openSession(app, f);
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
      case 'hide':
        final ok = await _confirm(tr('Xoá đoạn chat với {0}?', [e.bot?.displayName ?? '']),
            tr('Đoạn chat ẩn khỏi danh sách. Trợ lý vẫn còn, nhắn lại là hiện lại.'));
        if (ok == true) await _guard(() => app.hideConversation(c.id));
    }
  }

  /// Mở một phiên. Phiên của cuộc trò chuyện thường mở như ở cột AI của cuộc đó: máy tính nhiều cột thì mở cuộc trò
  /// chuyện ở giữa và phiên ở cột AI bên phải, điện thoại thì mở trang AI của cuộc đó đúng phiên này. Cuộc không có cột
  /// AI (vd. chat 1-1 với người) và phiên của "Chung" / dự án thì mở thẳng chat của phiên.
  void _openSession(AppState app, MmChannel c) {
    final g = app.channels[c.aiGroup];
    if (g == null || !app.isAiConversation(g) || !app.showsAiFor(g)) {
      widget.onOpen(c.id);
      return;
    }
    app.selectAiSession(g.id, c.id, thread: c.aiThread);
    final host = ChatHost.of(context);
    if (host?.openAi != null) {
      host!.openAi!(g.id, thread: c.aiThread);
    } else {
      openAiPanel(context, g.id, thread: c.aiThread);
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

  // Nút ＋ giống tab Chat, cùng độ cao (ngay trên thanh tab).
  Widget _fab(String label, VoidCallback onTap) => Positioned(
        right: 20,
        bottom: PlusFab.bottomOf(context),
        child: PlusFab(heroTag: 'agents-fab-$label', tooltip: label, onPressed: _busy ? null : onTap),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    if (!app.hasUsableAgents) return _noAgent(pal);
    // Số tin chưa đọc của tab "Dự án" / "Chat": cộng lại đúng bằng số trên tab Agents ([AppState.agentUnread]),
    // mỗi phiên thuộc đúng một trong hai tab (theo cuộc mà phiên gắn vào).
    int unreadOf(Iterable<String> groups) =>
        groups.fold(0, (n, id) => n + _entries(app, id).fold<int>(0, (m, e) => m + app.unreadAllOf(e.channel.id)));
    final projectUnread = unreadOf([_general, for (final p in app.agentProjects) p.id]);
    final chatUnread = unreadOf([for (final g in app.aiConversations) g.id]);
    return Column(children: [
      ?widget.header,
      TabBar(
        controller: _tabs,
        labelColor: pal.accentText,
        unselectedLabelColor: pal.sub,
        indicatorColor: pal.accent,
        dividerColor: pal.divider,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        tabs: [
          _UnreadTab(label: tr('Dự án'), unread: projectUnread),
          _UnreadTab(label: tr('Chat'), unread: chatUnread),
          _UnreadTab(label: tr('Hẹn giờ')),
          _UnreadTab(label: tr('Skill')),
        ],
      ),
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _projectsTab(app, pal),
          _chatsTab(app, pal),
          SchedulesView(header: const SizedBox.shrink(), bottomPadding: widget.bottomPadding, plusFab: true),
          SkillsView(onOpen: widget.onOpen, bottomPadding: widget.bottomPadding),
        ]),
      ),
    ]);
  }

  /// Một mục thu gọn / mở rộng: dự án ([channel]: bấm giữ để đổi tên / xoá) hoặc cuộc trò chuyện thường
  /// ([conversation]: hiện ảnh của cuộc đó); bên trong là các phiên đang mở, đã xong, đã lưu trữ.
  List<Widget> _group(AppState app, Pal pal, {required String id, required String name, MmChannel? channel, MmChannel? conversation}) {
    Widget section(String label, bool open, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 8, 16, 8),
            child: Row(children: [
              Text(label, style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600, fontSize: 13.5)),
              Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: pal.sub),
            ]),
          ),
        );
    final all = _entries(app, id);
    final open = all.where((e) => !e.channel.aiArchived && !(e.session && e.channel.aiDone)).toList();
    final done = all.where((e) => !e.channel.aiArchived && e.session && e.channel.aiDone).toList();
    final archived = all.where((e) => e.channel.aiArchived).toList();
    final unread = all.fold<int>(0, (n, e) => n + app.unreadAllOf(e.channel.id));
    final expanded = _expanded.contains(id);
    return [
      InkWell(
        onTap: () => setState(() => expanded ? _expanded.remove(id) : _expanded.add(id)),
        onLongPress: channel == null ? null : () => _projectMenu(app, channel),
        onSecondaryTap: channel == null ? null : () => _projectMenu(app, channel),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(children: [
            AnimatedRotation(
              turns: expanded ? .25 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(Icons.chevron_right_rounded, color: pal.sub),
            ),
            const SizedBox(width: 6),
            if (conversation != null) ...[
              () {
                final o = conversation.otherUserId(app.me?.id ?? '');
                final other = o == app.me?.id ? null : o;
                return Avatar(
                    userId: other, name: name, size: 26, status: false, icon: other == null ? chatIcon(conversation) : null, channel: conversation);
              }(),
              const SizedBox(width: 8),
            ],
            // Gọn: chỉ tên dự án, một dòng.
            Expanded(
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            if (unread > 0 && !expanded)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(12)),
                child: Text(unread > 99 ? '99+' : '$unread', style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            // "+" bên phải tên dự án / cuộc trò chuyện: phiên mới ở đó.
            IconButton(
              tooltip: tr('Phiên mới'),
              icon: Icon(Icons.add_rounded, color: pal.text),
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _expanded.add(id));
                      _addSession(app, id);
                    },
            ),
          ]),
        ),
      ),
      if (expanded) ...[
        for (final e in open) _tile(app, pal, e),
        if (open.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 16, 10),
            child: Text(tr('Chưa có phiên. Bấm + để bắt đầu.'), style: TextStyle(color: pal.sub, fontSize: 13.5)),
          ),
        if (done.isNotEmpty)
          section(tr('Đã xong ({0})', [done.length]), _doneOpen.contains(id),
              () => setState(() => _doneOpen.contains(id) ? _doneOpen.remove(id) : _doneOpen.add(id))),
        if (_doneOpen.contains(id)) for (final e in done) _tile(app, pal, e),
        if (archived.isNotEmpty)
          section(tr('Đã lưu trữ ({0})', [archived.length]), _archivedOpen.contains(id),
              () => setState(() => _archivedOpen.contains(id) ? _archivedOpen.remove(id) : _archivedOpen.add(id))),
        if (_archivedOpen.contains(id)) for (final e in archived) _tile(app, pal, e),
      ],
      Divider(height: 1, indent: 16, color: pal.divider),
    ];
  }

  /// Lời nhắc khi tab trống: biểu tượng, tiêu đề, giải thích, nút (tuỳ chọn).
  Widget _empty(Pal pal, String title, String body, {String? action, VoidCallback? onAction}) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
        child: Column(children: [
          Icon(Icons.auto_awesome_outlined, size: 44, color: pal.sub),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: pal.sub)),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(icon: const Icon(Icons.chat_bubble_outline_rounded), label: Text(action), onPressed: _busy ? null : onAction),
          ],
        ]),
      );

  // ---------------------------------------------------------------- tab "Dự án": "Chung" + các dự án
  Widget _projectsTab(AppState app, Pal pal) {
    final projects = app.agentProjects;
    final general = _entries(app, _general).isNotEmpty;
    return Stack(children: [
      // Không có dự án nào (kể cả "Chung" chưa có phiên): lời nhắc + nút "Thêm".
      ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding + 72), children: [
        if (general) ..._group(app, pal, id: _general, name: tr('Chung')),
        for (final p in projects) ..._group(app, pal, id: p.id, name: app.channelTitle(p), channel: p),
        if (!general && projects.isEmpty)
          _empty(pal, tr('Chưa có phiên nào với trợ lý AI'),
              tr('Bắt đầu một phiên để nhờ trợ lý trả lời, tóm tắt hoặc làm việc cho bạn. Trong nhóm chat, gõ @tên trợ lý để gọi.'),
              action: tr('Phiên mới với trợ lý'), onAction: () => _addSession(app, _general)),
      ]),
      _fab(tr('Thêm'), () async {
        final a = await _sheet(tr('Thêm'), [
          ('session', Icons.chat_bubble_outline_rounded, tr('Phiên mới với trợ lý')),
          ('project', Icons.create_new_folder_outlined, tr('Thêm dự án')),
        ]);
        if (!mounted) return;
        if (a == 'session') _addSession(app, _general);
        if (a == 'project') _addProject(app);
      }),
    ]);
  }

  // ---------------------------------------------------------------- tab "Chat": phiên AI theo cuộc trò chuyện
  /// Phiên AI của các cuộc trò chuyện thường (cột AI bên phải của từng cuộc), cuộc mới hoạt động trước.
  Widget _chatsTab(AppState app, Pal pal) {
    final conversations = app.aiConversations;
    return Stack(children: [
      ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding + 72), children: [
        for (final g in conversations) ..._group(app, pal, id: g.id, name: app.channelTitle(g), conversation: g),
        if (conversations.isEmpty)
          _empty(pal, tr('Chưa có phiên AI nào trong các cuộc trò chuyện'),
              tr('Mở một nhóm hoặc kênh rồi bấm nút AI ở góc trên để nhờ trợ lý, hoặc bấm + để chọn cuộc trò chuyện.')),
      ]),
      _fab(tr('Phiên mới trong cuộc trò chuyện'), () => _addInConversation(app)),
    ]);
  }

  /// ＋ của tab "Chat": chọn một cuộc trò chuyện có cột AI (nhóm, kênh, luồng bí mật…) rồi tạo phiên AI ở đó.
  Future<void> _addInConversation(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    final id = await pickChat(context, title: tr('Phiên mới trong cuộc trò chuyện'));
    if (id == null || !mounted) return;
    final g = app.channels[id];
    if (g == null || !app.isAiConversation(g) || !app.showsAiFor(g)) {
      messenger.showSnackBar(toast(Text(tr('Cuộc trò chuyện này không dùng được trợ lý AI.'))));
      return;
    }
    setState(() => _expanded.add(id));
    await _addSession(app, id);
  }

  /// Một phiên: biểu tượng trạng thái, tên phiên, giờ tin cuối (và số tin chưa đọc), một dòng.
  Widget _tile(AppState app, Pal pal, _Entry e) {
    final c = e.channel;
    final unread = app.unreadAllOf(c.id);
    final title = e.session ? aiSessionLabel(c) : tr('Chat chính');
    // Phiên của cuộc trò chuyện mở ở cột AI (máy tính): chọn khi cuộc đó đang mở ở giữa và đây là phiên đang chọn.
    final selected = c.id == widget.selectedId ||
        (c.aiGroup != null && c.aiGroup == widget.selectedId && c.aiThread == null && app.aiChannelFor(c.aiGroup!)?.id == c.id);
    return Material(
      color: selected ? pal.accent.withValues(alpha: .12) : Colors.transparent,
      child: InkWell(
        onTap: () => _openSession(app, c),
        onLongPress: () => _sessionMenu(app, e),
        onSecondaryTap: () => _sessionMenu(app, e),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 10, 16, 10),
          child: Row(children: [
            AiStatusIcon(aiSessionState(app, c), size: 18),
            const SizedBox(width: 10),
            // Phiên gắn với một luồng của cuộc trò chuyện.
            if (c.aiThread != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Tooltip(message: tr('Phiên của luồng'), child: Icon(Icons.forum_outlined, size: 15, color: pal.sub)),
              ),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500, color: pal.text)),
            ),
            const SizedBox(width: 8),
            Text(listTime(_at(app, c)), style: TextStyle(fontSize: 12.5, color: unread > 0 ? pal.accentText : pal.sub)),
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(12)),
                child: Text(unread > 99 ? '99+' : '$unread',
                    style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ),
    );
  }

  /// Chưa có trợ lý AI nào: chỉ hiện lời nhắc, không có nút thêm.
  Widget _noAgent(Pal pal) => Column(children: [
        ?widget.header,
        Expanded(child: noAgentNotice(pal)),
      ]);
}

/// Nhãn tab con, kèm số tin chưa đọc (nền màu nhấn như số ở danh sách).
class _UnreadTab extends StatelessWidget {
  final String label;
  final int unread;
  const _UnreadTab({required this.label, this.unread = 0});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Tab(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (unread > 0)
          Container(
            margin: const EdgeInsets.only(left: 5),
            constraints: const BoxConstraints(minWidth: 18),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(10)),
            child: Text(unread > 99 ? '99+' : '$unread',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}

/// Lời nhắc "Bạn chưa tích hợp AI agent" (tab Agents, tab Hẹn giờ).
Widget noAgentNotice(Pal pal) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome_outlined, size: 52, color: pal.sub),
          const SizedBox(height: 12),
          Text(tr('Bạn chưa tích hợp AI agent'),
              textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
        ]),
      ),
    );

