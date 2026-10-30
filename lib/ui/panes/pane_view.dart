import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../theme.dart';
import 'pane_layout.dart';

/// Tên và hình đại diện của một nội dung ô (đầu ô, hình kéo theo chuột).
class PaneLabel {
  final String title;
  final Widget leading;
  const PaneLabel(this.title, this.leading);
}

/// Thứ đang được kéo: nội dung (chat / mục thanh tab), [fromPane] = id ô khi kéo đầu một ô.
class PaneDragData {
  final PaneContent content;
  final String? fromPane;
  const PaneDragData(this.content, {this.fromPane});
}

/// Màn hình chia ô (máy tính / máy tính bảng ngang) đang bật: các danh sách cho phép kéo chat / mục vào vùng nội dung.
class PaneHost extends InheritedWidget {
  final PaneLabel Function(PaneContent c) describe;
  /// Kéo thả ra ngoài cửa sổ thì mở cửa sổ riêng (chỉ máy tính).
  final bool canPopOut;
  final void Function(PaneDragData d) popOut;
  const PaneHost({super.key, required this.describe, required this.canPopOut, required this.popOut, required super.child});

  static PaneHost? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PaneHost>();

  @override
  bool updateShouldNotify(PaneHost old) => canPopOut != old.canPopOut;
}

/// Bọc một dòng (chat, phiên trợ lý, mục thanh tab, đầu ô) để kéo được vào vùng chia ô. Không có [PaneHost] (điện
/// thoại) thì giữ nguyên. Máy tính kéo bằng chuột theo mọi hướng; máy tính bảng chỉ kéo ngang (dọc để cuộn danh sách).
class PaneDragSource extends StatefulWidget {
  final PaneContent content;
  final String? fromPane;
  final Widget child;
  const PaneDragSource({super.key, required this.content, this.fromPane, required this.child});
  @override
  State<PaneDragSource> createState() => _PaneDragSourceState();
}

class _PaneDragSourceState extends State<PaneDragSource> {
  Offset? _last;
  Size? _window;

  @override
  Widget build(BuildContext context) {
    final host = PaneHost.maybeOf(context);
    if (host == null) return widget.child;
    final data = PaneDragData(widget.content, fromPane: widget.fromPane);
    return Draggable<PaneDragData>(
      data: data,
      rootOverlay: true,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      affinity: isDesktop ? null : Axis.horizontal,
      feedback: _DragFeedback(describe: host.describe, content: widget.content),
      onDragStarted: () {
        _window = MediaQuery.sizeOf(context);
        HapticFeedback.selectionClick();
      },
      onDragUpdate: (d) => _last = d.globalPosition,
      // Thả ra ngoài cửa sổ app (không trúng ô nào): mở cửa sổ riêng.
      onDraggableCanceled: (_, _) {
        final p = _last, w = _window;
        if (!host.canPopOut || p == null || w == null) return;
        if (p.dx < 0 || p.dy < 0 || p.dx > w.width || p.dy > w.height) host.popOut(data);
      },
      childWhenDragging: Opacity(opacity: .45, child: widget.child),
      child: widget.child,
    );
  }
}

