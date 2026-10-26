import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';
import 'props_page.dart';

/// Cài đặt bảng: tên, biểu tượng, mô tả, quyền truy cập (mở cho team / riêng tư, quyền mặc định), thuộc tính, thành viên,
/// nhân bản, rời / xoá bảng.
class BoardSettingsPage extends StatelessWidget {
  final BoardStore store;
  const BoardSettingsPage({super.key, required this.store});

  Future<void> _run(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (context.mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final b = store.board;
        if (b == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final edit = store.canEdit, admin = store.isAdmin;
        Widget section(String t) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
              child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
            );
        return Scaffold(
          backgroundColor: pal.bg,
          appBar: AppBar(title: Text(tr('Cài đặt bảng'))),
          body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
            ListTile(
              leading: Text(b.icon.isEmpty ? '📋' : b.icon, style: const TextStyle(fontSize: 26)),
              title: Text(b.title.isEmpty ? tr('(Không có tên)') : b.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
              subtitle: Text(b.isOpen ? tr('Mở cho cả team') : tr('Riêng tư'), style: TextStyle(color: pal.sub)),
            ),
            section(tr('Chung')),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(tr('Đổi tên bảng')),
              enabled: edit,
              onTap: () async {
                final t = await askText(context, tr('Đổi tên bảng'), b.title);
                if (t != null && t.trim().isNotEmpty && context.mounted) await _run(context, () => store.patchBoard(title: t.trim()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: Text(tr('Biểu tượng')),
              trailing: b.icon.isEmpty ? null : TextButton(onPressed: !edit ? null : () => _run(context, () => store.patchBoard(icon: '')), child: Text(tr('Bỏ'))),
              enabled: edit,
              onTap: () async {
                final e = await pickBoardsIcon(context);
                if (e != null && context.mounted) await _run(context, () => store.patchBoard(icon: e));
              },
            ),
            ListTile(
              leading: const Icon(Icons.notes_rounded),
              title: Text(tr('Mô tả')),
              subtitle: b.description.isEmpty ? null : Text(b.description, maxLines: 3, overflow: TextOverflow.ellipsis),
              enabled: edit,
              onTap: () async {
                final t = await askText(context, tr('Mô tả'), b.description);
                if (t != null && context.mounted) await _run(context, () => store.patchBoard(description: t.trim()));
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.subject_rounded),
              title: Text(tr('Hiện mô tả trên bảng')),
              value: b.showDescription,
              onChanged: !edit ? null : (v) => _run(context, () => store.patchBoard(showDescription: v)),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: Text(tr('Thuộc tính của thẻ')),
              subtitle: Text(tr('{0} thuộc tính', [b.props.length])),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PropertiesPage(store: store))),
            ),
            section(tr('Quyền truy cập')),
            SwitchListTile(
              secondary: const Icon(Icons.groups_outlined),
              title: Text(tr('Mở cho cả team')),
              subtitle: Text(b.isOpen ? tr('Ai trong team cũng thấy và vào được bảng') : tr('Chỉ thành viên được mời mới thấy bảng')),
              value: b.isOpen,
              onChanged: !admin
                  ? null
                  : (v) => _run(context, () => store.patchBoard(type: v ? 'O' : 'P', minimumRole: v ? (b.minimumRole.isEmpty ? 'editor' : null) : '')),
            ),
            if (b.isOpen)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: Text(tr('Quyền của người trong team')),
                trailing: DropdownButton<String>(
                  value: ['editor', 'commenter', 'viewer'].contains(b.minimumRole) ? b.minimumRole : 'viewer',
                  underline: const SizedBox.shrink(),
                  items: [for (final r in ['editor', 'commenter', 'viewer']) DropdownMenuItem(value: r, child: Text(roleLabel(r)))],
                  onChanged: !admin ? null : (r) => _run(context, () => store.patchBoard(minimumRole: r)),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: Text(tr('Thành viên')),
              subtitle: Text(tr('{0} người · vai trò của bạn: {1}', [store.members.where((m) => !m.synthetic).length, roleLabel(store.myRole)])),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => BoardMembersPage(store: store))),
            ),
            section(tr('Khác')),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(tr('Nhân bản bảng')),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  final r = await store.api.duplicateBoard(b.id);
                  messenger.showSnackBar(toast(Text(tr('Đã nhân bản bảng "{0}"', [r.boards.firstOrNull?.title ?? b.title]))));
                } catch (e) {
                  if (context.mounted) boardsError(context, tr('Không nhân bản được'), e);
                }
              },
            ),
            if (store.members.any((m) => m.userId == store.myId && !m.synthetic))
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: Text(tr('Rời bảng')),
                onTap: () async {
                  if (!await confirmBoards(context, tr('Rời bảng?'), tr('Bạn sẽ không còn là thành viên của bảng này.'), action: tr('Rời'))) return;
                  if (!context.mounted) return;
                  final nav = Navigator.of(context);
                  try {
                    await store.api.leave(b.id);
                    nav.popUntil((r) => r.isFirst);
                  } catch (e) {
                    if (context.mounted) boardsError(context, tr('Không rời được'), e);
                  }
                },
              ),
            if (admin)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE53935)),
                title: Text(tr('Xoá bảng'), style: const TextStyle(color: Color(0xFFE53935))),
                onTap: () async {
                  if (!await confirmBoards(context, tr('Xoá bảng?'), tr('Bảng "{0}" cùng mọi thẻ sẽ bị xoá.', [b.title]))) return;
                  if (!context.mounted) return;
                  final nav = Navigator.of(context);
                  try {
                    await store.api.deleteBoard(b.id);
                    nav.popUntil((r) => r.isFirst);
                  } catch (e) {
                    if (context.mounted) boardsError(context, tr('Không xoá được'), e);
                  }
                },
              ),
          ]),
        );
      },
    );
  }
}

