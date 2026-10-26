import 'package:flutter/material.dart';

import '../../api/boards_api.dart';
import '../../config.dart';
import '../../i18n/i18n.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';

/// View Lịch: thẻ xếp theo một thuộc tính ngày (mặc định ngày tạo) trên lưới tháng. Màn hình rộng hiện tên thẻ trong ô ngày;
/// điện thoại hiện chấm và danh sách thẻ của ngày đang chọn. Kéo thẻ sang ngày khác để đổi ngày; bấm "+" để tạo thẻ vào ngày đó.
class CalendarView extends StatefulWidget {
  final BoardStore store;
  final BoardView view;
  final List<TaskCard> cards;
  final String? selectedId;
  final ValueChanged<TaskCard> onOpen;
  final Future<void> Function(Map<String, dynamic> props) onAdd;
  const CalendarView(
      {super.key, required this.store, required this.view, required this.cards, required this.onOpen, required this.onAdd, this.selectedId});

  /// Thuộc tính ngày của view (không có thì thuộc tính ngày đầu tiên, rồi ngày tạo).
  static PropTemplate? dateProp(TaskBoard b, BoardView v) {
    final p = b.prop(v.dateDisplayPropertyId);
    if (p != null && p.isDate) return p;
    return b.props.where((p) => p.type == 'date').firstOrNull;
  }

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _day = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  BoardStore get s => widget.store;

  /// Ngày bắt đầu (và kết thúc) của thẻ theo thuộc tính đang dùng.
  (DateTime, DateTime)? _range(TaskCard c, PropTemplate? p) {
    if (p == null || p.type == 'createdTime') {
      final d = DateTime.fromMillisecondsSinceEpoch(c.createAt);
      return (DateTime(d.year, d.month, d.day), DateTime(d.year, d.month, d.day));
    }
    if (p.type == 'updatedTime') {
      final d = DateTime.fromMillisecondsSinceEpoch(c.updateAt);
      return (DateTime(d.year, d.month, d.day), DateTime(d.year, d.month, d.day));
    }
    final dp = DateProp.parse(c.properties[p.id]);
    final a = dp?.start;
    if (a == null) return null;
    final e = dp!.end ?? a;
    return (DateTime(a.year, a.month, a.day), DateTime(e.year, e.month, e.day));
  }

