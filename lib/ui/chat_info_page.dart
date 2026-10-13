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
              icon: Icons.chat_bubble_outline,
              label: 'Nhắn tin',
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(width: 12),
            _ActionCard(
              icon: muted ? Icons.notifications_off_outlined : Icons.notifications_none,
              label: muted ? 'Bật tiếng' : 'Tắt tiếng',
              onTap: () => app.setMuted(ch.id, !muted),
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
