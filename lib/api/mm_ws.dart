import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../config.dart';

class WsEvent {
  final String event;
  final Map<String, dynamic> data;
  final Map<String, dynamic> broadcast;
  WsEvent(this.event, this.data, this.broadcast);
  String? get channelId => (broadcast['channel_id'] as String?)?.isNotEmpty == true
      ? broadcast['channel_id'] as String
      : data['channel_id'] as String?;
}

/// Kết nối WebSocket tới Mattermost, tự kết nối lại khi rớt mạng.
class MmSocket {
  final String token;
  final void Function(WsEvent) onEvent;
  final void Function(bool connected) onState;
  WebSocket? _ws;
  Timer? _retry;
  Timer? _ping;
  int _seq = 1;
  int _attempt = 0;
  bool _closed = false;
  bool connected = false;

  MmSocket(this.token, {required this.onEvent, required this.onState});

  void connect() {
    if (_closed) return;
    _retry?.cancel();
    final url = kServerUrl.replaceFirst('http', 'ws');
    WebSocket.connect('$url/api/v4/websocket', headers: {
      'Authorization': 'Bearer $token',
      'User-Agent': kUserAgent,
    }).timeout(const Duration(seconds: 20)).then((ws) {
      if (_closed) {
        ws.close();
        return;
      }
      _ws = ws;
      _attempt = 0;
      ws.add(jsonEncode({
        'seq': _seq++,
        'action': 'authentication_challenge',
        'data': {'token': token},
      }));
      _setState(true);
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          ws.add(jsonEncode({'seq': _seq++, 'action': 'ping'}));
        } catch (_) {}
      });
      ws.listen(_onMessage, onDone: _onDown, onError: (_) => _onDown(), cancelOnError: true);
    }).catchError((_) => _onDown());
  }

  void _onMessage(dynamic msg) {
    try {
      final m = jsonDecode(msg as String) as Map<String, dynamic>;
      final ev = m['event'] as String?;
      if (ev == null) return;
      onEvent(WsEvent(
        ev,
        (m['data'] as Map?)?.cast<String, dynamic>() ?? {},
        (m['broadcast'] as Map?)?.cast<String, dynamic>() ?? {},
      ));
    } catch (_) {}
  }

  void _onDown() {
    _ping?.cancel();
    _ws = null;
    _setState(false);
    if (_closed) return;
    _attempt++;
    final delay = Duration(seconds: min(30, pow(2, min(_attempt, 5)).toInt()));
    _retry?.cancel();
    _retry = Timer(delay, connect);
  }

  /// Gọi khi app quay lại foreground hoặc người dùng bấm thử lại.
  void reconnectNow() {
    if (connected || _closed) return;
    _attempt = 0;
    connect();
  }

  void _setState(bool v) {
    if (connected == v) return;
    connected = v;
    onState(v);
  }

  void sendTyping(String channelId) {
    try {
      _ws?.add(jsonEncode({
        'seq': _seq++,
        'action': 'user_typing',
        'data': {'channel_id': channelId, 'parent_id': ''},
      }));
    } catch (_) {}
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
    _ws?.close();
  }
}
