import '../i18n/i18n.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'attach_panel.dart';
import 'chat_page.dart';
import 'common.dart';
import 'home_page.dart';
import 'media_view.dart';
import 'theme.dart';

Widget searchInChannel(BuildContext context, String channelId) =>
    SearchPage(terms: '', channelId: channelId, onOpen: (_) {});

/// Mở chat 1-1 với một người (từ danh sách thành viên hoặc tên trong chat).
Future<void> openDirectWith(BuildContext context, AppState app, MmUser u) async {
  if (u.id == app.me?.id) return;
  final host = ChatHost.of(context);
  final nav = Navigator.of(context);
  final id = await app.openDirect(u.id);
  if (host != null) return host.openChat(id);
  nav.popUntil((r) => r.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => ChatPage(channelId: id)));
}

/// Cài đặt cuộc trò chuyện (tin nhắn riêng hoặc nhóm).
class ChatInfoPage extends StatefulWidget {
  final String channelId;
  /// Có thì trang nằm trong cột bên phải (máy tính): nút đóng thay cho quay lại.
  final VoidCallback? onClose;
  const ChatInfoPage({super.key, required this.channelId, this.onClose});
  @override
  State<ChatInfoPage> createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  List<MmUser>? _members;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.loadPinned(widget.channelId);
    app.loadScheduled();
    app.loadTodos();
    _reloadMembers();
  }

  Future<void> _reloadMembers() async {
    final app = context.read<AppState>();
    final ch = app.channels[widget.channelId];
    if (ch == null || ch.isDirect) return;
    final m = await app.channelUsers(widget.channelId);
    if (mounted) setState(() => _members = m);
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  Future<void> _addMembers() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final have = {for (final u in _members ?? const <MmUser>[]) u.id};
    final picked = await Navigator.of(context).push<List<MmUser>>(
      MaterialPageRoute(builder: (_) => _PickPeoplePage(exclude: have)),
    );
    if (picked == null || picked.isEmpty) return;
    try {
      for (final u in picked) {
        await app.addMember(widget.channelId, u.id);
      }
      messenger.showSnackBar(SnackBar(content: Text(tr('Đã thêm {0} thành viên', [picked.length]))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.toString().contains('403') ? tr('Bạn không có quyền thêm thành viên vào kênh này.') : tr('Không thêm được thành viên.'))));
    }
    _reloadMembers();
  }

  Future<bool> _confirmRemove(MmUser u) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Xóa {0} khỏi kênh?', [u.displayName])),
        content: Text(tr('Người này sẽ không xem và nhắn tin trong kênh được nữa.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Xóa'), style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      await app.removeMember(widget.channelId, u.id);
      messenger.showSnackBar(SnackBar(content: Text(tr('Đã xóa {0} khỏi kênh', [u.displayName]))));
      _reloadMembers();
      return true;
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Không xóa được. Bạn có thể không đủ quyền.'))));
      return false;
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
    final muted = app.isMuted(ch.id);
    final fav = app.isFavorite(ch.id);
    final canCall = ch.isDirect || ch.isGroupDm;
    final canManage = !ch.isDirect && app.canManage(ch.id);

    void call({bool video = false}) {
      if (!canCall) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Gọi dùng trong tin nhắn riêng hoặc nhóm nhỏ.'))));
        return;
      }
      app.calls.startCall(ch.id, video: video);
    }

    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
          Row(children: [
            widget.onClose != null
                ? GlassCircle(icon: Icons.close, onTap: widget.onClose)
                : GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
            Expanded(
              child: Text(ch.isDirect ? tr('Thông tin liên lạc') : tr('Thông tin nhóm'),
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            const SizedBox(width: 44),
          ]),
          const SizedBox(height: 24),
          Center(child: Avatar(userId: otherId, name: title, size: 120, icon: otherId == null ? chatIcon(ch) : null)),
          const SizedBox(height: 16),
          nameText(title, bot: app.users[otherId]?.isBot == true, maxLines: 2, textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: pal.text)),
          const SizedBox(height: 4),
          Text(
            other != null ? other.email : (_members == null ? tr('Nhóm') : tr('Nhóm · {0} thành viên', [_members!.length])),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: pal.sub),
          ),
          if (!ch.isDirect && ch.purpose.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(ch.purpose, textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, color: pal.sub)),
          ],
          const SizedBox(height: 22),
          Row(children: [
            _ActionCard(
              icon: fav ? Icons.star_rounded : Icons.star_outline_rounded,
              label: tr('Yêu thích'),
              active: fav,
              onTap: () => app.toggleFavorite(ch.id),
            ),
            const SizedBox(width: 10),
            _ActionCard(icon: Icons.call_outlined, label: tr('Thoại'), onTap: call),
            const SizedBox(width: 10),
            _ActionCard(icon: Icons.videocam_outlined, label: tr('Video'), onTap: () => call(video: true)),
            const SizedBox(width: 10),
            _ActionCard(icon: Icons.search, label: tr('Tìm kiếm'), onTap: () => _push(searchInChannel(context, ch.id))),
          ]),
          const SizedBox(height: 18),
          InfoGroup(children: [
            InfoRow(
              icon: Icons.push_pin_outlined,
              title: tr('Tin đã ghim'),
              value: '${app.pinnedIn(ch.id).length}',
              onTap: () => _push(PinnedPage(channelId: ch.id)),
            ),
            InfoRow(icon: Icons.photo_outlined, title: tr('Hình ảnh'), onTap: () => _push(_ChannelMediaPage(channelId: ch.id, kind: 'images'))),
            InfoRow(
                icon: Icons.insert_drive_file_outlined,
                title: tr('Tệp tin'),
                onTap: () => _push(_ChannelMediaPage(channelId: ch.id, kind: 'files'))),
            InfoRow(
              icon: Icons.schedule_send_outlined,
              title: tr('Tin hẹn giờ'),
              value: '${app.scheduledIn(ch.id).length}',
              onTap: () => _push(ScheduledPage(channelId: ch.id)),
            ),
            InfoRow(icon: Icons.link, title: tr('Liên kết'), onTap: () => _push(_ChannelMediaPage(channelId: ch.id, kind: 'links'))),
            InfoRow(
              icon: Icons.task_alt,
              title: tr('Công việc'),
              value: '${app.openTodosIn(ch.id)}',
              onTap: () => _push(TasksPage(channelId: ch.id)),
            ),
          ]),
          const SizedBox(height: 16),
          InfoGroup(children: [
            InfoRow(
              icon: muted ? Icons.notifications_off_outlined : Icons.notifications_none,
              title: tr('Tắt tiếng'),
              trailing: Switch.adaptive(value: muted, activeTrackColor: pal.accent, onChanged: (v) => app.setMuted(ch.id, v)),
            ),
          ]),
          if (other != null) ...[
            const SizedBox(height: 16),
            InfoGroup(children: [
              InfoRow(icon: Icons.alternate_email, title: tr('Tên đăng nhập'), value: '@${other.username}'),
              InfoRow(icon: Icons.mail_outline, title: tr('Email'), value: other.email),
            ]),
          ],
          if (_members != null) ...[
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(tr('{0} THÀNH VIÊN', [_members!.length]), style: TextStyle(fontSize: 13, color: pal.sub, letterSpacing: .3)),
            ),
            InfoGroup(children: [
              InfoRow(icon: Icons.person_add_alt_1_outlined, title: tr('Thêm thành viên'), onTap: _addMembers),
              for (final u in _members!.take(200))
                canManage && u.id != app.me?.id
                    ? Dismissible(
                        key: ValueKey('m-${u.id}'),
                        direction: DismissDirection.endToStart,
                        confirmDismiss: (_) => _confirmRemove(u),
                        background: Container(
                          color: Colors.redAccent,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.person_remove, color: Colors.white),
                            SizedBox(width: 6),
                            Text(tr('Xóa khỏi kênh'), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                        child: _MemberRow(user: u, isMe: false, onTap: () => openDirectWith(context, app, u)),
                      )
                    : _MemberRow(user: u, isMe: u.id == app.me?.id, onTap: () => openDirectWith(context, app, u)),
            ]),
            if (canManage)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(tr('Vuốt tên thành viên sang trái để xóa khỏi kênh.'), style: TextStyle(fontSize: 12.5, color: pal.sub)),
              ),
          ],
          if (ch.name != 'town-square') ...[
            const SizedBox(height: 48),
            if (!ch.isDirect && !ch.isGroupDm)
              _HoldToConfirm(
                label: tr('Giữ để rời kênh'),
                onConfirmed: () async {
                  final nav = Navigator.of(context);
                  if (await confirmChatAction(context, app, ch.id, 'leave')) nav.popUntil((r) => r.isFirst);
                },
              ),
            _HoldToConfirm(
              label: ch.isDirect || ch.isGroupDm ? tr('Giữ để xóa đoạn chat') : tr('Giữ để xóa kênh'),
              onConfirmed: () async {
                final nav = Navigator.of(context);
                if (await confirmChatAction(context, app, ch.id, 'delete')) nav.popUntil((r) => r.isFirst);
              },
            ),
          ],
        ]),
      ),
    );
  }
}

