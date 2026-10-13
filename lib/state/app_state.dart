import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/mm_api.dart';
import '../api/mm_ws.dart';
import '../auth/auth_service.dart';
import '../calls/call_service.dart';
import '../calls/calls_client.dart';
import '../config.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../ui/common.dart';

/// Một dòng trong danh sách hội thoại.
class ChatSummary {
  final MmChannel channel;
  final String title;
  final String? avatarUserId;
  final MmPost? last;
  final int unread;
  final int mentions;
  ChatSummary(this.channel, this.title, this.avatarUserId, this.last, this.unread, this.mentions);
  int get sortTime => last?.createAt ?? (channel.lastPostAt > 0 ? channel.lastPostAt : channel.createAt);
  /// Chat với chính mình ("Cloud của tôi").
  bool get isSelf => channel.isDirect && avatarUserId == null && channel.name.split('__').toSet().length == 1;
}

class AppState extends ChangeNotifier {
  final String token;
  final MmApi api;
  late LocalStore _store;
  MmSocket? _ws;

  MmUser? me;
  String? teamId;
  bool ready = false;
  bool sessionExpired = false;
  bool online = false;
  String? lastError;

  final Map<String, MmChannel> channels = {};
  final Map<String, MmMember> members = {};
  final Map<String, MmUser> users = {};
  final Map<String, MmPost?> latest = {};
  final Map<String, List<MmPost>> _posts = {}; // mới nhất trước
  final Map<String, bool> hasMore = {};
  final Map<String, int> otherViewedAt = {};
  final Map<String, Map<String, DateTime>> _typing = {};
  final Map<String, int> _lastSync = {};
  String? activeChannelId;
  Timer? _viewTimer;
  Timer? _tick;
  bool _syncing = false;

  late final CallService calls = CallService(
    api: api,
    myId: () => me?.id ?? '',
    isDirectOrGroup: (id) => channels[id]?.isDirect == true || channels[id]?.isGroupDm == true,
  )..addListener(notifyListeners);

  AppState(this.token) : api = MmApi(token);

  static Future<AppState?> restore() async {
    final t = await TokenStore.read();
    if (t == null) return null;
    final s = AppState(t);
    await s.start();
    return s;
  }

  // ---------------------------------------------------------------- khởi động
  /// [waitForSync]: chờ đồng bộ lần đầu xong (dùng khi vừa đăng nhập để kiểm tra
  /// phiên). Khi mở app bình thường thì hiện giao diện ngay, đồng bộ chạy nền.
  Future<void> start({bool waitForSync = false}) async {
    _store = await LocalStore.open(serverKey);
    final meJson = await _store.meta<Map>('me');
    teamId = await _store.meta<String>('team_id');
    if (meJson != null) {
      me = MmUser(Map<String, dynamic>.from(meJson));
      await _loadCache();
      ready = true;
      notifyListeners();
    }
    _ws = MmSocket(token, onEvent: _onWs, onState: _onWsState)..connect();
    _tick = Timer.periodic(const Duration(seconds: 3), (_) => _expireTyping());
    final sync = syncAll();
    if (waitForSync) await sync;
  }

  Future<void> _loadCache() async {
    for (final c in await _store.channels()) {
      channels[c.id] = c;
    }
    for (final m in await _store.members()) {
      members[m.channelId] = m;
    }
    for (final u in await _store.users()) {
      users[u.id] = u;
    }
    for (final id in channels.keys) {
      latest[id] = await _store.latest(id);
    }
    renderMarkdown = await _store.meta<bool>('render_markdown') ?? true;
    final ls = await _store.meta<Map>('last_sync');
    ls?.forEach((k, v) => _lastSync[k as String] = (v as num).toInt());
  }

