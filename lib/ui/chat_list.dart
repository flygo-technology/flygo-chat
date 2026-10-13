import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_info_page.dart';
import 'common.dart';
import 'theme.dart';

enum ChatFilter { all, unread, favorites, groups, direct }

Map<ChatFilter, String> get chatFilterLabels => {
  ChatFilter.all: tr('Tất cả'),
  ChatFilter.unread: tr('Chưa đọc'),
  ChatFilter.favorites: tr('Yêu thích'),
  ChatFilter.groups: tr('Nhóm'),
  ChatFilter.direct: tr('Tin nhắn riêng'),
};

/// Danh sách hội thoại: kênh và tin nhắn riêng chung một danh sách.
class ChatList extends StatelessWidget {
  final String query;
  final ChatFilter filter;
  final String? selectedId;
  final void Function(String channelId) onOpen;
  final VoidCallback? onSearchMessages;
  final Widget? header;
  final double bottomPadding;
  const ChatList({
    super.key,
    this.query = '',
    this.filter = ChatFilter.all,
    this.selectedId,
    required this.onOpen,
    this.onSearchMessages,
    this.header,
    this.bottomPadding = 0,
  });

  bool _match(ChatSummary c, Set<String> favorites) {
    final ch = c.channel;
    switch (filter) {
      case ChatFilter.all:
        break;
      case ChatFilter.unread:
        if (c.unread == 0 && c.mentions == 0) return false;
      case ChatFilter.favorites:
        if (!favorites.contains(ch.id)) return false;
      case ChatFilter.groups:
        if (ch.isDirect) return false;
      case ChatFilter.direct:
        if (!ch.isDirect && !ch.isGroupDm) return false;
    }
    final q = query.trim().toLowerCase();
    return q.isEmpty || c.title.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final chats = app.chats.where((c) => _match(c, app.favorites)).toList();
    final searchRow = query.trim().length >= 2 && onSearchMessages != null;
    final extra = (header != null ? 1 : 0);
    return RefreshIndicator(
      color: pal.accent,
      onRefresh: app.syncAll,
      child: ListView.builder(
        padding: EdgeInsets.only(bottom: bottomPadding),
        itemCount: extra + (app.ready ? chats.length : 1) + (searchRow ? 1 : 0),
        itemBuilder: (context, i) {
          if (header != null && i == 0) return header!;
          i -= extra;
          if (!app.ready) {
            if (app.lastError != null) {
              return Padding(
                padding: const EdgeInsets.all(40),
                child: Column(children: [
                  Icon(Icons.cloud_off, size: 48, color: pal.sub),
                  const SizedBox(height: 12),
                  Text(tr('Chưa kết nối được máy chủ.\nKiểm tra mạng rồi thử lại.'),
                      textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 15)),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                    onPressed: app.syncAll,
                    child: Text(tr('Thử lại')),
                  ),
                ]),
              );
            }
            return Padding(
                padding: const EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: pal.accent)));
          }
          if (i == chats.length) {
            return ListTile(
              leading: Icon(Icons.search, color: pal.sub),
              title: Text(tr('Tìm "{0}" trong tin nhắn', [query]), style: TextStyle(color: pal.text)),
              onTap: onSearchMessages,
            );
          }
          return ChatTile(
            c: chats[i],
            selected: chats[i].channel.id == selectedId,
            onTap: () => onOpen(chats[i].channel.id),
          );
        },
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  final ChatSummary c;
  final bool selected;
  final VoidCallback onTap;
  const ChatTile({super.key, required this.c, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final last = c.last;
    final mine = last != null && last.userId == app.me?.id;
    final unread = c.unread > 0;
    final typing = app.typingIn(c.channel.id);
    final ch = c.channel;
    String prefix = '';
    if (last != null && !mine && !ch.isDirect && !last.isSystem) {
      prefix = '~${app.users[last.userId]?.displayName ?? ''}: ';
    }
    IconData? leadIcon;
    if (last != null && last.message.isEmpty && last.files.isNotEmpty) {
      leadIcon = last.files.first.isImage ? Icons.photo_camera : Icons.insert_drive_file;
    }
    final preview = last != null && last.message.isEmpty && last.files.isNotEmpty
        ? (last.files.first.isImage ? tr('Ảnh') : last.files.first.name)
        : app.previewText(last);

    return Material(
      color: selected ? pal.surface : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showChatActions(context, app, c.channel.id),
        onSecondaryTap: () => showChatActions(context, app, c.channel.id),
        child: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Avatar(
                userId: c.avatarUserId,
                name: c.title,
                size: 56,
                icon: c.avatarUserId == null ? (c.channel.isSelfDm ? Icons.cloud : Icons.groups) : null,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                padding: const EdgeInsets.only(top: 12, bottom: 12, right: 16),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.divider, width: .6))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
                    ),
                    const SizedBox(width: 8),
                    Text(listTime(c.sortTime),
                        style: TextStyle(fontSize: 14, color: unread ? pal.accentText : pal.sub)),
                  ]),
                  const SizedBox(height: 3),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: typing.isNotEmpty
                          ? Text(tr('đang soạn tin...'), style: TextStyle(color: pal.accentText, fontSize: 15))
                          : Text.rich(
                              TextSpan(children: [
                                if (mine && !last.isSystem)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                        padding: const EdgeInsets.only(right: 4),
                                        child: statusIcon(last, app, pal, size: 17)),
                                  ),
                                if (leadIcon != null)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                        padding: const EdgeInsets.only(right: 4),
                                        child: Icon(leadIcon, size: 17, color: pal.sub)),
                                  ),
                                TextSpan(text: '$prefix$preview'),
                              ]),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: pal.sub, fontSize: 15, height: 1.3),
                            ),
                    ),
                    if (c.mentions > 0 && !ch.isDirect)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, top: 2),
                        child: CircleAvatar(
                            radius: 11,
                            backgroundColor: pal.accent,
                            child: const Text('@', style: TextStyle(color: Colors.white, fontSize: 12))),
                      ),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(left: 6, top: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(11)),
                        child: Text(c.unread > 99 ? '99+' : '${c.unread}',
                            style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Biểu tượng trạng thái tin của mình: đồng hồ, lỗi, hai dấu tích xám/xanh.
Widget statusIcon(MmPost p, AppState app, Pal pal, {double size = 15}) {
  switch (p.sendState) {
    case SendState.sending:
      return Icon(Icons.schedule, size: size - 2, color: pal.sub);
    case SendState.failed:
      return Icon(Icons.error_outline, size: size, color: Colors.redAccent);
    case SendState.sent:
      final seen = app.channels[p.channelId]?.isDirect == true && app.isSeen(p);
      return Icon(Icons.done_all, size: size, color: seen ? pal.tick : pal.sub);
  }
}
