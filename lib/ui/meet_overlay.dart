import '../i18n/i18n.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../calls/meet_room.dart';
import 'markdown_view.dart';

// Giao diện phòng họp trên màn hình cuộc gọi: sân khấu trình chiếu (trợ lý AI / chủ phòng điều khiển), web chia sẻ
// đồng bộ cuộn / bấm, cảm xúc bay lên, bình luận nổi và bảng bình luận.

bool get webShareSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Sân khấu: web chia sẻ hoặc nội dung trình chiếu (markdown / ảnh / video / slide / hình vẽ) + phụ đề.
class MeetStage extends StatelessWidget {
  final MeetRoom room;
  const MeetStage({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    final s = room.stage;
    Widget body;
    if (room.webUrl != null) {
      body = webShareSupported
          ? SharedWeb(room: room, key: ValueKey(room.webUrl))
          : Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.public, color: Colors.white70, size: 48),
                const SizedBox(height: 10),
                Text(room.webUrl!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: () => launchUrl(Uri.parse(room.webUrl!), mode: LaunchMode.externalApplication),
                    child: Text(tr('Mở trong trình duyệt'))),
              ]),
            );
    } else {
      body = switch (s?['kind']) {
        'image' => InteractiveViewer(child: Center(child: Image.network('${s!['url']}', fit: BoxFit.contain))),
        'video' => _StageVideo(url: '${s!['url']}', key: ValueKey(s['url'])),
        'slides' => _Slides(items: [for (final x in (s!['items'] as List? ?? const [])) (x as Map).cast<String, dynamic>()], index: (s['index'] as num?)?.toInt() ?? 0),
        'draw' => CustomPaint(painter: _Strokes(s!['strokes'] as List? ?? const []), child: const SizedBox.expand()),
        _ => _Card(child: MarkdownView(text: '${s?['content'] ?? ''}', style: const TextStyle(color: Color(0xFF1F1F1F), fontSize: 20, height: 1.45))),
      };
    }
    return Stack(children: [
      Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(14), child: ColoredBox(color: const Color(0xFF111316), child: body))),
      if (room.caption != null)
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: .72), borderRadius: BorderRadius.circular(10)),
              child: Text(room.caption!,
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17, height: 1.35, fontWeight: FontWeight.w500)),
            ),
          ),
        ),
    ]);
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.all(18),
          padding: const EdgeInsets.all(26),
          constraints: const BoxConstraints(maxWidth: 1000),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
          child: SingleChildScrollView(child: child),
        ),
      );
}

class _Slides extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final int index;
  const _Slides({required this.items, required this.index});
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox();
    final i = index.clamp(0, items.length - 1);
    final it = items[i];
    final img = it['image_url'] as String?;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: Container(
        key: ValueKey(i),
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0F2027), Color(0xFF2C5364)]),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${it['title'] ?? ''}', style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, height: 1.2)),
          const SizedBox(height: 16),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: SingleChildScrollView(
                  child: MarkdownView(text: '${it['body_md'] ?? it['body'] ?? ''}', style: const TextStyle(color: Colors.white, fontSize: 20, height: 1.5)),
                ),
              ),
              if (img != null) ...[
                const SizedBox(width: 20),
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(img, fit: BoxFit.contain))),
              ],
            ]),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Text('${i + 1} / ${items.length}', style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ),
        ]),
      ),
    );
  }
}

class _Strokes extends CustomPainter {
  final List strokes;
  _Strokes(this.strokes);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (final s in strokes) {
      final m = (s as Map);
      final pts = [for (final p in (m['points'] as List? ?? const [])) Offset(((p as List)[0] as num) * size.width, (p[1] as num) * size.height)];
      if (pts.length < 2) continue;
      final hex = '${m['color'] ?? '#E53935'}'.replaceFirst('#', '');
      final paint = Paint()
        ..color = Color(int.tryParse('FF$hex', radix: 16) ?? 0xFFE53935)
        ..strokeWidth = ((m['width'] as num?)?.toDouble() ?? 4)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Strokes old) => old.strokes != strokes;
}

class _StageVideo extends StatefulWidget {
  final String url;
  const _StageVideo({super.key, required this.url});
  @override
  State<_StageVideo> createState() => _StageVideoState();
}

class _StageVideoState extends State<_StageVideo> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(Uri.parse(widget.url))
    ..initialize().then((_) {
      if (mounted) setState(() {});
      _c.play();
    });
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: _c.value.isInitialized
            ? AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c))
            : const CircularProgressIndicator(color: Colors.white),
      );
}

/// Web chia sẻ: người mở (người điều khiển) cuộn / bấm thì mọi máy cuộn / bấm theo.
class SharedWeb extends StatefulWidget {
  final MeetRoom room;
  const SharedWeb({super.key, required this.room});
  @override
  State<SharedWeb> createState() => _SharedWebState();
}

class _SharedWebState extends State<SharedWeb> {
  late final WebViewController _web;
  StreamSubscription? _clicks;
  double _applied = -1;
  int _lastSent = 0;

  static const _js = '''
(function(){
  if (window.__flygo) return; window.__flygo = 1;
  function frac(){ var h = document.documentElement.scrollHeight - window.innerHeight; return h > 0 ? window.scrollY / h : 0; }
  window.addEventListener('scroll', function(){ Flygo.postMessage(JSON.stringify({t:'s', y: frac()})); }, {passive:true});
  document.addEventListener('click', function(e){ if (e.isTrusted) Flygo.postMessage(JSON.stringify({t:'c', x: e.clientX / window.innerWidth, y: e.clientY / window.innerHeight})); }, true);
})();''';

