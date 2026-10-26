import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';

/// Hiển thị và sửa giá trị thuộc tính của thẻ theo đúng loại (chữ, số, chọn, người, ngày, ô đánh dấu, liên kết...).

/// Chữ hiển thị của một giá trị (dùng cho ô bảng chữ, tìm kiếm...).
String propText(BuildContext context, PropTemplate t, TaskCard c) {
  final v = cardValue(c, t, t.id);
  switch (t.type) {
    case 'select':
    case 'multiSelect':
      return [for (final id in c.list(t.id)) t.optionName(id)].where((s) => s.isNotEmpty).join(', ');
    case 'person':
    case 'multiPerson':
      return [for (final id in c.list(t.id)) userName(context, id)].join(', ');
    case 'createdBy':
    case 'updatedBy':
      return userName(context, '$v');
    case 'createdTime':
    case 'updatedTime':
      final ms = int.tryParse('$v') ?? 0;
      return ms == 0 ? '' : shortDate(DateTime.fromMillisecondsSinceEpoch(ms), time: true);
    case 'date':
      final d = DateProp.parse(v);
      if (d?.start == null) return '';
      final s = shortDate(d!.start!, time: d.includeTime);
      return d.end == null ? s : '$s → ${shortDate(d.end!, time: d.includeTime)}';
    case 'checkbox':
      return v == 'true' ? '✓' : '';
  }
  return v is List ? v.join(', ') : '${v ?? ''}';
}

/// Giá trị thuộc tính dạng gọn (thẻ Kanban, ô bảng, chi tiết thẻ). [dense]: cỡ nhỏ trên thẻ.
class PropValue extends StatelessWidget {
  final PropTemplate t;
  final TaskCard card;
  final bool dense;
  /// Hiện chữ mờ "Trống" khi chưa có giá trị (chi tiết thẻ).
  final bool showEmpty;
  const PropValue(this.t, this.card, {super.key, this.dense = false, this.showEmpty = false});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final fs = dense ? 12.5 : 14.5;
    Widget empty() => showEmpty ? Text(tr('Trống'), style: TextStyle(color: pal.sub.withValues(alpha: .7), fontSize: fs)) : const SizedBox.shrink();
    switch (t.type) {
      case 'select':
      case 'multiSelect':
        final ids = card.list(t.id).where((id) => t.option(id) != null).toList();
        if (ids.isEmpty) return empty();
        return Wrap(spacing: 4, runSpacing: 4, children: [for (final id in ids) OptionPill(t.option(id), dense: dense)]);
      case 'person':
      case 'multiPerson':
      case 'createdBy':
      case 'updatedBy':
        final ids = t.type == 'createdBy' || t.type == 'updatedBy' ? ['${cardValue(card, t, t.id)}'] : card.list(t.id);
        if (ids.isEmpty || ids.first.isEmpty) return empty();
        if (dense && ids.length > 1) return AvatarStack(ids, size: 20);
        final app = context.watch<AppState>();
        return Wrap(spacing: 8, runSpacing: 4, children: [
          for (final id in ids)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Avatar(userId: id, name: app.users[id]?.displayName ?? '?', size: dense ? 18 : 22, status: false),
              const SizedBox(width: 5),
              Flexible(child: Text(userName(context, id), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: fs, color: pal.text))),
            ]),
        ]);
      case 'checkbox':
        final on = card.str(t.id) == 'true';
        if (!on && dense) return const SizedBox.shrink();
        return Icon(on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: dense ? 16 : 20, color: on ? pal.accentText : pal.sub);
      case 'url':
      case 'email':
      case 'phone':
        final s = card.str(t.id) ?? '';
        if (s.isEmpty) return empty();
        return Text(s, maxLines: dense ? 1 : 3, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fs, color: pal.accentText, decoration: TextDecoration.underline, decorationColor: pal.accentText));
      case 'date':
        final d = DateProp.parse(card.properties[t.id]);
        if (d?.start == null) return empty();
        final now = DateTime.now();
        final late = (d!.end ?? d.start!).isBefore(DateTime(now.year, now.month, now.day));
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (dense) ...[Icon(Icons.event_rounded, size: 13, color: late ? const Color(0xFFE53935) : pal.sub), const SizedBox(width: 3)],
          Flexible(
            child: Text(propText(context, t, card), overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fs, color: dense && late ? const Color(0xFFE53935) : (dense ? pal.sub : pal.text))),
          ),
        ]);
    }
    final s = propText(context, t, card);
    if (s.isEmpty) return empty();
    return Text(s, maxLines: dense ? 2 : 8, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: fs, color: dense ? pal.sub : pal.text));
  }
}

