import 'package:flutter/material.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';
import 'prop_editors.dart';

/// Tuỳ chọn của view: bộ lọc (điều kiện theo thuộc tính), sắp xếp, thuộc tính hiển thị.

String conditionLabel(String c) => switch (c) {
      'includes' => tr('là một trong'),
      'notIncludes' => tr('không là'),
      'isEmpty' => tr('trống'),
      'isNotEmpty' => tr('không trống'),
      'isSet' => tr('đã đặt'),
      'isNotSet' => tr('chưa đặt'),
      'is' => tr('bằng'),
      'contains' => tr('chứa'),
      'notContains' => tr('không chứa'),
      'startsWith' => tr('bắt đầu bằng'),
      'notStartsWith' => tr('không bắt đầu bằng'),
      'endsWith' => tr('kết thúc bằng'),
      'notEndsWith' => tr('không kết thúc bằng'),
      'isBefore' => tr('trước'),
      'isAfter' => tr('sau'),
      _ => c,
    };

/// Phép so phù hợp với loại thuộc tính (như bản web).
List<String> conditionsFor(String type) => switch (type) {
      'select' || 'multiSelect' || 'person' || 'multiPerson' || 'createdBy' || 'updatedBy' => ['includes', 'notIncludes', 'isEmpty', 'isNotEmpty'],
      'checkbox' => ['isSet', 'isNotSet'],
      'date' || 'createdTime' || 'updatedTime' => ['is', 'isBefore', 'isAfter', 'isSet', 'isNotSet'],
      _ => ['is', 'contains', 'notContains', 'startsWith', 'notStartsWith', 'endsWith', 'notEndsWith', 'isEmpty', 'isNotEmpty'],
    };

bool _needsValue(String c) => !const {'isEmpty', 'isNotEmpty', 'isSet', 'isNotSet'}.contains(c);

/// Bảng sửa bộ lọc của view.
class FilterSheet extends StatefulWidget {
  final BoardStore store;
  final BoardView view;
  const FilterSheet({super.key, required this.store, required this.view});
  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late String _op = widget.view.filter.operation;
  late final List<FilterClause> _clauses = widget.view.filter.clauses;
  /// Nhóm lồng (tạo trên bản web) giữ nguyên.
  late final List<FilterGroup> _groups = widget.view.filter.filters.whereType<FilterGroup>().toList();
  final _texts = <int, TextEditingController>{};

  TaskBoard get b => widget.store.board!;

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _type(String propId) => propId == 'title' ? 'text' : (b.prop(propId)?.type ?? 'text');

  Future<void> _apply() async {
    final nav = Navigator.of(context);
    final clauses = [
      for (final (i, c) in _clauses.indexed)
        FilterClause(c.propertyId, c.condition,
            _texts[i] != null ? [if (_texts[i]!.text.trim().isNotEmpty) _texts[i]!.text.trim()] : c.values),
    ];
    try {
      await widget.store.patchView(widget.view, {'filter': FilterGroup(_op, [...clauses, ..._groups]).toJson()});
      nav.pop();
    } catch (e) {
      if (mounted) boardsError(context, tr('Không lưu được bộ lọc'), e);
    }
  }