/// Thành viên của bảng: xem, thêm người, đổi vai trò (quản trị / chỉnh sửa / bình luận / chỉ xem), bỏ khỏi bảng.
class BoardMembersPage extends StatelessWidget {
  final BoardStore store;
  const BoardMembersPage({super.key, required this.store});

  Future<void> _add(BuildContext context) async {
    final have = {for (final m in store.members) if (!m.synthetic) m.userId};
    final picked = await PeoplePicker.show(context, exclude: have);
    if (picked == null || picked.isEmpty || !context.mounted) return;
    for (final id in picked) {
      try {
        await store.addMember(id, 'editor');
      } catch (e) {
        if (context.mounted) boardsError(context, tr('Không thêm được thành viên'), e);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final admin = store.isAdmin;
        final list = store.members.where((m) => !m.synthetic).toList()
          ..sort((a, b) {
            final r = boardRoles.indexOf(a.role).compareTo(boardRoles.indexOf(b.role));
            return r != 0 ? r : userName(context, a.userId).toLowerCase().compareTo(userName(context, b.userId).toLowerCase());
          });
        final admins = list.where((m) => m.role == 'admin').length;
        return Scaffold(
          backgroundColor: pal.bg,
          appBar: AppBar(title: Text(tr('Thành viên'))),
          floatingActionButton: admin
              ? FloatingActionButton.extended(
                  heroTag: 'add-member', onPressed: () => _add(context), icon: const Icon(Icons.person_add_alt_1_rounded), label: Text(tr('Thêm người')))
              : null,
          body: RefreshIndicator(
            onRefresh: store.reloadMembers,
            child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              if (store.board?.isOpen == true)
                ListTile(
                  leading: CircleAvatar(backgroundColor: pal.surface2, child: Icon(Icons.groups_outlined, color: pal.sub)),
                  title: Text(tr('Mọi người trong team')),
                  subtitle: Text(tr('Bảng mở cho cả team')),
                  trailing: Text(roleLabel(store.board!.minimumRole.isEmpty ? 'viewer' : store.board!.minimumRole), style: TextStyle(color: pal.sub)),
                ),
              for (final m in list)
                ListTile(
                  leading: Avatar(userId: m.userId, name: app.users[m.userId]?.displayName ?? '?', size: 40, status: false),
                  title: Text(userName(context, m.userId) + (m.userId == store.myId ? ' (${tr('bạn')})' : ''), style: TextStyle(color: pal.text)),
                  subtitle: Text('@${app.users[m.userId]?.username ?? ''}', style: TextStyle(color: pal.sub)),
                  trailing: !admin
                      ? Text(roleLabel(m.role), style: TextStyle(color: pal.sub))
                      : PopupMenuButton<String>(
                          tooltip: tr('Vai trò'),
                          onSelected: (r) async {
                            try {
                              if (r == 'remove') {
                                if (!await confirmBoards(context, tr('Bỏ khỏi bảng?'), userName(context, m.userId), action: tr('Bỏ'))) return;
                                await store.removeMember(m.userId);
                              } else {
                                await store.setMemberRole(m.userId, r);
                              }
                            } catch (e) {
                              if (context.mounted) boardsError(context, tr('Không lưu được'), e);
                            }
                          },
                          itemBuilder: (_) => [
                            for (final r in boardRoles)
                              PopupMenuItem(
                                value: r,
                                enabled: !(m.role == 'admin' && admins <= 1 && r != 'admin'),
                                child: Row(children: [
                                  SizedBox(width: 24, child: r == m.role ? const Icon(Icons.check_rounded, size: 18) : null),
                                  Text(roleLabel(r)),
                                ]),
                              ),
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'remove',
                              enabled: !(m.role == 'admin' && admins <= 1),
                              child: Text(tr('Bỏ khỏi bảng'), style: const TextStyle(color: Color(0xFFE53935))),
                            ),
                          ],
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(roleLabel(m.role), style: TextStyle(color: pal.accentText)),
                            Icon(Icons.arrow_drop_down_rounded, color: pal.accentText),
                          ]),
                        ),
                ),
            ]),
          ),
        );
      },
    );
  }
}
