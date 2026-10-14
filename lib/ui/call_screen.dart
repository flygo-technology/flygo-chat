import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../calls/call_service.dart';
import '../config.dart';
import '../state/app_state.dart';
import 'common.dart';

// Bảng màu kiểu Google Meet.
const _meetBg = Color(0xFF202124);
const _tileBg = Color(0xFF3C4043);
const _btnBg = Color(0xFF3C4043);
const _red = Color(0xFFEA4335);
const _blue = Color(0xFF8AB4F8);
const _grey = Color(0xFF9AA0A6);

/// Màn hình cuộc gọi. Lúc đổ chuông / đang gọi / đã kết thúc: kiểu WhatsApp (ảnh lớn, nút tròn).
/// Khi đã vào cuộc gọi: kiểu Google Meet (lưới ô cho mọi người, ghim, thanh nút ở dưới).
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  Timer? _hide;
  bool _popped = false;
  bool _usersLoaded = false;
  /// Ô đang ghim (null = không ghim). Chia sẻ màn hình tự ghim trừ khi đã bỏ ghim nó.
  String? _pinned;
  String? _dismissedScreen;
  bool _controls = true;
  CallPhase? _lastPhase;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    _poke();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  /// Hiện thanh nút; trên điện thoại tự ẩn sau vài giây.
  void _poke() {
    _hide?.cancel();
    if (!_controls) setState(() => _controls = true);
    if (isDesktop) return;
    _hide = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    if (_controls && !isDesktop) {
      _hide?.cancel();
      setState(() => _controls = false);
    } else {
      _poke();
    }
  }

  /// Nạp tên / ảnh thành viên của cuộc trò chuyện để hiện trên các ô.
  void _loadUsers(AppState app, String? ch) {
    if (_usersLoaded || ch == null) return;
    _usersLoaded = true;
    app.channelUsers(ch).then((_) {
      if (mounted) setState(() {});
    });
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
    final meeting = ch != null && !ch.isDirect;
    if (call.phase == CallPhase.idle && !_popped) {
      _popped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    _loadUsers(app, call.channelId);
    if (call.phase != _lastPhase) {
      // Vừa vào cuộc gọi: hiện thanh nút rồi mới tự ẩn.
      if (call.phase == CallPhase.active) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _poke() : null);
      _lastPhase = call.phase;
    }
    final title = ch == null ? '' : app.channelTitle(ch);
    final status = switch (call.phase) {
      CallPhase.incoming => meeting ? tr('Mời tham gia cuộc họp') : tr('Cuộc gọi thoại đến'),
      CallPhase.outgoing => tr('Đang đổ chuông...'),
      CallPhase.connecting => tr('Đang kết nối...'),
      CallPhase.active =>
        call.remoteUsers.isEmpty && ch?.isDirect == false
            ? tr('Đang chờ mọi người...')
            : _duration(call.startedAt),
      CallPhase.ended => call.endReason ?? (meeting ? tr('Cuộc họp đã kết thúc') : tr('Cuộc gọi đã kết thúc')),
      CallPhase.idle => '',
    };

    return PopScope(
      canPop: !call.busy,
      child: call.phase == CallPhase.active
          ? _meet(app, call, title, status)
          : _ringing(app, call, ch?.otherUserId(app.me?.id ?? ''), title, status, meeting),
    );
  }

  // ---------------------------------------------------------------- đổ chuông / đang gọi / kết thúc

  Widget _ringing(AppState app, CallService call, String? otherId, String title, String status, bool meeting) {
    final local = call.localVideo;
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      body: Stack(
        children: [
          if (local != null) Positioned.fill(child: _Video(stream: local, mirror: true)),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: local != null
                    ? [Colors.black38, Colors.transparent, Colors.black54]
                    : [const Color(0xFF1F2C34), const Color(0xFF0B141A)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.lock_outline, size: 14, color: Color(0xFF8696A0)),
                      const SizedBox(width: 6),
                      Text(
                        meeting ? tr('Cuộc họp nội bộ Flygo Chat') : tr('Cuộc gọi nội bộ Flygo Chat'),
                        style: const TextStyle(color: Color(0xFF8696A0), fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 40),
                  Avatar(
                    userId: otherId,
                    name: title,
                    size: 128,
                    icon: otherId == null ? Icons.groups : null,
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(status, style: const TextStyle(color: Color(0xFFD1D7DB), fontSize: 17)),
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
                            label: tr('Từ chối'),
                            onTap: call.decline,
                          ),
                          _RoundButton(
                            icon: Icons.call,
                            color: const Color(0xFF25D366),
                            label: tr('Trả lời'),
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
                            icon: call.camera ? Icons.videocam : Icons.videocam_off_outlined,
                            color: call.camera ? Colors.white : const Color(0xFF3B4A54),
                            iconColor: call.camera ? Colors.black : Colors.white,
                            onTap: call.toggleCamera,
                            size: 58,
                          ),
                          if (call.camera && !isDesktop)
                            _RoundButton(
                              icon: Icons.cameraswitch_outlined,
                              color: const Color(0xFF3B4A54),
                              onTap: call.switchCamera,
                              size: 58,
                            ),
                          if (!isDesktop)
                            _RoundButton(
                              icon: call.speaker ? Icons.volume_up : Icons.volume_down_outlined,
                              color: call.speaker ? Colors.white : const Color(0xFF3B4A54),
                              iconColor: call.speaker ? Colors.black : Colors.white,
                              onTap: call.toggleSpeaker,
                              size: 58,
                            ),
                          _RoundButton(
                            icon: call.muted ? Icons.mic_off : Icons.mic_none,
                            color: call.muted ? Colors.white : const Color(0xFF3B4A54),
                            iconColor: call.muted ? Colors.black : Colors.white,
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
    );
  }

  // ---------------------------------------------------------------- giao diện kiểu Google Meet

  String _nameOf(AppState app, String userId) {
    final n = app.users[userId]?.displayName ?? '';
    return n.isEmpty ? tr('Người dùng') : n;
  }

  /// Mọi ô: chia sẻ màn hình trước, rồi người khác, cuối cùng là mình.
  List<_TileData> _tiles(AppState app, CallService call) {
    final screens = <_TileData>[];
    final people = <_TileData>[];
    for (final p in call.participants) {
      final name = _nameOf(app, p.userId);
      if (p.hasScreen) {
        screens.add(_TileData(
          key: 'screen:${p.sessionId}',
          userId: p.userId,
          name: tr('{0} đang trình bày', [name]),
          stream: p.screenStream,
          trackId: p.screenTrackId,
          screen: true,
        ));
      }
      people.add(_TileData(
        key: p.sessionId,
        userId: p.userId,
        name: name,
        stream: p.hasVideo ? p.videoStream : null,
        trackId: p.videoTrackId,
        muted: !p.unmuted,
        speaking: p.speaking && p.unmuted,
        raisedHand: p.raisedHand,
      ));
    }
    final me = _TileData(
      key: 'me',
      userId: app.me?.id,
      name: tr('Bạn'),
      stream: call.localVideo,
      mirror: true,
      muted: call.muted,
      speaking: call.meSpeaking && !call.muted,
    );
    return [...screens, ...people, me];
  }

  void _tapTile(String key, String? spot) {
    setState(() {
      if (key == spot) {
        // Bấm lại ô đang ghim: bỏ ghim (chia sẻ màn hình thì nhớ là đã bỏ ghim).
        if (_pinned == key) {
          _pinned = null;
        } else {
          _dismissedScreen = key;
        }
      } else {
        _pinned = key;
      }
    });
    _poke();
  }

  Widget _meet(AppState app, CallService call, String title, String status) {
    final tiles = _tiles(app, call);
    final keys = {for (final t in tiles) t.key};
    if (_pinned != null && !keys.contains(_pinned)) _pinned = null;
    final spot = _pinned ??
        tiles.where((t) => t.screen && t.key != _dismissedScreen).firstOrNull?.key;
    final show = _controls;
    return Scaffold(
      backgroundColor: _meetBg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  padding: EdgeInsets.fromLTRB(8, show ? 60 : 8, 8, show ? 88 : 8),
                  child: LayoutBuilder(builder: (context, box) => _stage(tiles, spot, box)),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _fade(show, _topBar(title, status)),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _fade(show, _controlBar(app, call)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fade(bool show, Widget child) => IgnorePointer(
        ignoring: !show,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: child,
        ),
      );

  Widget _topBar(String title, String status) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(status, style: const TextStyle(color: _grey, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _tile(_TileData t, String? spot, {bool small = false}) => _Tile(
        key: ValueKey(t.key),
        data: t,
        pinned: t.key == spot,
        small: small,
        onTap: () => _tapTile(t.key, spot),
      );

  Widget _stage(List<_TileData> tiles, String? spot, BoxConstraints box) {
    final wide = box.maxWidth > box.maxHeight;
    const gap = 8.0;
    // Có ô ghim: ô đó lớn, các ô còn lại thành dải bên phải (màn ngang) hoặc ở dưới (màn dọc).
    if (spot != null) {
      final main = tiles.firstWhere((t) => t.key == spot);
      final rest = [for (final t in tiles) if (t.key != spot) t];
      if (rest.isEmpty) return _tile(main, spot);
      final strip = ListView.separated(
        scrollDirection: wide ? Axis.vertical : Axis.horizontal,
        itemCount: rest.length,
        separatorBuilder: (_, _) => const SizedBox(width: gap, height: gap),
        itemBuilder: (_, i) => SizedBox(
          width: wide ? null : 150,
          height: wide ? 130 : null,
          child: _tile(rest[i], spot, small: true),
        ),
      );
      return wide
          ? Row(children: [
              Expanded(child: _tile(main, spot)),
              const SizedBox(width: gap),
              SizedBox(width: math.min(240, box.maxWidth * .25), child: strip),
            ])
          : Column(children: [
              Expanded(child: _tile(main, spot)),
              const SizedBox(height: gap),
              SizedBox(height: 120, child: strip),
            ]);
    }
    // Gọi 1-1: người kia chiếm cả màn hình, mình là ô nhỏ nổi ở góc.
    if (tiles.length == 2) {
      final other = tiles.first;
      final me = tiles.last;
      final w = wide ? 240.0 : 108.0;
      final h = wide ? 135.0 : 160.0;
      return Stack(children: [
        Positioned.fill(child: _tile(other, spot)),
        Positioned(right: 12, bottom: 12, width: w, height: h, child: _tile(me, spot, small: true)),
      ]);
    }
    final n = tiles.length;
    final int cols;
    if (n == 1) {
      cols = 1;
    } else if (n == 2) {
      cols = wide ? 2 : 1;
    } else if (n <= 4) {
      cols = 2;
    } else if (n <= 9) {
      cols = 3;
    } else {
      cols = box.maxWidth > 1100 ? 4 : (wide ? 3 : 2);
    }
    // Đông người: cuộn dọc.
    if (n > 9) {
      return GridView.builder(
        itemCount: n,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childAspectRatio: wide ? 16 / 9 : 3 / 4,
        ),
        itemBuilder: (_, i) => _tile(tiles[i], spot, small: true),
      );
    }
    // Lưới vừa khít màn hình (2×2, 3×3...), hàng cuối thiếu thì căn giữa như Meet.
    final rows = (n / cols).ceil();
    var tw = (box.maxWidth - gap * (cols - 1)) / cols;
    final th = (box.maxHeight - gap * (rows - 1)) / rows;
    if (tw > th * 16 / 9) tw = th * 16 / 9;
    return Center(
      child: Wrap(
        spacing: gap,
        runSpacing: gap,
        alignment: WrapAlignment.center,
        runAlignment: WrapAlignment.center,
        children: [
          for (final t in tiles) SizedBox(width: tw, height: th, child: _tile(t, spot, small: n > 4)),
        ],
      ),
    );
  }

  Widget _controlBar(AppState app, CallService call) {
    final count = call.participants.length + 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MeetButton(
                icon: call.muted ? Icons.mic_off : Icons.mic,
                color: call.muted ? _red : _btnBg,
                tooltip: call.muted ? tr('Bật micro') : tr('Tắt micro'),
                onTap: () {
                  call.toggleMute();
                  _poke();
                },
              ),
              _MeetButton(
                icon: call.camera ? Icons.videocam : Icons.videocam_off,
                color: call.camera ? _btnBg : _red,
                tooltip: call.camera ? tr('Tắt camera') : tr('Bật camera'),
                onTap: () {
                  call.toggleCamera();
                  _poke();
                },
              ),
              if (!isDesktop && call.camera)
                _MeetButton(
                  icon: Icons.cameraswitch_outlined,
                  color: _btnBg,
                  tooltip: tr('Đổi camera'),
                  onTap: () {
                    call.switchCamera();
                    _poke();
                  },
                ),
              if (!isDesktop)
                _MeetButton(
                  icon: call.speaker ? Icons.volume_up : Icons.phone_in_talk,
                  color: call.speaker ? const Color(0xFFD2E3FC) : _btnBg,
                  iconColor: call.speaker ? const Color(0xFF041E49) : Colors.white,
                  tooltip: tr('Loa ngoài'),
                  onTap: () {
                    call.toggleSpeaker();
                    _poke();
                  },
                ),
              _MeetButton(
                icon: Icons.people_outline,
                color: _btnBg,
                tooltip: tr('Người tham gia'),
                badge: '$count',
                onTap: () => _showPeople(app, call),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Tooltip(
                  message: tr('Rời cuộc gọi'),
                  child: Material(
                    color: _red,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => call.hangUp(),
                      child: const SizedBox(
                        width: 68,
                        height: 52,
                        child: Icon(Icons.call_end, color: Colors.white, size: 26),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Danh sách người tham gia (cập nhật trực tiếp).
  void _showPeople(AppState app, CallService call) {
    _hide?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2D2E31),
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ListenableBuilder(
        listenable: call,
        builder: (ctx, _) {
          final people = call.participants;
          final myName = app.me?.displayName ?? '';
          Widget row({
            required String? userId,
            required String name,
            required bool muted,
            required bool speaking,
            required bool video,
            bool screen = false,
            bool hand = false,
          }) =>
              ListTile(
                leading: _Face(userId: userId, name: name, size: 40),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hand) const Padding(padding: EdgeInsets.only(right: 10), child: Icon(Icons.back_hand, color: Color(0xFFFDD663), size: 20)),
                    if (screen) const Padding(padding: EdgeInsets.only(right: 10), child: Icon(Icons.present_to_all, color: _blue, size: 20)),
                    Icon(video ? Icons.videocam : Icons.videocam_off, color: video ? Colors.white : _grey, size: 20),
                    const SizedBox(width: 10),
                    Icon(
                      muted ? Icons.mic_off : (speaking ? Icons.graphic_eq : Icons.mic),
                      color: muted ? _red : (speaking ? _blue : Colors.white),
                      size: 20,
                    ),
                  ],
                ),
              );
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                    child: Text(
                      tr('Người tham gia ({0})', [people.length + 1]),
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        row(
                          userId: app.me?.id,
                          name: myName.isEmpty ? tr('Bạn') : tr('{0} (Bạn)', [myName]),
                          muted: call.muted,
                          speaking: call.meSpeaking && !call.muted,
                          video: call.camera,
                        ),
                        for (final p in people)
                          row(
                            userId: p.userId,
                            name: _nameOf(app, p.userId),
                            muted: !p.unmuted,
                            speaking: p.speaking && p.unmuted,
                            video: p.video,
                            screen: p.screen,
                            hand: p.raisedHand,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(_poke);
  }
}

/// Dữ liệu một ô: một người (camera hoặc ảnh đại diện) hoặc một màn hình đang chia sẻ.
class _TileData {
  final String key;
  final String? userId;
  final String name;
  final MediaStream? stream;
  final String? trackId;
  final bool mirror;
  final bool muted;
  final bool speaking;
  final bool screen;
  final bool raisedHand;
  const _TileData({
    required this.key,
    required this.userId,
    required this.name,
    this.stream,
    this.trackId,
    this.mirror = false,
    this.muted = false,
    this.speaking = false,
    this.screen = false,
    this.raisedHand = false,
  });
}

class _Tile extends StatelessWidget {
  final _TileData data;
  final bool pinned;
  final bool small;
  final VoidCallback onTap;
  const _Tile({super.key, required this.data, required this.pinned, required this.small, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = data;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: d.screen ? Colors.black : _tileBg,
          borderRadius: BorderRadius.circular(12),
          // Viền xanh khi đang nói.
          border: Border.all(color: d.speaking ? _blue : Colors.transparent, width: 3),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              fit: StackFit.expand,
              children: [
                if (d.stream != null)
                  _Video(stream: d.stream!, trackId: d.trackId, mirror: d.mirror, contain: d.screen)
                else
                  Center(
                    child: _Face(
                      userId: d.userId,
                      name: d.name,
                      size: (math.min(box.maxWidth, box.maxHeight) * .4).clamp(32.0, 128.0),
                    ),
                  ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (d.muted) ...[
                                Icon(Icons.mic_off, color: Colors.white, size: small ? 13 : 16),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.white, fontSize: small ? 12 : 14),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (d.speaking)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(color: Color(0xFF1A73E8), shape: BoxShape.circle),
                      child: const Icon(Icons.graphic_eq, color: Colors.white, size: 14),
                    ),
                  ),
                if (pinned || d.raisedHand)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Row(
                      children: [
                        if (pinned) const Icon(Icons.push_pin, color: Colors.white, size: 18),
                        if (d.raisedHand) const Icon(Icons.back_hand, color: Color(0xFFFDD663), size: 18),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Ảnh đại diện trong ô khi tắt camera: ảnh hồ sơ nếu có, không thì hình tròn màu kèm chữ cái đầu.
class _Face extends StatelessWidget {
  final String? userId;
  final String name;
  final double size;
  const _Face({required this.userId, required this.name, required this.size});

  static const _colors = [
    Color(0xFF1A73E8),
    Color(0xFFE8710A),
    Color(0xFF188038),
    Color(0xFF9334E6),
    Color(0xFFD93025),
    Color(0xFF129EAF),
    Color(0xFFE52592),
    Color(0xFF795548),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final uid = userId;
    if (uid != null && uid.isNotEmpty && (app.users[uid]?.lastPictureUpdate ?? 0) > 0) {
      return Avatar(userId: uid, name: name, size: size, status: false);
    }
    final key = (uid ?? name).codeUnits.fold<int>(0, (a, b) => a + b);
    final shown = uid != null && app.users[uid] != null ? app.users[uid]!.displayName : name;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _colors[key % _colors.length]),
      child: Text(
        initials(shown).characters.first,
        style: TextStyle(color: Colors.white, fontSize: size * .45, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// Khung video của một track (mỗi ô có renderer riêng).
class _Video extends StatefulWidget {
  final MediaStream stream;
  final String? trackId;
  final bool mirror;
  final bool contain;
  const _Video({required this.stream, this.trackId, this.mirror = false, this.contain = false});
  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  final _r = RTCVideoRenderer();
  bool _ready = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _r.initialize().then((_) {
      if (_disposed) return;
      _ready = true;
      _attach();
      if (mounted) setState(() {});
    });
  }

  Future<void> _attach() async {
    try {
      // Luồng từ SFU gom mọi track của một người: chọn đúng track video (camera / màn hình).
      await _r.setSrcObject(stream: widget.stream, trackId: widget.trackId);
    } catch (e) {
      debugPrint('[calls] renderer: $e');
    }
  }

  @override
  void didUpdateWidget(covariant _Video old) {
    super.didUpdateWidget(old);
    if (_ready && (old.stream != widget.stream || old.trackId != widget.trackId)) _attach();
  }

  @override
  void dispose() {
    _disposed = true;
    _r.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.expand();
    return RTCVideoView(
      _r,
      mirror: widget.mirror,
      objectFit: widget.contain
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }
}

/// Nút tròn của thanh điều khiển kiểu Meet.
class _MeetButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color iconColor;
  final String tooltip;
  final String? badge;
  final VoidCallback onTap;
  const _MeetButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.iconColor = Colors.white,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: tooltip,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              color: color,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(width: 52, height: 52, child: Icon(icon, color: iconColor, size: 24)),
              ),
            ),
            if (badge != null)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFF1A73E8), borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    badge!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
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
