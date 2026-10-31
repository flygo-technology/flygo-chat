import 'package:flutter/material.dart';

import '../../api/boards_models.dart';
import '../../data/models.dart';
import '../../i18n/i18n.dart';
import '../../push/push_service.dart';
import '../../state/app_state.dart';
import '../boards/boards_common.dart';
import '../boards/card_detail.dart' show openBoardCard, boardsWide;
import '../chat_page.dart' show ChatPage;
import '../common.dart';
import '../theme.dart';
import 'quick_add.dart' show taskPropsOf;
import 'task_tile.dart';

/// Việc và chat: thẻ việc trong khung chat (props.flygo_task), mở tin nhắn gốc của việc, mở chat với người làm.

/// Mở một cuộc trò chuyện từ màn hình việc (thẻ mở trên bộ điều hướng gốc): máy tính rộng thì đóng trang thẻ rồi mở ở ô chat.
void openChatFromTask(BuildContext context, String channelId, {String? rootId}) {
  final nav = Navigator.of(context, rootNavigator: true);
  final hook = PushService.openChatHook;
  if (hook == null) {
    nav.push(MaterialPageRoute(builder: (_) => ChatPage(channelId: channelId)));
    return;
  }
  if (boardsWide(context)) nav.popUntil((r) => r.isFirst);
  hook(channelId);
  if (rootId != null && rootId.isNotEmpty) PushService.openThreadHook?.call(channelId, rootId);
}

/// Mở tin nhắn gốc của việc: mở cuộc trò chuyện (luồng nếu tin nằm trong luồng) rồi cuộn tới tin đó.
Future<void> openSourceMessage(BuildContext context, AppState app, String postId) async {
  final messenger = ScaffoldMessenger.of(context);
  MmPost p;
  try {
    p = MmPost((await app.api.get('/posts/$postId') as Map).cast());
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không mở được tin nhắn gốc. Tin có thể đã bị xoá hoặc bạn không ở trong cuộc trò chuyện đó.'))));
    return;
  }
  if (!context.mounted) return;
  final inThread = p.rootId.isNotEmpty && p.inThread;
  openChatFromTask(context, p.channelId, rootId: inThread ? p.rootId : null);
  if (!inThread) {
    // Khung chat vừa mở mới bắt đầu nghe yêu cầu cuộn: chờ một nhịp.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    app.requestJump(p.channelId, p.id);
  }
}

/// Nhắn người làm (hoặc người giao, khi mình là người làm): mở DM; nhiều người thì hỏi chọn.
Future<void> messageTaskPeople(BuildContext context, AppState app, List<String> people) async {
  final me = app.me?.id;
  final ids = people.where((id) => id != me && id.isNotEmpty).toSet().toList();
  if (ids.isEmpty) return;
  var who = ids.first;
  if (ids.length > 1) {
    final r = await boardsSheet<String>(context, scroll: false, (c) {
      final pal = Pal.of(c);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final id in ids)
            ListTile(
              leading: Avatar(userId: id, name: app.users[id]?.displayName ?? '?', size: 36, status: false),
              title: Text(app.users[id]?.displayName ?? id, style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(c, id),
            ),
          const SizedBox(height: 8),
        ]),
      );
    });
    if (r == null) return;
    who = r;
  }
  try {
    final ch = await app.openDirect(who);
    if (context.mounted) openChatFromTask(context, ch);
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không mở được cuộc trò chuyện.'))));
  }
}

/// Thẻ việc trong khung chat: việc được giao / sắp đến hạn / quá hạn / đã xong / việc mỗi sáng. Bấm một việc để mở.
class TaskPostCard extends StatelessWidget {
  final AppState app;
  final MmPost post;
  final double width;
  const TaskPostCard({super.key, required this.app, required this.post, required this.width});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final p = taskPropsOf(post) ?? const {};
    final kind = '${p['kind'] ?? 'assigned'}';
    final items = [for (final x in (p['items'] as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
    final (icon, color, label) = switch (kind) {
      'due_soon' => (Icons.alarm_rounded, kTaskOrange, tr('Sắp đến hạn')),
      'overdue' => (Icons.error_outline_rounded, kTaskRed, tr('Việc quá hạn')),
      'done' => (Icons.check_circle_rounded, kTaskGreen, tr('Việc đã xong')),
      'digest' => (Icons.wb_sunny_outlined, kTaskOrange, tr('Việc hôm nay của bạn')),
      _ => (Icons.assignment_ind_outlined, pal.accentText, tr('Việc được giao')),
    };
    final by = '${p['by'] ?? ''}';
    return Container(
      width: width.clamp(200.0, 360.0),
      margin: const EdgeInsets.only(top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(
          color: color.withValues(alpha: .10),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13.5))),
            if (by.isNotEmpty && kind == 'assigned')
              Flexible(
                child: Text(tr('bởi {0}', [app.users[by]?.displayName ?? '']),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: pal.sub)),
              ),
          ]),
        ),
        if (items.isEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(post.message, style: TextStyle(color: pal.text))),
        for (final (i, it) in items.take(12).indexed) ...[
          if (i > 0) Divider(height: 1, color: pal.divider),
          _item(context, pal, it, kind),
        ],
        if (items.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Text(tr('và {0} việc khác', [items.length - 12]), style: TextStyle(color: pal.sub, fontSize: 13)),
          ),
      ]),
    );
  }

  Widget _item(BuildContext context, Pal pal, Map<String, dynamic> it, String kind) {
    final due = DateProp.parse(it['due'])?.start;
    final people = [for (final x in (it['assignees'] as List? ?? const [])) '$x'];
    final board = '${it['board_id'] ?? ''}', card = '${it['card_id'] ?? ''}';
    final title = '${it['title'] ?? ''}';
    return InkWell(
      onTap: board.isEmpty || card.isEmpty ? null : () => openBoardCard(context, board, card),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title.isEmpty ? tr('(Không có tiêu đề)') : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: pal.text,
                      decoration: kind == 'done' ? TextDecoration.lineThrough : null,
                      decorationColor: pal.sub)),
              if (due != null || people.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (due != null) DueChip(due, done: kind == 'done'),
                  if (people.isNotEmpty) AvatarStack(people, size: 20),
                ]),
              ],
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: pal.sub),
        ]),
      ),
    );
  }
}
