import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart' show kBoardsNarrow;
import 'kanban_view.dart' show BoardCardTile;

/// View Thư viện: lưới thẻ có ảnh bìa (ảnh đầu tiên trong nội dung thẻ).
class GalleryView extends StatelessWidget {
  final BoardStore store;
  final BoardView view;
  final List<TaskCard> cards;
  final String? selectedId;
  final ValueChanged<TaskCard> onOpen;
  final VoidCallback onAdd;
  const GalleryView(
      {super.key, required this.store, required this.view, required this.cards, required this.onOpen, required this.onAdd, this.selectedId});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.read<AppState>();
    return LayoutBuilder(builder: (context, box) {
      // Điện thoại: 2 cột (máy rất hẹp 1 cột); màn rộng: mỗi cột ~240px.
      final cols = box.maxWidth < kBoardsNarrow ? (box.maxWidth >= 340 ? 2 : 1) : (box.maxWidth / 240).floor().clamp(1, 8);
      final w = (box.maxWidth - 16 - (cols - 1) * 10) / cols;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          for (final c in cards)
            SizedBox(
              width: w,
              child: BoardCardTile(
                store: store,
                view: view,
                card: c,
                selected: c.id == selectedId,
                onTap: () => onOpen(c),
                cover: _cover(context, pal, app, c),
              ),
            ),
          if (store.canEdit)
            SizedBox(
              width: w,
              height: 120,
              child: OutlinedButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: Text(tr('Thêm thẻ'))),
            ),
        ]),
      );
    });
  }

  Widget _cover(BuildContext context, Pal pal, AppState app, TaskCard c) {
    final id = store.coverFileId(c);
    if (id == null) {
      // Không có ảnh: vài dòng đầu của nội dung chữ, như bản web.
      final text = store.contentOf(c).where((b) => b.type == 'text').map((b) => b.title).join('\n');
      return Container(
        height: 110,
        color: pal.surface2.withValues(alpha: .5),
        padding: const EdgeInsets.all(10),
        child: Text(text, maxLines: 5, overflow: TextOverflow.fade, style: TextStyle(fontSize: 12, color: pal.sub)),
      );
    }
    return SizedBox(
      height: 140,
      child: Image.network(store.api.fileUrl(store.teamId, store.boardId, id),
          headers: app.api.headers,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(color: pal.surface2, child: Icon(Icons.broken_image_outlined, color: pal.sub))),
    );
  }
}
