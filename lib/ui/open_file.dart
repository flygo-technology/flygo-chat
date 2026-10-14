import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

const _channel = MethodChannel('flygo/open');

/// Kiểu MIME theo đuôi tệp (đủ cho các tệp thường gặp).
String mimeOfPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  return const {
        'pdf': 'application/pdf',
        'doc': 'application/msword',
        'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'xls': 'application/vnd.ms-excel',
        'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'ppt': 'application/vnd.ms-powerpoint',
        'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'txt': 'text/plain',
        'csv': 'text/csv',
        'html': 'text/html',
        'zip': 'application/zip',
        'apk': 'application/vnd.android.package-archive',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'mp4': 'video/mp4',
        'm4a': 'audio/mp4',
        'mp3': 'audio/mpeg',
      }[ext] ??
      '*/*';
}

/// Mở tệp trên điện thoại: Android mở bằng ứng dụng phù hợp; iPhone (hoặc khi không có ứng dụng mở được)
/// hiện bảng chia sẻ để xem / lưu / gửi đi. Trả về false nếu không mở được.
Future<bool> openLocalFile(String path, {String? mime, String? title}) async {
  if (Platform.isAndroid) {
    final ok = await _channel.invokeMethod<bool>('open', {'path': path, 'mime': mime ?? mimeOfPath(path)}) ?? false;
    if (ok) return true;
  }
  await SharePlus.instance.share(ShareParams(files: [XFile(path)], title: title));
  return true;
}