  Future<void> _pickValues(int i) async {
    final c = _clauses[i];
    final t = b.prop(c.propertyId);
    if (t == null) return;
    List<String>? r;
    if (t.isSelect) {
      r = await boardsSheet<List<String>>(context, (_) => OptionPicker(store: widget.store, prop: t, selected: c.values, forFilter: true));
    } else if (t.isPerson) {
      r = (await PeoplePicker.show(context, selected: c.values.toSet()))?.toList();
    } else if (t.isDate) {
      final now = DateTime.now();
      final init = c.values.isEmpty ? now : DateTime.fromMillisecondsSinceEpoch(int.tryParse(c.values.first) ?? 0, isUtc: true);
      final d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(now.year - 10), lastDate: DateTime(now.year + 10));
      if (d != null) r = ['${DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch}'];
    }
    if (r != null) setState(() => _clauses[i] = FilterClause(c.propertyId, c.condition, r!));
  }

  String _valuesText(FilterClause c) {
    final t = b.prop(c.propertyId);
    if (c.values.isEmpty) return tr('Chọn...');
    if (t == null) return c.values.join(', ');
    if (t.isSelect) return c.values.map(t.optionName).join(', ');
    if (t.isPerson) return c.values.map((id) => userName(context, id)).join(', ');
    if (t.isDate) {
      final d = DateTime.fromMillisecondsSinceEpoch(int.tryParse(c.values.first) ?? 0, isUtc: true);
      return shortDate(DateTime(d.year, d.month, d.day));
    }
    return c.values.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final props = [
      ('title', tr('Tên')),
      for (final p in b.props) (p.id, p.name),
    ];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
          child: Row(children: [
            Expanded(child: Text(tr('Bộ lọc'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text))),
            if (_clauses.isNotEmpty || _groups.isNotEmpty)
              TextButton(
                  onPressed: () => setState(() {
                        _clauses.clear();
                        _groups.clear();
                        _texts.clear();
                      }),
                  child: Text(tr('Xoá hết'))),
            FilledButton(onPressed: _apply, child: Text(tr('Áp dụng'))),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            if (_clauses.length > 1)
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'and', label: Text(tr('Thỏa mọi điều kiện'))),
                  ButtonSegment(value: 'or', label: Text(tr('Thỏa một điều kiện'))),
                ],
                selected: {_op},
                onSelectionChanged: (v) => setState(() => _op = v.first),
              ),
            if (_groups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('{0} nhóm điều kiện tạo trên web được giữ nguyên', [_groups.length]), style: TextStyle(color: pal.sub, fontSize: 13)),
              ),
            for (final (i, c) in _clauses.indexed)
              Card(
                elevation: 0,
                color: pal.surface2.withValues(alpha: .5),
                margin: const EdgeInsets.only(top: 10),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: DropdownButton<String>(
                          value: props.any((p) => p.$1 == c.propertyId) ? c.propertyId : null,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [for (final (id, name) in props) DropdownMenuItem(value: id, child: Text(name, overflow: TextOverflow.ellipsis))],
                          onChanged: (v) => setState(() {
                            _texts.remove(i)?.dispose();
                            _clauses[i] = FilterClause(v!, conditionsFor(_type(v)).first);
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<String>(
                          value: conditionsFor(_type(c.propertyId)).contains(c.condition) ? c.condition : null,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final x in conditionsFor(_type(c.propertyId)))
                              DropdownMenuItem(value: x, child: Text(conditionLabel(x), overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setState(() => _clauses[i] = FilterClause(c.propertyId, v!, c.values)),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Xoá'),
                        icon: Icon(Icons.close_rounded, color: pal.sub, size: 20),
                        onPressed: () => setState(() {
                          _clauses.removeAt(i);
                          // Ô chữ gắn theo vị trí: dựng lại.
                          for (final t in _texts.values) {
                            t.dispose();
                          }
                          _texts.clear();
                        }),
                      ),
                    ]),
                    if (_needsValue(c.condition))
                      if (_type(c.propertyId) == 'text' ||
                          const {'number', 'url', 'email', 'phone'}.contains(_type(c.propertyId)))
                        TextField(
                          controller: _texts[i] ??= TextEditingController(text: c.values.firstOrNull ?? ''),
                          decoration: InputDecoration(hintText: tr('Giá trị'), isDense: true, border: const OutlineInputBorder()),
                        )
                      else
                        OutlinedButton(
                          onPressed: () => _pickValues(i),
                          child: Align(alignment: Alignment.centerLeft, child: Text(_valuesText(c), overflow: TextOverflow.ellipsis)),
                        ),
                  ]),
                ),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  final p = b.props.where((p) => p.type == 'select').firstOrNull;
                  final id = p?.id ?? 'title';
                  _clauses.add(FilterClause(id, conditionsFor(_type(id)).first));
                }),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(tr('Thêm điều kiện')),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Bảng sửa sắp xếp của view (nhiều tiêu chí, theo thứ tự ưu tiên).