  /// Đồng bộ toàn bộ danh sách kênh, thành viên, người dùng và tin mới nhất.
  Future<void> syncAll() async {
    if (_syncing) return;
    _syncing = true;
    try {
      me = await api.me();
      await _store.setMeta('me', me!.raw);
      teamId ??= await _resolveTeam();
      await _store.setMeta('team_id', teamId);

      final chs = (await api.myChannels(teamId!)).where((c) => c.deleteAt == 0).toList();
      final mems = await api.myMembers(teamId!);
      channels
        ..clear()
        ..addEntries(chs.map((c) => MapEntry(c.id, c)));
      for (final m in mems) {
        members[m.channelId] = m;
      }
      await _store.putChannels(chs, replace: true);
      await _store.putMembers(mems);

      final teamUsers = await api.teamUsers(teamId!);
      for (final u in teamUsers) {
        users[u.id] = u;
      }
      final missing = <String>{};
      for (final c in chs) {
        final o = c.otherUserId(me!.id);
        if (o != null && !users.containsKey(o)) missing.add(o);
      }
      for (final u in await api.usersByIds(missing.toList())) {
        users[u.id] = u;
      }
      await _store.putUsers(users.values.toList());

      // Đã có danh sách kênh: hiện giao diện ngay.
      loadFavorites();
      loadTodos();
      loadScheduled();
      ready = true;
      online = true;
      lastError = null;
      notifyListeners();
      await _flushOutbox();

      // Tải tin mới cho các kênh có hoạt động, kênh mới nhất trước, 4 kênh một lúc.
      final todo = chs.where((c) {
        final cached = latest[c.id];
        return !(cached != null && c.lastPostAt <= (_lastSync[c.id] ?? 0));
      }).toList()
        ..sort((a, b) => b.lastPostAt.compareTo(a.lastPostAt));
      for (var i = 0; i < todo.length; i += 4) {
        await Future.wait(todo.skip(i).take(4).map((c) => _fetchNewer(c.id).catchError((_) {})));
        notifyListeners();
      }
    } on ApiException catch (e) {
      if (e.isAuth) {
        sessionExpired = true;
      } else {
        lastError = e.message;
      }
    } catch (e) {
      online = false;
      lastError = tr('Không có kết nối mạng');
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Ưu tiên team cấu hình sẵn; người dùng không ở team đó thì lấy team đầu tiên.
  Future<String> _resolveTeam() async {
    final teams = (await api.get('/users/me/teams') as List).cast<Map>();
    if (teams.isEmpty) throw ApiException(403, tr('Tài khoản chưa thuộc nhóm nào'));
    final t = teams.where((t) => t['name'] == kTeamName).firstOrNull ?? teams.first;
    return t['id'] as String;
  }

  Future<void> _fetchNewer(String channelId) async {
    final since = _lastSync[channelId];
    final started = DateTime.now().millisecondsSinceEpoch;
    List<MmPost> got;
    if (since != null && (_posts[channelId]?.isNotEmpty ?? latest[channelId] != null)) {
      got = await api.posts(channelId, since: since - 1000, perPage: 200);
    } else {
      got = await api.posts(channelId, perPage: 60);
      hasMore[channelId] = got.length >= 60;
    }
    await _store.putPosts(got);
    _merge(channelId, got);
    _lastSync[channelId] = started;
    await _store.setMeta('last_sync', Map<String, int>.from(_lastSync));
    await _store.trim(channelId);
    latest[channelId] = await _store.latest(channelId);
  }

  // ---------------------------------------------------------------- danh sách chat
  String channelTitle(MmChannel c) {
    final o = me == null ? null : c.otherUserId(me!.id);
    if (o != null) {
      if (o == me!.id) return tr('Cloud của tôi');
      return users[o]?.displayName ?? tr('Người dùng');
    }
    if (c.isGroupDm) {
      final names = c.displayName.split(',').map((s) => s.trim()).where((s) => s != me?.username);
      return names.map((n) => users.values.where((u) => u.username == n).firstOrNull?.displayName ?? n).join(', ');
    }
    return c.displayName;
  }

  int unreadOf(String channelId) {
    final c = channels[channelId];
    final m = members[channelId];
    if (c == null || m == null) return 0;
    return (c.totalMsgCount - m.msgCount).clamp(0, 9999);
  }

  List<ChatSummary> get chats {
    final list = channels.values.map((c) {
      final o = me == null ? null : c.otherUserId(me!.id);
      return ChatSummary(c, channelTitle(c), o == me?.id ? null : o, latest[c.id], unreadOf(c.id), members[c.id]?.mentionCount ?? 0);
    }).toList();
    list.sort((a, b) => b.sortTime.compareTo(a.sortTime));
    return list;
  }

  List<MmUser> get people {
    final l = users.values.where((u) => u.deleteAt == 0 && !u.isBot && u.id != me?.id).toList();
    l.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return l;
  }

  String previewText(MmPost? p) {
    if (p == null) return '';
    if (p.isRecalled) return tr('Tin nhắn đã được thu hồi');
    var t = plainPreview(p.message);
    if (t.isEmpty && p.files.isNotEmpty) {
      final f = p.files.first;
      t = f.isImage ? tr('📷 Ảnh') : '📄 ${f.name}';
    }
    return t;
  }

  // ---------------------------------------------------------------- một cuộc chat
  List<MmPost> postsOf(String channelId) => _posts[channelId] ?? const [];

  Future<void> openChannel(String channelId) async {
    activeChannelId = channelId;
    if (!_posts.containsKey(channelId)) {
      _posts[channelId] = await _store.posts(channelId, limit: 120);
      hasMore.putIfAbsent(channelId, () => true);
      for (final p in await _store.outbox()) {
        if (p['channel_id'] == channelId) _merge(channelId, [MmPost(p)]);
      }
      notifyListeners();
    }
    try {
      await _fetchNewer(channelId);
      loadPinned(channelId);
      _refreshViewedBy(channelId);
      markViewed(channelId);
    } catch (_) {}
    notifyListeners();
  }

  void closeChannel(String channelId) {
    if (activeChannelId == channelId) activeChannelId = null;
  }

  Future<void> loadOlder(String channelId) async {
    final list = _posts[channelId];
    if (list == null || hasMore[channelId] == false) return;
    final oldest = list.lastWhere((p) => p.sendState == SendState.sent, orElse: () => list.last);
    try {
      final got = await api.posts(channelId, before: oldest.id, perPage: 60);
      hasMore[channelId] = got.length >= 60;
      _merge(channelId, got);
      notifyListeners();
    } catch (_) {}
  }

  void markViewed(String channelId) {
    final c = channels[channelId];
    final m = members[channelId];
    if (c != null && m != null) {
      members[channelId] = MmMember({...m.raw, 'msg_count': c.totalMsgCount, 'mention_count': 0});
    }
    _viewTimer?.cancel();
    _viewTimer = Timer(const Duration(milliseconds: 600), () => api.viewChannel(channelId).catchError((_) {}));
    notifyListeners();
  }

  Future<void> _refreshViewedBy(String channelId) async {
    final c = channels[channelId];
    final o = c == null || me == null ? null : c.otherUserId(me!.id);
    if (o == null || o == me!.id) return;
    try {
      otherViewedAt[channelId] = (await api.member(channelId, o)).lastViewedAt;
      notifyListeners();
    } catch (_) {}
  }

  /// Người kia đã xem tin này chưa (chỉ có ý nghĩa với tin nhắn riêng).
  bool isSeen(MmPost p) => (otherViewedAt[p.channelId] ?? 0) >= p.createAt;

  List<String> typingIn(String channelId) =>
      (_typing[channelId]?.keys ?? const <String>[]).map((u) => users[u]?.displayName ?? '').toList();

  void notifyTyping(String channelId) => _ws?.sendTyping(channelId);

  void _merge(String channelId, List<MmPost> incoming) {
    final list = _posts[channelId];
    if (list == null) return;
    for (final p in incoming) {
      final had = list.any((x) => x.id == p.id);
      list.removeWhere((x) => x.id == p.id || (p.pendingId.isNotEmpty && x.pendingId == p.pendingId));
      if (p.deleteAt == 0) {
        list.add(p);
      } else if (had || p.createAt > 0) {
        // Tin bị thu hồi: giữ chỗ, xóa nội dung.
        list.add(MmPost({...p.raw, 'message': '', 'metadata': {}, 'file_ids': const [], '_deleted': true}));
      }
    }
    list.sort((a, b) => b.createAt.compareTo(a.createAt));
  }

  MmPost? findPost(String channelId, String id) =>
      _posts[channelId]?.where((p) => p.id == id).firstOrNull;

  // ---------------------------------------------------------------- gửi tin
  /// Gửi tin. [priority]: '' | 'important' | 'urgent'; [requestAck]: yêu cầu xác nhận đã đọc;
  /// [burnOnRead]: tin tự hủy sau khi người nhận đọc; [props]: thuộc tính thêm (vd. chuyển tiếp).
  Future<void> send(String channelId, String text,
      {String rootId = '',
      List<String> fileIds = const [],
      String priority = '',
      bool requestAck = false,
      bool burnOnRead = false,
      Map<String, dynamic>? props}) async {
    if (me == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pendingId = '${me!.id}:$now';
    final local = <String, dynamic>{
      'id': pendingId,
      'pending_post_id': pendingId,
      'channel_id': channelId,
      'user_id': me!.id,
      'message': text,
      'root_id': rootId,
      'create_at': now,
      'file_ids': fileIds,
      'metadata': {
        if (priority.isNotEmpty || requestAck)
          'priority': {'priority': priority, 'requested_ack': requestAck},
      },
      if (burnOnRead) 'type': 'burn_on_read',
      'props': ?props,
      '_send': 'sending',
    };
    await _store.putOutbox(local);
    _merge(channelId, [MmPost(local)]);
    notifyListeners();
    await _sendOne(local);
  }

  Future<void> _sendOne(Map<String, dynamic> local) async {
    final channelId = local['channel_id'] as String;
    try {
      final body = {
        'channel_id': channelId,
        'message': local['message'],
        'root_id': local['root_id'],
        'pending_post_id': local['pending_post_id'],
        if ((local['file_ids'] as List).isNotEmpty) 'file_ids': local['file_ids'],
        if ((local['metadata'] as Map?)?['priority'] != null)
          'metadata': {'priority': (local['metadata'] as Map)['priority']},
        if (local['type'] != null) 'type': local['type'],
        if (local['props'] != null) 'props': local['props'],
      };
      final saved = await api.createPost(body);
      await _store.removeOutbox(local['pending_post_id'] as String);
      await _store.putPosts([saved]);
      _merge(channelId, [saved]);
      latest[channelId] = saved;
    } catch (e) {
      final failed = {...local, '_send': 'failed'};
      await _store.putOutbox(failed);
      _merge(channelId, [MmPost(failed)]);
      if (e is! ApiException) online = false;
    }
    notifyListeners();
  }

  Future<void> retry(MmPost p) async {
    final raw = {...p.raw, '_send': 'sending'};
    _merge(p.channelId, [MmPost(raw)]);
    notifyListeners();
    await (p.localFiles.isNotEmpty ? _sendMediaOne(raw) : _sendOne(raw));
  }

  // ---------------------------------------------------------------- gửi ảnh / file
  /// fileId -> đường dẫn ảnh trên máy, để ảnh mình vừa gửi hiện ngay, không tải lại.
  final Map<String, String> _localById = {};
  String? localPathFor(String fileId) => _localById[fileId];

  /// Gửi ảnh/file: tin hiện ngay trong khung chat với ảnh từ máy, tải lên chạy nền.
  /// [files]: (đường dẫn, tên, mime, tỉ lệ khung ảnh).
  Future<void> sendMedia(String channelId, List<(String, String, String, double)> files,
      {String text = '', String rootId = ''}) async {
    if (me == null || files.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pendingId = '${me!.id}:$now';
    final local = <String, dynamic>{
      'id': pendingId,
      'pending_post_id': pendingId,
      'channel_id': channelId,
      'user_id': me!.id,
      'message': text,
      'root_id': rootId,
      'create_at': now,
      'file_ids': const <String>[],
      'metadata': {},
      '_local_files': [
        for (final (path, name, mime, aspect) in files) {'path': path, 'name': name, 'mime': mime, 'aspect': aspect},
      ],
      '_send': 'sending',
    };
    await _store.putOutbox(local);
    _merge(channelId, [MmPost(local)]);
    notifyListeners();
    await _sendMediaOne(local);
  }

  /// Lần gửi file gần nhất bị máy chủ từ chối vì quá lớn.
  bool uploadTooLarge = false;

  Future<void> _sendMediaOne(Map<String, dynamic> local) async {
    uploadTooLarge = false;
    final channelId = local['channel_id'] as String;
    try {
      final ids = <String>[];
      for (final f in MmPost(local).localFiles) {
        final path = f['path'] as String;
        final got = await api.uploadFile(channelId, f['name'] as String, await File(path).readAsBytes());
        for (final id in got) {
          _localById[id] = path;
        }
        ids.addAll(got);
      }
      final saved = await api.createPost({
        'channel_id': channelId,
        'message': local['message'],
        'root_id': local['root_id'],
        'pending_post_id': local['pending_post_id'],
        'file_ids': ids,
      });
      await _store.removeOutbox(local['pending_post_id'] as String);
      await _store.putPosts([saved]);
      _merge(channelId, [saved]);
      latest[channelId] = saved;
    } catch (e) {
      debugPrint('[upload] $e');
      final failed = {...local, '_send': 'failed'};
      await _store.putOutbox(failed);
      _merge(channelId, [MmPost(failed)]);
      uploadTooLarge = e is ApiException && e.status == 413;
    }
    notifyListeners();
  }

  Future<void> discard(MmPost p) async {
    await _store.removeOutbox(p.pendingId);
    _posts[p.channelId]?.removeWhere((x) => x.pendingId == p.pendingId);
    notifyListeners();
  }

  Future<void> _flushOutbox() async {
    for (final p in await _store.outbox()) {
      final raw = {...p, '_send': 'sending'};
      await (MmPost(raw).localFiles.isNotEmpty ? _sendMediaOne(raw) : _sendOne(raw));
    }
  }

  Future<List<String>> upload(String channelId, String name, Uint8List bytes) =>
      api.uploadFile(channelId, name, bytes);

  /// Thả hoặc gỡ cảm xúc. Cập nhật giao diện ngay, sự kiện từ máy chủ sẽ
  /// đồng bộ lại sau. Mỗi người chỉ giữ một cảm xúc trên một tin, giống WhatsApp.
  Future<void> toggleReaction(MmPost p, String emoji) async {
    if (me == null) return;
    final uid = me!.id;
    final current = findPost(p.channelId, p.id) ?? p;
    final mine = current.reactions[emoji]?.contains(uid) ?? false;
    final others = current.reactions.entries
        .where((e) => e.key != emoji && e.value.contains(uid))
        .map((e) => e.key)
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final old in others) {
      _applyReaction({'user_id': uid, 'post_id': p.id, 'emoji_name': old}, false);
    }
    _applyReaction({'user_id': uid, 'post_id': p.id, 'emoji_name': emoji, 'create_at': now}, !mine);
    notifyListeners();
    try {
      for (final old in others) {
        await api.unreact(uid, p.id, old);
      }
      mine ? await api.unreact(uid, p.id, emoji) : await api.react(uid, p.id, emoji);
    } catch (_) {
      // Lỗi mạng: trả lại trạng thái cũ.
      _applyReaction({'user_id': uid, 'post_id': p.id, 'emoji_name': emoji, 'create_at': now}, mine);
      for (final old in others) {
        _applyReaction({'user_id': uid, 'post_id': p.id, 'emoji_name': old, 'create_at': now}, true);
      }
      notifyListeners();
    }
  }

  /// Sửa nội dung tin của mình.
  Future<void> editPost(MmPost p, String text) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _merge(p.channelId, [MmPost({...p.raw, 'message': text, 'edit_at': now})]);
    notifyListeners();
    final saved = MmPost((await api.put('/posts/${p.id}/patch', {'message': text}) as Map).cast());
    await _store.putPosts([saved]);
    _merge(p.channelId, [saved]);
    notifyListeners();
  }

  Future<void> deletePost(MmPost p) async {
    try {
      await api.deletePost(p.id);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- tính năng gửi nâng cao
  /// Hẹn giờ gửi (tính năng ScheduledPosts của máy chủ).
  Future<void> schedule(String channelId, String text, DateTime at, {String rootId = '', List<String> fileIds = const []}) async {
    await api.post('/posts/schedule', {
      'channel_id': channelId,
      'message': text,
      'root_id': rootId,
      if (fileIds.isNotEmpty) 'file_ids': fileIds,
      'scheduled_at': at.millisecondsSinceEpoch,
    });
    await loadScheduled();
  }

  /// Tin hẹn giờ đang chờ gửi, theo kênh.
  final Map<String, List<Map<String, dynamic>>> scheduled = {};

  Future<void> loadScheduled() async {
    if (teamId == null) return;
    try {
      final r = await api.get('/posts/scheduled/team/$teamId', {'includeDirectChannels': 'true'});
      scheduled.clear();
      void add(dynamic list) {
        for (final e in (list as List? ?? const [])) {
          final m = (e as Map).cast<String, dynamic>();
          if ((m['error_code'] as String? ?? '').isNotEmpty) continue;
          (scheduled[m['channel_id'] as String] ??= []).add(m);
        }
      }
      if (r is Map) {
        r.values.forEach(add);
      } else {
        add(r);
      }
      for (final l in scheduled.values) {
        l.sort((a, b) => (a['scheduled_at'] as num).compareTo(b['scheduled_at'] as num));
      }
      notifyListeners();
    } catch (_) {}
  }

  List<Map<String, dynamic>> scheduledIn(String channelId) => scheduled[channelId] ?? const [];

  Future<void> cancelScheduled(String id) async {
    await api.delete('/posts/schedule/$id');
    await loadScheduled();
  }

  /// Gửi ngay một tin hẹn giờ: gửi như tin thường rồi xóa lịch hẹn.
  Future<void> sendScheduledNow(Map<String, dynamic> sp) async {
    await send(sp['channel_id'] as String, sp['message'] as String? ?? '',
        rootId: sp['root_id'] as String? ?? '', fileIds: (sp['file_ids'] as List? ?? const []).cast<String>());
    await cancelScheduled(sp['id'] as String);
  }

  /// Xác nhận đã đọc tin quan trọng.
  Future<void> acknowledge(MmPost p) async {
    if (me == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final meta = Map<String, dynamic>.from(p.raw['metadata'] as Map? ?? {});
    final acks = List<dynamic>.from(meta['acknowledgements'] as List? ?? [])
      ..add({'user_id': me!.id, 'post_id': p.id, 'acknowledged_at': now});
    meta['acknowledgements'] = acks;
    _merge(p.channelId, [MmPost({...p.raw, 'metadata': meta})]);
    notifyListeners();
    try {
      await api.post('/users/${me!.id}/posts/${p.id}/ack', null);
    } catch (_) {}
  }

  /// Mở tin tự hủy: máy chủ trả nội dung và bắt đầu đếm ngược.
  Future<void> reveal(MmPost p) async {
    final r = MmPost((await api.get('/posts/${p.id}/reveal') as Map).cast());
    final raw = {...r.raw, '_revealed_at': DateTime.now().millisecondsSinceEpoch};
    _merge(p.channelId, [MmPost(raw)]);
    notifyListeners();
  }

  /// Chuyển tiếp một tin (kèm file) sang nhiều cuộc trò chuyện.
  Future<void> forward(MmPost p, List<String> channelIds) async {
    for (final cid in channelIds) {
      final ids = <String>[];
      for (final f in p.files) {
        final bytes = await api.fileBytes(f.id);
        ids.addAll(await api.uploadFile(cid, f.name, bytes));
      }
      await send(cid, p.message, fileIds: ids, props: {'dnd_forwarded': true});
    }
  }

  Future<void> leaveChannel(String channelId) async {
    await api.delete('/channels/$channelId/members/${me!.id}');
    _dropChannel(channelId);
  }

  Future<void> archiveChannel(String channelId) async {
    await api.delete('/channels/$channelId');
    _dropChannel(channelId);
  }

  /// Ẩn tin nhắn riêng / nhóm nhỏ khỏi danh sách (giống "xóa đoạn chat").
  Future<void> hideConversation(String channelId) async {
    final c = channels[channelId];
    if (c == null || me == null) return;
    final pref = c.isDirect
        ? {'user_id': me!.id, 'category': 'direct_channel_show', 'name': c.otherUserId(me!.id), 'value': 'false'}
        : {'user_id': me!.id, 'category': 'group_channel_show', 'name': c.id, 'value': 'false'};
    await api.put('/users/${me!.id}/preferences', [pref]);
    _dropChannel(channelId);
  }

  void _dropChannel(String channelId) {
    channels.remove(channelId);
    latest.remove(channelId);
    _posts.remove(channelId);
    _store.putChannels(channels.values.toList(), replace: true);
    notifyListeners();
  }

  /// Hiển thị markdown (đậm, danh sách, bảng...) hay chữ thô. Lưu trong kho máy.
  bool renderMarkdown = true;
  Future<void> setRenderMarkdown(bool v) async {
    renderMarkdown = v;
    notifyListeners();
    await _store.setMeta('render_markdown', v);
  }

  /// Tin dài đang được mở rộng ("Xem thêm").
  final Set<String> expanded = {};
  void expand(String postId) {
    expanded.add(postId);
    notifyListeners();
  }

  // ---------------------------------------------------------------- chưa đọc, yêu thích
  /// Đánh dấu cuộc trò chuyện là chưa đọc (từ tin mới nhất của người khác).
  Future<void> markUnread(String channelId) async {
    if (me == null) return;
    var posts = _posts[channelId];
    if (posts == null || posts.isEmpty) posts = await _store.posts(channelId, limit: 30);
    final target = posts.where((p) => p.userId != me!.id && !p.isSystem && p.sendState == SendState.sent).firstOrNull ??
        posts.where((p) => p.sendState == SendState.sent).firstOrNull;
    if (target == null) return;
    final m = members[channelId];
    final c = channels[channelId];
    if (m != null && c != null) {
      members[channelId] = MmMember({...m.raw, 'msg_count': (c.totalMsgCount - 1).clamp(0, 1 << 30)});
      notifyListeners();
    }
    try {
      await api.post('/users/${me!.id}/posts/${target.id}/set_unread', {'collapsed_threads_supported': false});
    } catch (_) {}
  }

  /// Kênh yêu thích (nhóm "Favorites" trong thanh bên của Mattermost).
  final Set<String> favorites = {};
  Map<String, dynamic>? _favCategory;

  Future<void> loadFavorites() async {
    if (me == null || teamId == null) return;
    try {
      final r = (await api.get('/users/${me!.id}/teams/$teamId/channels/categories') as Map).cast<String, dynamic>();
      final cats = (r['categories'] as List).cast<Map>();
      final fav = cats.where((c) => c['type'] == 'favorites').firstOrNull;
      if (fav == null) return;
      _favCategory = fav.cast<String, dynamic>();
      favorites
        ..clear()
        ..addAll((fav['channel_ids'] as List? ?? const []).cast<String>());
      notifyListeners();
    } catch (_) {}
  }

  bool isFavorite(String channelId) => favorites.contains(channelId);

  Future<void> toggleFavorite(String channelId) async {
    if (_favCategory == null) await loadFavorites();
    final cat = _favCategory;
    if (cat == null || me == null) return;
    favorites.contains(channelId) ? favorites.remove(channelId) : favorites.add(channelId);
    notifyListeners();
    final body = {...cat, 'channel_ids': favorites.toList()};
    try {
      final r = await api.put('/users/${me!.id}/teams/$teamId/channels/categories/${cat['id']}', body);
      if (r is Map) _favCategory = r.cast<String, dynamic>();
    } catch (_) {
      await loadFavorites();
    }
  }

  // ---------------------------------------------------------------- tin ghim
  final Map<String, List<MmPost>> pinned = {};

  Future<void> loadPinned(String channelId) async {
    try {
      final r = (await api.get('/channels/$channelId/pinned') as Map).cast<String, dynamic>();
      final posts = (r['posts'] as Map? ?? {}).cast<String, dynamic>();
      final order = (r['order'] as List? ?? const []).cast<String>();
      pinned[channelId] = [for (final id in order) if (posts[id] != null) MmPost((posts[id] as Map).cast())];
      notifyListeners();
    } catch (_) {}
  }

  List<MmPost> pinnedIn(String channelId) => pinned[channelId] ?? const [];

  Future<void> setPinned(MmPost p, bool pin) async {
    await api.post('/posts/${p.id}/${pin ? 'pin' : 'unpin'}', null);
    _merge(p.channelId, [MmPost({...p.raw, 'is_pinned': pin})]);
    await loadPinned(p.channelId);
  }

  /// Có quyền quản lý thành viên kênh không (quản trị hệ thống hoặc quản trị kênh).
  bool canManage(String channelId) {
    final roles = '${me?.raw['roles'] ?? ''} ${members[channelId]?.raw['roles'] ?? ''}';
    return roles.contains('system_admin') || roles.contains('channel_admin') || roles.contains('team_admin');
  }

  Future<void> addMember(String channelId, String userId) async {
    await api.post('/channels/$channelId/members', {'user_id': userId});
    _channelMembers.remove(channelId);
  }

  Future<void> removeMember(String channelId, String userId) async {
    await api.delete('/channels/$channelId/members/$userId');
    _channelMembers.remove(channelId);
  }

  // ---------------------------------------------------------------- thành viên kênh (gợi ý @tên)
  final Map<String, List<String>> _channelMembers = {};
  Future<List<MmUser>> channelUsers(String channelId) async {
    var ids = _channelMembers[channelId];
    if (ids == null) {
      try {
        ids = await api.channelMemberIds(channelId);
        _channelMembers[channelId] = ids;
        final missing = ids.where((id) => !users.containsKey(id)).toList();
        for (final u in await api.usersByIds(missing)) {
          users[u.id] = u;
        }
      } catch (_) {
        ids = const [];
      }
    }
    return [for (final id in ids) if (users[id] != null && users[id]!.deleteAt == 0) users[id]!];
  }

  // ---------------------------------------------------------------- công việc (plugin Todo)
  static const _todo = '/plugins/com.mattermost.plugin-todo';
  /// Danh sách việc: 'my' (của tôi), 'in' (người khác giao, chờ nhận), 'out' (tôi giao).
  final Map<String, List<Map<String, dynamic>>> todos = {'my': [], 'in': [], 'out': []};
  final Map<String, String> _postChannel = {};
  bool todoAvailable = true;

  Future<void> loadTodos() async {
    try {
      for (final l in ['my', 'in', 'out']) {
        final r = await api.get('$_todo/list', {'list': l});
        todos[l] = [for (final e in (r as List? ?? const [])) (e as Map).cast<String, dynamic>()];
      }
      todoAvailable = true;
      // Biết việc nào thuộc kênh nào (qua tin nhắn gốc của việc).
      final ids = {for (final l in todos.values) for (final t in l) t['post_id'] as String? ?? ''}
        ..removeWhere((id) => id.isEmpty || _postChannel.containsKey(id));
      await Future.wait(ids.map((id) async {
        try {
          final p = await api.postById(id);
          _postChannel[id] = p.channelId;
        } catch (_) {
          _postChannel[id] = '';
        }
      }));
    } on ApiException catch (e) {
      if (e.status == 404) todoAvailable = false;
    } catch (_) {}
    notifyListeners();
  }

  String? todoChannel(Map<String, dynamic> t) => _postChannel[t['post_id'] as String? ?? ''];

  /// Số việc chưa xong liên quan tới một kênh (của tôi + chờ tôi nhận).
  int openTodosIn(String channelId) => [...todos['my']!, ...todos['in']!].where((t) => todoChannel(t) == channelId).length;

  /// Tạo việc gắn với kênh: gửi một tin mô tả việc, rồi tạo việc trỏ vào tin đó.
  Future<void> createTodo(String channelId, String title, {String description = '', MmUser? assignee}) async {
    final who = assignee == null || assignee.id == me?.id ? '' : ' → @${assignee.username}';
    final post = await api.createPost({
      'channel_id': channelId,
      'message': tr('📋 **Việc mới:** {0}{1}{2}', [title, who, description.isEmpty ? '' : '\n$description']),
    });
    await _store.putPosts([post]);
    _merge(channelId, [post]);
    await api.post('$_todo/add', {
      'message': title,
      'description': description,
      'send_to': assignee == null || assignee.id == me?.id ? '' : assignee.username,
      'post_id': post.id,
    });
    _postChannel[post.id] = channelId;
    await loadTodos();
  }

  Future<void> todoAction(String action, String id) async {
    await api.post('$_todo/$action', {'id': id});
    await loadTodos();
  }

  // ---------------------------------------------------------------- GIF / sticker (Giphy)
  String? _giphyKey;
  Future<String?> giphyKey() async {
    if (_giphyKey != null) return _giphyKey;
    try {
      final c = (await api.get('/config/client', {'format': 'old'}) as Map).cast<String, dynamic>();
      if (c['EnableGifPicker'] == 'true') _giphyKey = c['GiphySdkKey'] as String?;
    } catch (_) {}
    return _giphyKey;
  }

  // ---------------------------------------------------------------- tệp, ảnh, liên kết của kênh
  Future<List<Map<String, dynamic>>> bookmarks(String channelId) async {
    try {
      final r = await api.get('/channels/$channelId/bookmarks') as List;
      return [for (final e in r) (e as Map).cast<String, dynamic>()];
    } catch (_) {
      return const [];
    }
  }

  /// Quét tin của kênh (tối đa [pages] trang) để lấy file, ảnh và liên kết.
  Future<List<MmPost>> scanChannel(String channelId, {int pages = 5}) async {
    final out = <MmPost>[];
    String? before;
    for (var i = 0; i < pages; i++) {
      final got = await api.posts(channelId, before: before, perPage: 200);
      out.addAll(got);
      if (got.length < 200) break;
      before = got.last.id;
    }
    return out;
  }

  bool isMuted(String channelId) => members[channelId]?.muted ?? false;

  Future<void> setMuted(String channelId, bool muted) async {
    final m = members[channelId];
    if (m == null || me == null) return;
    final props = {...(m.raw['notify_props'] as Map? ?? {}).cast<String, dynamic>(), 'mark_unread': muted ? 'mention' : 'all'};
    members[channelId] = MmMember({...m.raw, 'notify_props': props});
    notifyListeners();
    await api.updateNotify(channelId, me!.id, {'mark_unread': muted ? 'mention' : 'all'});
  }

  /// Tạo nhóm (kênh riêng tư) với các thành viên đã chọn; trả về id kênh.
  Future<String> createGroup(String name, List<String> userIds) async {
    final slug = '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '')}'
        '-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final c = MmChannel((await api.post('/channels', {
      'team_id': teamId,
      'name': slug.startsWith('-') ? 'nhom$slug' : slug,
      'display_name': name,
      'type': 'P',
    }) as Map).cast());
    for (final id in userIds.where((id) => id != me?.id)) {
      try {
        await api.post('/channels/${c.id}/members', {'user_id': id});
      } catch (_) {}
    }
    channels[c.id] = c;
    members[c.id] = MmMember({'channel_id': c.id, 'msg_count': 0, 'mention_count': 0, 'roles': 'channel_user channel_admin'});
    await _store.putChannels([c]);
    notifyListeners();
    return c.id;
  }

  Future<String> openDirect(String userId) async {
    final c = await api.directChannel(me!.id, userId);
    channels[c.id] = c;
    members.putIfAbsent(c.id, () => MmMember({'channel_id': c.id, 'msg_count': c.totalMsgCount, 'mention_count': 0}));
    await _store.putChannels([c]);
    notifyListeners();
    return c.id;
  }

  Future<File> download(MmFile f) async {
    Directory dir;
    if (Platform.isAndroid || Platform.isIOS) {
      dir = await getApplicationDocumentsDirectory();
    } else {
      dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    }
    return api.downloadFile(f, dir);
  }

  // ---------------------------------------------------------------- WebSocket
  void _onWsState(bool connected) {
    online = connected;
    notifyListeners();
    if (connected) {
      syncAll();
      final a = activeChannelId;
      if (a != null) _fetchNewer(a).then((_) => notifyListeners()).catchError((_) {});
    }
  }

  void appResumed() {
    _ws?.reconnectNow();
    if (online) syncAll();
  }

  void _onWs(WsEvent e) {
    if (e.event.startsWith(callsEventPrefix)) {
      calls.onWsEvent(e);
      return;
    }
    switch (e.event) {
      case 'posted':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        _onPosted(p);
      case 'post_edited':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        if ((p.raw['is_pinned'] == true) != pinnedIn(p.channelId).any((x) => x.id == p.id)) loadPinned(p.channelId);
        _store.putPosts([p]);
        _merge(p.channelId, [p]);
        if (latest[p.channelId]?.id == p.id) latest[p.channelId] = p;
      case 'post_deleted':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        final tomb = MmPost({...p.raw, 'delete_at': p.deleteAt > 0 ? p.deleteAt : DateTime.now().millisecondsSinceEpoch});
        _merge(p.channelId, [tomb]);
        _store.putPosts([tomb]);
        _store.latest(p.channelId).then((v) {
          latest[p.channelId] = v;
          notifyListeners();
        });
      case 'reaction_added' || 'reaction_removed':
        final r = (jsonDecode(e.data['reaction'] as String) as Map).cast<String, dynamic>();
        _applyReaction(r, e.event == 'reaction_added');
      case 'typing':
        final ch = e.channelId;
        final uid = e.data['user_id'] as String?;
        if (ch != null && uid != null && uid != me?.id) {
          (_typing[ch] ??= {})[uid] = DateTime.now();
        }
      case 'channel_viewed':
        final ch = e.data['channel_id'] as String?;
        if (ch != null) {
          final c = channels[ch];
          final m = members[ch];
          if (c != null && m != null) {
            members[ch] = MmMember({...m.raw, 'msg_count': c.totalMsgCount, 'mention_count': 0});
          }
        }
      case 'multiple_channels_viewed':
        syncAll();
      case 'channel_created' || 'direct_added' || 'group_added' || 'user_added' || 'channel_updated' ||
            'user_removed' || 'channel_deleted':
        syncAll();
      case 'user_updated':
        final u = MmUser((e.data['user'] as Map).cast());
        users[u.id] = u;
        _store.putUsers([u]);
    }
    notifyListeners();
  }

  void _onPosted(MmPost p) {
    if (scheduledIn(p.channelId).isNotEmpty && p.userId == me?.id) loadScheduled();
    _store.putPosts([p]);
    _store.removeOutbox(p.pendingId);
    _merge(p.channelId, [p]);
    _typing[p.channelId]?.remove(p.userId);
    final c = channels[p.channelId];
    if (c == null) {
      syncAll();
      return;
    }
    if (p.rootId.isEmpty || latest[p.channelId] == null || p.createAt >= (latest[p.channelId]?.createAt ?? 0)) {
      latest[p.channelId] = p;
    }
    channels[c.id] = MmChannel({...c.raw, 'last_post_at': p.createAt, 'total_msg_count': c.totalMsgCount + 1});
    final m = members[c.id];
    final mine = p.userId == me?.id;
    if (m != null && (mine || activeChannelId == c.id)) {
      members[c.id] = MmMember({...m.raw, 'msg_count': c.totalMsgCount + 1});
    } else if (m != null && !mine && _mentionsMe(p, c)) {
      members[c.id] = MmMember({...m.raw, 'mention_count': m.mentionCount + 1});
    }
    if (!mine && activeChannelId == c.id) {
      markViewed(c.id);
      otherViewedAt[c.id] = p.createAt;
    }
    if (mine) _refreshViewedBy(c.id);
  }

  bool _mentionsMe(MmPost p, MmChannel c) =>
      c.isDirect || (me != null && p.message.contains('@${me!.username}'));

  void _applyReaction(Map<String, dynamic> r, bool added) {
    final postId = r['post_id'] as String;
    for (final entry in _posts.entries) {
      final i = entry.value.indexWhere((p) => p.id == postId);
      if (i < 0) continue;
      final p = entry.value[i];
      final meta = Map<String, dynamic>.from(p.raw['metadata'] as Map? ?? {});
      final list = List<dynamic>.from(meta['reactions'] as List? ?? []);
      list.removeWhere((x) => x['user_id'] == r['user_id'] && x['emoji_name'] == r['emoji_name']);
      if (added) list.add(r);
      meta['reactions'] = list;
      final np = MmPost({...p.raw, 'metadata': meta});
      entry.value[i] = np;
      _store.putPosts([np]);
    }
  }

  void _expireTyping() {
    var changed = false;
    final now = DateTime.now();
    for (final m in _typing.values) {
      final before = m.length;
      m.removeWhere((_, t) => now.difference(t).inSeconds > 5);
      changed |= m.length != before;
    }
    final a = activeChannelId;
    if (a != null && channels[a]?.isDirect == true && online) {
      // Thỉnh thoảng hỏi lại xem người kia đã đọc chưa.
      if (now.second % 15 < 3) _refreshViewedBy(a);
    }
    if (changed) notifyListeners();
  }

  // ---------------------------------------------------------------- đăng xuất
  Future<void> logout() async {
    await api.logout();
    await TokenStore.clear();
    disposeSession();
    final dir = await getApplicationSupportDirectory();
    final db = File('${dir.path}${Platform.pathSeparator}cache_$serverKey.db');
    if (await db.exists()) await db.delete();
  }

  void disposeSession() {
    calls.hangUp();
    _ws?.close();
    _tick?.cancel();
    _viewTimer?.cancel();
    _store.close();
    api.close();
  }
}
