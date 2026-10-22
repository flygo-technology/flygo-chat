import '../i18n/i18n.dart';
import 'dart:io';

import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';

import '../api/stt.dart';
import 'package:gal/gal.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_page.dart' show saveMedia;
import 'forward_page.dart';
import 'image_edit.dart';
import 'clip.dart';
import 'common.dart';
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
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlbumPage(post: post, images: images))),
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
    // Sticker có chữ ở cả phần dưới: giờ gửi đặt ngay dưới sticker, không đè lên chữ.
    if (sticker && overlay != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        ChatMedia(post: post, images: images, sending: sending, maxWidth: maxWidth, sticker: true),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: overlay!),
          ),
        ),
      ]);
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

  /// Sửa ảnh đang xem (vẽ, cắt, xoay), rồi chọn gửi lại vào cuộc trò chuyện, chuyển tiếp hoặc lưu.
  Future<void> _edit(ChatImage img) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    String path;
    try {
      final local = img.localPath ?? app.localPathFor(img.file!.id);
      path = local != null && File(local).existsSync() ? local : (await app.download(img.file!)).path;
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không tải được ảnh để sửa.'))));
      return;
    }
    if (!mounted) return;
    final edited = await editImage(context, path);
    if (edited == null || !mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        final pal = Pal.of(ctx);
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(edited), height: 180)),
            ),
            ListTile(
              leading: Icon(Icons.send_rounded, color: pal.text),
              title: Text(tr('Gửi vào cuộc trò chuyện này'), style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(ctx, 'send'),
            ),
            ListTile(
              leading: Icon(Icons.shortcut, color: pal.text),
              title: Text(tr('Chuyển tiếp...'), style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(ctx, 'forward'),
            ),
            ListTile(
              leading: Icon(Icons.download, color: pal.text),
              title: Text(tr('Lưu về máy'), style: TextStyle(color: pal.text)),
              onTap: () => Navigator.pop(ctx, 'save'),
            ),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
    if (!mounted || choice == null) return;
    final name = 'edited_${DateTime.now().millisecondsSinceEpoch}.png';
    switch (choice) {
      case 'send':
        await app.sendMedia(widget.post.channelId, [(edited, name, 'image/png', await imageAspect(edited))]);
        if (mounted) Navigator.pop(context);
      case 'forward':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ForwardPage(localPaths: [edited])));
      case 'save':
        await saveLocalImage(context, edited);
    }
  }

  /// Giữ / nháy phải vào ảnh đang xem: Sao chép, Sửa, Chuyển tiếp, Tải xuống.
  Future<void> _imageMenu(int i, Offset at) async {
    final img = widget.images[i];
    final sent = widget.post.sendState == SendState.sent && img.url == null && img.file != null;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    PopupMenuItem<String> item(String v, IconData icon, String label) => PopupMenuItem(
          value: v,
          height: 44,
          child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
        );
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        item('copy', Icons.copy, tr('Sao chép')),
        if (sent) ...[
          item('edit', Icons.edit_outlined, tr('Sửa')),
          item('forward', Icons.shortcut, tr('Chuyển tiếp')),
          item('download', Icons.download, tr('Tải xuống')),
        ],
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'copy':
        await copyChatImage(context, img);
      case 'edit':
        await _edit(img);
      case 'forward':
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => widget.images.length > 1 ? ForwardPage(files: [img.file!]) : ForwardPage(post: widget.post)));
      case 'download':
        await saveMedia(context, [img.file!]);
    }
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
            onLongPressStart: (d) => _imageMenu(i, d.globalPosition),
            onSecondaryTapDown: (d) => _imageMenu(i, d.globalPosition),
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
                        tooltip: tr('Sửa'),
                        icon: const Icon(Icons.edit_outlined, color: Colors.white),
                        onPressed: () => _edit(widget.images[_index]),
                      ),
                      IconButton(
                        tooltip: tr('Chuyển tiếp'),
                        icon: const Icon(Icons.shortcut, color: Colors.white),
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => widget.images.length > 1
                                ? ForwardPage(files: [widget.images[_index].file!])
                                : ForwardPage(post: widget.post))),
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

  /// Chữ nhận diện từ tin ghi âm (nhớ trong phiên để không chuyển lại).
  static final Map<String, String> _transcripts = {};
  bool _transcribing = false;

  Future<String> _ensurePath() async {
    if (_path != null) return _path!;
    final app = context.read<AppState>();
    final local = app.localPathFor(widget.file.id);
    if (local != null && File(local).existsSync()) return _path = local;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${widget.file.id}_${widget.file.name}');
    if (!f.existsSync()) await f.writeAsBytes(await app.api.fileBytes(widget.file.id));
    return _path = f.path;
  }

  Future<void> _toText() async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _transcribing = true);
    try {
      final text = await transcribeAudio(api, await _ensurePath());
      _transcripts[widget.file.id] = text.isEmpty ? tr('(Không nghe rõ nội dung)') : text;
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không chuyển được thành chữ. Kiểm tra kết nối mạng.'))));
    }
    if (mounted) setState(() => _transcribing = false);
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    if (_path == null) {
      setState(() => _loading = true);
      try {
        await _ensurePath();
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
    final transcript = _transcripts[widget.file.id];
    return Container(
      width: 250,
      margin: const EdgeInsets.only(bottom: 4, top: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        GestureDetector(
          onTap: _loading ? null : _toggle,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
            child: _loading
                ? const Padding(padding: EdgeInsets.all(11), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
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
              const Spacer(),
              if (transcript == null)
                GestureDetector(
                  onTap: _transcribing ? null : _toText,
                  child: _transcribing
                      ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: pal.accentText))
                      : Text(tr('Chuyển thành chữ'), style: TextStyle(fontSize: 12.5, color: pal.accentText, fontWeight: FontWeight.w600)),
                ),
            ]),
          ]),
        ),
      ]),
      if (transcript != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: SelectableText(transcript, style: TextStyle(fontSize: 15, color: pal.text, height: 1.3)),
        ),
      ]),
    );
  }
}

