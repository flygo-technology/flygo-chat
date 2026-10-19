import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_page.dart';
import 'ai_panel.dart';
import 'common.dart';
import 'theme.dart';

/// Tab Agents: quản lý các cuộc trò chuyện riêng với trợ lý AI (không tính chat AI cột phải của từng nhóm).
/// Danh sách phẳng, mới nhất trước: chat chính 1-1 với từng trợ lý và các phiên riêng (kênh AI gắn với chat 1-1 đó).
/// Phiên tách (fork) có dòng "↳ tách từ …"; nút ＋ tạo phiên mới; giữ (chuột phải) để tách / đổi tên / xong / lưu trữ.
class AgentsView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final String? selectedId;
  final double bottomPadding;
  final Widget? header;
  const AgentsView({super.key, required this.onOpen, this.selectedId, this.bottomPadding = 0, this.header});
  @override
  State<AgentsView> createState() => _AgentsViewState();
}

/// Một dòng của tab Agents: chat chính với trợ lý ([session] null) hoặc một phiên riêng.
class _Entry {
  final MmChannel channel;
  final MmUser bot;
  final bool session;
  _Entry(this.channel, this.bot, this.session);
}

class _AgentsViewState extends State<AgentsView> {
  Set<String> _mine = const {};
  bool _busy = false;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().myBotIds().then((v) {
      if (mounted) setState(() => _mine = v);
    }).catchError((_) {});
  }

  /// Trợ lý mình gọi được (của mình hoặc được chia sẻ).
  List<MmUser> _bots(AppState app) => app.users.values
      .where((u) => u.isBot && u.deleteAt == 0 && app.isAssistant(u.id) && app.canCallBot(u, _mine))
      .toList()
    ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

  List<_Entry> _entries(AppState app) {
    final me = app.me?.id;
    final out = <_Entry>[];
    for (final c in app.channels.values) {
      if (c.deleteAt != 0) continue;
      if (app.isAgentDm(c)) {
        final bot = app.users[c.otherUserId(me ?? '')];
        if (bot != null) out.add(_Entry(c, bot, false));
      } else if (c.isAi && c.aiOwner == me) {
        // Phiên riêng: kênh AI gắn với chat 1-1 với trợ lý (phiên của nhóm chat không tính).
        final dm = app.channels[c.aiGroup];
        if (dm == null || !app.isAgentDm(dm)) continue;
        final bot = app.users[dm.otherUserId(me ?? '')];
        if (bot != null) out.add(_Entry(c, bot, true));
      }
    }
    int at(MmChannel c) => app.latest[c.id]?.createAt ?? (c.lastPostAt > 0 ? c.lastPostAt : c.createAt);
    out.sort((a, b) => at(b.channel).compareTo(at(a.channel)));
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

  /// ＋ Phiên mới: chọn trợ lý, đặt tên (không bắt buộc), tạo phiên riêng rồi mở.
  Future<void> _newSession(AppState app) async {
    final bots = _bots(app);
    if (bots.isEmpty) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage()));
      return;
    }
    final bot = bots.length == 1 ? bots.first : await _pickBot(bots);
    if (bot == null || !mounted) return;
    final title = await askSessionTitle(context, tr('Phiên mới với {0}', [bot.displayName]), '');
    if (title == null) return;
    await _guard(() async {
      final dm = app.channels[await app.openDirect(bot.id)]!;
      final c = await app.createAiChannel(dm, [bot.id], title: title.trim().isEmpty ? tr('Phiên mới') : title);
      widget.onOpen(c.id);
    });
  }

  Future<MmUser?> _pickBot(List<MmUser> bots) {
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

  /// Giữ / chuột phải: chat chính chỉ tách phiên được; phiên riêng có đủ thao tác.
  Future<void> _menu(AppState app, _Entry e) async {
    final pal = Pal.of(context);
    final actions = e.session
        ? aiSessionActions(e.channel)
        : [('fork', Icons.call_split, tr('Tách phiên (fork)')), ('new', Icons.add_comment_outlined, tr('Phiên mới'))];
    final a = await showModalBottomSheet<String>(
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
            child: Text(e.session ? aiSessionLabel(e.channel) : e.bot.displayName,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          for (final (v, i, t) in actions)
            ListTile(leading: Icon(i, color: pal.sub), title: Text(t, style: TextStyle(color: pal.text)), onTap: () => Navigator.pop(ctx, v)),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    if (a == 'new') return _newSession(app);
    if (!e.session && a == 'fork') {
      // Tách từ chat chính: phiên mới gắn với chat 1-1, runner fork phiên của chat chính.
      final t = await askSessionTitle(context, tr('Tách phiên'), tr('{0} (tách)', [e.bot.displayName]));
      if (t == null) return;
      return _guard(() async {
        final c = await app.createAiChannel(e.channel, [e.bot.id], title: t, forkFrom: e.channel.id);
        widget.onOpen(c.id);
      });
    }
    if (mounted) await runAiSessionAction(context, e.channel, a);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final all = _entries(app);
    final open = all.where((e) => !e.session || !e.channel.aiDone).toList();
    final done = all.where((e) => e.session && e.channel.aiDone).toList();
    final withChat = {for (final e in all) if (!e.session) e.bot.id};
    final idle = _bots(app).where((b) => !withChat.contains(b.id)).toList();

    return Stack(children: [
      Column(children: [
        ?widget.header,
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: all.isEmpty && idle.isEmpty
              ? _empty(pal)
              : ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding + 72), children: [
                  for (final e in open) _tile(app, pal, e),
                  if (done.isNotEmpty)
                    ListTile(
                      dense: true,
                      leading: Icon(_showDone ? Icons.expand_less : Icons.expand_more, color: pal.sub),
                      title: Text(tr('Đã xong ({0})', [done.length]), style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600)),
                      onTap: () => setState(() => _showDone = !_showDone),
                    ),
                  if (_showDone) for (final e in done) _tile(app, pal, e),
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
      Positioned(
        right: 16,
        bottom: widget.bottomPadding + 16,
        child: FloatingActionButton.extended(
          heroTag: 'agents-new',
          onPressed: _busy ? null : () => _newSession(app),
          icon: const Icon(Icons.add),
          label: Text(tr('Phiên mới')),
        ),
      ),
    ]);
  }

  Widget _tile(AppState app, Pal pal, _Entry e) {
    final c = e.channel;
    final last = app.latest[c.id];
    final unread = app.unreadAllOf(c.id);
    final at = last?.createAt ?? (c.lastPostAt > 0 ? c.lastPostAt : c.createAt);
    final parent = c.aiForkOf == null ? null : app.channels[c.aiForkOf];
    final parentName = parent == null ? null : (parent.isAi ? aiSessionLabel(parent) : app.channelTitle(parent));
    final title = e.session ? aiSessionLabel(c) : e.bot.displayName;
    final preview = last == null ? '' : app.previewText(last).replaceAll('\n', ' ');
    final selected = c.id == widget.selectedId;
    return Material(
      color: selected ? pal.accent.withValues(alpha: .12) : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onOpen(c.id),
        onLongPress: () => _menu(app, e),
        onSecondaryTap: () => _menu(app, e),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
                  ),
                  Text(listTime(at), style: TextStyle(fontSize: 12.5, color: unread > 0 ? pal.accentText : pal.sub)),
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
                  Expanded(
                    child: Text(preview,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: pal.sub)),
                  ),
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
          ]),
        ),
      ),
    );
  }

  Widget _empty(Pal pal) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.auto_awesome_outlined, size: 48, color: pal.sub),
            const SizedBox(height: 12),
            Text(tr('Chưa có trợ lý AI nào'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
            const SizedBox(height: 6),
            Text(tr('Tạo trợ lý Claude / Codex chạy trên máy của bạn, rồi trò chuyện với trợ lý ở đây.'),
                textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: Text(tr('Tạo trợ lý AI')),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage())),
            ),
          ]),
        ),
      );
}
