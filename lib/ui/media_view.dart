import 'dart:io';

import 'package:flutter/material.dart';
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
  final double aspect;
  ChatImage({this.localPath, this.file, this.aspect = 4 / 3});

  ImageProvider provider(AppState app, {bool full = false}) {
    final p = localPath ?? (file == null ? null : app.localPathFor(file!.id));
    if (p != null && File(p).existsSync()) return FileImage(File(p));
    final url = full ? app.api.fileUrl(file!.id) : app.api.previewUrl(file!.id);
    return NetworkImage(url, headers: app.api.headers);
  }

  ImageProvider? thumb(AppState app) =>
      file == null || app.localPathFor(file!.id) != null ? null : NetworkImage(app.api.thumbUrl(file!.id), headers: app.api.headers);
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
  const ChatMedia({super.key, required this.post, required this.images, this.overlay, this.sending = false, this.maxWidth = 280});

  void _open(BuildContext context, int index) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => GalleryViewer(post: post, images: images, initial: index),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final w = maxWidth.clamp(160.0, 300.0);
    Widget content;
    if (images.length == 1) {
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
                  Text('${images.length} ảnh', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
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
    return Scaffold(
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
                    if (sent && widget.images[_index].file != null) ...[
                      IconButton(
                        tooltip: 'Chuyển tiếp',
                        icon: const Icon(Icons.shortcut, color: Colors.white),
                        onPressed: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => ForwardPage(post: widget.post))),
                      ),
                      IconButton(
                        tooltip: 'Tải xuống',
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
    );
  }
}
