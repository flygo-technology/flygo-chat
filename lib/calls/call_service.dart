import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'ringtones.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api/mm_api.dart';
import '../api/mm_ws.dart';
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
  final DateTime joinedAt = DateTime.now();

  CallParticipant(this.sessionId, this.userId);

  bool get hasVideo => video && videoStream != null;
  bool get hasScreen => screen && screenStream != null;
}

/// Trạng thái cuộc gọi hiện tại; nghe sự kiện Calls trên WebSocket chính.
class CallService extends ChangeNotifier {
  final MmApi api;
  final String Function() myId;
  final bool Function(String channelId) isDirectOrGroup;

  CallService({required this.api, required this.myId, required this.isDirectOrGroup});

  CallPhase phase = CallPhase.idle;
  String? channelId;
  String? callerId;
  String? endReason;
  bool muted = false;
  bool speaker = false;
  bool camera = false;
  bool _wantVideo = false;
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

  bool get busy => phase != CallPhase.idle && phase != CallPhase.ended;

  Future<List<Map<String, dynamic>>> _iceServers() async {
    final cfg = (await api.get('/plugins/$callsPluginId/config') as Map).cast<String, dynamic>();
    final servers = <Map<String, dynamic>>[
      for (final s in (cfg['ICEServersConfigs'] as List? ?? [])) (s as Map).cast<String, dynamic>(),
    ];
    if (cfg['NeedsTURNCredentials'] == true) {
      try {
        final turn = await api.get('/plugins/$callsPluginId/turn-credentials') as List;
        servers.addAll(turn.map((e) => (e as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    return servers;
  }

  /// Gọi đi (hoặc tham gia cuộc gọi đang diễn ra) trong một cuộc trò chuyện.
  Future<void> startCall(String channel, {bool video = false}) async {
    if (busy) return;
    _wantVideo = video;
    channelId = channel;
    callerId = myId();
    phase = CallPhase.outgoing;
    _reset();
    notifyListeners();
    onShowCallScreen?.call();
    await _join();
    if (video) {
      // Gọi video: bật camera và loa ngoài ngay, không chờ người kia bắt máy.
      speaker = true;
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
    _noAnswer = Timer(Duration(seconds: 50), () {
      if (phase == CallPhase.outgoing) hangUp(reason: tr('Không có người trả lời'));
    });
  }

  Future<void> accept() async {
    if (phase != CallPhase.incoming) return;
    _stopRing();
    phase = CallPhase.connecting;
    notifyListeners();
    await _join();
  }

  /// Đã bấm "Trả lời" trên màn hình cuộc gọi của hệ điều hành (app có thể vừa được mở lên).
  Future<void> acceptFromSystem(String channel) async {
    if (phase == CallPhase.incoming && channelId == channel) return accept();
    if (busy) return;
    channelId = channel;
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
    if (ch != null) {
      try {
        await api.post('/plugins/$callsPluginId/calls/$ch/dismiss-notification', null);
      } catch (_) {}
    }
  }

  Future<void> hangUp({String? reason}) async {
    reason ??= tr('Cuộc gọi đã kết thúc');
    _stopRing();
    _watch?.cancel();
    final ch = channelId;
    final c = _client;
    _client = null;
    await c?.leave();
    _end(reason);
    // Gọi 1-1 / nhóm nhỏ: một bên gác máy thì kết thúc cuộc gọi cho cả hai bên (chủ cuộc gọi mới có quyền;
    // bên kia vẫn tự gác nhờ kiểm tra định kỳ bên dưới).
    if (ch != null && isDirectOrGroup(ch)) {
      try {
        await api.post('/plugins/$callsPluginId/calls/$ch/end', null);
      } catch (_) {}
    }
  }

  /// Kiểm tra định kỳ cuộc gọi 1-1 / nhóm nhỏ: còn mỗi mình (người kia đã gác máy, kể cả khi lỡ mất
  /// sự kiện trên WebSocket) thì tự gác máy.
  Timer? _watch;
  int _aloneTicks = 0;

  void _startWatch() {
    _watch?.cancel();
    _aloneTicks = 0;
    final ch = channelId;
    if (ch == null) return;
    final small = isDirectOrGroup(ch);
    _syncState(ch);
    _watch = Timer.periodic(Duration(seconds: small ? 3 : 6), (_) async {
      if (phase != CallPhase.active || channelId != ch) return;
      final others = await _syncState(ch);
      if (others == null || !small) return; // lỗi mạng: thử lại lần sau
      _aloneTicks = others == 0 ? _aloneTicks + 1 : 0;
      if (_aloneTicks >= 2 && phase == CallPhase.active && channelId == ch) hangUp();
    });
  }

  /// Đọc trạng thái cuộc gọi của kênh (`GET /plugins/com.mattermost.calls/<kênh>`), cập nhật danh sách
  /// người tham gia và trả về số người khác đang trong cuộc gọi (null nếu không đọc được).
  Future<int?> _syncState(String ch) async {
    try {
      final r = (await api.get('/plugins/$callsPluginId/$ch') as Map).cast<String, dynamic>();
      if (channelId != ch || !busy) return null;
      final call = (r['call'] as Map?)?.cast<String, dynamic>();
      if (call == null || ((call['end_at'] as num?) ?? 0) > 0) return 0;
      _applyCallState(call);
      final ids = <String>{
        for (final u in (call['users'] as List? ?? const [])) if (u is String) u,
        for (final s in _sessionsOf(call)) if (s['user_id'] is String) s['user_id'] as String,
      };
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
  void _applyCallState(Map<String, dynamic> call) {
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
      if (s.containsKey('video')) p.video = s['video'] == true;
      p.screen = sid == screenSid;
      if (!p.video) _dropVideo(p);
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
    switch (type) {
      case 'video':
        p.video = true;
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
        p.video = false;
        _dropVideo(p);
      case 'user_screen_on':
        p.screen = true;
      case 'user_screen_off':
        p.screen = false;
        _dropScreen(p);
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

  Future<void> _join() async {
    try {
      final servers = await _iceServers();
      final c = CallsClient(
        token: api.token,
        channelId: channelId!,
        iceServers: servers,
        onConnected: () {
          if (phase == CallPhase.connecting) {
            phase = CallPhase.active;
            startedAt = DateTime.now();
          }
          _startWatch();
          notifyListeners();
          if (_wantVideo && !camera) {
            _wantVideo = false;
            toggleCamera();
          }
        },
        onRemoteTrack: _onRemoteTrack,
        onRemoteTrackEnded: _onRemoteTrackEnded,
        onEvent: (ev, data) {
          // user_joined / user_left đã xử lý qua WebSocket chính (kèm logic gác máy).
          if (ev != 'user_joined' && ev != 'user_left') _onPeerEvent(ev, data);
        },
        onClosed: (reason) => _end(reason),
      );
      _client = c;
      await c.start();
    } catch (e, st) {
      debugPrint('[calls] join failed: $e\n$st');
      _end(tr('Không bắt đầu được cuộc gọi. Kiểm tra quyền micro và kết nối mạng.'));
    }
  }

  void _reset() {
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
    _stopRing();
    _client?.leave();
    _client = null;
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
        if (ch == null || owner == myId() || busy || !isDirectOrGroup(ch)) return;
        channelId = ch;
        callerId = owner;
        _reset();
        phase = CallPhase.incoming;
        _startRing();
        notifyListeners();
        onShowCallScreen?.call();
        Timer(const Duration(seconds: 45), () {
          if (phase == CallPhase.incoming && channelId == ch) _end(tr('Cuộc gọi nhỡ'));
        });
      case 'call_end':
        if (ch != null && ch == channelId && busy) {
          phase == CallPhase.incoming ? _end(tr('Cuộc gọi nhỡ')) : hangUp();
        }
      case 'user_joined':
        final uid = e.data['user_id'] as String? ?? e.data['userID'] as String?;
        if (ch != channelId || uid == null || uid == myId()) return;
        final sid = e.data['session_id'] as String? ?? '';
        if (sid.isNotEmpty) _people.putIfAbsent(sid, () => CallParticipant(sid, uid)).userId = uid;
        remoteUsers.add(uid);
        if (phase == CallPhase.outgoing) {
          _noAnswer?.cancel();
          phase = CallPhase.active;
          startedAt = DateTime.now();
        }
        notifyListeners();
      case 'user_left':
        final uid = e.data['user_id'] as String? ?? e.data['userID'] as String?;
        if (ch != channelId || uid == null || uid == myId()) return;
        final sid = e.data['session_id'] as String? ?? '';
        if (sid.isNotEmpty) {
          _people.remove(sid);
        } else {
          _people.removeWhere((_, p) => p.userId == uid);
        }
        _syncRemoteUsers();
        if (phase == CallPhase.active && remoteUsers.isEmpty) hangUp();
        notifyListeners();
      default:
        // Mic, đang nói, camera, chia sẻ màn hình, trạng thái cuộc gọi của chính cuộc gọi đang tham gia.
        if (busy && phase != CallPhase.incoming && (ch == null || ch.isEmpty || ch == channelId)) _onPeerEvent(ev, e.data);
    }
  }

  @override
  void dispose() {
    _client?.leave();
    _noAnswer?.cancel();
    _stopRing();
    super.dispose();
  }
}
