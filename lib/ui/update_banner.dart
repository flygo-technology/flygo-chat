import '../i18n/i18n.dart';
import 'package:flutter/material.dart';

import '../update/updater.dart';
import 'theme.dart';

/// Dải "Có bản mới · Cập nhật" phía trên danh sách chat (Android, máy tính).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: Updater.available,
      builder: (_, u, _) => u == null
          ? const SizedBox.shrink()
          : ValueListenableBuilder<double?>(
              valueListenable: Updater.progress,
              builder: (_, p, _) => Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                decoration: BoxDecoration(color: pal.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Icon(Icons.system_update, color: pal.accentText, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(tr('Có bản mới {0}', [u.label]),
                          style: TextStyle(color: pal.text, fontWeight: FontWeight.w600, fontSize: 14)),
                      if (p != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: LinearProgressIndicator(value: p, color: pal.accent, backgroundColor: pal.surface2),
                        )
                      else if (u.notes.isNotEmpty)
                        Text(u.notes, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 12.5)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: pal.accent,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: p != null
                        ? null
                        : () => Updater.install().catchError((_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(tr('Không tải được bản cập nhật. Kiểm tra kết nối mạng.'))));
                              }
                            }),
                    child: Text(p != null ? '${(p * 100).round()}%' : tr('Cập nhật')),
                  ),
                ]),
              ),
            ),
    );
  }
}
