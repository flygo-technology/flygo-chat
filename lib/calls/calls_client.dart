import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

import '../config.dart';

const callsPluginId = 'com.mattermost.calls';
const callsEventPrefix = 'custom_$callsPluginId';

/// Kết nối thoại tới plugin Calls của Mattermost (SFU tích hợp).
/// Giao thức theo calls-common: WebSocket riêng, SDP nén zlib gói msgpack,
/// ICE gửi dạng JSON, tín hiệu từ server về qua sự kiện `_signal`.
class CallsClient {
  final String token;
  final String channelId;
  final List<Map<String, dynamic>> iceServers;
  final void Function() onConnected;
  final void Function(String reason) onClosed;
  final void Function(MediaStream stream) onRemoteStream;
  final void Function(MediaStream? stream) onRemoteVideo;

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

  CallsClient({
    required this.token,
    required this.channelId,
    required this.iceServers,
    required this.onConnected,
    required this.onClosed,
    required this.onRemoteStream,
    required this.onRemoteVideo,
  });

  MediaStream? _video;
  RTCRtpSender? _videoSender;
  MediaStream? get localVideo => _video;

  bool get muted => !(_local?.getAudioTracks().firstOrNull?.enabled ?? false);

  Future<void> start() async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    final url = '${kServerUrl.replaceFirst('http', 'ws')}/api/v4/websocket?connection_id=&sequence_number=0';
    _ws = await WebSocket.connect(url, headers: {'Authorization': 'Bearer $token', 'User-Agent': kUserAgent})
        .timeout(const Duration(seconds: 15));
    _ws!.listen(_onMessage, onDone: () => _fail('Mất kết nối tới máy chủ'), onError: (_) => _fail('Mất kết nối tới máy chủ'));
    _sendRaw({'action': 'authentication_challenge', 'seq': _seq++, 'data': {'token': token}});
    _ping = Timer.periodic(const Duration(seconds: 5), (_) => _sendRaw({'action': 'ping', 'seq': _seq++}));
    _timeout = Timer(const Duration(seconds: 30), () {
      if (!_connected) _fail('Không kết nối được cuộc gọi');
    });
  }

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
      _fail('Máy chủ từ chối cuộc gọi: ${data['data']}');
    } else if (ev == '${callsEventPrefix}_signal') {
      await _onSignal(data['data'] as String);
    }
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
        _fail('Kết nối cuộc gọi bị lỗi');
      }
    };
    pc.onTrack = (e) {
      if (e.track.kind == 'video') {
        if (e.streams.isNotEmpty) {
          onRemoteVideo(e.streams.first);
        } else {
          createLocalMediaStream('remote-video').then((s) {
            s.addTrack(e.track);
            onRemoteVideo(s);
          });
        }
        e.track.onEnded = () => onRemoteVideo(null);
        return;
      }
      if (e.track.kind == 'audio') {
        if (e.streams.isNotEmpty) {
          onRemoteStream(e.streams.first);
        } else {
          createLocalMediaStream('remote').then((s) {
            s.addTrack(e.track);
            onRemoteStream(s);
          });
        }
      }
    };
    _dc = await pc.createDataChannel('calls-dc', RTCDataChannelInit());
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _sendSdp(offer);
    pc.onRenegotiationNeeded = () async {
      if (_closed || pc.signalingState != RTCSignalingState.RTCSignalingStateStable) return;
      final o = await pc.createOffer();
      await pc.setLocalDescription(o);
      _sendSdp(o);
    };
  }

  void _sendSdp(RTCSessionDescription d) {
    final payload = utf8.encode(jsonEncode({'type': d.type, 'sdp': d.sdp}));
    final compressed = Uint8List.fromList(ZLibCodec().encode(payload));
    _send('sdp', {'data': compressed}, true);
  }

  Future<void> _onSignal(String raw) async {
    final pc = _pc;
    if (pc == null) return;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    switch (m['type']) {
      case 'candidate':
        final c = (m['candidate'] as Map).cast<String, dynamic>();
        final cand = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt());
        if (await pc.getRemoteDescription() != null) {
          await pc.addCandidate(cand);
        } else {
          _pendingRemote.add(cand);
        }
      case 'offer':
        await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'offer'));
        await _flush(pc);
        final ans = await pc.createAnswer();
        await pc.setLocalDescription(ans);
        _sendSdp(ans);
      case 'answer':
        await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'answer'));
        await _flush(pc);
    }
  }

  Future<void> _flush(RTCPeerConnection pc) async {
    for (final c in _pendingRemote) {
      await pc.addCandidate(c);
    }
    _pendingRemote.clear();
  }

  /// Bật camera: thêm luồng video (1 Mbps, 30 khung hình/giây như web client)
  /// rồi báo `video_on` kèm id luồng.
  Future<MediaStream?> startVideo({bool front = true}) async {
    final pc = _pc;
    if (pc == null) return null;
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': front ? 'user' : 'environment',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 30},
      },
    });
    final track = stream.getVideoTracks().first;
    _video = stream;
    if (_videoSender != null) {
      await _videoSender!.replaceTrack(track);
    } else {
      final trx = await pc.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: [stream],
          sendEncodings: [RTCRtpEncoding(maxBitrate: 1000 * 1000, maxFramerate: 30, scaleResolutionDownBy: 1.0)],
        ),
      );
      _videoSender = trx.sender;
    }
    _send('video_on', {'data': jsonEncode({'videoStreamID': stream.id})});
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
