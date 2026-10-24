import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../api/mini_apps.dart';
import '../api/show_api.dart';
import '../config.dart' show isDesktop;
import '../i18n/i18n.dart';
import '../state/app_state.dart';
import 'mini_app_view.dart' show ScanOncePage;
import 'theme.dart';

// App Trình chiếu (mini app "show") dạng màn hình native: tab Danh sách slide và tab Đang trình chiếu.
// Mọi thao tác gọi bộ tool của app (ShowClient.call), cùng bộ tool AI dùng qua MCP.

String _err(Object e) => e is ShowException || e is MiniAppException ? '$e' : tr('Không kết nối được, thử lại sau.');

List<Map<String, dynamic>> _maps(Object? l) => [for (final x in (l as List? ?? const [])) (x as Map).cast<String, dynamic>()];

void _toast(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(toast(Text(text)));

/// Mã ghép 8 ký tự từ nội dung QR (`…/pair/<MÃ>`) hoặc mã gõ tay; không hợp lệ: null.
String? pairCodeOf(String raw) {
  final s = raw.trim();
  final m = RegExp(r'/pair/([A-Za-z0-9]{8})(?:[/?#]|$)').firstMatch(s);
  if (m != null) return m.group(1)!.toUpperCase();
  final c = s.replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(c) ? c.toUpperCase() : null;
}

/// Webview xem trước chạy được ở đây (Windows / Linux: hiện chữ của trang).
bool get _webPreview => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// Màn hình chính của app Trình chiếu. [pairCode]: mở từ QR của màn hình TV → hỏi ghép vào buổi nào.
class ShowHome extends StatefulWidget {
  final MiniApp app;
  final String mmToken;
  final String? pairCode;
  const ShowHome({super.key, required this.app, required this.mmToken, this.pairCode});
  @override
  State<ShowHome> createState() => _ShowHomeState();
}

class _ShowHomeState extends State<ShowHome> with SingleTickerProviderStateMixin {
  late final client = ShowClient(widget.app, widget.mmToken);
  late final _tabs = TabController(length: 2, vsync: this);
  final _liveKey = GlobalKey<_LiveListState>();

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && _tabs.index == 1) _liveKey.currentState?.reload();
    });
    if (widget.pairCode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => ShowPairPage(client: client, code: widget.pairCode!))));
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Bộ slide mới, sửa slide: nhờ trợ lý AI (app không có trình soạn tay).
  void _howToCreate() {
    final sample = tr('Làm slide báo cáo doanh thu quý 3, khoảng 5 trang, kèm ghi chú thuyết minh');
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.auto_awesome_rounded, size: 34),
        title: Text(tr('Tạo bằng trợ lý AI')),
        content: Text(tr('Mở cuộc trò chuyện với trợ lý AI và nhắn, ví dụ:\n\n"{0}"', [sample])),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: sample));
                Navigator.pop(d);
                _toast(context, tr('Đã chép câu mẫu'));
              },
              child: Text(tr('Chép câu mẫu'))),
          FilledButton(onPressed: () => Navigator.pop(d), child: Text(tr('Đã hiểu'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Pal.of(context).bg,
        appBar: AppBar(
          title: Text(widget.app.name),
          actions: [IconButton(icon: const Icon(Icons.add_rounded), tooltip: tr('Tạo bằng trợ lý AI'), onPressed: _howToCreate)],
          bottom: TabBar(controller: _tabs, tabs: [Tab(text: tr('Danh sách slide')), Tab(text: tr('Đang trình chiếu'))]),
        ),
        body: TabBarView(controller: _tabs, children: [
          _DeckList(client: client, onStarted: (pid) => _tabs.animateTo(1)),
          _LiveList(key: _liveKey, client: client),
        ]),
      );
}

/// Thời điểm (chuỗi ISO hoặc mili giây) theo giờ máy: hôm nay chỉ hiện giờ.
String _when(Object? v) {
  final t = (v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : DateTime.tryParse('$v'))?.toLocal();
  if (t == null) return '';
  final n = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return t.year == n.year && t.month == n.month && t.day == n.day ? hm : '${t.day}/${t.month}/${t.year} $hm';
}

/// Danh sách có tải lại bằng kéo xuống: [load] trả về các mục; lỗi / trống hiện chữ giữa màn.
class _Loader extends StatefulWidget {
  final Future<List<Map<String, dynamic>>> Function() load;
  final Widget Function(BuildContext, Map<String, dynamic>) item;
  final String empty;
  const _Loader({super.key, required this.load, required this.item, required this.empty});
  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  List<Map<String, dynamic>>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final l = await widget.load();
      if (mounted) {
        setState(() {
          _items = l;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget center(String t) => ListView(children: [
          Padding(padding: const EdgeInsets.fromLTRB(32, 80, 32, 0), child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: pal.sub))),
        ]);
    final items = _items;
    return RefreshIndicator(
      onRefresh: reload,
      child: _error != null && items == null
          ? center(_error!)
          : items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? center(widget.empty)
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => Divider(height: 1, indent: 72, color: pal.divider),
                      itemBuilder: (ctx, i) => widget.item(ctx, items[i]),
                    ),
    );
  }
}

class _DeckList extends StatelessWidget {
  final ShowClient client;
  final void Function(String pid) onStarted;
  const _DeckList({required this.client, required this.onStarted});

  @override
  Widget build(BuildContext context) => _Loader(
        load: () async => [for (final d in (await client.call('deck_list', {'limit': 100}))['decks'] as List? ?? const []) (d as Map).cast<String, dynamic>()],
        empty: tr('Chưa có bài trình chiếu. Nhắn trợ lý AI để tạo'),
        item: (ctx, d) => ListTile(
          leading: CircleAvatar(child: Text('${d['slides'] ?? 0}')),
          title: Text('${d['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(tr('{0} trang · {1} · {2}', ['${d['slides'] ?? 0}', '${d['owner_name'] ?? ''}', _when(d['updated_at'])]),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () async {
            final pid = await Navigator.of(ctx).push<String>(
                MaterialPageRoute(builder: (_) => DeckDetailPage(client: client, deckId: '${d['id']}', title: '${d['title'] ?? ''}')));
            if (pid != null) onStarted(pid);
          },
        ),
      );
}

class _LiveList extends StatefulWidget {
  final ShowClient client;
  const _LiveList({super.key, required this.client});
  @override
  State<_LiveList> createState() => _LiveListState();
}

class _LiveListState extends State<_LiveList> {
  final _loader = GlobalKey<_LoaderState>();
  void reload() => _loader.currentState?.reload();

  @override
  Widget build(BuildContext context) => _Loader(
        key: _loader,
        load: () async =>
            [for (final p in (await widget.client.call('show_list'))['presentations'] as List? ?? const []) (p as Map).cast<String, dynamic>()],
        empty: tr('Chưa có buổi trình chiếu nào đang chạy'),
        item: (ctx, p) => ListTile(
          leading: const _LiveDot(),
          title: Text('${p['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              tr('Trang {0}/{1} · {2} màn hình · {3}', ['${p['slide'] ?? 1}', '${p['total'] ?? 0}', '${p['screens'] ?? 0}', '${p['presenter_name'] ?? ''}']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          onTap: () async {
            await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ShowControlPage(client: widget.client, pid: '${p['presentation_id']}')));
            reload();
          },
        ),
      );
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: const Color(0xFFE53935), borderRadius: BorderRadius.circular(6)),
        child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}

/// Khung xem trước 16:9 của bộ slide: webview trang render, lật bằng flygoGo; không nhận chạm, không điều hướng.
/// Máy không có webview: tiêu đề + chữ của trang.
class SlidePreview extends StatefulWidget {
  final ShowClient client;
  final String deckId;
  /// slide bắt đầu từ 1.
  final int slide, step;
  /// Chỉ số 0-based truyền cho flygoGo (gồm cả trang hệ thống: màn chờ = n, Hỏi & Đáp = n+1, kết thúc = n+2);
  /// null = slide - 1.
  final int? frame;
  /// Buổi đang chiếu (màn chờ hiện người trình bày + QR link khách).
  final String? pid;
  /// Ngôn ngữ hiển thị (bản dịch của bộ slide); null = ngôn ngữ gốc.
  final String? lang;
  final bool animate;
  final String fallbackTitle, fallbackText;
  const SlidePreview(
      {super.key,
      required this.client,
      required this.deckId,
      required this.slide,
      this.step = 0,
      this.frame,
      this.pid,
      this.lang,
      this.animate = true,
      this.fallbackTitle = '',
      this.fallbackText = ''});
  @override
  State<SlidePreview> createState() => _SlidePreviewState();
}

class _SlidePreviewState extends State<SlidePreview> {
  WebViewController? _web;
  bool _ready = false;
  Uri? _url;

  @override
  void initState() {
    super.initState();
    if (_webPreview) _open();
  }