  Future<void> _moveTo(TaskCard c, PropTemplate p, DateTime day) async {
    final dp = DateProp.parse(c.properties[p.id]);
    String v;
    if (dp?.start != null && dp!.end != null) {
      final len = dp.end!.difference(dp.start!);
      final st = dp.includeTime ? DateTime(day.year, day.month, day.day, dp.start!.hour, dp.start!.minute) : day;
      v = DateProp.encode(st, end: st.add(len), includeTime: dp.includeTime);
    } else if (dp?.start != null && dp!.includeTime) {
      v = DateProp.encode(DateTime(day.year, day.month, day.day, dp.start!.hour, dp.start!.minute), includeTime: true);
    } else {
      v = DateProp.encode(day);
    }
    try {
      await s.setCardProp(c, p.id, v);
    } catch (e) {
      if (mounted) boardsError(context, tr('Không đổi được ngày'), e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = s.board!;
    final p = CalendarView.dateProp(b, widget.view);
    final editableDate = p != null && p.type == 'date' && s.canEdit;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    // Thẻ theo từng ngày (khoảng ngày thì có mặt ở mọi ngày trong khoảng, tối đa 62 ngày).
    final byDay = <DateTime, List<TaskCard>>{};
    for (final c in widget.cards) {
      final r = _range(c, p);
      if (r == null) continue;
      var d = r.$1;
      for (var i = 0; i < 62 && !d.isAfter(r.$2); i++) {
        (byDay[d] ??= []).add(c);
        d = DateTime(d.year, d.month, d.day + 1);
      }
    }
    final first = DateTime(_month.year, _month.month);
    final lead = (first.weekday + 6) % 7; // tuần bắt đầu thứ Hai
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final rows = ((lead + days) / 7).ceil();
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final wd = [tr('T2'), tr('T3'), tr('T4'), tr('T5'), tr('T6'), tr('T7'), tr('CN')];

    Widget dayCell(DateTime d) {
      final list = byDay[d] ?? const [];
      final inMonth = d.month == _month.month;
      final sel = d == _day;
      final cell = InkWell(
        onTap: () => setState(() => _day = d),
        onDoubleTap: editableDate ? () => widget.onAdd({p.id: DateProp.encode(d)}) : null,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: pal.divider.withValues(alpha: .6), width: .5),
            color: sel && !wide ? pal.accent.withValues(alpha: .12) : null,
          ),
          padding: const EdgeInsets.all(4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: d == today ? BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(8)) : null,
                child: Text('${d.day}',
                    style: TextStyle(fontSize: 12.5, color: d == today ? Colors.white : (inMonth ? pal.text : pal.sub.withValues(alpha: .5)))),
              ),
              const Spacer(),
              if (wide && editableDate)
                InkWell(onTap: () => widget.onAdd({p.id: DateProp.encode(d)}), child: Icon(Icons.add_rounded, size: 15, color: pal.sub)),
            ]),
            const SizedBox(height: 2),
            if (wide)
              Expanded(
                child: ClipRect(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final c in list.take(4))
                      _draggable(
                        c,
                        editableDate,
                        Container(
                          margin: const EdgeInsets.only(bottom: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.id == widget.selectedId ? pal.accent.withValues(alpha: .3) : pal.accent.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: InkWell(
                            onTap: () => widget.onOpen(c),
                            child: Text('${c.icon} ${c.title.isEmpty ? tr('(Không có tiêu đề)') : c.title}'.trim(),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: pal.text)),
                          ),
                        ),
                      ),
                    if (list.length > 4) Text('+${list.length - 4}', style: TextStyle(fontSize: 11.5, color: pal.sub)),
                  ]),
                ),
              )
            else if (list.isNotEmpty)
              Wrap(spacing: 2, children: [
                for (final _ in list.take(4)) Container(width: 5, height: 5, decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle)),
              ]),
          ]),
        ),
      );
      if (!editableDate) return cell;
      return DragTarget<TaskCard>(
        onAcceptWithDetails: (det) => _moveTo(det.data, p, d),
        builder: (_, cand, _) => cand.isEmpty ? cell : Container(color: pal.accent.withValues(alpha: .2), child: cell),
      );
    }

    final grid = Column(children: [
      Row(children: [for (final w in wd) Expanded(child: Center(child: Text(w, style: TextStyle(fontSize: 12, color: pal.sub, fontWeight: FontWeight.w600))))]),
      const SizedBox(height: 4),
      for (var r = 0; r < rows; r++)
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var c = 0; c < 7; c++) Expanded(child: dayCell(DateTime(_month.year, _month.month, 1 + r * 7 + c - lead))),
          ]),
        ),
    ]);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(children: [
        IconButton(
            tooltip: tr('Tháng trước'),
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1))),
        Flexible(
          child: Text(tr('Tháng {0}/{1}', [_month.month, _month.year]),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
        ),
        IconButton(
            tooltip: tr('Tháng sau'),
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
        IconButton(
            tooltip: tr('Hôm nay'),
            icon: const Icon(Icons.today_rounded),
            onPressed: () => setState(() {
                  _month = DateTime(today.year, today.month);
                  _day = today;
                })),
        if (wide) ...[
          const Spacer(),
          Flexible(
            child: Text(p == null ? tr('Theo ngày tạo') : tr('Theo {0}', [p.name]),
                overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13)),
          ),
        ],
      ]),
    );

    if (wide) {
      return Column(children: [header, Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), child: grid))]);
    }
    final dayCards = byDay[_day] ?? const [];
    return Column(children: [
      header,
      SizedBox(height: 50.0 * rows + 22, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: grid)),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
        child: Row(children: [
          Expanded(child: Text(dueText(_day), style: TextStyle(fontWeight: FontWeight.w600, color: pal.text))),
          if (editableDate)
            TextButton.icon(
                onPressed: () => widget.onAdd({p.id: DateProp.encode(_day)}), icon: const Icon(Icons.add_rounded, size: 18), label: Text(tr('Thêm thẻ'))),
        ]),
      ),
      Expanded(
        child: dayCards.isEmpty
            ? Center(child: Text(tr('Không có thẻ nào trong ngày'), style: TextStyle(color: pal.sub)))
            : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                for (final c in dayCards)
                  ListTile(
                    selected: c.id == widget.selectedId,
                    leading: Text(c.icon.isEmpty ? '•' : c.icon, style: const TextStyle(fontSize: 18)),
                    title: Text(c.title.isEmpty ? tr('(Không có tiêu đề)') : c.title, style: TextStyle(color: pal.text)),
                    onTap: () => widget.onOpen(c),
                  ),
              ]),
      ),
    ]);
  }

  Widget _draggable(TaskCard c, bool enabled, Widget child) {
    if (!enabled) return child;
    final fb = Material(color: Colors.transparent, child: SizedBox(width: 140, child: child));
    return isDesktop
        ? Draggable<TaskCard>(data: c, feedback: fb, child: child)
        : LongPressDraggable<TaskCard>(data: c, feedback: fb, child: child);
  }
}
