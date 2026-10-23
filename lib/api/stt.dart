import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'mm_api.dart';

// Máy chủ nhận diện giọng nói (Whisper tự dựng): [kSttUrl] trong config.dart, theo máy chủ đang dùng.
// Xác thực bằng phiên Mattermost của người dùng.

/// Chuyển file ghi âm thành chữ (mặc định tiếng Việt).
Future<String> transcribeAudio(MmApi api, String path, {String language = 'vi'}) async {
  final req = http.MultipartRequest('POST', Uri.parse('$kSttUrl/stt'))
    ..headers.addAll({'Authorization': 'Bearer ${api.token}', 'X-MM-Server': kServerUrl, 'User-Agent': kUserAgent})
    ..fields['language'] = language
    ..files.add(await http.MultipartFile.fromPath('file', path));
  final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 3)));
  if (res.statusCode != 200) throw HttpException('STT ${res.statusCode}');
  return ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['text'] as String? ?? '').trim();
}
