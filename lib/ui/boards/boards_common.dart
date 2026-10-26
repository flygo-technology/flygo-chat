import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/boards_api.dart';
import '../../api/mm_api.dart';
import '../../data/models.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../reactions.dart' show showEmojiPicker;
import '../theme.dart';

/// Phần dùng chung của các màn hình Boards: màu, tên loại thuộc tính / view, chip phương án, chọn người, hỏi xác nhận.

/// Màu phương án select của Boards (`propColorBlue`...).
Color boardsColor(String c, Color fallback) => switch (c) {
      'propColorGray' => const Color(0xFF9E9E9E),
      'propColorBrown' => const Color(0xFF8D6E63),
      'propColorOrange' => const Color(0xFFFB8C00),
      'propColorYellow' => const Color(0xFFF9A825),
      'propColorGreen' => const Color(0xFF43A047),
      'propColorBlue' => const Color(0xFF1E88E5),
      'propColorPurple' => const Color(0xFF8E24AA),
      'propColorPink' => const Color(0xFFD81B60),
      'propColorRed' => const Color(0xFFE53935),
      _ => fallback,
    };

const boardsColorNames = [
  'propColorDefault', 'propColorGray', 'propColorBrown', 'propColorOrange', 'propColorYellow', 'propColorGreen', 'propColorBlue',
  'propColorPurple', 'propColorPink', 'propColorRed',
];

String colorLabel(String c) => switch (c) {
      'propColorGray' => tr('Xám'),
      'propColorBrown' => tr('Nâu'),
      'propColorOrange' => tr('Cam'),
      'propColorYellow' => tr('Vàng'),
      'propColorGreen' => tr('Xanh lá'),
      'propColorBlue' => tr('Xanh dương'),
      'propColorPurple' => tr('Tím'),
      'propColorPink' => tr('Hồng'),
      'propColorRed' => tr('Đỏ'),
      _ => tr('Mặc định'),
    };

/// Màu kế tiếp cho phương án mới (xoay vòng như bản web).
String nextOptionColor(List<PropOption> opts) => boardsColorNames[1 + opts.length % (boardsColorNames.length - 1)];

String propTypeLabel(String t) => switch (t) {
      'text' => tr('Chữ'),
      'number' => tr('Số'),
      'select' => tr('Chọn một'),
      'multiSelect' => tr('Chọn nhiều'),
      'date' => tr('Ngày'),
      'person' => tr('Một người'),
      'multiPerson' => tr('Nhiều người'),
      'checkbox' => tr('Ô đánh dấu'),
      'url' => tr('Liên kết'),
      'email' => tr('Email'),
      'phone' => tr('Số điện thoại'),
      'createdTime' => tr('Ngày tạo'),
      'createdBy' => tr('Người tạo'),
      'updatedTime' => tr('Ngày sửa'),
      'updatedBy' => tr('Người sửa'),
      _ => t,
    };

IconData propTypeIcon(String t) => switch (t) {
      'text' => Icons.notes_rounded,
      'number' => Icons.numbers_rounded,
      'select' => Icons.arrow_drop_down_circle_outlined,
      'multiSelect' => Icons.checklist_rounded,
      'date' => Icons.event_rounded,
      'person' => Icons.person_outline_rounded,
      'multiPerson' => Icons.people_outline_rounded,
      'checkbox' => Icons.check_box_outlined,
      'url' => Icons.link_rounded,
      'email' => Icons.alternate_email_rounded,
      'phone' => Icons.phone_outlined,
      'createdTime' || 'updatedTime' => Icons.schedule_rounded,
      'createdBy' || 'updatedBy' => Icons.badge_outlined,
      _ => Icons.label_outline_rounded,
    };

String viewTypeLabel(String t) => switch (t) {
      'table' => tr('Bảng'),
      'calendar' => tr('Lịch'),
      'gallery' => tr('Thư viện'),
      _ => tr('Kanban'),
    };

IconData viewTypeIcon(String t) => switch (t) {
      'table' => Icons.table_rows_outlined,
      'calendar' => Icons.calendar_month_outlined,
      'gallery' => Icons.grid_view_rounded,
      _ => Icons.view_kanban_outlined,
    };

String roleLabel(String r) => switch (r) {
      'admin' => tr('Quản trị'),
      'editor' => tr('Chỉnh sửa'),
      'commenter' => tr('Bình luận'),
      'viewer' => tr('Chỉ xem'),
      _ => tr('Không có quyền'),
    };

/// Tên hiển thị của người dùng (người lạ: tải về một lần rồi vẽ lại).
String userName(BuildContext context, String id) {
  final app = context.read<AppState>();
  final u = app.users[id];
  if (u != null) return u.displayName;
  _fetchUser(app, id);
  return id.isEmpty ? '' : '…';
}

final _fetching = <String>{};
void _fetchUser(AppState app, String id) {
  if (id.isEmpty || !_fetching.add(id)) return;
  app.api.usersByIds([id]).then((l) {
    if (l.isNotEmpty) app.putUsers(l);
  }).catchError((_) {});
}

/// Viên màu của một phương án select.
class OptionPill extends StatelessWidget {
  final PropOption? option;
  final String? text;
  final bool dense;
  const OptionPill(this.option, {super.key, this.text, this.dense = false});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final c = boardsColor(option?.color ?? '', pal.sub);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(color: c.withValues(alpha: .16), borderRadius: BorderRadius.circular(6)),
      child: Text(text ?? option?.value ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: dense ? 11.5 : 13, color: option?.color == 'propColorDefault' || option == null ? pal.text : c, fontWeight: FontWeight.w500)),
    );
  }
}

