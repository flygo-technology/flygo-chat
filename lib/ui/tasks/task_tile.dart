import 'package:flutter/material.dart';

import '../../i18n/i18n.dart';
import '../boards/boards_common.dart';
import '../theme.dart';
import 'task_logic.dart';

/// Thành phần giao diện của tab Việc: thẻ việc (vuốt, đánh dấu xong), chip hạn, thanh việc con, khung chờ tải, màn trống.

const kTaskRed = Color(0xFFE53935);
const kTaskOrange = Color(0xFFF57C00);
const kTaskGreen = Color(0xFF43A047);

/// Chip hạn: đỏ khi quá hạn, cam khi hôm nay, xám khi còn xa / đã xong.
class DueChip extends StatelessWidget {
  final DateTime due;
  final bool done;
  final bool large;
  final DateTime? now;
  const DueChip(this.due, {super.key, this.done = false, this.large = false, this.now});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final n = now ?? DateTime.now();
    final day = dayOf(due), today = dayOf(n);
    final late = !done && day.isBefore(today);
    final isToday = !done && day == today;
    final c = late ? kTaskRed : (isToday ? kTaskOrange : pal.sub);
    final hasTime = due.hour != 0 || due.minute != 0;
    final text = '${dueText(due)}${hasTime ? ' ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}' : ''}';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 10 : 7, vertical: large ? 5 : 2),
      decoration: BoxDecoration(
        color: late || isToday ? c.withValues(alpha: .13) : pal.surface2.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(large ? 10 : 7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(late ? Icons.error_outline_rounded : Icons.event_rounded, size: large ? 16 : 13, color: c),
        const SizedBox(width: 4),
        Flexible(
          child: Text(late ? tr('Quá hạn · {0}', [text]) : text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: large ? 14 : 12, color: c, fontWeight: late || isToday ? FontWeight.w600 : FontWeight.w500)),
        ),
      ]),
    );
  }
}

/// Tiến độ việc con: "2/5" + thanh mảnh.
class SubtaskProgress extends StatelessWidget {
  final int done, total;
  final double width;
  const SubtaskProgress(this.done, this.total, {super.key, this.width = 34});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final all = total > 0 && done >= total;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.checklist_rounded, size: 14, color: all ? kTaskGreen : pal.sub),
      const SizedBox(width: 3),
      Text('$done/$total', style: TextStyle(fontSize: 12, color: all ? kTaskGreen : pal.sub, fontWeight: FontWeight.w500)),
      const SizedBox(width: 5),
      SizedBox(
        width: width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : done / total,
            minHeight: 3,
            backgroundColor: pal.surface2,
            color: all ? kTaskGreen : pal.accent,
          ),
        ),
      ),
    ]);
  }
}

