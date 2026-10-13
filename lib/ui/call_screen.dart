import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../calls/call_service.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Màn hình cuộc gọi kiểu WhatsApp: nền tối, ảnh lớn, nút tròn ở dưới.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  bool _popped = false;
  final _remote = RTCVideoRenderer();
  final _local = RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    Future.wait([_remote.initialize(), _local.initialize()]).then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _remote.dispose();
    _local.dispose();
    super.dispose();
  }

  void _syncRenderers(CallService call) {
    if (!_ready) return;
    if (_remote.srcObject != call.remoteVideo) {
      _remote.srcObject = call.remoteVideo;
    }
    if (_local.srcObject != call.localVideo) {
      _local.srcObject = call.localVideo;
    }
  }

  String _duration(DateTime? s) {
    if (s == null) return '';
    final d = DateTime.now().difference(s);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$sec' : '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final call = app.calls;
    final ch = call.channelId == null ? null : app.channels[call.channelId];
    if (call.phase == CallPhase.idle && !_popped) {
      _popped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    _syncRenderers(call);
    final hasRemoteVideo = _ready && call.remoteVideo != null;
    final hasLocalVideo = _ready && call.localVideo != null;
    final otherId = ch == null || app.me == null
        ? null
        : ch.otherUserId(app.me!.id);
    final title = ch == null ? '' : app.channelTitle(ch);
    final status = switch (call.phase) {
      CallPhase.incoming => 'Cuộc gọi thoại đến',
      CallPhase.outgoing => 'Đang đổ chuông...',
      CallPhase.connecting => 'Đang kết nối...',
      CallPhase.active =>
        call.remoteUsers.isEmpty && ch?.isDirect == false
            ? 'Đang chờ mọi người...'
            : _duration(call.startedAt),
      CallPhase.ended => call.endReason ?? 'Cuộc gọi đã kết thúc',
      CallPhase.idle => '',
    };

    return PopScope(
      canPop: !call.busy,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B141A),
        body: Stack(
          children: [
            if (hasRemoteVideo)
              Positioned.fill(
                child: RTCVideoView(
                  _remote,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            if (hasLocalVideo)
              Positioned(
                right: 16,
                top: MediaQuery.paddingOf(context).top + 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: RTCVideoView(
                    _local,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: hasRemoteVideo
                      ? [Colors.black38, Colors.transparent, Colors.black54]
                      : [const Color(0xFF1F2C34), const Color(0xFF0B141A)],
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 14,
                          color: Color(0xFF8696A0),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Cuộc gọi nội bộ DND Chat',
                          style: TextStyle(
                            color: Color(0xFF8696A0),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: hasRemoteVideo ? 8 : 40),
                    if (!hasRemoteVideo) ...[
                      Avatar(
                        userId: otherId,
                        name: title,
                        size: 128,
                        icon: otherId == null ? Icons.groups : null,
                      ),
                      const SizedBox(height: 24),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      status,
                      style: const TextStyle(
                        color: Color(0xFFD1D7DB),
                        fontSize: 17,
                      ),
                    ),
                    const Spacer(),
                    if (call.phase == CallPhase.incoming)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 56),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _RoundButton(
                              icon: Icons.call_end,
                              color: const Color(0xFFF15C6D),
                              label: 'Từ chối',
                              onTap: call.decline,
                            ),
                            _RoundButton(
                              icon: Icons.call,
                              color: const Color(0xFF25D366),
                              label: 'Trả lời',
                              onTap: call.accept,
                            ),
                          ],
                        ),
                      )
                    else if (call.busy)
                      Container(
                        margin: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F2C34),
                          borderRadius: BorderRadius.circular(36),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _RoundButton(
                              icon: call.camera
                                  ? Icons.videocam
                                  : Icons.videocam_off_outlined,
                              color: call.camera
                                  ? Colors.white
                                  : const Color(0xFF3B4A54),
                              iconColor: call.camera
                                  ? Colors.black
                                  : Colors.white,
                              onTap: call.toggleCamera,
                              size: 58,
                            ),
                            if (call.camera)
                              _RoundButton(
                                icon: Icons.cameraswitch_outlined,
                                color: const Color(0xFF3B4A54),
                                onTap: call.switchCamera,
                                size: 58,
                              ),
                            _RoundButton(
                              icon: call.speaker
                                  ? Icons.volume_up
                                  : Icons.volume_down_outlined,
                              color: call.speaker
                                  ? Colors.white
                                  : const Color(0xFF3B4A54),
                              iconColor: call.speaker
                                  ? Colors.black
                                  : Colors.white,
                              onTap: call.toggleSpeaker,
                              size: 58,
                            ),
                            _RoundButton(
                              icon: call.muted ? Icons.mic_off : Icons.mic_none,
                              color: call.muted
                                  ? Colors.white
                                  : const Color(0xFF3B4A54),
                              iconColor: call.muted
                                  ? Colors.black
                                  : Colors.white,
                              onTap: call.toggleMute,
                              size: 58,
                            ),
                            _RoundButton(
                              icon: Icons.call_end,
                              color: const Color(0xFFF15C6D),
                              onTap: () => call.hangUp(),
                              size: 58,
                            ),
                          ],
                        ),
                      )
                    else
                      const SizedBox(height: 120),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color iconColor;
  final String? label;
  final VoidCallback onTap;
  final double size;
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.iconColor = Colors.white,
    this.label,
    this.size = 70,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: iconColor, size: size * .45),
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 10),
          Text(
            label!,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ],
    );
  }
}
