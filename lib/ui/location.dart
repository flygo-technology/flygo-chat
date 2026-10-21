import '../i18n/i18n.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

// Chia sẻ vị trí trong tin nhắn: props.flygo_location = {lat, lng, acc, at, live, until?, stopped?}.
// - Gửi vị trí hiện tại: một điểm cố định (live = false).
// - Vị trí trực tiếp: máy người gửi cập nhật props của chính tin đó tới khi hết giờ / bấm dừng (live = true).
// Nội dung tin là đường dẫn Google Maps để app khác vẫn mở được.

/// Lấy vị trí hiện tại (xin quyền nếu cần). Lỗi thì báo bằng SnackBar và trả null.
Future<Position?> currentPosition(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String t) => messenger.showSnackBar(toast(Text(t)));
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      say(tr('Hãy bật dịch vụ vị trí (GPS) của máy.'));
      return null;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      say(tr('Cần cho phép Flygo Chat dùng vị trí.'));
      return null;
    }
    return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
  } catch (e) {
    say(tr('Không lấy được vị trí: {0}', ['$e']));
    return null;
  }
}

String mapsUrl(double lat, double lng) => 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

Map<String, dynamic> locationProps(Position p, {bool live = false, int? until}) => {
      'lat': p.latitude,
      'lng': p.longitude,
      'acc': p.accuracy.round(),
      'at': DateTime.now().millisecondsSinceEpoch,
      'live': live,
      'until': ?until,
    };

/// Chọn thời gian chia sẻ vị trí trực tiếp (null = huỷ).
Future<Duration?> askLiveDuration(BuildContext context) => showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 600),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        final pal = Pal.of(ctx);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(tr('Chia sẻ vị trí trực tiếp'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr('Mọi người trong cuộc trò chuyện thấy vị trí của bạn thay đổi theo thời gian thực. Giữ Flygo Chat chạy trong lúc chia sẻ.'),
                  style: TextStyle(color: pal.sub, fontSize: 13.5)),
            ),
            for (final (d, l) in [
              (const Duration(minutes: 15), tr('15 phút')),
              (const Duration(hours: 1), tr('1 giờ')),
              (const Duration(hours: 8), tr('8 giờ')),
            ])
              ListTile(
                leading: Icon(Icons.timer_outlined, color: pal.accent),
                title: Text(l, style: TextStyle(color: pal.text)),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ]),
        );
      },
    );

/// Máy này đang chia sẻ vị trí trực tiếp cho những tin nào (post id → lượt chia sẻ).
class LiveLocation {
  static final active = <String, LiveLocation>{};
  static final changes = ValueNotifier<int>(0);

  final AppState app;
  final String postId, channelId;
  final int until;
  StreamSubscription<Position>? _sub;
  Timer? _end;
  int _lastSent = 0;

  LiveLocation._(this.app, this.postId, this.channelId, this.until);

  static bool isSharing(String postId) => active.containsKey(postId);

  /// Bắt đầu cập nhật vị trí cho tin [post] tới [until] (ms).
  static void start(AppState app, MmPost post, int until) {
    if (active.containsKey(post.id)) return;
    final l = LiveLocation._(app, post.id, post.channelId, until);
    active[post.id] = l;
    changes.value++;
    l._run();
  }

  void _run() {
    final left = until - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) {
      stop();
      return;
    }
    _end = Timer(Duration(milliseconds: left), stop);
    final LocationSettings settings = !kIsWeb && Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 15,
            intervalDuration: const Duration(seconds: 10),
            // Giữ cập nhật khi app chạy nền (thông báo thường trực của Android).
            foregroundNotificationConfig: ForegroundNotificationConfig(
              notificationTitle: tr('Đang chia sẻ vị trí trực tiếp'),
              notificationText: tr('Flygo Chat đang gửi vị trí của bạn vào cuộc trò chuyện.'),
              enableWakeLock: true,
            ),
          )
        : !kIsWeb && (Platform.isIOS || Platform.isMacOS)
            ? AppleSettings(accuracy: LocationAccuracy.high, distanceFilter: 15, pauseLocationUpdatesAutomatically: false)
            : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15);
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_send, onError: (_) {});
  }

  Future<void> _send(Position p) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSent < 8000) return; // tối đa ~1 lần / 8 giây
    _lastSent = now;
    final post = app.findPost(channelId, postId);
    if (post == null || post.isRecalled) return stop();
    try {
      await app.patchProps(post, {'flygo_location': locationProps(p, live: true, until: until)});
    } catch (_) {}
  }

  /// Dừng chia sẻ (đánh dấu stopped trên tin để mọi người thấy đã kết thúc).
  Future<void> stop() async {
    _end?.cancel();
    await _sub?.cancel();
    active.remove(postId);
    changes.value++;
    final post = app.findPost(channelId, postId);
    final loc = (post?.props['flygo_location'] as Map?)?.cast<String, dynamic>();
    if (post != null && loc != null && loc['stopped'] != true) {
      try {
        await app.patchProps(post, {
          'flygo_location': {...loc, 'stopped': true, 'until': DateTime.now().millisecondsSinceEpoch},
        });
      } catch (_) {}
    }
  }
}

/// Lớp bản đồ OpenStreetMap.
TileLayer _tiles() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'vn.flygo.chat',
      tileProvider: NetworkTileProvider(headers: {'User-Agent': kUserAgent}),
    );

Widget _pin(Color c, {bool live = false}) => Stack(alignment: Alignment.center, children: [
      if (live) Container(width: 44, height: 44, decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: .22))),
      Icon(Icons.location_on, color: c, size: 38),
    ]);

