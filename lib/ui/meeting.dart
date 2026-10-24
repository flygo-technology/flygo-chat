import '../i18n/i18n.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

// Cuộc họp hẹn trước (bảng đính kèm → "Cuộc họp"): tin mang props.flygo_meeting =
// {title, start (ms), allow_early, reminders:[phút], created_by}. Nhắc trong nhóm = tin hẹn giờ của máy chủ chat
// (gửi trước giờ họp N phút và đúng giờ bắt đầu). Bấm "Tham gia" mở cuộc họp (gọi nhóm dạng họp) của chat đó.

/// Bảng tạo cuộc họp. Trả về props.flygo_meeting (null = huỷ).
Future<Map<String, dynamic>?> showCreateMeeting(BuildContext context, String myId) =>
    Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CreateMeeting(myId: myId)));

class _CreateMeeting extends StatefulWidget {
  final String myId;
  const _CreateMeeting({required this.myId});
  @override
  State<_CreateMeeting> createState() => _CreateMeetingState();
}

class _CreateMeetingState extends State<_CreateMeeting> {
  final _title = TextEditingController();
  late DateTime _start = () {
    final n = DateTime.now().add(const Duration(hours: 1));
    return DateTime(n.year, n.month, n.day, n.hour, n.minute < 30 ? 30 : 0).add(Duration(hours: n.minute < 30 ? 0 : 1));
  }();
  bool _early = true;
  bool _remind = true;
  final _reminders = <int>{10};

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty && _start.isAfter(DateTime.now());

