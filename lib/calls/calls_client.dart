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

// Nối lại WebSocket như client chính thức (webapp/src/websocket.ts): thử lại sau 1 giây, mỗi lần chậm
// thêm 0,5 giây, ping 5 giây. Plugin Calls chỉ giữ phiên ~10 giây sau khi mất WebSocket.
const _wsMinRetryMs = 1000;
const _wsRetryStepMs = 500;
const _wsPing = Duration(seconds: 5);
const _wsResumeWindow = Duration(seconds: 9);

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
  /// Kết nối media còn tốt không (false khi mạng rớt / đổi Wi-Fi ↔ 4G, đang tự nối lại).
  final void Function(bool ok)? onHealth;
  /// Phiên này không cứu được nữa (máy chủ đã bỏ phiên sau khi mất WebSocket quá lâu): cần vào lại cuộc gọi.
  final void Function()? onLost;

  WebSocket? _ws;
  /// Thế hệ WebSocket: sự kiện của socket cũ (đã bỏ) thì bỏ qua.
  int _wsGen = 0;
  bool _wsOpen = false;
  /// Phiên Calls gốc (= connection_id lúc tham gia); sau khi nối lại WebSocket máy chủ vẫn dùng id này.
  String _originalConnId = '';
  /// Số thứ tự tin tiếp theo từ máy chủ (để nối lại đúng chỗ, không mất sự kiện).
  int _serverSeq = 0;
  DateTime? _wsLostAt;
  int _retryMs = _wsMinRetryMs;
  Timer? _wsRetry;
  bool _waitingPong = false;
  int _pongSeq = 0;
  bool _joinAcked = false;
  bool _pcConnected = false;
  bool _healthy = true;
  Timer? _iceTimer;
  DateTime? _lastIceRestart;
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
  /// Track SFU đang gửi theo SDP mới nhất của nó: mid → (id luồng = phiên người gửi, id track thật).
  Map<String, (String, String)> _remoteMsid = {};

  CallsClient({
    required this.token,
    required this.channelId,
    required this.iceServers,
    required this.onConnected,
    required this.onClosed,
    required this.onRemoteTrack,
    required this.onRemoteTrackEnded,
    this.onEvent,
    this.onHealth,
    this.onLost,
  });

  /// Id phiên của mình trong cuộc gọi (= connection_id của WebSocket riêng khi tham gia).
  String get sessionId => _originalConnId.isNotEmpty ? _originalConnId : _connId;

  MediaStream? _video;
  RTCRtpSender? _videoSender;
  MediaStream? get localVideo => _video;

  bool get muted => !(_local?.getAudioTracks().firstOrNull?.enabled ?? false);

  /// [video]: mở camera ngay và gửi kèm trong offer đầu tiên (không phải thương lượng lại).
  /// [muted]: vào lại cuộc gọi (sau khi rớt mạng) mà mic đang tắt.
  Future<void> start({bool video = false, bool muted = false}) async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    _startMuted = muted;
    if (muted) {
      for (final t in _local!.getAudioTracks()) {
        t.enabled = false;
      }
    }
    if (video) {
      try {
        _video = await _openCamera(true);
      } catch (e) {
        debugPrint('[calls] camera: $e');
      }
    }
    _wsBase = '${kServerUrl.replaceFirst('http', 'ws')}/api/v4/websocket';
    await _openWs();
    _timeout = Timer(const Duration(seconds: 30), () {
      if (!_connected) _fail(tr('Không kết nối được cuộc gọi'));
    });
  }

  bool _startMuted = false;
  String _wsBase = '';

  // ---------------------------------------------------------------- WebSocket (nối lại như client chính thức)

  /// Mở WebSocket riêng của cuộc gọi. Nối lại: gửi kèm connection_id + số thứ tự để máy chủ giữ nguyên
  /// kết nối (gửi bù sự kiện bị lỡ), rồi báo `reconnect` với phiên gốc để plugin Calls giữ phiên trong cuộc gọi.
  Future<void> _openWs({bool reconnect = false}) async {
    final url = reconnect
        ? '$_wsBase?connection_id=$_connId&sequence_number=$_serverSeq'
        : '$_wsBase?connection_id=&sequence_number=0';
    final ws = await WebSocket.connect(url, headers: {'Authorization': 'Bearer $token', 'User-Agent': kUserAgent})
        .timeout(Duration(seconds: reconnect ? 6 : 15));
    if (_closed) {
      ws.close();
      return;
    }
    final gen = ++_wsGen;
    _ws = ws;
    _wsOpen = true;
    ws.listen(
      (m) {
        if (gen == _wsGen) _onMessage(m);
      },
      onDone: () => _wsClosed(gen),
      onError: (_) => _wsClosed(gen),
      cancelOnError: true,
    );
    _sendRaw({'action': 'authentication_challenge', 'seq': _seq++, 'data': {'token': token}});
    if (reconnect) {
      debugPrint('[calls] ws reconnected, original=$_originalConnId prev=$_connId');
      _send('reconnect', {'channelID': channelId, 'originalConnID': _originalConnId, 'prevConnID': _connId});
    }
    _waitingPong = false;
    _ping?.cancel();
    _ping = Timer.periodic(_wsPing, (_) => _doPing(gen));
  }

  /// Ping mỗi 5 giây; ping trước chưa có pong thì coi như mất kết nối (đổi mạng thường không báo đóng socket).
  void _doPing(int gen) {
    if (gen != _wsGen || _closed) return;
    if (_waitingPong) {
      debugPrint('[calls] ws ping timeout');
      try {
        _ws?.close();
      } catch (_) {}
      _wsClosed(gen);
      return;
    }
    _waitingPong = true;
    _pongSeq = _seq;
    _sendRaw({'action': 'ping', 'seq': _seq++});
  }

  void _wsClosed(int gen) {
    if (gen != _wsGen || _closed) return;
    _wsGen++;
    _wsOpen = false;
    _ws = null;
    _ping?.cancel();
    if (!_joinAcked) {
      _fail(tr('Mất kết nối tới máy chủ'));
      return;
    }
    _wsLostAt ??= DateTime.now();
    _health();
    // Media vẫn chạy thì chờ chút mới báo mất kết nối: WebSocket thường nối lại trong 1–2 giây,
    // khỏi nháy "Đang kết nối lại…".
    _healthTimer?.cancel();
    _healthTimer = Timer(_wsGrace, _health);
    _scheduleWsRetry();
  }

  void _scheduleWsRetry() {
    _wsRetry?.cancel();
    if (_closed) return;
    final lost = _wsLostAt;
    // Máy chủ chỉ giữ phiên ~10 giây sau khi mất WebSocket: quá thì phải vào lại cuộc gọi.
    if (lost != null && DateTime.now().difference(lost) >= _wsResumeWindow) {
      debugPrint('[calls] ws resume window passed');
      onLost?.call();
      return;
    }
    _wsRetry = Timer(Duration(milliseconds: _retryMs), () async {
      if (_closed || _wsOpen) return;
      try {
        await _openWs(reconnect: true);
        final at = _wsLostAt;
        if (at != null && DateTime.now().difference(at) > _wsResumeWindow + const Duration(seconds: 1)) {
          onLost?.call();
          return;
        }
        _wsLostAt = null;
        _retryMs = _wsMinRetryMs;
        _health();
        // Media cũng đứt (đổi mạng): khởi động lại ICE ngay khi có đường tín hiệu.
        if (!_pcConnected) _iceRestart();
      } catch (e) {
        debugPrint('[calls] ws reconnect: $e');
        _scheduleWsRetry();
      }
    });
    _retryMs += _wsRetryStepMs;
  }

  Timer? _healthTimer;
  static const _wsGrace = Duration(seconds: 4);

  void _health() {
    final lost = _wsLostAt;
    final wsOk = _wsOpen || (lost != null && DateTime.now().difference(lost) < _wsGrace);
    final ok = _pcConnected && wsOk;
    if (ok == _healthy) return;
    _healthy = ok;
    if (_connected) onHealth?.call(ok);
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

  /// Gửi một lệnh của plugin Calls (raise_hand, unraise_hand, react…).
  void action(String action, [Map<String, dynamic>? data]) => _send(action, data);

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
    if (_waitingPong && msg['seq_reply'] == _pongSeq) {
      _waitingPong = false;
      return;
    }
    final sq = msg['seq'];
    if (sq is int) _serverSeq = sq + 1;
    final ev = msg['event'] as String?;
    final data = (msg['data'] as Map?)?.cast<String, dynamic>();
    if (ev == null || data == null) return;
    if (ev == 'hello') {
      final id = data['connection_id'] as String? ?? '';
      if (id != _connId) {
        // Máy chủ cấp kết nối mới (không nối tiếp được kết nối cũ).
        _connId = id;
        _serverSeq = 0;
        if (_originalConnId.isEmpty) _originalConnId = id;
      }
      if (!_joined) {
        _joined = true;
        _send('join', {'channelID': channelId});
      }
      return;
    }
    final cid = data['connID'];
    if (cid != null && cid != _connId && cid != _originalConnId) return;
    if (ev == '${callsEventPrefix}_join') {
      if (_joinAcked) return;
      _joinAcked = true;
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
      debugPrint('[calls] pc state $s');
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _pcConnected = true;
          _iceTimer?.cancel();
          if (!_connected) {
            _connected = true;
            _timeout?.cancel();
            if (!_startMuted) _send('unmute');
            onConnected();
          }
          _health();
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // Mạng chập chờn / đổi mạng: chờ chút cho ICE tự hồi, không được thì khởi động lại ICE.
          _pcConnected = false;
          _health();
          _iceTimer?.cancel();
          _iceTimer = Timer(const Duration(seconds: 2), _iceRestart);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _pcConnected = false;
          if (!_connected) {
            _fail(tr('Kết nối cuộc gọi bị lỗi'));
            return;
          }
          _health();
          _iceRestart();
        default:
      }
    };
    pc.onTrack = _onTrack;
    pc.onRemoveTrack = (stream, track) => _trackGone(track.id ?? '', 'removed');
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
          // Đọc SDP trước: trong lúc áp, máy có thể báo bỏ track mà SDP mới vẫn gửi.
          _remoteMsid = _parseMsid(m['sdp'] as String? ?? '');
          await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'offer'));
          await _flush(pc);
          final ans = await pc.createAnswer();
          await pc.setLocalDescription(ans);
          _sendSdp(ans);
          _syncTracks(pc);
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
      // Đứt media thì data channel cũng không dùng được: khỏi chờ khoá.
      if (!_holdLock && _pcConnected) await _grabLock();
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

  /// Khởi động lại ICE (đổi Wi-Fi ↔ 4G: địa chỉ cũ chết hẳn): offer mới với thông tin ICE mới qua
  /// WebSocket; SFU trả lời là media chạy lại trên đường mới, vẫn giữ nguyên phiên trong cuộc gọi.
  Future<void> _iceRestart() async {
    final pc = _pc;
    _iceTimer?.cancel();
    if (_closed || pc == null || _pcConnected || !_negotiated) return;
    // Chưa có đường tín hiệu: làm khi WebSocket nối lại.
    if (!_wsOpen) return;
    final now = DateTime.now();
    final last = _lastIceRestart;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      _iceTimer = Timer(const Duration(seconds: 5) - now.difference(last), _iceRestart);
      return;
    }
    _lastIceRestart = now;
    debugPrint('[calls] ICE restart');
    await _serial('ice restart', () async {
      if (_awaitingAnswer) {
        // Offer trước có thể đã mất cùng kết nối cũ: bỏ nó.
        try {
          await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        } catch (_) {}
        _awaitingAnswer = false;
      }
      _unlock();
      await pc.restartIce();
      final o = await pc.createOffer();
      await pc.setLocalDescription(o);
      _awaitingAnswer = true;
      _sendSdp(o);
    });
    // Vẫn chưa thông thì thử lại.
    _iceTimer = Timer(const Duration(seconds: 6), _iceRestart);
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

  /// Loại track và phiên người gửi. SFU (rtcd) đặt id luồng (msid) = phiên người gửi và id track
  /// `<loại>_<phiên>_<ngẫu nhiên>`. Không dùng `sender_id` của bảng MediaMap: rtcd điền phiên của chính
  /// người nhận (session.go sendMediaMapping), dùng nó thì hình / màn hình của người khác bị coi là của
  /// mình và bị bỏ. Id track cũng không chắc: SFU dùng lại transceiver của người đã rời cho người mới
  /// và máy nhận giữ id track cũ, nên ưu tiên id luồng; loại lấy từ MediaMap (theo track hiện tại).
  (String, String) _resolve(String mid, MediaStream stream, MediaStreamTrack track) {
    // SDP mới nhất của SFU cho mid này là chắc nhất (máy nhận có thể giữ id track / luồng cũ).
    final sdp = _remoteMsid[mid];
    if (sdp != null && _idPattern.hasMatch(sdp.$1)) {
      final p = sdp.$2.split('_');
      if (p.length == 3 && _trackTypes.contains(p[0])) return (p[0], sdp.$1);
    }
    final mapType = _mediaMap[mid]?['type'] as String?;
    final parts = (track.id ?? '').split('_');
    final parsed = parts.length == 3 && _trackTypes.contains(parts[0]);
    final type = mapType != null && _trackTypes.contains(mapType)
        ? mapType
        : parsed
            ? parts[0]
            : (track.kind == 'video' ? 'video' : 'voice');
    final sender = _idPattern.hasMatch(stream.id) || !parsed ? stream.id : parts[1];
    return (type, sender);
  }

  /// Id của Mattermost (phiên Calls): 26 ký tự chữ thường và số.
  static final _idPattern = RegExp(r'^[a-z0-9]{26}$');

  void _emitTrack(String mid, MediaStream stream, MediaStreamTrack track) {
    if (_closed) return;
    final (type, session) = _resolve(mid, stream, track);
    debugPrint('[calls] track ${track.kind} ${track.id} mid=$mid type=$type session=$session');
    _byMid[mid] = (stream, track, type, session);
    track.onEnded = () => _trackGone(track.id ?? '', 'ended');
    onRemoteTrack(type, session, stream, track);
  }

  /// Máy báo track đã dừng / bị bỏ: bỏ qua nếu SDP mới nhất của SFU vẫn gửi track ở mid đó
  /// (Android báo nhầm khi thương lượng lại).
  void _trackGone(String trackId, String why) {
    final mid = _byMid.entries.where((e) => e.value.$2.id == trackId).map((e) => e.key).firstOrNull;
    if (mid != null && _remoteMsid.containsKey(mid)) {
      debugPrint('[calls] track $why ignored (still sent) $trackId mid=$mid');
      return;
    }
    debugPrint('[calls] track $why $trackId mid=$mid');
    if (mid != null) _byMid.remove(mid);
    onRemoteTrackEnded(trackId);
  }

  /// mid → (id luồng, id track) của các track SFU gửi (a=msid, không recvonly / inactive / bị từ chối).
  static Map<String, (String, String)> _parseMsid(String sdp) {
    final out = <String, (String, String)>{};
    String? mid;
    String? msid;
    var sending = false;
    void flush() {
      final parts = msid?.split(' ') ?? const <String>[];
      if (mid != null && sending && parts.length == 2 && parts[0] != '-') out[mid] = (parts[0], parts[1]);
    }

    for (final raw in sdp.split('\n')) {
      final l = raw.trim();
      if (l.startsWith('m=')) {
        flush();
        mid = null;
        msid = null;
        sending = l.split(' ').elementAtOrNull(1) != '0';
      } else if (l.startsWith('a=mid:')) {
        mid = l.substring(6);
      } else if (l.startsWith('a=msid:')) {
        msid = l.substring(7);
      } else if (l == 'a=recvonly' || l == 'a=inactive') {
        sending = false;
      }
    }
    flush();
    return out;
  }

  /// Sau mỗi offer của SFU: đối chiếu track theo SDP. SFU dùng lại transceiver của người đã rời / đã tắt
  /// cho người khác và Android có lúc không báo `onTrack` (hình của người đó không bao giờ hiện); mid
  /// không còn gửi thì báo track dừng.
  Future<void> _syncTracks(RTCPeerConnection pc) async {
    for (final mid in [..._byMid.keys]) {
      if (mid.startsWith('track:') || _remoteMsid.containsKey(mid)) continue;
      final gone = _byMid.remove(mid)!;
      debugPrint('[calls] track gone by sdp ${gone.$2.id} mid=$mid');
      onRemoteTrackEnded(gone.$2.id ?? '');
    }
    // Để `onTrack` (nếu có) báo trước.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_closed || _pc != pc) return;
    List<RTCRtpTransceiver>? trxs;
    for (final e in [..._remoteMsid.entries]) {
      final cur = _byMid[e.key];
      if (cur != null) {
        final (t2, s2) = _resolve(e.key, cur.$1, cur.$2);
        if (t2 == cur.$3 && s2 == cur.$4) continue;
      }
      try {
        trxs ??= await pc.getTransceivers();
        final track = trxs.where((t) => t.mid == e.key).firstOrNull?.receiver.track;
        if (track == null) continue;
        var stream = cur?.$1;
        if (stream == null || cur?.$2.id != track.id) {
          stream = await createLocalMediaStream('remote_${e.key}_${e.value.$2}');
          await stream.addTrack(track);
        }
        debugPrint('[calls] track sync by sdp mid=${e.key} msid=${e.value.$1} ${e.value.$2}');
        _emitTrack(e.key, stream, track);
      } catch (err) {
        debugPrint('[calls] track sync: $err');
      }
    }
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

  // ---------------------------------------------------------------- chia sẻ màn hình

  MediaStream? _screen;
  RTCRtpSender? _screenSender;
  MediaStream? get localScreen => _screen;

  /// Chia sẻ màn hình như client chính thức: báo `screen_on` kèm id luồng (SFU nhận ra đây là track
  /// màn hình), rồi thêm track (1 Mbps, 10 khung hình/giây) và thương lượng lại có giữ khoá tín hiệu.
  /// Luồng do bên gọi giữ (vào lại cuộc gọi thì chia sẻ tiếp), client không tự dừng.
  Future<void> startScreen(MediaStream stream) async {
    final pc = _pc;
    if (_closed || pc == null || _screen != null) return;
    final track = stream.getVideoTracks().firstOrNull;
    if (track == null) return;
    _screen = stream;
    _send('screen_on', {'data': jsonEncode({'screenStreamID': stream.id})});
    if (_negotiated && _pcConnected) await _grabLock();
    final trx = await pc.addTransceiver(
      track: track,
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv,
        streams: [stream],
        sendEncodings: [RTCRtpEncoding(maxBitrate: 1000 * 1000, maxFramerate: 10, scaleResolutionDownBy: 1.0)],
      ),
    );
    _screenSender = trx.sender;
    _renegotiate();
  }

  Future<void> stopScreen() async {
    final sender = _screenSender;
    final had = _screen != null;
    _screenSender = null;
    _screen = null;
    final pc = _pc;
    if (sender != null && pc != null && !_closed) {
      try {
        if (_negotiated && _pcConnected) await _grabLock();
        await pc.removeTrack(sender);
        _renegotiate();
      } catch (e) {
        debugPrint('[calls] stop screen: $e');
        _unlock();
      }
    }
    if (had) _send('screen_off');
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
    if (_screen != null) _send('screen_off');
    _send('leave');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _cleanup();
  }

  /// Bỏ phiên này để vào lại cuộc gọi bằng phiên mới (mạng rớt quá lâu): không gửi `leave`
  /// (máy chủ tự bỏ phiên cũ sau ~10 giây), không dừng luồng chia sẻ màn hình (bên gọi giữ).
  void abandon() {
    if (_closed) return;
    _screen = null;
    _cleanup();
  }

  void _cleanup() {
    _closed = true;
    _wsGen++;
    _ping?.cancel();
    _timeout?.cancel();
    _wsRetry?.cancel();
    _iceTimer?.cancel();
    _lockTimer?.cancel();
    _healthTimer?.cancel();
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