  Future<void> _open() async {
    try {
      _url = await widget.client.renderUrl(widget.deckId, pid: widget.pid, lang: widget.lang);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) => r.url == _url.toString() ? NavigationDecision.navigate : NavigationDecision.prevent,
        onPageFinished: (_) {
          _ready = true;
          _go(false);
        },
      ))
      ..loadRequest(_url!);
    setState(() => _web = web);
  }

  void _go(bool live) {
    if (_ready) _web?.runJavaScript('window.flygoGo && flygoGo(${widget.frame ?? widget.slide - 1}, ${widget.step}, ${live && widget.animate})');
  }

  @override
  void didUpdateWidget(SlidePreview old) {
    super.didUpdateWidget(old);
    if (old.slide != widget.slide || old.step != widget.step || old.frame != widget.frame) _go(true);
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: const Color(0xFF05070D),
          child: web != null
              ? IgnorePointer(child: WebViewWidget(controller: web))
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(widget.fallbackTitle,
                        textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Flexible(
                        child: Text(widget.fallbackText,
                            textAlign: TextAlign.center, overflow: TextOverflow.fade, style: const TextStyle(color: Colors.white70, fontSize: 13))),
                  ]),
                ),
        ),
      ),
    );
  }
}

/// Chi tiết một bộ slide: xem trước, danh sách trang, Xem trước toàn màn hình, gợi ý sửa bằng AI, Trình chiếu.
/// Bắt đầu trình chiếu: thay trang này bằng màn điều khiển, pop trả presentation_id cho danh sách.
class DeckDetailPage extends StatefulWidget {
  final ShowClient client;
  final String deckId, title;
  const DeckDetailPage({super.key, required this.client, required this.deckId, required this.title});
  @override
  State<DeckDetailPage> createState() => _DeckDetailPageState();
}

class _DeckDetailPageState extends State<DeckDetailPage> {
  Map<String, dynamic>? _deck;
  String? _error;
  int _slide = 1;

  List<Map<String, dynamic>> get _slides => [for (final s in (_deck?['slides'] as List? ?? const [])) (s as Map).cast<String, dynamic>()];

  @override
  void initState() {
    super.initState();
    widget.client.call('deck_get', {'deck_id': widget.deckId}).then((d) {
      if (mounted) setState(() => _deck = d);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = _err(e));
    });
  }

  /// Mở buổi mới: ở màn chờ, hoặc vào thẳng trang đang chọn nếu không phải trang 1.
  Future<String> _open() async =>
      '${(await widget.client.call('show_start', {'deck_id': widget.deckId, if (_slide > 1) 'start_slide': _slide}))['presentation_id']}';

  /// Trình chiếu: ghép màn hình (quét QR / nhập mã trên TV) rồi mở buổi, hoặc chỉ điều khiển → sang màn điều khiển.
  Future<void> _start() async {
    final host = Uri.parse(widget.client.base).host;
    final pid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(sheet).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Kết nối màn hình'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(tr('Mở {0}/tv trên TV hoặc máy chiếu, rồi quét mã QR hoặc nhập mã 8 ký tự hiện trên màn hình.', [host]),
              style: TextStyle(color: Pal.of(sheet).sub)),
          const SizedBox(height: 14),
          _PairBox(onCode: (code) async {
            final pid = await _open();
            try {
              await widget.client.call('screen_pair', {'presentation_id': pid, 'code': code});
            } catch (_) {
              // Ghép hỏng: bỏ buổi vừa mở, không để buổi trống chạy.
              unawaited(widget.client.call('show_stop', {'presentation_id': pid}).catchError((_) => <String, dynamic>{}));
              rethrow;
            }
            if (sheet.mounted) {
              _toast(sheet, tr('Đã kết nối màn hình'));
              Navigator.pop(sheet, pid);
            }
          }),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () async {
              try {
                final pid = await _open();
                if (sheet.mounted) Navigator.pop(sheet, pid);
              } catch (e) {
                if (sheet.mounted) _toast(sheet, _err(e));
              }
            },
            child: Text(tr('Chỉ điều khiển, không ghép màn hình')),
          ),
        ]),
      ),
    );
    if (pid == null || !mounted) return;
    final nav = Navigator.of(context);
    nav.pop(pid);
    nav.push(MaterialPageRoute(builder: (_) => ShowControlPage(client: widget.client, pid: pid)));
  }

  void _editHint() {
    final sample = tr('Sửa bộ slide «{0}»: ', ['${_deck?['title'] ?? widget.title}']);
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.auto_awesome_rounded, size: 34),
        title: Text(tr('Sửa bằng AI')),
        content: Text(tr('Muốn sửa? Nhắn trợ lý AI:\n\n"{0}…"', [sample])),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: sample));
                Navigator.pop(d);
                _toast(context, tr('Đã chép câu mẫu'));
              },
              child: Text(tr('Chép câu mẫu'))),
          FilledButton(onPressed: () => Navigator.pop(d), child: Text(tr('Đã hiểu'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final deck = _deck;
    final slides = _slides;
    final langs = [for (final l in (deck?['languages'] as List? ?? const [])) '$l'];
    final cur = slides.isEmpty ? null : slides[(_slide - 1).clamp(0, slides.length - 1)];
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text('${deck?['title'] ?? widget.title}'), actions: [
        if (langs.length > 1)
          Tooltip(
            message: langs.map(langName).join(', '),
            child: Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(12)),
              child: Text(tr('🌐 {0} ngôn ngữ', ['${langs.length}']), style: TextStyle(fontSize: 13, color: pal.text)),
            ),
          ),
      ]),
      body: deck == null
          ? Center(child: _error != null ? Text(_error!, style: TextStyle(color: pal.sub)) : const CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SlidePreview(
                  key: ValueKey(deck['rev']),
                  client: widget.client,
                  deckId: widget.deckId,
                  slide: _slide,
                  animate: false,
                  fallbackTitle: '${cur?['title'] ?? ''}',
                  fallbackText: '${cur?['text'] ?? ''}',
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.fullscreen_rounded),
                    label: Text(tr('Xem trước')),
                    onPressed: slides.isEmpty
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => DeckFullPreview(client: widget.client, deckId: widget.deckId, slides: slides, start: _slide))),
                  ),
                  OutlinedButton.icon(icon: const Icon(Icons.auto_awesome_rounded), label: Text(tr('Sửa bằng AI')), onPressed: _editHint),
                  if (widget.client.can('present'))
                    FilledButton.icon(
                      icon: const Icon(Icons.slideshow_rounded),
                      label: Text(tr('Trình chiếu')),
                      onPressed: slides.isEmpty ? null : _start,
                    ),
                ]),
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: pal.divider),
              Expanded(
                child: ListView.builder(
                  itemCount: slides.length,
                  itemBuilder: (_, i) {
                    final s = slides[i];
                    final notes = '${s['summary'] ?? s['notes'] ?? ''}'.trim();
                    return ListTile(
                      selected: i + 1 == _slide,
                      leading: CircleAvatar(radius: 16, child: Text('${i + 1}', style: const TextStyle(fontSize: 13))),
                      title: Text('${s['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: notes.isEmpty ? null : Text(notes, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => setState(() => _slide = i + 1),
                    );
                  },
                ),
              ),
            ]),
    );
  }
}

/// Xem trước toàn màn hình: lật ◀ / ▶ tại chỗ (chỉ gọi flygoGo, không tạo buổi trình chiếu).
class DeckFullPreview extends StatefulWidget {
  final ShowClient client;
  final String deckId;
  final List<Map<String, dynamic>> slides;
  final int start;
  const DeckFullPreview({super.key, required this.client, required this.deckId, required this.slides, required this.start});
  @override
  State<DeckFullPreview> createState() => _DeckFullPreviewState();
}

class _DeckFullPreviewState extends State<DeckFullPreview> {
  late int _slide = widget.start;
  int _step = 0;

  int _steps(int slide) => ((widget.slides[slide - 1]['steps'] as num?)?.toInt() ?? 0);

  void _next() => setState(() {
        if (_step < _steps(_slide)) {
          _step++;
        } else if (_slide < widget.slides.length) {
          _slide++;
          _step = 0;
        }
      });

  void _prev() => setState(() {
        if (_step > 0) {
          _step--;
        } else if (_slide > 1) {
          _slide--;
          _step = _steps(_slide);
        }
      });

