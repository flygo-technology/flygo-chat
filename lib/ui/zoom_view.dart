import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Xem ảnh trên máy tính: vuốt / cuộn chuột (hoặc vuốt hai ngón trên bàn di chuột) để phóng to thu nhỏ quanh con trỏ,
/// chụm hai ngón cũng phóng to thu nhỏ, kéo chuột để di chuyển ảnh. Vuốt lên là phóng to (InteractiveViewer làm
/// ngược chiều và không đổi được chiều một cách an toàn). Dùng chung [controller] với nút bấm đúp phóng to.
class ZoomPanView extends StatefulWidget {
  /// null: tự tạo (không cần điều khiển từ ngoài).
  final TransformationController? controller;
  final double maxScale;
  final Widget child;
  const ZoomPanView({super.key, this.controller, this.maxScale = 10, required this.child});
  @override
  State<ZoomPanView> createState() => _ZoomPanViewState();
}

class _ZoomPanViewState extends State<ZoomPanView> {
  double _lastScale = 1;
  late final _own = TransformationController();

  TransformationController get _ctl => widget.controller ?? _own;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  /// Phóng to / thu nhỏ [factor] lần quanh điểm [focal] (toạ độ trong khung), giữ trong khoảng 1…maxScale.
  void _zoom(double factor, Offset focal) {
    final cur = _ctl.value.getMaxScaleOnAxis();
    final next = (cur * factor).clamp(1.0, widget.maxScale);
    if (next <= 1.001) {
      _ctl.value = Matrix4.identity();
      return;
    }
    final s = next / cur;
    final m = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _ctl.value = m.multiplied(_ctl.value);
  }

  void _pan(Offset delta) {
    if (_ctl.value.getMaxScaleOnAxis() <= 1.001) return;
    _ctl.value = (Matrix4.identity()..translateByDouble(delta.dx, delta.dy, 0, 1)).multiplied(_ctl.value);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
          // Nhận sự kiện cuộn trước PageView bên ngoài (không lật trang khi đang cuộn để phóng to).
          GestureBinding.instance.pointerSignalResolver.register(e, (_) => _zoom(math.exp(e.scrollDelta.dy / 200), e.localPosition));
        },
        onPointerPanZoomStart: (_) => _lastScale = 1,
        onPointerPanZoomUpdate: (e) {
          final pinch = e.scale / _lastScale;
          _lastScale = e.scale;
          _zoom(pinch * math.exp(e.panDelta.dy / 200), e.localPosition);
        },
        child: GestureDetector(
          onPanUpdate: (d) => _pan(d.delta),
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _ctl,
              builder: (_, child) => Transform(transform: _ctl.value, child: child),
              child: widget.child,
            ),
          ),
        ),
      );
}