  @override
  void initState() {
    super.initState();
    final room = widget.room;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Flygo', onMessageReceived: (m) {
        if (!room.iDriveWeb) return;
        final s = m.message;
        final t = RegExp(r'"t":"(\w)"').firstMatch(s)?.group(1);
        double n(String k) => double.tryParse(RegExp('"$k":([0-9.eE-]+)').firstMatch(s)?.group(1) ?? '') ?? 0;
        if (t == 's') {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastSent < 120) return;
          _lastSent = now;
          room.scrollWeb(n('y'));
        } else if (t == 'c') {
          room.clickWeb(n('x'), n('y'));
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          _web.runJavaScript(_js);
          // Người điều khiển chuyển trang: mọi máy chuyển theo.
          if (room.iDriveWeb && url != room.webUrl) room.navWeb(url);
          _applyScroll(force: true);
        },
      ))
      ..loadRequest(Uri.parse(room.webUrl!));
    room.addListener(_applyScroll);
    _clicks = room.webClicks.stream.listen((p) {
      if (room.iDriveWeb) return;
      _web.runJavaScript(
          'var e=document.elementFromPoint(${p.$1}*window.innerWidth, ${p.$2}*window.innerHeight); if(e) e.click();');
    });
  }

  void _applyScroll({bool force = false}) {
    final room = widget.room;
    if (room.iDriveWeb) return;
    if (!force && (room.webScroll - _applied).abs() < .001) return;
    _applied = room.webScroll;
    _web.runJavaScript(
        'window.scrollTo({top: ${room.webScroll} * (document.documentElement.scrollHeight - window.innerHeight), behavior: "smooth"});');
  }

  @override
  void dispose() {
    widget.room.removeListener(_applyScroll);
    _clicks?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}

/// Cảm xúc bay lên (của mọi người trong cuộc gọi).
class ReactionsLayer extends StatefulWidget {
  final Stream<(String, String)> reactions;
  const ReactionsLayer({super.key, required this.reactions});
  @override
  State<ReactionsLayer> createState() => _ReactionsLayerState();
}

class _ReactionsLayerState extends State<ReactionsLayer> with TickerProviderStateMixin {
  final _items = <(String, double, AnimationController)>[];
  StreamSubscription? _sub;
  final _rnd = Random();

  @override
  void initState() {
    super.initState();
    _sub = widget.reactions.listen((r) {
      final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
      final item = (r.$2, .55 + _rnd.nextDouble() * .4, c);
      setState(() => _items.add(item));
      c.forward().whenComplete(() {
        if (!mounted) return;
        setState(() => _items.remove(item));
        c.dispose();
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final i in _items) {
      i.$3.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: LayoutBuilder(
          builder: (context, box) => Stack(children: [
            for (final (e, x, c) in _items)
              AnimatedBuilder(
                animation: c,
                builder: (_, _) => Positioned(
                  left: x * box.maxWidth + sin(c.value * 8) * 14,
                  bottom: 90 + c.value * box.maxHeight * .6,
                  child: Opacity(opacity: (1 - c.value).clamp(0, 1), child: Text(e, style: const TextStyle(fontSize: 36))),
                ),
              ),
          ]),
        ),
      );
}

/// Bình luận mới hiện nổi ở góc trái dưới vài giây.
class CommentsTicker extends StatefulWidget {
  final MeetRoom room;
  const CommentsTicker({super.key, required this.room});
  @override
  State<CommentsTicker> createState() => _CommentsTickerState();
}

class _CommentsTickerState extends State<CommentsTicker> {
  final _shown = <MeetComment>[];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.room.newComments.stream.listen((c) {
      setState(() {
        _shown.add(c);
        if (_shown.length > 4) _shown.removeAt(0);
      });
      Timer(const Duration(seconds: 7), () {
        if (mounted) setState(() => _shown.remove(c));
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final c in _shown)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              constraints: const BoxConstraints(maxWidth: 320),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(14)),
              child: RichText(
                text: TextSpan(children: [
                  TextSpan(text: '${c.bot ? '✨ ' : ''}${c.name}: ', style: const TextStyle(color: Color(0xFF8AB4F8), fontWeight: FontWeight.w700, fontSize: 14)),
                  TextSpan(text: c.text, style: const TextStyle(color: Colors.white, fontSize: 14)),
                ]),
              ),
            ),
        ]),
      );
}

/// Bảng bình luận của cuộc họp.
Future<void> showMeetComments(BuildContext context, MeetRoom room) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF202124),
      builder: (ctx) {
        final ctl = TextEditingController();
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .6,
            child: ListenableBuilder(
              listenable: room,
              builder: (ctx, _) => Column(children: [
                Text(tr('Bình luận'), style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                Expanded(
                  child: room.comments.isEmpty
                      ? Center(child: Text(tr('Chưa có bình luận.'), style: const TextStyle(color: Colors.white54)))
                      : ListView(reverse: true, padding: const EdgeInsets.all(14), children: [
                          for (final c in room.comments.reversed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: RichText(
                                text: TextSpan(children: [
                                  TextSpan(text: '${c.bot ? '✨ ' : ''}${c.name}\n', style: const TextStyle(color: Color(0xFF8AB4F8), fontWeight: FontWeight.w700)),
                                  TextSpan(text: c.text, style: const TextStyle(color: Colors.white, fontSize: 15)),
                                ]),
                              ),
                            ),
                        ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: ctl,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: tr('Viết bình luận…'),
                          hintStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: const Color(0xFF303134),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onSubmitted: (v) {
                          if (v.trim().isEmpty) return;
                          room.comment(v.trim());
                          ctl.clear();
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send_rounded, color: Color(0xFF8AB4F8)),
                      onPressed: () {
                        if (ctl.text.trim().isEmpty) return;
                        room.comment(ctl.text.trim());
                        ctl.clear();
                      },
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
