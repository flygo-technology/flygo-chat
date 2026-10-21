import '../i18n/i18n.dart';
import 'dart:io';

import 'sub_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_page.dart';
import 'chat_themes.dart';
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
  final messenger = ScaffoldMessenger.of(context);
  // Bảo mật: không nhắn riêng với trợ lý AI của người khác (trợ lý chạy trên máy chủ nhân của nó,
  // nhắn riêng thì chủ không thấy). Chỉ dùng trợ lý được chia sẻ trong nhóm có chủ của nó.
  if (u.isBot && !(await app.myBotIds()).contains(u.id)) {
    messenger.showSnackBar(SnackBar(
        content: Text(tr('Chỉ chủ của trợ lý mới nhắn riêng được. Hãy gọi trợ lý trong nhóm có chủ của nó.'))));
    return;
  }
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
  /// Quản trị kênh = người được gửi tin khi kênh khoá gửi tin.
  Set<String> _admins = {};

  Future<void> _changePrivacy(AppState app, MmChannel ch) async {
    final messenger = ScaffoldMessenger.of(context);
    final pal = Pal.of(context);
    Widget option(BuildContext ctx, bool public) => ListTile(
          leading: Icon(public ? Icons.public : Icons.lock_outline, color: pal.text),
          title: Text(public ? tr('Công khai') : tr('Riêng tư'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          subtitle: Text(
              public ? tr('Mọi người trong công ty đều tìm thấy và tham gia được.') : tr('Chỉ người được mời mới thấy và tham gia.'),
              style: TextStyle(color: pal.sub)),
          trailing: ch.isPublic == public ? Icon(Icons.radio_button_checked, color: pal.accent) : Icon(Icons.radio_button_off, color: pal.sub),
          onTap: () => Navigator.pop(ctx, public),
        );
    final public = await showDialog<bool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Loại nhóm')),
        children: [option(ctx, false), option(ctx, true)],
      ),
    );
    if (public == null || public == ch.isPublic) return;
    try {
      await app.setChannelPrivacy(ch.id, public);
      if (mounted) setState(() {});
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không đổi được loại nhóm. Có thể bạn chưa có quyền.'))));
    }
  }

  Future<void> _rename(AppState app, MmChannel ch, String current) async {
    final ctl = TextEditingController(text: current);
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Đổi tên nhóm')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 64,
          decoration: InputDecoration(hintText: tr('Tên nhóm')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Hủy'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(tr('Lưu'))),
        ],
      ),
    );
    ctl.dispose();
    if (name == null || name.trim().isEmpty || name.trim() == current) return;
    try {
      await app.renameChannel(ch.id, name);
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không đổi được tên nhóm. Kiểm tra kết nối mạng.'))));
    }
  }

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
    final admins = await app.channelAdmins(widget.channelId);
    app.loadModeration(widget.channelId);
    if (mounted) {
      setState(() {
        _members = m;
        _admins = admins;
      });
    }
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
      messenger.showSnackBar(toast(Text(tr('Đã thêm {0} thành viên', [picked.length]))));
    } catch (e) {
      messenger.showSnackBar(toast(Text(e is OneAssistantException
          ? e.toString()
          : e.toString().contains('403')
              ? tr('Bạn không có quyền thêm thành viên vào kênh này.')
              : tr('Không thêm được thành viên.'))));
    }
    _reloadMembers();
  }

  Future<void> _togglePost(AppState app, String channelId, MmUser u) async {
    final allow = !_admins.contains(u.id);
    try {
      await app.setPostRight(channelId, u.id, allow);
      setState(() => allow ? _admins.add(u.id) : _admins.remove(u.id));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không đổi được. Bạn có thể không đủ quyền.'))));
      }
    }
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
      messenger.showSnackBar(toast(Text(tr('Đã xóa {0} khỏi kênh', [u.displayName]))));
      _reloadMembers();
      return true;
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không xóa được. Bạn có thể không đủ quyền.'))));
      return false;
    }
  }

  /// "3 người · 1 bot · 2 trợ lý".
  String _memberSummary(AppState app) {
    final m = _members ?? const <MmUser>[];
    final assistants = m.where((u) => u.isBot && app.isAssistant(u.id)).length;
    final bots = m.where((u) => u.isBot).length - assistants;
    final people = m.length - bots - assistants;
    return [
      tr('{0} người', [people]),
      if (bots > 0) tr('{0} bot', [bots]),
      if (assistants > 0) tr('{0} trợ lý', [assistants]),
    ].join(' · ');
  }

  Future<void> _guard(Future<void> Function() f) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await f();
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không đổi được. Bạn có thể không đủ quyền.'))));
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
    final canManage = !ch.isDirect && app.canManage(ch.id);

    // Gọi trong mọi cuộc trò chuyện (nhóm/kênh: đổ chuông cả nhóm), giống nút gọi trên đầu khung chat.
    void call({bool video = false}) => app.calls.startCall(ch.id, video: video);

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
          Center(
            child: otherId == null && (!ch.isPublic || canManage)
                ? EditableAvatar(
                    size: 120,
                    avatar: Avatar(userId: null, name: title, size: 120, icon: chatIcon(ch), channel: ch),
                    onPicked: (n, b) => app.setChannelIcon(ch.id, n, b),
                  )
                : Avatar(userId: otherId, name: title, size: 120, icon: otherId == null ? chatIcon(ch) : null, channel: ch),
          ),
          const SizedBox(height: 16),
          // Nhóm: nút sửa tên ngay bên phải tên (nhóm riêng tư, hoặc mình là quản trị nhóm công khai).
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            // Ngôi sao trước tên: bấm để bật / tắt yêu thích (chat yêu thích ghim lên đầu danh sách).
            IconButton(
              tooltip: app.isFavorite(ch.id) ? tr('Bỏ yêu thích') : tr('Yêu thích'),
              icon: Icon(app.isFavorite(ch.id) ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 28, color: app.isFavorite(ch.id) ? const Color(0xFFFFC107) : pal.sub),
              onPressed: () => app.toggleFavorite(ch.id),
            ),
            Flexible(
              child: nameText(title, bot: app.users[otherId]?.isBot == true, engine: engineOf(app.users[otherId]), maxLines: 2, textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            if (otherId == null && !ch.isSelfDm && (!ch.isPublic || canManage))
              IconButton(
                tooltip: tr('Đổi tên nhóm'),
                icon: Icon(Icons.edit_outlined, size: 22, color: pal.sub),
                onPressed: () => _rename(app, ch, title),
              )
            else
              const SizedBox(width: 48),
          ]),
          const SizedBox(height: 4),
          Text(
            other != null ? other.email : (_members == null ? tr('Nhóm') : 'Nhóm · ${_memberSummary(app)}'.replaceFirst('Nhóm', tr('Nhóm'))),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: pal.sub),
          ),
          if (!ch.isDirect && ch.purposeText.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(ch.purposeText, textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, color: pal.sub)),
          ],
          const SizedBox(height: 22),
          // Bot không nghe máy: không có gọi thoại / video. Yêu thích (ngôi sao) và tìm kiếm đã nằm ngay trong khung chat.
          if (!ch.isSelfDm)
            Row(children: [
              if (!ch.isDirect && other?.isBot != true) ...[
                _ActionCard(
                  icon: Icons.groups_outlined,
                  label: tr('Cuộc họp'),
                  onTap: () => app.calls.startCall(ch.id, meeting: true),
                ),
                const SizedBox(width: 10),
              ],
              if (other?.isBot != true) ...[
                _ActionCard(icon: Icons.call_outlined, label: tr('Thoại'), onTap: call),
                const SizedBox(width: 10),
                _ActionCard(icon: Icons.videocam_outlined, label: tr('Video'), onTap: () => call(video: true)),
                const SizedBox(width: 10),
              ],
              // Thông báo: bật / tắt có thời hạn (gộp "Thông báo" + "Tắt tiếng" cũ).
              _NotifyCard(channelId: ch.id),
            ]),
          const SizedBox(height: 18),
          InfoGroup(children: [
            // Loại nhóm: công khai / riêng tư (quản trị nhóm mới đổi được).
            if (!ch.isDirect && !ch.isGroupDm && !ch.isSub && !ch.isSelfDm)
              InfoRow(
                icon: ch.isPublic ? Icons.public : Icons.lock_outline,
                title: tr('Loại nhóm'),
                value: ch.isPublic ? tr('Công khai') : tr('Riêng tư'),
                onTap: canManage ? () => _changePrivacy(app, ch) : null,
              ),
            // Khoá gửi tin: chỉ người được cấp quyền (quản trị kênh) mới chat được.
            if (!ch.isDirect && !ch.isGroupDm && !ch.isSub && !ch.isSelfDm)
              InfoRow(
                icon: Icons.edit_off_outlined,
                title: tr('Chỉ người được cấp quyền mới gửi tin'),
                trailing: Switch.adaptive(
                  value: app.postLocked[ch.id] == true,
                  activeTrackColor: pal.accent,
                  onChanged: canManage
                      ? (v) => app.setPostLocked(ch.id, v).catchError((_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  toast(Text(tr('Không đổi được. Bạn có thể không đủ quyền.'))));
                            }
                          })
                      : null,
                ),
              ),
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
            if (ch.isSub)
              InfoRow(icon: Icons.outbox_outlined, title: tr('Gửi kết luận về nhóm'), onTap: () => sendConclusionDialog(context, ch)),
            if (!ch.isDirect && !ch.isGroupDm)
              InfoRow(
                icon: Icons.notes,
                title: tr('Mô tả'),
                value: ch.purposeText.isEmpty ? tr('Chưa có') : ch.purposeText.replaceAll('\n', ' '),
                onTap: () => _push(_PurposePage(channelId: ch.id)),
              ),
            // Giao diện chat và banner: dùng chung cho mọi người trong cuộc trò chuyện.
            InfoRow(
              icon: Icons.palette_outlined,
              title: tr('Giao diện chat'),
              value: chatThemeById(ch.themeId)?.name ?? tr('Mặc định'),
              onTap: () async {
                final id = await pickChatTheme(context, ch.themeId);
                if (id == null) return;
                await _guard(() => app.setChatTheme(ch.id, id.isEmpty ? null : id));
              },
            ),
            InfoRow(
              icon: Icons.campaign_outlined,
              title: tr('Banner'),
              value: ch.flygoBanner?.text ?? tr('Chưa có'),
              onTap: () async {
                final b = await editBanner(context, ch.flygoBanner);
                if (b == null) return;
                await _guard(() => app.setChatBanner(ch.id, b.text.isEmpty ? null : b));
              },
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
              child: Text(_memberSummary(app).toUpperCase(), style: TextStyle(fontSize: 13, color: pal.sub, letterSpacing: .3)),
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
                        child: _MemberRow(
                            user: u,
                            isMe: false,
                            onTap: () => openDirectWith(context, app, u),
                            canPost: app.postLocked[ch.id] == true ? _admins.contains(u.id) : null,
                            onTogglePost: () => _togglePost(app, ch.id, u)),
                      )
                    : _MemberRow(
                        user: u,
                        isMe: u.id == app.me?.id,
                        onTap: () => openDirectWith(context, app, u),
                        canPost: app.postLocked[ch.id] == true ? _admins.contains(u.id) : null),
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
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('{0} (nhấn giữ khoảng 1 giây)', [label])))),
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
  const _ActionCard({required this.icon, required this.label, required this.onTap});
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
              Icon(icon, color: pal.accentText, size: 27),
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
  /// Kênh khoá gửi tin: người này có quyền gửi tin không (null = kênh không khoá, không hiện).
  final bool? canPost;
  /// Quản trị kênh: bấm để cấp / bỏ quyền gửi tin.
  final VoidCallback? onTogglePost;
  const _MemberRow({required this.user, required this.isMe, this.onTap, this.canPost, this.onTogglePost});
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
                  bot: u?.isBot == true, engine: engineOf(u),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: pal.text)),
              if (u != null) Text(u.email, style: TextStyle(fontSize: 13.5, color: pal.sub)),
            ]),
          ),
          if (canPost != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: Icon(canPost! ? Icons.check_circle : Icons.block, size: 16,
                    color: canPost! ? const Color(0xFF2E9D5B) : pal.sub),
                label: Text(canPost! ? tr('Được gửi tin') : tr('Chỉ xem'),
                    style: TextStyle(fontSize: 12.5, color: canPost! ? const Color(0xFF2E9D5B) : pal.sub)),
                backgroundColor: pal.surface,
                side: BorderSide(color: pal.divider),
                shape: const StadiumBorder(),
                onPressed: onTogglePost,
              ),
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
    // Cả người và bot (bot có biểu tượng robot) để thêm vào cho tiện.
    final people = app.peopleAndBots
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
                        onChanged: (v) => setState(() {
                          // Mỗi chat chỉ một trợ lý AI: chọn trợ lý này thì bỏ trợ lý đã chọn trước.
                          if (v == true && engineOf(u) != null) _picked.removeWhere((id) => engineOf(app.users[id]) != null);
                          v == true ? _picked.add(u.id) : _picked.remove(u.id);
                        }),
                        secondary: Avatar(userId: u.id, name: u.displayName, size: 40, icon: u.isBot ? Icons.smart_toy_outlined : null),
                        title: nameText(u.displayName, bot: u.isBot, engine: engineOf(u), style: TextStyle(color: pal.text)),
                        subtitle: Text(u.isBot ? '@${u.username}' : u.email, style: TextStyle(color: pal.sub)),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

