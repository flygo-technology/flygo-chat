import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Popover nổi sát ngay phía trên nút [anchor], căn giữa theo nút (sát mép màn hình thì tự lùi vào trong).
/// Bấm ra ngoài để đóng. Nội dung có thể là các PopupMenuItem: bấm một mục thì popover đóng và trả về giá trị của mục.
Future<T?> showPopoverAbove<T>(BuildContext anchor, {required WidgetBuilder builder, double width = 340}) {
  final box = anchor.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return Navigator.of(anchor, rootNavigator: true).push<T>(_PopoverRoute<T>(anchor: rect, width: width, builder: builder));
}

class _PopoverRoute<T> extends PopupRoute<T> {
  final Rect anchor;
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
    return CustomSingleChildLayout(
      delegate: _AboveLayout(anchor, top, width),
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
    );
  }
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
