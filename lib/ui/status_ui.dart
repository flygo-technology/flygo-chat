import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'common.dart';
import 'reactions.dart';
import 'theme.dart';

String availabilityLabel(String status) => switch (status) {
      'online' => tr('Trực tuyến'),
      'away' => tr('Vắng mặt'),
      'dnd' => tr('Đừng làm phiền'),
      _ => tr('Ngoại tuyến'),
    };

/// Dòng hiện trạng thái của một người: "📅 Đang họp" hoặc "Trực tuyến".
String statusLine(AppState app, String userId) {
  final c = app.customStatusOf(userId);
  if (c != null) return [if (c.emoji.isNotEmpty) emojiOf(c.emoji), c.text].where((s) => s.isNotEmpty).join(' ');
  return availabilityLabel(app.statusOf(userId));
}

Widget statusDot(String status, Pal pal, {double size = 12}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Avatar.statusColor(status, pal) ?? Colors.transparent,
        border: Avatar.statusColor(status, pal) == null ? Border.all(color: pal.sub, width: 2) : null,
      ),
    );

/// Hai dòng trong trang Bạn: hoạt động (trực tuyến / vắng / đừng làm phiền / ẩn)
/// và trạng thái tùy chỉnh chọn từ danh sách (dropdown) hoặc quản lý danh sách.
class StatusSection extends StatelessWidget {
  const StatusSection({super.key});

  Future<void> _pickAvailability(BuildContext context, AppState app) async {
    final pal = Pal.of(context);
    final v = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(tr('Hoạt động'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
          ),
          for (final s in ['online', 'away', 'dnd', 'offline'])
            ListTile(
              leading: statusDot(s, pal, size: 14),
              title: Text(s == 'offline' ? tr('Ẩn (hiện ngoại tuyến)') : availabilityLabel(s), style: TextStyle(color: pal.text)),
              trailing: app.statusOf(app.me!.id) == s ? Icon(Icons.check_circle, color: pal.accent) : null,
              onTap: () => Navigator.pop(ctx, s),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (v != null) {
      app.setMyStatus(v).catchError((_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Không đổi được trạng thái.'))));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final me = app.me!;
    final st = app.statusOf(me.id);
    final custom = app.customStatusOf(me.id);
    return Container(
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        InkWell(
          onTap: () => _pickAvailability(context, app),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            child: Row(children: [
              SizedBox(width: 24, child: Center(child: statusDot(st, pal, size: 14))),
              const SizedBox(width: 16),
              Expanded(child: Text(tr('Hoạt động'), style: TextStyle(fontSize: 17, color: pal.text))),
              Text(availabilityLabel(st), style: TextStyle(fontSize: 16, color: pal.sub)),
              Icon(Icons.chevron_right, color: pal.sub),
            ]),
          ),
        ),
        Divider(height: 1, thickness: .6, indent: 56, color: pal.divider),
        PopupMenuButton<int>(
          tooltip: tr('Chọn trạng thái'),
          position: PopupMenuPosition.under,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          constraints: const BoxConstraints(minWidth: 260),
          onSelected: (i) {
            if (i == -1) {
              app.clearCustomStatus().catchError((_) {});
            } else if (i == -2) {
              showManageStatuses(context);
            } else {
              final p = app.statusPresets[i];
              app.setCustomStatus(p.emoji, p.text).catchError((_) {});
            }
          },
          itemBuilder: (_) => [
            for (var i = 0; i < app.statusPresets.length; i++)
              PopupMenuItem(
                value: i,
                child: Row(children: [
                  SizedBox(width: 28, child: Text(emojiOf(app.statusPresets[i].emoji), style: const TextStyle(fontSize: 20))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(app.statusPresets[i].text, style: TextStyle(color: pal.text))),
                  if (custom != null && custom.text == app.statusPresets[i].text) Icon(Icons.check, size: 18, color: pal.accent),
                ]),
              ),
            if (custom != null)
              PopupMenuItem(
                value: -1,
                child: Row(children: [
                  Icon(Icons.close, size: 20, color: pal.sub),
                  const SizedBox(width: 16),
                  Text(tr('Xóa trạng thái'), style: TextStyle(color: pal.text)),
                ]),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: -2,
              child: Row(children: [
                Icon(Icons.tune, size: 20, color: pal.accentText),
                const SizedBox(width: 16),
                Text(tr('Quản lý trạng thái...'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
              ]),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            child: Row(children: [
              SizedBox(
                width: 24,
                child: custom != null && custom.emoji.isNotEmpty
                    ? Text(emojiOf(custom.emoji), style: const TextStyle(fontSize: 20))
                    : Icon(Icons.emoji_emotions_outlined, color: pal.text),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(tr('Trạng thái'), style: TextStyle(fontSize: 17, color: pal.text))),
              Flexible(
                child: Text(custom?.text ?? tr('Chưa đặt'),
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: pal.sub)),
              ),
              Icon(Icons.arrow_drop_down, color: pal.sub),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Hộp thoại thêm / sửa / xóa các trạng thái chọn nhanh (biểu tượng + chữ).
Future<void> showManageStatuses(BuildContext context) async {
  final app = context.read<AppState>();
  final items = [for (final p in app.statusPresets) (emoji: p.emoji, ctl: TextEditingController(text: p.text))];
  final saved = await showDialog<bool>(
    context: context,
    builder: (d) => StatefulBuilder(builder: (d, set) {
      final pal = Pal.of(d);
      return AlertDialog(
        title: Text(tr('Quản lý trạng thái')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (var i = 0; i < items.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Tooltip(
                        message: tr('Chọn biểu tượng'),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () async {
                            final e = await showEmojiPicker(d);
                            if (e != null) set(() => items[i] = (emoji: e, ctl: items[i].ctl));
                          },
                          child: Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(10)),
                            child: items[i].emoji.isEmpty
                                ? Icon(Icons.add_reaction_outlined, color: pal.sub)
                                : Text(emojiOf(items[i].emoji), style: const TextStyle(fontSize: 22)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: items[i].ctl,
                          decoration: InputDecoration(hintText: tr('Nội dung trạng thái'), isDense: true),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Xóa'),
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        onPressed: () => set(() => items.removeAt(i)),
                      ),
                    ]),
                  ),
              ]),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: pal.accentText),
                onPressed: () => set(() => items.add((emoji: 'speech_balloon', ctl: TextEditingController()))),
                icon: const Icon(Icons.add),
                label: Text(tr('Thêm trạng thái')),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Lưu'))),
        ],
      );
    }),
  );
  if (saved == true) {
    final list = [
      for (final it in items)
        if (it.ctl.text.trim().isNotEmpty) (emoji: it.emoji, text: it.ctl.text.trim()),
    ];
    try {
      await app.saveStatusPresets(list);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Không lưu được danh sách trạng thái.'))));
      }
    }
  }
}
