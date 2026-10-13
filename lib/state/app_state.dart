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
  Future<void> start() async {
    _store = await LocalStore.open('main');
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
    await syncAll();
    ready = me != null;
    notifyListeners();
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

      // Tải tin mới cho các kênh có hoạt động sau lần đồng bộ trước.
      await Future.wait(chs.map((c) async {
        final cached = latest[c.id];
        if (cached != null && c.lastPostAt <= (_lastSync[c.id] ?? 0)) return;
        await _fetchNewer(c.id);
      }));
      online = true;
      lastError = null;
      await _flushOutbox();
    } on ApiException catch (e) {
      if (e.isAuth) {
        sessionExpired = true;
      } else {
        lastError = e.message;
      }
    } catch (e) {
      online = false;
      lastError = 'Không có kết nối mạng';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Ưu tiên team cấu hình sẵn; người dùng không ở team đó thì lấy team đầu tiên.
  Future<String> _resolveTeam() async {
    final teams = (await api.get('/users/me/teams') as List).cast<Map>();
    if (teams.isEmpty) throw ApiException(403, 'Tài khoản chưa thuộc nhóm nào');
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
      if (o == me!.id) return '${me!.displayName} (Bạn)';
      return users[o]?.displayName ?? 'Người dùng';
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
      return ChatSummary(c, channelTitle(c), o, latest[c.id], unreadOf(c.id), members[c.id]?.mentionCount ?? 0);
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
    if (p.deleteAt > 0) return 'Tin nhắn đã bị xóa';
    var t = plainPreview(p.message);
    if (t.isEmpty && p.files.isNotEmpty) {
      final f = p.files.first;
      t = f.isImage ? '📷 Ảnh' : '📄 ${f.name}';
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
      list.removeWhere((x) => x.id == p.id || (p.pendingId.isNotEmpty && x.pendingId == p.pendingId));
      if (p.deleteAt == 0) list.add(p);
    }
    list.sort((a, b) => b.createAt.compareTo(a.createAt));
  }

  MmPost? findPost(String channelId, String id) =>
      _posts[channelId]?.where((p) => p.id == id).firstOrNull;

  // ---------------------------------------------------------------- gửi tin
  Future<void> send(String channelId, String text, {String rootId = '', List<String> fileIds = const []}) async {
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
      'metadata': {},
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
    await _sendOne(raw);
  }

  Future<void> discard(MmPost p) async {
    await _store.removeOutbox(p.pendingId);
    _posts[p.channelId]?.removeWhere((x) => x.pendingId == p.pendingId);
    notifyListeners();
  }

  Future<void> _flushOutbox() async {
    for (final p in await _store.outbox()) {
      await _sendOne({...p, '_send': 'sending'});
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

  Future<void> deletePost(MmPost p) async {
    try {
      await api.deletePost(p.id);
    } catch (_) {}
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
        _store.putPosts([p]);
        _merge(p.channelId, [p]);
        if (latest[p.channelId]?.id == p.id) latest[p.channelId] = p;
      case 'post_deleted':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        _store.deletePost(p.id);
        _posts[p.channelId]?.removeWhere((x) => x.id == p.id);
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
    final db = File('${dir.path}${Platform.pathSeparator}cache_main.db');
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