/// Mở trình sửa phù hợp với loại thuộc tính rồi lưu vào thẻ. Thuộc tính tự điền thì không làm gì.
Future<void> editProp(BuildContext context, BoardStore store, TaskCard card, PropTemplate t) async {
  if (t.readOnly || !store.canEdit) return;
  try {
    switch (t.type) {
      case 'checkbox':
        await store.setCardProp(card, t.id, card.str(t.id) == 'true' ? '' : 'true');
      case 'select':
      case 'multiSelect':
        final r = await boardsSheet<List<String>>(context, (_) => OptionPicker(store: store, prop: t, selected: card.list(t.id)));
        if (r == null) return;
        await store.setCardProp(card, t.id, t.type == 'select' ? (r.firstOrNull ?? '') : r);
      case 'person':
      case 'multiPerson':
        final multi = t.type == 'multiPerson';
        final r = await PeoplePicker.show(context, selected: card.list(t.id).toSet(), multi: multi);
        if (r == null) return;
        await store.setCardProp(card, t.id, multi ? r.toList() : (r.firstOrNull ?? ''));
      case 'date':
        final r = await boardsSheet<String>(context, (_) => DateEditor(value: DateProp.parse(card.properties[t.id])), scroll: false);
        if (r == null) return;
        await store.setCardProp(card, t.id, r);
      default:
        if (!context.mounted) return;
        final r = await askPropText(context, t, card.str(t.id) ?? '');
        if (r == null) return;
        await store.setCardProp(card, t.id, r.trim());
    }
  } catch (e) {
    if (context.mounted) boardsError(context, tr('Không lưu được'), e);
  }
}

/// Mở liên kết / email / số điện thoại của ô thuộc tính.
Future<void> openPropLink(PropTemplate t, String v) async {
  if (v.isEmpty) return;
  final uri = switch (t.type) {
    'email' => Uri(scheme: 'mailto', path: v),
    'phone' => Uri(scheme: 'tel', path: v),
    _ => Uri.tryParse(v.contains('://') ? v : 'https://$v'),
  };
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Hộp nhập chữ cho thuộc tính chữ / số / liên kết / email / điện thoại.
Future<String?> askPropText(BuildContext context, PropTemplate t, String initial) {
  final ctl = TextEditingController(text: initial);
  final kb = switch (t.type) {
    'number' => const TextInputType.numberWithOptions(decimal: true, signed: true),
    'email' => TextInputType.emailAddress,
    'phone' => TextInputType.phone,
    'url' => TextInputType.url,
    _ => TextInputType.multiline,
  };
  String? err;
  return showDialog<String>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, set) {
        void done() {
          final v = ctl.text.trim();
          if (t.type == 'number' && v.isNotEmpty && num.tryParse(v) == null) {
            set(() => err = tr('Hãy nhập một số'));
            return;
          }
          Navigator.pop(d, v);
        }

        return AlertDialog(
          title: Text(t.name),
          content: TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: kb,
            minLines: 1,
            maxLines: t.type == 'text' ? 6 : 1,
            onSubmitted: (_) => done(),
            decoration: InputDecoration(errorText: err, border: const OutlineInputBorder()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
            FilledButton(onPressed: done, child: Text(tr('Lưu'))),
          ],
        );
      },
    ),
  );
}

/// Chọn phương án (một / nhiều), tìm, tạo phương án mới ngay khi gõ tên chưa có. Trả về danh sách id đã chọn.
class OptionPicker extends StatefulWidget {
  final BoardStore store;
  final PropTemplate prop;
  final List<String> selected;
  /// Dùng cho bộ lọc: luôn chọn nhiều, không tạo phương án mới.
  final bool forFilter;
  const OptionPicker({super.key, required this.store, required this.prop, required this.selected, this.forFilter = false});
  @override
  State<OptionPicker> createState() => _OptionPickerState();
}

