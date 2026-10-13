import '../i18n/i18n.dart';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_page.dart' show saveMedia;
import 'forward_page.dart';
import 'theme.dart';

/// Một ảnh hiển thị trong chat: ảnh trên máy (đang gửi / vừa gửi) hoặc ảnh
/// trên máy chủ.
class ChatImage {
  final String? localPath;
  final MmFile? file;
  /// Ảnh ngoài (GIF, sticker).
  final String? url;
  final double aspect;
  ChatImage({this.localPath, this.file, this.url, this.aspect = 4 / 3});

  ImageProvider provider(AppState app, {bool full = false}) {
    if (url != null) return NetworkImage(url!);
    final p = localPath ?? (file == null ? null : app.localPathFor(file!.id));
    if (p != null && File(p).existsSync()) return FileImage(File(p));
    final remote = full ? app.api.fileUrl(file!.id) : app.api.previewUrl(file!.id);
    return NetworkImage(remote, headers: app.api.headers);
  }

  ImageProvider? thumb(AppState app) =>
      url != null || file == null || app.localPathFor(file!.id) != null ? null : NetworkImage(app.api.thumbUrl(file!.id), headers: app.api.headers);
}

/// Danh sách ảnh của một tin (ảnh đang gửi lấy từ máy, ảnh đã gửi lấy từ máy chủ).
List<ChatImage> imagesOf(MmPost p) {
  final local = p.localFiles.where((f) => (f['mime'] as String? ?? '').startsWith('image/')).toList();
  if (local.isNotEmpty) {
    return [for (final f in local) ChatImage(localPath: f['path'] as String, aspect: (f['aspect'] as num?)?.toDouble() ?? 4 / 3)];
  }
  return [
    for (final f in p.files.where((f) => f.isImage))
      ChatImage(file: f, aspect: f.width > 0 && f.height > 0 ? f.width / f.height : 4 / 3),
  ];
}

/// Ảnh trong tin nhắn: một ảnh thì hiện nguyên, nhiều ảnh thì xếp chồng lệch nhau.
/// [overlay] là giờ gửi + trạng thái, đặt đè ở góc dưới phải.
class ChatMedia extends StatelessWidget {
  final MmPost post;
  final List<ChatImage> images;
  final Widget? overlay;
  final bool sending;
  final double maxWidth;
  final bool sticker;
  const ChatMedia(
      {super.key, required this.post, required this.images, this.overlay, this.sending = false, this.maxWidth = 280, this.sticker = false});

  void _open(BuildContext context, int index) {
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => GalleryViewer(post: post, images: images, initial: index),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final w = maxWidth.clamp(sticker ? 100.0 : 160.0, 300.0);
    Widget content;
    if (sticker) {
      content = SizedBox(width: w, height: w / images.first.aspect.clamp(.5, 2.0), child: Image(image: images.first.provider(app), fit: BoxFit.contain));
    } else if (images.length == 1) {
      final img = images.first;
      final aspect = img.aspect.clamp(.6, 1.9);
      content = GestureDetector(
        onTap: () => _open(context, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(width: w, height: w / aspect, child: _Img(image: img, app: app)),
        ),
      );
    } else {
      // Chồng ảnh: ảnh đầu ở trên, tối đa 2 ảnh lộ ra phía sau, nghiêng nhẹ.
      final h = w * 1.05;
      final back = images.skip(1).take(2).toList();
      content = GestureDetector(
        onTap: () => _open(context, 0),
        child: SizedBox(
          width: w + 14,
          height: h + 14,
          child: Stack(clipBehavior: Clip.none, children: [
            for (var i = back.length - 1; i >= 0; i--)
              Positioned(
                left: 7.0 + (i + 1) * 5,
                top: 7.0 - (i + 1) * 3,
                child: Transform.rotate(
                  angle: (i == 0 ? 1 : -1) * 0.06 * (i + 1),
                  child: _Card(width: w - 6, height: h - 6, child: _Img(image: back[i], app: app)),
                ),
              ),
            Positioned(left: 4, top: 10, child: _Card(width: w, height: h, child: _Img(image: images.first, app: app))),
            Positioned(
              left: 14,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.photo_library, color: Colors.white, size: 15),
                  const SizedBox(width: 4),
                  Text(tr('{0} ảnh', [images.length]), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
        ),
      );
    }
    return Stack(children: [
      content,
      if (sending)
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Container(
                width: 52,
                height: 52,
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
              ),
            ),
          ),
        ),
      if (overlay != null)
        Positioned(
          right: images.length > 1 ? 14 : 8,
          bottom: images.length > 1 ? 10 : 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white),
              child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: overlay!),
            ),
          ),
        ),
    ]);
  }
}

class _Card extends StatelessWidget {
  final double width, height;
  final Widget child;
  const _Card({required this.width, required this.height, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Pal.of(context).chatBg, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3))],
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: child),
      );
}

/// Ảnh có ảnh nhỏ làm nền trong lúc chờ ảnh lớn tải về.
class _Img extends StatelessWidget {
  final ChatImage image;
  final AppState app;
  const _Img({required this.image, required this.app});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final thumb = image.thumb(app);
    return Stack(fit: StackFit.expand, children: [
      Container(color: pal.surface2),
      if (thumb != null) Image(image: thumb, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
      Image(
        image: image.provider(app),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: (_, child, frame, sync) =>
            sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 200), child: child),
        errorBuilder: (_, _, _) => Center(child: Icon(Icons.image_not_supported, color: pal.sub)),
      ),
    ]);
  }
}