  @override
  Widget build(BuildContext context) {
    final s = widget.slides[_slide - 1];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('$_slide / ${widget.slides.length}'),
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
          const SingleActivator(LogicalKeyboardKey.space): _next,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
        },
        child: Focus(
          autofocus: true,
          child: Column(children: [
            Expanded(
              child: Center(
                child: SlidePreview(
                  client: widget.client,
                  deckId: widget.deckId,
                  slide: _slide,
                  step: _step,
                  fallbackTitle: '${s['title'] ?? ''}',
                  fallbackText: '${s['text'] ?? ''}',
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(child: _BigButton(icon: Icons.chevron_left_rounded, label: '', onTap: _prev)),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _BigButton(icon: Icons.chevron_right_rounded, label: tr('Tới'), onTap: _next, primary: true)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  const _BigButton({required this.icon, required this.label, required this.onTap, this.primary = false});
  @override
  Widget build(BuildContext context) {
    final child = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      if (label.isNotEmpty) Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      Icon(icon, size: 34),
    ]);
    final style = ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size.fromHeight(64)));
    return primary ? FilledButton(style: style, onPressed: onTap, child: child) : OutlinedButton(style: style, onPressed: onTap, child: child);
  }
}

/// Màn điều khiển một buổi trình chiếu, đồng bộ realtime. Từ trên xuống: khung xem trực tiếp; hàng 6 nút (tự chạy,
/// nhạc, trước, tiếp, màn chờ, AI); dòng trạng thái; danh sách trang (cả màn chờ / Hỏi & Đáp / kết thúc, bấm là chuyển);
/// phần thu gọn: ghép màn hình, tự động, âm thanh, tài liệu và câu hỏi cho AI, link khách, kết thúc. Máy này phát nhạc +
/// giọng đọc qua trang /audio trong WebView ẩn (mặc định khi chưa ghép màn hình). Trợ lý AI: cố định bên phải khi màn rộng,
/// bottom sheet trên điện thoại.
class ShowControlPage extends StatefulWidget {
  final ShowClient client;
  final String pid;
  const ShowControlPage({super.key, required this.client, required this.pid});
  @override
  State<ShowControlPage> createState() => _ShowControlPageState();
}

/// Một dòng trong khung trợ lý AI. Bản này chỉ có câu người dùng đưa lên màn chiếu; sau nối thêm tin của AI.
class ShowChatLine {
  final bool mine;
  final String text;
  final DateTime at;
  ShowChatLine(this.text, {this.mine = true}) : at = DateTime.now();
}

class _ShowControlPageState extends State<ShowControlPage> with SingleTickerProviderStateMixin {
  // Dưới khung xem: tab Nội dung (dàn ý + danh sách trang), Màn hình (ghép nối, từng màn hình kể cả máy này), AI.
  late final TabController _tabs = TabController(length: 4, vsync: this)..addListener(_onTab);
  // Bình luận của khách (link dành cho khách, nút 💬): chỉ hiện ở đây, không lên màn chiếu.
  List<Map<String, dynamic>>? _comments;
  String? _commentsError;
  int _commentsSeen = 0;
  /// Thứ tự chạy của bộ slide (server 0.5+): trang và mục "Chuyển tới slide X"; null = server cũ, dựng từ danh sách trang.
  List<Map<String, dynamic>>? _flow;
  /// Thanh âm lượng đang kéo (khoá: `id màn hình:music` / `:voice`, `here:…`).
  final Map<String, double> _drag = {};
  // Máy này: nhạc nền và giọng đọc bật / tắt và âm lượng riêng.
  bool _hereMusic = true, _hereVoice = true;
  double _hereMusicVol = 1, _hereVoiceVol = 1;
  ShowLive? _live;
  StreamSubscription? _sub;
  Map<String, dynamic>? _st;
  Map<String, dynamic>? _deck;
  String _notes = '';
  List<Map<String, dynamic>> _pages = [];
  List<Map<String, dynamic>> _screens = [];
  int _docs = 0, _openNotes = 0;
  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)>? _kb;
  double? _volDrag;
  final chat = ValueNotifier<List<ShowChatLine>>([]);
  // Máy phát tiếng trên máy này: trang /audio trong WebView ẩn (tự nối WebSocket, phát nhạc + giọng đọc, báo đọc xong
  // để tự chạy sang trang). Native chỉ bật / tắt và mở khoá tiếng.
  WebViewController? _audio;
  String? _audioToken;
  bool _audioReady = false, _audioBlocked = false;
  String _here = 'auto';
  /// Ngôn ngữ trên máy này: khung xem trước, giọng đọc (rỗng = ngôn ngữ gốc).
  String _hereSlide = '', _hereAudio = '';

  ShowClient get _c => widget.client;
  String get _pid => widget.pid;
  int get _slide => (_st?['slide'] is num ? (_st!['slide'] as num).toInt() : null) ?? 1;
  /// Server cũ (spec 0.1) không có scene: luôn là trang nội dung.
  String get _scene => '${_st?['scene'] ?? 'slide'}';
  int? get _frame => (_st?['frame'] as num?)?.toInt();
  List<Map<String, dynamic>> get _slides => [for (final s in (_deck?['slides'] as List? ?? const [])) (s as Map).cast<String, dynamic>()];

  @override
  void initState() {
    super.initState();
    _status();
    _live = _c.live(_pid);
    _sub = _live!.states.listen(_onState);
    _HerePrefs.load().then((m) {
      if (!mounted) return;
      setState(() {
        _here = m['here']!;
        _hereSlide = m['slide'] ?? '';
        _hereAudio = m['audio'] ?? '';
        _hereMusic = m['music'] != 'off';
        _hereVoice = m['voice'] != 'off';
        _hereMusicVol = (double.tryParse(m['music_volume'] ?? '') ?? 1).clamp(0.0, 1.0);
        _hereVoiceVol = (double.tryParse(m['voice_volume'] ?? '') ?? 1).clamp(0.0, 1.0);
      });
      _openAudio();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _live?.close();
    _tabs.dispose();
    chat.dispose();
    super.dispose();
  }

  /// Nạp (lại) trang /audio với token phiên hiện tại. Linux / Windows không có webview: không phát.
  Future<void> _openAudio() async {
    if (!_webPreview) return;
    final Uri url;
    try {
      url = await _c.audioUrl(_pid);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    _audioToken = _c.current;
    _audioReady = false;
    if (_audio == null) setState(() => _audio = _audioController());
    await _audio!.loadRequest(url);
  }

  WebViewController _audioController() {
    // Cho phát nhạc / giọng đọc không cần chạm vào trang.
    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(allowsInlineMediaPlayback: true, mediaTypesRequiringUserAction: const {})
        : const PlatformWebViewControllerCreationParams();
    final web = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FlygoAudioHost', onMessageReceived: (m) {
        try {
          final blocked = (jsonDecode(m.message) as Map)['blocked'] == true;
          if (mounted && blocked != _audioBlocked) setState(() => _audioBlocked = blocked);
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) => Uri.tryParse(r.url)?.path == '/audio' ? NavigationDecision.navigate : NavigationDecision.prevent,
        onPageFinished: (_) {
          _audioReady = true;
          _applyAudio();
        },
      ));
    final platform = web.platform;
    if (platform is AndroidWebViewController) platform.setMediaPlaybackRequiresUserGesture(false);
    return web;
  }

  /// Bật tiếng trên máy này theo lựa chọn: luôn bật, tắt, hoặc chỉ khi buổi chưa ghép màn hình nào (màn hình phát).
  bool get _hereOn => _here == 'on' || (_here == 'auto' && ((_st?['screen_count'] as num?)?.toInt() ?? 0) == 0);

  void _applyAudio() {
    if (!_audioReady) return;
    final on = _hereOn;
    final mix = jsonEncode({'music': _hereMusic, 'voice': _hereVoice, 'music_volume': _hereMusicVol, 'voice_volume': _hereVoiceVol});
    _audio?.runJavaScript('window.flygoAudioLang && flygoAudioLang(${jsonEncode(_okLang(_hereAudio))});'
        'window.flygoAudioMix && flygoAudioMix($mix);'
        'window.flygoAudioEnable && flygoAudioEnable($on)');
    if (!on && _audioBlocked) setState(() => _audioBlocked = false);
  }

  Future<void> _setHere(String mode) async {
    setState(() => _here = mode);
    _applyAudio();
    await _HerePrefs.set('here', mode);
  }

  /// Ngôn ngữ của bộ slide (gốc đứng đầu); server cũ: chỉ ngôn ngữ gốc.
  List<String> get _languages {
    final l = [for (final x in (_st?['languages'] as List? ?? const [])) '$x'];
    return l.isNotEmpty ? l : ['${_st?['lang'] ?? 'vi'}'];
  }

  /// [l] nếu bộ slide có bản dịch đó, không thì ngôn ngữ gốc.
  String _okLang(String l) => _languages.contains(l) ? l : _languages.first;

  Future<void> _setHereLang({String? slide, String? audio}) async {
    setState(() {
      _hereSlide = slide ?? _hereSlide;
      _hereAudio = audio ?? _hereAudio;
    });
    if (audio != null) _applyAudio();
    if (slide != null) await _HerePrefs.set('slide', slide);
    if (audio != null) await _HerePrefs.set('audio', audio);
  }

  /// Trạng thái mới (WebSocket hoặc kết quả lời gọi): đổi trang thì tải ghi chú; bộ slide bị sửa thì tải lại bộ + trang.
  void _onState(Map<String, dynamic> st) {
    if (!mounted) return;
    if (st['ended'] == true || st['state'] == 'ended') {
      _toast(context, tr('Buổi trình chiếu đã kết thúc'));
      Navigator.of(context).maybePop();
      return;
    }
    final old = _st;
    setState(() => _st = {...?old, ...st});
    if (old == null || old['slide'] != st['slide'] || old['scene'] != st['scene'] || old['deck_rev'] != st['deck_rev']) _status();
    if (old?['screen_count'] != st['screen_count'] || jsonEncode(old?['languages']) != jsonEncode(st['languages'])) _applyAudio();
    if (st['comment_count'] != null && old?['comment_count'] != st['comment_count']) _loadComments();
    // Màn hình đổi: ghép / ngắt, tắt tiếng / hình, ngôn ngữ (TV tự đổi bằng ⚙️ cũng vậy).
    if (old != null &&
        (old['screen_count'] != st['screen_count'] ||
            jsonEncode(old['screen_flags']) != jsonEncode(st['screen_flags']) ||
            jsonEncode(old['screen_prefs']) != jsonEncode(st['screen_prefs']))) {
      _loadScreens();
    }
    // Phiên được làm mới (token cũ hết hạn): trang /audio nối lại bằng token mới.
    if (_audio != null && _audioToken != null && _c.current != null && _c.current != _audioToken) _openAudio();
    if (_deck == null || (st['deck_rev'] != null && _deck!['rev'] != st['deck_rev'])) _loadDeck('${st['deck_id'] ?? old?['deck_id'] ?? ''}');
  }

  Future<void> _loadDeck(String id) async {
    if (id.isEmpty) return;
    try {
      final d = await _c.call('deck_get', {'deck_id': id});
      if (mounted) {
        setState(() {
          _deck = d;
          if (d['flow'] is List) _flow = _maps(d['flow']);
        });
      }
    } catch (_) {}
  }

  Future<void> _status() async {
    try {
      final s = await _c.call('show_status', {'presentation_id': _pid});
      if (!mounted) return;
      setState(() {
        _notes = '${s['notes'] ?? ''}';
        _screens = [for (final x in (s['screens'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
        _pages = [for (final x in (s['pages'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
        _docs = (s['docs'] as num?)?.toInt() ?? 0;
        _openNotes = (s['open_notes'] as num?)?.toInt() ?? 0;
        if (s['flow'] is List) _flow = _maps(s['flow']);
      });
      final st = Map<String, dynamic>.from(s)
        ..remove('notes')
        ..remove('screens')
        ..remove('pages')
        ..remove('docs')
        ..remove('open_notes')
        ..remove('flow');
      if (_st == null) _onState(st);
    } catch (e) {
      if (mounted && _st == null) _toast(context, _err(e));
    }
  }

  /// Trang để vẽ: pages của server; server cũ không có thì dựng từ các trang của bộ slide.
  List<Map<String, dynamic>> get _pageList => _pages.isNotEmpty
      ? _pages
      : [
          for (final (i, s) in _slides.indexed)
            {'scene': 'slide', 'slide': i + 1, 'title': s['title'], 'summary': s['summary'] ?? s['text'], 'steps': s['steps']},
        ];

  bool _isCurrent(Map<String, dynamic> p) => p['scene'] == _scene && (_scene != 'slide' || (p['slide'] as num?)?.toInt() == _slide);

  /// Gọi tool điều khiển; kết quả là trạng thái thì cập nhật ngay (không chờ WebSocket).
  Future<Map<String, dynamic>?> _do(String tool, [Map<String, dynamic> extra = const {}]) async {
    try {
      final r = await _c.call(tool, {'presentation_id': _pid, ...extra});
      if (r['type'] == 'state' || r['slide'] is num) _onState(r);
      return r;
    } catch (e) {
      if (mounted) _toast(context, _err(e));
      return null;
    }
  }

  /// Màn hình đã ghép (kèm tắt tiếng / tắt hình của từng cái).
  Future<void> _loadScreens() async {
    try {
      final r = await _c.call('screen_list', {'presentation_id': _pid});
      if (mounted) setState(() => _screens = [for (final x in (r['screens'] as List? ?? const [])) (x as Map).cast<String, dynamic>()]);
    } catch (_) {}
  }

  /// Tắt / bật tiếng hoặc hình của riêng màn hình [id] (TV tự làm; màn đen nhưng vẫn ghép).
  Future<void> _screenSet(String id, Map<String, dynamic> flag) async {
    // Gọi thẳng, không qua _do: kết quả có khoá slide / audio / sub là mã ngôn ngữ của màn hình, không phải trạng thái buổi.
    Map<String, dynamic> r;
    try {
      r = await _c.call('screen_set', {'presentation_id': _pid, 'screen_id': id, ...flag});
    } catch (e) {
      if (mounted) _toast(context, _err(e));
      return;
    }
    if (!mounted) return;
    setState(() => _screens = [for (final x in _screens) x['screen_id'] == id ? {...x, ...r} : x]);
  }

  /// Ghép thêm màn hình (TV mở trang /tv) bằng mã 8 ký tự; lỗi ném ra cho _PairBox hiện.
  Future<void> _pair(String code) async {
    final r = await _c.call('screen_pair', {'presentation_id': _pid, 'code': code});
    if (!mounted) return;
    _toast(context, tr('Đã kết nối {0}', ['${r['name'] ?? ''}']));
    _status();
  }

  /// Tài liệu AI đọc được và câu hỏi / vấn đề / việc đã ghi của buổi (AI thêm và trả lời; ở đây chỉ xem).
  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)> _loadKb() async {
    final r = await Future.wait([
      _c.call('doc_list', {'presentation_id': _pid}),
      _c.call('note_list', {'presentation_id': _pid, 'status': 'all', 'limit': 50}),
    ]);
    List<Map<String, dynamic>> of(Object? l) => [for (final x in (l as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    return (of(r[0]['docs']), of(r[1]['notes']));
  }

  /// Đưa [text] lên màn chiếu (phụ đề + đọc to); chuỗi rỗng = xoá phụ đề.
  Future<bool> say(String text) async {
    if (text.isNotEmpty && !await context.read<AppState>().ensureAiConsent()) return false;
    final ok = await _do('show_say', {'text': text}) != null;
    if (ok && text.isNotEmpty) chat.value = [...chat.value, ShowChatLine(text)];
    return ok;
  }

  Future<void> _guestLink() async {
    final r = await _do('show_link', {'minutes': 120});
    final url = '${r?['url'] ?? ''}';
    if (url.isEmpty || !mounted) return;
    await SharePlus.instance.share(ShareParams(text: url, subject: '${_st?['title'] ?? ''}'));
  }

  Future<void> _stop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Kết thúc trình chiếu?')),
        content: Text(tr('Màn hình đã ghép và link cho khách sẽ ngắt.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
              onPressed: () => Navigator.pop(d, true),
              child: Text(tr('Kết thúc'))),
        ],
      ),
    );
    if (ok != true) return;
    if (await _do('show_stop') != null && mounted) Navigator.of(context).maybePop();
  }

  Map get _autopilot => (_st?['autopilot'] as Map?) ?? const {};
  Map get _music => (_st?['music'] as Map?) ?? const {};

  /// Hàng 6 nút bằng nhau ngay dưới khung xem.
  Widget _buttons(Pal pal) {
    final running = _autopilot['running'] == true, paused = _autopilot['paused'] == true;
    final musicOn = _music['on'] == true;
    Widget b(IconData icon, String label, VoidCallback? onTap, {bool primary = false, bool active = false}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Material(
              color: primary ? pal.accent : (active ? pal.accent.withValues(alpha: .16) : pal.surface2),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 24, color: primary ? Colors.white : (onTap == null ? pal.sub.withValues(alpha: .4) : pal.text)),
                    const SizedBox(height: 2),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: primary ? Colors.white : pal.sub, fontWeight: primary ? FontWeight.w700 : null)),
                  ]),
                ),
              ),
            ),
          ),
        );
    return Row(children: [
      running
          ? (paused
              ? b(Icons.play_arrow_rounded, tr('Tiếp tục'), () => _do('show_autopilot', {'action': 'resume'}), active: true)
              : b(Icons.pause_rounded, tr('Tạm dừng'), () => _do('show_autopilot', {'action': 'pause'}), active: true))
          // Tự chạy: AI dẫn buổi trình chiếu theo lời đọc, cần đồng ý gửi dữ liệu cho AI trước.
          : b(Icons.play_circle_outline_rounded, tr('Tự chạy'), () async {
              if (await context.read<AppState>().ensureAiConsent()) _do('show_autopilot', {'action': 'start'});
            }),
      b(musicOn ? Icons.music_note_rounded : Icons.music_off_rounded, tr('Nhạc'), () => _do('show_music', {'on': !musicOn}), active: musicOn),
      b(Icons.chevron_left_rounded, tr('Trước'), () => _do('show_prev')),
      b(Icons.chevron_right_rounded, tr('Tiếp'), () => _do('show_next'), primary: true),
      b(Icons.skip_previous_rounded, tr('Màn chờ'), _scene == 'waiting' ? null : () => _do('show_goto', {'scene': 'waiting'})),
      b(Icons.auto_awesome_rounded, tr('AI'), () => _tabs.animateTo(3), active: _tabs.index == 3),
    ]);
  }

  String _sceneName(String scene) => switch (scene) {
        'waiting' => tr('Màn chờ'),
        'qa' => tr('Hỏi & Đáp'),
        'end' => tr('Kết thúc'),
        _ => '',
      };

  Widget _statusLine(Pal pal, int total) {
    final step = (_st?['step'] as num?)?.toInt() ?? 0, steps = (_st?['steps'] as num?)?.toInt() ?? 0;
    final parts = [
      if (_scene != 'slide') _sceneName(_scene)
      else if (steps > 0) tr('Trang {0}/{1} · bước {2}/{3}', ['$_slide', '$total', '$step', '$steps'])
      else tr('Trang {0}/{1}', ['$_slide', '$total']),
      if (_autopilot['running'] == true)
        _autopilot['paused'] == true ? tr('tự động đang tạm dừng: bấm Tiếp tục') : tr('đang tự động theo lời đọc'),
    ];
    final caption = '${_st?['caption'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Column(children: [
        Text(parts.join(' · '), textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 13)),
        if (caption.isNotEmpty)
          Text('“$caption”', maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontStyle: FontStyle.italic, fontSize: 13)),
        if (_audioBlocked)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.tonal(
              onPressed: () => _audio?.runJavaScript('window.flygoAudioUnlock && flygoAudioUnlock()'),
              child: Text(tr('🔈 Chạm để bật tiếng trên máy này')),
            ),
          ),
      ]),
    );
  }

  Widget _pageTile(Pal pal, Map<String, dynamic> p) {
    final cur = _isCurrent(p);
    final scene = '${p['scene'] ?? 'slide'}';
    final summary = '${p['summary'] ?? ''}'.trim();
    final lead = switch (scene) {
      'waiting' => const Icon(Icons.hourglass_top_rounded, size: 18),
      'qa' => const Icon(Icons.help_outline_rounded, size: 18),
      'end' => const Icon(Icons.stop_rounded, size: 18),
      _ => Text('${p['slide'] ?? ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
    };
    return Material(
      color: cur ? pal.accent.withValues(alpha: .12) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: cur ? null : () => _do('show_goto', scene == 'slide' ? {'slide': p['slide'], 'step': 0} : {'scene': scene}),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 14, backgroundColor: cur ? pal.accent : pal.surface2, foregroundColor: cur ? Colors.white : pal.text, child: lead),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: pal.text)),
                if (summary.isNotEmpty)
                  Text(summary, maxLines: cur ? null : 2, overflow: cur ? null : TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
                if (cur && _notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(tr('Ghi chú người nói'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pal.sub)),
                  Text(_notes, style: TextStyle(fontSize: 14, color: pal.text)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  int get _commentCount => (_st?['comment_count'] as num?)?.toInt() ?? (_comments?.length ?? 0);
  int get _commentsUnread => _tabs.index == 2 ? 0 : (_commentCount - _commentsSeen).clamp(0, 999);

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    if (_tabs.index == 2) {
      if (_comments == null) _loadComments();
      _commentsSeen = _commentCount;
    }
    setState(() {});
  }

  Future<void> _loadComments() async {
    try {
      final r = await _c.call('comment_list', {'presentation_id': _pid, 'limit': 200});
      final list = _maps(r['comments']);
      list.sort((a, b) => ((a['at'] as num?) ?? 0).compareTo((b['at'] as num?) ?? 0));
      if (!mounted) return;
      setState(() {
        _comments = list;
        _commentsError = null;
        if (_tabs.index == 2) _commentsSeen = _commentCount;
      });
    } catch (e) {
      if (mounted) setState(() => _commentsError = _err(e));
    }
  }

  Future<void> _deleteComment(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Xoá bình luận này?')),
        content: Text('${c['name'] ?? ''}: ${c['text'] ?? ''}', maxLines: 4, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Xoá'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _c.call('comment_delete', {'presentation_id': _pid, 'comment_id': c['id']});
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
    _loadComments();
  }

  /// Tab Bình luận: bình luận của khách theo thời gian (mới nhất ở dưới), bấm giữ để xoá; chỉ người điều khiển thấy.
  Widget _commentsTab(Pal pal) {
    final list = _comments;
    if (list == null) {
      return _commentsError == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_commentsError!, textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
                  TextButton(onPressed: _loadComments, child: Text(tr('Thử lại'))),
                ]),
              ),
            );
    }
    return RefreshIndicator(
      onRefresh: _loadComments,
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 12),
            child: Column(children: [
              Icon(Icons.forum_outlined, size: 40, color: pal.sub),
              const SizedBox(height: 10),
              Text(tr('Chưa có bình luận. Khách mở link dành cho khách và bấm 💬 ở góc dưới để bình luận.'),
                  textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
              const SizedBox(height: 8),
              TextButton.icon(icon: const Icon(Icons.link_rounded), label: Text(tr('Link cho khách')), onPressed: _guestLink),
            ]),
          ),
        for (final c in list)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onLongPress: () => _deleteComment(c),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: pal.accent.withValues(alpha: .15),
                  foregroundColor: pal.accent,
                  child: Text('${c['name'] ?? '?'}'.trim().isEmpty ? '?' : '${c['name']}'.trim().characters.first.toUpperCase()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text('${c['name'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: pal.text)),
                      ),
                      const SizedBox(width: 8),
                      Text(_when(c['at']), style: TextStyle(fontSize: 12, color: pal.sub)),
                    ]),
                    const SizedBox(height: 2),
                    SelectableText('${c['text'] ?? ''}', style: TextStyle(fontSize: 14.5, color: pal.text)),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    );
  }

  String get _deckId => '${_deck?['id'] ?? _st?['deck_id'] ?? ''}';

  /// Thứ tự chạy: của server (trang + mục nhảy), server cũ thì chỉ các trang nội dung theo số trang.
  List<Map<String, dynamic>> get _flowItems =>
      _flow ??
      [
        for (final p in _pageList)
          if ('${p['scene'] ?? 'slide'}' == 'slide') {'type': 'slide', 'slide': p['slide'], 'title': p['title'], 'hidden': false},
      ];

  /// Gọi tool sửa bộ slide (đổi thứ tự, ẩn trang, mục nhảy) rồi tải lại bộ + trạng thái; lỗi thì tải lại để bỏ thay đổi tạm.
  Future<void> _deckCall(String tool, Map<String, dynamic> args) async {
    try {
      await _c.call(tool, {'deck_id': _deckId, ...args});
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
    await _loadDeck(_deckId);
    await _status();
  }

  /// Kéo thả trong danh sách: trang → slide_move tới số trang mới; mục nhảy → đặt sau trang ngay phía trên (0 = đầu).
  void _onReorder(int from, int to) {
    final list = [..._flowItems];
    if (from == to) return;
    final item = list.removeAt(from);
    list.insert(to, item);
    setState(() => _flow = list);
    if (item['type'] == 'jump') {
      var after = 0;
      for (var i = to - 1; i >= 0; i--) {
        if (list[i]['type'] == 'slide') {
          after = (list[i]['slide'] as num).toInt();
          break;
        }
      }
      _deckCall('deck_jump', {'action': 'update', 'jump_id': item['jump_id'], 'after': after, 'to': item['to']});
    } else {
      final target = list.take(to + 1).where((x) => x['type'] == 'slide').length;
      _deckCall('slide_move', {'slide': item['slide'], 'to': target});
    }
  }

  /// Một trang trong danh sách: nút 👁 ẩn / hiện (trang ẩn bị bỏ qua khi chuyển trang và tự chạy), bấm để chiếu.
  Widget _slideRow(Pal pal, Map<String, dynamic> f, Map<int, Map<String, dynamic>> pages) {
    final n = (f['slide'] as num?)?.toInt() ?? 0;
    final hidden = f['hidden'] == true;
    final page = pages[n] ?? {'scene': 'slide', 'slide': n, 'title': f['title']};
    return Row(children: [
      IconButton(
        tooltip: hidden ? tr('Hiện trang này') : tr('Tạm ẩn trang này'),
        icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, color: hidden ? pal.sub : pal.text),
        onPressed: () {
          setState(() => _flow = [for (final x in _flowItems) identical(x, f) ? {...x, 'hidden': !hidden} : x]);
          _deckCall('slide_update', {'slide': n, 'hidden': !hidden});
        },
      ),
      Expanded(child: Opacity(opacity: hidden ? .45 : 1, child: _pageTile(pal, page))),
    ]);
  }

  /// Mục "Chuyển tới slide X": chạy tới đây thì nhảy về trang X (lặp lại cho hội chợ); kéo thả được như trang.
  Widget _jumpRow(Pal pal, Map<String, dynamic> f) {
    final slides = _flowItems.where((x) => x['type'] == 'slide').toList();
    final to = (f['to'] as num?)?.toInt() ?? 1;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: pal.accent.withValues(alpha: .07),
        border: Border.all(color: pal.accent.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(Icons.redo_rounded, size: 20, color: pal.accent),
        const SizedBox(width: 10),
        Text(tr('Chuyển tới slide'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<int>(
            value: slides.any((x) => (x['slide'] as num?)?.toInt() == to) ? to : null,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            hint: Text('$to'),
            items: [
              for (final x in slides)
                DropdownMenuItem(
                  value: (x['slide'] as num).toInt(),
                  child: Text('${x['slide']}. ${x['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v == null || v == to) return;
              setState(() => _flow = [for (final x in _flowItems) identical(x, f) ? {...x, 'to': v} : x]);
              _deckCall('deck_jump', {'action': 'update', 'jump_id': f['jump_id'], 'to': v});
            },
          ),
        ),
        IconButton(
          tooltip: tr('Bỏ mục này'),
          icon: Icon(Icons.close_rounded, size: 20, color: pal.sub),
          onPressed: () {
            setState(() => _flow = [for (final x in _flowItems) if (!identical(x, f)) x]);
            _deckCall('deck_jump', {'action': 'delete', 'jump_id': f['jump_id']});
          },
        ),
      ]),
    );
  }

  /// Tab Nội dung: màn chờ, các trang theo thứ tự chạy (bấm giữ để kéo đổi chỗ), Hỏi & Đáp / Kết thúc, "Nhảy và lặp",
  /// rồi tự động trình chiếu, tài liệu cho AI, link khách, kết thúc buổi.
  Widget _contentTab(Pal pal) {
    final pages = {
      for (final p in _pageList)
        if ('${p['scene'] ?? 'slide'}' == 'slide' && p['slide'] != null) (p['slide'] as num).toInt(): p,
    };
    final system = [for (final p in _pageList) if ('${p['scene'] ?? 'slide'}' != 'slide') p];
    final flow = _flowItems;
    final canJump = _flow != null;
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
          child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.sub)),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
      for (final p in system.where((p) => p['scene'] == 'waiting')) _pageTile(pal, p),
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: flow.length,
        onReorderItem: _onReorder,
        proxyDecorator: (child, _, _) => Material(elevation: 4, color: pal.bg, borderRadius: BorderRadius.circular(12), child: child),
        itemBuilder: (_, i) {
          final f = flow[i];
          final key = f['type'] == 'jump' ? 'j:${f['jump_id']}' : 's:${f['id'] ?? f['slide']}';
          return ReorderableDelayedDragStartListener(
            key: ValueKey(key),
            index: i,
            child: f['type'] == 'jump' ? _jumpRow(pal, f) : _slideRow(pal, f, pages),
          );
        },
      ),
      for (final p in system.where((p) => p['scene'] != 'waiting')) _pageTile(pal, p),
      if (canJump)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.repeat_rounded),
            label: Text(tr('Nhảy và lặp')),
            onPressed: () => _deckCall('deck_jump', {'action': 'add', 'to': 1}),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: Text(tr('Bấm giữ một dòng để kéo đổi thứ tự. "Nhảy và lặp" thêm mục chuyển tới một trang khi chạy tới đó, hợp để chiếu lặp ở hội chợ.'),
            style: TextStyle(fontSize: 12.5, color: pal.sub)),
      ),
      head(tr('Tự động trình chiếu')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(tr('Màn hình đọc ghi chú người nói của từng trang, đọc xong mới sang trang sau. Bấm chuyển trang thì tự động tạm dừng.'),
            style: TextStyle(fontSize: 13, color: pal.sub)),
      ),
      if (_autopilot['running'] == true)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
              icon: const Icon(Icons.stop_rounded), label: Text(tr('Dừng tự động')), onPressed: () => _do('show_autopilot', {'action': 'stop'})),
        ),
      ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        onExpansionChanged: (open) {
          if (open) setState(() => _kb = _loadKb());
        },
        title: Text(tr('Tài liệu cho AI và câu hỏi đã ghi'), style: TextStyle(fontSize: 14, color: pal.text)),
        subtitle: _docs + _openNotes == 0
            ? null
            : Text(tr('{0} tài liệu · {1} câu hỏi chưa xong', ['$_docs', '$_openNotes']), style: TextStyle(fontSize: 12, color: pal.sub)),
        children: [_kbView(pal)],
      ),
      const Divider(height: 16),
      ListTile(leading: const Icon(Icons.link_rounded), title: Text(tr('Link cho khách')), onTap: _guestLink),
      ListTile(
        leading: const Icon(Icons.stop_circle_outlined, color: Color(0xFFE53935)),
        title: Text(tr('Kết thúc buổi'), style: const TextStyle(color: Color(0xFFE53935))),
        onTap: _stop,
      ),
    ]);
  }

  /// Bật / tắt và âm lượng của một nguồn tiếng (nhạc nền hoặc giọng đọc); [key] để giữ vị trí thanh khi đang kéo.
  Widget _mixRow(Pal pal, String key, IconData icon, String label, bool on, double vol, ValueChanged<bool> setOn, ValueChanged<double> setVol) =>
      Row(children: [
        IconButton(
          tooltip: on ? tr('Tắt') : tr('Bật'),
          icon: Icon(on ? icon : Icons.volume_off_rounded, color: on ? pal.accent : pal.sub),
          onPressed: () => setOn(!on),
        ),
        SizedBox(width: 92, child: Text(label, style: TextStyle(fontSize: 14, color: on ? pal.text : pal.sub))),
        Expanded(
          child: Slider(
            value: (_drag[key] ?? vol).clamp(0.0, 1.0),
            onChanged: on ? (v) => setState(() => _drag[key] = v) : null,
            onChangeEnd: (v) {
              setState(() => _drag.remove(key));
              setVol(double.parse(v.toStringAsFixed(2)));
            },
          ),
        ),
      ]);

  /// Một dòng bật / tắt riêng (phụ đề, cho chỉnh ngôn ngữ trên màn hình).
  Widget _switchRow(Pal pal, IconData icon, String label, bool value, ValueChanged<bool> onChanged) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Padding(padding: const EdgeInsets.all(12), child: Icon(icon, color: value ? pal.accent : pal.sub)),
            Expanded(child: Text(label, style: TextStyle(fontSize: 14, color: pal.text))),
            Switch(value: value, onChanged: onChanged),
          ]),
        ),
      );

  Future<void> _setHereMix({bool? music, bool? voice, double? musicVol, double? voiceVol}) async {
    setState(() {
      _hereMusic = music ?? _hereMusic;
      _hereVoice = voice ?? _hereVoice;
      _hereMusicVol = musicVol ?? _hereMusicVol;
      _hereVoiceVol = voiceVol ?? _hereVoiceVol;
    });
    _applyAudio();
    if (music != null) await _HerePrefs.set('music', music ? 'on' : 'off');
    if (voice != null) await _HerePrefs.set('voice', voice ? 'on' : 'off');
    if (musicVol != null) await _HerePrefs.set('music_volume', '$musicVol');
    if (voiceVol != null) await _HerePrefs.set('voice_volume', '$voiceVol');
  }

  /// "Thiết bị này" (máy điều khiển): luôn ở đầu danh sách màn hình; âm thanh phát ngay trên máy (trang /audio ẩn).
  Widget _hereRow(Pal pal) {
    final on = _hereOn;
    final canPlay = _webPreview;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: pal.surface2,
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(isDesktop ? Icons.computer_rounded : Icons.smartphone_rounded, color: pal.accent),
        title: Text(tr('Thiết bị này'), style: TextStyle(fontSize: 15, color: pal.text, fontWeight: FontWeight.w600)),
        subtitle: Text(
          !canPlay
              ? tr('Máy điều khiển · không phát tiếng trên máy này')
              : [
                  tr('Máy điều khiển'),
                  on ? tr('đang phát tiếng') : tr('đang tắt tiếng'),
                  if (_here == 'auto') tr('tự động'),
                ].join(' · '),
          style: TextStyle(fontSize: 12.5, color: pal.sub),
        ),
        trailing: canPlay
            ? IconButton(
                tooltip: on ? tr('Tắt tiếng') : tr('Bật tiếng'),
                icon: Icon(on ? Icons.volume_up_rounded : Icons.volume_off_rounded, color: on ? pal.accent : pal.sub),
                onPressed: () => _setHere(on ? 'off' : 'on'),
              )
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canPlay) ...[
            Row(children: [
              Expanded(child: Text(tr('Phát tiếng trên máy này'), style: TextStyle(fontSize: 14, color: pal.text))),
              DropdownButton<String>(
                value: _here,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 'auto', child: Text(tr('Khi không có màn hình'))),
                  DropdownMenuItem(value: 'on', child: Text(tr('Luôn bật'))),
                  DropdownMenuItem(value: 'off', child: Text(tr('Tắt'))),
                ],
                onChanged: (v) => v == null ? null : _setHere(v),
              ),
            ]),
            _mixRow(pal, 'here:music', Icons.music_note_rounded, tr('Nhạc nền'), _hereMusic, _hereMusicVol,
                (v) => _setHereMix(music: v), (v) => _setHereMix(musicVol: v)),
            _mixRow(pal, 'here:voice', Icons.record_voice_over_rounded, tr('Giọng đọc'), _hereVoice, _hereVoiceVol,
                (v) => _setHereMix(voice: v), (v) => _setHereMix(voiceVol: v)),
          ],
          if (_languages.length > 1)
            Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _langPick(pal, '🖼️', tr('Ngôn ngữ slide'), _hereSlide, (l) => _setHereLang(slide: l)),
              if (canPlay) _langPick(pal, '🔊', tr('Ngôn ngữ âm thanh'), _hereAudio, (l) => _setHereLang(audio: l)),
            ]),
        ],
      ),
    );
  }

  /// Một màn hình đã ghép: nút tắt tiếng / tắt hình ngay trên dòng; bấm vào dòng để chỉnh ngôn ngữ, nhạc nền, giọng đọc.
  Widget _screenRow(Pal pal, Map<String, dynamic> s) {
    final id = '${s['screen_id']}';
    final muted = s['muted'] == true, blanked = s['blanked'] == true;
    final music = s['music'] != false, voice = s['voice'] != false;
    final musicVol = ((s['music_volume'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0);
    final voiceVol = ((s['voice_volume'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: pal.surface2,
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(blanked ? Icons.tv_off_rounded : Icons.tv_rounded, color: blanked ? const Color(0xFFE53935) : pal.sub),
        title: Text('${s['name'] ?? id}', style: TextStyle(fontSize: 15, color: pal.text)),
        subtitle: Text(
          [
            blanked ? tr('đang tắt hình') : tr('Ghép lúc {0}', [_when(s['paired_at'])]),
            if (_languages.length > 1) langName(_okLang('${s['slide'] ?? ''}')),
          ].join(' · '),
          style: TextStyle(fontSize: 12.5, color: blanked ? const Color(0xFFE53935) : pal.sub),
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: muted ? tr('Bật tiếng') : tr('Tắt tiếng'),
            icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: muted ? const Color(0xFFE53935) : pal.text),
            onPressed: () => _screenSet(id, {'muted': !muted}),
          ),
          IconButton(
            tooltip: blanked ? tr('Bật hình') : tr('Tắt hình'),
            icon: Icon(blanked ? Icons.desktop_access_disabled_rounded : Icons.desktop_windows_rounded,
                color: blanked ? const Color(0xFFE53935) : pal.text),
            onPressed: () => _screenSet(id, {'blanked': !blanked}),
          ),
        ]),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mixRow(pal, '$id:music', Icons.music_note_rounded, tr('Nhạc nền'), music, musicVol,
              (v) => _screenSet(id, {'music': v}), (v) => _screenSet(id, {'music_volume': v})),
          _mixRow(pal, '$id:voice', Icons.record_voice_over_rounded, tr('Giọng đọc'), voice, voiceVol,
              (v) => _screenSet(id, {'voice': v}), (v) => _screenSet(id, {'voice_volume': v})),
          // Ngôn ngữ riêng của màn hình này: hình, giọng đọc, phụ đề (TV tự áp dụng).
          Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (_languages.length > 1) ...[
              _langPick(pal, '🖼️', tr('Ngôn ngữ slide'), '${s['slide'] ?? ''}', (l) => _screenSet(id, {'slide_lang': l})),
              _langPick(pal, '🔊', tr('Ngôn ngữ âm thanh'), '${s['audio'] ?? ''}', (l) => _screenSet(id, {'audio_lang': l})),
              _langPick(pal, '💬', tr('Ngôn ngữ phụ đề'), '${s['sub'] ?? ''}', (l) => _screenSet(id, {'sub_lang': l})),
            ] else
              Text(tr('🌐 {0} (bộ slide chưa có bản dịch)', [langName(_languages.first)]), style: TextStyle(fontSize: 13, color: pal.sub)),
          ]),
          _switchRow(pal, Icons.subtitles_outlined, tr('Phụ đề'), s['subtitles'] != false, (v) => _screenSet(id, {'subtitles': v})),
          _switchRow(pal, Icons.translate_rounded, tr('Cho chỉnh ngôn ngữ trên màn hình'), s['self'] == true,
              (v) => _screenSet(id, {'self_config': v})),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.link_off_rounded, size: 18),
              label: Text(tr('Ngắt')),
              onPressed: () async {
                await _do('screen_unpair', {'screen_id': id});
                _loadScreens();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Tab Màn hình: ghép nối (QR / mã), "Thiết bị này" luôn đứng đầu, các màn hình đã ghép, kiểu nhạc nền của buổi.
  Widget _screensTab(Pal pal) {
    final vol = ((_music['volume'] as num?)?.toDouble() ?? .3).clamp(0.0, 1.0);
    final style = '${_music['style'] ?? 'tech'}';
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
      _PairBox(onCode: _pair),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        child: Text(tr('Đang trình chiếu ({0})', ['${_screens.length + 1}']),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.sub)),
      ),
      _hereRow(pal),
      for (final s in _screens) _screenRow(pal, s),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
        child: Text(tr('Nhạc nền của buổi'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.sub)),
      ),
      Row(children: [
        Icon(Icons.music_note_outlined, color: pal.sub),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: style == 'calm' ? 'calm' : 'tech',
          underline: const SizedBox.shrink(),
          items: [
            DropdownMenuItem(value: 'tech', child: Text(tr('Nhạc nhịp nhẹ'))),
            DropdownMenuItem(value: 'calm', child: Text(tr('Nhạc nền êm'))),
          ],
          onChanged: (v) => _do('show_music', {'style': v}),
        ),
        Expanded(
          child: Slider(
            value: _volDrag ?? vol,
            onChanged: (v) => setState(() => _volDrag = v),
            onChangeEnd: (v) async {
              await _do('show_music', {'volume': double.parse(v.toStringAsFixed(2))});
              if (mounted) setState(() => _volDrag = null);
            },
          ),
        ),
      ]),
    ]);
  }

  /// Chọn một ngôn ngữ của bộ slide, tên viết bằng chính ngôn ngữ đó; [value] không có trong bộ thì hiện ngôn ngữ gốc.
  Widget _langPick(Pal pal, String emoji, String hint, String value, ValueChanged<String> onChanged) => Tooltip(
        message: hint,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(emoji),
          const SizedBox(width: 4),
          DropdownButton<String>(
            value: _okLang(value),
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 13.5, color: pal.text),
            items: [for (final l in _languages) DropdownMenuItem(value: l, child: Text(langName(l)))],
            onChanged: (l) {
              if (l != null && l != value) onChanged(l);
            },
          ),
        ]),
      );

  /// Tài liệu (📄) và ghi chú của AI: ❓ câu hỏi / ⚠️ vấn đề / ☑️ việc, người hỏi, trang, buổi này / buổi trước, câu trả lời;
  /// đã xong thì gạch ngang.
  Widget _kbView(Pal pal) => FutureBuilder(
        future: _kb ??= _loadKb(),
        builder: (_, snap) {
          if (snap.hasError) return Text(_err(snap.error!), style: TextStyle(fontSize: 13, color: pal.sub));
          if (!snap.hasData) return const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator()));
          final (docs, notes) = snap.data!;
          final small = TextStyle(fontSize: 12.5, color: pal.sub);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (docs.isEmpty) Text(tr('Chưa có tài liệu. Nhắn trợ lý AI gửi tài liệu vào buổi này.'), style: small),
            for (final d in docs) Text('📄 ${d['title'] ?? ''}', style: TextStyle(fontSize: 14, color: pal.text)),
            const SizedBox(height: 8),
            if (notes.isEmpty) Text(tr('Chưa có câu hỏi nào được ghi.'), style: small),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 26, child: Text(switch (n['kind']) { 'question' => '❓', 'issue' => '⚠️', 'todo' => '☑️', _ => '•' })),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${n['text'] ?? ''}',
                          style: TextStyle(
                            fontSize: 14,
                            color: n['status'] == 'done' ? pal.sub : pal.text,
                            decoration: n['status'] == 'done' ? TextDecoration.lineThrough : null,
                          )),
                      Text(
                        [
                          if ('${n['asked_by'] ?? ''}'.isNotEmpty) '${n['asked_by']}',
                          if ((n['slide'] as num?) != null && n['slide'] != 0) tr('trang {0}', ['${n['slide']}']),
                          n['presentation_id'] == _pid ? tr('buổi này') : tr('buổi trước'),
                        ].join(' · '),
                        style: small,
                      ),
                      if ('${n['answer'] ?? ''}'.trim().isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(8)),
                          child: Text('${n['answer']}', style: TextStyle(fontSize: 13, color: pal.text)),
                        ),
                    ]),
                  ),
                ]),
              ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final st = _st;
    final slides = _slides;
    final total = (st?['total'] as num?)?.toInt() ?? slides.length;
    final cur = slides.isEmpty ? null : slides[(_slide - 1).clamp(0, slides.length - 1)];
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 960;
      final tabBar = TabBar(
        controller: _tabs,
        onTap: (_) => setState(() {}),
        tabs: [
          Tab(text: tr('Nội dung')),
          Tab(text: tr('Màn hình')),
          Tab(
            child: Badge(
              isLabelVisible: _commentsUnread > 0,
              label: Text('$_commentsUnread'),
              child: Text(tr('Bình luận')),
            ),
          ),
          Tab(text: tr('AI')),
        ],
      );
      final tabs = TabBarView(controller: _tabs, children: [
        _contentTab(pal),
        _screensTab(pal),
        _commentsTab(pal),
        _ShowAiPanel(control: this),
      ]);
      // Đang gõ (bàn phím mở, thường ở tab AI): bỏ khung xem + hàng nút để ô nhập và tin nhắn không bị bàn phím che.
      final typing = MediaQuery.of(context).viewInsets.bottom > 0;
      final Widget main;
      if (st == null) {
        main = const Center(child: CircularProgressIndicator());
      } else if (typing) {
        main = Column(children: [tabBar, Expanded(child: tabs)]);
      } else {
        // Cuộn danh sách bên dưới thì khung xem + hàng nút trượt lên trên, thanh tab dính lại ở đầu.
        main = NestedScrollView(
          headerSliverBuilder: (_, _) => [
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: _deck == null
                        ? const AspectRatio(aspectRatio: 16 / 9, child: Center(child: CircularProgressIndicator()))
                        : SlidePreview(
                            key: ValueKey('${_deck!['id']}#${_deck!['rev']}#${_okLang(_hereSlide)}'),
                            client: _c,
                            deckId: '${_deck!['id']}',
                            pid: _pid,
                            lang: _languages.length > 1 ? _okLang(_hereSlide) : null,
                            slide: _slide,
                            frame: _frame,
                            step: (st['step'] as num?)?.toInt() ?? 0,
                            fallbackTitle: '${st['slide_title'] ?? ''}',
                            fallbackText: '${st['summary'] ?? cur?['text'] ?? ''}',
                          ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 13), child: _buttons(pal))),
            SliverToBoxAdapter(child: _statusLine(pal, total)),
            SliverPersistentHeader(pinned: true, delegate: _PinnedTabs(tabBar, pal.bg)),
          ],
          body: tabs,
        );
      }
      return Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), tooltip: tr('Thoát'), onPressed: () => Navigator.of(context).maybePop()),
          title: Text('${st?['title'] ?? ''}', overflow: TextOverflow.ellipsis),
          actions: const [Center(child: _LiveDot()), SizedBox(width: 12)],
        ),
        body: Stack(children: [
          // Máy phát tiếng: 1×1, không nhận chạm (huỷ cùng màn điều khiển).
          if (_audio != null) Positioned(left: 0, top: 0, width: 1, height: 1, child: IgnorePointer(child: WebViewWidget(controller: _audio!))),
          Positioned.fill(
            child: wide ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: main)) : main,
          ),
        ]),
      );
    });
  }
}

