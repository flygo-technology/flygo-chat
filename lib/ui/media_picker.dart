import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import 'theme.dart';

/// Một file được chọn để gửi.
class PickedMedia {
  final String path;
  final String name;
  PickedMedia(this.path, this.name);
}

/// Kết quả từ bảng chọn: danh sách file + chú thích (nếu có).
class MediaPickResult {
  final List<PickedMedia> files;
  final String caption;
  final bool openDocuments;
  final bool openGallery;
  MediaPickResult(this.files, {this.caption = '', this.openDocuments = false, this.openGallery = false});
}

/// Bảng chọn ảnh kiểu WhatsApp: ô đầu là máy ảnh trực tiếp, sau đó là ảnh/video
/// trong máy từ mới đến cũ. Chọn nhiều ảnh rồi bấm Gửi.
Future<MediaPickResult?> showMediaPicker(BuildContext context) {
  return showModalBottomSheet<MediaPickResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => const _MediaPicker(),
  );
}

class _MediaPicker extends StatefulWidget {
  const _MediaPicker();
  @override
  State<_MediaPicker> createState() => _MediaPickerState();
}

class _MediaPickerState extends State<_MediaPicker> {
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = [];
  bool _loading = true;
  bool _denied = false;
  bool _more = true;
  int _page = 0;
  CameraController? _cam;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _load();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return;
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.low, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _cam = c);
    } catch (_) {}
  }

  Future<void> _load() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.hasAccess) {
      setState(() {
        _denied = true;
        _loading = false;
      });
      return;
    }
    final list = await PhotoManager.getAssetListPaged(page: _page, pageCount: 60, type: RequestType.common);
    if (!mounted) return;
    setState(() {
      _assets.addAll(list);
      _more = list.length == 60;
      _page++;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _cam?.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    final nav = Navigator.of(context);
    await _cam?.dispose();
    setState(() => _cam = null);
    if (!mounted) return;
    final r = await Navigator.of(context).push<MediaPickResult>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CameraCapturePage()),
    );
    if (r != null) {
      nav.pop(r);
    } else {
      _initCamera();
    }
  }

  void _toggle(AssetEntity a) {
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(a) ? _selected.remove(a) : _selected.add(a));
  }

  Future<void> _send() async {
    final nav = Navigator.of(context);
    final files = <PickedMedia>[];
    for (final a in _selected) {
      final f = await a.originFile ?? await a.file;
      if (f != null) files.add(PickedMedia(f.path, a.title ?? f.uri.pathSegments.last));
    }
    nav.pop(MediaPickResult(files));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final h = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: h * .75,
      child: Column(children: [
        Container(
          margin: const EdgeInsets.only(top: 8),
          width: 36,
          height: 5,
          decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(3)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Text('Ảnh gần đây', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => Navigator.pop(context, MediaPickResult(const [], openGallery: true)),
              icon: Icon(Icons.photo_library_outlined, color: pal.accentText),
              label: Text('Thư viện', style: TextStyle(color: pal.accentText)),
            ),
            TextButton.icon(
              onPressed: () => Navigator.pop(context, MediaPickResult(const [], openDocuments: true)),
              icon: Icon(Icons.insert_drive_file_outlined, color: pal.accentText),
              label: Text('Tài liệu', style: TextStyle(color: pal.accentText)),
            ),
          ]),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (_more && !_loading && n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
                      _loading = true;
                      _load();
                    }
                    return false;
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.all(2),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                    itemCount: _assets.length + 1 + (_denied ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (_denied && i == 1) {
                        return GestureDetector(
                          onTap: () async {
                            final perm = await PhotoManager.requestPermissionExtend();
                            if (perm.hasAccess) {
                              setState(() => _denied = false);
                              _load();
                            } else {
                              PhotoManager.openSetting();
                            }
                          },
                          child: Container(
                            color: pal.surface2,
                            padding: const EdgeInsets.all(8),
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(Icons.lock_open, color: pal.accentText),
                              const SizedBox(height: 6),
                              Text('Cho phép xem ảnh trong máy',
                                  textAlign: TextAlign.center, style: TextStyle(color: pal.text, fontSize: 12.5)),
                            ]),
                          ),
                        );
                      }
                      if (i == 0) {
                        return GestureDetector(
                          onTap: _openCamera,
                          child: Stack(fit: StackFit.expand, children: [
                            Container(color: Colors.black),
                            if (_cam != null && _cam!.value.isInitialized)
                              ClipRect(
                                child: FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: _cam!.value.previewSize?.height ?? 100,
                                    height: _cam!.value.previewSize?.width ?? 100,
                                    child: CameraPreview(_cam!),
                                  ),
                                ),
                              ),
                            const Center(child: Icon(Icons.photo_camera, color: Colors.white, size: 34)),
                          ]),
                        );
                      }
                      final a = _assets[i - 1];
                      final idx = _selected.indexOf(a);
                      return GestureDetector(
                        onTap: () => _toggle(a),
                        child: Stack(fit: StackFit.expand, children: [
                          _Thumb(asset: a),
                          if (a.type == AssetType.video)
                            Positioned(
                              left: 6,
                              bottom: 4,
                              child: Row(children: [
                                const Icon(Icons.videocam, color: Colors.white, size: 16),
                                const SizedBox(width: 3),
                                Text(_dur(a.duration),
                                    style: const TextStyle(color: Colors.white, fontSize: 12, shadows: [Shadow(blurRadius: 3)])),
                              ]),
                            ),
                          if (idx >= 0) Container(color: Colors.black.withValues(alpha: .25)),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: idx >= 0 ? pal.accent : Colors.black26,
                                border: Border.all(color: Colors.white, width: 1.6),
                              ),
                              child: idx >= 0
                                  ? Text('${idx + 1}',
                                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 13))
                                  : null,
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
        ),
        if (_selected.isNotEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.black),
                  onPressed: _send,
                  icon: const Icon(Icons.send_rounded),
                  label: Text('Gửi ${_selected.length} mục', style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  static String _dur(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class _Thumb extends StatefulWidget {
  final AssetEntity asset;
  const _Thumb({required this.asset});
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _data;
  @override
  void initState() {
    super.initState();
    widget.asset.thumbnailDataWithSize(const ThumbnailSize(240, 240)).then((d) {
      if (mounted) setState(() => _data = d);
    });
  }

  @override
  Widget build(BuildContext context) => _data == null
      ? Container(color: Pal.of(context).surface2)
      : Image.memory(_data!, fit: BoxFit.cover, gaplessPlayback: true);
}

/// Màn chụp: chạm để chụp ảnh, giữ để quay video; xong thì xem lại và gửi.
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});
  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage> {
  List<CameraDescription> _cams = [];
  CameraController? _c;
  int _index = 0;
  bool _recording = false;
  DateTime? _recStart;
  Timer? _tick;
  FlashMode _flash = FlashMode.off;

  @override
  void initState() {
    super.initState();
    availableCameras().then((c) {
      _cams = c;
      _index = c.indexWhere((x) => x.lensDirection == CameraLensDirection.back).clamp(0, c.length - 1);
      _start();
    }).catchError((_) {});
  }

  Future<void> _start() async {
    if (_cams.isEmpty) return;
    await _c?.dispose();
    final c = CameraController(_cams[_index], ResolutionPreset.high, enableAudio: true);
    await c.initialize();
    await c.setFlashMode(_flash);
    if (mounted) setState(() => _c = c);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _c?.dispose();
    super.dispose();
  }

  Future<void> _photo() async {
    final c = _c;
    if (c == null || _recording) return;
    final x = await c.takePicture();
    _review(x.path, isVideo: false);
  }

  Future<void> _startVideo() async {
    final c = _c;
    if (c == null || _recording) return;
    HapticFeedback.mediumImpact();
    await c.startVideoRecording();
    setState(() {
      _recording = true;
      _recStart = DateTime.now();
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  Future<void> _stopVideo() async {
    final c = _c;
    if (c == null || !_recording) return;
    _tick?.cancel();
    final x = await c.stopVideoRecording();
    setState(() => _recording = false);
    _review(x.path, isVideo: true);
  }

  Future<void> _review(String path, {required bool isVideo}) async {
    final nav = Navigator.of(context);
    final r = await Navigator.of(context).push<MediaPickResult>(
      MaterialPageRoute(builder: (_) => _ReviewPage(path: path, isVideo: isVideo)),
    );
    if (r != null) nav.pop(r);
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final secs = _recStart == null ? 0 : DateTime.now().difference(_recStart!).inSeconds;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          if (c != null && c.value.isInitialized)
            Positioned.fill(
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: c.value.previewSize?.height ?? 1,
                    height: c.value.previewSize?.width ?? 1,
                    child: CameraPreview(c),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(children: [
              IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 30), onPressed: () => Navigator.pop(context)),
              const Spacer(),
              if (_recording)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(12)),
                  child: Text('${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              const Spacer(),
              IconButton(
                icon: Icon(_flash == FlashMode.off ? Icons.flash_off : Icons.flash_on, color: Colors.white, size: 28),
                onPressed: () async {
                  _flash = _flash == FlashMode.off ? FlashMode.always : FlashMode.off;
                  await _c?.setFlashMode(_flash);
                  setState(() {});
                },
              ),
            ]),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                const SizedBox(width: 48),
                GestureDetector(
                  onTap: _photo,
                  onLongPressStart: (_) => _startVideo(),
                  onLongPressEnd: (_) => _stopVideo(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: _recording ? 92 : 78,
                    height: _recording ? 92 : 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 5),
                      color: _recording ? Colors.red : Colors.white24,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white, size: 32),
                  onPressed: _cams.length < 2 || _recording
                      ? null
                      : () {
                          _index = (_index + 1) % _cams.length;
                          _start();
                        },
                ),
              ]),
              const SizedBox(height: 12),
              Text(_recording ? 'Thả tay để dừng quay' : 'Chạm để chụp, giữ để quay video',
                  style: const TextStyle(color: Colors.white, fontSize: 13, shadows: [Shadow(blurRadius: 4)])),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ReviewPage extends StatefulWidget {
  final String path;
  final bool isVideo;
  const _ReviewPage({required this.path, required this.isVideo});
  @override
  State<_ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<_ReviewPage> {
  final _caption = TextEditingController();
  VideoPlayerController? _v;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _v = VideoPlayerController.file(File(widget.path))
        ..initialize().then((_) {
          _v!.setLooping(true);
          _v!.play();
          setState(() {});
        });
    }
  }

  @override
  void dispose() {
    _v?.dispose();
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final name = widget.path.split(Platform.pathSeparator).last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Column(children: [
        Expanded(
          child: Center(
            child: widget.isVideo
                ? (_v != null && _v!.value.isInitialized
                    ? AspectRatio(aspectRatio: _v!.value.aspectRatio, child: VideoPlayer(_v!))
                    : const CircularProgressIndicator())
                : Image.file(File(widget.path)),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _caption,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Thêm chú thích...',
                    hintStyle: const TextStyle(color: Colors.white60),
                    filled: true,
                    fillColor: const Color(0xFF1F2C34),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: pal.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.pop(
                      context, MediaPickResult([PickedMedia(widget.path, name)], caption: _caption.text.trim())),
                  child: const SizedBox(width: 50, height: 50, child: Icon(Icons.send_rounded, color: Colors.black)),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
