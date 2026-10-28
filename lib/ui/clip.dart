import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

/// Ảnh / tệp trong bộ nhớ tạm (clipboard) của hệ điều hành: dán vào chat và sao chép ảnh.

bool get _mobile => Platform.isAndroid || Platform.isIOS;

/// Điện thoại: kênh native chỉ HỎI loại nội dung trong bộ nhớ tạm, không đọc nội dung
/// (iOS không hiện "đã dán từ…", Android không hiện thông báo đã đọc bộ nhớ tạm).
/// iOS: ios/Runner/AppDelegate.swift; Android: MainActivity.kt.
const _probeChannel = MethodChannel('flygo/clip');

/// Loại nội dung đang có trong bộ nhớ tạm. [stamp] đổi khi nội dung đổi (để ẩn gợi ý "Dán ảnh" đã bỏ qua).
typedef ClipKind = ({bool image, bool text, int stamp});

/// Điện thoại: bộ nhớ tạm có ảnh / có chữ không (không đọc nội dung). Máy tính: không dùng.
Future<ClipKind> probeClipboard() async {
  try {
    final r = await _probeChannel.invokeMapMethod<String, Object?>('probe');
    return (image: r?['image'] == true, text: r?['text'] == true, stamp: (r?['stamp'] as num?)?.toInt() ?? 0);
  } catch (_) {
    return (image: false, text: false, stamp: 0);
  }
}

/// Bộ nhớ tạm có ảnh hoặc tệp để dán không.
Future<bool> clipboardHasMedia() async {
  try {
    if (_mobile) return (await probeClipboard()).image;
    if ((await Pasteboard.files()).isNotEmpty) return true;
    return await Pasteboard.image != null;
  } catch (_) {
    return false;
  }
}

Future<List<(String, String)>> _copiedFiles() async {
  if (_mobile) return const [];
  return [
    for (final p in await Pasteboard.files())
      if (File(p).existsSync()) (p, p.split(Platform.pathSeparator).last),
  ];
}

Future<List<(String, String)>> _clipImage() async {
  final bytes = await Pasteboard.image;
  if (bytes == null || bytes.isEmpty) return const [];
  final dir = await getTemporaryDirectory();
  final name = 'paste_${DateTime.now().millisecondsSinceEpoch}.png';
  final f = File('${dir.path}${Platform.pathSeparator}$name');
  await f.writeAsBytes(bytes);
  return [(f.path, name)];
}

/// Lấy ảnh / tệp đang có trong bộ nhớ tạm, lưu ra file tạm. Trả về (đường dẫn, tên).
Future<List<(String, String)>> readClipboardMedia() async {
  try {
    // Tệp được sao chép từ Finder / Explorer / trình quản lý tệp (máy tính).
    final files = await _copiedFiles();
    if (files.isNotEmpty) return files;
    // Ảnh (chụp màn hình, sao chép ảnh từ trình duyệt...).
    return await _clipImage();
  } catch (e) {
    debugPrint('[clip] read: $e');
    return const [];
  }
}

/// Bấm Dán (Cmd/Ctrl+V, nút Dán): bộ nhớ tạm có tệp / ảnh thì trả về để đính kèm; rỗng thì để ô nhắn tin
/// dán chữ như thường. Có cả chữ lẫn ảnh (ô Excel / Word kèm ảnh xem trước) thì ưu tiên chữ, trừ khi chữ chỉ là
/// một đường link (trình duyệt "Sao chép ảnh").
Future<List<(String, String)>> clipboardMediaForPaste() async {
  try {
    if (_mobile) {
      final k = await probeClipboard();
      if (!k.image || k.text) return const [];
      return await _clipImage();
    }
    final files = await _copiedFiles();
    if (files.isNotEmpty) return files;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (text.isNotEmpty && !RegExp(r'^\S+://\S+$').hasMatch(text)) return const [];
    return await _clipImage();
  } catch (e) {
    debugPrint('[clip] paste: $e');
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