/// Khung trợ lý AI của buổi trình chiếu: danh sách tin + ô nhập. Bản này: câu gửi lên là phụ đề trên màn chiếu
/// (show_say, TV đọc to); "Xoá phụ đề" gửi chuỗi rỗng. Trò chuyện với AI thật sẽ nối vào cùng danh sách tin.
class _ShowAiPanel extends StatefulWidget {
  final _ShowControlPageState control;
  const _ShowAiPanel({required this.control});
  @override
  State<_ShowAiPanel> createState() => _ShowAiPanelState();
}

class _ShowAiPanelState extends State<_ShowAiPanel> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.control.say(t);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: pal.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 6),
          child: Row(children: [
            Icon(Icons.auto_awesome_rounded, color: pal.accentText, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('Trợ lý AI'), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: pal.text))),
            TextButton(onPressed: () => widget.control.say(''), child: Text(tr('Xoá phụ đề'))),
          ]),
        ),
        Divider(height: 1, color: pal.divider),
        Expanded(
          child: ValueListenableBuilder<List<ShowChatLine>>(
            valueListenable: widget.control.chat,
            builder: (_, lines, _) => lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(tr('Gõ nội dung để hiện lên màn chiếu như phụ đề, màn hình sẽ đọc to.'),
                          textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: lines.length,
                    itemBuilder: (_, i) {
                      final l = lines[lines.length - 1 - i];
                      return Align(
                        alignment: l.mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: BoxDecoration(color: l.mine ? pal.outBubble : pal.inBubble, borderRadius: BorderRadius.circular(14)),
                          child: Text(l.text, style: TextStyle(color: pal.text)),
                        ),
                      );
                    },
                  ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 6, 6, 8 + MediaQuery.of(context).viewInsets.bottom),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(hintText: tr('Nội dung đưa lên màn chiếu'), isDense: true, border: const OutlineInputBorder()),
                ),
              ),
              IconButton(
                icon: _sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded),
                onPressed: _sending ? null : _send,
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Ghép màn hình (TV mở trang /tv): luôn 2 nút cạnh nhau, Quét mã QR và Nhập mã ghép nối (hiện ô 8 ký tự + Kết nối).
/// Máy không có camera vẫn hiện nút Quét, bấm thì báo chọn Nhập mã. [onCode] ném lỗi thì hiện lỗi đó.
class _PairBox extends StatefulWidget {
  final Future<void> Function(String code) onCode;
  const _PairBox({required this.onCode});
  @override
  State<_PairBox> createState() => _PairBoxState();
}

