import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_page.dart';
import 'common.dart';
import 'home_page.dart';
import 'theme.dart';

Widget searchInChannel(BuildContext context, String channelId) =>
    SearchPage(terms: '', channelId: channelId, onOpen: (_) {});

/// Thông tin liên lạc (tin nhắn riêng) hoặc thông tin nhóm.
class ChatInfoPage extends StatefulWidget {
  final String channelId;
  const ChatInfoPage({super.key, required this.channelId});
  @override
  State<ChatInfoPage> createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  List<String>? _memberIds;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final ch = app.channels[widget.channelId];
    if (ch != null && !ch.isDirect) {
      app.api.channelMemberIds(ch.id).then((ids) {
        final missing = ids.where((id) => !app.users.containsKey(id)).toList();
        return app.api.usersByIds(missing).then((us) {
          for (final u in us) {
            app.users[u.id] = u;
          }
          return ids;
        });
      }).then((ids) {
        if (mounted) setState(() => _memberIds = ids);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final ch = app.channels[widget.channelId];
    if (ch == null) return Scaffold(backgroundColor: pal.bg);
    final title = app.channelTitle(ch);
    final otherId = app.me == null ? null : ch.otherUserId(app.me!.id);
    final other = otherId == null ? null : app.users[otherId];
    final files = app.postsOf(ch.id).expand((p) => p.files).toList();
    final muted = app.isMuted(ch.id);

    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          Row(children: [
            GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
            Expanded(
              child: Text(ch.isDirect ? 'Thông tin liên lạc' : 'Thông tin nhóm',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            const SizedBox(width: 44),
          ]),
          const SizedBox(height: 28),
          Center(child: Avatar(userId: otherId, name: title, size: 130, icon: otherId == null ? Icons.groups : null)),
          const SizedBox(height: 18),
          Text(title,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: pal.text)),
          const SizedBox(height: 4),
          Text(
            other != null
                ? other.email
                : (_memberIds == null ? 'Nhóm' : 'Nhóm · ${_memberIds!.length} thành viên'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, color: pal.sub),
          ),
          if (!ch.isDirect && ch.purpose.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(ch.purpose, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: pal.sub)),
          ],
          const SizedBox(height: 24),
          Row(children: [
            _ActionCard(
              icon: Icons.call_outlined,
              label: 'Thoại',
              onTap: () {
                if (!(ch.isDirect || ch.isGroupDm)) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Gọi thoại dùng trong tin nhắn riêng hoặc nhóm nhỏ.')));
                  return;
                }
                app.calls.startCall(ch.id);
              },
            ),
            const SizedBox(width: 12),
            _ActionCard(
              icon: Icons.videocam_outlined,
              label: 'Video',
              onTap: () {
                if (!(ch.isDirect || ch.isGroupDm)) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Gọi video dùng trong tin nhắn riêng hoặc nhóm nhỏ.')));
                  return;
                }
                app.calls.startCall(ch.id, video: true);
              },
            ),
            const SizedBox(width: 12),
            _ActionCard(
              icon: Icons.search,
              label: 'Tìm kiếm',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => searchInChannel(context, ch.id))),
            ),
          ]),
          const SizedBox(height: 20),
          InfoGroup(children: [
            InfoRow(
              icon: Icons.photo_outlined,
              title: 'File phương tiện và tài liệu',
              value: '${files.length}',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _MediaPage(files: files))),
            ),
          ]),
          if (other != null) ...[
            const SizedBox(height: 16),
            InfoGroup(children: [
              InfoRow(icon: Icons.alternate_email, title: 'Tên đăng nhập', value: '@${other.username}'),
              InfoRow(icon: Icons.mail_outline, title: 'Email', value: other.email),
            ]),
          ],
          const SizedBox(height: 16),
          InfoGroup(children: [
            InfoRow(
              icon: muted ? Icons.notifications_off_outlined : Icons.notifications_none,
              title: 'Tắt tiếng',
              trailing: Switch.adaptive(
                value: muted,
                activeTrackColor: pal.accent,
                onChanged: (v) => app.setMuted(ch.id, v),
              ),
            ),
          ]),
          if (ch.name != 'town-square') ...[
            const SizedBox(height: 16),
            InfoGroup(children: [
              if (!ch.isDirect && !ch.isGroupDm)
                InfoRow(
                  icon: Icons.logout,
                  title: 'Rời kênh',
                  danger: true,
                  onTap: () async {
                    final nav = Navigator.of(context);
                    if (await confirmChatAction(context, app, ch.id, 'leave')) nav.popUntil((r) => r.isFirst);
                  },
                ),
              InfoRow(
                icon: Icons.delete_outline,
                title: ch.isDirect || ch.isGroupDm ? 'Xóa đoạn chat' : 'Xóa kênh',
                danger: true,
                onTap: () async {
                  final nav = Navigator.of(context);
                  if (await confirmChatAction(context, app, ch.id, 'delete')) nav.popUntil((r) => r.isFirst);
                },
              ),
            ]),
          ],
          if (_memberIds != null) ...[
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text('${_memberIds!.length} THÀNH VIÊN',
                  style: TextStyle(fontSize: 13, color: pal.sub, letterSpacing: .3)),
            ),
            InfoGroup(children: [
              for (final id in _memberIds!.take(100))
                _MemberRow(user: app.users[id], isMe: id == app.me?.id),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionCard({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Expanded(
      child: Material(
        color: pal.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              Icon(icon, color: pal.accentText, size: 28),
              const SizedBox(height: 8),
              Text(label, style: TextStyle(fontSize: 15.5, color: pal.text)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final MmUser? user;
  final bool isMe;
  const _MemberRow({required this.user, required this.isMe});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final u = user;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        Avatar(userId: u?.id, name: u?.displayName ?? '?', size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isMe ? 'Bạn' : (u?.displayName ?? 'Người dùng'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: pal.text)),
            if (u != null) Text(u.email, style: TextStyle(fontSize: 13.5, color: pal.sub)),
          ]),
        ),
      ]),
    );
  }
}

