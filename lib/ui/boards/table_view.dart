import 'package:flutter/material.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';
import 'prop_editors.dart';
import 'props_page.dart';

/// View Bảng: mỗi dòng một thẻ, mỗi cột một thuộc tính đang hiện. Bấm ô để sửa ngay, bấm tiêu đề cột để sắp xếp / ẩn cột.
class TableView extends StatelessWidget {
  final BoardStore store;
  final BoardView view;
  final List<TaskCard> cards;
  final String? selectedId;
  final ValueChanged<TaskCard> onOpen;
  final VoidCallback onAdd;
  const TableView(
      {super.key, required this.store, required this.view, required this.cards, required this.onOpen, required this.onAdd, this.selectedId});

  static const _titleW = 260.0, _colW = 160.0, _rowH = 48.0;

  double _w(String id) => (view.columnWidths[id]?.toDouble() ?? (id == kTitleColumn ? _titleW : _colW)).clamp(90.0, 600.0);

  Future<void> _header(BuildContext context, String id, PropTemplate? t, Offset pos) async {
    final sorts = view.sortOptions;
    final cur = sorts.where((s) => s.propertyId == id).firstOrNull;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        PopupMenuItem(value: 'asc', child: Row(children: [const Icon(Icons.arrow_upward_rounded, size: 18), const SizedBox(width: 10), Text(tr('Sắp xếp tăng dần'))])),
        PopupMenuItem(value: 'desc', child: Row(children: [const Icon(Icons.arrow_downward_rounded, size: 18), const SizedBox(width: 10), Text(tr('Sắp xếp giảm dần'))])),
        if (cur != null) PopupMenuItem(value: 'nosort', child: Text(tr('Bỏ sắp xếp'))),
        if (t != null) ...[
          PopupMenuItem(value: 'hide', child: Row(children: [const Icon(Icons.visibility_off_outlined, size: 18), const SizedBox(width: 10), Text(tr('Ẩn cột'))])),
          if (store.canEdit) PopupMenuItem(value: 'edit', child: Row(children: [const Icon(Icons.edit_outlined, size: 18), const SizedBox(width: 10), Text(tr('Sửa thuộc tính'))])),
        ],
        PopupMenuItem(value: 'wider', child: Text(tr('Rộng hơn'))),
        PopupMenuItem(value: 'narrower', child: Text(tr('Hẹp hơn'))),
      ],
    );
    if (v == null || !context.mounted) return;
    try {
      switch (v) {
        case 'asc':
        case 'desc':
          await store.patchView(view, {
            'sortOptions': [SortOption(id, v == 'desc').toJson()],
          });
        case 'nosort':
          await store.patchView(view, {'sortOptions': [for (final s in sorts) if (s.propertyId != id) s.toJson()]});
        case 'hide':
          await store.patchView(view, {'visiblePropertyIds': view.visiblePropertyIds.where((x) => x != id).toList()});
        case 'edit':
          await editPropertySheet(context, store, prop: t);
        case 'wider':
        case 'narrower':
          await store.patchView(view, {
            'columnWidths': {...view.columnWidths, id: _w(id) + (v == 'wider' ? 60 : -60)},
          });
      }
    } catch (e) {
      if (context.mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // Màn hẹp (điện thoại): mỗi dòng thành một thẻ dọc, không cuộn ngang.
        builder: (context, box) => box.maxWidth < kBoardsNarrow ? _narrow(context) : _wide(context),
      );

  /// Dạng thẻ dọc cho điện thoại: tên + các thuộc tính đang hiện (có giá trị), bấm để mở thẻ.
  Widget _narrow(BuildContext context) {
    final pal = Pal.of(context);
    final b = store.board!;
    final props = [for (final id in view.visiblePropertyIds) ?b.prop(id)];
    bool has(PropTemplate p, TaskCard c) {
      if (p.readOnly) return true;
      final v = c.properties[p.id];
      if (v == null || v == '' || (v is List && v.isEmpty)) return false;
      return !(p.type == 'checkbox' && v != 'true');
    }

    return ListView.builder(
      key: const ValueKey('table-narrow'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: cards.length + 1,
      itemBuilder: (context, i) {
        if (i == cards.length) {
          return store.canEdit
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded, size: 18), label: Text(tr('Thêm thẻ'))),
                )
              : const SizedBox.shrink();
        }
        final c = cards[i];
        final shown = [for (final p in props) if (has(p, c)) p];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: c.id == selectedId ? pal.accent.withValues(alpha: .1) : pal.surface,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onOpen(c),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${c.icon.isEmpty ? '' : '${c.icon} '}${c.title.isEmpty ? tr('(Không có tiêu đề)') : c.title}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.title.isEmpty ? pal.sub : pal.text)),
                      for (final p in shown.take(6))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                            SizedBox(
                              width: 96,
                              child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: pal.sub)),
                            ),
                            Expanded(child: Align(alignment: Alignment.centerLeft, child: ClipRect(child: PropValue(p, c, dense: true)))),
                          ]),
                        ),
                    ]),
                  ),
                  Icon(Icons.chevron_right_rounded, color: pal.sub),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _wide(BuildContext context) {
    final pal = Pal.of(context);
    final b = store.board!;
    final props = [for (final id in view.visiblePropertyIds) ?b.prop(id)];
    final total = _w(kTitleColumn) + [for (final p in props) _w(p.id)].fold(0.0, (a, x) => a + x) + 24;
    final sorts = {for (final s in view.sortOptions) s.propertyId: s.reversed};
    Widget head(String id, PropTemplate? t, String name, IconData icon) => Builder(
          builder: (hc) => InkWell(
            onTapDown: (d) => _header(hc, id, t, d.globalPosition),
            onTap: () {},
            child: Container(
              width: _w(id),
              height: _rowH,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(border: Border(right: BorderSide(color: pal.divider))),
              child: Row(children: [
                Icon(icon, size: 16, color: pal.sub),
                const SizedBox(width: 6),
                Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: pal.sub, fontSize: 13.5))),
                if (sorts.containsKey(id)) Icon(sorts[id]! ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 15, color: pal.accentText),
              ]),
            ),
          ),
        );
    Widget cell(double w, Widget child, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            width: w,
            height: _rowH,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(border: Border(right: BorderSide(color: pal.divider))),
            child: child,
          ),
        );
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: total < MediaQuery.sizeOf(context).width ? MediaQuery.sizeOf(context).width : total,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              decoration: BoxDecoration(color: pal.surface, border: Border(bottom: BorderSide(color: pal.divider))),
              child: Row(children: [
                head(kTitleColumn, null, tr('Tên'), Icons.title_rounded),
                for (final p in props) head(p.id, p, p.name, propTypeIcon(p.type)),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: cards.length + 1,
                itemBuilder: (context, i) {
                  if (i == cards.length) {
                    return store.canEdit
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded, size: 18), label: Text(tr('Thêm thẻ'))),
                          )
                        : const SizedBox.shrink();
                  }
                  final c = cards[i];
                  return Container(
                    decoration: BoxDecoration(
                      color: c.id == selectedId ? pal.accent.withValues(alpha: .1) : null,
                      border: Border(bottom: BorderSide(color: pal.divider.withValues(alpha: .6))),
                    ),
                    child: Row(children: [
                      cell(
                        _w(kTitleColumn),
                        // Bấm tên để mở thẻ (mũi tên nhỏ cho dễ nhận ra).
                        Row(children: [
                          Expanded(
                            child: Text('${c.icon.isEmpty ? '' : '${c.icon} '}${c.title.isEmpty ? tr('(Không có tiêu đề)') : c.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w500, color: c.title.isEmpty ? pal.sub : pal.text)),
                          ),
                          Icon(Icons.chevron_right_rounded, size: 18, color: pal.sub),
                        ]),
                        onTap: () => onOpen(c),
                      ),
                      for (final p in props)
                        cell(
                          _w(p.id),
                          ClipRect(child: PropValue(p, c, dense: true)),
                          onTap: p.readOnly || !store.canEdit ? null : () => editProp(context, store, c, p),
                        ),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
