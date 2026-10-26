import '../i18n/i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../data/models.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  bool get isAuth => status == 401;
  @override
  String toString() => 'ApiException($status): $message';
}

/// Client REST cho API v4 của máy chủ chat.
class MmApi {
  final String token;
  final http.Client _http = http.Client();
  MmApi(this.token);

  Map<String, String> get headers => {
        'Authorization': 'Bearer $token',
        'User-Agent': kUserAgent,
        'X-Requested-With': 'XMLHttpRequest',
      };

  /// Đường dẫn plugin (`/plugins/...`) nằm ngoài `/api/v4`.
  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse(path.startsWith('/plugins/') ? '$kServerUrl$path' : '$kServerUrl/api/v4$path')
          .replace(queryParameters: q);

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, _u(path, query))..headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 30)));
    if (res.statusCode >= 400) {
      String msg = res.body;
      try {
        msg = (jsonDecode(res.body) as Map)['message'] as String? ?? msg;
      } catch (_) {}
      throw ApiException(res.statusCode, msg);
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<dynamic> get(String p, [Map<String, String>? q]) => _send('GET', p, query: q);
  Future<dynamic> post(String p, Object? body) => _send('POST', p, body: body);
  Future<dynamic> put(String p, Object? body) => _send('PUT', p, body: body);
  Future<dynamic> patch(String p, Object? body) => _send('PATCH', p, body: body);
  Future<dynamic> delete(String p) => _send('DELETE', p);

  // --- Người dùng, nhóm
  Future<MmUser> me() async => MmUser((await get('/users/me') as Map).cast());
  Future<Json> teamByName(String name) async => (await get('/teams/name/$name') as Map).cast();
  Future<List<MmUser>> usersByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final r = await post('/users/ids', ids) as List;
    return r.map((e) => MmUser((e as Map).cast())).toList();
  }

  Future<List<MmUser>> teamUsers(String teamId) async {
    final out = <MmUser>[];
    for (var page = 0;; page++) {
      final r = await get('/users', {'in_team': teamId, 'active': 'true', 'per_page': '200', 'page': '$page'}) as List;
      out.addAll(r.map((e) => MmUser((e as Map).cast())));
      if (r.length < 200) break;
    }
    return out;
  }

  // --- Kênh
  Future<List<MmChannel>> myChannels(String teamId) async {
    final r = await get('/users/me/teams/$teamId/channels', {'include_deleted': 'false'}) as List;
    return r.map((e) => MmChannel((e as Map).cast())).toList();
  }

  Future<List<MmMember>> myMembers(String teamId) async {
    final r = await get('/users/me/teams/$teamId/channels/members') as List;
    return r.map((e) => MmMember((e as Map).cast())).toList();
  }

  Future<MmMember> member(String channelId, String userId) async =>
      MmMember((await get('/channels/$channelId/members/$userId') as Map).cast());

  Future<MmChannel> directChannel(String me, String other) async =>
      MmChannel((await post('/channels/direct', [me, other]) as Map).cast());

  Future<List<String>> channelMemberIds(String channelId) async {
    final r = await get('/channels/$channelId/members', {'per_page': '200'}) as List;
    return r.map((e) => e['user_id'] as String).toList();
  }

  Future<void> updateNotify(String channelId, String userId, Map<String, String> props) =>
      put('/channels/$channelId/members/$userId/notify_props', props);

  Future<void> viewChannel(String channelId) => post('/channels/members/me/view', {'channel_id': channelId});

  // --- Tin nhắn
  /// Trả về danh sách tin theo thứ tự mới nhất trước.
  Future<List<MmPost>> posts(String channelId, {String? before, int? since, int perPage = 60}) async {
    final q = <String, String>{'per_page': '$perPage'};
    if (before != null) q['before'] = before;
    if (since != null) q['since'] = '$since';
    final r = (await get('/channels/$channelId/posts', q) as Map).cast<String, dynamic>();
    final posts = (r['posts'] as Map).cast<String, dynamic>();
    final order = (r['order'] as List).cast<String>();
    final ids = order.isNotEmpty ? order : posts.keys.toList();
    return ids.where(posts.containsKey).map((id) => MmPost((posts[id] as Map).cast())).toList();
  }

  Future<MmPost> postById(String id) async => MmPost((await get('/posts/$id') as Map).cast());

  Future<MmPost> createPost(Json body) async => MmPost((await post('/posts', body) as Map).cast());

  Future<void> deletePost(String id) => delete('/posts/$id');

  Future<void> react(String userId, String postId, String emoji) =>
      post('/reactions', {'user_id': userId, 'post_id': postId, 'emoji_name': emoji});
  Future<void> unreact(String userId, String postId, String emoji) =>
      delete('/users/$userId/posts/$postId/reactions/$emoji');

  Future<List<MmPost>> search(String teamId, String terms) async {
    final r = (await post('/teams/$teamId/posts/search', {'terms': terms, 'is_or_search': false, 'per_page': 60}) as Map)
        .cast<String, dynamic>();
    final posts = (r['posts'] as Map? ?? {}).cast<String, dynamic>();
    final order = (r['order'] as List? ?? []).cast<String>();
    return order.where(posts.containsKey).map((id) => MmPost((posts[id] as Map).cast())).toList();
  }

  // --- File
  Future<List<String>> uploadFile(String channelId, String name, Uint8List bytes) async {
    final req = http.MultipartRequest('POST', _u('/files'))
      ..headers.addAll(headers)
      ..fields['channel_id'] = channelId
      ..files.add(http.MultipartFile.fromBytes('files', bytes, filename: name));
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    final infos = (jsonDecode(res.body) as Map)['file_infos'] as List;
    return infos.map((e) => e['id'] as String).toList();
  }

  /// Tải tệp lớn (video...) theo từng phần qua phiên tải lên của máy chủ chat (/uploads): mỗi lần gửi
  /// không quá [chunk] byte, nên không bị giới hạn 100 MB mỗi yêu cầu của Cloudflare. Trả về id tệp.
  Future<List<String>> uploadPath(String channelId, String name, String path, {int chunk = 20 << 20}) async {
    final f = File(path);
    final size = await f.length();
    if (size <= chunk) return uploadFile(channelId, name, await f.readAsBytes());
    final session = (await post('/uploads', {'channel_id': channelId, 'filename': name, 'file_size': size}) as Map).cast<String, dynamic>();
    final id = session['id'] as String;
    final raf = await f.open();
    try {
      var offset = 0;
      Map<String, dynamic>? info;
      while (offset < size) {
        final n = (size - offset) < chunk ? size - offset : chunk;
        final bytes = await raf.read(n);
        final req = http.Request('POST', _u('/uploads/$id'))
          ..headers.addAll(headers)
          ..headers['Content-Type'] = 'application/octet-stream'
          ..bodyBytes = bytes;
        final res = await http.Response.fromStream(await _http.send(req));
        if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
        offset += n;
        if (res.body.isNotEmpty) {
          final j = jsonDecode(res.body);
          if (j is Map && j['id'] != null && offset >= size) info = j.cast<String, dynamic>();
        }
      }
      if (info == null) throw ApiException(500, 'upload incomplete');
      return [info['id'] as String];
    } finally {
      await raf.close();
    }
  }

  /// Đặt ảnh đại diện cho người dùng (chính mình, hoặc bot của mình).
  Future<void> uploadUserImage(String userId, String name, Uint8List bytes) async {
    final req = http.MultipartRequest('POST', _u('/users/$userId/image'))
      ..headers.addAll(headers)
      ..files.add(http.MultipartFile.fromBytes('image', bytes, filename: name));
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  }

  String fileUrl(String id) => '$kServerUrl/api/v4/files/$id';
  String thumbUrl(String id) => '$kServerUrl/api/v4/files/$id/thumbnail';
  String previewUrl(String id) => '$kServerUrl/api/v4/files/$id/preview';
  String avatarUrl(String userId, [int v = 0]) => '$kServerUrl/api/v4/users/$userId/image?_=$v';

  Future<Uint8List> fileBytes(String id) async {
    final res = await _http.get(Uri.parse(fileUrl(id)), headers: headers);
    if (res.statusCode >= 400) throw ApiException(res.statusCode, tr('Không tải được file'));
    return res.bodyBytes;
  }

  Future<File> downloadFile(MmFile f, Directory dir) async {
    final res = await _http.get(Uri.parse(fileUrl(f.id)), headers: headers);
    if (res.statusCode >= 400) throw ApiException(res.statusCode, tr('Không tải được file'));
    final out = File('${dir.path}${Platform.pathSeparator}${f.name}');
    await out.writeAsBytes(res.bodyBytes);
    return out;
  }

  Future<void> logout() async {
    try {
      await post('/users/logout', null);
    } catch (_) {}
  }

  void close() => _http.close();
}
