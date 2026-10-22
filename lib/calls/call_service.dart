import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'ringtones.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../api/mm_api.dart';
import '../api/mm_ws.dart';
import '../config.dart';
import '../push/push_service.dart';
import 'calls_client.dart';

enum CallPhase { idle, incoming, outgoing, connecting, active, ended }

/// Một người (một phiên Calls) khác trong cuộc gọi.
class CallParticipant {
  final String sessionId;
  String userId;
  bool unmuted = false;
  bool speaking = false;
  /// Máy chủ báo đang bật camera.
  bool video = false;
  /// Đang chia sẻ màn hình.
  bool screen = false;
  bool raisedHand = false;
  MediaStream? videoStream;
  String? videoTrackId;
  MediaStream? screenStream;
  String? screenTrackId;
  /// Lúc nhận track camera (trạng thái đọc từ máy chủ có thể cũ hơn vài giây).
  DateTime? videoAt;
  final DateTime joinedAt = DateTime.now();

  CallParticipant(this.sessionId, this.userId);

  bool get hasVideo => video && videoStream != null;
  bool get hasScreen => screen && screenStream != null;
}

/// Trạng thái cuộc gọi hiện tại; nghe sự kiện Calls trên WebSocket chính.
class CallService extends ChangeNotifier {
  final MmApi api;
  final String Function() myId;
  final String Function() myName;
  /// Tin riêng (1-1) hoặc nhóm tin riêng: Mattermost tự đổ chuông, gác máy là kết thúc cho cả hai.
  final bool Function(String channelId) isDirectOrGroup;
  /// Tin riêng 1-1.
  final bool Function(String channelId) isDm;

  CallService({
    required this.api,
    required this.myId,
    required this.myName,
    required this.isDirectOrGroup,
    required this.isDm,
  });

  CallPhase phase = CallPhase.idle;
  String? channelId;
  String? callerId;
  String? endReason;
  bool muted = false;
  bool speaker = false;
  bool camera = false;
  bool _wantVideo = false;
  /// Cuộc họp: vào thẳng giao diện họp, không đổ chuông, không hết giờ chờ, ở lại một mình vẫn được.
  bool meeting = false;
  /// Cuộc gọi đến là gọi video.
  bool incomingVideo = false;
  /// Cuộc gọi đến là cuộc gọi nhóm (tin `flygo_call_ring` trong nhóm/kênh).
  bool groupRing = false;
  /// Cuộc gọi đang diễn ra theo kênh: những người đang trong đó (từ sự kiện WebSocket và
  /// `GET /plugins/com.mattermost.calls/<kênh>`), để hiện "Đang họp · N người · Tham gia".
  final Map<String, Set<String>> ongoing = {};
  MediaStream? localVideo;
  DateTime? startedAt;
  final Set<String> remoteUsers = {};
  /// Những người khác trong cuộc gọi, theo phiên (sessionID), giữ thứ tự vào.
  final Map<String, CallParticipant> _people = {};
  /// Mình đang nói (máy chủ báo `user_voice_on` cho phiên của mình).
  bool meSpeaking = false;
  CallsClient? _client;
  Timer? _noAnswer;
  Timer? _ringBuzz;
  // Giữ tham chiếu để luồng âm thanh phía xa không bị thu hồi.
  final Map<String, MediaStream> _audio = {};

  /// Người khác trong cuộc gọi (bỏ phiên của chính mình, kể cả mình trên thiết bị khác).
  List<CallParticipant> get participants =>
      [for (final p in _people.values) if (p.userId != myId() && p.sessionId != mySessionId) p];

  String? get mySessionId {
    final id = _client?.sessionId;
    return id == null || id.isEmpty ? null : id;
  }

  /// Gọi khi cần đẩy màn hình cuộc gọi lên (main.dart gắn vào).
  void Function()? onShowCallScreen;

  /// Cuộc gọi vừa bắt đầu trên máy này (để lịch sử cuộc gọi biết là gọi video / cuộc họp).
  void Function(String channelId, {required bool video, required bool meeting})? onCallMode;

  /// Mạng rớt / đổi mạng: đang tự nối lại (hiện "Đang kết nối lại…").
  bool reconnecting = false;
  DateTime? _lostAt;
  Timer? _rejoinTimer;
  Timer? _giveUp;
  bool _rejoining = false;

  /// Màn hình đang chia sẻ (máy tính).
  MediaStream? localScreen;
  /// Máy chủ cho phép chia sẻ màn hình (cấu hình plugin Calls).
  bool screenAllowed = true;

  /// Chia sẻ màn hình chỉ có trên máy tính (flutter_webrtc: macOS, Windows, Linux).
  static bool get canShareScreen => isDesktop;

  bool get busy => phase != CallPhase.idle && phase != CallPhase.ended;