class _MediaPage extends StatelessWidget {
  final List<MmFile> files;
  const _MediaPage({required this.files});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.read<AppState>();
    final images = files.where((f) => f.isImage).toList();
    final docs = files.where((f) => !f.isImage).toList();
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Row(children: [
            GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
            Expanded(
              child: Text('File phương tiện',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            const SizedBox(width: 44),
          ]),
          const SizedBox(height: 16),
          if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Text('Chưa có file nào trong các tin đã tải.',
                  textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
            ),
          if (images.isNotEmpty)
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 3,
              crossAxisSpacing: 3,
              children: [
                for (final f in images)
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageViewer(file: f))),
                    child: Image.network(app.api.thumbUrl(f.id),
                        headers: app.api.headers,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(color: pal.surface2)),
                  ),
              ],
            ),
          if (docs.isNotEmpty) ...[
            const SizedBox(height: 16),
            InfoGroup(children: [
              for (final f in docs)
                InfoRow(
                  icon: Icons.insert_drive_file_outlined,
                  title: f.name,
                  value: fileSize(f.size),
                  onTap: () => openFile(context, f),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Các thao tác với một cuộc trò chuyện: tắt tiếng, rời kênh, xóa kênh.
/// Dùng chung cho nhấn giữ trong danh sách và trang thông tin.
Future<bool> confirmChatAction(BuildContext context, AppState app, String channelId, String action) async {
  final ch = app.channels[channelId];
  if (ch == null) return false;
  final title = app.channelTitle(ch);
  final private = ch.isDirect || ch.isGroupDm;
  final (q, body, ok) = switch (action) {
    'leave' => ('Rời "$title"?', 'Bạn sẽ không nhận tin nhắn của kênh này nữa. Có thể được mời lại sau.', 'Rời kênh'),
    'delete' when private => ('Xóa đoạn chat với "$title"?',
        'Đoạn chat sẽ ẩn khỏi danh sách của bạn. Khi có tin nhắn mới nó sẽ hiện lại.', 'Xóa đoạn chat'),
    _ => ('Xóa kênh "$title"?', 'Kênh sẽ được lưu trữ và mọi thành viên không nhắn tiếp được nữa.', 'Xóa kênh'),
  };
  final yes = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(q),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Hủy')),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: Text(ok, style: const TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (action == 'leave') {
      await app.leaveChannel(channelId);
    } else if (private) {
      await app.hideConversation(channelId);
    } else {
      await app.archiveChannel(channelId);
    }
    return true;
  } catch (e) {
    final noPerm = e.toString().contains('403');
    messenger.showSnackBar(SnackBar(
        content: Text(noPerm ? 'Bạn không có quyền làm việc này với kênh.' : 'Không thực hiện được. Kiểm tra kết nối mạng.')));
    return false;
  }
}

Future<void> showChatActions(BuildContext context, AppState app, String channelId) async {
  final ch = app.channels[channelId];
  if (ch == null) return;
  final muted = app.isMuted(channelId);
  final private = ch.isDirect || ch.isGroupDm;
  final isTownSquare = ch.name == 'town-square';
  final choice = await showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(app.channelTitle(ch),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
          ),
          ListTile(
            leading: Icon(muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, color: pal.text),
            title: Text(muted ? 'Bật tiếng' : 'Tắt tiếng', style: TextStyle(color: pal.text)),
            onTap: () => Navigator.pop(ctx, 'mute'),
          ),
          if (!private && !isTownSquare)
            ListTile(
              leading: Icon(Icons.logout, color: pal.text),
              title: Text('Rời kênh', style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(ctx, 'leave'),
            ),
          if (!isTownSquare)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(private ? 'Xóa đoạn chat' : 'Xóa kênh', style: const TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'mute') {
    await app.setMuted(channelId, !muted);
  } else {
    await confirmChatAction(context, app, channelId, choice);
  }
}
