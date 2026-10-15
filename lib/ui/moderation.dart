import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Báo cáo tin nhắn: chọn lý do, gửi cho quản trị viên máy chủ.
Future<void> reportPostDialog(BuildContext context, AppState app, MmPost post) async {
  final messenger = ScaffoldMessenger.of(context);
  final reasons = [tr('Spam hoặc quảng cáo'), tr('Quấy rối hoặc xúc phạm'), tr('Nội dung không phù hợp'), tr('Lý do khác')];
  final reason = await showDialog<String>(
    context: context,
    builder: (d) => SimpleDialog(
      title: Text(tr('Báo cáo tin nhắn')),
      children: [
        for (final r in reasons) SimpleDialogOption(onPressed: () => Navigator.pop(d, r), child: Text(r)),
      ],
    ),
  );
  if (reason == null) return;
  try {
    final n = await app.reportPost(post, reason);
    messenger.showSnackBar(SnackBar(
        content: Text(n > 0 ? tr('Đã gửi báo cáo cho quản trị viên.') : tr('Không tìm thấy quản trị viên để gửi báo cáo.'))));
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không gửi được báo cáo. Kiểm tra kết nối mạng.'))));
  }
}

/// Chặn người dùng: ẩn mọi tin của người đó (bỏ chặn trong Cá nhân → Người đã chặn).
Future<void> blockUserDialog(BuildContext context, AppState app, MmUser u) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Chặn {0}?', [u.displayName])),
      content: Text(tr('Bạn sẽ không thấy tin nhắn của người này nữa. Bỏ chặn trong Cá nhân → Người đã chặn.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
        TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Chặn'), style: const TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await app.setBlocked(u.id, true);
    messenger.showSnackBar(toast(Text(tr('Đã chặn {0}', [u.displayName]))));
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
  }
}

/// Yêu cầu xoá tài khoản: gửi cho quản trị viên máy chủ.
Future<void> requestAccountDeletion(BuildContext context, AppState app) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Yêu cầu xoá tài khoản?')),
      content: Text(tr('Quản trị viên sẽ nhận yêu cầu và xoá tài khoản cùng dữ liệu của bạn trên máy chủ này.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
        TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Gửi yêu cầu'), style: const TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final me = app.me;
    final n = await app.sendToAdmins(tr('🗑 Yêu cầu xoá tài khoản: @{0} ({1})', [me?.username ?? '', me?.email ?? '']));
    messenger.showSnackBar(SnackBar(
        content: Text(n > 0 ? tr('Đã gửi yêu cầu cho quản trị viên.') : tr('Không tìm thấy quản trị viên để gửi yêu cầu.'))));
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
  }
}

Future<void> openPrivacyPolicy() => launchUrl(Uri.parse(kPrivacyUrl), mode: LaunchMode.externalApplication);

/// Danh sách người đã chặn, bỏ chặn.
class BlockedUsersPage extends StatelessWidget {
  const BlockedUsersPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final list = app.blocked.map((id) => app.users[id]).whereType<MmUser>().toList();
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(tr('Người đã chặn'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
      ),
      body: list.isEmpty
          ? Center(child: Text(tr('Chưa chặn ai'), style: TextStyle(color: pal.sub)))
          : ListView(children: [
              for (final u in list)
                ListTile(
                  leading: Avatar(userId: u.id, name: u.displayName, size: 40),
                  title: Text(u.displayName, style: TextStyle(color: pal.text)),
                  subtitle: Text(u.email, style: TextStyle(color: pal.sub)),
                  trailing: TextButton(onPressed: () => app.setBlocked(u.id, false), child: Text(tr('Bỏ chặn'))),
                ),
            ]),
    );
  }
}