/// Vòng tròn đánh dấu xong (bấm được, có hiệu ứng).
class DoneCircle extends StatelessWidget {
  final bool done;
  final Color? color;
  final VoidCallback? onTap;
  final double size;
  const DoneCircle({super.key, required this.done, this.onTap, this.color, this.size = 24});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Semantics(
      button: true,
      checked: done,
      label: done ? tr('Mở lại') : tr('Đánh dấu xong'),
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: c),
              child: done
                  ? Icon(Icons.check_circle_rounded, key: const ValueKey('on'), color: kTaskGreen, size: size)
                  : Icon(Icons.radio_button_unchecked_rounded, key: const ValueKey('off'), color: color ?? pal.sub, size: size),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thẻ một việc: vòng đánh dấu xong, tên (2 dòng), chip hạn, trạng thái, bảng, ưu tiên, việc con, bình luận, người làm.
/// Vuốt phải = xong / mở lại, vuốt trái = dời hạn; nhấn giữ (chuột phải) = menu.
class TaskTile extends StatelessWidget {
  final MyTask task;
  final VoidCallback onTap;
  final VoidCallback? onToggleDone;
  final VoidCallback? onSnooze;
  final VoidCallback? onMenu;
  final bool showBoard;
  final DateTime? now;
  const TaskTile(
      {super.key, required this.task, required this.onTap, this.onToggleDone, this.onSnooze, this.onMenu, this.showBoard = true, this.now});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final t = task;
    final due = t.due, st = t.status, pr = t.priority;
    final prColor = pr == null ? null : boardsColor(pr.color, pal.sub);
    final meta = <Widget>[
      if (due != null) DueChip(due, done: t.done, now: now),
      if (st != null) OptionPill(st, dense: true),
      if (pr != null)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.flag_rounded, size: 14, color: prColor),
          const SizedBox(width: 2),
          Text(pr.value, style: TextStyle(fontSize: 12, color: prColor, fontWeight: FontWeight.w500)),
        ]),
      if (t.checksTotal > 0) SubtaskProgress(t.checksDone, t.checksTotal),
      if (t.comments > 0)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 13, color: pal.sub),
          const SizedBox(width: 3),
          Text('${t.comments}', style: TextStyle(fontSize: 12, color: pal.sub)),
        ]),
      if (showBoard)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text('${t.board.icon.isEmpty ? '' : '${t.board.icon} '}${t.board.title.isEmpty ? tr('Bảng chưa đặt tên') : t.board.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: pal.sub)),
        ),
    ];
    final body = Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        onSecondaryTap: onMenu,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DoneCircle(done: t.done, onTap: onToggleDone, color: t.overdueAt(now ?? DateTime.now()) ? kTaskRed : null),
            const SizedBox(width: 2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.card.title.isEmpty ? tr('(Không có tiêu đề)') : t.card.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.5,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: t.done ? pal.sub : pal.text,
                        decoration: t.done ? TextDecoration.lineThrough : null,
                        decorationColor: pal.sub,
                      )),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 5, crossAxisAlignment: WrapCrossAlignment.center, children: meta),
                  ],
                ]),
              ),
            ),
            if (t.assignees.isNotEmpty)
              Padding(padding: const EdgeInsets.only(left: 8, top: 10), child: AvatarStack(t.assignees, size: 24)),
          ]),
        ),
      ),
    );
    Widget bg(Color c, IconData icon, String label, Alignment a) => Container(
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          alignment: a,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Dismissible(
        key: ValueKey('task-${t.key}'),
        direction: onToggleDone == null && onSnooze == null
            ? DismissDirection.none
            : onSnooze == null
                ? DismissDirection.startToEnd
                : onToggleDone == null
                    ? DismissDirection.endToStart
                    : DismissDirection.horizontal,
        dismissThresholds: const {DismissDirection.startToEnd: .3, DismissDirection.endToStart: .3},
        background: t.done
            ? bg(pal.sub, Icons.replay_rounded, tr('Mở lại'), Alignment.centerLeft)
            : bg(kTaskGreen, Icons.check_rounded, tr('Xong'), Alignment.centerLeft),
        secondaryBackground: bg(kTaskOrange, Icons.schedule_rounded, tr('Dời hạn'), Alignment.centerRight),
        // Không xoá thẻ khỏi danh sách: chỉ chạy thao tác rồi trả thẻ về chỗ cũ.
        confirmDismiss: (d) async {
          if (d == DismissDirection.startToEnd) {
            onToggleDone?.call();
          } else {
            onSnooze?.call();
          }
          return false;
        },
        child: body,
      ),
    );
  }
}

/// Khung chờ tải (thay vòng xoay): vài thẻ xám nhấp nháy nhẹ.
class TaskSkeleton extends StatefulWidget {
  final int count;
  const TaskSkeleton({super.key, this.count = 5});
  @override
  State<TaskSkeleton> createState() => _TaskSkeletonState();
}

class _TaskSkeletonState extends State<TaskSkeleton> with SingleTickerProviderStateMixin {
  late final _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(6)),
        );
    return FadeTransition(
      opacity: Tween(begin: .45, end: 1.0).animate(_a),
      child: Column(children: [
        for (var i = 0; i < widget.count; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 22, height: 22, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: pal.surface2, width: 2))),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  bar(i.isEven ? 220 : 160, 13),
                  const SizedBox(height: 9),
                  Row(children: [bar(64, 10), const SizedBox(width: 8), bar(48, 10)]),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Màn trống thân thiện: biểu tượng lớn trong vòng màu, một dòng tiêu đề, một dòng giải thích, một nút.
class TasksEmpty extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final String? action;
  final VoidCallback? onAction;
  final Color? color;
  const TasksEmpty({super.key, required this.icon, required this.title, this.body = '', this.action, this.onAction, this.color});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final c = color ?? pal.accentText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 120,
          height: 104,
          child: Stack(alignment: Alignment.center, children: [
            Container(width: 96, height: 96, decoration: BoxDecoration(color: c.withValues(alpha: .12), shape: BoxShape.circle)),
            Positioned(right: 6, top: 8, child: Container(width: 14, height: 14, decoration: BoxDecoration(color: c.withValues(alpha: .25), shape: BoxShape.circle))),
            Positioned(left: 10, bottom: 10, child: Container(width: 9, height: 9, decoration: BoxDecoration(color: c.withValues(alpha: .35), shape: BoxShape.circle))),
            Icon(icon, size: 46, color: c),
          ]),
        ),
        const SizedBox(height: 14),
        Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: TextStyle(color: pal.sub, height: 1.35)),
        ],
        if (action != null && onAction != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onAction, icon: const Icon(Icons.add_rounded), label: Text(action!)),
        ],
      ]),
    );
  }
}
