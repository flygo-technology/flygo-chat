import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';

// Phòng họp (trạm Flygo wss://push.flygo.vn/meet/ws?channel=…): kênh điều khiển dùng chung cho mọi máy trong cuộc gọi
// và cho trợ lý AI (công cụ meeting_* của runner gọi /meet/<kênh>/cmd). Trạm giữ trạng thái và phát lại mọi sự kiện:
// bình luận, tắt tiếng, mời bật mic / chia sẻ màn hình, ngôi sao, web chia sẻ (cuộn / bấm đồng bộ), sân khấu trình chiếu
// (markdown, ảnh, video, slide, hình vẽ), âm thanh (giọng đọc, nhạc) và phụ đề. Giơ tay / cảm xúc đi bằng giao thức gốc
// của Calls (CallService).

class MeetComment {
  final String userId, name, text;
  final bool bot;
  final int at;
  const MeetComment(this.userId, this.name, this.text, this.bot, this.at);
}

/// Yêu cầu gửi tới mình: mời bật mic / mời chia sẻ màn hình.
class MeetAsk {
  final String kind; // unmute_request | screen_request
  final String from;
  const MeetAsk(this.kind, this.from);
}

class MeetRoom extends ChangeNotifier {
  final String channelId;
  final String token;
  final String server;
  final String myId;
  /// Lệnh tắt mic mình (chủ phòng / trợ lý).
  final void Function() onMuteMe;

  MeetRoom({required this.channelId, required this.token, required this.server, required this.myId, required this.onMuteMe}) {
    _connect();
  }

  WebSocket? _ws;
  Timer? _retry;
  bool _closed = false;
  bool connected = false;

  final comments = <MeetComment>[];
  /// Người đang là "ngôi sao" (chỉ họ trình bày), null = bình thường.
  String? star;
  /// Web chia sẻ: url + vị trí cuộn (0..1) + người điều khiển.
  String? webUrl;
  double webScroll = 0;
  String? webDriver;
  /// Bấm trên web chia sẻ (tọa độ 0..1 trong khung) — màn hình web phát lại.
  final webClicks = StreamController<(double, double)>.broadcast();
  /// Sân khấu trình chiếu: {kind, content, url, items, index, strokes}; null = không có.
  Map<String, dynamic>? stage;
  String? caption;
  final asks = StreamController<MeetAsk>.broadcast();
  /// Bình luận mới (để hiện nổi trên màn hình cuộc gọi).
  final newComments = StreamController<MeetComment>.broadcast();

  final _tts = AudioPlayer();
  final _music = AudioPlayer();

  Uri get _uri => Uri.parse('${kFlygoPush.replaceFirst('https', 'wss')}/meet/ws')
      .replace(queryParameters: {'channel': channelId, 'token': token, 'server': server});