class SortSheet extends StatefulWidget {
  final BoardStore store;
  final BoardView view;
  const SortSheet({super.key, required this.store, required this.view});
  @override
  State<SortSheet> createState() => _SortSheetState();
}

class _SortSheetState extends State<SortSheet> {
  late final List<SortOption> _s = widget.view.sortOptions;

  Future<void> _apply() async {
    final nav = Navigator.of(context);
    try {
      await widget.store.patchView(widget.view, {'sortOptions': [for (final s in _s) s.toJson()]});
      nav.pop();
    } catch (e) {
      if (mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = widget.store.board!;
    final props = [(kTitleColumn, tr('Tên')), for (final p in b.props) (p.id, p.name)];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 12, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(tr('Sắp xếp'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text))),
            FilledButton(onPressed: _apply, child: Text(tr('Áp dụng'))),
          ]),
          if (_s.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(tr('Đang theo thứ tự kéo thả'), style: TextStyle(color: pal.sub)),
            ),
          for (final (i, s) in _s.indexed)
            Row(children: [
              Expanded(
                child: DropdownButton<String>(
                  value: props.any((p) => p.$1 == s.propertyId) ? s.propertyId : null,
                  isExpanded: true,
                  items: [for (final (id, name) in props) DropdownMenuItem(value: id, child: Text(name, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => _s[i] = SortOption(v!, s.reversed)),
                ),
              ),
              IconButton(
                tooltip: s.reversed ? tr('Giảm dần') : tr('Tăng dần'),
                icon: Icon(s.reversed ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded),
                onPressed: () => setState(() => _s[i] = SortOption(s.propertyId, !s.reversed)),
              ),
              IconButton(tooltip: tr('Xoá'), icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _s.removeAt(i))),
            ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _s.add(const SortOption(kTitleColumn))),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Thêm tiêu chí')),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Bảng chọn thuộc tính hiện trên thẻ / cột (bật tắt, kéo để đổi thứ tự).
class VisiblePropsSheet extends StatelessWidget {
  final BoardStore store;
  final String viewId;
  const VisiblePropsSheet({super.key, required this.store, required this.viewId});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final v = store.view(viewId);
        final b = store.board;
        if (v == null || b == null) return const SizedBox.shrink();
        final vis = v.visiblePropertyIds.where((id) => b.prop(id) != null).toList();
        final rest = b.props.where((p) => !vis.contains(p.id)).toList();
        Future<void> save(List<String> ids) => store.patchView(v, {'visiblePropertyIds': ids}).catchError((e) {
              if (context.mounted) boardsError(context, tr('Không lưu được'), e);
            });
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('Thuộc tính hiển thị'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text))),
            ),
            Expanded(
              child: CustomScrollView(slivers: [
                SliverReorderableList(
                  itemCount: vis.length,
                  onReorderItem: (a, z) {
                    final l = [...vis];
                    l.insert(z, l.removeAt(a));
                    save(l);
                  },
                  itemBuilder: (_, i) {
                    final p = b.prop(vis[i])!;
                    return Material(
                      key: ValueKey(p.id),
                      color: Colors.transparent,
                      child: SwitchListTile(
                        value: true,
                        secondary: ReorderableDragStartListener(index: i, child: Icon(Icons.drag_indicator_rounded, color: pal.sub)),
                        title: Text(p.name),
                        onChanged: (_) => save(vis.where((x) => x != p.id).toList()),
                      ),
                    );
                  },
                ),
                SliverList.list(children: [
                  for (final p in rest)
                    SwitchListTile(
                      value: false,
                      secondary: Icon(propTypeIcon(p.type), color: pal.sub),
                      title: Text(p.name),
                      onChanged: (_) => save([...vis, p.id]),
                    ),
                ]),
              ]),
            ),
          ]),
        );
      },
    );
  }
}
