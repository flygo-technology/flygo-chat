import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Dịch [text] sang ngôn ngữ [to] (vi, en, ko, ja, th, zh…) qua trạm đẩy (`POST /translate`, mô hình AI rẻ và nhanh
/// nhất, dự phòng Google Dịch). Xác thực bằng phiên Mattermost. Trạm của máy chủ chưa có dịch thì dùng trạm Flygo.
/// Trả về bản dịch và mã ngôn ngữ gốc đoán được.
Future<({String text, String from})> translateText(String token, String text, String to) async {
  Future<http.Response> call(String base) => http
      .post(Uri.parse('$base/translate'),
          headers: {
            'Authorization': 'Bearer $token',
            'X-MM-Server': kServerUrl,
            'Content-Type': 'application/json',
            'User-Agent': kUserAgent,
          },
          body: jsonEncode({'text': text, 'to': to}))
      .timeout(const Duration(seconds: 25));
  var r = await call(pushUrlFor(kServerUrl));
  if (r.statusCode == 404 && pushUrlFor(kServerUrl) != kFlygoPush) r = await call(kFlygoPush);
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
  if (r.statusCode != 200) throw HttpException('${j['error'] ?? 'translate ${r.statusCode}'}');
  return (text: '${j['text']}', from: '${j['from'] ?? ''}');
}

/// Tin song ngữ (nút "Dịch AI"): props.flygo_bilingual = {v:1, langs:[gốc, dịch], texts:[bản gốc, bản dịch]}.
/// Nội dung tin (message) là bản gốc + dòng kẻ + bản dịch, để app khác vẫn đọc được cả hai.
const kBilingualRule = '───';

({List<String> langs, List<String> texts})? bilingualOf(Map<String, dynamic> props) {
  final b = props['flygo_bilingual'];
  if (b is! Map) return null;
  final langs = [for (final x in (b['langs'] as List? ?? const [])) '$x'];
  final texts = [for (final x in (b['texts'] as List? ?? const [])) '$x'];
  if (langs.length != 2 || texts.length != 2) return null;
  return (langs: langs, texts: texts);
}
