import 'package:flutter/material.dart';

import '../../api/boards_api.dart';
import '../../config.dart';
import '../../i18n/i18n.dart';
import '../common.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';
import 'prop_editors.dart';

/// Thẻ gọn dùng chung cho Kanban / Thư viện: biểu tượng + tên, các thuộc tính đang hiện, số việc con / bình luận.
class BoardCardTile extends StatelessWidget {
  final BoardStore store;
  final BoardView view;
  final TaskCard card;
  final bool selected;
  final VoidCallback onTap;
  final Widget? cover;
  const BoardCardTile({super.key, required this.store, required this.view, required this.card, required this.onTap, this.selected = false, this.cover});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = store.board!;
    final props = [for (final id in view.visiblePropertyIds) ?b.prop(id)];
    final checks = store.contentOf(card).where((x) => x.type == 'checkbox').toList();
    final done = checks.where((x) => x.fields['value'] == true).length;
    final comments = store.commentsOf(card).length;
    final values = [
      for (final p in props)
        if (_hasValue(p)) PropValue(p, card, dense: true),
    ];
    return Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? pal.accent : pal.divider, width: selected ? 1.6 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            ?cover,
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('${card.icon.isEmpty ? '' : '${card.icon} '}${card.title.isEmpty ? tr('(Không có tiêu đề)') : card.title}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: card.title.isEmpty ? pal.sub : pal.text)),
                if (values.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 5, crossAxisAlignment: WrapCrossAlignment.center, children: values),
                ],
                if (checks.isNotEmpty || comments > 0) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    if (checks.isNotEmpty) ...[
                      Icon(Icons.check_box_outlined, size: 14, color: done == checks.length ? const Color(0xFF43A047) : pal.sub),
                      const SizedBox(width: 3),
                      Text('$done/${checks.length}', style: TextStyle(fontSize: 12, color: pal.sub)),
                      const SizedBox(width: 10),
                    ],
                    if (comments > 0) ...[
                      Icon(Icons.chat_bubble_outline_rounded, size: 13, color: pal.sub),
                      const SizedBox(width: 3),
                      Text('$comments', style: TextStyle(fontSize: 12, color: pal.sub)),
                    ],
                  ]),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  bool _hasValue(PropTemplate p) {
    if (p.readOnly) return true;
    final v = card.properties[p.id];
    if (v == null || v == '' || (v is List && v.isEmpty)) return false;
    return !(p.type == 'checkbox' && v != 'true');
  }
}

/// View Kanban: cột theo phương án của thuộc tính chọn; kéo thẻ giữa / trong các cột; ẩn / hiện cột; thêm cột (= phương án mới).
class KanbanView extends StatelessWidget {
  final BoardStore store;
  final BoardView view;
  final List<TaskCard> cards;
  final String? selectedId;
  final ValueChanged<TaskCard> onOpen;
  final Future<void> Function(Map<String, dynamic> props) onAdd;
  const KanbanView(
      {super.key, required this.store, required this.view, required this.cards, required this.onOpen, required this.onAdd, this.selectedId});

  /// Thuộc tính nhóm: theo view, không có thì thuộc tính chọn đầu tiên.
  static PropTemplate? groupOf(TaskBoard b, BoardView v) {
    final g = b.prop(v.groupById);
    if (g != null && g.type == 'select') return g;
    return b.props.where((p) => p.type == 'select').firstOrNull;
  }