/// Thẻ vị trí trong khung tin.
class LocationCard extends StatelessWidget {
  final AppState app;
  final MmPost post;
  final double width;
  const LocationCard({super.key, required this.app, required this.post, required this.width});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final loc = (post.props['flygo_location'] as Map).cast<String, dynamic>();
    final live = loc['live'] == true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = (loc['until'] as num?)?.toInt() ?? 0;
    final ended = live && (loc['stopped'] == true || until <= now);
    final at = (loc['at'] as num?)?.toInt() ?? post.createAt;
    final mine = post.userId == app.me?.id;
    final w = width.isFinite ? width.clamp(200.0, 320.0) : 280.0;
    final soft = pal.text.withValues(alpha: .72);
    final liveNow = live && !ended;
    final sender = app.users[post.userId]?.displayName ?? '';
    return SizedBox(
      width: w,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(live ? tr('Vị trí trực tiếp của {0}', [sender]) : tr('Vị trí của {0}', [sender]),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: pal.text)),
        const SizedBox(height: 2),
        Text(
          live
              ? (ended
                  ? tr('Đã kết thúc chia sẻ vị trí')
                  : tr('Đến {0} · cập nhật {1}', [hhmm(DateTime.fromMillisecondsSinceEpoch(until)), hhmm(DateTime.fromMillisecondsSinceEpoch(at))]))
              : tr('Sai số khoảng {0} m', [loc['acc'] ?? '?']),
          style: TextStyle(fontSize: 13, color: soft),
        ),
        if (mine && liveNow)
          ValueListenableBuilder<int>(
            valueListenable: LiveLocation.changes,
            builder: (context, _, _) => LiveLocation.isSharing(post.id)
                ? TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: Colors.redAccent, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    onPressed: () => LiveLocation.active[post.id]?.stop(),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: Text(tr('Dừng chia sẻ')),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(tr('Máy này không còn gửi vị trí (app đã tắt).'), style: TextStyle(fontSize: 12.5, color: soft)),
                  ),
          ),
      ]),
    );
  }
}

/// Bản đồ của tin vị trí: tràn hết chiều rộng khung tin, sát mép trên (khung tin tự bo góc).
class LocationMap extends StatelessWidget {
  final AppState app;
  final MmPost post;
  final double width;
  const LocationMap({super.key, required this.app, required this.post, required this.width});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final loc = (post.props['flygo_location'] as Map).cast<String, dynamic>();
    final pt = LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble());
    final live = loc['live'] == true;
    final until = (loc['until'] as num?)?.toInt() ?? 0;
    final liveNow = live && loc['stopped'] != true && until > DateTime.now().millisecondsSinceEpoch;
    return GestureDetector(
          // Bấm vào bản đồ: mở Google Maps (điện thoại mở app Google Maps, máy tính mở bản web).
          onTap: () => launchUrl(Uri.parse(mapsUrl(pt.latitude, pt.longitude)), mode: LaunchMode.externalApplication),
          child: ClipRRect(
            borderRadius: BorderRadius.zero,
            child: SizedBox(
              width: width,
              height: 160,
              child: Stack(children: [
                IgnorePointer(
                  child: FlutterMap(
                    options: MapOptions(initialCenter: pt, initialZoom: 15, interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
                    children: [
                      _tiles(),
                      MarkerLayer(markers: [Marker(point: pt, width: 44, height: 44, child: _pin(liveNow ? Colors.redAccent : pal.accent, live: liveNow))]),
                    ],
                  ),
                ),
                if (live)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: liveNow ? Colors.redAccent : Colors.black54, borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(liveNow ? Icons.circle : Icons.location_off, size: 8, color: Colors.white),
                        const SizedBox(width: 5),
                        Text(liveNow ? tr('TRỰC TIẾP') : tr('ĐÃ KẾT THÚC'),
                            style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: .6)),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        );
  }
}

/// Trang bản đồ toàn màn hình (vị trí trực tiếp tự di chuyển khi tin được cập nhật).
class LocationPage extends StatelessWidget {
  final AppState app;
  final String channelId, postId;
  const LocationPage({super.key, required this.app, required this.channelId, required this.postId});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final post = app.findPost(channelId, postId);
        final loc = (post?.props['flygo_location'] as Map?)?.cast<String, dynamic>();
        if (post == null || loc == null) return Scaffold(appBar: AppBar());
        final pt = LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble());
        final sender = app.users[post.userId]?.displayName ?? '';
        final live = loc['live'] == true && loc['stopped'] != true && ((loc['until'] as num?)?.toInt() ?? 0) > DateTime.now().millisecondsSinceEpoch;
        return Scaffold(
          appBar: AppBar(title: Text(live ? tr('Vị trí trực tiếp của {0}', [sender]) : tr('Vị trí của {0}', [sender]))),
          body: FlutterMap(
            key: ValueKey('${pt.latitude},${pt.longitude}'),
            options: MapOptions(initialCenter: pt, initialZoom: 16),
            children: [
              _tiles(),
              MarkerLayer(markers: [Marker(point: pt, width: 44, height: 44, child: _pin(live ? Colors.redAccent : pal.accent, live: live))]),
              const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: pal.accent,
            foregroundColor: Colors.white,
            onPressed: () => launchUrl(Uri.parse(mapsUrl(pt.latitude, pt.longitude)), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.directions),
            label: Text(tr('Chỉ đường')),
          ),
        );
      },
    );
  }
}