/// Tỉ lệ khung ảnh, đọc từ đầu file.
Future<double> imageAspect(String path) async {
  try {
    final buf = await ui.ImmutableBuffer.fromFilePath(path);
    final desc = await ui.ImageDescriptor.encoded(buf);
    final r = desc.width / desc.height;
    desc.dispose();
    buf.dispose();
    return r;
  } catch (_) {
    return 4 / 3;
  }
}

/// Lưu ảnh trên máy vào thư viện ảnh (điện thoại) hoặc thư mục Tải về (máy tính).
Future<void> saveLocalImage(BuildContext context, String path) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putImage(path, album: 'Flygo Chat');
      messenger.showSnackBar(toast(Text(tr('Đã lưu vào thư viện ảnh'))));
    } else {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      await File(path).copy('${dir.path}${Platform.pathSeparator}${path.split(Platform.pathSeparator).last}');
      messenger.showSnackBar(toast(Text(tr('Đã lưu vào thư mục Tải về'))));
    }
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không lưu được. Kiểm tra quyền truy cập ảnh và kết nối mạng.'))));
  }
}

/// Các ảnh của một tin xếp dọc từ trên xuống. Chạm một ảnh để xem phóng to;
/// giữ một ảnh để vào chế độ chọn, rồi chuyển tiếp / tải các ảnh đã chọn.
class AlbumPage extends StatefulWidget {
  final MmPost post;
  final List<ChatImage> images;
  const AlbumPage({super.key, required this.post, required this.images});
  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  final Set<int> _sel = {};
  bool _selecting = false;

  void _toggle(int i) => setState(() {
        _sel.contains(i) ? _sel.remove(i) : _sel.add(i);
        if (_sel.isEmpty) _selecting = false;
      });