  Future<void> _connect() async {
    if (_closed) return;
    try {
      final ws = await WebSocket.connect(_uri.toString(), headers: {'Authorization': 'Bearer $token', 'X-MM-Server': server, 'User-Agent': kUserAgent})
          .timeout(const Duration(seconds: 10));
      if (_closed) {
        ws.close();
        return;
      }
      _ws = ws;
      connected = true;
      notifyListeners();
      ws.listen(_onRaw, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
    } catch (e) {
      debugPrint('[meet] connect: $e');
      _lost();
    }
  }

  void _lost() {
    connected = false;
    _ws = null;
    if (_closed) return;
    notifyListeners();
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 4), _connect);
  }

  void send(String type, [Map<String, dynamic> data = const {}]) {
    try {
      _ws?.add(jsonEncode({'type': type, ...data}));
    } catch (_) {}
  }

  void _onRaw(dynamic raw) {
    if (raw is! String) return;
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      _apply(m, live: true);
    } catch (e) {
      debugPrint('[meet] bad event: $e');
    }
  }

  void _apply(Map<String, dynamic> m, {bool live = false}) {
    final from = (m['from'] as Map?)?.cast<String, dynamic>() ?? const {};
    final fromId = from['user_id'] as String? ?? '';
    final fromName = from['name'] as String? ?? '';
    switch (m['type']) {
      case 'state':
        final st = (m['state'] as Map?)?.cast<String, dynamic>() ?? const {};
        comments
          ..clear()
          ..addAll([
            for (final c in (st['comments'] as List? ?? const []))
              MeetComment('${(c as Map)['from']?['user_id'] ?? ''}', '${c['from']?['name'] ?? ''}', '${c['text'] ?? ''}',
                  c['from']?['bot'] == true, (c['at'] as num?)?.toInt() ?? 0),
          ]);
        star = st['star'] as String?;
        final web = (st['web'] as Map?)?.cast<String, dynamic>();
        webUrl = web?['url'] as String?;
        webScroll = (web?['y'] as num?)?.toDouble() ?? 0;
        webDriver = web?['driver'] as String?;
        stage = (st['stage'] as Map?)?.cast<String, dynamic>();
        caption = st['caption'] as String?;
        final audio = (st['audio'] as Map?)?.cast<String, dynamic>();
        if (audio != null && audio['action'] == 'play' && audio['kind'] == 'music') _playAudio(audio);
      case 'comment':
        final c = MeetComment(fromId, fromName, '${m['text'] ?? ''}', from['bot'] == true, (m['at'] as num?)?.toInt() ?? 0);
        comments.add(c);
        if (comments.length > 200) comments.removeAt(0);
        if (live) newComments.add(c);
      case 'mute':
        if (m['user_id'] == myId) onMuteMe();
      case 'mute_all':
        final except = (m['except'] as List? ?? const []).cast<String>();
        if (fromId != myId && !except.contains(myId)) onMuteMe();
      case 'unmute_request' || 'screen_request':
        if (m['user_id'] == myId) asks.add(MeetAsk(m['type'] as String, fromName));
      case 'star':
        star = m['user_id'] as String?;
      case 'web_open' || 'web_nav':
        webUrl = m['url'] as String?;
        webScroll = 0;
        webDriver = fromId;
      case 'web_scroll':
        webScroll = (m['y'] as num?)?.toDouble() ?? webScroll;
      case 'web_click':
        if (fromId != myId) webClicks.add(((m['x'] as num?)?.toDouble() ?? 0, (m['y'] as num?)?.toDouble() ?? 0));
      case 'web_close':
        webUrl = null;
        webDriver = null;
      case 'stage':
        stage = m['kind'] == 'clear' ? null : m;
      case 'caption':
        final t = (m['text'] as String? ?? '').trim();
        caption = t.isEmpty ? null : t;
      case 'audio':
        _playAudio(m);
    }
    notifyListeners();
  }

  Future<void> _playAudio(Map<String, dynamic> a) async {
    final p = a['kind'] == 'music' ? _music : _tts;
    try {
      switch (a['action']) {
        case 'play':
          final url = a['url'] as String?;
          if (url == null) return;
          await p.setReleaseMode(a['loop'] == true ? ReleaseMode.loop : ReleaseMode.stop);
          await p.setVolume(((a['volume'] as num?)?.toDouble() ?? (a['kind'] == 'music' ? .4 : 1)).clamp(0, 1));
          await p.play(UrlSource(url));
        case 'pause':
          await p.pause();
        case 'stop':
          await p.stop();
      }
    } catch (e) {
      debugPrint('[meet] audio: $e');
    }
  }

  // ---------------------------------------------------------------- thao tác của mình
  void comment(String text) => send('comment', {'text': text});
  void muteAll() => send('mute_all', {'except': [myId]});
  void mute(String userId) => send('mute', {'user_id': userId});
  void askUnmute(String userId) => send('unmute_request', {'user_id': userId});
  void askScreen(String userId) => send('screen_request', {'user_id': userId});
  void setStar(String? userId) => send('star', {'user_id': userId});
  void openWeb(String url) => send('web_open', {'url': url});
  void navWeb(String url) => send('web_nav', {'url': url});
  void scrollWeb(double y) {
    webScroll = y;
    send('web_scroll', {'x': 0, 'y': y});
  }

  void clickWeb(double x, double y) => send('web_click', {'x': x, 'y': y});
  void closeWeb() => send('web_close');
  void clearStage() => send('stage', {'kind': 'clear'});
  bool get iDriveWeb => webDriver == null || webDriver == myId;

  @override
  void dispose() {
    _closed = true;
    _retry?.cancel();
    _ws?.close();
    _tts.dispose();
    _music.dispose();
    webClicks.close();
    asks.close();
    newComments.close();
    super.dispose();
  }
}