/// Nút nguy hiểm, nhỏ và nhạt, phải nhấn giữ mới chạy (khó bấm nhầm).
class _HoldToConfirm extends StatelessWidget {
  final String label;
  final VoidCallback onConfirmed;
  const _HoldToConfirm({required this.label, required this.onConfirmed});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('{0} (nhấn giữ khoảng 1 giây)', [label])))),
        onLongPress: () {
          HapticFeedback.heavyImpact();
          onConfirmed();
        },
        // Máy tính: chuột phải làm như nhấn giữ (vẫn có hộp xác nhận).
        onSecondaryTap: onConfirmed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Text(label, style: TextStyle(fontSize: 13.5, color: Colors.redAccent.withValues(alpha: .75))),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _ActionCard({required this.icon, required this.label, required this.onTap, this.active = false});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Expanded(
      child: Material(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Icon(icon, color: active ? const Color(0xFFF5B400) : pal.accentText, size: 27),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 14, color: pal.text)),
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
  final VoidCallback? onTap;
  const _MemberRow({required this.user, required this.isMe, this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final u = user;
    return InkWell(
      onTap: isMe ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Avatar(userId: u?.id, name: u?.displayName ?? '?', size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              nameText(isMe ? tr('Bạn') : (u?.displayName ?? tr('Người dùng')),
                  bot: u?.isBot == true,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: pal.text)),
              if (u != null) Text(u.email, style: TextStyle(fontSize: 13.5, color: pal.sub)),
            ]),
          ),
          if (!isMe) Icon(Icons.chat_bubble_outline, size: 18, color: pal.sub),
        ]),
      ),
    );
  }
}

