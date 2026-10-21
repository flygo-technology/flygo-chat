import '../i18n/i18n.dart';

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../push/push_service.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'effects.dart';

// Tin khẩn cấp (priority "urgent") của người khác: hiện toàn màn hình, đè lên mọi thứ, kêu chuông tới khi bấm "Đã nhận".
// Nền / chữ theo màu nền người gửi chọn (props.flygo_fx.bg; chữ trắng), mặc định nền đen chữ đỏ.

/// Màn hình tin khẩn cấp. Bấm "Đã nhận" = xác nhận đã đọc (ack); "Mở chat" = xác nhận rồi mở cuộc trò chuyện.
class UrgentAlertPage extends StatefulWidget {
  final AppState app;
  final MmPost post;
  const UrgentAlertPage({super.key, required this.app, required this.post});

  @override
  State<UrgentAlertPage> createState() => _UrgentAlertPageState();
}

class _UrgentAlertPageState extends State<UrgentAlertPage> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))
    ..repeat(reverse: true);
  final _player = AudioPlayer();
  static const _lock = MethodChannel('flygo/urgent');

  /// Android: chỉ trong lúc hiện tin khẩn cấp mới cho hiện đè màn hình khoá và bật màn hình.
  static void _overLock(bool on) {
    if (!kIsWeb && Platform.isAndroid) _lock.invokeMethod('overLock', on).catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    _overLock(true);
    _player
      ..setReleaseMode(ReleaseMode.loop)
      ..play(AssetSource('ringtones/ring_digital.mp3')).catchError((_) {});
  }

  @override
  void dispose() {
    _overLock(false);
    _blink.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _ack({bool open = false}) async {
    _player.stop();
    final p = widget.post;
    if (p.requestedAck && !p.ackUserIds.contains(widget.app.me?.id)) {
      widget.app.acknowledge(p).catchError((_) {});
    }
    if (mounted) Navigator.of(context).pop();
    if (open) {
      PushService.openPostId = p.id;
      PushService.openChannel.value = null;
      PushService.openChannel.value = p.channelId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app, p = widget.post;
    final bg = fxBackgrounds[(p.props['flygo_fx'] as Map?)?['bg'] as String?]?.$2;
    final fg = bg == null ? const Color(0xFFFF2D2D) : Colors.white;
    final ch = app.channels[p.channelId];
    final sender = app.users[p.userId];
    final senderName = sender?.displayName ?? tr('Người dùng');
    final chatName = ch == null ? '' : (ch.isDirect ? senderName : app.channelTitle(ch));
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            color: bg == null ? Colors.black : null,
            gradient: bg == null ? null : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: bg),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FadeTransition(
                  opacity: Tween(begin: .25, end: 1.0).animate(_blink),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.campaign_rounded, color: fg, size: 34),
                    const SizedBox(width: 10),
                    Text(tr('TIN KHẨN CẤP'),
                        style: TextStyle(color: fg, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 2)),
                  ]),
                ),
                const SizedBox(height: 28),
                if (chatName.isNotEmpty && !(ch?.isDirect ?? false))
                  Text(chatName,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg.withValues(alpha: .85), fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Avatar(userId: p.userId, name: senderName, size: 40),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Text(hhmm(DateTime.fromMillisecondsSinceEpoch(p.createAt)), style: TextStyle(color: fg.withValues(alpha: .7), fontSize: 15)),
                ]),
                const SizedBox(height: 24),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Text(plainPreview(p.message),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: fg, fontSize: 26, height: 1.35, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: fg,
                        side: BorderSide(color: fg, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => _ack(open: true),
                      child: Text(tr('Mở chat'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: fg,
                        foregroundColor: bg == null ? Colors.black : bg.first,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _ack,
                      child: Text(tr('Đã nhận'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Nhãn nhấp nháy trên tin quan trọng / khẩn cấp trong khung chat.
class BlinkLabel extends StatefulWidget {
  final IconData icon;
  final String text;
  final Color color;
  const BlinkLabel({super.key, required this.icon, required this.text, required this.color});

  @override
  State<BlinkLabel> createState() => _BlinkLabelState();
}

class _BlinkLabelState extends State<BlinkLabel> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: .35, end: 1.0).animate(_c),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Text(widget.text,
                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: .8)),
          ]),
        ),
      );
}
