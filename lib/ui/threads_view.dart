import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_page.dart' show openThread;
import 'common.dart';
import 'home_page.dart' show ChatHost;
import 'sub_channel.dart';
import 'theme.dart';

/// Tab "Luồng riêng": các luồng công việc riêng và luồng riêng tư còn dang dở, có nút đóng luồng.
class ThreadsView extends StatefulWidget {
  final Widget? header;
  final String query;
  final double bottomPadding;
  const ThreadsView({super.key, this.header, this.query = '', this.bottomPadding = 0});
  @override
  State<ThreadsView> createState() => _ThreadsViewState();
}

class _ThreadsViewState extends State<ThreadsView> {
  bool _showClosed = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadWorkThreads();
  }

  bool _match(String text) {
    final q = widget.query.trim().toLowerCase();
    return q.isEmpty || text.toLowerCase().contains(q);
  }

  void _openPrivate(MmChannel c) {
    final host = ChatHost.of(context);
    final parent = c.subParent;
    if (host != null && host.openSide != null && parent != null && context.read<AppState>().channels.containsKey(parent)) {
      host.openChat(parent);
      host.openSide!(c.id);
      return;
    }
    openChannelAnywhere(context, c.id);
  }

  void _openWork(MmPost root) {
    final host = ChatHost.of(context);
    if (host != null) host.openChat(root.channelId);
    openThread(context, root.channelId, root.id);
  }

  Future<void> _run(Future<void> Function() job, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await job();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final privates = app.privateThreads
        .where((c) => c.isClosed == _showClosed && _match('${c.displayName} ${app.channelTitle(app.channels[c.subParent] ?? c)}'))
        .toList();
    final works = app.workThreads
        .where((t) => app.isThreadClosed(t.root.channelId, t.root.id) == _showClosed && _match(plainPreview(t.root.message)))
        .toList();

    Widget section(String title, int n) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: Text('$title ($n)'.toUpperCase(), style: TextStyle(fontSize: 12.5, color: pal.sub, letterSpacing: .3, fontWeight: FontWeight.w600)),
        );

    Widget action(bool closed, VoidCallback onTap) => TextButton(
          style: TextButton.styleFrom(foregroundColor: closed ? pal.accentText : Colors.redAccent, visualDensity: VisualDensity.compact),
          onPressed: onTap,
          child: Text(closed ? tr('Mở lại') : tr('Đóng luồng')),
        );

    final rows = <Widget>[
      if (widget.header != null) widget.header!,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: false, label: Text(tr('Đang dang dở'))),
            ButtonSegment(value: true, label: Text(tr('Đã đóng'))),
          ],
          selected: {_showClosed},
          onSelectionChanged: (s) => setState(() => _showClosed = s.first),
        ),
      ),
      section(tr('Luồng riêng tư'), privates.length),
      for (final c in privates)
        ListTile(
          leading: Avatar(name: c.displayName, size: 42, icon: Icons.lock_outline, channel: c),
          title: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          subtitle: Text(
            [if (app.channels[c.subParent] != null) app.channelTitle(app.channels[c.subParent]!), if (c.lastPostAt > 0) listTime(c.lastPostAt)].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: pal.sub, fontSize: 13),
          ),
          trailing: action(c.isClosed,
              () => _run(() => app.setPrivateThreadClosed(c, !c.isClosed), c.isClosed ? tr('Đã mở lại luồng') : tr('Đã đóng luồng'))),
          onTap: () => _openPrivate(c),
        ),
      if (privates.isEmpty) _empty(pal),
      section(tr('Luồng công việc riêng'), works.length),
      for (final t in works)
        ListTile(
          leading: Avatar(userId: t.root.userId, name: app.users[t.root.userId]?.displayName ?? '', size: 42),
          title: Text(plainPreview(t.root.message).replaceAll('\n', ' '),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          subtitle: Text(
            [
              if (app.channels[t.root.channelId] != null) app.channelTitle(app.channels[t.root.channelId]!),
              tr('{0} trả lời', [t.replies]),
              if (t.lastAt > 0) listTime(t.lastAt),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: pal.sub, fontSize: 13),
          ),
          trailing: action(_showClosed, () {
            final closed = app.isThreadClosed(t.root.channelId, t.root.id);
            _run(() => app.setThreadClosed(t.root.channelId, t.root.id, !closed), closed ? tr('Đã mở lại luồng') : tr('Đã đóng luồng'));
          }),
          onTap: () => _openWork(t.root),
        ),
      if (works.isEmpty)
        app.workThreadsLoading
            ? Padding(padding: const EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: pal.accent)))
            : _empty(pal),
    ];

    return RefreshIndicator(
      color: pal.accent,
      onRefresh: app.loadWorkThreads,
      child: ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding), children: rows),
    );
  }

  Widget _empty(Pal pal) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
        child: Text(_showClosed ? tr('Chưa có luồng nào đã đóng') : tr('Không có luồng nào đang dang dở'),
            style: TextStyle(color: pal.sub, fontSize: 14)),
      );
}