/// Hình kéo theo chuột: tên + ảnh của nội dung (chỉ dựng khi đang kéo).
class _DragFeedback extends StatelessWidget {
  final PaneLabel Function(PaneContent c) describe;
  final PaneContent content;
  const _DragFeedback({required this.describe, required this.content});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final label = describe(content);
    return Transform.translate(
      offset: const Offset(14, 10),
      child: Material(
        elevation: 8,
        color: pal.surface,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 24, height: 24, child: Center(child: label.leading)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: pal.text)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Vùng nội dung chia ô: dựng cây [PaneLayout], thanh chia kéo được, vùng thả kiểu VS Code khi kéo (trái / phải /
/// trên / dưới để chia, giữa để thay), đầu ô (tên, chấm chưa đọc, phóng to, tách cửa sổ, đóng) khi có từ hai ô.
class PaneArea extends StatelessWidget {
  final PaneLayout layout;
  /// Khoá của từng ô (theo id ô): chuyển ô sang chỗ khác trong cây vẫn giữ nguyên trạng thái (ô nhắn tin, cuộn…).
  final GlobalKey Function(String paneId) keyOf;
  final Widget Function(BuildContext context, PaneLeaf leaf) body;
  final PaneLabel Function(PaneContent c) describe;
  final bool Function(PaneLeaf leaf) unread;
  final void Function(String paneId) onFocus;
  final void Function(String targetId, PaneEdge edge, PaneDragData d) onDrop;
  final void Function(String paneId) onClose;
  final void Function(String paneId) onMaximize;
  final void Function(String paneId)? onPopOut;
  final void Function(String splitId, double ratio) onRatio;
  final VoidCallback onRatioEnd;

  const PaneArea({
    super.key,
    required this.layout,
    required this.keyOf,
    required this.body,
    required this.describe,
    required this.unread,
    required this.onFocus,
    required this.onDrop,
    required this.onClose,
    required this.onMaximize,
    this.onPopOut,
    required this.onRatio,
    required this.onRatioEnd,
  });

  Widget _leaf(PaneLeaf l, bool multi) => KeyedSubtree(
        key: keyOf(l.id),
        child: _PaneFrame(area: this, leaf: l, multi: multi),
      );

  Widget _node(PaneNode n, bool multi) => switch (n) {
        PaneLeaf l => _leaf(l, multi),
        PaneSplit s => _SplitBox(split: s, first: _node(s.first, multi), second: _node(s.second, multi), area: this),
      };

  @override
  Widget build(BuildContext context) {
    final multi = layout.isMulti;
    final max = multi ? layout.maximizedId : null;
    if (max != null) {
      // Phóng to một ô: các ô khác vẫn dựng (ẩn) để giữ trạng thái.
      return Stack(fit: StackFit.expand, children: [
        for (final l in layout.leaves)
          if (l.id != max) Offstage(child: _leaf(l, multi)),
        for (final l in layout.leaves)
          if (l.id == max) _leaf(l, multi),
      ]);
    }
    return _node(layout.root, multi);
  }
}

class _SplitBox extends StatelessWidget {
  final PaneSplit split;
  final Widget first, second;
  final PaneArea area;
  const _SplitBox({required this.split, required this.first, required this.second, required this.area});

  static const _handle = 6.0;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final h = split.horizontal;
    return LayoutBuilder(builder: (context, box) {
      final total = (h ? box.maxWidth : box.maxHeight) - _handle;
      final a = (total * split.ratio).clamp(0.0, total < 0 ? 0.0 : total);
      return Flex(direction: h ? Axis.horizontal : Axis.vertical, children: [
        SizedBox(width: h ? a : null, height: h ? null : a, child: first),
        MouseRegion(
          cursor: h ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: total <= 0 ? null : (d) => area.onRatio(split.id, split.ratio + (h ? d.delta.dx : d.delta.dy) / total),
            onPanEnd: (_) => area.onRatioEnd(),
            // Bấm đúp: chia đều.
            onDoubleTap: () {
              area.onRatio(split.id, .5);
              area.onRatioEnd();
            },
            child: SizedBox(
              width: h ? _handle : null,
              height: h ? null : _handle,
              child: Center(child: h ? VerticalDivider(width: 1, color: pal.divider) : Divider(height: 1, color: pal.divider)),
            ),
          ),
        ),
        Expanded(child: second),
      ]);
    });
  }
}

class _PaneFrame extends StatefulWidget {
  final PaneArea area;
  final PaneLeaf leaf;
  final bool multi;
  const _PaneFrame({required this.area, required this.leaf, required this.multi});
  @override
  State<_PaneFrame> createState() => _PaneFrameState();
}

class _PaneFrameState extends State<_PaneFrame> {
  PaneEdge? _zone;

  /// Chỗ thả theo vị trí chuột trong ô: giữa ô = thay nội dung, gần cạnh nào thì chia về cạnh đó.
  PaneEdge _zoneAt(Offset global, PaneDragData d) {
    final box = context.findRenderObject() as RenderBox?;
    final layout = widget.area.layout;
    final canSplit = widget.leaf.content != null && layout.canSplitWith(d.content, fromPane: d.fromPane);
    if (box == null || !box.hasSize || !canSplit) return PaneEdge.center;
    final p = box.globalToLocal(global);
    final rx = (p.dx / box.size.width).clamp(0.0, 1.0), ry = (p.dy / box.size.height).clamp(0.0, 1.0);
    if (rx > .3 && rx < .7 && ry > .3 && ry < .7) return PaneEdge.center;
    final edges = {PaneEdge.left: rx, PaneEdge.right: 1 - rx, PaneEdge.top: ry, PaneEdge.bottom: 1 - ry};
    return edges.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  }

