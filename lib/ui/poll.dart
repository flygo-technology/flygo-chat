import '../i18n/i18n.dart';

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

// Bình chọn: tin mang props.flygo_poll = {v, question, options:[{id,text,by?}], multi, revote, allow_add,
// ends_at (ms, 0 = không hạn), closed, votes:{user_id:[option_id]}, created_by}.
// Bỏ phiếu / thêm lựa chọn / kết thúc đi qua trạm đẩy (POST <trạm>/poll/vote|option|close): trạm kiểm tra luật
// rồi sửa props của tin bằng quyền quản trị (người bỏ phiếu không sửa được tin của người khác).

String _rid() {
  const a = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(8, (_) => a[r.nextInt(a.length)]).join();
}

/// Bảng tạo bình chọn. Trả về props.flygo_poll (null = huỷ).
Future<Map<String, dynamic>?> showCreatePoll(BuildContext context, String myId) =>
    Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CreatePoll(myId: myId)));

class _CreatePoll extends StatefulWidget {
  final String myId;
  const _CreatePoll({required this.myId});
  @override
  State<_CreatePoll> createState() => _CreatePollState();
}

class _CreatePollState extends State<_CreatePoll> {
  final _q = TextEditingController();
  final _opts = [TextEditingController(), TextEditingController()];
  bool _multi = false, _revote = true, _allowAdd = false;
  String _end = 'none'; // none | after | at
  int _n = 1;
  String _unit = 'h'; // m | h | d
  DateTime? _at;

  @override
  void dispose() {
    _q.dispose();
    for (final c in _opts) {
      c.dispose();
    }
    super.dispose();
  }

  int get _endsAt => switch (_end) {
        'after' => DateTime.now()
            .add(switch (_unit) { 'm' => Duration(minutes: _n), 'h' => Duration(hours: _n), _ => Duration(days: _n) })
            .millisecondsSinceEpoch,
        'at' => _at?.millisecondsSinceEpoch ?? 0,
        _ => 0,
      };

  bool get _valid =>
      _q.text.trim().isNotEmpty &&
      _opts.where((c) => c.text.trim().isNotEmpty).length >= 2 &&
      (_end != 'at' || (_at != null && _at!.isAfter(DateTime.now())));

  void _done() {
    final seen = <String>{};
    final options = [
      for (final c in _opts)
        if (c.text.trim().isNotEmpty && seen.add(c.text.trim().toLowerCase())) {'id': _rid(), 'text': c.text.trim()},
    ];
    Navigator.pop(context, <String, dynamic>{
      'v': 1,
      'question': _q.text.trim(),
      'options': options,
      'multi': _multi,
      'revote': _revote,
      'allow_add': _allowAdd,
      'ends_at': _endsAt,
      'closed': false,
      'votes': <String, dynamic>{},
      'created_by': widget.myId,
    });
  }