/// Chồng ảnh đại diện (tối đa [max] + số còn lại).
class AvatarStack extends StatelessWidget {
  final List<String> ids;
  final int max;
  final double size;
  const AvatarStack(this.ids, {super.key, this.max = 3, this.size = 21});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final shown = ids.take(max).toList();
    final step = size * .76;
    return SizedBox(
      width: shown.isEmpty ? 0 : (shown.length - 1) * step + size + 4 + (ids.length > max ? 22 : 0),
      height: size + 3,
      child: Stack(children: [
        for (var i = 0; i < shown.length; i++)
          Positioned(
            left: i * step,
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: pal.bg, width: 1.5)),
              child: Avatar(userId: shown[i], name: app.users[shown[i]]?.displayName ?? '?', size: size, status: false),
            ),
          ),
        if (ids.length > max)
          Positioned(
            left: (shown.length - 1) * step + size + 4,
            top: size / 2 - 8,
            child: Text('+${ids.length - max}', style: TextStyle(fontSize: 12, color: pal.sub)),
          ),
      ]),
    );
  }
}

/// Chọn biểu tượng (emoji). Trả về chuỗi emoji, null nếu huỷ.
Future<String?> pickBoardsIcon(BuildContext context) async {
  final name = await showEmojiPicker(context);
  if (name == null) return null;
  final e = emojiOf(name);
  return e.startsWith(':') ? null : e;
}

/// Hỏi xác nhận (nút đỏ cho việc xoá).
Future<bool> confirmBoards(BuildContext context, String title, String body, {String? action, bool danger = true}) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)) : null,
            onPressed: () => Navigator.pop(d, true),
            child: Text(action ?? tr('Xoá')),
          ),
        ],
      ),
    ) ==
    true;

/// Báo lỗi gọn.
void boardsError(BuildContext context, String what, Object e) {
  if (!context.mounted) return;
  final msg = e is ApiException ? (e.status == 403 ? tr('Bạn không có quyền làm việc này trên bảng') : e.message) : '$e';
  ScaffoldMessenger.of(context).showSnackBar(toast(Text('$what: $msg')));
}

/// Mở bảng dưới (sheet) đúng kiểu của app, giới hạn bề rộng trên máy tính.
Future<T?> boardsSheet<T>(BuildContext context, WidgetBuilder builder, {bool scroll = true}) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: scroll,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Pal.of(context).surface,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: builder,
    );

/// Ngày ngắn: dd/mm(/yyyy) [hh:mm].
String shortDate(DateTime d, {bool time = false}) {
  final now = DateTime.now();
  final s = d.year == now.year ? '${d.day}/${d.month}' : '${d.day}/${d.month}/${d.year}';
  return time ? '$s ${hhmm(d)}' : s;
}

/// Hạn: "Hôm nay", "Ngày mai", "Hôm qua" hoặc ngày/tháng(/năm).
String dueText(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days == 0) return tr('Hôm nay');
  if (days == 1) return tr('Ngày mai');
  if (days == -1) return tr('Hôm qua');
  return d.year == now.year ? '${d.day}/${d.month}' : '${d.day}/${d.month}/${d.year}';
}

/// Chọn người trong team (tìm theo tên / @username). [multi] = chọn nhiều; một người thì chọn là xong.
class PeoplePicker extends StatefulWidget {
  final List<MmUser> users;
  final Set<String> selected;
  final bool multi;
  const PeoplePicker({super.key, required this.users, required this.selected, this.multi = true});
  @override
  State<PeoplePicker> createState() => _PeoplePickerState();

  /// Mở bảng chọn người. Trả về tập đã chọn, null nếu huỷ.
  static Future<Set<String>?> show(BuildContext context, {Set<String> selected = const {}, bool multi = true, Set<String> exclude = const {}}) {
    final app = context.read<AppState>();
    final me = app.me?.id;
    final users = app.users.values.where((u) => !u.isBot && u.deleteAt == 0 && !exclude.contains(u.id)).toList()
      ..sort((a, b) => a.id == me ? -1 : b.id == me ? 1 : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return boardsSheet<Set<String>>(context, (_) => PeoplePicker(users: users, selected: selected, multi: multi));
  }
}

class _PeoplePickerState extends State<PeoplePicker> {
  late final Set<String> _sel = {...widget.selected};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final q = normText(_q);
    final list = widget.users.where((u) => q.isEmpty || normText(u.displayName).contains(q) || u.username.toLowerCase().contains(q)).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Tìm người'), isDense: true, border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.multi)
              FilledButton(onPressed: () => Navigator.pop(context, _sel), child: Text(tr('Xong')))
            else if (_sel.isNotEmpty)
              TextButton(onPressed: () => Navigator.pop(context, <String>{}), child: Text(tr('Bỏ chọn'))),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final u = list[i];
              final avatar = Avatar(userId: u.id, name: u.displayName, size: 36, status: false);
              if (!widget.multi) {
                return ListTile(
                  leading: avatar,
                  title: Text(u.displayName, style: TextStyle(color: pal.text)),
                  subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
                  trailing: _sel.contains(u.id) ? Icon(Icons.check_rounded, color: pal.accentText) : null,
                  onTap: () => Navigator.pop(context, {u.id}),
                );
              }
              return CheckboxListTile(
                value: _sel.contains(u.id),
                onChanged: (v) => setState(() => v == true ? _sel.add(u.id) : _sel.remove(u.id)),
                secondary: avatar,
                title: Text(u.displayName, style: TextStyle(color: pal.text)),
                subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Dòng thông báo giữa màn hình (trống / lỗi).
class BoardsNotice extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const BoardsNotice({super.key, required this.icon, required this.title, this.body = '', this.action});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: pal.sub),
        const SizedBox(height: 12),
        Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
        ],
        if (action != null) ...[const SizedBox(height: 14), action!],
      ]),
    );
  }
}
