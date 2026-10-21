import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/chat_themes.dart';
import 'package:flygo_chat/ui/theme.dart';

/// Tỉ lệ tương phản WCAG 2.x giữa hai màu.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (max(la, lb) + .05) / (min(la, lb) + .05);
}

void main() {
  test('mọi giao diện chat đủ tương phản ở cả chế độ ngày và đêm', () {
    final bad = <String>[];
    for (final t in chatThemes) {
      for (final dark in [false, true]) {
        final c = t.colors(dark);
        final p = t.apply(dark ? Pal.dark : Pal.light, dark);
        final mode = dark ? 'đêm' : 'ngày';
        void need(String what, Color x, Color y, double min) {
          final r = contrast(x, y);
          if (r < min) bad.add('${t.id}/$mode $what ${r.toStringAsFixed(2)} < $min');
        }
        need('chữ/nền', c.fg, c.bg, 7);
        need('chữ/bong bóng vào', c.fg, c.inBubble, 7);
        need('chữ/bong bóng ra', c.fg, c.outBubble, 4.5);
        need('chữ phụ/nền', p.sub, c.bg, 3);
        need('chữ phụ/bong bóng vào', p.sub, c.inBubble, 3);
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });
}