  Future<void> _pickAt() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
    if (t == null) return;
    setState(() {
      _at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
      _end = 'at';
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          filled: true,
          fillColor: pal.surface,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        );
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
        );
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        title: Text(tr('Tạo bình chọn')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _valid ? _done : null, child: Text(tr('Gửi'))),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        head(tr('Câu hỏi')),
        TextField(controller: _q, autofocus: true, maxLines: 3, minLines: 1, onChanged: (_) => setState(() {}), decoration: deco(tr('Đặt câu hỏi'))),
        head(tr('Các lựa chọn')),
        for (var i = 0; i < _opts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _opts[i],
                  maxLength: 100,
                  onChanged: (_) => setState(() {}),
                  decoration: deco(tr('Lựa chọn {0}', [i + 1])).copyWith(counterText: ''),
                ),
              ),
              if (_opts.length > 2)
                IconButton(
                  icon: Icon(Icons.remove_circle_outline, color: pal.sub),
                  onPressed: () => setState(() => _opts.removeAt(i).dispose()),
                ),
            ]),
          ),
        if (_opts.length < 20)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _opts.add(TextEditingController())),
              icon: const Icon(Icons.add),
              label: Text(tr('Thêm lựa chọn')),
            ),
          ),
        head(tr('Thời gian kết thúc')),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(label: Text(tr('Không giới hạn')), selected: _end == 'none', onSelected: (_) => setState(() => _end = 'none')),
          ChoiceChip(label: Text(tr('Sau một khoảng')), selected: _end == 'after', onSelected: (_) => setState(() => _end = 'after')),
          ChoiceChip(
            avatar: const Icon(Icons.event, size: 16),
            label: Text(_at == null ? tr('Chọn thời điểm…') : '${hhmm(_at!)} ${ddmmyyyy(_at!)}'),
            selected: _end == 'at',
            onSelected: (_) => _pickAt(),
          ),
        ]),
        if (_end == 'after')
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(children: [
              DropdownButton<int>(
                value: _n,
                items: [for (var i = 1; i <= 10; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                onChanged: (v) => setState(() => _n = v ?? 1),
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: _unit,
                items: [
                  DropdownMenuItem(value: 'm', child: Text(tr('phút'))),
                  DropdownMenuItem(value: 'h', child: Text(tr('giờ'))),
                  DropdownMenuItem(value: 'd', child: Text(tr('ngày'))),
                ],
                onChanged: (v) => setState(() => _unit = v ?? 'h'),
              ),
            ]),
          ),
        head(tr('Tùy chọn')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _multi,
          onChanged: (v) => setState(() => _multi = v),
          title: Text(tr('Cho chọn nhiều lựa chọn'), style: TextStyle(color: pal.text)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _revote,
          onChanged: (v) => setState(() => _revote = v),
          title: Text(tr('Cho bình chọn lại'), style: TextStyle(color: pal.text)),
          subtitle: Text(tr('Người đã bình chọn được đổi hoặc rút lựa chọn.'), style: TextStyle(color: pal.sub, fontSize: 13)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _allowAdd,
          onChanged: (v) => setState(() => _allowAdd = v),
          title: Text(tr('Cho mọi người thêm lựa chọn'), style: TextStyle(color: pal.text)),
        ),
      ]),
    );
  }
}

/// Gọi trạm đẩy cho bình chọn; trả về flygo_poll mới. Lỗi thì ném Exception với lời báo của trạm.
Future<Map<String, dynamic>> pollCall(AppState app, String action, Map<String, dynamic> body) async {
  final r = await http
      .post(Uri.parse('${pushUrlFor(kServerUrl)}/poll/$action'),
          headers: {
            'Authorization': 'Bearer ${app.token}',
            'X-MM-Server': kServerUrl,
            'Content-Type': 'application/json',
            'User-Agent': kUserAgent,
          },
          body: jsonEncode(body))
      .timeout(const Duration(seconds: 15));
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
  if (r.statusCode != 200 || j['ok'] != true) throw Exception(j['error'] ?? 'poll $action ${r.statusCode}');
  return (j['poll'] as Map).cast<String, dynamic>();
}

/// Thẻ bình chọn trong khung tin.
class PollCard extends StatefulWidget {
  final AppState app;
  final MmPost post;
  final double width;
  const PollCard({super.key, required this.app, required this.post, required this.width});
  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  bool _busy = false;
  Set<String>? _draft; // chọn nhiều: các lựa chọn đang tick trước khi bấm "Bình chọn"

  Map<String, dynamic> get _poll => (widget.post.props['flygo_poll'] as Map).cast<String, dynamic>();

