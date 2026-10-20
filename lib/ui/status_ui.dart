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
  /// Không nền (trang Apps): chỉ hai dòng Hoạt động / Trạng thái trên nền trang.
  final bool plain;
  const StatusSection({super.key, this.plain = false});

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
          ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không đổi được trạng thái.'))));
        }
      });
    }
  }

  /// Chọn trạng thái (biểu tượng + chữ): bảng dưới giống chọn hoạt động.
  Future<void> _pickCustom(BuildContext context, AppState app) async {
    final custom = app.customStatusOf(app.me!.id);
    final v = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        final pal = Pal.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .75),
            child: ListView(shrinkWrap: true, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(tr('Trạng thái'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              for (var i = 0; i < app.statusPresets.length; i++)
                ListTile(
                  leading: SizedBox(
                      width: 28, child: Center(child: Text(emojiOf(app.statusPresets[i].emoji), style: const TextStyle(fontSize: 20)))),
                  title: Text(app.statusPresets[i].text, style: TextStyle(color: pal.text)),
                  trailing: custom != null && custom.text == app.statusPresets[i].text ? Icon(Icons.check_circle, color: pal.accent) : null,
                  onTap: () => Navigator.pop(ctx, i),
                ),
              if (custom != null)
                ListTile(
                  leading: SizedBox(width: 28, child: Icon(Icons.close, color: pal.sub)),
                  title: Text(tr('Xóa trạng thái'), style: TextStyle(color: pal.text)),
                  onTap: () => Navigator.pop(ctx, -1),
                ),
              Divider(height: 1, color: pal.divider),
              ListTile(
                leading: SizedBox(width: 28, child: Icon(Icons.tune, color: pal.accentText)),
                title: Text(tr('Quản lý trạng thái...'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx, -2),
              ),
              const SizedBox(height: 8),
            ]),
          ),
        );
      },
    );
    if (v == null || !context.mounted) return;
    if (v == -1) {
      app.clearCustomStatus().catchError((_) {});
    } else if (v == -2) {
      showManageStatuses(context);
    } else {
      final p = app.statusPresets[v];
      app.setCustomStatus(p.emoji, p.text).catchError((_) {});
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
      decoration: plain ? null : BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(22)),
      clipBehavior: plain ? Clip.none : Clip.antiAlias,
      child: Column(children: [
        InkWell(
          onTap: () => _pickAvailability(context, app),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: plain ? 8 : 15),
            child: plain
                // Trang Apps: căn giữa, gọn (chấm trạng thái + tên trạng thái).
                ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    statusDot(st, pal, size: 12),
                    const SizedBox(width: 8),
                    Text(availabilityLabel(st), style: TextStyle(fontSize: 16, color: pal.text)),
                    Icon(Icons.arrow_drop_down, color: pal.sub),
                  ])
                : Row(children: [
                    SizedBox(width: 24, child: Center(child: statusDot(st, pal, size: 14))),
                    const SizedBox(width: 16),
                    Expanded(child: Text(tr('Hoạt động'), style: TextStyle(fontSize: 17, color: pal.text))),
                    Text(availabilityLabel(st), style: TextStyle(fontSize: 16, color: pal.sub)),
                    Icon(Icons.chevron_right, color: pal.sub),
                  ]),
          ),
        ),
        if (!plain) Divider(height: 1, thickness: .6, indent: 56, color: pal.divider),
        InkWell(
          onTap: () => _pickCustom(context, app),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: plain ? 8 : 15),
            child: plain
                ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (custom != null && custom.emoji.isNotEmpty)
                      Text(emojiOf(custom.emoji), style: const TextStyle(fontSize: 18))
                    else
                      Icon(Icons.emoji_emotions_outlined, size: 20, color: pal.sub),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(custom?.text ?? tr('Đặt trạng thái'),
                          overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: custom == null ? pal.sub : pal.text)),
                    ),
                    Icon(Icons.arrow_drop_down, color: pal.sub),
                  ])
                : Row(children: [
              SizedBox(
                width: 24,
                child: custom != null && custom.emoji.isNotEmpty
                    ? Text(emojiOf(custom.emoji), style: const TextStyle(fontSize: 20))
                    : Icon(Icons.emoji_emotions_outlined, color: pal.text),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(tr('Trạng thái'), style: TextStyle(fontSize: 17, color: pal.text))),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .4),
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
        ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không lưu được danh sách trạng thái.'))));
      }
    }
  }
}
