import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api/mm_api.dart';
import '../api/mm_ws.dart';
import 'calls_client.dart';

enum CallPhase { idle, incoming, outgoing, connecting, active, ended }

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
  MediaStream? remoteVideo;
  DateTime? startedAt;
  final Set<String> remoteUsers = {};
  CallsClient? _client;
  Timer? _noAnswer;
  Timer? _ringBuzz;
  MediaStream? _remote;

  /// Gọi khi cần đẩy màn hình cuộc gọi lên (main.dart gắn vào).
  void Function()? onShowCallScreen;

  bool get busy => phase != CallPhase.idle && phase != CallPhase.ended;

  Future<List<Map<String, dynamic>>> _iceServers() async {
    final cfg = (await api.get('/plugins/$callsPluginId/config') as Map).cast<String, dynamic>();
    final servers = <Map<String, dynamic>>[
      for (final s in (cfg['ICEServersConfigs'] as List? ?? const [])) (s as Map).cast<String, dynamic>(),
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
    _noAnswer = Timer(const Duration(seconds: 50), () {
      if (phase == CallPhase.outgoing) hangUp(reason: 'Không có người trả lời');
    });
  }

  Future<void> accept() async {
    if (phase != CallPhase.incoming) return;
    _stopRing();
    phase = CallPhase.connecting;
    notifyListeners();
    await _join();
  }

  Future<void> decline() async {
    if (phase != CallPhase.incoming) return;
    final ch = channelId;
    _stopRing();
    _end('Đã từ chối');
    if (ch != null) {
      try {
        await api.post('/plugins/$callsPluginId/calls/$ch/dismiss-notification', null);
      } catch (_) {}
    }
  }

  Future<void> hangUp({String reason = 'Cuộc gọi đã kết thúc'}) async {
    _stopRing();
    final c = _client;
    _client = null;
    await c?.leave();
    _end(reason);
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
          notifyListeners();
          if (_wantVideo && !camera) {
            _wantVideo = false;
            toggleCamera();
          }
        },
        onRemoteVideo: (s) {
          remoteVideo = s;
          notifyListeners();
        },
        onClosed: (reason) => _end(reason),
        onRemoteStream: (s) => _remote = s,
      );
      _client = c;
      await c.start();
    } catch (e, st) {
      debugPrint('[calls] join failed: $e\n$st');
      _end('Không bắt đầu được cuộc gọi. Kiểm tra quyền micro và kết nối mạng.');
    }
  }

  void _reset() {
    muted = false;
    speaker = false;
    camera = false;
    localVideo = null;
    remoteVideo = null;
    startedAt = null;
    endReason = null;
    remoteUsers.clear();
  }

  void _end(String reason) {
    debugPrint('[calls] end: $reason (phase $phase)');
    if (phase == CallPhase.idle || phase == CallPhase.ended) return;
    _noAnswer?.cancel();
    _stopRing();
    _client?.leave();
    _client = null;
    _remote = null;
    camera = false;
    localVideo = null;
    remoteVideo = null;
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
    SystemSound.play(SystemSoundType.alert);
    _ringBuzz = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    });
  }

  void _stopRing() {
    _ringBuzz?.cancel();
    _ringBuzz = null;
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
          if (phase == CallPhase.incoming && channelId == ch) _end('Cuộc gọi nhỡ');
        });
      case 'call_end':
        if (ch != null && ch == channelId && busy) {
          phase == CallPhase.incoming ? _end('Cuộc gọi nhỡ') : hangUp();
        }
      case 'user_joined':
        final uid = e.data['user_id'] as String? ?? e.data['userID'] as String?;
        if (ch != channelId || uid == null || uid == myId()) return;
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
        remoteUsers.remove(uid);
        if (phase == CallPhase.active && remoteUsers.isEmpty) hangUp();
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _client?.leave();
    _noAnswer?.cancel();
    _stopRing();
    super.dispose();
  }

  // Giữ tham chiếu để luồng âm thanh phía xa không bị thu hồi.
  MediaStream? get remoteStream => _remote;
}