  Future<void> _call(String action, Map<String, dynamic> body) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final poll = await pollCall(widget.app, action, {'post_id': widget.post.id, ...body});
      widget.app.mergeLocalProps(widget.post, {'flygo_poll': poll});
      _draft = null;
    } catch (e) {
      messenger.showSnackBar(toast(Text('$e'.replaceFirst('Exception: ', ''))));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addOption() async {
    final t = await askText(context, tr('Thêm lựa chọn'), '');
    if (t == null || t.trim().isEmpty) return;
    await _call('option', {'text': t.trim()});
  }

  Future<void> _showVoters(Map<String, dynamic> o, List<String> ids) => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('${o['text']} · ${ids.length}', style: TextStyle(fontWeight: FontWeight.w700, color: Pal.of(ctx).text, fontSize: 16)),
            ),
            for (final id in ids)
              ListTile(
                leading: Avatar(userId: id, name: widget.app.users[id]?.displayName ?? '', size: 34),
                title: Text(widget.app.users[id]?.displayName ?? id),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final p = _poll;
    final me = widget.app.me?.id ?? '';
    final options = [for (final o in (p['options'] as List? ?? const [])) (o as Map).cast<String, dynamic>()];
    final votes = {for (final e in ((p['votes'] as Map?) ?? const {}).entries) e.key as String: [for (final x in e.value as List) '$x']};
    final mineVotes = votes[me] ?? const <String>[];
    final voted = mineVotes.isNotEmpty;
    final endsAt = (p['ends_at'] as num?)?.toInt() ?? 0;
    final closed = p['closed'] == true || (endsAt > 0 && endsAt <= DateTime.now().millisecondsSinceEpoch);
    final multi = p['multi'] == true, revote = p['revote'] == true;
    final canVote = !closed && !_busy && (!voted || revote);
    final voters = votes.values.where((v) => v.isNotEmpty).length;
    int count(String id) => votes.values.where((v) => v.contains(id)).length;
    final maxCount = options.fold<int>(0, (m, o) => max(m, count(o['id'] as String)));
    final w = widget.width.isFinite ? widget.width.clamp(240.0, 360.0) : 320.0;
    final draft = _draft ?? mineVotes.toSet();

    return SizedBox(
      width: w,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.poll_outlined, size: 18, color: pal.accentText),
          const SizedBox(width: 6),
          Text(tr('Bình chọn'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: pal.accentText, letterSpacing: .3)),
        ]),
        const SizedBox(height: 4),
        Text('${p['question']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pal.text)),
        const SizedBox(height: 2),
        Text(
            [
              multi ? tr('Chọn nhiều') : tr('Chọn một'),
              if (!revote) tr('Không đổi được'),
              if (closed) tr('Đã kết thúc') else if (endsAt > 0) tr('Kết thúc {0} {1}', [hhmm(DateTime.fromMillisecondsSinceEpoch(endsAt)), ddmmyyyy(DateTime.fromMillisecondsSinceEpoch(endsAt))]),
            ].join(' · '),
            style: TextStyle(fontSize: 12.5, color: pal.sub)),
        const SizedBox(height: 8),
        for (final o in options)
          Builder(builder: (context) {
            final id = o['id'] as String;
            final n = count(id);
            final on = draft.contains(id);
            final frac = voters == 0 ? 0.0 : n / voters;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: !canVote
                    ? (n > 0 ? () => _showVoters(o, [for (final e in votes.entries) if (e.value.contains(id)) e.key]) : null)
                    : () {
                        if (multi) {
                          setState(() => _draft = {...draft}..toggle(id));
                        } else {
                          _call('vote', {'options': mineVotes.contains(id) && revote ? <String>[] : [id]});
                        }
                      },
                child: Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: on ? pal.accent : pal.divider)),
                  child: Stack(children: [
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: frac,
                        child: Container(
                          decoration: BoxDecoration(
                            color: (n == maxCount && n > 0 ? pal.accent : pal.sub).withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                      child: Row(children: [
                        Icon(
                          multi
                              ? (on ? Icons.check_box : Icons.check_box_outline_blank)
                              : (on ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                          size: 19,
                          color: on ? pal.accent : pal.sub,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text('${o['text']}', style: TextStyle(color: pal.text, fontSize: 14.5))),
                        Text('$n', style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ]),
                ),
              ),
            );
          }),
        Row(children: [
          Expanded(child: Text(tr('{0} người đã bình chọn', [voters]), style: TextStyle(fontSize: 12.5, color: pal.sub))),
          if (_busy) SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent)),
        ]),
        Wrap(spacing: 4, children: [
          if (multi && canVote && _draft != null && !_setEq(_draft!, mineVotes.toSet()))
            FilledButton(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => _call('vote', {'options': _draft!.toList()}),
              child: Text(tr('Bình chọn')),
            ),
          if (!closed && p['allow_add'] == true)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: _busy ? null : _addOption,
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('Thêm lựa chọn')),
            ),
          if (!closed && p['created_by'] == me)
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: pal.sub),
              onPressed: _busy ? null : () => _call('close', {}),
              child: Text(tr('Kết thúc bình chọn')),
            ),
        ]),
      ]),
    );
  }
}

bool _setEq(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

extension on Set<String> {
  void toggle(String v) => contains(v) ? remove(v) : add(v);
}