class _PairBoxState extends State<_PairBox> {
  final _code = TextEditingController();
  bool _typing = false, _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(String code) async {
    setState(() => _busy = true);
    try {
      await widget.onCode(code);
      _code.clear();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _scan() async {
    if (isDesktop) return _toast(context, tr('Máy này không quét được QR: hãy chọn "Nhập mã ghép nối"'));
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanOncePage()));
    if (raw == null || !mounted) return;
    final code = pairCodeOf(raw);
    if (code == null) return _toast(context, tr('Mã QR này không phải màn hình trình chiếu'));
    await _run(code);
  }

  Future<void> _submit() async {
    final code = pairCodeOf(_code.text);
    if (code == null) return _toast(context, tr('Mã gồm 8 ký tự'));
    await _run(code);
  }

  @override
  Widget build(BuildContext context) {
    Widget half(IconData icon, String label, VoidCallback? onTap) => Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              minimumSize: const Size(0, 38),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        half(Icons.qr_code_scanner_rounded, tr('Quét mã QR'), _busy ? null : _scan),
        const SizedBox(width: 8),
        half(Icons.keyboard_rounded, tr('Nhập mã ghép nối'), _busy ? null : () => setState(() => _typing = true)),
      ]),
      if (_typing)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _code,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(hintText: tr('VD: XKF3 6GSF'), isDense: true, border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _busy ? null : _submit, child: Text(tr('Kết nối'))),
          ]),
        ),
      if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
    ]);
  }
}

