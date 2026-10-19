import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_page.dart';
import 'chat_list.dart';
import 'common.dart';
import 'theme.dart';

/// Tab Agents: mọi chat 1-1 với trợ lý AI (không tính chat AI cột phải của từng nhóm), và các trợ lý
/// mình gọi được (của mình hoặc được chia sẻ) nhưng chưa có cuộc trò chuyện nào.
class AgentsView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final String? selectedId;
  final double bottomPadding;
  final Widget? header;
  const AgentsView({super.key, required this.onOpen, this.selectedId, this.bottomPadding = 0, this.header});
  @override
  State<AgentsView> createState() => _AgentsViewState();
}

class _AgentsViewState extends State<AgentsView> {
  Set<String> _mine = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().myBotIds().then((v) {
      if (mounted) setState(() => _mine = v);
    }).catchError((_) {});
  }

  Future<void> _start(MmUser bot) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      widget.onOpen(await context.read<AppState>().openDirect(bot.id));
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không mở được cuộc trò chuyện. Kiểm tra kết nối mạng.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final chats = app.agentChats;
    final withChat = {for (final c in chats) c.avatarUserId};
    final idle = app.users.values
        .where((u) => u.isBot && u.deleteAt == 0 && app.isAssistant(u.id) && app.canCallBot(u, _mine) && !withChat.contains(u.id))
        .toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    return Column(children: [
      ?widget.header,
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: chats.isEmpty && idle.isEmpty
            ? _empty(pal)
            : ListView(padding: EdgeInsets.only(bottom: widget.bottomPadding), children: [
                for (final c in chats)
                  ChatTile(c: c, selected: c.channel.id == widget.selectedId, onTap: () => widget.onOpen(c.channel.id)),
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
                      onTap: _busy ? null : () => _start(u),
                    ),
                ],
              ]),
      ),
    ]);
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