  void _view(int i) {
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => GalleryViewer(post: widget.post, images: widget.images, initial: i),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  List<MmFile> get _selectedFiles =>
      [for (final i in _sel.toList()..sort()) if (widget.images[i].file != null) widget.images[i].file!];

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final sent = widget.post.sendState == SendState.sent;
    final sender = app.users[widget.post.userId]?.displayName ?? '';
    final when = DateTime.fromMillisecondsSinceEpoch(widget.post.createAt);
    final width = MediaQuery.sizeOf(context).width.clamp(0.0, 720.0);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            _selecting = false;
            _sel.clear();
          });
        }
      },
      child: EscToPop(
        child: Scaffold(
          backgroundColor: pal.bg,
          appBar: AppBar(
            backgroundColor: pal.bg,
            surfaceTintColor: Colors.transparent,
            leading: _selecting
                ? IconButton(
                    icon: Icon(Icons.close, color: pal.text),
                    onPressed: () => setState(() {
                          _selecting = false;
                          _sel.clear();
                        }))
                : null,
            title: _selecting
                ? Text(tr('Đã chọn {0}', [_sel.length]), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('{0} ảnh', [widget.images.length]), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600, fontSize: 17)),
                    Text('$sender · ${two(when.hour)}:${two(when.minute)} ${two(when.day)}/${two(when.month)}',
                        style: TextStyle(color: pal.sub, fontSize: 13)),
                  ]),
            actions: [
              if (_selecting)
                TextButton(
                  onPressed: () => setState(() => _sel
                    ..clear()
                    ..addAll(List.generate(widget.images.length, (i) => i))),
                  child: Text(tr('Chọn tất cả'), style: TextStyle(color: pal.accentText)),
                ),
            ],
          ),
          body: ListView.builder(
            padding: const EdgeInsets.only(bottom: 90, top: 4),
            itemCount: widget.images.length,
            itemBuilder: (_, i) {
              final img = widget.images[i];
              final picked = _sel.contains(i);
              return Center(
                child: GestureDetector(
                  onTap: () => _selecting ? _toggle(i) : _view(i),
                  onLongPress: sent
                      ? () => setState(() {
                            _selecting = true;
                            _sel.add(i);
                          })
                      : null,
                  onSecondaryTap: sent
                      ? () => setState(() {
                            _selecting = true;
                            _sel.add(i);
                          })
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Stack(children: [
                      AnimatedScale(
                        scale: picked ? .94 : 1,
                        duration: const Duration(milliseconds: 120),
                        child: SizedBox(
                          width: width,
                          height: width / img.aspect.clamp(.4, 3.0),
                          child: _Img(image: img, app: app),
                        ),
                      ),
                      if (_selecting)
                        Positioned(
                          right: 14,
                          top: 12,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: picked ? pal.accent : Colors.black26,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: picked ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
                          ),
                        ),
                    ]),
                  ),
                ),
              );
            },
          ),
          bottomNavigationBar: _selecting && _sel.isNotEmpty
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                    child: Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: pal.accentText,
                            side: BorderSide(color: pal.accentText),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () => saveMedia(context, _selectedFiles),
                          icon: const Icon(Icons.download),
                          label: Text(tr('Tải xuống')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: pal.accent,
                            foregroundColor: Colors.white,
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () async {
                            final files = _selectedFiles;
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ForwardPage(files: files)));
                            if (mounted) {
                              setState(() {
                                _selecting = false;
                                _sel.clear();
                              });
                            }
                          },
                          icon: const Icon(Icons.shortcut),
                          label: Text(tr('Chuyển tiếp ({0})', [_sel.length])),
                        ),
                      ),
                    ]),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// Sao chép một ảnh trong chat vào bộ nhớ tạm.
Future<void> copyChatImage(BuildContext context, ChatImage img) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final local = img.localPath ?? (img.file == null ? null : app.localPathFor(img.file!.id));
    final bytes = local != null && File(local).existsSync()
        ? await File(local).readAsBytes()
        : img.file != null
            ? await app.api.fileBytes(img.file!.id)
            : null;
    final ok = bytes != null && await copyImageToClipboard(bytes);
    messenger.showSnackBar(toast(Text(ok ? tr('Đã sao chép ảnh') : tr('Không sao chép được ảnh.'))));
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không sao chép được ảnh.'))));
  }
}

/// Video trong tin nhắn: hiện khung hình đầu của video (đang gửi thì kèm vòng tải), bấm để xem.
/// Windows / Linux chưa có trình phát video nhúng: hiện thẻ video như cũ.
class ChatVideo extends StatefulWidget {
  final MmFile? file;
  final String? localPath;
  final bool sending;
  const ChatVideo({super.key, this.file, this.localPath, this.sending = false});
  @override
  State<ChatVideo> createState() => _ChatVideoState();
}

class _ChatVideoState extends State<ChatVideo> {
  VideoPlayerController? _v;
  bool _failed = false;

  static bool get supported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (!supported) return;
    final app = context.read<AppState>();
    final local = widget.localPath ?? (widget.file == null ? null : app.localPathFor(widget.file!.id));
    final v = _v = local != null && File(local).existsSync()
        ? VideoPlayerController.file(File(local))
        : VideoPlayerController.networkUrl(Uri.parse(app.api.fileUrl(widget.file!.id)), httpHeaders: app.api.headers);
    v.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _v?.dispose();
    super.dispose();
  }

  void _open() {
    final f = widget.file;
    if (f != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPlayerPage(file: f)));
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final ready = v != null && v.value.isInitialized && !_failed;
    final aspect = ready ? v.value.aspectRatio.clamp(.56, 1.8) : 16 / 10;
    const w = 260.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 2),
      child: GestureDetector(
        onTap: widget.sending ? null : _open,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: w,
            height: (w / aspect).clamp(140.0, 380.0),
            color: Colors.black87,
            child: Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
              if (ready) FittedBox(fit: BoxFit.cover, child: SizedBox(width: v.value.size.width, height: v.value.size.height, child: VideoPlayer(v))),
              Center(
                child: widget.sending
                    ? Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                        child: const SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)),
                      )
                    : const Icon(Icons.play_circle_fill, color: Colors.white, size: 56),
              ),
              Positioned(
                left: 10,
                bottom: 8,
                right: 10,
                child: Row(children: [
                  const Icon(Icons.videocam, color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      ready ? _fmt(v.value.duration) : (widget.file?.name ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12, shadows: [Shadow(blurRadius: 4)]),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
