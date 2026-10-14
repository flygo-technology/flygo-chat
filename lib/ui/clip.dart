import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

/// Ảnh / tệp trong bộ nhớ tạm (clipboard) của hệ điều hành: dán vào chat và sao chép ảnh.

/// Bộ nhớ tạm có ảnh hoặc tệp để dán không.
Future<bool> clipboardHasMedia() async {
  try {
    if (!Platform.isAndroid && !Platform.isIOS && (await Pasteboard.files()).isNotEmpty) return true;
    return await Pasteboard.image != null;
  } catch (_) {
    return false;
  }
}

/// Lấy ảnh / tệp đang có trong bộ nhớ tạm, lưu ra file tạm. Trả về (đường dẫn, tên).
Future<List<(String, String)>> readClipboardMedia() async {
  try {
    // Tệp được sao chép từ Finder / trình quản lý tệp (máy tính).
    if (!Platform.isAndroid && !Platform.isIOS) {
      final files = [
        for (final p in await Pasteboard.files())
          if (File(p).existsSync()) (p, p.split(Platform.pathSeparator).last),
      ];
      if (files.isNotEmpty) return files;
    }
    // Ảnh (chụp màn hình, sao chép ảnh từ trình duyệt...).
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) return const [];
    final dir = await getTemporaryDirectory();
    final name = 'paste_${DateTime.now().millisecondsSinceEpoch}.png';
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes);
    return [(f.path, name)];
  } catch (e) {
    debugPrint('[clip] read: $e');
    return const [];
  }
}

/// Sao chép ảnh vào bộ nhớ tạm (đổi sang PNG để mọi ứng dụng dán được).
Future<bool> copyImageToClipboard(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return false;
    await Pasteboard.writeImage(png.buffer.asUint8List());
    return true;
  } catch (e) {
    debugPrint('[clip] write: $e');
    return false;
  }
}
