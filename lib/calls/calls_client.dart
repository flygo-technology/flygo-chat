import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

import '../config.dart';

const callsPluginId = 'com.mattermost.calls';
const callsEventPrefix = 'custom_$callsPluginId';

// Tin trên data channel (rtcd/service/rtc/dc/msg.go): msgpack phẳng, loại tin rồi đến nội dung.
const _dcLock = 7;
const _dcUnlock = 8;
const _dcMediaMap = 9;

const _trackTypes = {'voice', 'screen', 'screen-audio', 'video'};

/// Kết nối thoại / video tới plugin Calls của Mattermost (SFU rtcd tích hợp).
/// Giao thức theo calls-common: WebSocket riêng, SDP nén zlib gói msgpack,
/// ICE gửi dạng JSON, tín hiệu từ server về qua sự kiện `_signal`.
///
/// Thương lượng lại (bật camera lần đầu) làm như client chính thức: xin khoá tín hiệu qua
/// data channel trước khi gửi offer để SFU không gửi offer của nó cùng lúc (va chạm offer làm
/// SFU bỏ offer của mình và kẹt luôn phiên: mất hình cả hai chiều). Loại track của người khác
/// lấy từ bảng `MediaMap` (mid → loại, phiên người gửi) SFU gửi qua data channel.
class CallsClient {
  final String token;
  final String channelId;
  final List<Map<String, dynamic>> iceServers;
  final void Function() onConnected;
  final void Function(String reason) onClosed;
  /// Có luồng từ người khác: [type] là `voice` / `video` / `screen` / `screen-audio`,
  /// [sessionId] là phiên Calls của người gửi.
  final void Function(String type, String sessionId, MediaStream stream, MediaStreamTrack track) onRemoteTrack;
  final void Function(String trackId) onRemoteTrackEnded;
  /// Sự kiện Calls (`user_muted`, `user_voice_on`...) nhận trên WebSocket riêng của cuộc gọi.
  final void Function(String event, Map<String, dynamic> data)? onEvent;

  WebSocket? _ws;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _local;
  String _connId = '';
  int _seq = 1;
  bool _closed = false;
  bool _connected = false;
  bool _joined = false;
  final List<RTCIceCandidate> _pendingRemote = [];
  Timer? _ping;
  Timer? _timeout;

  // Thương lượng.
  Future<void> _sig = Future.value();
  bool _dcOpen = false;
  /// Offer đầu tiên đã được trả lời (từ đó mới cần khoá tín hiệu).
  bool _negotiated = false;
  bool _awaitingAnswer = false;
  bool _renegPending = false;
  bool _renegLater = false;
  bool _holdLock = false;
  Future<bool>? _locking;
  Completer<bool>? _lockReply;
  Timer? _lockTimer;

  // Bảng loại track của SFU và các track đã nhận theo mid.
  Map<String, Map<String, dynamic>> _mediaMap = {};
  final Map<String, (MediaStream, MediaStreamTrack, String, String)> _byMid = {};

  CallsClient({
    required this.token,
    required this.channelId,
    required this.iceServers,
    required this.onConnected,
    required this.onClosed,
    required this.onRemoteTrack,
    required this.onRemoteTrackEnded,
    this.onEvent,
  });

  /// Id phiên của mình trong cuộc gọi (= connection_id của WebSocket riêng khi tham gia).
  String get sessionId => _connId;

  MediaStream? _video;
  RTCRtpSender? _videoSender;
  MediaStream? get localVideo => _video;

  bool get muted => !(_local?.getAudioTracks().firstOrNull?.enabled ?? false);

