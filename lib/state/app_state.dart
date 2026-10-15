import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api/mm_api.dart';
import '../calls/ringtones.dart';
import '../api/mm_ws.dart';
import '../auth/auth_service.dart';
import '../calls/call_service.dart';
import '../calls/calls_client.dart';
import '../config.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../data/servers.dart';
import '../push/push_service.dart';
import '../ui/agent_view.dart' show agentDisplayText;
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
  Timer? _statusTimer;
  bool _syncing = false;

  late final CallService calls = CallService(
    api: api,
    myId: () => me?.id ?? '',
    myName: () => me?.displayName ?? '',
    isDirectOrGroup: (id) => channels[id]?.isDirect == true || channels[id]?.isGroupDm == true,
    isDm: (id) => channels[id]?.isDirect == true,
  )
    ..addListener(notifyListeners)
    ..onCallMode = _rememberCallMode;

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
      loadCallLog();
    }
    _ws = MmSocket(token, onEvent: _onWs, onState: _onWsState)..connect();
    _tick = Timer.periodic(const Duration(seconds: 3), (_) => _expireTyping());
    // Máy chủ không đẩy trạng thái của người khác: hỏi lại mỗi phút như bản web.
    _statusTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (online) loadStatuses();
    });
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
      teamMemberIds = {for (final u in teamUsers) u.id};
      // Người đã bị xóa hẳn trên máy chủ: bỏ khỏi bộ nhớ máy (danh bạ, gợi ý @tên).
      final stale = users.keys.where((id) => !teamMemberIds.contains(id) && id != me!.id).toList();
      if (stale.isNotEmpty) {
        try {
          final found = {for (final u in await api.usersByIds(stale)) u.id};
          final gone = stale.where((id) => !found.contains(id)).toList();
          for (final id in gone) {
            users.remove(id);
          }
          await _store.deleteUsers(gone);
        } catch (_) {}
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
      loadStatuses();
      loadStatusPresets();
      loadRingtones();
      loadBlocked();
      loadAgentConfig();
      myBotIds();
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
      await loadCallLog();
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

  /// Nhóm gốc ngoài cùng của một luồng bí mật (luồng con nhiều tầng); null nếu nhóm gốc không có ở máy.
  String? topParentOf(String channelId) {
    var id = channelId;
    for (var i = 0; i < 10; i++) {
      final p = channels[id]?.subParent;
      if (p == null) return id;
      if (!channels.containsKey(p)) return null;
      id = p;
    }
    return id;
  }

  /// Tin chưa đọc của cả một luồng bí mật và mọi luồng bí mật con của nó (nhiều tầng).
  int subtreeUnread(String channelId, [int depth = 0]) {
    var n = unreadAllOf(channelId);
    if (depth > 10) return n;
    for (final c in channels.values) {
      if (c.subParent == channelId) n += subtreeUnread(c.id, depth + 1);
    }
    return n;
  }

  /// Chỗ có tin chưa đọc trong luồng của kênh (để tua tới): (id tin gốc, số chưa đọc), gồm luồng riêng
  /// (trả lời chưa đọc) và luồng bí mật con (kể cả các tầng sâu hơn).
  List<(String, int)> unreadThreadSpots(String channelId) {
    final out = <(String, int)>[];
    for (final c in channels.values) {
      if (c.subParent != channelId || c.subRoot == null) continue;
      final n = subtreeUnread(c.id);
      if (n > 0) out.add((c.subRoot!, n));
    }
    for (final p in postsOf(channelId)) {
      if (p.rootId.isNotEmpty) continue;
      final n = threadUnread(channelId, p.id);
      if (n > 0) out.add((p.id, n));
    }
    return out;
  }

  /// Tổng tin chưa đọc của kênh, kể cả trả lời trong các luồng (dùng cho số ngoài danh sách chat):
  /// tin chưa đọc ở chat chính + số trả lời trong luồng chưa đọc.
  int unreadAllOf(String channelId) {
    final c = channels[channelId];
    final m = members[channelId];
    if (c == null || m == null) return 0;
    final tr = c.totalMsgCountRoot, mr = m.msgCountRoot;
    final replies = tr != null && mr != null ? ((c.totalMsgCount - m.msgCount) - (tr - mr)).clamp(0, 9999) : 0;
    return unreadOf(channelId) + replies;
  }

  int unreadOf(String channelId) {
    final c = channels[channelId];
    final m = members[channelId];
    if (c == null || m == null) return 0;
    // Máy chủ không trừ bộ đếm khi tin bị xóa (tin bot viết dần rồi xóa, tin của tài khoản đã bị xóa):
    // tin cuối cùng còn thấy đã cũ hơn lần xem cuối thì coi như đã đọc hết.
    final last = latest[channelId];
    if (last != null && m.lastViewedAt > 0 && last.createAt <= m.lastViewedAt && last.sendState == SendState.sent) return 0;
    // Chỉ đếm tin ở chat chính: trả lời trong luồng không hiện ở chat chính (luồng có số chưa đọc riêng
    // ở nút "Luồng riêng"), nếu đếm vào thì ra số chưa đọc mà không tìm thấy tin nào.
    final tr = c.totalMsgCountRoot, mr = m.msgCountRoot;
    if (tr != null && mr != null) return (tr - mr).clamp(0, 9999);
    return (c.totalMsgCount - m.msgCount).clamp(0, 9999);
  }

  /// Danh sách chat. Luồng riêng tư không hiện riêng: nằm dưới tin gốc, số tin chưa đọc cộng vào nhóm gốc.
  /// Tin nhắn riêng với bot của plugin Todo (thông báo tiếng Anh "You have received a new Todo…"):
  /// app đã có tab Công việc và tin "📋 Việc mới" nên ẩn khỏi danh sách chat.
  bool _isPluginBotDm(MmChannel c) {
    if (!c.isDirect || me == null) return false;
    final u = users[c.otherUserId(me!.id)];
    return u != null && u.isBot && u.username == 'todo';
  }

  List<ChatSummary> get chats {
    // Số chưa đọc ngoài danh sách = tổng của chat chính, các luồng (trả lời trong luồng) và mọi luồng bí mật con
    // (nhiều tầng: cộng dồn lên nhóm gốc ngoài cùng).
    final subUnread = <String, int>{};
    final subMention = <String, int>{};
    for (final c in channels.values) {
      if (c.subParent == null) continue;
      final top = topParentOf(c.id);
      if (top == null || top == c.id) continue;
      subUnread[top] = (subUnread[top] ?? 0) + unreadAllOf(c.id);
      subMention[top] = (subMention[top] ?? 0) + (members[c.id]?.mentionCount ?? 0);
    }
    final list = channels.values.where((c) => (!c.isSub || topParentOf(c.id) == null) && !_isPluginBotDm(c)).map((c) {
      final o = me == null ? null : c.otherUserId(me!.id);
      return ChatSummary(c, channelTitle(c), o == me?.id ? null : o, latest[c.id], unreadAllOf(c.id) + (subUnread[c.id] ?? 0),
          (members[c.id]?.mentionCount ?? 0) + (subMention[c.id] ?? 0));
    }).toList();
    list.sort((a, b) => b.sortTime.compareTo(a.sortTime));
    return list;
  }

  /// Thành viên nhóm làm việc (team) ở lần đồng bộ gần nhất.
  Set<String> teamMemberIds = {};

  bool _inTeam(MmUser u) => teamMemberIds.isEmpty || teamMemberIds.contains(u.id);

  List<MmUser> get people {
    final l = users.values.where((u) => u.deleteAt == 0 && !u.isBot && u.id != me?.id && _inTeam(u)).toList();
    l.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return l;
  }

  String previewText(MmPost? p) {
    if (p == null) return '';
    if (p.isRecalled) return tr('Tin nhắn đã được thu hồi');
    // Tin hệ thống của plugin Calls ("X started a call"): hiện tiếng Việt.
    if (p.isCall) return tr('📞 {0} đã bắt đầu cuộc gọi', [users[p.userId]?.displayName ?? tr('Ai đó')]);
    var t = plainPreview(p.isCallRing ? p.callRingText : p.message);
    if (t.isEmpty && p.files.isNotEmpty) {
      final f = p.files.first;
      t = f.isImage ? tr('📷 Ảnh') : '📄 ${f.name}';
    }
    return t;
  }

  // ---------------------------------------------------------------- một cuộc chat
  List<MmPost> postsOf(String channelId) {
    final l = _posts[channelId] ?? const <MmPost>[];
    // Tin của người mình đã chặn không hiện. Tin bot tự xóa (trợ lý AI thay tin đang viết bằng tin cuối)
    // không để lại dòng "Tin nhắn đã được thu hồi".
    return l
        .where((p) => !blocked.contains(p.userId) && !(p.isRecalled && _isBotPost(p)) && !_resolvedApproval(p) && !_isTodoBotPost(p))
        .toList();
  }

  /// Tin tiếng Anh của plugin Todo ("… sent … a todo attached to this thread"): app đã có tin "📋 Việc mới" riêng
  /// nên ẩn đi cho khỏi trùng.
  bool _isTodoBotPost(MmPost p) {
    if (p.type.startsWith('custom_todo')) return true;
    final u = users[p.userId];
    if (u != null && u.isBot && u.username == 'todo') return true;
    // Bot plugin thường chưa có trong danh sách người dùng của app: nhận theo props + nội dung.
    return p.props['from_plugin'] == 'true' && RegExp(r'\bsent\b.*\ba todo\b').hasMatch(p.message);
  }

  /// Yêu cầu duyệt của trợ lý AI đã xử lý xong (đã cho phép / từ chối / hết hạn): ẩn khỏi chat cho gọn,
  /// các bước đã chạy vẫn xem được trong dòng trạng thái của câu trả lời.
  bool _resolvedApproval(MmPost p) {
    final a = (p.props['flygo_agent_approval'] as Map?);
    // Chỉ ẩn tin chỉ có yêu cầu duyệt; tin câu trả lời có gắn yêu cầu duyệt thì vẫn hiện.
    if (a == null || p.props.containsKey('flygo_agent_message') || p.props.containsKey('flygo_agent')) return false;
    return (a['status'] as String? ?? 'pending') != 'pending';
  }

  bool _isBotPost(MmPost p) =>
      users[p.userId]?.isBot == true ||
      p.props['from_bot'] == 'true' ||
      p.props.containsKey('flygo_agent') ||
      p.props.containsKey('flygo_agent_message');

  // ---------------------------------------------------------------- chủ đề
  /// Câu trả lời trong chủ đề của từng tin gốc (đã tải), mới nhất cuối.
  final Map<String, List<MmPost>> _threads = {};

  /// Các câu trả lời trong chủ đề của tin [rootId] đang có trên máy (kể cả trả lời trong chat).
  List<MmPost> threadReplies(String channelId, String rootId) {
    final byId = <String, MmPost>{
      for (final p in _threads[rootId] ?? const <MmPost>[]) p.id: p,
      for (final p in postsOf(channelId)) if (p.rootId == rootId) p.id: p,
    };
    final l = byId.values.where((p) => !p.isEditHistory && !(p.isRecalled && _isBotPost(p)) && !_resolvedApproval(p)).toList()
      ..sort((a, b) => a.createAt.compareTo(b.createAt));
    return l;
  }

  /// Tóm tắt chủ đề dưới tin gốc: số câu trả lời trong chủ đề, người trả lời gần nhất, thời điểm.
  ({int count, List<String> users, int lastAt})? threadSummary(String channelId, String rootId) {
    final l = threadReplies(channelId, rootId).where((p) => p.inThread).toList();
    if (l.isEmpty) return null;
    final users = <String>[];
    for (final p in l.reversed) {
      if (!users.contains(p.userId)) users.add(p.userId);
    }
    return (count: l.length, users: users, lastAt: l.last.createAt);
  }

  // ---------------------------------------------------------------- tab "Luồng riêng"
  /// Luồng riêng tư (kênh tách từ một tin) mình đang ở trong.
  List<MmChannel> get privateThreads =>
      channels.values.where((c) => c.isSub && c.deleteAt == 0).toList()..sort((a, b) => b.lastPostAt.compareTo(a.lastPostAt));

  /// Luồng công việc riêng (chủ đề trả lời dưới một tin) mình đang theo dõi, mới nhất trước.
  List<({MmPost root, int replies, int lastAt})> workThreads = [];
  bool workThreadsLoading = false;

  Future<void> loadWorkThreads() async {
    if (me == null || teamId == null || workThreadsLoading) return;
    workThreadsLoading = true;
    notifyListeners();
    try {
      final r = (await api.get('/users/${me!.id}/teams/$teamId/threads', {'per_page': '40'}) as Map).cast<String, dynamic>();
      final list = <({MmPost root, int replies, int lastAt})>[];
      for (final t in (r['threads'] as List? ?? const [])) {
        final m = (t as Map).cast<String, dynamic>();
        final root = MmPost((m['post'] as Map).cast());
        if (!channels.containsKey(root.channelId) || root.isRecalled) continue;
        list.add((root: root, replies: (m['reply_count'] as num?)?.toInt() ?? 0, lastAt: (m['last_reply_at'] as num?)?.toInt() ?? 0));
      }
      workThreads = list;
      notifyListeners();
      // Tải câu trả lời để biết luồng nào đã đóng (mỗi lần vài luồng).
      for (var i = 0; i < list.length; i += 6) {
        await Future.wait([for (final t in list.skip(i).take(6)) if (!_threads.containsKey(t.root.id)) loadThread(t.root.id)]);
      }
    } catch (e) {
      debugPrint('[threads] $e');
    } finally {
      workThreadsLoading = false;
      notifyListeners();
    }
  }

  /// Luồng công việc riêng đã đóng: tin đánh dấu đóng/mở gần nhất trong luồng là "đóng".
  bool isThreadClosed(String channelId, String rootId) {
    final marks = threadReplies(channelId, rootId).where((p) => p.props.containsKey('flygo_thread_closed'));
    return marks.isNotEmpty && marks.last.props['flygo_thread_closed'] == true;
  }

  /// Đóng / mở lại luồng công việc riêng: gửi một tin đánh dấu vào luồng (bot đọc mốc này để dừng).
  Future<void> setThreadClosed(String channelId, String rootId, bool closed) async {
    await send(channelId, closed ? tr('🔒 Đã đóng luồng') : tr('🔓 Đã mở lại luồng'),
        rootId: rootId, replyKind: 'thread', props: {'flygo_thread_closed': closed});
    final saved = postsOf(channelId).where((p) => p.rootId == rootId).toList();
    _threads[rootId] = {for (final p in [...?_threads[rootId], ...saved]) p.id: p}.values.toList();
    notifyListeners();
  }

  /// Đóng / mở lại luồng riêng tư: thêm/bỏ mốc [flygo-closed] trong mô tả kênh và gửi tin thông báo.
  Future<void> setPrivateThreadClosed(MmChannel c, bool closed) async {
    final base = c.purpose.replaceAll('[flygo-closed]', '').trim();
    final purpose = closed ? '$base [flygo-closed]'.trim() : base;
    final updated = MmChannel((await api.put('/channels/${c.id}/patch', {'purpose': purpose}) as Map).cast());
    channels[c.id] = updated;
    await _store.putChannels([updated]);
    notifyListeners();
    await send(c.id, closed ? tr('🔒 Đã đóng luồng') : tr('🔓 Đã mở lại luồng'), props: {'flygo_thread_closed': closed});
  }

  /// Tải cả luồng trả lời của tin gốc từ máy chủ.
  Future<MmPost?> loadThread(String rootId) async {
    try {
      final r = (await api.get('/posts/$rootId/thread') as Map).cast<String, dynamic>();
      final posts = (r['posts'] as Map).cast<String, dynamic>().values.map((e) => MmPost((e as Map).cast())).toList();
      final root = posts.where((p) => p.id == rootId).firstOrNull;
      _threads[rootId] = posts.where((p) => p.rootId == rootId).toList();
      await _store.putPosts(posts);
      notifyListeners();
      return root;
    } catch (_) {
      return null;
    }
  }

  Future<void> openChannel(String channelId) async {
    activeChannelId = channelId;
    loadModeration(channelId);
    PushService.activeChannel = channelId;
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
    if (activeChannelId == channelId) {
      activeChannelId = null;
      PushService.activeChannel = null;
    }
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

  /// Ai đang soạn tin ở chat chính ([rootId] rỗng) hoặc trong luồng của tin [rootId].
  List<String> typingIn(String channelId, [String rootId = '']) =>
      (_typing[_typingKey(channelId, rootId)]?.keys ?? const <String>[]).map((u) => users[u]?.displayName ?? '').toList();

  static String _typingKey(String channelId, String rootId) => rootId.isEmpty ? channelId : '$channelId:$rootId';

  void notifyTyping(String channelId, [String rootId = '']) => _ws?.sendTyping(channelId, rootId);

  void _merge(String channelId, List<MmPost> incoming) {
    final list = _posts[channelId];
    if (list == null) return;
    for (final p in incoming) {
      if (p.isEditHistory) continue;
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
  /// Tag trợ lý AI (mình được gọi) chưa có trong kênh: thêm bot vào kênh trước khi gửi để bot nhận được tin.
  Future<void> _addTaggedBots(String channelId, String text) async {
    if (!text.contains('@')) return;
    final names = RegExp(r'@([a-z0-9._-]+)', caseSensitive: false).allMatches(text).map((m) => m.group(1)!.toLowerCase()).toSet();
    final bots = users.values.where((u) => u.isBot && names.contains(u.username.toLowerCase())).toList();
    if (bots.isEmpty) return;
    try {
      final mine = await myBotIds();
      final inChannel = {for (final u in await channelUsers(channelId)) u.id};
      for (final b in bots) {
        if (inChannel.contains(b.id) || !canCallBot(b, mine)) continue;
        try {
          await addMember(channelId, b.id);
        } catch (e) {
          debugPrint('[bots] add ${b.username}: $e');
        }
      }
    } catch (_) {}
  }

  /// Gửi tin; trả về tin đã lưu trên máy chủ (null nếu chưa gửi được, tin nằm trong hàng chờ).
  Future<MmPost?> send(String channelId, String text,
      {String rootId = '',
      List<String> fileIds = const [],
      String priority = '',
      bool requestAck = false,
      bool burnOnRead = false,
      String replyKind = '',
      Map<String, dynamic>? props}) async {
    if (me == null) return null;
    await _addTaggedBots(channelId, text);
    if (rootId.isNotEmpty && replyKind.isNotEmpty) props = {...?props, 'flygo_reply': replyKind};
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
    return _sendOne(local);
  }

  Future<MmPost?> _sendOne(Map<String, dynamic> local) async {
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
      notifyListeners();
      return saved;
    } catch (e) {
      final failed = {...local, '_send': 'failed'};
      await _store.putOutbox(failed);
      _merge(channelId, [MmPost(failed)]);
      if (e is! ApiException) online = false;
    }
    notifyListeners();
    return null;
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
      {String text = '', String rootId = '', String replyKind = ''}) async {
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
      if (rootId.isNotEmpty && replyKind.isNotEmpty) 'props': {'flygo_reply': replyKind},
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
        final got = await api.uploadPath(channelId, f['name'] as String, path);
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
        if (local['props'] != null) 'props': local['props'],
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
      await send(cid, p.message, fileIds: ids, props: {'flygo_forwarded': true});
    }
  }

  /// Chuyển tiếp một số ảnh/tệp (đã có trên máy chủ hoặc trên máy) sang nhiều cuộc trò chuyện.
  Future<void> forwardFiles(List<String> channelIds, {List<MmFile> files = const [], List<String> localPaths = const []}) async {
    for (final cid in channelIds) {
      final ids = <String>[];
      for (final f in files) {
        ids.addAll(await api.uploadFile(cid, f.name, await api.fileBytes(f.id)));
      }
      for (final path in localPaths) {
        final got = await api.uploadFile(cid, path.split(Platform.pathSeparator).last, await File(path).readAsBytes());
        for (final id in got) {
          _localById[id] = path;
        }
        ids.addAll(got);
      }
      await send(cid, '', fileIds: ids, props: {'flygo_forwarded': true});
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

  // ---------------------------------------------------------------- đã xem luồng công việc riêng
  /// id tin gốc → lúc xem luồng gần nhất (lưu trên máy).
  final Map<String, int> _threadSeen = {};
  bool _threadSeenLoaded = false;

  Future<void> _loadThreadSeen() async {
    if (_threadSeenLoaded) return;
    _threadSeenLoaded = true;
    final m = await _store.meta<Map>('thread_seen');
    if (m != null) _threadSeen.addAll(m.map((k, v) => MapEntry(k as String, (v as num).toInt())));
  }

  /// Đánh dấu đã xem luồng (mở trang luồng / có tin mới khi đang mở).
  void markThreadSeen(String rootId) {
    _threadSeen[rootId] = DateTime.now().millisecondsSinceEpoch;
    _store.setMeta('thread_seen', _threadSeen);
    notifyListeners();
  }

  /// Số câu trả lời của người khác trong luồng mà mình chưa xem.
  int threadUnread(String channelId, String rootId) {
    if (!_threadSeenLoaded) {
      _loadThreadSeen().then((_) => notifyListeners());
      return 0;
    }
    // Chưa mở luồng lần nào: tính từ lần xem kênh gần nhất.
    final seen = _threadSeen[rootId] ?? members[channelId]?.lastViewedAt ?? 0;
    return threadReplies(channelId, rootId).where((p) => p.inThread && p.userId != me?.id && p.createAt > seen).length;
  }

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

  /// Yêu cầu khung chat cuộn tới một tin (vd. bấm vào tin đã ghim): (id kênh, id tin).
  final jumpRequest = ValueNotifier<(String, String)?>(null);
  void requestJump(String channelId, String postId) {
    jumpRequest.value = null;
    jumpRequest.value = (channelId, postId);
  }

  Future<void> setPinned(MmPost p, bool pin) async {
    await api.post('/posts/${p.id}/${pin ? 'pin' : 'unpin'}', null);
    _merge(p.channelId, [MmPost({...p.raw, 'is_pinned': pin})]);
    await loadPinned(p.channelId);
  }

  /// Có quyền quản lý thành viên kênh không (quản trị hệ thống hoặc quản trị kênh).
  // ---------------------------------------------------------------- quyền gửi tin trong kênh
  /// Kênh chỉ người được cấp quyền mới gửi tin (moderation create_post của thành viên = false).
  final Map<String, bool> postLocked = {};

  Future<void> loadModeration(String channelId) async {
    final c = channels[channelId];
    if (c == null || c.isDirect || c.isGroupDm) return;
    try {
      final l = await api.get('/channels/$channelId/moderations') as List;
      final cp = l.cast<Map>().where((m) => m['name'] == 'create_post').firstOrNull;
      final v = ((cp?['roles'] as Map?)?['members'] as Map?)?['value'];
      final locked = v == false;
      if (postLocked[channelId] != locked) {
        postLocked[channelId] = locked;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Bật/tắt "chỉ người được cấp quyền mới gửi tin" (quản trị kênh, quản trị viên luôn gửi được).
  Future<void> setPostLocked(String channelId, bool locked) async {
    await api.put('/channels/$channelId/moderations/patch', [
      {
        'name': 'create_post',
        'roles': {'members': !locked, 'guests': !locked},
      }
    ]);
    postLocked[channelId] = locked;
    notifyListeners();
  }

  /// Cấp / bỏ quyền gửi tin cho một thành viên = đặt làm quản trị kênh.
  Future<void> setPostRight(String channelId, String userId, bool allow) async {
    await api.put('/channels/$channelId/members/$userId/schemeRoles', {'scheme_user': true, 'scheme_admin': allow});
    _channelMembers.remove(channelId);
    if (userId == me?.id) await syncAll();
    notifyListeners();
  }

  /// Thành viên là quản trị kênh (được gửi tin khi kênh khoá gửi tin).
  Future<Set<String>> channelAdmins(String channelId) async {
    final out = <String>{};
    try {
      for (var page = 0; page < 10; page++) {
        final l = await api.get('/channels/$channelId/members', {'page': '$page', 'per_page': '200'}) as List;
        for (final m in l.cast<Map>()) {
          if ('${m['roles']}'.contains('channel_admin') || m['scheme_admin'] == true) out.add(m['user_id'] as String);
        }
        if (l.length < 200) break;
      }
    } catch (_) {}
    return out;
  }

  /// Mình gửi tin được trong kênh này không.
  bool canPost(String channelId) => postLocked[channelId] != true || canManage(channelId);

  bool canManage(String channelId) {
    final roles = '${me?.raw['roles'] ?? ''} ${members[channelId]?.raw['roles'] ?? ''}';
    return roles.contains('system_admin') || roles.contains('channel_admin') || roles.contains('team_admin');
  }

  /// Người và bot có thể thêm vào kênh (người trước, bot sau).
  List<MmUser> get peopleAndBots {
    final l = users.values.where((u) => u.deleteAt == 0 && u.id != me?.id && (u.isBot || _inTeam(u))).toList();
    l.sort((a, b) => a.isBot != b.isBot ? (a.isBot ? 1 : -1) : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return l;
  }

  Future<void> addMember(String channelId, String userId) async {
    try {
      await api.post('/channels/$channelId/members', {'user_id': userId});
    } catch (_) {
      // Bot chưa ở trong nhóm làm việc (team): thêm vào team trước rồi thử lại.
      if (teamId == null) rethrow;
      await api.post('/teams/$teamId/members', {'team_id': teamId, 'user_id': userId});
      await api.post('/channels/$channelId/members', {'user_id': userId});
    }
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

  // ---------------------------------------------------------------- lịch sử cuộc gọi
  /// Lịch sử cuộc gọi dựng từ tin `custom_calls` (plugin Calls) đã có trong bộ nhớ máy — máy chủ không có
  /// API lọc tin theo loại, còn đồng bộ thì đã tải tin mới của mọi kênh có hoạt động nên không phải gọi thêm.
  List<CallLogEntry> callLog = [];
  /// Số cuộc gọi nhỡ chưa xem (chấm đỏ trên tab Lịch sử).
  int missedCalls = 0;
  int? _callsSeenAt;
  Timer? _callLogTimer;
  bool _callLogLoaded = false;

  void _callLogSoon() {
    _callLogTimer?.cancel();
    _callLogTimer = Timer(const Duration(seconds: 1), loadCallLog);
  }

  Future<void> loadCallLog() async {
    final my = me?.id;
    if (my == null) return;
    List<MmPost> posts;
    try {
      posts = await _store.callPosts();
    } catch (_) {
      return;
    }
    _callsSeenAt ??= await _store.meta<int>('calls_seen_at');
    if (_callsSeenAt == null) {
      // Lần đầu: không tính các cuộc gọi nhỡ cũ.
      _callsSeenAt = DateTime.now().millisecondsSinceEpoch;
      await _store.setMeta('calls_seen_at', _callsSeenAt);
    }
    final modes = await _store.meta<List>('call_modes') ?? const [];
    final rings = [for (final p in posts) if (p.isCallRing) p];
    final list = <CallLogEntry>[];
    for (final p in posts) {
      if (!p.isCall) continue;
      final c = channels[p.channelId];
      if (c == null) continue;
      final start = p.callStart;
      final ring = rings
          .where((r) => r.channelId == p.channelId && (r.createAt - start).abs() < 90000)
          .firstOrNull;
      final small = c.isDirect || c.isGroupDm;
      // Gọi video / cuộc họp: tin đổ chuông nhóm có ghi; gọi 1-1 thì nhớ trên máy lúc gọi / nghe.
      final mode = modes
          .whereType<Map>()
          .where((m) => m['ch'] == p.channelId && ((m['at'] as num? ?? 0) - start).abs() < 120000)
          .firstOrNull;
      final meeting = !small && ring == null;
      final video = ring != null ? ring.callRingVideo : mode?['video'] == true;
      final caller = ring?.userId ?? p.userId;
      final end = p.callEnd;
      final joined = (p.props['participants'] as List?)?.contains(my);
      final outgoing = caller == my;
      final missed = !outgoing && !meeting && end != null && joined == false && mode == null;
      list.add(CallLogEntry(
        post: p,
        channelId: p.channelId,
        callerId: caller,
        startAt: start,
        endAt: end,
        outgoing: outgoing,
        missed: missed,
        video: video,
        meeting: meeting,
      ));
    }
    callLog = list;
    missedCalls = list.where((e) => e.missed && e.startAt > _callsSeenAt!).length;
    _callLogLoaded = true;
    notifyListeners();
  }

  bool get callLogLoaded => _callLogLoaded;

  /// Đã mở trang Lịch sử: xoá chấm đỏ cuộc gọi nhỡ.
  Future<void> markCallsSeen() async {
    _callsSeenAt = DateTime.now().millisecondsSinceEpoch;
    if (missedCalls != 0) {
      missedCalls = 0;
      notifyListeners();
    }
    await _store.setMeta('calls_seen_at', _callsSeenAt);
  }

  /// Nhớ cuộc gọi trên máy này là gọi video / cuộc họp (tin cuộc gọi của máy chủ không ghi).
  Future<void> _rememberCallMode(String channelId, {required bool video, required bool meeting}) async {
    final list = [...(await _store.meta<List>('call_modes') ?? const [])];
    list.add({'ch': channelId, 'at': DateTime.now().millisecondsSinceEpoch, 'video': video, 'meeting': meeting});
    while (list.length > 300) {
      list.removeAt(0);
    }
    await _store.setMeta('call_modes', list);
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

  /// Mức thông báo của kênh: 'default' | 'all' | 'mention' | 'none' (theo cài đặt push của Mattermost).
  String notifyLevel(String channelId) =>
      ((members[channelId]?.raw['notify_props'] as Map?)?['push'] as String?) ?? 'default';

  Future<void> setNotifyLevel(String channelId, String level) async {
    final m = members[channelId];
    if (m == null || me == null) return;
    final change = {'push': level, 'desktop': level};
    members[channelId] = MmMember({...m.raw, 'notify_props': {...(m.raw['notify_props'] as Map? ?? {}).cast<String, dynamic>(), ...change}});
    notifyListeners();
    await api.updateNotify(channelId, me!.id, change);
  }

  /// Đổi ảnh nhóm: tải ảnh lên kênh (kèm một tin báo để ảnh được lưu lâu dài), rồi ghi mốc vào mô tả.
  /// Đổi loại nhóm: công khai (O) ↔ riêng tư (P).
  Future<void> setChannelPrivacy(String channelId, bool public) async {
    final updated = MmChannel((await api.put('/channels/$channelId/privacy', {'privacy': public ? 'O' : 'P'}) as Map).cast());
    channels[channelId] = updated;
    await _store.putChannels([updated]);
    notifyListeners();
  }

  /// Đổi tên nhóm (tên hiển thị của kênh).
  Future<void> renameChannel(String channelId, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final updated = MmChannel((await api.put('/channels/$channelId/patch', {'display_name': n.length > 64 ? n.substring(0, 64) : n}) as Map).cast());
    channels[channelId] = updated;
    await _store.putChannels([updated]);
    notifyListeners();
  }

  Future<void> setChannelIcon(String channelId, String name, Uint8List bytes) async {
    final c = channels[channelId];
    if (c == null || me == null) return;
    final ids = await api.uploadFile(channelId, name, bytes);
    await api.createPost({
      'channel_id': channelId,
      'message': tr('🖼 {0} đã đổi ảnh nhóm', [me!.displayName]),
      'file_ids': ids,
      'props': {'flygo_channel_icon': true},
    });
    final markers = c.purposeMarkers.replaceAll(RegExp(r'\[flygo-icon \w+\]'), '').trim();
    final purpose = '${c.purposeText} $markers [flygo-icon ${ids.first}]'.trim();
    final updated = MmChannel((await api.put('/channels/$channelId/patch', {'purpose': purpose}) as Map).cast());
    channels[channelId] = updated;
    await _store.putChannels([updated]);
    notifyListeners();
  }

  /// Đổi ảnh đại diện của mình hoặc của bot của mình.
  /// Đổi tên hiển thị (cả tên ghi vào first_name, last_name để trống: hiện đúng như gõ) và/hoặc tên người dùng (@username).
  Future<void> renameMe({String? name, String? username}) async {
    if (me == null) return;
    final patch = <String, dynamic>{};
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) patch.addAll({'first_name': n.length > 64 ? n.substring(0, 64) : n, 'last_name': ''});
    final un = username?.trim().toLowerCase() ?? '';
    if (un.isNotEmpty && un != me!.username) patch['username'] = un;
    if (patch.isEmpty) return;
    final u = MmUser((await api.put('/users/${me!.id}/patch', patch) as Map).cast());
    users[u.id] = u;
    me = u;
    await _store.putUsers([u]);
    notifyListeners();
  }

  /// Tải lại thông tin một người dùng / bot (sau khi đổi tên...).
  Future<void> refreshUser(String userId) async {
    final u = MmUser((await api.get('/users/$userId') as Map).cast());
    users[u.id] = u;
    if (u.id == me?.id) me = u;
    await _store.putUsers([u]);
    notifyListeners();
  }

  Future<void> setUserImage(String userId, String name, Uint8List bytes) async {
    await api.uploadUserImage(userId, name, bytes);
    final u = MmUser((await api.get('/users/$userId') as Map).cast());
    users[u.id] = u;
    if (u.id == me?.id) me = u;
    await _store.putUsers([u]);
    notifyListeners();
  }

  /// Sửa mô tả kênh.
  Future<void> setPurpose(String channelId, String purpose) async {
    // Giữ các mốc kỹ thuật ([flygo-sub …], [flygo-icon …]) trong mô tả.
    final old = channels[channelId];
    if (old != null && old.purposeMarkers.isNotEmpty) purpose = '$purpose ${old.purposeMarkers}'.trim();
    final c = MmChannel((await api.put('/channels/$channelId/patch', {'purpose': purpose}) as Map).cast());
    channels[channelId] = c;
    await _store.putChannels([c]);
    notifyListeners();
  }

  Future<void> setMuted(String channelId, bool muted) async {
    final m = members[channelId];
    if (m == null || me == null) return;
    final props = {...(m.raw['notify_props'] as Map? ?? {}).cast<String, dynamic>(), 'mark_unread': muted ? 'mention' : 'all'};
    members[channelId] = MmMember({...m.raw, 'notify_props': props});
    notifyListeners();
    await api.updateNotify(channelId, me!.id, {'mark_unread': muted ? 'mention' : 'all'});
  }

  /// Máy tính: mở cuộc trò chuyện trong một cửa sổ riêng (một tiến trình app khác).
  Future<void> openInWindow(String channelId) async {
    await Process.start(Platform.resolvedExecutable, ['--chat=$channelId'], mode: ProcessStartMode.detached);
  }

  /// Tạo nhóm với các thành viên đã chọn; [public]: kênh công khai (ai trong team
  /// cũng tìm và vào được), ngược lại là kênh riêng tư. Trả về id kênh.
  Future<String> createGroup(String name, List<String> userIds, {bool public = false}) async {
    final slug = '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '')}'
        '-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final c = MmChannel((await api.post('/channels', {
      'team_id': teamId,
      'name': slug.startsWith('-') ? 'nhom$slug' : slug,
      'display_name': name,
      'type': public ? 'O' : 'P',
    }) as Map).cast());
    for (final id in userIds.where((id) => id != me?.id)) {
      try {
        // addMember: bot chưa ở team thì thêm vào team trước.
        await addMember(c.id, id);
      } catch (_) {}
    }
    channels[c.id] = c;
    // Kênh công khai mới: mặc định không ai gửi tin, phải được cấp quyền (quản trị kênh) mới chat được.
    if (public) {
      try {
        await setPostLocked(c.id, true);
      } catch (e) {
        debugPrint('[channel] lock posting: $e');
      }
    }
    members[c.id] = MmMember({'channel_id': c.id, 'msg_count': 0, 'mention_count': 0, 'roles': 'channel_user channel_admin'});
    await _store.putChannels([c]);
    notifyListeners();
    return c.id;
  }

  // ---------------------------------------------------------------- luồng riêng (kênh riêng tư tách từ nhóm)
  /// Các luồng riêng của nhóm [parentId] mà mình là thành viên.
  List<MmChannel> subChannelsOf(String parentId) =>
      channels.values.where((c) => c.subParent == parentId && c.deleteAt == 0).toList()
        ..sort((a, b) => b.lastPostAt.compareTo(a.lastPostAt));

  /// Luồng riêng tách từ tin [postId] (nếu mình là thành viên).
  MmChannel? subChannelForPost(String postId) => channels.values.where((c) => c.subRoot == postId && c.deleteAt == 0).firstOrNull;

  /// Tạo luồng riêng từ một tin: kênh riêng tư chỉ gồm người được chọn (có thể kèm trợ lý AI),
  /// tin gốc được chép vào làm tin đầu tiên. Trả về id kênh mới.
  Future<String> createSubChannel(MmChannel parent, MmPost root, String name, List<String> userIds) async {
    final slug = 'luong-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final c = MmChannel((await api.post('/channels', {
      'team_id': teamId,
      'name': slug,
      'display_name': name.length > 64 ? name.substring(0, 64) : name,
      'type': 'P',
      'purpose': '[flygo-sub parent=${parent.id} root=${root.id}]',
    }) as Map).cast());
    for (final id in userIds.where((id) => id != me?.id)) {
      try {
        await api.post('/channels/${c.id}/members', {'user_id': id});
      } catch (_) {}
    }
    channels[c.id] = c;
    members[c.id] = MmMember({'channel_id': c.id, 'msg_count': 0, 'mention_count': 0, 'roles': 'channel_user channel_admin'});
    await _store.putChannels([c]);
    // Chép tin gốc (kèm tệp) vào làm tin đầu tiên.
    final ids = <String>[];
    for (final f in root.files) {
      try {
        ids.addAll(await api.uploadFile(c.id, f.name, await api.fileBytes(f.id)));
      } catch (_) {}
    }
    final who = users[root.userId]?.displayName ?? '';
    await send(c.id, tr('📌 Từ {0} · {1}:\n{2}', [channelTitle(parent), who, root.message]),
        fileIds: ids, props: {'flygo_sub_origin': {'channel_id': parent.id, 'post_id': root.id}});
    notifyListeners();
    return c.id;
  }

  /// Gửi kết luận từ luồng riêng về nhóm gốc (trả lời ngay dưới tin gốc, hiện ở chat chính).
  /// Bot này là trợ lý AI của mình (đã tải danh sách bot của mình).
  bool isMyBot(String userId) => _myBotIds?.contains(userId) ?? false;

  /// "Báo ra ngoài": gửi y hệt một tin trong luồng riêng tư (chữ + tệp) ra nhóm ngoài của luồng.
  Future<void> reportToParent(MmChannel sub, MmPost p) async {
    final parent = sub.subParent;
    if (parent == null) return;
    final ids = <String>[];
    for (final f in p.files) {
      ids.addAll(await api.uploadFile(parent, f.name, await api.fileBytes(f.id)));
    }
    final text = agentDisplayText(p);
    await send(parent, text, fileIds: ids, props: {'flygo_sub_report': {'channel_id': sub.id, 'post_id': p.id}});
  }

  /// "Gửi ra nhóm chính": gửi y hệt một tin trong luồng (chữ + tệp) thành tin mới ở chat chính của nhóm.
  Future<void> shareThreadPost(MmPost p) async {
    final ids = <String>[];
    for (final f in p.files) {
      ids.addAll(await api.uploadFile(p.channelId, f.name, await api.fileBytes(f.id)));
    }
    await send(p.channelId, agentDisplayText(p), fileIds: ids, props: {'flygo_thread_share': {'root_id': p.rootId, 'post_id': p.id}});
  }

  Future<void> sendConclusion(MmChannel sub, String text) async {
    final parent = sub.subParent;
    if (parent == null) return;
    await api.createPost({
      'channel_id': parent,
      'root_id': sub.subRoot ?? '',
      'message': tr('🔒 Kết luận từ luồng riêng "{0}":\n{1}', [sub.displayName, text]),
      'props': {'flygo_sub_conclusion': sub.id},
    });
  }

  // ---------------------------------------------------------------- trạng thái
  /// Trạng thái hoạt động: online | away | dnd | offline.
  final Map<String, String> statuses = {};

  Future<void> loadStatuses() async {
    final ids = {...users.keys}..removeWhere((id) => users[id]?.isBot == true);
    final list = ids.toList();
    try {
      for (var i = 0; i < list.length; i += 200) {
        final r = await api.post('/users/status/ids', list.skip(i).take(200).toList()) as List;
        for (final e in r) {
          statuses[(e as Map)['user_id'] as String] = e['status'] as String;
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  String statusOf(String userId) => statuses[userId] ?? 'offline';

  /// Đổi trạng thái hoạt động của mình.
  Future<void> setMyStatus(String status) async {
    if (me == null) return;
    statuses[me!.id] = status;
    notifyListeners();
    await api.put('/users/${me!.id}/status', {'user_id': me!.id, 'status': status});
  }

  /// Trạng thái tùy chỉnh (biểu tượng + chữ) của một người, null nếu không có hoặc đã hết hạn.
  ({String emoji, String text})? customStatusOf(String userId) {
    final raw = (users[userId]?.raw['props'] as Map?)?['customStatus'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final exp = m['expires_at'] as String?;
      if (exp != null && exp.isNotEmpty && !exp.startsWith('0001')) {
        final t = DateTime.tryParse(exp);
        if (t != null && t.isBefore(DateTime.now())) return null;
      }
      final text = m['text'] as String? ?? '';
      final emoji = m['emoji'] as String? ?? '';
      if (text.isEmpty && emoji.isEmpty) return null;
      return (emoji: emoji, text: text);
    } catch (_) {
      return null;
    }
  }

  Future<void> setCustomStatus(String emoji, String text) async {
    if (me == null) return;
    _patchMyCustomStatus(jsonEncode({'emoji': emoji, 'text': text, 'duration': ''}));
    await api.put('/users/me/status/custom', {'emoji': emoji, 'text': text});
  }

  Future<void> clearCustomStatus() async {
    if (me == null) return;
    _patchMyCustomStatus('');
    await api.delete('/users/me/status/custom');
  }

  void _patchMyCustomStatus(String value) {
    final props = {...(me!.raw['props'] as Map? ?? {}).cast<String, dynamic>(), 'customStatus': value};
    me = MmUser({...me!.raw, 'props': props});
    users[me!.id] = me!;
    notifyListeners();
  }

  /// Danh sách trạng thái chọn nhanh của mình, lưu trong tùy chọn tài khoản trên máy chủ
  /// (dùng chung mọi thiết bị).
  List<({String emoji, String text})> statusPresets = defaultStatusPresets;

  static List<({String emoji, String text})> get defaultStatusPresets => [
        (emoji: 'calendar', text: tr('Đang họp')),
        (emoji: 'car', text: tr('Đang di chuyển')),
        (emoji: 'fork_and_knife', text: tr('Đang ăn trưa')),
        (emoji: 'house', text: tr('Làm việc tại nhà')),
        (emoji: 'face_with_thermometer', text: tr('Nghỉ ốm')),
        (emoji: 'palm_tree', text: tr('Nghỉ phép')),
      ];

  Future<void> loadStatusPresets() async {
    if (me == null) return;
    try {
      final r = (await api.get('/users/${me!.id}/preferences/flygo_chat/name/status_presets') as Map).cast<String, dynamic>();
      final list = jsonDecode(r['value'] as String) as List;
      statusPresets = [
        for (final e in list) (emoji: (e as Map)['emoji'] as String? ?? '', text: e['text'] as String? ?? ''),
      ];
      notifyListeners();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- cấu hình trợ lý AI (mô hình, mức suy nghĩ)
  /// id bot → {model, effort} đã chọn gần nhất (preferences flygo_chat/agent_config, dùng chung mọi thiết bị).
  Map<String, Map<String, String>> agentConfig = {};

  Future<void> loadAgentConfig() async {
    if (me == null) return;
    try {
      final r = (await api.get('/users/${me!.id}/preferences/flygo_chat/name/agent_config') as Map).cast<String, dynamic>();
      agentConfig = {
        for (final e in (jsonDecode(r['value'] as String) as Map).entries) e.key as String: (e.value as Map).cast<String, String>(),
      };
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAgentConfig(String botId, String model, String effort) async {
    if (me == null) return;
    agentConfig[botId] = {'model': model, 'effort': effort};
    notifyListeners();
    await api.put('/users/${me!.id}/preferences', [
      {'user_id': me!.id, 'category': 'flygo_chat', 'name': 'agent_config', 'value': jsonEncode(agentConfig)}
    ]);
  }

  // ---------------------------------------------------------------- bố cục máy tính
  /// Độ rộng các cột (kéo thả trên máy tính), lưu trên máy.
  Future<Map<String, double>> loadLayout() async {
    final m = await _store.meta<Map>('layout_widths');
    return {for (final e in (m ?? const {}).entries) e.key as String: (e.value as num).toDouble()};
  }

  Future<void> saveLayout(Map<String, double> widths) => _store.setMeta('layout_widths', widths);

  // ---------------------------------------------------------------- chặn / báo cáo (App Store 1.2)
  /// Người mình đã chặn (preferences flygo_chat/blocked): ẩn tin của họ trên mọi thiết bị của mình.
  Set<String> blocked = {};

  Future<void> loadBlocked() async {
    if (me == null) return;
    try {
      final r = (await api.get('/users/${me!.id}/preferences/flygo_chat/name/blocked') as Map).cast<String, dynamic>();
      blocked = (jsonDecode(r['value'] as String) as List).cast<String>().toSet();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setBlocked(String userId, bool block) async {
    if (me == null || userId == me!.id) return;
    block ? blocked.add(userId) : blocked.remove(userId);
    notifyListeners();
    await api.put('/users/${me!.id}/preferences', [
      {'user_id': me!.id, 'category': 'flygo_chat', 'name': 'blocked', 'value': jsonEncode(blocked.toList())}
    ]);
  }

  /// Gửi báo cáo / yêu cầu tới quản trị viên máy chủ (tin nhắn riêng). Trả về số quản trị viên đã nhận.
  Future<int> sendToAdmins(String text) async {
    final r = await api.get('/users', {'role': 'system_admin', 'per_page': '20', 'active': 'true'}) as List;
    final admins = [
      for (final e in r)
        if ((e as Map)['is_bot'] != true && e['id'] != me?.id) e['id'] as String,
    ];
    var n = 0;
    for (final id in admins.take(3)) {
      try {
        final ch = await openDirect(id);
        await api.createPost({'channel_id': ch, 'message': text});
        n++;
      } catch (_) {}
    }
    return n;
  }

  Future<int> reportPost(MmPost p, String reason) {
    final who = users[p.userId];
    final quote = plainPreview(p.message).replaceAll('\n', ' ');
    return sendToAdmins([
      tr('🚩 Báo cáo tin nhắn'),
      tr('Người báo cáo: @{0}', [me?.username ?? '']),
      tr('Người gửi: @{0}', [who?.username ?? p.userId]),
      tr('Lý do: {0}', [reason]),
      '$kServerUrl/$kTeamName/pl/${p.id}',
      if (quote.isNotEmpty) '> ${quote.length > 300 ? '${quote.substring(0, 300)}…' : quote}',
    ].join('\n'));
  }

  // ---------------------------------------------------------------- nhạc chuông cuộc gọi theo nhóm
  /// id kênh → id nhạc chuông (preferences flygo_chat/ringtones, dùng chung mọi thiết bị).
  Map<String, String> ringtones = {};

  Future<void> loadRingtones() async {
    if (me == null) return;
    try {
      final r = (await api.get('/users/${me!.id}/preferences/flygo_chat/name/ringtones') as Map).cast<String, dynamic>();
      ringtones = (jsonDecode(r['value'] as String) as Map).cast<String, String>();
    } catch (_) {
      ringtones = {};
    }
    await Ringtones.merge(ringtones, channels.keys);
    notifyListeners();
  }

  Future<void> setRingtone(String channelId, String? id) async {
    if (me == null) return;
    id == null ? ringtones.remove(channelId) : ringtones[channelId] = id;
    notifyListeners();
    await Ringtones.set(channelId, id);
    await api.put('/users/${me!.id}/preferences', [
      {'user_id': me!.id, 'category': 'flygo_chat', 'name': 'ringtones', 'value': jsonEncode(ringtones)}
    ]);
  }

  Future<void> saveStatusPresets(List<({String emoji, String text})> list) async {
    if (me == null) return;
    statusPresets = list;
    notifyListeners();
    await api.put('/users/${me!.id}/preferences', [
      {
        'user_id': me!.id,
        'category': 'flygo_chat',
        'name': 'status_presets',
        'value': jsonEncode([for (final p in list) {'emoji': p.emoji, 'text': p.text}]),
      }
    ]);
  }

  // ---------------------------------------------------------------- bot cá nhân
  /// Bot do mình tạo. Xóa bot chỉ quản trị viên làm được.
  Future<List<Map<String, dynamic>>> myBots() async {
    final r = await api.get('/bots', {'per_page': '200'}) as List;
    final list = [
      for (final e in r)
        if ((e as Map)['owner_id'] == me?.id && (e['delete_at'] as num? ?? 0) == 0) e.cast<String, dynamic>()
    ];
    _myBotIds = {for (final b in list) b['user_id'] as String};
    return list;
  }

  Set<String>? _myBotIds;

  /// Id các bot của mình (tải một lần, cập nhật khi mở trang quản lý bot).
  Future<Set<String>> myBotIds() async {
    if (_myBotIds != null) return _myBotIds!;
    try {
      await myBots();
    } catch (_) {
      return const {};
    }
    return _myBotIds ?? const {};
  }

  static final _agentMarker = RegExp(r'\[flygo-agent([^\]]*)\]');

  /// Mình có được gọi bot này không: bot của mình, hoặc bot trợ lý AI có mình trong danh sách được gọi.
  /// Bot khác (bot hệ thống, bot của plugin, bot của người khác) không gọi được.
  bool canCallBot(MmUser u, Set<String> mine) {
    if (!u.isBot) return true;
    if (mine.contains(u.id)) return true;
    final m = _agentMarker.firstMatch(u.raw['bot_description'] as String? ?? '');
    if (m == null || me == null) return false;
    final allow = RegExp(r'allow=([\w,]+)').firstMatch(m.group(1)!)?.group(1)?.split(',') ?? const [];
    return allow.contains(me!.id);
  }

  /// Token đã cấp cho bot trên máy này (máy chủ chỉ trả token đúng một lần lúc tạo).
  Future<String?> botToken(String botId) async => ((await _store.meta<Map>('bot_tokens')) ?? const {})[botId] as String?;

  Future<String> newBotToken(String botId) async {
    final t = (await api.post('/users/$botId/tokens', {'description': 'Flygo Chat'}) as Map).cast<String, dynamic>();
    final token = t['token'] as String;
    final all = Map<String, dynamic>.from((await _store.meta<Map>('bot_tokens')) ?? const {});
    all[botId] = token;
    await _store.setMeta('bot_tokens', all);
    return token;
  }

  /// Tạo bot và một token cho bot. Trả về id người dùng của bot.
  Future<String> createBot(String username, String displayName, String description) async {
    final bot = (await api.post('/bots', {
      'username': username,
      'display_name': displayName,
      'description': description,
    }) as Map).cast<String, dynamic>();
    final uid = bot['user_id'] as String;
    await newBotToken(uid);
    return uid;
  }

  Future<void> updateBot(String botId, String username, String displayName, String description) async {
    await api.put('/bots/$botId', {'username': username, 'display_name': displayName, 'description': description});
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

  // ---------------------------------------------------------------- thông báo đẩy
  StreamSubscription<String>? _tokenSub;

  /// Gắn mã thiết bị (Firebase / APNs) vào phiên đăng nhập để máy chủ gửi thông báo đẩy.
  Future<void> registerPush() async {
    if (!PushService.supported) return;
    Future<void> attach(String id) async {
      try {
        await api.put('/users/sessions/device', {'device_id': id});
        debugPrint('[push] device attached');
        await _registerFlygoDevice(kServerUrl, token, id);
      } catch (e) {
        debugPrint('[push] attach: $e');
      }
    }

    final id = await PushService.deviceId();
    if (id != null) await attach(id);
    _tokenSub ??= PushService.tokenRefresh.listen(attach);
    // Mã máy chủ (để thông báo đẩy mở đúng máy chủ) và gắn thiết bị cho cả các máy chủ khác đã đăng nhập.
    for (final e in [...ServerList.items]) {
      final url = e.url;
      final token = url == kServerUrl ? this.token : await TokenStore.readFor(url);
      if (token == null) continue;
      final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'User-Agent': kUserAgent};
      try {
        final r = await http.get(Uri.parse('$url/api/v4/config/client?format=old'), headers: headers);
        final sid = (jsonDecode(r.body) as Map)['DiagnosticId'] as String? ?? '';
        await ServerList.setServerId(url, sid);
        if (id != null && url != kServerUrl) {
          final r = await http.put(Uri.parse('$url/api/v4/users/sessions/device'), headers: headers, body: jsonEncode({'device_id': id}));
          if (r.statusCode < 300) await _registerFlygoDevice(url, token, id);
        }
      } catch (_) {}
    }
  }

  /// Ghi thiết bị vào sổ của máy chủ đẩy Flygo (để dừng đổ chuông trên các máy khác của mình khi đã
  /// trả lời / từ chối ở một máy). [deviceId] đúng mã đã gắn với Mattermost.
  static Future<void> _registerFlygoDevice(String server, String token, String deviceId) async {
    try {
      final r = await http
          .post(Uri.parse('$kPushUrl/device'),
              headers: {
                'Authorization': 'Bearer $token',
                'X-MM-Server': server,
                'Content-Type': 'application/json',
                'User-Agent': kUserAgent,
              },
              body: jsonEncode({'device_id': deviceId}))
          .timeout(const Duration(seconds: 10));
      debugPrint('[push] flygo device ${r.statusCode}');
    } catch (e) {
      debugPrint('[push] flygo device: $e');
    }
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
      // Cuộc gọi chỉ đổ chuông ở cửa sổ chính.
      if (kWindowChannel == null) calls.onWsEvent(e);
      return;
    }
    switch (e.event) {
      case 'posted':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        _onPosted(p);
        if (p.isCall || p.isCallRing) _callLogSoon();
      case 'post_edited':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        if (p.isCall) _callLogSoon();
        if ((p.raw['is_pinned'] == true) != pinnedIn(p.channelId).any((x) => x.id == p.id)) loadPinned(p.channelId);
        _store.putPosts([p]);
        _merge(p.channelId, [p]);
        // Tin cuối của bot đổi từ "chỉ trong luồng" sang "cả chat chính" bằng cách sửa tin.
        if (latest[p.channelId]?.id == p.id ||
            (!p.threadOnly && p.createAt >= (latest[p.channelId]?.createAt ?? 0))) {
          latest[p.channelId] = p;
        }
      case 'post_deleted':
        final p = MmPost((jsonDecode(e.data['post'] as String) as Map).cast());
        // Bot AI xóa tin đang viết dở sau khi đăng tin cuối: bỏ hẳn, không hiện "đã thu hồi".
        if (p.props.keys.any((k) => k.startsWith('flygo_agent'))) {
          _dropPost(p);
          break;
        }
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
          (_typing[_typingKey(ch, e.data['parent_id'] as String? ?? '')] ??= {})[uid] = DateTime.now();
        }
      case 'preferences_changed':
        // Đổi mô hình / mức thông minh trợ lý trên máy khác: cập nhật ngay ở máy này.
        try {
          final list = jsonDecode(e.data['preferences'] as String) as List;
          for (final p in list) {
            if (p['category'] == 'flygo_chat' && p['name'] == 'agent_config' && p['user_id'] == me?.id) {
              agentConfig = {
                for (final x in (jsonDecode(p['value'] as String) as Map).entries) x.key as String: (x.value as Map).cast<String, String>(),
              };
              notifyListeners();
            }
          }
        } catch (_) {}
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
        if (u.id == me?.id) me = u;
        _store.putUsers([u]);
      case 'status_change':
        final uid = e.data['user_id'] as String?;
        final st = e.data['status'] as String?;
        if (uid != null && st != null) statuses[uid] = st;
    }
    notifyListeners();
  }

  /// Bỏ hẳn một tin khỏi danh sách và bộ nhớ đệm (không để lại "đã thu hồi").
  void _dropPost(MmPost p) {
    _posts[p.channelId]?.removeWhere((x) => x.id == p.id);
    _threads[p.rootId]?.removeWhere((x) => x.id == p.id);
    _store.deletePost(p.id);
    if (latest[p.channelId]?.id == p.id) {
      _store.latest(p.channelId).then((v) {
        latest[p.channelId] = v;
        notifyListeners();
      });
    }
  }

  void _onPosted(MmPost p) {
    // Tin cuối của bot AI được đăng lại thành tin mới: thay ngay bong bóng đang viết dở cùng lượt (run_id).
    final am = (p.props['flygo_agent_message'] as Map?)?.cast<String, dynamic>();
    if (am != null && am['final'] == true && am['run_id'] != null) {
      bool sameRun(MmPost x) =>
          x.id != p.id && ((x.props['flygo_agent_message'] as Map?)?['run_id']) == am['run_id'];
      for (final x in [...?_posts[p.channelId]?.where(sameRun), ...?_threads[p.rootId]?.where(sameRun)]) {
        _dropPost(x);
      }
    }
    if (scheduledIn(p.channelId).isNotEmpty && p.userId == me?.id) loadScheduled();
    _store.putPosts([p]);
    _store.removeOutbox(p.pendingId);
    _merge(p.channelId, [p]);
    _typing[_typingKey(p.channelId, p.rootId)]?.remove(p.userId);
    final c = channels[p.channelId];
    if (c == null) {
      syncAll();
      return;
    }
    // Câu trả lời chỉ trong chủ đề không thay dòng xem trước của chat chính.
    if (!p.threadOnly && (p.rootId.isEmpty || latest[p.channelId] == null || p.createAt >= (latest[p.channelId]?.createAt ?? 0))) {
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
    if (!mine && p.isCallRing) {
      _ringFromPost(p, c);
      return;
    }
    if (!mine && !p.isSystem) _notifyDesktop(p, c);
  }

  /// Gọi thoại / video trong nhóm/kênh: tin `flygo_call_ring` của người khác đổ chuông như cuộc gọi đến,
  /// trừ nhóm đang tắt tiếng hoặc tắt thông báo, tin cũ, hay cửa sổ phụ (máy chủ khác).
  void _ringFromPost(MmPost p, MmChannel c) {
    if (kWindowChannel != null || c.isDirect || c.isGroupDm || p.rootId.isNotEmpty) return;
    if (isMuted(c.id) || notifyLevel(c.id) == 'none') return;
    if (DateTime.now().millisecondsSinceEpoch - p.createAt > 45000) return;
    calls.ringFromPost(c.id, p.userId, video: p.callRingVideo);
  }

  /// Máy tính: báo tin mới (tin riêng, được nhắc tên, hoặc kênh đặt "Mọi tin nhắn"),
  /// trừ khi đang xem đúng cuộc trò chuyện đó.
  void _notifyDesktop(MmPost p, MmChannel c) {
    if (kIsWeb || !(Platform.isMacOS || Platform.isLinux || Platform.isWindows) || kWindowChannel != null) return;
    if (activeChannelId == c.id && PushService.appFocused) return;
    // Tin của bot AI: chỉ báo cho chủ việc (props.flygo_agent_owner), không làm phiền người khác.
    final agentOwner = p.props['flygo_agent_owner'] as String?;
    final isAgent = p.props.keys.any((k) => k.startsWith('flygo_agent'));
    if (isAgent && agentOwner != me?.id) return;
    // Tin mở "Luồng riêng" / "Bí mật": chỉ báo cho người được tag.
    if (p.rootId.isEmpty &&
        (p.props['flygo_open_thread'] == true || p.props['flygo_private_thread'] == true) &&
        !_mentionsMe(p, c)) {
      return;
    }
    final level = notifyLevel(c.id);
    if (level == 'none') return;
    final direct = c.isDirect || c.isGroupDm;
    if (level != 'all' && !direct && !_mentionsMe(p, c)) return;
    if (isMuted(c.id) && !_mentionsMe(p, c)) return;
    final sender = users[p.userId]?.displayName ?? tr('Người dùng');
    final text = previewText(p);
    PushService.showDesktop(
      channelId: c.id,
      title: c.isDirect ? sender : channelTitle(c),
      body: c.isDirect ? text : '$sender: $text',
    );
  }

  /// Máy tính: mở một máy chủ khác trong cửa sổ riêng.
  static Future<void> openServerWindow(String url) =>
      Process.start(Platform.resolvedExecutable, ['--server=$url'], mode: ProcessStartMode.detached);

  static final _groupMention = RegExp(r'(^|\W)@(all|channel|here)\b');
  bool _mentionsMe(MmPost p, MmChannel c) =>
      c.isDirect || (me != null && (p.message.contains('@${me!.username}') || _groupMention.hasMatch(p.message)));

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
    _statusTimer?.cancel();
    _tokenSub?.cancel();
    _viewTimer?.cancel();
    _store.close();
    api.close();
  }
}

/// Một dòng trong lịch sử cuộc gọi.
class CallLogEntry {
  final MmPost post;
  final String channelId;
  final String callerId;
  final int startAt;
  final int? endAt;
  final bool outgoing;
  final bool missed;
  final bool video;
  final bool meeting;
  const CallLogEntry({
    required this.post,
    required this.channelId,
    required this.callerId,
    required this.startAt,
    required this.endAt,
    required this.outgoing,
    required this.missed,
    required this.video,
    required this.meeting,
  });
  bool get ongoing => endAt == null;
  Duration get duration => Duration(milliseconds: (endAt ?? startAt) - startAt);
}
