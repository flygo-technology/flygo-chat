// Ảnh xem trước các giao diện chat (chạy tay): THEME_OUT=<thư mục> flutter test test/chat_themes_preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/chat_themes.dart';
import 'package:flygo_chat/ui/theme.dart';

Widget _cell(ChatTheme t, bool dark) {
  final c = t.colors(dark);
  final p = t.apply(dark ? Pal.dark : Pal.light, dark);
  Widget bubble(String text, Color bg, bool out) => Align(
        alignment: out ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(text, style: TextStyle(color: c.fg, fontSize: 13)),
            Text('09:41', style: TextStyle(color: p.sub, fontSize: 10)),
          ]),
        ),
      );
  return Container(
    width: 230,
    height: 150,
    color: c.bg,
    padding: const EdgeInsets.all(8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${t.id} · ${dark ? 'đêm' : 'ngày'}', style: TextStyle(color: p.sub, fontSize: 11, fontWeight: FontWeight.w700)),
      bubble('Chào cả nhà, họp lúc 9h nhé', c.inBubble, false),
      bubble('Ok, em vào ngay', c.outBubble, true),
      Text('Hôm nay', style: TextStyle(color: p.sub, fontSize: 11)),
    ]),
  );
}

void main() {
  testWidgets('ảnh xem trước giao diện chat', (tester) async {
    final out = Platform.environment['THEME_OUT'];
    if (out == null) return;
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1900, 3200);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: key,
        child: Container(
          color: Colors.grey,
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            for (final t in chatThemes) ...[_cell(t, false), _cell(t, true)],
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/themes.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}