/// Sửa mô tả kênh.
class _PurposePage extends StatefulWidget {
  final String channelId;
  const _PurposePage({required this.channelId});
  @override
  State<_PurposePage> createState() => _PurposePageState();
}

class _PurposePageState extends State<_PurposePage> {
  late final _ctl = TextEditingController(text: context.read<AppState>().channels[widget.channelId]?.purposeText ?? '');
  bool _busy = false;

  Future<void> _save() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await app.setPurpose(widget.channelId, _ctl.text.trim());
      nav.pop();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(toast(Text(tr('Không lưu được mô tả. Bạn có thể không có quyền sửa kênh này.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return _SubPage(
      title: tr('Mô tả'),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _ctl,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          maxLength: 250,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: tr('Kênh này dùng để làm gì?'),
            filled: true,
            fillColor: pal.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
            onPressed: _busy ? null : _save,
            child: Text(tr('Lưu'), style: const TextStyle(fontSize: 16)),
          ),
        ),
      ]),
    );
  }
}

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
                        messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
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

/// Thao tác nhanh với một cuộc trò chuyện (giữ / nháy phải trong danh sách chat):
/// menu hiện ngay tại chỗ bấm [at].
Future<void> showChatActions(BuildContext context, AppState app, String channelId, {Offset? at}) async {
  final ch = app.channels[channelId];
  if (ch == null) return;
  final muted = app.isMuted(channelId);
  final private = ch.isDirect || ch.isGroupDm;
  final isTownSquare = ch.name == 'town-square';
  final unread = app.unreadOf(channelId) > 0 || (app.members[channelId]?.mentionCount ?? 0) > 0;
  final pal = Pal.of(context);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final box = context.findRenderObject() as RenderBox?;
  final p = at ?? (box == null ? overlay.size.center(Offset.zero) : box.localToGlobal(box.size.center(Offset.zero)));
  PopupMenuItem<String> item(String v, IconData icon, String label, {bool danger = false}) => PopupMenuItem(
        value: v,
        height: 44,
        child: Row(children: [
          Icon(icon, size: 20, color: danger ? Colors.redAccent : pal.text),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: danger ? Colors.redAccent : pal.text, fontSize: 15)),
        ]),
      );
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(p & const Size(1, 1), Offset.zero & overlay.size),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    items: [
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows)
        item('window', Icons.open_in_new_rounded, tr('Mở trong cửa sổ mới')),
      unread
          ? item('read', Icons.mark_chat_read_outlined, tr('Đánh dấu là đã đọc'))
          : item('unread', Icons.mark_chat_unread_outlined, tr('Đánh dấu là chưa đọc')),
      item('fav', app.isFavorite(channelId) ? Icons.star_rounded : Icons.star_outline_rounded,
          app.isFavorite(channelId) ? tr('Bỏ yêu thích') : tr('Yêu thích')),
      item('mute', muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, muted ? tr('Bật tiếng') : tr('Tắt tiếng')),
      if (!private && !isTownSquare) item('leave', Icons.logout, tr('Rời kênh')),
      if (!isTownSquare) item('delete', Icons.delete_outline, private ? tr('Xóa đoạn chat') : tr('Xóa kênh'), danger: true),
    ],
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'window') {
    await app.openInWindow(channelId);
  } else if (choice == 'mute') {
    await app.setMuted(channelId, !muted);
  } else if (choice == 'unread') {
    await app.markUnread(channelId);
  } else if (choice == 'read') {
    app.markViewed(channelId);
  } else if (choice == 'fav') {
    await app.toggleFavorite(channelId);
  } else {
    await confirmChatAction(context, app, channelId, choice);
  }
}