  /// [video]: mở camera ngay và gửi kèm trong offer đầu tiên (không phải thương lượng lại).
  Future<void> start({bool video = false}) async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    if (video) {
      try {
        _video = await _openCamera(true);
      } catch (e) {
        debugPrint('[calls] camera: $e');
      }
    }
    final url = '${kServerUrl.replaceFirst('http', 'ws')}/api/v4/websocket?connection_id=&sequence_number=0';
    _ws = await WebSocket.connect(url, headers: {'Authorization': 'Bearer $token', 'User-Agent': kUserAgent})
        .timeout(const Duration(seconds: 15));
    _ws!.listen(_onMessage, onDone: () => _fail(tr('Mất kết nối tới máy chủ')), onError: (_) => _fail(tr('Mất kết nối tới máy chủ')));
    _sendRaw({'action': 'authentication_challenge', 'seq': _seq++, 'data': {'token': token}});
    _ping = Timer.periodic(const Duration(seconds: 5), (_) => _sendRaw({'action': 'ping', 'seq': _seq++}));
    _timeout = Timer(const Duration(seconds: 30), () {
      if (!_connected) _fail(tr('Không kết nối được cuộc gọi'));
    });
  }

  Future<MediaStream> _openCamera(bool front) => navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': front ? 'user' : 'environment',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'ideal': 30},
        },
      });

  void _sendRaw(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  void _send(String action, [Map<String, dynamic>? data, bool binary = false]) {
    final msg = {'action': '${callsEventPrefix}_$action', 'seq': _seq++, 'data': data};
    try {
      if (binary) {
        _ws?.add(msgpack.serialize(msg));
      } else {
        _ws?.add(jsonEncode(msg));
      }
    } catch (_) {}
  }

  Future<void> _onMessage(dynamic raw) async {
    if (raw is! String) return;
    if (raw.contains('calls')) debugPrint('[calls] ws <- ${raw.length > 300 ? raw.substring(0, 300) : raw}');
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final ev = msg['event'] as String?;
    final data = (msg['data'] as Map?)?.cast<String, dynamic>();
    if (ev == null || data == null) return;
    if (ev == 'hello') {
      _connId = data['connection_id'] as String? ?? '';
      if (!_joined) {
        _joined = true;
        _send('join', {'channelID': channelId});
      }
      return;
    }
    final cid = data['connID'];
    if (cid != null && cid != _connId) return;
    if (ev == '${callsEventPrefix}_join') {
      await _initPeer();
    } else if (ev == '${callsEventPrefix}_error') {
      _fail(tr('Máy chủ từ chối cuộc gọi: {0}', [data['data']]));
    } else if (ev == '${callsEventPrefix}_signal') {
      _onSignal(data['data'] as String);
    } else if (ev.startsWith(callsEventPrefix)) {
      onEvent?.call(ev.substring(callsEventPrefix.length + 1), data);
    }
  }

  /// Chạy lần lượt các bước tín hiệu (offer/answer) để không chồng lên nhau.
  Future<void> _serial(String what, Future<void> Function() f) {
    final next = _sig.then((_) async {
      if (_closed) return;
      try {
        await f();
      } catch (e) {
        debugPrint('[calls] $what: $e');
      }
    });
    _sig = next;
    return next;
  }

  Future<void> _initPeer() async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      _send('ice', {
        'data': jsonEncode({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}),
      });
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected && !_connected) {
        _connected = true;
        _timeout?.cancel();
        _send('unmute');
        onConnected();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail(tr('Kết nối cuộc gọi bị lỗi'));
      }
    };
    pc.onTrack = _onTrack;
    pc.onRemoveTrack = (stream, track) => onRemoteTrackEnded(track.id ?? '');
    final dc = await pc.createDataChannel('calls-dc', RTCDataChannelInit());
    _dc = dc;
    dc.onDataChannelState = (s) {
      _dcOpen = s == RTCDataChannelState.RTCDataChannelOpen;
      if (!_dcOpen) _replyLock(false);
    };
    dc.onMessage = (m) {
      if (m.isBinary) _onDcMessage(m.binary);
    };
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    // Gọi video: camera đi luôn trong offer đầu, báo `video_on` (id luồng) trước khi gửi SDP
    // để SFU nhận ra track video ngay khi có gói tin đầu tiên.
    if (_video != null) {
      await _addVideoTransceiver(pc, _video!);
      _sendVideoOn();
    }
    await _serial('offer', () async {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _awaitingAnswer = true;
      _sendSdp(offer);
    });
    pc.onRenegotiationNeeded = _renegotiate;
  }

  Future<void> _addVideoTransceiver(RTCPeerConnection pc, MediaStream stream) async {
    final trx = await pc.addTransceiver(
      track: stream.getVideoTracks().first,
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv,
        streams: [stream],
        sendEncodings: [RTCRtpEncoding(maxBitrate: 1000 * 1000, maxFramerate: 30, scaleResolutionDownBy: 1.0)],
      ),
    );
    _videoSender = trx.sender;
  }

  void _sendVideoOn() {
    final v = _video;
    if (v == null) return;
    _send('video_on', {'data': jsonEncode({'videoStreamID': v.id})});
  }

  void _sendSdp(RTCSessionDescription d) {
    final payload = utf8.encode(jsonEncode({'type': d.type, 'sdp': d.sdp}));
    final compressed = Uint8List.fromList(ZLibCodec().encode(payload));
    _send('sdp', {'data': compressed}, true);
  }

  // ---------------------------------------------------------------- tín hiệu

  void _onSignal(String raw) {
    final pc = _pc;
    if (pc == null) return;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    switch (m['type']) {
      case 'candidate':
        final c = (m['candidate'] as Map).cast<String, dynamic>();
        final cand = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt());
        _addCandidate(pc, cand);
      case 'offer':
        _serial('answer', () async {
          if (_awaitingAnswer) {
            // Va chạm offer (không giữ được khoá): mình nhường, huỷ offer của mình rồi gửi lại sau.
            debugPrint('[calls] glare: rolling back local offer');
            try {
              await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
            } catch (e) {
              debugPrint('[calls] rollback: $e');
            }
            _awaitingAnswer = false;
            _renegLater = true;
          }
          await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'offer'));
          await _flush(pc);
          final ans = await pc.createAnswer();
          await pc.setLocalDescription(ans);
          _sendSdp(ans);
        }).then((_) {
          if (_renegLater && !_awaitingAnswer) {
            _renegLater = false;
            _renegotiate();
          }
        });
      case 'answer':
        _serial('answer in', () async {
          try {
            await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'answer'));
            await _flush(pc);
          } finally {
            _awaitingAnswer = false;
            _unlock();
          }
          _negotiated = true;
        }).then((_) {
          // Có thay đổi trong lúc chờ trả lời (vd. bật camera khi offer đầu chưa xong): thương lượng tiếp.
          if (_renegLater && !_awaitingAnswer) {
            _renegLater = false;
            _renegotiate();
          }
        });
    }
  }

  Future<void> _addCandidate(RTCPeerConnection pc, RTCIceCandidate cand) async {
    try {
      if (await pc.getRemoteDescription() != null) {
        await pc.addCandidate(cand);
      } else {
        _pendingRemote.add(cand);
      }
    } catch (e) {
      debugPrint('[calls] candidate: $e');
    }
  }

  Future<void> _flush(RTCPeerConnection pc) async {
    final list = [..._pendingRemote];
    _pendingRemote.clear();
    for (final c in list) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
  }

  /// Gửi offer mới khi cần (vd. bật camera lần đầu): giữ khoá tín hiệu của SFU trước.
  Future<void> _renegotiate() async {
    final pc = _pc;
    if (_closed || pc == null) return;
    if (!_negotiated || _awaitingAnswer) {
      _renegLater = true;
      return;
    }
    if (_renegPending) return;
    _renegPending = true;
    try {
      // Xin khoá ngoài hàng đợi tín hiệu: trong lúc chờ vẫn trả lời được offer của SFU.
      if (!_holdLock) await _grabLock();
      await _serial('reoffer', () async {
        if (_awaitingAnswer) return;
        final o = await pc.createOffer();
        await pc.setLocalDescription(o);
        _awaitingAnswer = true;
        _sendSdp(o);
      });
      if (!_awaitingAnswer) _unlock();
    } finally {
      _renegPending = false;
    }
  }

  // ---------------------------------------------------------------- data channel

  void _dcSend(int type) {
    final dc = _dc;
    if (dc == null || !_dcOpen) return;
    try {
      dc.send(RTCDataChannelMessage.fromBinary(msgpack.serialize(type)));
    } catch (e) {
      debugPrint('[calls] dc send: $e');
    }
  }

  void _onDcMessage(Uint8List data) {
    int? type;
    dynamic payload;
    try {
      final d = msgpack.Deserializer(data);
      type = d.decode() as int?;
      try {
        payload = d.decode();
      } catch (_) {}
    } catch (e) {
      debugPrint('[calls] dc decode: $e');
      return;
    }
    switch (type) {
      case _dcLock:
        _replyLock(payload == true);
      case _dcMediaMap:
        if (payload is Map) {
          _mediaMap = {
            for (final e in payload.entries)
              if (e.value is Map) '${e.key}': (e.value as Map).cast<String, dynamic>(),
          };
          _remapTracks();
        }
    }
  }

  /// Khoá tín hiệu của phiên trên SFU (như `grabSignalingLock` của calls-common).
  /// Không lấy được trong 5 giây thì vẫn làm tiếp (đã có xử lý va chạm offer).
  Future<bool> _grabLock() => _locking ??= () async {
        try {
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (!_closed && _dcOpen && DateTime.now().isBefore(until)) {
            final c = _lockReply = Completer<bool>();
            _dcSend(_dcLock);
            final ok = await c.future.timeout(const Duration(seconds: 2), onTimeout: () => false);
            if (ok) {
              _holdLock = true;
              _lockTimer?.cancel();
              _lockTimer = Timer(const Duration(seconds: 5), _unlock);
              return true;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          debugPrint('[calls] signaling lock not acquired');
          return false;
        } finally {
          _locking = null;
        }
      }();

  void _replyLock(bool ok) {
    final c = _lockReply;
    _lockReply = null;
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _unlock() {
    _lockTimer?.cancel();
    if (!_holdLock) return;
    _holdLock = false;
    _dcSend(_dcUnlock);
  }

  // ---------------------------------------------------------------- track của người khác

  void _onTrack(RTCTrackEvent e) {
    final track = e.track;
    final mid = e.transceiver?.mid ?? 'track:${track.id}';
    final stream = e.streams.firstOrNull;
    if (stream != null) {
      _emitTrack(mid, stream, track);
    } else {
      createLocalMediaStream('remote_${track.id}').then((s) {
        s.addTrack(track);
        _emitTrack(mid, s, track);
      });
    }
  }

  /// Loại track và phiên người gửi: bảng MediaMap của SFU; chưa có thì đoán theo id
  /// (`<loại>_<phiên>_<ngẫu nhiên>`, chỉ đúng khi id track phía nhận giữ id của SFU)
  /// hoặc theo id luồng (= phiên người gửi) và loại media.
  (String, String) _resolve(String mid, MediaStream stream, MediaStreamTrack track) {
    final info = _mediaMap[mid];
    final type = info?['type'] as String?;
    final sender = info?['sender_id'] as String?;
    if (type != null && type.isNotEmpty && sender != null && sender.isNotEmpty) return (type, sender);
    final parts = (track.id ?? '').split('_');
    if (parts.length == 3 && _trackTypes.contains(parts[0])) return (parts[0], parts[1]);
    return (track.kind == 'video' ? 'video' : 'voice', stream.id);
  }

  void _emitTrack(String mid, MediaStream stream, MediaStreamTrack track) {
    if (_closed) return;
    final (type, session) = _resolve(mid, stream, track);
    debugPrint('[calls] track ${track.kind} ${track.id} mid=$mid type=$type session=$session');
    _byMid[mid] = (stream, track, type, session);
    track.onEnded = () => onRemoteTrackEnded(track.id ?? '');
    onRemoteTrack(type, session, stream, track);
  }

  /// Bảng MediaMap đến sau track: sửa lại loại / người gửi của các track đã báo.
  void _remapTracks() {
    for (final e in [..._byMid.entries]) {
      final (stream, track, type, session) = e.value;
      final (t2, s2) = _resolve(e.key, stream, track);
      if (t2 != type || s2 != session) _emitTrack(e.key, stream, track);
    }
  }

  // ---------------------------------------------------------------- camera / mic

  /// Bật camera: lần đầu thêm luồng video (1 Mbps, 30 khung hình/giây như web client) và thương
  /// lượng lại; các lần sau chỉ thay track. Báo `video_on` kèm id luồng.
  Future<MediaStream?> startVideo({bool front = true}) async {
    if (_closed) return null;
    final stream = await _openCamera(front);
    final old = _video;
    _video = stream;
    if (old != null && old != stream) {
      for (final t in old.getTracks()) {
        t.stop();
      }
      await old.dispose();
    }
    final pc = _pc;
    // Chưa có kết nối: camera sẽ đi kèm offer đầu tiên.
    if (pc == null) return stream;
    final track = stream.getVideoTracks().first;
    if (_videoSender != null) {
      await _videoSender!.replaceTrack(track);
      _sendVideoOn();
      return stream;
    }
    if (_negotiated) await _grabLock();
    await _addVideoTransceiver(pc, stream);
    _sendVideoOn();
    _renegotiate();
    return stream;
  }

  Future<void> stopVideo() async {
    await _videoSender?.replaceTrack(null);
    for (final t in _video?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    await _video?.dispose();
    _video = null;
    _send('video_off');
  }

  Future<void> switchCamera() async {
    final t = _video?.getVideoTracks().firstOrNull;
    if (t != null) await Helper.switchCamera(t);
  }

  void setMuted(bool mute) {
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !mute;
    }
    _send(mute ? 'mute' : 'unmute');
  }

  void _fail(String reason) {
    if (_closed) return;
    _cleanup();
    onClosed(reason);
  }

  Future<void> leave() async {
    if (_closed) return;
    _send('leave');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _cleanup();
  }

  void _cleanup() {
    _closed = true;
    _ping?.cancel();
    _timeout?.cancel();
    _lockTimer?.cancel();
    _replyLock(false);
    try {
      _dc?.close();
    } catch (_) {}
    _pc?.close();
    for (final t in [...?_local?.getTracks(), ...?_video?.getTracks()]) {
      t.stop();
    }
    _local?.dispose();
    _video?.dispose();
    _ws?.close();
  }
}