  void _setZone(PaneEdge? z) {
    if (z != _zone) setState(() => _zone = z);
  }

  Widget _overlay(Pal pal) {
    final z = _zone!;
    final half = z != PaneEdge.center;
    final box = Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: pal.accent.withValues(alpha: .16),
        border: Border.all(color: pal.accent, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Icon(
          switch (z) {
            PaneEdge.center => Icons.swap_horiz_rounded,
            PaneEdge.left || PaneEdge.right => Icons.vertical_split_outlined,
            PaneEdge.top || PaneEdge.bottom => Icons.horizontal_split_outlined,
          },
          size: 34,
          color: pal.accent.withValues(alpha: .8),
        ),
      ),
    );
    if (!half) return box;
    return Align(
      alignment: switch (z) {
        PaneEdge.left => Alignment.centerLeft,
        PaneEdge.right => Alignment.centerRight,
        PaneEdge.top => Alignment.topCenter,
        _ => Alignment.bottomCenter,
      },
      child: FractionallySizedBox(
        widthFactor: z == PaneEdge.left || z == PaneEdge.right ? .5 : 1,
        heightFactor: z == PaneEdge.top || z == PaneEdge.bottom ? .5 : 1,
        child: box,
      ),
    );
  }

  Widget _header(Pal pal, bool focused, bool unread) {
    final a = widget.area;
    final l = widget.leaf;
    final c = l.content;
    final label = c == null ? PaneLabel(tr('Ô trống'), Icon(Icons.crop_square_rounded, size: 18, color: pal.sub)) : a.describe(c);
    final maximized = a.layout.maximizedId == l.id;
    Widget btn(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, size: 17, color: pal.sub),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        );
    final row = Container(
      height: 34,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: focused ? pal.accent.withValues(alpha: .10) : pal.surface,
        border: Border(bottom: BorderSide(color: pal.divider, width: .6)),
      ),
      child: Row(children: [
        SizedBox(width: 22, height: 22, child: Center(child: label.leading)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, fontWeight: unread ? FontWeight.w700 : FontWeight.w600, color: pal.text)),
        ),
        if (unread)
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
          ),
        btn(maximized ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, maximized ? tr('Thu nhỏ ô') : tr('Phóng to ô'),
            () => a.onMaximize(l.id)),
        if (a.onPopOut != null && c != null) btn(Icons.open_in_new_rounded, tr('Mở trong cửa sổ riêng'), () => a.onPopOut!(l.id)),
        btn(Icons.close_rounded, tr('Đóng ô'), () => a.onClose(l.id)),
      ]),
    );
    if (c == null) return row;
    // Kéo đầu ô để đổi chỗ / chuyển ô (thả ra ngoài cửa sổ: tách cửa sổ riêng).
    return MouseRegion(cursor: SystemMouseCursors.grab, child: PaneDragSource(content: c, fromPane: l.id, child: row));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final a = widget.area;
    final l = widget.leaf;
    final multi = widget.multi;
    final focused = multi && a.layout.focusedId == l.id;
    final unread = multi && !focused && a.unread(l);
    final content = Column(children: [
      if (multi) _header(pal, focused, unread),
      Expanded(child: a.body(context, l)),
    ]);
    // Cùng một dãy widget cho một ô hay nhiều ô (chỉ đổi tham số): đổi kiểu widget bọc ngoài sẽ dựng lại cả nội dung
    // (mất chữ đang gõ, vị trí cuộn) khi chia thêm ô.
    final radius = BorderRadius.circular(multi ? 8 : 0);
    final framed = Padding(
      padding: EdgeInsets.all(multi ? 2 : 0),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: !multi
            ? const BoxDecoration()
            : BoxDecoration(
                border: Border.all(
                  color: focused ? pal.accent : (unread ? pal.accent.withValues(alpha: .45) : pal.divider),
                  width: focused || unread ? 1.5 : 1,
                ),
                borderRadius: radius,
              ),
        child: ClipRRect(borderRadius: radius, child: content),
      ),
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => a.onFocus(l.id),
      child: DragTarget<PaneDragData>(
        onWillAcceptWithDetails: (d) => d.data.fromPane != l.id,
        onMove: (d) {
          if (d.data.fromPane != l.id) _setZone(_zoneAt(d.offset, d.data));
        },
        onLeave: (_) => _setZone(null),
        onAcceptWithDetails: (d) {
          final z = _zoneAt(d.offset, d.data);
          _setZone(null);
          a.onDrop(l.id, z, d.data);
        },
        builder: (context, _, _) => Stack(children: [
          Positioned.fill(child: framed),
          if (_zone != null) Positioned.fill(child: IgnorePointer(child: _overlay(pal))),
        ]),
      ),
    );
  }
}