class _OptionPickerState extends State<OptionPicker> {
  late final Set<String> _sel = {...widget.selected};
  late PropTemplate _p = widget.prop;
  final _q = TextEditingController();
  bool get _multi => widget.forFilter || _p.type == 'multiSelect';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _q.text.trim();
    if (name.isEmpty) return;
    final o = PropOption(newBoardsId(), name, nextOptionColor(_p.options));
    final np = _p.copyWith(options: [..._p.options, o]);
    try {
      await widget.store.saveProp(np);
    } catch (e) {
      if (mounted) boardsError(context, tr('Không thêm được phương án'), e);
      return;
    }
    if (!mounted) return;
    setState(() {
      _p = np;
      _q.clear();
    });
    if (_multi) {
      setState(() => _sel.add(o.id));
    } else {
      Navigator.pop(context, [o.id]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final q = normText(_q.text);
    final opts = _p.options.where((o) => q.isEmpty || normText(o.value).contains(q)).toList();
    final exact = _p.options.any((o) => normText(o.value) == q);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => !exact && !widget.forFilter && widget.store.canEdit ? _create() : null,
                decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: widget.forFilter ? tr('Tìm phương án') : tr('Tìm hoặc tạo phương án'),
                    isDense: true,
                    border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            if (_multi)
              FilledButton(onPressed: () => Navigator.pop(context, _sel.toList()), child: Text(tr('Xong')))
            else if (_sel.isNotEmpty)
              TextButton(onPressed: () => Navigator.pop(context, <String>[]), child: Text(tr('Bỏ chọn'))),
          ]),
        ),
        Expanded(
          child: ListView(children: [
            for (final o in opts)
              ListTile(
                dense: true,
                leading: _multi
                    ? Checkbox(value: _sel.contains(o.id), onChanged: (v) => setState(() => v == true ? _sel.add(o.id) : _sel.remove(o.id)))
                    : Icon(_sel.contains(o.id) ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                        color: _sel.contains(o.id) ? pal.accentText : pal.sub),
                title: Align(alignment: Alignment.centerLeft, child: OptionPill(o)),
                onTap: () {
                  if (_multi) {
                    setState(() => _sel.contains(o.id) ? _sel.remove(o.id) : _sel.add(o.id));
                  } else {
                    Navigator.pop(context, [o.id]);
                  }
                },
              ),
            if (q.isNotEmpty && !exact && !widget.forFilter && widget.store.canEdit)
              ListTile(
                leading: Icon(Icons.add_rounded, color: pal.accentText),
                title: Text(tr('Tạo "{0}"', [_q.text.trim()]), style: TextStyle(color: pal.accentText)),
                onTap: _create,
              ),
            if (opts.isEmpty && q.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(tr('Chưa có phương án nào. Gõ tên để tạo.'), textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Sửa ngày: một ngày hoặc khoảng ngày, có / không kèm giờ; xoá ngày. Trả về giá trị để lưu ('' = xoá).
class DateEditor extends StatefulWidget {
  final DateProp? value;
  const DateEditor({super.key, this.value});
  @override
  State<DateEditor> createState() => _DateEditorState();
}

class _DateEditorState extends State<DateEditor> {
  late DateTime? _start = widget.value?.start;
  late DateTime? _end = widget.value?.end;
  late bool _range = widget.value?.end != null;
  late bool _time = widget.value?.includeTime ?? false;

  Future<DateTime?> _pick(DateTime? init) async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: init ?? now, firstDate: DateTime(now.year - 10), lastDate: DateTime(now.year + 10));
    if (d == null || !mounted) return null;
    if (!_time) return d;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(init ?? DateTime(d.year, d.month, d.day, 9)));
    return t == null ? d : DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  String _fmt(DateTime? d) => d == null ? tr('Chọn ngày') : shortDate(d, time: _time);

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(_fmt(_start)),
                onPressed: () async {
                  final d = await _pick(_start);
                  if (d != null) setState(() => _start = d);
                },
              ),
            ),
            if (_range) ...[
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward_rounded, color: pal.sub, size: 18)),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event_rounded, size: 18),
                  label: Text(_fmt(_end)),
                  onPressed: () async {
                    final d = await _pick(_end ?? _start);
                    if (d != null) setState(() => _end = d);
                  },
                ),
              ),
            ],
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Khoảng ngày (ngày kết thúc)')),
            value: _range,
            onChanged: (v) => setState(() {
              _range = v;
              if (!v) _end = null;
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Kèm giờ')),
            value: _time,
            onChanged: (v) => setState(() => _time = v),
          ),
          const SizedBox(height: 8),
          Row(children: [
            TextButton.icon(
              onPressed: () => Navigator.pop(context, ''),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(tr('Xoá ngày')),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _start == null
                  ? null
                  : () {
                      final e = _range && _end != null && !_end!.isBefore(_start!) ? _end : null;
                      Navigator.pop(context, DateProp.encode(_start!, end: e, includeTime: _time));
                    },
              child: Text(tr('Lưu')),
            ),
          ]),
        ]),
      ),
    );
  }
}
