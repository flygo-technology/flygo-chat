import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/screen_grab.dart';

/// Ảnh thử 400x300: nửa trái đỏ, nửa phải xanh.
Future<ui.Image> _testImage() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 200, 300), Paint()..color = const Color(0xFFFF0000));
  c.drawRect(const Rect.fromLTWH(200, 0, 200, 300), Paint()..color = const Color(0xFF0000FF));
  return rec.endRecording().toImage(400, 300);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Thư mục tạm cho ảnh lưu ra.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), (_) async => Directory.systemTemp.path);

  Future<String?> run(WidgetTester tester, Future<void> Function() act) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final image = (await tester.runAsync(_testImage))!;
    String? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await Navigator.of(ctx).push<String>(MaterialPageRoute(builder: (_) => ScreenshotOverlay(image: image)));
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await act();
    for (var i = 0; i < 50 && !done; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('chọn vùng rồi Enter: lưu PNG đúng vùng, đủ độ phân giải ảnh gốc', (tester) async {
    final path = await run(tester, () async {
      // Ảnh 400x300 hiện phóng to x2 trên lớp phủ 800x600: kéo (100,100) → (500,300) = vùng ảnh (50,50)-(250,150).
      await tester.dragFrom(const Offset(100, 100), const Offset(400, 200));
      await tester.pump();
      expect(find.text('400 × 200'), findsNothing);
      expect(find.text('200 × 100'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    });
    expect(path, isNotNull);
    final bytes = File(path!).readAsBytesSync();
    final img = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    }))!;
    expect((img.width, img.height), (200, 100));
    final px = (await tester.runAsync(() => img.toByteData()))!;
    // Góc trái đỏ, góc phải xanh.
    expect(px.getUint8(0), 255);
    expect(px.getUint8(2), 0);
    final right = (img.width - 1) * 4;
    expect(px.getUint8(right), 0);
    expect(px.getUint8(right + 2), 255);
    File(path).deleteSync();
  });

  testWidgets('vẽ khung lên vùng chọn: nét vẽ có trong ảnh lưu ra', (tester) async {
    final path = await run(tester, () async {
      await tester.dragFrom(const Offset(100, 100), const Offset(600, 400));
      await tester.pump();
      await tester.tap(find.byTooltip('Hình chữ nhật'));
      await tester.pump();
      // Khung trên nửa xanh: cạnh trái ở x=520 trên lớp phủ = x 210 trong ảnh cắt (300x200).
      await tester.dragFrom(const Offset(520, 140), const Offset(60, 120));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    });
    expect(path, isNotNull);
    final bytes = File(path!).readAsBytesSync();
    final img = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    }))!;
    expect((img.width, img.height), (300, 200));
    final px = (await tester.runAsync(() => img.toByteData()))!;
    final stroke = (50 * img.width + 210) * 4;
    // Nét đỏ dày 1,5 điểm ảnh (khử răng cưa): đỏ trội hơn xanh.
    expect(px.getUint8(stroke), greaterThan(120));
    expect(px.getUint8(stroke), greaterThan(px.getUint8(stroke + 2)));
    final inside = (50 * img.width + 225) * 4;
    expect(px.getUint8(inside + 2), 255); // trong khung vẫn xanh
    File(path).deleteSync();
  });

  testWidgets('Esc: hủy, không trả ảnh', (tester) async {
    final path = await run(tester, () async {
      await tester.dragFrom(const Offset(100, 100), const Offset(200, 200));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    });
    expect(path, isNull);
  });
}
