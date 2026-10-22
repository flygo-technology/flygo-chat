import '../i18n/i18n.dart';
import 'package:flutter/material.dart';

import '../data/servers.dart';
import 'theme.dart';

/// Nút hiện tên máy chủ đang dùng; bấm vào thả danh sách máy chủ.
class ServerSelectButton extends StatelessWidget {
  final void Function(String url) onSelected;
  const ServerSelectButton({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final cur = ServerList.currentEntry;
    return Center(
      child: Material(
        color: pal.surface,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () async {
            final url = await showServerPicker(context);
            if (url != null) onSelected(url);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.dns_outlined, size: 18, color: pal.accentText),
              const SizedBox(width: 8),
              Text(cur.name, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(width: 6),
              Text(cur.host, style: TextStyle(color: pal.sub, fontSize: 13)),
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down_rounded, color: pal.sub),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Tiêu đề danh sách chat: tên máy chủ đang dùng, bấm để chọn máy chủ khác.
class ServerTitle extends StatelessWidget {
  final void Function(String url) onSelected;
  const ServerTitle({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final url = await showServerPicker(context);
          if (url != null) onSelected(url);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(ServerList.currentEntry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, color: pal.sub),
          ]),
        ),
      ),
    );
  }
}

/// Giá trị [showServerPicker] trả về khi bấm "Thêm máy chủ mới": mở màn đăng nhập (nhập email, tự tìm máy chủ).
const kAddServer = 'add-server:';

/// Danh sách máy chủ + "Thêm máy chủ mới". Trả về địa chỉ được chọn, hoặc [kAddServer].
Future<String?> showServerPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      return SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(tr('Máy chủ'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            for (final e in ServerList.items)
              ListTile(
                leading: Icon(Icons.dns_outlined, color: pal.accentText),
                title: Text(e.name, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                subtitle: Text(e.host, style: TextStyle(color: pal.sub)),
                // Dấu tích và nút xoá cùng một ô cố định 48×48 để thẳng hàng.
                trailing: SizedBox(
                  width: 48,
                  height: 48,
                  child: e.url == ServerList.current
                      ? Center(child: Icon(Icons.check_circle, color: pal.accent, size: 24))
                      : IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: tr('Bỏ máy chủ này'),
                          icon: Icon(Icons.close, color: pal.sub, size: 22),
                          onPressed: e.url == ServerList.items.first.url
                              ? null
                              : () async {
                                  await ServerList.remove(e.url);
                                  setSheet(() {});
                                },
                        ),
                ),
                onTap: () => Navigator.pop(ctx, e.url),
              ),
            Divider(color: pal.divider, height: 1),
            // Nút thêm máy chủ căn giữa.
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Center(
                child: TextButton.icon(
                  icon: Icon(Icons.add_circle_outline, color: pal.accentText),
                  label: Text(tr('Thêm máy chủ mới'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600, fontSize: 15)),
                  onPressed: () => Navigator.pop(ctx, kAddServer),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );
    },
  );
}