/// Cài đặt trình chiếu trên máy này: phát nhạc và giọng đọc ('auto' khi buổi chưa ghép màn hình nào, mặc định;
/// 'on'; 'off') và ngôn ngữ trên máy này (`slide`: khung xem trước, `audio`: giọng đọc; rỗng = ngôn ngữ gốc).
class _HerePrefs {
  static Map<String, String>? _v;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}show-audio.json');
  }

  static Future<Map<String, String>> load() async {
    if (_v != null) return _v!;
    final v = <String, String>{};
    try {
      final f = await _file();
      if (await f.exists()) {
        (jsonDecode(await f.readAsString()) as Map).forEach((k, x) => v['$k'] = '${x ?? ''}');
      }
    } catch (_) {}
    if (!const ['auto', 'on', 'off'].contains(v['here'])) v['here'] = 'auto';
    return _v = v;
  }

  static Future<void> set(String key, String value) async {
    final v = await load();
    v[key] = value;
    try {
      await (await _file()).writeAsString(jsonEncode(v));
    } catch (_) {}
  }
}

/// Tên ngôn ngữ viết bằng chính ngôn ngữ đó (Tiếng Việt, English, 中文…); mã lạ thì hiện mã.
String langName(String code) =>
    const {
      'vi': 'Tiếng Việt',
      'en': 'English',
      'zh': '中文',
      'ja': '日本語',
      'ko': '한국어',
      'th': 'ไทย',
      'fr': 'Français',
      'de': 'Deutsch',
      'es': 'Español',
      'ru': 'Русский',
      'id': 'Bahasa Indonesia',
      'ms': 'Bahasa Melayu',
      'lo': 'ລາວ',
      'km': 'ខ្មែរ',
    }[code.split(RegExp('[-_]')).first.toLowerCase()] ??
    code;

