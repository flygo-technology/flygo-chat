import 'package:flutter/material.dart';

import '../../api/boards_models.dart';
import '../../i18n/i18n.dart';
import '../boards/boards_common.dart';
import '../theme.dart';
import 'task_logic.dart';

/// Các bảng chọn nhanh của tab Việc: đổi trạng thái, dời hạn, menu nhấn giữ.

/// Chọn trạng thái. Trả về phương án đã chọn, null nếu huỷ.
Future<PropOption?> pickStatus(BuildContext context, PropTemplate status, String? currentId) => boardsSheet<PropOption>(
      context,
      scroll: false,
      (c) {
        final pal = Pal.of(c);
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr('Đổi trạng thái'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            for (final o in status.options)
              ListTile(
                minTileHeight: 52,
                leading: Icon(isDoneStatus(o.value) ? Icons.check_circle_rounded : Icons.circle, size: isDoneStatus(o.value) ? 22 : 14,
                    color: boardsColor(o.color, pal.sub)),
                title: Align(alignment: Alignment.centerLeft, child: OptionPill(o)),
                trailing: o.id == currentId ? Icon(Icons.check_rounded, color: pal.accentText) : null,
                onTap: () => Navigator.pop(c, o),
              ),
            const SizedBox(height: 8),
          ]),
        );
      },
    );

/// Dời hạn: Hôm nay / Mai / Thứ 2 tuần sau / Chọn ngày / Bỏ hạn. Trả về giá trị thuộc tính ngày mới ('' = bỏ hạn), null nếu huỷ.
Future<String?> pickSnooze(BuildContext context, DateProp? current, {DateTime? now}) async {
  final n = now ?? DateTime.now();
  final picks = <(IconData, String, DateTime)>[
    (Icons.today_rounded, tr('Hôm nay'), dayOf(n)),
    (Icons.wb_twilight_rounded, tr('Mai'), addDays(n, 1)),
    (Icons.weekend_outlined, tr('Cuối tuần'), weekendOf(n)),
    (Icons.next_week_outlined, tr('Thứ 2 tuần sau'), nextMonday(n)),
  ];
  final r = await boardsSheet<Object>(
    context,
    scroll: false,
    (c) {
      final pal = Pal.of(c);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('Dời hạn'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          for (final (icon, label, d) in picks)
            ListTile(
              minTileHeight: 52,
              leading: Icon(icon, color: pal.accentText),
              title: Text(label, style: TextStyle(color: pal.text)),
              trailing: Text(dueDayLabel(d), style: TextStyle(color: pal.sub)),
              onTap: () => Navigator.pop(c, d),
            ),
          ListTile(
            minTileHeight: 52,
            leading: Icon(Icons.edit_calendar_rounded, color: pal.accentText),
            title: Text(tr('Chọn ngày…'), style: TextStyle(color: pal.text)),
            onTap: () => Navigator.pop(c, 'pick'),
          ),
          if (current?.start != null)
            ListTile(
              minTileHeight: 52,
              leading: Icon(Icons.event_busy_rounded, color: pal.sub),
              title: Text(tr('Bỏ hạn'), style: TextStyle(color: pal.sub)),
              onTap: () => Navigator.pop(c, ''),
            ),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
  if (r == null) return null;
  if (r == '') return '';
  if (r is DateTime) return dueValueFor(r, current);
  if (!context.mounted) return null;
  final d = await showDatePicker(
    context: context,
    initialDate: current?.start ?? addDays(n, 1),
    firstDate: DateTime(n.year - 1),
    lastDate: DateTime(n.year + 5),
  );
  return d == null ? null : dueValueFor(d, current);
}

/// Menu nhấn giữ một việc. Trả về khoá thao tác: done, status, snooze, assign, board, open.
Future<String?> showTaskMenu(BuildContext context, MyTask t) => boardsSheet<String>(
      context,
      scroll: false,
      (c) {
        final pal = Pal.of(c);
        Widget item(String key, IconData icon, String label, {bool enabled = true}) => ListTile(
              minTileHeight: 52,
              enabled: enabled,
              leading: Icon(icon, color: enabled ? pal.text : pal.sub),
              title: Text(label),
              onTap: () => Navigator.pop(c, key),
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(t.card.title.isEmpty ? tr('(Không có tiêu đề)') : t.card.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            item('done', t.done ? Icons.replay_rounded : Icons.check_circle_outline_rounded, t.done ? tr('Mở lại') : tr('Đánh dấu xong'),
                enabled: t.board.status != null),
            item('status', Icons.swap_horiz_rounded, tr('Đổi trạng thái'), enabled: t.board.status != null),
            item('snooze', Icons.schedule_rounded, tr('Dời hạn'), enabled: t.board.due != null),
            item('assign', Icons.person_add_alt_rounded, tr('Giao lại'), enabled: t.board.assignee != null),
            item('board', Icons.dashboard_outlined, tr('Mở bảng')),
            item('open', Icons.open_in_full_rounded, tr('Xem chi tiết')),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