/// Chọn nhiều người trong công ty để thêm vào kênh.
class _PickPeoplePage extends StatefulWidget {
  final Set<String> exclude;
  const _PickPeoplePage({required this.exclude});
  @override
  State<_PickPeoplePage> createState() => _PickPeoplePageState();
}

class _PickPeoplePageState extends State<_PickPeoplePage> {
  final Set<String> _picked = {};
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final q = _q.toLowerCase();
    final people = app.people
        .where((u) => !widget.exclude.contains(u.id))
        .where((u) => q.isEmpty || u.displayName.toLowerCase().contains(q) || u.email.contains(q))
        .toList();
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              GlassCircle(icon: Icons.close, onTap: () => Navigator.pop(context)),
              Expanded(
                child: Text(tr('Thêm thành viên'),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              GlassCircle(
                icon: Icons.check,
                color: _picked.isEmpty ? pal.surface : pal.accent,
                iconColor: _picked.isEmpty ? pal.sub : Colors.white,
                onTap: _picked.isEmpty ? null : () => Navigator.pop(context, [for (final id in _picked) app.users[id]!]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: TextStyle(color: pal.text),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: pal.surface,
                hintText: tr('Tìm theo tên hoặc email'),
                hintStyle: TextStyle(color: pal.sub),
                prefixIcon: Icon(Icons.search, size: 20, color: pal.sub),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
          Expanded(
            child: people.isEmpty
                ? Center(child: Text(tr('Mọi người đều đã ở trong kênh'), style: TextStyle(color: pal.sub)))
                : ListView(children: [
                    for (final u in people)
                      CheckboxListTile(
                        value: _picked.contains(u.id),
                        activeColor: pal.accent,
                        checkColor: Colors.white,
                        onChanged: (v) => setState(() => v == true ? _picked.add(u.id) : _picked.remove(u.id)),
                        secondary: Avatar(userId: u.id, name: u.displayName, size: 40),
                        title: nameText(u.displayName, bot: u.isBot, style: TextStyle(color: pal.text)),
                        subtitle: Text(u.email, style: TextStyle(color: pal.sub)),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

/// Trang con có thanh tiêu đề chung.
class _SubPage extends StatelessWidget {
  final String title;
  final Widget child;
  const _SubPage({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return EscToPop(child: Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
              Expanded(
                child: Text(title,
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              const SizedBox(width: 44),
            ]),
          ),
          Expanded(child: child),
        ]),
      ),
    ));
  }
}

/// Danh sách tin đã ghim.
class PinnedPage extends StatelessWidget {
  final String channelId;
  const PinnedPage({super.key, required this.channelId});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final list = app.pinnedIn(channelId);
    return _SubPage(
      title: tr('Tin đã ghim'),
      child: list.isEmpty
          ? Center(child: Text(tr('Chưa có tin nào được ghim'), style: TextStyle(color: pal.sub)))
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => Divider(height: 1, indent: 72, color: pal.divider),
              itemBuilder: (_, i) {
                final p = list[i];
                return ListTile(
                  onTap: () {
                    app.requestJump(channelId, p.id);
                    Navigator.of(context).maybePop();
                  },
                  leading: Avatar(userId: p.userId, name: app.users[p.userId]?.displayName ?? '?', size: 40),
                  title: Text(app.users[p.userId]?.displayName ?? tr('Người dùng'),
                      style: TextStyle(color: pal.text, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: Text(app.previewText(p), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub)),
                  trailing: IconButton(
                    tooltip: tr('Bỏ ghim'),
                    icon: Icon(Icons.push_pin, color: pal.sub),
                    onPressed: () => app.setPinned(p, false),
                  ),
                );
              },
            ),
    );
  }
}

/// Danh sách tin hẹn giờ chờ gửi: gửi ngay hoặc hủy.
class ScheduledPage extends StatelessWidget {
  final String channelId;
  const ScheduledPage({super.key, required this.channelId});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final list = app.scheduledIn(channelId);
    return _SubPage(
      title: tr('Tin hẹn giờ'),
      child: list.isEmpty
          ? Center(child: Text(tr('Không có tin hẹn giờ nào'), style: TextStyle(color: pal.sub)))
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => Divider(height: 1, indent: 16, color: pal.divider),
              itemBuilder: (_, i) {
                final sp = list[i];
                final at = DateTime.fromMillisecondsSinceEpoch((sp['scheduled_at'] as num).toInt());
                return ListTile(
                  leading: Icon(Icons.schedule_send_outlined, color: pal.accentText),
                  title: Text(sp['message'] as String? ?? '', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text)),
                  subtitle: Text(tr('Gửi lúc {0} ngày {1}', [hhmm(at), ddmmyyyy(at)]), style: TextStyle(color: pal.sub)),
                  trailing: PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, color: pal.sub),
                    onSelected: (a) async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        a == 'now' ? await app.sendScheduledNow(sp) : await app.cancelScheduled(sp['id'] as String);
                      } catch (_) {
                        messenger.showSnackBar(SnackBar(content: Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'now', child: Text(tr('Gửi ngay'))),
                      PopupMenuItem(value: 'cancel', child: Text(tr('Hủy hẹn giờ'))),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// Hình ảnh / Tệp tin / Liên kết của một cuộc trò chuyện (quét các tin gần đây).
class _ChannelMediaPage extends StatefulWidget {
  final String channelId;
  final String kind;
  const _ChannelMediaPage({required this.channelId, required this.kind});
  @override
  State<_ChannelMediaPage> createState() => _ChannelMediaPageState();
}

class _ChannelMediaPageState extends State<_ChannelMediaPage> {
  List<MmPost>? _posts;
  List<Map<String, dynamic>> _bookmarks = [];
  String? _err;
  static final _url = RegExp(r'https?://[^\s<>()\]]+');

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.scanChannel(widget.channelId).then((p) {
      if (mounted) setState(() => _posts = p);
    }).catchError((_) {
      if (mounted) setState(() => _err = tr('Không tải được. Kiểm tra kết nối mạng.'));
    });
    if (widget.kind == 'links') {
      app.bookmarks(widget.channelId).then((b) {
        if (mounted) setState(() => _bookmarks = b);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final title = {'images': tr('Hình ảnh'), 'files': tr('Tệp tin'), 'links': tr('Liên kết')}[widget.kind]!;
    if (_err != null) return _SubPage(title: title, child: Center(child: Text(_err!, style: TextStyle(color: pal.sub))));
    if (_posts == null) return _SubPage(title: title, child: Center(child: CircularProgressIndicator(color: pal.accent)));
    final posts = _posts!;
    Widget body;
    switch (widget.kind) {
      case 'images':
        final items = [for (final p in posts) for (final f in p.files.where((f) => f.isImage)) (p, f)];
        body = items.isEmpty
            ? Center(child: Text(tr('Chưa có hình ảnh'), style: TextStyle(color: pal.sub)))
            : GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
                children: [
                  for (final (p, f) in items)
                    GestureDetector(
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => GalleryViewer(post: p, images: [ChatImage(file: f)]))),
                      child: Image.network(app.api.thumbUrl(f.id),
                          headers: app.api.headers, fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: pal.surface2)),
                    ),
                ],
              );
      case 'files':
        final items = [for (final p in posts) for (final f in p.files.where((f) => !f.isImage)) (p, f)];
        body = items.isEmpty
            ? Center(child: Text(tr('Chưa có tệp tin'), style: TextStyle(color: pal.sub)))
            : ListView(children: [
                for (final (p, f) in items)
                  ListTile(
                    leading: Icon(f.isVideo ? Icons.videocam_outlined : Icons.insert_drive_file_outlined, color: pal.accentText),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text)),
                    subtitle: Text('${fileSize(f.size)} · ${app.users[p.userId]?.displayName ?? ''} · ${listTime(p.createAt)}',
                        style: TextStyle(color: pal.sub, fontSize: 13)),
                    onTap: () => openFile(context, f),
                  ),
              ]);
      default:
        final links = <(String, String)>[];
        final seen = <String>{};
        for (final b in _bookmarks) {
          final u = b['link_url'] as String? ?? '';
          if (u.isNotEmpty && seen.add(u)) links.add((b['display_name'] as String? ?? u, u));
        }
        final nBookmarks = links.length;
        for (final p in posts) {
          for (final m in _url.allMatches(p.message)) {
            final u = m.group(0)!;
            if (seen.add(u)) links.add((u, u));
          }
        }
        body = links.isEmpty
            ? Center(child: Text(tr('Chưa có liên kết'), style: TextStyle(color: pal.sub)))
            : ListView(children: [
                if (nBookmarks > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(tr('ĐÁNH DẤU CỦA KÊNH'), style: TextStyle(fontSize: 12.5, color: pal.sub)),
                  ),
                for (final (i, (name, u)) in links.indexed) ...[
                  if (i == nBookmarks && nBookmarks > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(tr('LIÊN KẾT TRONG TIN NHẮN'), style: TextStyle(fontSize: 12.5, color: pal.sub)),
                    ),
                  ListTile(
                    leading: Icon(i < nBookmarks ? Icons.bookmark_outline : Icons.link, color: pal.accentText),
                    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text)),
                    subtitle: name == u ? null : Text(u, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub)),
                    onTap: () => launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication),
                  ),
                ],
              ]);
    }
    return _SubPage(title: title, child: body);
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
    'leave' => (tr('Rời "{0}"?', [title]), tr('Bạn sẽ không nhận tin nhắn của kênh này nữa. Có thể được mời lại sau.'), tr('Rời kênh')),
    'delete' when private => (tr('Xóa đoạn chat với "{0}"?', [title]),
        tr('Đoạn chat sẽ ẩn khỏi danh sách của bạn. Khi có tin nhắn mới nó sẽ hiện lại.'), tr('Xóa đoạn chat')),
    _ => (tr('Xóa kênh "{0}"?', [title]), tr('Kênh sẽ được lưu trữ và mọi thành viên không nhắn tiếp được nữa.'), tr('Xóa kênh')),
  };
  final yes = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(q),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
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
        content: Text(noPerm ? tr('Bạn không có quyền làm việc này với kênh.') : tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
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
          if (Platform.isMacOS || Platform.isLinux || Platform.isWindows)
            ListTile(
              leading: Icon(Icons.open_in_new_rounded, color: pal.text),
              title: Text(tr('Mở trong cửa sổ mới'), style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(ctx, 'window'),
            ),
          ListTile(
            leading: Icon(Icons.mark_chat_unread_outlined, color: pal.text),
            title: Text(tr('Đánh dấu là chưa đọc'), style: TextStyle(color: pal.text)),
            onTap: () => Navigator.pop(ctx, 'unread'),
          ),
          ListTile(
            leading: Icon(app.isFavorite(channelId) ? Icons.star_rounded : Icons.star_outline_rounded, color: pal.text),
            title: Text(app.isFavorite(channelId) ? tr('Bỏ yêu thích') : tr('Yêu thích'), style: TextStyle(color: pal.text)),
            onTap: () => Navigator.pop(ctx, 'fav'),
          ),
          ListTile(
            leading: Icon(muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, color: pal.text),
            title: Text(muted ? tr('Bật tiếng') : tr('Tắt tiếng'), style: TextStyle(color: pal.text)),
            onTap: () => Navigator.pop(ctx, 'mute'),
          ),
          if (!private && !isTownSquare)
            ListTile(
              leading: Icon(Icons.logout, color: pal.text),
              title: Text(tr('Rời kênh'), style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(ctx, 'leave'),
            ),
          if (!isTownSquare)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(private ? tr('Xóa đoạn chat') : tr('Xóa kênh'), style: const TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'window') {
    await app.openInWindow(channelId);
  } else if (choice == 'mute') {
    await app.setMuted(channelId, !muted);
  } else if (choice == 'unread') {
    await app.markUnread(channelId);
  } else if (choice == 'fav') {
    await app.toggleFavorite(channelId);
  } else {
    await confirmChatAction(context, app, channelId, choice);
  }
}
