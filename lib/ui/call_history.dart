import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Tab "Lịch sử": các cuộc gọi gần đây (gọi đi / gọi đến / nhỡ; thoại / video / cuộc họp).
/// Bấm một dòng là gọi lại đúng kiểu cũ (đang diễn ra thì tham gia), giữ lâu để mở cuộc trò chuyện.
class CallHistoryView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final double bottomPadding;
  final Widget? header;
  const CallHistoryView({super.key, required this.onOpen, this.bottomPadding = 0, this.header});
  @override
  State<CallHistoryView> createState() => _CallHistoryViewState();
}

class _CallHistoryViewState extends State<CallHistoryView> {

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

  /// Cuộc họp: gọi trong kênh / nhóm (không phải chat 1-1, nhóm nhỏ) hoặc mở ở chế độ họp.
  bool _isMeeting(AppState app, CallLogEntry e) {
    final c = app.channels[e.channelId];
    return e.meeting || (c != null && !c.isDirect && !c.isGroupDm);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final all = app.callLog;
    final tabs = <(String, String, List<CallLogEntry>)>[
      (tr('Tất cả'), tr('Chưa có cuộc gọi nào'), all),
      (tr('Gọi nhỡ'), tr('Không có cuộc gọi nhỡ'), all.where((e) => e.missed).toList()),
      (tr('Gọi đi'), tr('Không có cuộc gọi đi'), all.where((e) => e.outgoing && !_isMeeting(app, e)).toList()),
      (tr('Gọi đến'), tr('Không có cuộc gọi đến'), all.where((e) => !e.outgoing && !e.missed && !_isMeeting(app, e)).toList()),
      (tr('Cuộc họp'), tr('Chưa có cuộc họp nào'), all.where((e) => _isMeeting(app, e)).toList()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        ?widget.header,
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: pal.accentText,
          unselectedLabelColor: pal.sub,
          indicatorColor: pal.accent,
          dividerColor: pal.divider,
          tabs: [for (final (label, _, _) in tabs) Tab(text: label)],
        ),
        Expanded(
          child: TabBarView(children: [
            for (final (_, empty, list) in tabs)
              list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(32, 32, 32, 32 + widget.bottomPadding / 2),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.call_outlined, size: 48, color: pal.sub),
                          const SizedBox(height: 12),
                          Text(empty, textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 15)),
                        ]),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(bottom: widget.bottomPadding),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _row(app, pal, list[i]),
                    ),
          ]),
        ),
      ]),
    );
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