  Future<List<Map<String, dynamic>>> _iceServers() async {
    // TURN của trạm đẩy lấy song song, lỗi / trống thì thôi.
    final extra = _flygoTurn();
    final cfg = (await api.get('/plugins/$callsPluginId/config') as Map).cast<String, dynamic>();
    screenAllowed = cfg['AllowScreenSharing'] != false;
    final servers = <Map<String, dynamic>>[
      for (final s in (cfg['ICEServersConfigs'] as List? ?? [])) (s as Map).cast<String, dynamic>(),
    ];
    if (cfg['NeedsTURNCredentials'] == true) {
      try {
        final turn = await api.get('/plugins/$callsPluginId/turn-credentials') as List;
        servers.addAll(turn.map((e) => (e as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    servers.addAll(await extra);
    return servers;
  }

  /// TURN của máy chủ đẩy Flygo, giữ đến hết `ttl` (giây). Không được thì trả danh sách trống.
  static final Map<String, (DateTime, List<Map<String, dynamic>>)> _turnCache = {};

  Future<List<Map<String, dynamic>>> _flygoTurn() async {
    final key = kServerUrl;
    final hit = _turnCache[key];
    if (hit != null && DateTime.now().isBefore(hit.$1)) return hit.$2;
    try {
      await discoverPush(kServerUrl);
      final r = await http.get(Uri.parse('$kPushUrl/turn'), headers: {
        'Authorization': 'Bearer ${api.token}',
        'X-MM-Server': kServerUrl,
        'User-Agent': kUserAgent,
      }).timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return const [];
      final j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      final list = <Map<String, dynamic>>[
        for (final s in (j['iceServers'] as List? ?? const []))
          if (s is Map && s['urls'] != null) s.cast<String, dynamic>(),
      ];
      final ttl = (j['ttl'] as num?)?.toInt() ?? 0;
      // Hết hạn sớm hơn một chút để không dùng thông tin TURN sắp hết hạn.
      if (ttl > 0) _turnCache[key] = (DateTime.now().add(Duration(seconds: (ttl * .9).floor())), list);
      return list;
    } catch (e) {
      debugPrint('[calls] flygo turn: $e');
      return const [];
    }
  }

  /// Gọi đi (hoặc tham gia cuộc gọi đang diễn ra) trong một cuộc trò chuyện.
  /// - Tin riêng / nhóm tin riêng: Mattermost tự đổ chuông cho người kia.
  /// - Nhóm / kênh: đăng tin `flygo_call_ring` để app của các thành viên đổ chuông
  ///   (đã có cuộc gọi đang diễn ra thì chỉ tham gia, không đổ chuông lại).
  /// - [meeting]: cuộc họp, vào thẳng giao diện họp, không đổ chuông, không chờ ai.
  Future<void> startCall(String channel, {bool video = false, bool meeting = false}) async {
    if (busy) return;
    final small = isDirectOrGroup(channel);
    // Máy tính: cuộc họp / gọi nhóm mở trong cửa sổ riêng (tiến trình app khác), cửa sổ chính vẫn dùng bình thường.
    if (isDesktop && kWindowChannel == null && !small) {
      await Process.start(Platform.resolvedExecutable, ['--call=$channel', if (video) '--call-video', if (meeting) '--call-meeting'], mode: ProcessStartMode.detached);
      return;
    }
    _wantVideo = video;
    channelId = channel;
    callerId = myId();
    this.meeting = meeting;
    incomingVideo = false;
    groupRing = false;
    phase = meeting ? CallPhase.connecting : CallPhase.outgoing;
    _reset();
    notifyListeners();
    onShowCallScreen?.call();
    var ring = !meeting && !small;
    if (ring && ((await _othersInCall(channel)) ?? 0) > 0) ring = false;
    if (channelId != channel || !busy) return;
    await _join();
    if (video) {
      // Gọi video: bật camera và loa ngoài ngay, không chờ người kia bắt máy.
      speaker = true;
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
    if (ring && busy && channelId == channel && _client != null) _postRing(channel, video);
    if (!meeting) {
      _noAnswer = Timer(const Duration(seconds: 50), () {
        if (phase == CallPhase.outgoing && channelId == channel) hangUp(reason: tr('Không có người trả lời'));
      });
    }
  }

  /// Tham gia cuộc gọi / cuộc họp đang diễn ra của kênh (không đổ chuông ai).
  Future<void> join(String channel) => startCall(channel, meeting: !isDm(channel));

  /// Tin báo đổ chuông cho cả nhóm. Máy chủ đẩy (flygo-push) nhận ra tin bắt đầu bằng "📞 " / "📹 "
  /// và gửi thành cuộc gọi đến cho máy đang tắt app; "@channel" để Mattermost gửi thông báo đẩy cho
  /// mọi thành viên (trừ ai đã tắt tiếng nhóm hoặc tắt thông báo).
  Future<void> _postRing(String channel, bool video) async {
    final name = myName();
    final text = video ? tr('📹 {0} đang gọi video nhóm', [name]) : tr('📞 {0} đang gọi thoại nhóm', [name]);
    try {
      await api.post('/posts', {
        'channel_id': channel,
        'message': '$text @channel',
        'props': {
          ringProp: {'video': video},
        },
      });
    } catch (e) {
      debugPrint('[calls] ring post: $e');
    }
  }

  static const ringProp = 'flygo_call_ring';

  /// Số người khác đang trong cuộc gọi của kênh (null nếu không đọc được).
  Future<int?> _othersInCall(String ch) async {
    try {
      final r = (await api.get('/plugins/$callsPluginId/$ch') as Map).cast<String, dynamic>();
      final call = (r['call'] as Map?)?.cast<String, dynamic>();
      if (call == null || ((call['end_at'] as num?) ?? 0) > 0) {
        _setOngoing(ch, null);
        return 0;
      }
      final ids = _usersOf(call);
      _setOngoing(ch, ids);
      return ids.where((u) => u != myId()).length;
    } catch (_) {
      return null;
    }
  }

  Set<String> _usersOf(Map<String, dynamic> call) => {
        for (final u in (call['users'] as List? ?? const [])) if (u is String) u,
        for (final s in _sessionsOf(call)) if (s['user_id'] is String) s['user_id'] as String,
      };

  void _setOngoing(String ch, Set<String>? users) {
    final before = ongoing[ch];
    if (users == null || users.isEmpty) {
      if (ongoing.remove(ch) != null) notifyListeners();
      return;
    }
    if (before != null && before.length == users.length && before.containsAll(users)) return;
    ongoing[ch] = {...users};
    notifyListeners();
  }

  /// Đọc lại cuộc gọi đang diễn ra của kênh (mở khung chat).
  Future<void> refreshChannel(String ch) async => _othersInCall(ch);

  /// Có tin `flygo_call_ring` của người khác trong nhóm/kênh: đổ chuông như cuộc gọi đến
  /// (AppState đã bỏ qua nhóm đang tắt tiếng / tắt thông báo).
  void ringFromPost(String ch, String caller, {bool video = false}) {
    if (busy || caller == myId() || isDirectOrGroup(ch)) return;
    channelId = ch;
    callerId = caller;
    meeting = false;
    incomingVideo = video;
    groupRing = true;
    _reset();
    phase = CallPhase.incoming;
    _startRing();
    notifyListeners();
    onShowCallScreen?.call();
    Timer(const Duration(seconds: 45), () {
      if (phase == CallPhase.incoming && channelId == ch) _end(tr('Cuộc gọi nhỡ'));
    });
    // Tin đến muộn (người gọi đã gác máy): không còn ai trong cuộc gọi thì thôi đổ chuông.
    _othersInCall(ch).then((n) {
      if (n == 0 && phase == CallPhase.incoming && channelId == ch) _end(tr('Cuộc gọi nhỡ'));
    });
  }

  Future<void> accept() async {
    if (phase != CallPhase.incoming) return;
    _stopRing();
    _wantVideo = incomingVideo;
    phase = CallPhase.connecting;
    notifyListeners();
    await _join();
    if (_wantVideo) {
      speaker = true;
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
  }

  /// Đã bấm "Trả lời" trên màn hình cuộc gọi của hệ điều hành (app có thể vừa được mở lên).
  Future<void> acceptFromSystem(String channel, {bool video = false}) async {
    if (phase == CallPhase.incoming && channelId == channel) {
      incomingVideo = incomingVideo || video;
      return accept();
    }
    if (busy) return;
    channelId = channel;
    meeting = false;
    groupRing = !isDirectOrGroup(channel);
    incomingVideo = video;
    _wantVideo = video;
    phase = CallPhase.connecting;
    _reset();
    notifyListeners();
    onShowCallScreen?.call();
    await _join();
  }

  Future<void> decline() async {
    if (phase != CallPhase.incoming) return;
    final ch = channelId;
    _stopRing();
    _end(tr('Đã từ chối'));
    if (ch != null) await _declined(ch);
  }

  /// Đã bấm "Từ chối" trên màn hình cuộc gọi của hệ điều hành.
  Future<void> declineFromSystem(String ch) async {
    if (phase == CallPhase.incoming && channelId == ch) return decline();
    if (busy && channelId == ch) return;
    await _declined(ch);
  }

  /// Báo đã từ chối: plugin Calls (các phiên đang mở của mình thôi đổ chuông) và máy chủ đẩy Flygo
  /// (huỷ đổ chuông trên các máy khác đang tắt app).
  Future<void> _declined(String ch) async {
    await Future.wait([
      api.post('/plugins/$callsPluginId/calls/$ch/dismiss-notification', null).catchError((_) => null),
      _pushPost('/decline', {'channel_id': ch}),
    ]);
  }

  Future<void> _pushPost(String path, Map<String, dynamic> body) async {
    try {
      await discoverPush(kServerUrl);
      final r = await http
          .post(Uri.parse('$kPushUrl$path'),
              headers: {
                'Authorization': 'Bearer ${api.token}',
                'X-MM-Server': kServerUrl,
                'Content-Type': 'application/json',
                'User-Agent': kUserAgent,
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode >= 300) debugPrint('[calls] push $path: ${r.statusCode} ${r.body}');
    } catch (e) {
      debugPrint('[calls] push $path: $e');
    }
  }

  Future<void> hangUp({String? reason}) async {
    reason ??= tr('Cuộc gọi đã kết thúc');
    _stopRing();
    _watch?.cancel();
    _stopReconnect();
    final ch = channelId;
    final c = _client;
    _client = null;
    await c?.leave();
    _end(reason);
    // Gọi 1-1 / nhóm nhỏ: một bên gác máy thì kết thúc cuộc gọi cho cả hai bên (chủ cuộc gọi mới có quyền;
    // bên kia vẫn tự gác nhờ kiểm tra định kỳ bên dưới). Nhóm/kênh và cuộc họp: rời đi là chỉ mình rời,
    // cuộc gọi kết thúc khi người cuối cùng rời (máy chủ tự làm).
    if (ch != null && isDirectOrGroup(ch) && !meeting) {
      try {
        await api.post('/plugins/$callsPluginId/calls/$ch/end', null);
      } catch (_) {}
    }
  }

  Timer? _hangSoon;

  /// Kiểm tra định kỳ cuộc gọi 1-1 / nhóm nhỏ: còn mỗi mình (người kia đã gác máy, kể cả khi lỡ mất
  /// sự kiện trên WebSocket) thì tự gác máy.
  Timer? _watch;
  int _aloneTicks = 0;

  void _startWatch() {
    _watch?.cancel();
    _aloneTicks = 0;
    final ch = channelId;
    if (ch == null) return;
    final small = isDirectOrGroup(ch) && !meeting;
    _syncState(ch);
    _watch = Timer.periodic(Duration(seconds: small ? 3 : 6), (_) async {
      if (phase != CallPhase.active || channelId != ch) return;
      final others = await _syncState(ch);
      if (others == null || !small) return; // lỗi mạng: thử lại lần sau
      _aloneTicks = others == 0 ? _aloneTicks + 1 : 0;
      // Chờ ~9 giây: người kia có thể đang tự vào lại sau khi rớt mạng.
      if (_aloneTicks >= 3 && phase == CallPhase.active && channelId == ch && !reconnecting) hangUp();
    });
  }

  /// Đọc trạng thái cuộc gọi của kênh (`GET /plugins/com.mattermost.calls/<kênh>`), cập nhật danh sách
  /// người tham gia và trả về số người khác đang trong cuộc gọi (null nếu không đọc được).
  Future<int?> _syncState(String ch) async {
    try {
      final r = (await api.get('/plugins/$callsPluginId/$ch') as Map).cast<String, dynamic>();
      if (channelId != ch || !busy) return null;
      final call = (r['call'] as Map?)?.cast<String, dynamic>();
      if (call == null || ((call['end_at'] as num?) ?? 0) > 0) {
        _setOngoing(ch, null);
        return 0;
      }
      _applyCallState(call);
      final ids = _usersOf(call);
      _setOngoing(ch, ids);
      ids.remove(myId());
      return ids.length;
    } catch (_) {
      return null;
    }
  }

  /// Danh sách phiên trong trạng thái cuộc gọi (bản mới là mảng, bản cũ là map theo sessionID).
  static List<Map<String, dynamic>> _sessionsOf(Map<String, dynamic> call) => switch (call['sessions']) {
        List l => [for (final s in l) if (s is Map) s.cast<String, dynamic>()],
        Map m => [
            for (final e in m.entries)
              if (e.value is Map) {'session_id': e.key, ...(e.value as Map).cast<String, dynamic>()},
          ],
        _ => const [],
      };

  /// Áp trạng thái cuộc gọi từ máy chủ (sự kiện `call_state` hoặc GET): thêm/bớt người, mic, camera,
  /// chia sẻ màn hình. Trạng thái "đang nói" chỉ đến từ sự kiện nên giữ nguyên.
  /// Tin gốc của cuộc gọi (Calls: thread_id / post_id): luồng lưu bình luận của cuộc họp.
  String? callThreadId;

  /// Lấy id luồng của cuộc gọi đang diễn ra ở kênh hiện tại (đọc lại từ máy chủ nếu chưa có).
  Future<String?> threadIdOf() async {
    if (callThreadId != null || channelId == null) return callThreadId;
    try {
      final r = (await api.get('/plugins/$callsPluginId/$channelId') as Map).cast<String, dynamic>();
      final call = (r['call'] as Map?)?.cast<String, dynamic>();
      callThreadId = (call?['thread_id'] ?? call?['post_id']) as String?;
    } catch (_) {}
    return callThreadId;
  }

  void _applyCallState(Map<String, dynamic> call) {
    final t = (call['thread_id'] ?? call['post_id']) as String?;
    if (t != null && t.isNotEmpty) callThreadId = t;
    final seen = <String>{};
    final screenSid = call['screen_sharing_session_id'] as String? ?? '';
    for (final s in _sessionsOf(call)) {
      final sid = s['session_id'] as String? ?? '';
      final uid = s['user_id'] as String? ?? '';
      if (sid.isEmpty || sid == mySessionId) continue;
      seen.add(sid);
      final p = _people.putIfAbsent(sid, () => CallParticipant(sid, uid));
      if (uid.isNotEmpty) p.userId = uid;
      p.unmuted = s['unmuted'] == true;
      p.raisedHand = ((s['raised_hand'] as num?) ?? 0) > 0;
      // Camera: trạng thái đọc có thể cũ hơn track vừa nhận; tắt camera thì giữ track (bật lại người gửi
      // chỉ thay track trên cùng luồng, không có track mới) và chỉ ẩn hình.
      final fresh = p.videoAt != null && DateTime.now().difference(p.videoAt!).inSeconds < 8;
      if (s.containsKey('video') && !(fresh && p.video)) p.video = s['video'] == true;
      p.screen = sid == screenSid;
      if (!p.screen) _dropScreen(p);
    }
    // Người mới vào vài giây có thể chưa có trong bản trạng thái đọc trước đó: chưa xoá vội.
    final now = DateTime.now();
    _people.removeWhere((sid, p) => !seen.contains(sid) && now.difference(p.joinedAt).inSeconds > 8);
    _syncRemoteUsers();
    // Tham gia cuộc gọi đang diễn ra: đã có người trong đó thì coi như đã kết nối.
    if (phase == CallPhase.outgoing && remoteUsers.isNotEmpty) {
      _noAnswer?.cancel();
      phase = CallPhase.active;
      startedAt ??= DateTime.now();
      _startWatch();
    }
    notifyListeners();
  }

  void _syncRemoteUsers() {
    remoteUsers
      ..clear()
      ..addAll([for (final p in participants) if (p.userId.isNotEmpty) p.userId]);
  }

  void _dropVideo(CallParticipant p) {
    p.videoStream = null;
    p.videoTrackId = null;
  }

  void _dropScreen(CallParticipant p) {
    p.screenStream = null;
    p.screenTrackId = null;
  }

  /// Có track mới từ SFU: gắn vào đúng người theo sessionID.
  void _onRemoteTrack(String type, String sid, MediaStream stream, MediaStreamTrack track) {
    if (sid.isEmpty || sid == mySessionId) return;
    final p = _people.putIfAbsent(sid, () => CallParticipant(sid, ''));
    // Bảng loại track đến sau có thể đổi loại / người gửi của track đã nhận: gỡ khỏi chỗ cũ.
    for (final q in _people.values) {
      if (q.videoTrackId == track.id) _dropVideo(q);
      if (q.screenTrackId == track.id) _dropScreen(q);
    }
    switch (type) {
      case 'video':
        p.video = true;
        p.videoAt = DateTime.now();
        p.videoStream = stream;
        p.videoTrackId = track.id;
      case 'screen':
        p.screen = true;
        p.screenStream = stream;
        p.screenTrackId = track.id;
      default:
        // Âm thanh (giọng nói, âm thanh màn hình) tự phát; chỉ cần giữ tham chiếu.
        _audio[track.id ?? stream.id] = stream;
    }
    notifyListeners();
  }

  void _onRemoteTrackEnded(String trackId) {
    _audio.remove(trackId);
    for (final p in _people.values) {
      if (p.videoTrackId == trackId) _dropVideo(p);
      if (p.screenTrackId == trackId) _dropScreen(p);
    }
    notifyListeners();
  }

  /// Sự kiện trạng thái người tham gia (từ WebSocket chính hoặc WebSocket riêng của cuộc gọi;
  /// nhận trùng cũng không sao).
  void _onPeerEvent(String ev, Map<String, dynamic> data) {
    final sid = data['session_id'] as String? ?? '';
    final uid = (data['user_id'] ?? data['userID']) as String? ?? '';
    if (ev == 'call_state') {
      final ch = data['channel_id'] as String? ?? data['channelID'] as String?;
      if (ch != null && ch != channelId) return;
      try {
        final raw = data['call'];
        final call = raw is String ? (jsonDecode(raw) as Map).cast<String, dynamic>() : (raw as Map).cast<String, dynamic>();
        _applyCallState(call);
      } catch (_) {}
      return;
    }
    if (ev == 'user_screen_off' && sid.isEmpty) {
      // Máy chủ báo tắt chia sẻ màn hình khi người chia sẻ rời đi (không kèm phiên).
      for (final p in _people.values) {
        p.screen = false;
        _dropScreen(p);
      }
      notifyListeners();
      return;
    }
    if (sid.isEmpty) return;
    if (sid == mySessionId) {
      if (ev == 'user_voice_on' || ev == 'user_voice_off') {
        meSpeaking = ev == 'user_voice_on';
        notifyListeners();
      }
      return;
    }
    if (ev == 'user_left') {
      if (_people.remove(sid) != null) {
        _syncRemoteUsers();
        notifyListeners();
      }
      return;
    }
    final p = _people.putIfAbsent(sid, () => CallParticipant(sid, uid));
    if (uid.isNotEmpty) p.userId = uid;
    switch (ev) {
      case 'user_muted':
        p.unmuted = false;
        p.speaking = false;
      case 'user_unmuted':
        p.unmuted = true;
      case 'user_voice_on':
        p.speaking = true;
      case 'user_voice_off':
        p.speaking = false;
      case 'user_video_on':
        p.video = true;
      case 'user_video_off':
        // Giữ track: bật lại camera người gửi dùng lại luồng cũ (không có track mới).
        p.video = false;
      case 'user_screen_on':
        p.screen = true;
      case 'user_screen_off':
        p.screen = false;
        _dropScreen(p);
      case 'user_reacted':
        try {
          // Plugin Calls gửi `emoji` {name, skin, unified, literal} ngay trong sự kiện.
          final r = data['emoji'] ?? data['reaction'];
          final e = r is String ? jsonDecode(r) as Map : (r as Map? ?? const {});
          final l = e['literal'] as String? ?? '';
          final lit = l.isNotEmpty
              ? l
              : reactionNames.entries.where((x) => x.value == e['name']).firstOrNull?.key ?? '❤️';
          // Sự kiện đến cả trên WebSocket chính lẫn WebSocket của cuộc gọi: chỉ hiện một lần.
          final key = '$sid:${data['timestamp']}';
          if (_seenReactions.add(key)) {
            if (_seenReactions.length > 200) _seenReactions.remove(_seenReactions.first);
            reactions.add((p.userId, lit));
          }
        } catch (_) {}
      case 'user_raise_hand':
        p.raisedHand = true;
      case 'user_unraise_hand':
        p.raisedHand = false;
    }
    _syncRemoteUsers();
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final c = _client;
    if (c == null) return;
    try {
      if (camera) {
        await c.stopVideo();
        localVideo = null;
        camera = false;
      } else {
        localVideo = await c.startVideo();
        camera = localVideo != null;
        if (camera && !speaker) await toggleSpeaker();
      }
    } catch (e) {
      debugPrint('[calls] camera error: $e');
    }
    notifyListeners();
  }

  Future<void> switchCamera() async => _client?.switchCamera();

  // ---------------------------------------------------------------- quyền chủ phòng (Calls host controls)
  /// Tắt mic mọi người khác bằng lệnh gốc của Calls (mọi app đều chịu, kể cả Mattermost web / máy tính).
  Future<void> hostMuteOthers() async {
    final ch = channelId;
    if (ch == null) return;
    try {
      await api.post('/plugins/$callsPluginId/calls/$ch/host/mute-others', {});
    } catch (e) {
      debugPrint('[calls] host mute-others: $e');
    }
  }

  /// Tắt mic một người (mọi phiên của họ trong cuộc gọi).
  Future<void> hostMute(String userId) async {
    final ch = channelId;
    if (ch == null) return;
    for (final p in _people.values.where((p) => p.userId == userId)) {
      try {
        await api.post('/plugins/$callsPluginId/calls/$ch/host/mute', {'session_id': p.sessionId});
      } catch (e) {
        debugPrint('[calls] host mute: $e');
      }
    }
  }

  // ---------------------------------------------------------------- giơ tay, cảm xúc (giao thức gốc của Calls)
  bool handRaised = false;
  /// Cảm xúc thả trong cuộc gọi (của mình và người khác): (user id, emoji) — màn hình cuộc gọi vẽ hiệu ứng bay lên.
  final reactions = StreamController<(String, String)>.broadcast();

  void toggleHand() {
    handRaised = !handRaised;
    _client?.action(handRaised ? 'raise_hand' : 'unraise_hand');
    notifyListeners();
  }

  /// Hạ tay của mình (chủ phòng / trợ lý yêu cầu).
  void lowerHand() {
    if (!handRaised) return;
    toggleHand();
  }

  final Set<String> _seenReactions = {};

  static const _reactionUnified = {
    '❤️': '2764-fe0f',
    '👍': '1f44d',
    '👏': '1f44f',
    '😂': '1f602',
    '🎉': '1f389',
    '😮': '1f62e',
  };

  static const reactionNames = {'❤️': 'heart', '👍': '+1', '👏': 'clap', '😂': 'joy', '🎉': 'tada', '😮': 'open_mouth'};

  void react(String emoji) {
    final name = reactionNames[emoji] ?? 'heart';
    _client?.action('react', {
      // Plugin Calls đọc thẳng `data` là EmojiData (server/websocket.go), không bọc thêm.
      'data': jsonEncode({'name': name, 'skin': '', 'unified': _reactionUnified[emoji] ?? '', 'literal': emoji}),
    });
    reactions.add((myId(), emoji));
  }

  void toggleMute() {
    muted = !muted;
    _client?.setMuted(muted);
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    notifyListeners();
  }

  /// Vừa vào cuộc gọi nhóm / cuộc họp với mic + camera tắt sẵn: màn hình cuộc gọi hiện thông báo một lần.
  bool autoMutedNotice = false;

  Future<void> _join() async {
    final ch = channelId;
    // Cuộc gọi nhóm / cuộc họp: ai vào cũng tắt sẵn mic và camera, muốn nói / hiện hình thì tự bật.
    // (Gọi 1-1 giữ như cũ.)
    if (ch != null && !isDm(ch)) {
      muted = true;
      _wantVideo = false;
      incomingVideo = false;
      autoMutedNotice = true;
    }
    final video = _wantVideo;
    _wantVideo = false;
    if (ch != null) onCallMode?.call(ch, video: video || incomingVideo, meeting: meeting);
    // Không vào được cuộc gọi sau 30 giây (vd. máy không có micro / camera, mạng chặn): báo lỗi thay vì
    // đứng mãi ở "Đang kết nối...".
    Timer(const Duration(seconds: 30), () {
      if (phase == CallPhase.connecting && channelId == ch) {
        hangUp(reason: tr('Không kết nối được cuộc gọi. Kiểm tra micro, camera và mạng.'));
      }
    });
    try {
      await _connect(video: video);
    } catch (e, st) {
      debugPrint('[calls] join failed: $e\n$st');
      _end(tr('Không bắt đầu được cuộc gọi. Kiểm tra quyền micro và kết nối mạng.'));
    }
  }

  /// Tạo phiên Calls mới và vào cuộc gọi của kênh hiện tại (lần đầu hoặc vào lại sau khi rớt mạng).
  Future<void> _connect({required bool video, bool rejoin = false}) async {
    final servers = await _iceServers();
    if (!busy) return;
    late final CallsClient c;
    c = CallsClient(
      token: api.token,
      channelId: channelId!,
      iceServers: servers,
      onConnected: () {
        if (_client != c) return;
        if (phase == CallPhase.connecting) {
          phase = CallPhase.active;
          startedAt = DateTime.now();
        }
        if (rejoin) {
          debugPrint('[calls] rejoined');
          _stopReconnect();
          final scr = localScreen;
          if (scr != null) c.startScreen(scr);
        }
        _startWatch();
        notifyListeners();
      },
      onRemoteTrack: _onRemoteTrack,
      onRemoteTrackEnded: _onRemoteTrackEnded,
      onEvent: (ev, data) {
        // user_joined / user_left đã xử lý qua WebSocket chính (kèm logic gác máy).
        if (ev != 'user_joined' && ev != 'user_left') _onPeerEvent(ev, data);
      },
      onHealth: (ok) {
        if (_client == c) _setHealthy(ok);
      },
      onLost: () {
        if (_client == c) _rejoin();
      },
      onClosed: (reason) {
        if (_client != c) return;
        // Đang nối lại: phiên mới hỏng thì thử lại (đến khi hết 30 giây).
        if (reconnecting) {
          _client = null;
          _retryRejoin();
          return;
        }
        _end(reason);
      },
    );
    _client = c;
    // Gọi video: camera mở ngay (xem trước lúc đổ chuông) và đi kèm offer đầu tiên.
    await c.start(video: video, muted: muted);
    if (_client == c && c.localVideo != null) {
      localVideo = c.localVideo;
      camera = true;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- nối lại khi rớt mạng

  /// Kết nối media đứt / nối lại được. Đứt: phiên hiện tại tự nối lại WebSocket và khởi động lại ICE;
  /// sau 12 giây chưa được thì vào lại cuộc gọi bằng phiên mới; 30 giây vẫn không được thì kết thúc.
  void _setHealthy(bool ok) {
    if (ok) {
      if (reconnecting) {
        debugPrint('[calls] connection recovered');
        _stopReconnect();
        notifyListeners();
      }
      return;
    }
    if (phase != CallPhase.active && phase != CallPhase.outgoing && phase != CallPhase.connecting) return;
    if (reconnecting) return;
    debugPrint('[calls] connection lost, reconnecting');
    reconnecting = true;
    _lostAt = DateTime.now();
    _rejoinTimer?.cancel();
    _rejoinTimer = Timer(const Duration(seconds: 12), _rejoin);
    _giveUp?.cancel();
    _giveUp = Timer(const Duration(seconds: 30), () {
      if (reconnecting && busy) _end(tr('Mất kết nối'));
    });
    notifyListeners();
  }

  void _stopReconnect() {
    reconnecting = false;
    _lostAt = null;
    _rejoinTimer?.cancel();
    _rejoinTimer = null;
    _giveUp?.cancel();
    _giveUp = null;
  }

  /// Vào lại cuộc gọi bằng phiên mới (không gửi `leave` để người kia không thấy mình rời đi).
  Future<void> _rejoin() async {
    if (!busy || phase == CallPhase.incoming || _rejoining) return;
    if (!reconnecting) {
      // Phiên báo mất hẳn trước khi media báo đứt.
      _setHealthy(false);
    }
    _rejoinTimer?.cancel();
    _rejoining = true;
    debugPrint('[calls] rejoining call');
    final old = _client;
    _client = null;
    old?.abandon();
    // Track của người khác thuộc kết nối cũ: bỏ, phiên mới sẽ nhận lại.
    for (final p in _people.values) {
      _dropVideo(p);
      _dropScreen(p);
    }
    _audio.clear();
    final cam = camera;
    camera = false;
    localVideo = null;
    notifyListeners();
    try {
      await _connect(video: cam, rejoin: true);
    } catch (e) {
      debugPrint('[calls] rejoin: $e');
      _client = null;
      _rejoining = false;
      _retryRejoin();
      return;
    }
    _rejoining = false;
  }

  void _retryRejoin() {
    if (!reconnecting || !busy) return;
    final lost = _lostAt;
    if (lost != null && DateTime.now().difference(lost) > const Duration(seconds: 28)) return;
    _rejoinTimer?.cancel();
    _rejoinTimer = Timer(const Duration(seconds: 2), _rejoin);
  }

  // ---------------------------------------------------------------- chia sẻ màn hình (máy tính)

  /// Bắt đầu chia sẻ một màn hình / cửa sổ ([sourceId] từ `desktopCapturer.getSources`).
  /// Trả về lỗi để hiện cho người dùng, null nếu được.
  Future<String?> startScreenShare(String sourceId) async {
    final c = _client;
    if (c == null || localScreen != null) return null;
    if (!screenAllowed) return tr('Máy chủ không cho phép chia sẻ màn hình');
    if (_people.values.any((p) => p.screen)) return tr('Người khác đang chia sẻ màn hình');
    MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': sourceId},
          'mandatory': {'frameRate': 15.0},
        },
      });
    } catch (e) {
      debugPrint('[calls] getDisplayMedia: $e');
      return tr('Không chia sẻ được màn hình. Kiểm tra quyền ghi màn hình của ứng dụng.');
    }
    if (_client != c || !busy) {
      for (final t in stream.getTracks()) {
        t.stop();
      }
      return null;
    }
    localScreen = stream;
    // Người dùng dừng chia sẻ từ hệ điều hành / cửa sổ bị đóng.
    stream.getVideoTracks().firstOrNull?.onEnded = () {
      if (localScreen == stream) stopScreenShare();
    };
    notifyListeners();
    try {
      await c.startScreen(stream);
    } catch (e) {
      debugPrint('[calls] share screen: $e');
      await stopScreenShare();
      return tr('Không chia sẻ được màn hình');
    }
    return null;
  }

  Future<void> stopScreenShare() async {
    final s = localScreen;
    if (s == null) return;
    localScreen = null;
    notifyListeners();
    try {
      await _client?.stopScreen();
    } catch (_) {}
    _disposeScreen(s);
  }

  void _disposeScreen(MediaStream s) {
    for (final t in s.getTracks()) {
      try {
        t.stop();
      } catch (_) {}
    }
    s.dispose().catchError((_) {});
  }

  void _reset() {
    _stopReconnect();
    muted = false;
    speaker = false;
    camera = false;
    localVideo = null;
    startedAt = null;
    endReason = null;
    meSpeaking = false;
    remoteUsers.clear();
    _people.clear();
    _audio.clear();
  }

  void _end(String reason) {
    _watch?.cancel();
    debugPrint('[calls] end: $reason (phase $phase)');
    if (phase == CallPhase.idle || phase == CallPhase.ended) return;
    _noAnswer?.cancel();
    _hangSoon?.cancel();
    _stopRing();
    _stopReconnect();
    _rejoining = false;
    _client?.leave();
    _client = null;
    final scr = localScreen;
    localScreen = null;
    if (scr != null) _disposeScreen(scr);
    _audio.clear();
    _people.clear();
    meSpeaking = false;
    camera = false;
    localVideo = null;
    endReason = reason;
    phase = CallPhase.ended;
    notifyListeners();
    Timer(const Duration(seconds: 2), () {
      if (phase == CallPhase.ended) {
        phase = CallPhase.idle;
        channelId = null;
        notifyListeners();
      }
    });
  }

  void _startRing() {
    _ringBuzz?.cancel();
    HapticFeedback.heavyImpact();
    // Nhạc chuông theo nhóm (cài trong thông tin nhóm).
    Ringtones.ring(channelId ?? '');
    _ringBuzz = Timer.periodic(const Duration(milliseconds: 1500), (_) => HapticFeedback.heavyImpact());
  }

  void _stopRing() {
    _ringBuzz?.cancel();
    _ringBuzz = null;
    Ringtones.stop();
  }

  /// Sự kiện Calls trên WebSocket chính của app.
  void onWsEvent(WsEvent e) {
    final ev = e.event.substring(callsEventPrefix.length + 1);
    final ch = (e.data['channelID'] as String?) ?? e.channelId;
    switch (ev) {
      case 'call_start':
        final owner = e.data['owner_id'] as String? ?? '';
        if (ch != null) {
          ongoing.putIfAbsent(ch, () => {});
          if (owner.isNotEmpty) ongoing[ch]!.add(owner);
          notifyListeners();
        }
        if (ch == null || owner == myId() || busy || !isDirectOrGroup(ch)) return;
        channelId = ch;
        callerId = owner;
        meeting = false;
        incomingVideo = false;
        groupRing = false;
        _reset();
        phase = CallPhase.incoming;
        _startRing();
        notifyListeners();
        onShowCallScreen?.call();
        Timer(const Duration(seconds: 45), () {
          if (phase == CallPhase.incoming && channelId == ch) _end(tr('Cuộc gọi nhỡ'));
        });
      case 'call_end':
        if (ch != null && ongoing.remove(ch) != null) notifyListeners();
        if (ch != null && ch == channelId && busy) {
          phase == CallPhase.incoming ? _end(tr('Cuộc gọi nhỡ')) : hangUp();
        }
      case 'user_joined':
        final uid = e.data['user_id'] as String? ?? e.data['userID'] as String?;
        if (ch != null && uid != null) {
          ongoing.putIfAbsent(ch, () => {}).add(uid);
          notifyListeners();
        }
        if (uid != null && uid == myId()) {
          // Mình vào cuộc gọi từ thiết bị khác trong lúc máy này đang đổ chuông: thôi đổ chuông.
          if (ch == channelId && phase == CallPhase.incoming) {
            _end(tr('Đã trả lời trên thiết bị khác'));
          } else if (!busy && ch != null && isDirectOrGroup(ch)) {
            PushService.endCalls();
          }
          return;
        }
        if (ch != channelId || uid == null) return;
        final sid = e.data['session_id'] as String? ?? '';
        if (sid.isNotEmpty) _people.putIfAbsent(sid, () => CallParticipant(sid, uid)).userId = uid;
        _hangSoon?.cancel();
        remoteUsers.add(uid);
        if (phase == CallPhase.outgoing) {
          _noAnswer?.cancel();
          phase = CallPhase.active;
          startedAt = DateTime.now();
        }
        notifyListeners();
      case 'user_left':
        final uid = e.data['user_id'] as String? ?? e.data['userID'] as String?;
        if (ch != null && uid != null && ongoing[ch]?.remove(uid) == true) {
          // Có thể còn phiên khác của cùng người: đọc lại cho chắc.
          if (ongoing[ch]!.isEmpty) ongoing.remove(ch);
          notifyListeners();
          if (ch != channelId) _othersInCall(ch);
        }
        if (ch != channelId || uid == null || uid == myId()) return;
        final sid = e.data['session_id'] as String? ?? '';
        if (sid.isNotEmpty) {
          _people.remove(sid);
        } else {
          _people.removeWhere((_, p) => p.userId == uid);
        }
        _syncRemoteUsers();
        // Cuộc họp: ở lại một mình vẫn được, mọi người vào lúc nào cũng được. Gọi thường: chờ vài giây
        // trước khi gác máy vì người kia có thể đang tự vào lại sau khi rớt mạng (phiên mới).
        if (phase == CallPhase.active && remoteUsers.isEmpty && !meeting) {
          _hangSoon?.cancel();
          _hangSoon = Timer(const Duration(seconds: 8), () {
            if (phase == CallPhase.active && channelId == ch && remoteUsers.isEmpty && !meeting) hangUp();
          });
        }
        notifyListeners();
      case 'user_dismissed_notification':
        // Mình bấm từ chối trên thiết bị khác (máy chủ chỉ báo cho chính mình).
        final uid = e.data['userID'] as String? ?? e.data['user_id'] as String?;
        if (uid != null && uid != myId()) return;
        if (phase == CallPhase.incoming) {
          _end(tr('Đã từ chối trên thiết bị khác'));
        } else if (!busy) {
          PushService.endCalls();
        }
      default:
        // Mic, đang nói, camera, chia sẻ màn hình, trạng thái cuộc gọi của chính cuộc gọi đang tham gia.
        if (busy && phase != CallPhase.incoming && (ch == null || ch.isEmpty || ch == channelId)) _onPeerEvent(ev, e.data);
    }
  }

  @override
  void dispose() {
    _stopReconnect();
    _client?.leave();
    _noAnswer?.cancel();
    _stopRing();
    super.dispose();
  }
}
