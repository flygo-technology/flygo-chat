import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Tab "Lịch sử": các cuộc gọi gần đây (gọi đi / gọi đến / nhỡ; thoại / video / cuộc họp).
/// Bấm một dòng là gọi lại đúng kiểu cũ (đang diễn ra thì tham gia), nút chat mở cuộc trò chuyện.
class CallHistoryView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final double bottomPadding;
  final Widget? header;
  const CallHistoryView({super.key, required this.onOpen, this.bottomPadding = 0, this.header});
  @override
  State<CallHistoryView> createState() => _CallHistoryViewState();
}

class _CallHistoryViewState extends State<CallHistoryView> {
  bool _onlyMissed = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.markCallsSeen();
    if (!app.callLogLoaded) app.loadCallLog();
  }

  @override
  void deactivate() {
    // Rời trang: những cuộc nhỡ vừa thấy coi như đã xem.
    context.read<AppState>().markCallsSeen();
    super.deactivate();
  }

  String _dur(Duration d) {
    if (d.inHours > 0) return tr('{0} giờ {1} phút', [d.inHours, d.inMinutes % 60]);
    if (d.inMinutes > 0) return tr('{0} phút {1} giây', [d.inMinutes, d.inSeconds % 60]);
    return tr('{0} giây', [d.inSeconds]);
  }

  void _callBack(AppState app, CallLogEntry e) {
    final calls = app.calls;
    if (calls.busy) return;
    if (e.ongoing && (calls.ongoing[e.channelId]?.isNotEmpty ?? false)) {
      calls.join(e.channelId);
    } else {
      calls.startCall(e.channelId, video: e.video, meeting: e.meeting);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final list = app.callLog.where((e) => !_onlyMissed || e.missed).toList();
    Widget chip(String label, bool sel, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Material(
            color: sel ? pal.chipSelBg : Colors.transparent,
            shape: StadiumBorder(side: BorderSide(color: sel ? pal.chipSelBg : pal.divider, width: 1.2)),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(label,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: sel ? pal.chipSelFg : pal.sub)),
              ),
            ),
          ),
        );
    return Column(children: [
      ?widget.header,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(children: [
          chip(tr('Tất cả'), !_onlyMissed, () => setState(() => _onlyMissed = false)),
          chip(tr('Cuộc gọi nhỡ'), _onlyMissed, () => setState(() => _onlyMissed = true)),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.call_outlined, size: 48, color: pal.sub),
                    const SizedBox(height: 12),
                    Text(_onlyMissed ? tr('Không có cuộc gọi nhỡ') : tr('Chưa có cuộc gọi nào'),
                        textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 15)),
                  ]),
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.only(bottom: widget.bottomPadding),
                itemCount: list.length,
                itemBuilder: (_, i) => _row(app, pal, list[i]),
              ),
      ),
    ]);
  }

  Widget _row(AppState app, Pal pal, CallLogEntry e) {
    final c = app.channels[e.channelId];
    final title = c == null ? '' : app.channelTitle(c);
    final other = c?.otherUserId(app.me?.id ?? '');
    const missedRed = Color(0xFFE53935);
    final (IconData dirIcon, Color dirColor, String dirText) = e.ongoing
        ? (Icons.call, pal.accentText, e.meeting ? tr('Cuộc họp đang diễn ra') : tr('Cuộc gọi đang diễn ra'))
        : e.missed
            ? (Icons.call_missed, missedRed, tr('Cuộc gọi nhỡ'))
            : e.meeting
                ? (Icons.groups_outlined, pal.sub, tr('Cuộc họp'))
                : e.outgoing
                    ? (Icons.call_made, const Color(0xFF2E9E5B), tr('Gọi đi'))
                    : (Icons.call_received, const Color(0xFF2E9E5B), tr('Gọi đến'));
    final kind = e.meeting ? '' : (e.video ? tr('Video') : tr('Thoại'));
    final when = '${listTime(e.startAt)}${listTime(e.startAt).contains(':') ? '' : ' ${hhmm(DateTime.fromMillisecondsSinceEpoch(e.startAt))}'}';
    final sub = [
      if (kind.isNotEmpty) kind,
      if (!e.ongoing && !e.missed) _dur(e.duration),
    ].join(' · ');
    final caller = e.meeting || e.outgoing || c?.isDirect == true ? '' : (app.users[e.callerId]?.displayName ?? '');
    return InkWell(
      onTap: () => _callBack(app, e),
      onLongPress: () => widget.onOpen(e.channelId),
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(children: [
          Avatar(userId: other, name: title, size: 46, icon: other == null ? Icons.groups : null, channel: c),
          const SizedBox(width: 14),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.divider, width: .6))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: e.missed ? missedRed : pal.text),
                    ),
                    const SizedBox(height: 2),
                    Row(children: [
                      Icon(dirIcon, size: 16, color: dirColor),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          [dirText, if (caller.isNotEmpty) caller, if (sub.isNotEmpty) sub].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: pal.sub, fontSize: 13.5),
                        ),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(width: 8),
                Text(when, style: TextStyle(color: pal.sub, fontSize: 12.5)),
                IconButton(
                  tooltip: tr('Mở cuộc trò chuyện'),
                  icon: Icon(Icons.chat_bubble_outline, color: pal.sub, size: 21),
                  onPressed: () => widget.onOpen(e.channelId),
                ),
                IconButton(
                  tooltip: e.ongoing ? tr('Tham gia') : tr('Gọi lại'),
                  icon: Icon(e.meeting ? Icons.groups_outlined : (e.video ? Icons.videocam_outlined : Icons.call_outlined),
                      color: pal.accentText),
                  onPressed: app.calls.busy ? null : () => _callBack(app, e),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