/// Mở từ QR của màn hình TV: ghép vào buổi đang chạy, hoặc chọn bộ slide để bắt đầu rồi ghép.
class ShowPairPage extends StatefulWidget {
  final ShowClient client;
  final String code;
  const ShowPairPage({super.key, required this.client, required this.code});
  @override
  State<ShowPairPage> createState() => _ShowPairPageState();
}

class _ShowPairPageState extends State<ShowPairPage> {
  ShowClient get client => widget.client;
  String get code => widget.code;
  late final _load = Future.wait([client.call('show_list'), client.call('deck_list', {'limit': 100})]);

  Future<void> _pairInto(BuildContext context, String pid) async {
    final nav = Navigator.of(context);
    try {
      final r = await client.call('screen_pair', {'presentation_id': pid, 'code': code});
      if (!context.mounted) return;
      _toast(context, tr('Đã kết nối {0}', ['${r['name'] ?? ''}']));
      nav.pushReplacement(MaterialPageRoute(builder: (_) => ShowControlPage(client: client, pid: pid)));
    } catch (e) {
      if (context.mounted) _toast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
        );
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text(tr('Ghép màn hình {0}', [code]))),
      body: FutureBuilder(
        future: _load,
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Text(_err(snap.error!), style: TextStyle(color: pal.sub)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final live = [for (final p in snap.data![0]['presentations'] as List? ?? const []) (p as Map).cast<String, dynamic>()];
          final decks = [for (final d in snap.data![1]['decks'] as List? ?? const []) (d as Map).cast<String, dynamic>()];
          return ListView(children: [
            if (live.isNotEmpty) head(tr('Đang trình chiếu')),
            for (final p in live)
              ListTile(
                leading: const _LiveDot(),
                title: Text('${p['title'] ?? ''}'),
                subtitle: Text(tr('Trang {0}/{1}', ['${p['slide'] ?? 1}', '${p['total'] ?? 0}'])),
                onTap: () => _pairInto(ctx, '${p['presentation_id']}'),
              ),
            if (client.can('present') && decks.isNotEmpty) head(tr('Bắt đầu trình chiếu')),
            if (client.can('present'))
              for (final d in decks)
                ListTile(
                  leading: const Icon(Icons.slideshow_rounded),
                  title: Text('${d['title'] ?? ''}'),
                  subtitle: Text(tr('{0} trang', ['${d['slides'] ?? 0}'])),
                  onTap: () async {
                    try {
                      final st = await client.call('show_start', {'deck_id': d['id']});
                      if (ctx.mounted) await _pairInto(ctx, '${st['presentation_id']}');
                    } catch (e) {
                      if (ctx.mounted) _toast(ctx, _err(e));
                    }
                  },
                ),
            if (live.isEmpty && (decks.isEmpty || !client.can('present')))
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(tr('Chưa có buổi trình chiếu nào đang chạy'), textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
              ),
          ]);
        },
      ),
    );
  }
}

/// Thanh tab dính ở đầu khi cuộn (màn điều khiển trình chiếu).
class _PinnedTabs extends SliverPersistentHeaderDelegate {
  final TabBar bar;
  final Color color;
  _PinnedTabs(this.bar, this.color);
  @override
  double get minExtent => bar.preferredSize.height;
  @override
  double get maxExtent => bar.preferredSize.height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => ColoredBox(color: color, child: bar);
  @override
  bool shouldRebuild(_PinnedTabs old) => old.bar != bar || old.color != color;
}
