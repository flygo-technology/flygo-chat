import 'package:flutter/material.dart';

import '../../api/boards_models.dart';
import '../../i18n/i18n.dart';
import '../theme.dart';
import 'task_logic.dart';

/// Bảng dưới chọn bảng của tab Việc: "Tất cả bảng" + từng bảng (biểu tượng, tên, số việc của tôi / đang mở),
/// cuối là "Tạo bảng mới" và "Quản lý bảng". Kéo lên / xuống được.
///
/// Trả về (pop): '' = mọi bảng, `b:<id>` = lọc theo bảng, `o:<id>` = mở bảng đầy đủ, '+' = tạo bảng, '*' = quản lý bảng.
class BoardPickerSheet extends StatelessWidget {
  final List<TaskBoard> boards;
  final List<MyTask> tasks;
  final String me;
  /// Bảng đang lọc (null: mọi bảng).
  final String? selected;
  const BoardPickerSheet({super.key, required this.boards, required this.tasks, required this.me, this.selected});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final counts = boardOpenCounts(tasks, me);
    final myTotal = tasks.where((t) => !t.done && t.isMine(me)).length;
    String sub(int mine, int all) {
      if (all == 0) return tr('Không có việc đang mở');
      return mine > 0 ? tr('{0} việc của bạn · {1} đang mở', [mine, all]) : tr('{0} việc đang mở', [all]);
    }

    Widget badge(int n) => Container(
          constraints: const BoxConstraints(minWidth: 24),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: n > 0 ? pal.accent : pal.surface2, borderRadius: BorderRadius.circular(12)),
          child: Text('$n', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: n > 0 ? Colors.white : pal.sub)),
        );

    Widget row({
      required Key key,
      required Widget leading,
      required String title,
      required String subtitle,
      required int mine,
      required bool sel,
      required VoidCallback onTap,
      VoidCallback? onOpen,
    }) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: ListTile(
            key: key,
            minTileHeight: 60,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            selected: sel,
            selectedTileColor: pal.chipSelBg,
            selectedColor: pal.chipSelFg,
            leading: SizedBox(width: 32, child: Center(child: leading)),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
            subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              badge(mine),
              if (onOpen != null)
                IconButton(
                  tooltip: tr('Mở bảng đầy đủ'),
                  icon: Icon(Icons.open_in_full_rounded, size: 19, color: pal.sub),
                  onPressed: onOpen,
                ),
            ]),
            onTap: onTap,
          ),
        );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .62,
      minChildSize: .35,
      maxChildSize: .94,
      builder: (context, ctrl) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Row(children: [
            Expanded(child: Text(tr('Bảng việc'), style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: pal.text))),
            Text(tr('{0} bảng', [boards.length]), style: TextStyle(color: pal.sub)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(tr('Chọn một bảng để xem các việc trong bảng đó.'), style: TextStyle(color: pal.sub, fontSize: 13)),
          ),
        ),
        Expanded(
          child: ListView(controller: ctrl, padding: const EdgeInsets.only(bottom: 8), children: [
            row(
              key: const ValueKey('board-pick-all'),
              leading: Icon(Icons.all_inbox_rounded, color: selected == null ? pal.chipSelFg : pal.sub),
              title: tr('Tất cả bảng'),
              subtitle: myTotal > 0 ? tr('{0} việc của bạn đang mở', [myTotal]) : tr('Không có việc đang mở'),
              mine: myTotal,
              sel: selected == null,
              onTap: () => Navigator.pop(context, ''),
            ),
            if (boards.isNotEmpty) Divider(height: 12, indent: 20, endIndent: 20, color: pal.divider),
            for (final b in boards)
              row(
                key: ValueKey('board-pick-${b.id}'),
                leading: b.icon.isEmpty ? Icon(Icons.dashboard_outlined, color: pal.sub) : Text(b.icon, style: const TextStyle(fontSize: 22)),
                title: b.title.isEmpty ? tr('Bảng chưa đặt tên') : b.title,
                subtitle: sub(counts[b.id]?.$1 ?? 0, counts[b.id]?.$2 ?? 0),
                mine: counts[b.id]?.$1 ?? 0,
                sel: selected == b.id,
                onTap: () => Navigator.pop(context, 'b:${b.id}'),
                onOpen: () => Navigator.pop(context, 'o:${b.id}'),
              ),
            if (boards.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(tr('Nhóm chưa có bảng việc nào. Tạo bảng đầu tiên để bắt đầu.'), textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
              ),
          ]),
        ),
        Divider(height: 1, color: pal.divider),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const ValueKey('board-pick-new'),
                  onPressed: () => Navigator.pop(context, '+'),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('Tạo bảng mới'), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('board-pick-manage'),
                  onPressed: () => Navigator.pop(context, selected == null ? '*' : 'o:$selected'),
                  icon: Icon(selected == null ? Icons.grid_view_rounded : Icons.view_kanban_outlined),
                  label: Text(selected == null ? tr('Quản lý bảng') : tr('Mở bảng đầy đủ'), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