/// Xem ảnh toàn màn hình: phóng to tự do, vuốt ngang giữa các ảnh, chạm để ẩn/hiện
/// thanh công cụ; có Tải xuống và Chuyển tiếp.
class GalleryViewer extends StatefulWidget {
  final MmPost post;
  final List<ChatImage> images;
  final int initial;
  const GalleryViewer({super.key, required this.post, required this.images, this.initial = 0});
  @override
  State<GalleryViewer> createState() => _GalleryViewerState();
}

class _GalleryViewerState extends State<GalleryViewer> {
  late final PageController _page = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  bool _chrome = true;
  bool _zoomed = false;
  final Map<int, TransformationController> _tc = {};

  TransformationController _ctl(int i) => _tc.putIfAbsent(i, () {
        final c = TransformationController();
        c.addListener(() {
          final z = c.value.getMaxScaleOnAxis() > 1.01;
          if (z != _zoomed && i == _index) setState(() => _zoomed = z);
        });
        return c;
      });

  @override
  void dispose() {
    _page.dispose();
    for (final c in _tc.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _doubleTap(int i, TapDownDetails? d) {
    final c = _ctl(i);
    if (c.value.getMaxScaleOnAxis() > 1.01) {
      c.value = Matrix4.identity();
    } else {
      final p = d?.localPosition ?? Offset.zero;
      c.value = Matrix4.identity()
        ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
        ..scaleByDouble(2.5, 2.5, 1, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final sent = widget.post.sendState == SendState.sent;
    TapDownDetails? lastDown;
    return EscToPop(child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _page,
          physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          itemCount: widget.images.length,
          onPageChanged: (i) => setState(() {
            _index = i;
            _zoomed = false;
          }),
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => setState(() => _chrome = !_chrome),
            onDoubleTapDown: (d) => lastDown = d,
            onDoubleTap: () => _doubleTap(i, lastDown),
            child: InteractiveViewer(
              transformationController: _ctl(i),
              minScale: 1,
              maxScale: 10,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              child: SizedBox.expand(
                child: Image(
                  image: widget.images[i].provider(app, full: true),
                  fit: BoxFit.contain,
                  loadingBuilder: (_, child, p) => p == null
                      ? child
                      : Stack(alignment: Alignment.center, children: [
                          Image(image: widget.images[i].provider(app), fit: BoxFit.contain),
                          const CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
                        ]),
                  errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 48)),
                ),
              ),
            ),
          ),
        ),
        AnimatedOpacity(
          opacity: _chrome ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: !_chrome,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent]),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  child: Row(children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    if (widget.images.length > 1)
                      Text('${_index + 1}/${widget.images.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (sent && widget.images[_index].url == null && widget.images[_index].file != null) ...[
                      IconButton(
                        tooltip: tr('Chuyển tiếp'),
                        icon: const Icon(Icons.shortcut, color: Colors.white),
                        onPressed: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => ForwardPage(post: widget.post))),
                      ),
                      IconButton(
                        tooltip: tr('Tải xuống'),
                        icon: const Icon(Icons.download, color: Colors.white),
                        onPressed: () => saveMedia(context, [widget.images[_index].file!]),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    ));
  }
}


/// Tin ghi âm: nút phát/dừng, thanh tiến trình, thời lượng.
class AudioMessage extends StatefulWidget {
  final MmFile file;
  const AudioMessage({super.key, required this.file});
  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  final _player = AudioPlayer();
  Duration _pos = Duration.zero;
  Duration _len = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  String? _path;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((p) => mounted ? setState(() => _pos = p) : null);
    _player.onDurationChanged.listen((d) => mounted ? setState(() => _len = d) : null);
    _player.onPlayerComplete.listen((_) => mounted ? setState(() {
          _playing = false;
          _pos = Duration.zero;
        }) : null);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    if (_path == null) {
      final app = context.read<AppState>();
      setState(() => _loading = true);
      try {
        final local = app.localPathFor(widget.file.id);
        if (local != null && File(local).existsSync()) {
          _path = local;
        } else {
          final dir = await getTemporaryDirectory();
          final f = File('${dir.path}/${widget.file.id}_${widget.file.name}');
          if (!f.existsSync()) await f.writeAsBytes(await app.api.fileBytes(widget.file.id));
          _path = f.path;
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
        return;
      }
    }
    await _player.play(DeviceFileSource(_path!));
    if (mounted) {
      setState(() {
        _loading = false;
        _playing = true;
      });
    }
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final total = _len.inMilliseconds == 0 ? 1 : _len.inMilliseconds;
    return Container(
      width: 250,
      margin: const EdgeInsets.only(bottom: 4, top: 2),
      child: Row(children: [
        GestureDetector(
          onTap: _loading ? null : _toggle,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
            child: _loading
                ? const Padding(padding: EdgeInsets.all(11), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.black),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _pos.inMilliseconds / total,
                minHeight: 5,
                backgroundColor: pal.text.withValues(alpha: .15),
                color: pal.accentText,
              ),
            ),
            const SizedBox(height: 5),
            Row(children: [
              Icon(Icons.mic, size: 14, color: pal.sub),
              const SizedBox(width: 3),
              Text(_len == Duration.zero ? tr('Tin ghi âm') : _fmt(_playing || _pos > Duration.zero ? _pos : _len),
                  style: TextStyle(fontSize: 12.5, color: pal.sub)),
            ]),
          ]),
        ),
      ]),
    );
  }
}
