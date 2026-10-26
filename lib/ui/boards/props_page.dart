import 'package:flutter/material.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../common.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';

/// Quản lý thuộc tính của bảng: thêm, đổi tên, đổi loại, sắp xếp, xoá; sửa phương án (tên, màu, thứ tự) của thuộc tính chọn.

/// Sửa một thuộc tính ([prop] null = thêm mới).
Future<void> editPropertySheet(BuildContext context, BoardStore store, {PropTemplate? prop}) =>
    boardsSheet<void>(context, (_) => _PropEditor(store: store, prop: prop));

class _PropEditor extends StatefulWidget {
  final BoardStore store;
  final PropTemplate? prop;
  const _PropEditor({required this.store, this.prop});
  @override
  State<_PropEditor> createState() => _PropEditorState();
}

class _PropEditorState extends State<_PropEditor> {
  late final _name = TextEditingController(text: widget.prop?.name ?? '');
  late String _type = widget.prop?.type ?? 'text';
  late List<PropOption> _opts = [...?widget.prop?.options];
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _isSelect => _type == 'select' || _type == 'multiSelect';

  Future<void> _save() async {
    final name = _name.text.trim().isEmpty ? propTypeLabel(_type) : _name.text.trim();
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    try {
      await widget.store.saveProp(PropTemplate(widget.prop?.id ?? newBoardsId(), name, _type, _isSelect ? _opts : const []));
      nav.pop();
    } catch (e) {
      if (mounted) {
        boardsError(context, tr('Không lưu được thuộc tính'), e);
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete() async {
    final p = widget.prop!;
    if (!await confirmBoards(context, tr('Xoá thuộc tính?'), tr('Thuộc tính "{0}" và giá trị của nó trên mọi thẻ sẽ bị xoá.', [p.name]))) return;
    if (!mounted) return;
    final nav = Navigator.of(context);
    try {
      await widget.store.deleteProp(p);
      nav.pop();
    } catch (e) {
      if (mounted) boardsError(context, tr('Không xoá được'), e);
    }
  }

  Future<void> _editOption(int i) async {
    final o = _opts[i];
    final v = await askText(context, tr('Tên phương án'), o.value);
    if (v != null && v.trim().isNotEmpty) setState(() => _opts[i] = o.copyWith(value: v.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final types = boardPropTypes;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * (_isSelect ? .82 : .5),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
          child: Row(children: [
            Expanded(
              child: Text(widget.prop == null ? tr('Thuộc tính mới') : tr('Sửa thuộc tính'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            if (widget.prop != null)
              IconButton(
                  tooltip: tr('Xoá thuộc tính'), icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE53935)), onPressed: _delete),
            FilledButton(onPressed: _saving ? null : _save, child: Text(tr('Lưu'))),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), children: [
            TextField(
              controller: _name,
              autofocus: widget.prop == null,
              decoration: InputDecoration(labelText: tr('Tên thuộc tính'), border: const OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _type,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Loại'), border: const OutlineInputBorder(), isDense: true),
              items: [
                for (final t in types)
                  DropdownMenuItem(
                    value: t,
                    child: Row(children: [Icon(propTypeIcon(t), size: 18, color: pal.sub), const SizedBox(width: 8), Text(propTypeLabel(t))]),
                  ),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            if (_isSelect) ...[
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: Text(tr('Phương án'), style: TextStyle(fontWeight: FontWeight.w600, color: pal.sub))),
                TextButton.icon(
                  onPressed: () async {
                    final v = await askText(context, tr('Phương án mới'), '');
                    if (v != null && v.trim().isNotEmpty) {
                      setState(() => _opts = [..._opts, PropOption(newBoardsId(), v.trim(), nextOptionColor(_opts))]);
                    }
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(tr('Thêm')),
                ),
              ]),
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (a, b) => setState(() {
                  _opts.insert(b, _opts.removeAt(a));
                }),
                children: [
                  for (final (i, o) in _opts.indexed)
                    ListTile(
                      key: ValueKey(o.id),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: ReorderableDragStartListener(index: i, child: Icon(Icons.drag_indicator_rounded, color: pal.sub)),
                      title: Align(alignment: Alignment.centerLeft, child: OptionPill(o)),
                      onTap: () => _editOption(i),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        PopupMenuButton<String>(
                          tooltip: tr('Màu'),
                          icon: Icon(Icons.palette_outlined, color: boardsColor(o.color, pal.sub), size: 20),
                          onSelected: (c) => setState(() => _opts[i] = o.copyWith(color: c)),
                          itemBuilder: (_) => [
                            for (final c in boardsColorNames)
                              PopupMenuItem(
                                value: c,
                                child: Row(children: [
                                  CircleAvatar(radius: 7, backgroundColor: boardsColor(c, pal.surface2)),
                                  const SizedBox(width: 10),
                                  Text(colorLabel(c)),
                                ]),
                              ),
                          ],
                        ),
                        IconButton(
                          tooltip: tr('Xoá'),
                          icon: Icon(Icons.close_rounded, color: pal.sub, size: 20),
                          onPressed: () => setState(() => _opts.removeAt(i)),
                        ),
                      ]),
                    ),
                ],
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Danh sách thuộc tính của bảng: kéo để đổi thứ tự, bấm để sửa, thêm mới.
class PropertiesPage extends StatelessWidget {
  final BoardStore store;
  const PropertiesPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final props = store.board?.props ?? const <PropTemplate>[];
        return Scaffold(
          backgroundColor: pal.bg,
          appBar: AppBar(title: Text(tr('Thuộc tính của thẻ'))),
          floatingActionButton: store.canEdit
              ? FloatingActionButton.extended(
                  heroTag: 'add-prop',
                  onPressed: () => editPropertySheet(context, store),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('Thêm thuộc tính')),
                )
              : null,
          body: props.isEmpty
              ? BoardsNotice(icon: Icons.tune_rounded, title: tr('Bảng chưa có thuộc tính'), body: tr('Thêm thuộc tính như Trạng thái, Người làm, Hạn...'))
              : ReorderableListView(
                  padding: const EdgeInsets.only(bottom: 96),
                  buildDefaultDragHandles: false,
                  onReorderItem: (a, b) {
                    if (!store.canEdit) return;
                    final l = [...props];
                    l.insert(b, l.removeAt(a));
                    store.reorderProps(l).catchError((e) {
                      if (context.mounted) boardsError(context, tr('Không lưu được'), e);
                    });
                  },
                  children: [
                    for (final (i, p) in props.indexed)
                      ListTile(
                        key: ValueKey(p.id),
                        leading: Icon(propTypeIcon(p.type), color: pal.sub),
                        title: Text(p.name, style: TextStyle(color: pal.text)),
                        subtitle: Text(
                            p.isSelect ? '${propTypeLabel(p.type)} · ${tr('{0} phương án', [p.options.length])}' : propTypeLabel(p.type),
                            style: TextStyle(color: pal.sub)),
                        onTap: store.canEdit ? () => editPropertySheet(context, store, prop: p) : null,
                        trailing: store.canEdit
                            ? ReorderableDragStartListener(index: i, child: Icon(Icons.drag_indicator_rounded, color: pal.sub))
                            : null,
                      ),
                  ],
                ),
        );
      },
    );
  }
}