  Future<void> _pick() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: _start, firstDate: now, lastDate: now.add(const Duration(days: 365)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (t == null) return;
    setState(() => _start = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
        );
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text(tr('Tạo cuộc họp'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        head(tr('Tên cuộc họp')),
        TextField(
          controller: _title,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: tr('Ví dụ: Họp giao ban tuần'),
            filled: true,
            fillColor: pal.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        head(tr('Thời gian bắt đầu')),
        Material(
          color: pal.surface,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            leading: Icon(Icons.event, color: pal.accent),
            title: Text('${hhmm(_start)} · ${ddmmyyyy(_start)}', style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
            trailing: Icon(Icons.edit_calendar_outlined, color: pal.sub),
            onTap: _pick,
          ),
        ),
        if (!_start.isAfter(DateTime.now()))
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(tr('Thời gian bắt đầu phải ở tương lai.'), style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
        head(tr('Tùy chọn')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _early,
          onChanged: (v) => setState(() => _early = v),
          title: Text(tr('Cho phép tham gia trước giờ'), style: TextStyle(color: pal.text)),
          subtitle: Text(tr('Tắt: chỉ vào được khi tới giờ bắt đầu.'), style: TextStyle(color: pal.sub, fontSize: 13)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _remind,
          onChanged: (v) => setState(() => _remind = v),
          title: Text(tr('Nhắc trong nhóm'), style: TextStyle(color: pal.text)),
          subtitle: Text(tr('Gửi tin nhắc vào chat trước giờ họp và lúc bắt đầu.'), style: TextStyle(color: pal.sub, fontSize: 13)),
        ),
        if (_remind)
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in const [5, 10, 15, 30, 60, 120, 1440])
              FilterChip(
                label: Text(m < 60 ? tr('{0} phút', [m]) : (m < 1440 ? tr('{0} giờ', [m ~/ 60]) : tr('1 ngày'))),
                selected: _reminders.contains(m),
                onSelected: (v) => setState(() => v ? _reminders.add(m) : _reminders.remove(m)),
              ),
          ]),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: !_valid
                  ? null
                  : () => Navigator.pop(context, <String, dynamic>{
                        'title': _title.text.trim(),
                        'start': _start.millisecondsSinceEpoch,
                        'allow_early': _early,
                        'reminders': _remind ? (_reminders.toList()..sort()) : <int>[],
                        'created_by': widget.myId,
                      }),
              icon: const Icon(Icons.event_available),
              label: Text(tr('Tạo cuộc họp'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gửi tin cuộc họp + đặt các tin nhắc (tin hẹn giờ) trong chat.
Future<void> postMeeting(AppState app, String channelId, Map<String, dynamic> m) async {
  final start = DateTime.fromMillisecondsSinceEpoch(m['start'] as int);
  final title = m['title'] as String;
  await app.send(channelId, '📅 ${tr('Cuộc họp')}: $title · ${hhmm(start)} ${ddmmyyyy(start)}', props: {'flygo_meeting': m});
  final now = DateTime.now();
  for (final min in (m['reminders'] as List).cast<int>()) {
    final at = start.subtract(Duration(minutes: min));
    if (!at.isAfter(now.add(const Duration(minutes: 1)))) continue;
    final left = min < 60 ? tr('{0} phút', [min]) : (min < 1440 ? tr('{0} giờ', [min ~/ 60]) : tr('1 ngày'));
    await app.schedule(channelId, '⏰ @channel ${tr('Cuộc họp "{0}" bắt đầu sau {1} ({2}).', [title, left, hhmm(start)])}', at);
  }
  if ((m['reminders'] as List).isNotEmpty) {
    await app.schedule(channelId, '🔔 @channel ${tr('Cuộc họp "{0}" bắt đầu ngay bây giờ. Mở tin cuộc họp và bấm "Tham gia".', [title])}', start);
  }
}

/// Thẻ cuộc họp trong khung tin.
class MeetingCard extends StatefulWidget {
  final AppState app;
  final MmPost post;
  final double width;
  const MeetingCard({super.key, required this.app, required this.post, required this.width});
  @override
  State<MeetingCard> createState() => _MeetingCardState();
}

class _MeetingCardState extends State<MeetingCard> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final m = (widget.post.props['flygo_meeting'] as Map).cast<String, dynamic>();
    final start = DateTime.fromMillisecondsSinceEpoch((m['start'] as num).toInt());
    final now = DateTime.now();
    final left = start.difference(now);
    final started = !left.isNegative;
    final canJoin = m['allow_early'] == true || !started;
    // Cuộc họp đã diễn ra và kết thúc (có tin cuộc gọi của Calls sau thẻ này, đã có giờ kết thúc, không còn cuộc gọi
    // nào đang diễn ra): ẩn nút "Tham gia".
    final calls = widget.app.postsOf(widget.post.channelId).where((p) =>
        p.type == 'custom_calls' && ((p.props['start_at'] as num?)?.toInt() ?? p.createAt) >= widget.post.createAt - 60000);
    final ended = calls.isNotEmpty && calls.every((p) => ((p.props['end_at'] as num?)?.toInt() ?? 0) > 0);
    final w = widget.width.isFinite ? widget.width.clamp(240.0, 340.0) : 300.0;
    String until() {
      if (!started) return tr('Đã tới giờ họp');
      if (left.inMinutes < 60) return tr('Bắt đầu sau {0} phút', [left.inMinutes + 1]);
      if (left.inHours < 24) return tr('Bắt đầu sau {0} giờ', [left.inHours]);
      return tr('Bắt đầu sau {0} ngày', [left.inDays]);
    }

    return SizedBox(
      width: w,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: 44,
            height: 48,
            decoration: BoxDecoration(color: pal.accent.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('${start.day}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: pal.accentText, height: 1)),
              Text(tr('Th{0}', [start.month]), style: TextStyle(fontSize: 11, color: pal.accentText)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m['title']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pal.text)),
              const SizedBox(height: 2),
              Text('${hhmm(start)} · ${ddmmyyyy(start)}', style: TextStyle(fontSize: 13.5, color: pal.sub)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Text(until(), style: TextStyle(fontSize: 13, color: started ? pal.sub : pal.accentText, fontWeight: started ? FontWeight.normal : FontWeight.w600)),
        if ((m['reminders'] as List?)?.isNotEmpty == true)
          Text(
              tr('Nhắc trước: {0}', [
                [for (final x in (m['reminders'] as List).cast<num>()) x < 60 ? tr('{0} phút', [x]) : (x < 1440 ? tr('{0} giờ', [x ~/ 60]) : tr('1 ngày'))].join(', ')
              ]),
              style: TextStyle(fontSize: 12.5, color: pal.sub)),
        const SizedBox(height: 10),
        if (ended)
          Text(tr('Cuộc họp đã kết thúc'), style: TextStyle(fontSize: 13, color: pal.sub, fontWeight: FontWeight.w600))
        else
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: canJoin && !widget.app.calls.busy ? () => widget.app.calls.startCall(widget.post.channelId, meeting: true) : null,
              icon: const Icon(Icons.groups_rounded, size: 19),
              label: Text(canJoin ? tr('Tham gia') : tr('Chưa tới giờ')),
            ),
          ),
      ]),
    );
  }
}
