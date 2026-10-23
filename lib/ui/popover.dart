import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Popover nổi sát ngay phía trên nút [anchor], căn giữa theo nút (sát mép màn hình thì tự lùi vào trong).
/// Bấm ra ngoài để đóng. Nội dung có thể là các PopupMenuItem: bấm một mục thì popover đóng và trả về giá trị của mục.
Future<T?> showPopoverAbove<T>(BuildContext anchor, {required WidgetBuilder builder, double width = 340}) {
  final box = anchor.findRenderObject() as RenderBox;
  return Navigator.of(anchor, rootNavigator: true).push<T>(_PopoverRoute<T>(anchor: box, width: width, builder: builder));
}

/// Vị trí nút trên màn hình lúc này. Nút có thể dời chỗ khi popover đang mở (bấm nút lúc đang soạn tin: bàn phím
/// đóng lại, thanh soạn tin tụt xuống), nên popover đọc lại vị trí mỗi khung hình thay vì giữ vị trí lúc bấm.
Rect? _rectOf(RenderBox box) => box.attached && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;

class _PopoverRoute<T> extends PopupRoute<T> {
  final RenderBox anchor;
  final double width;
  final WidgetBuilder builder;
  _PopoverRoute({required this.anchor, required this.width, required this.builder});

  @override
  Color? get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'popover';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final pal = Pal.of(context);
    final top = MediaQuery.paddingOf(context).top + 8;
    return _FollowAnchor(
      anchor: anchor,
      builder: (rect) => CustomSingleChildLayout(
        delegate: _AboveLayout(rect, top, width),
        child: FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: .96, end: 1.0).animate(animation),
            alignment: Alignment.bottomCenter,
            child: Material(
              color: pal.surface,
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: builder(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dựng lại popover mỗi khi nút đổi vị trí (kiểm tra từng khung hình trong lúc popover mở).
class _FollowAnchor extends StatefulWidget {
  final RenderBox anchor;
  final Widget Function(Rect anchor) builder;
  const _FollowAnchor({required this.anchor, required this.builder});
  @override
  State<_FollowAnchor> createState() => _FollowAnchorState();
}

class _FollowAnchorState extends State<_FollowAnchor> with SingleTickerProviderStateMixin {
  late Rect _rect = _rectOf(widget.anchor) ?? Rect.zero;
  late final _ticker = createTicker((_) {
    final r = _rectOf(widget.anchor);
    if (r != null && r != _rect) setState(() => _rect = r);
  })..start();

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_rect);
}

class _AboveLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final double top;
  final double width;
  _AboveLayout(this.anchor, this.top, this.width);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final w = min(width, c.maxWidth - 24);
    return BoxConstraints(minWidth: w, maxWidth: w, maxHeight: max(80, anchor.top - 8 - top));
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (anchor.center.dx - child.width / 2).clamp(12.0, max(12.0, size.width - child.width - 12)).toDouble();
    return Offset(x, max(top, anchor.top - 8 - child.height));
  }

  @override
  bool shouldRelayout(_AboveLayout old) => old.anchor != anchor || old.top != top || old.width != width;
}

/// Các mục kiểu menu (PopupMenuItem, PopupMenuDivider…) xếp dọc trong [showPopoverAbove], cuộn được khi dài.
class PopoverItems extends StatelessWidget {
  final List<Widget> items;
  const PopoverItems(this.items, {super.key});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: items),
      );
}