/// Ctrl/Cmd+K: tìm nhanh một cuộc trò chuyện theo tên rồi mở ở ô đang chọn. Trả về id kênh.
Future<String?> showQuickSwitcher(BuildContext context) =>
    showDialog<String>(context: context, builder: (_) => const _QuickSwitcher());

class _QuickSwitcher extends StatefulWidget {
  const _QuickSwitcher();
  @override
  State<_QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends State<_QuickSwitcher> {
  String _q = '';
  int _index = 0;
  final _scroll = ScrollController();

  /// Bỏ dấu tiếng Việt + chữ thường ("dang" khớp "Đang").
  static String _fold(String s) {
    const a = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
    const b = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
    final out = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = a.indexOf(ch);
      out.write(i < 0 ? ch : b[i]);
    }
    return out.toString();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _move(int d, int n) {
    if (n == 0) return;
    setState(() => _index = (_index + d + n) % n);
    const row = 56.0;
    if (_scroll.hasClients) {
      final top = _index * row;
      final pos = _scroll.position;
      if (top < pos.pixels) _scroll.jumpTo(top);
      if (top + row > pos.pixels + pos.viewportDimension) _scroll.jumpTo(top + row - pos.viewportDimension);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final q = _fold(_q.trim());
    final chats = app.chats.where((c) => q.isEmpty || _fold(c.title).contains(q)).take(60).toList();
    if (_index >= chats.length) _index = 0;
    return Dialog(
      backgroundColor: pal.surface,
      alignment: const Alignment(0, -.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, chats.length),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, chats.length),
            const SingleActivator(LogicalKeyboardKey.enter): () {
              if (chats.isNotEmpty) Navigator.pop(context, chats[_index].channel.id);
            },
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() {
                  _q = v;
                  _index = 0;
                }),
                onSubmitted: (_) {
                  if (chats.isNotEmpty) Navigator.pop(context, chats[_index].channel.id);
                },
                style: TextStyle(color: pal.text, fontSize: 16),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: pal.bg,
                  hintText: tr('Chuyển nhanh tới cuộc trò chuyện…'),
                  hintStyle: TextStyle(color: pal.sub),
                  prefixIcon: Icon(Icons.search, color: pal.sub, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            Flexible(
              child: chats.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(tr('Không có cuộc trò chuyện nào phù hợp'), style: TextStyle(color: pal.sub)),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      shrinkWrap: true,
                      itemExtent: 56,
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: chats.length,
                      itemBuilder: (_, i) {
                        final c = chats[i];
                        final sel = i == _index;
                        return InkWell(
                          onTap: () => Navigator.pop(context, c.channel.id),
                          child: Container(
                            color: sel ? pal.accent.withValues(alpha: .14) : Colors.transparent,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(children: [
                              Avatar(
                                userId: c.avatarUserId,
                                name: c.title,
                                size: 36,
                                status: false,
                                icon: c.avatarUserId == null ? chatIcon(c.channel) : null,
                                channel: c.channel,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(c.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15, color: pal.text, fontWeight: c.unread > 0 ? FontWeight.w700 : FontWeight.w500)),
                              ),
                              if (c.unread > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(12)),
                                  child: Text(c.unread > 99 ? '99+' : '${c.unread}',
                                      style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                                ),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