/// Nút "Thông báo" cạnh Thoại / Video: menu bật, tắt 10 phút … 5 giờ, tùy chỉnh, tắt tới khi bật lại.
class _NotifyCard extends StatelessWidget {
  final String channelId;
  const _NotifyCard({required this.channelId});

  Future<void> _custom(BuildContext context, AppState app) async {
    var hours = 8.0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) {
        final pal = Pal.of(d);
        return AlertDialog(
          title: Text(tr('Tắt thông báo trong')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('{0} giờ', [hours.round()]), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: pal.text)),
            Slider(value: hours, min: 1, max: 72, divisions: 71, label: tr('{0} giờ', [hours.round()]), onChanged: (v) => set(() => hours = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Tắt thông báo'))),
          ],
        );
      }),
    );
    if (ok == true) await app.setNotificationsOff(channelId, Duration(hours: hours.round()));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final off = app.notificationsOff(channelId);
    final until = app.muteUntil[channelId] ?? 0;
    final label = !off
        ? tr('Thông báo')
        : until > 0
            ? tr('Tắt đến {0}', [hhmm(DateTime.fromMillisecondsSinceEpoch(until))])
            : tr('Đã tắt');
    final items = <(String, String)>[
      ('on', tr('Bật thông báo')),
      ('10', tr('Tắt 10 phút')),
      ('20', tr('Tắt 20 phút')),
      ('30', tr('Tắt 30 phút')),
      ('60', tr('Tắt 1 giờ')),
      ('120', tr('Tắt 2 giờ')),
      ('300', tr('Tắt 5 giờ')),
      ('custom', tr('Tùy chỉnh…')),
      ('forever', tr('Tắt đến khi bật lại')),
    ];
    return Expanded(
      child: PopupMenuButton<String>(
        tooltip: tr('Thông báo'),
        color: pal.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: (v) async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            switch (v) {
              case 'on':
                await app.setNotificationsOn(channelId);
              case 'custom':
                await _custom(context, app);
              case 'forever':
                await app.setNotificationsOff(channelId, null);
              default:
                await app.setNotificationsOff(channelId, Duration(minutes: int.parse(v)));
            }
          } catch (_) {
            messenger.showSnackBar(toast(Text(tr('Không đổi được cài đặt thông báo.'))));
          }
        },
        itemBuilder: (_) => [
          for (final (v, l) in items)
            PopupMenuItem(
              value: v,
              height: 42,
              child: Row(children: [
                Icon(v == 'on' ? Icons.notifications_active_outlined : (v == 'custom' ? Icons.tune : Icons.notifications_off_outlined),
                    size: 19, color: v == 'on' && !off ? pal.accent : pal.sub),
                const SizedBox(width: 12),
                Text(l, style: TextStyle(color: pal.text, fontWeight: v == 'on' && !off ? FontWeight.w700 : FontWeight.normal)),
              ]),
            ),
        ],
        child: Material(
          color: pal.surface,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Icon(off ? Icons.notifications_off_outlined : Icons.notifications_none_rounded, color: off ? pal.sub : pal.accentText, size: 27),
              const SizedBox(height: 6),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: pal.text)),
            ]),
          ),
        ),
      ),
    );
  }
}