  /// Các cột theo thứ tự của view (`visibleOptionIds`), cột "không có" (id '') đứng đầu.
  static List<PropOption> columnsOf(PropTemplate g, BoardView v) {
    final none = PropOption('', tr('Không có {0}', [g.name]), '');
    final all = [none, ...g.options];
    final order = v.visibleOptionIds;
    if (order.isEmpty) return all;
    int idx(PropOption o) {
      final i = order.indexOf(o.id);
      return i < 0 ? 1 << 20 : i;
    }

    final sorted = [...all]..sort((a, b) {
        final r = idx(a).compareTo(idx(b));
        return r != 0 ? r : all.indexOf(a).compareTo(all.indexOf(b));
      });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = store.board!;
    final g = groupOf(b, view);
    if (g == null) {
      return BoardsNotice(
        icon: Icons.view_kanban_outlined,
        title: tr('Kanban cần một thuộc tính chọn'),
        body: tr('Thêm thuộc tính loại "Chọn một" (vd. Trạng thái) để chia cột.'),
        action: store.canEdit
            ? FilledButton.icon(
                onPressed: () async {
                  final p = PropTemplate(newBoardsId(), tr('Trạng thái'), 'select', [
                    PropOption(newBoardsId(), tr('Chưa làm'), 'propColorGray'),
                    PropOption(newBoardsId(), tr('Đang làm'), 'propColorBlue'),
                    PropOption(newBoardsId(), tr('Xong'), 'propColorGreen'),
                  ]);
                  try {
                    await store.saveProp(p);
                    await store.patchView(view, {'groupById': p.id});
                  } catch (e) {
                    if (context.mounted) boardsError(context, tr('Không lưu được'), e);
                  }
                },
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Thêm thuộc tính Trạng thái')),
              )
            : null,
      );
    }
    final hidden = view.hiddenOptionIds.toSet();
    final cols = columnsOf(g, view);
    final shown = cols.where((o) => !hidden.contains(o.id)).toList();
    final hiddenCols = cols.where((o) => hidden.contains(o.id)).toList();
    final by = <String, List<TaskCard>>{for (final o in cols) o.id: []};
    for (final c in cards) {
      final v = c.str(g.id) ?? '';
      (by[g.option(v) == null ? '' : v] ??= []).add(c);
    }
    final w = MediaQuery.sizeOf(context).width;
    final colW = w < 600 ? (w * .82).clamp(240.0, 320.0) : 290.0;
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final o in shown)
            _Column(
              key: ValueKey('col-${o.id}'),
              store: store,
              view: view,
              group: g,
              option: o,
              cards: by[o.id] ?? const [],
              width: colW,
              selectedId: selectedId,
              onOpen: onOpen,
              onAdd: () => onAdd({if (o.id.isNotEmpty) g.id: o.id}),
              columns: shown,
            ),
          if (hiddenCols.isNotEmpty)
            Container(
              width: 200,
              margin: const EdgeInsets.only(right: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                  child: Text(tr('Cột ẩn'), style: TextStyle(fontWeight: FontWeight.w600, color: pal.sub)),
                ),
                for (final o in hiddenCols)
                  Card(
                    elevation: 0,
                    color: pal.surface,
                    child: ListTile(
                      dense: true,
                      title: Align(alignment: Alignment.centerLeft, child: OptionPill(o.id.isEmpty ? null : o, text: o.value)),
                      trailing: Text('${by[o.id]?.length ?? 0}', style: TextStyle(color: pal.sub)),
                      onTap: !store.canEdit
                          ? null
                          : () => store.patchView(view, {'hiddenOptionIds': view.hiddenOptionIds.where((x) => x != o.id).toList()}),
                    ),
                  ),
              ]),
            ),
          if (store.canEdit)
            SizedBox(
              width: 180,
              child: TextButton.icon(
                onPressed: () async {
                  final name = await askText(context, tr('Cột mới'), '');
                  if (name == null || name.trim().isEmpty) return;
                  try {
                    await store.saveProp(g.copyWith(options: [...g.options, PropOption(newBoardsId(), name.trim(), nextOptionColor(g.options))]));
                  } catch (e) {
                    if (context.mounted) boardsError(context, tr('Không thêm được cột'), e);
                  }
                },
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Thêm cột')),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Column extends StatefulWidget {
  final BoardStore store;
  final BoardView view;
  final PropTemplate group;
  final PropOption option;
  final List<TaskCard> cards;
  final List<PropOption> columns;
  final double width;
  final String? selectedId;
  final ValueChanged<TaskCard> onOpen;
  final VoidCallback onAdd;
  const _Column(
      {super.key,
      required this.store,
      required this.view,
      required this.group,
      required this.option,
      required this.cards,
      required this.columns,
      required this.width,
      required this.onOpen,
      required this.onAdd,
      this.selectedId});
  @override
  State<_Column> createState() => _ColumnState();
}

class _ColumnState extends State<_Column> {
  /// Đang kéo thẻ ngang qua chỗ nào (id thẻ đứng sau, '' = cuối cột).
  String? _hover;

  BoardStore get s => widget.store;

  Future<void> _drop(TaskCard c, String? beforeId) async {
    setState(() => _hover = null);
    if (beforeId == c.id) return;
    try {
      await s.moveCard(widget.view, c,
          group: widget.group, toOption: widget.option.id, beforeId: beforeId, columnCards: widget.cards);
    } catch (e) {
      if (mounted) boardsError(context, tr('Không chuyển được thẻ'), e);
    }
  }

  Future<void> _menu(String v) async {
    final g = widget.group, o = widget.option, view = widget.view;
    try {
      switch (v) {
        case 'add':
          widget.onAdd();
        case 'hide':
          await s.patchView(view, {'hiddenOptionIds': {...view.hiddenOptionIds, o.id}.toList()});
        case 'rename':
          final name = await askText(context, tr('Đổi tên cột'), o.value);
          if (name == null || name.trim().isEmpty) return;
          await s.saveProp(g.copyWith(options: [for (final x in g.options) x.id == o.id ? x.copyWith(value: name.trim()) : x]));
        case 'left':
        case 'right':
          final ids = [for (final c in KanbanView.columnsOf(g, view)) c.id];
          final i = ids.indexOf(o.id), j = v == 'left' ? i - 1 : i + 1;
          if (i < 0 || j < 0 || j >= ids.length) return;
          ids[i] = ids[j];
          ids[j] = o.id;
          await s.patchView(view, {'visibleOptionIds': ids});
        case 'del':
          if (!mounted || !await confirmBoards(context, tr('Xoá cột?'), tr('Phương án "{0}" sẽ bị xoá; các thẻ trong cột chuyển sang "Không có".', [o.value]))) {
            return;
          }
          await s.saveProp(g.copyWith(options: g.options.where((x) => x.id != o.id).toList()));
        default:
          if (v.startsWith('propColor')) {
            await s.saveProp(g.copyWith(options: [for (final x in g.options) x.id == o.id ? x.copyWith(color: v) : x]));
          }
      }
    } catch (e) {
      if (mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  Widget _draggable(TaskCard c, Widget child) {
    if (!s.canEdit) return child;
    final feedback = Material(
      color: Colors.transparent,
      child: SizedBox(width: widget.width - 16, child: Opacity(opacity: .9, child: child)),
    );
    final ghost = Opacity(opacity: .35, child: child);
    return isDesktop
        ? Draggable<TaskCard>(data: c, feedback: feedback, childWhenDragging: ghost, child: child)
        : LongPressDraggable<TaskCard>(data: c, feedback: feedback, childWhenDragging: ghost, child: child);
  }

  Widget _slot(String beforeId, Widget child) => DragTarget<TaskCard>(
        onWillAcceptWithDetails: (_) {
          if (_hover != beforeId) setState(() => _hover = beforeId);
          return true;
        },
        onLeave: (_) {
          if (_hover == beforeId) setState(() => _hover = null);
        },
        onAcceptWithDetails: (d) => _drop(d.data, beforeId.isEmpty ? null : beforeId),
        builder: (context, cand, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (cand.isNotEmpty && _hover == beforeId)
            Container(height: 4, margin: const EdgeInsets.only(bottom: 6), decoration: BoxDecoration(color: Pal.of(context).accent, borderRadius: BorderRadius.circular(2))),
          child,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final o = widget.option;
    final i = widget.columns.indexWhere((x) => x.id == o.id);
    final h = MediaQuery.sizeOf(context).height;
    return Container(
      width: widget.width,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      decoration: BoxDecoration(color: pal.surface2.withValues(alpha: .45), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Flexible(child: OptionPill(o.id.isEmpty ? null : o, text: o.value)),
          const SizedBox(width: 8),
          Text('${widget.cards.length}', style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (s.canEdit)
            IconButton(tooltip: tr('Thêm thẻ'), visualDensity: VisualDensity.compact, icon: Icon(Icons.add_rounded, color: pal.sub, size: 20), onPressed: widget.onAdd),
          if (s.canEdit)
            PopupMenuButton<String>(
              tooltip: tr('Thêm'),
              icon: Icon(Icons.more_horiz_rounded, color: pal.sub, size: 20),
              onSelected: _menu,
              itemBuilder: (_) => [
                PopupMenuItem(value: 'hide', child: Text(tr('Ẩn cột'))),
                if (i > 0) PopupMenuItem(value: 'left', child: Text(tr('Chuyển sang trái'))),
                if (i >= 0 && i < widget.columns.length - 1) PopupMenuItem(value: 'right', child: Text(tr('Chuyển sang phải'))),
                if (o.id.isNotEmpty) ...[
                  PopupMenuItem(value: 'rename', child: Text(tr('Đổi tên'))),
                  const PopupMenuDivider(),
                  for (final c in boardsColorNames)
                    PopupMenuItem(
                      value: c,
                      height: 36,
                      child: Row(children: [
                        CircleAvatar(radius: 7, backgroundColor: boardsColor(c, pal.surface2)),
                        const SizedBox(width: 10),
                        Text(colorLabel(c)),
                        if (c == o.color) ...[const Spacer(), const Icon(Icons.check_rounded, size: 16)],
                      ]),
                    ),
                  const PopupMenuDivider(),
                  PopupMenuItem(value: 'del', child: Text(tr('Xoá cột'), style: const TextStyle(color: Color(0xFFE53935)))),
                ],
              ],
            ),
        ]),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: h - 250 < 240 ? 240 : h - 250),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in widget.cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _slot(
                    c.id,
                    _draggable(
                      c,
                      BoardCardTile(store: s, view: widget.view, card: c, selected: c.id == widget.selectedId, onTap: () => widget.onOpen(c)),
                    ),
                  ),
                ),
              _slot(
                '',
                s.canEdit
                    ? TextButton.icon(
                        onPressed: widget.onAdd,
                        style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: pal.sub),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(tr('Thêm thẻ')),
                      )
                    : const SizedBox(height: 24),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
