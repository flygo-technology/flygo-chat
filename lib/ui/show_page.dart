import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/mini_apps.dart';
import '../api/show_api.dart';
import '../config.dart' show isDesktop;
import '../i18n/i18n.dart';
import 'mini_app_view.dart' show ScanOncePage;
import 'theme.dart';

// App Trình chiếu (mini app "show") dạng màn hình native: tab Danh sách slide và tab Đang trình chiếu.
// Mọi thao tác gọi bộ tool của app (ShowClient.call), cùng bộ tool AI dùng qua MCP.

String _err(Object e) => e is ShowException || e is MiniAppException ? '$e' : tr('Không kết nối được, thử lại sau.');

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
  final bool animate;
  final String fallbackTitle, fallbackText;
  const SlidePreview(
      {super.key, required this.client, required this.deckId, required this.slide, this.step = 0, this.animate = true, this.fallbackTitle = '', this.fallbackText = ''});
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
      _url = await widget.client.renderUrl(widget.deckId);
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
    if (_ready) _web?.runJavaScript('window.flygoGo && flygoGo(${widget.slide - 1}, ${widget.step}, ${live && widget.animate})');
  }

  @override
  void didUpdateWidget(SlidePreview old) {
    super.didUpdateWidget(old);
    if (old.slide != widget.slide || old.step != widget.step) _go(true);
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
  bool _starting = false;

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

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      final st = await widget.client.call('show_start', {'deck_id': widget.deckId, 'start_slide': _slide});
      if (!mounted) return;
      final pid = '${st['presentation_id']}';
      final nav = Navigator.of(context);
      nav.pop(pid);
      nav.push(MaterialPageRoute(builder: (_) => ShowControlPage(client: widget.client, pid: pid)));
    } catch (e) {
      if (mounted) {
        setState(() => _starting = false);
        _toast(context, _err(e));
      }
    }
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
    final cur = slides.isEmpty ? null : slides[(_slide - 1).clamp(0, slides.length - 1)];
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text('${deck?['title'] ?? widget.title}')),
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
                      icon: _starting
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.slideshow_rounded),
                      label: Text(tr('Trình chiếu')),
                      onPressed: _starting || slides.isEmpty ? null : _start,
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
                    final notes = '${s['notes'] ?? ''}'.trim();
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

/// Màn điều khiển một buổi trình chiếu, đồng bộ realtime: lật trang, lưới trang, ghi chú, ghép màn hình bằng QR,
/// tự động trình chiếu, phụ đề / đọc to, link cho khách, kết thúc.
class ShowControlPage extends StatefulWidget {
  final ShowClient client;
  final String pid;
  const ShowControlPage({super.key, required this.client, required this.pid});
  @override
  State<ShowControlPage> createState() => _ShowControlPageState();
}

class _ShowControlPageState extends State<ShowControlPage> {
  ShowLive? _live;
  StreamSubscription? _sub;
  Map<String, dynamic>? _st;
  Map<String, dynamic>? _deck;
  String _notes = '';
  List<Map<String, dynamic>> _screens = [];
  bool _busy = false;
  final _interval = TextEditingController(text: '15');

  ShowClient get _c => widget.client;
  String get _pid => widget.pid;
  int get _slide => (_st?['slide'] as num?)?.toInt() ?? 1;
  List<Map<String, dynamic>> get _slides => [for (final s in (_deck?['slides'] as List? ?? const [])) (s as Map).cast<String, dynamic>()];

  @override
  void initState() {
    super.initState();
    _status();
    _live = _c.live(_pid);
    _sub = _live!.states.listen(_onState);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _live?.close();
    _interval.dispose();
    super.dispose();
  }

  /// Trạng thái mới (WebSocket hoặc kết quả lời gọi): đổi trang thì tải ghi chú; bộ slide bị sửa thì tải lại bộ.
  void _onState(Map<String, dynamic> st) {
    if (!mounted) return;
    if (st['ended'] == true || st['state'] == 'ended') {
      _toast(context, tr('Buổi trình chiếu đã kết thúc'));
      Navigator.of(context).maybePop();
      return;
    }
    final old = _st;
    setState(() => _st = {...?old, ...st});
    if (old == null || old['slide'] != st['slide'] || old['deck_rev'] != st['deck_rev']) _status();
    if (_deck == null || (st['deck_rev'] != null && _deck!['rev'] != st['deck_rev'])) _loadDeck('${st['deck_id'] ?? old?['deck_id'] ?? ''}');
  }

  Future<void> _loadDeck(String id) async {
    if (id.isEmpty) return;
    try {
      final d = await _c.call('deck_get', {'deck_id': id});
      if (mounted) setState(() => _deck = d);
    } catch (_) {}
  }

  Future<void> _status() async {
    try {
      final s = await _c.call('show_status', {'presentation_id': _pid});
      if (!mounted) return;
      setState(() {
        _notes = '${s['notes'] ?? ''}';
        _screens = [for (final x in (s['screens'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
      });
      final st = Map<String, dynamic>.from(s)..remove('notes')..remove('screens');
      if (_st == null) _onState(st);
    } catch (e) {
      if (mounted && _st == null) _toast(context, _err(e));
    }
  }

  /// Gọi tool điều khiển; kết quả là trạng thái thì cập nhật ngay (không chờ WebSocket).
  Future<Map<String, dynamic>?> _do(String tool, [Map<String, dynamic> extra = const {}]) async {
    try {
      final r = await _c.call(tool, {'presentation_id': _pid, ...extra});
      if (r['type'] == 'state' || r.containsKey('slide')) _onState(r);
      return r;
    } catch (e) {
      if (mounted) _toast(context, _err(e));
      return null;
    }
  }

  /// Ghép màn hình khác (TV mở trang /tv): quét QR trên điện thoại, máy tính nhập mã 8 ký tự.
  Future<void> _pair() async {
    String? raw;
    if (!isDesktop) {
      raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanOncePage()));
    }
    if (!mounted) return;
    raw ??= await _askCode(context);
    final code = raw == null ? null : pairCodeOf(raw);
    if (code == null) {
      if (raw != null && mounted) _toast(context, tr('Mã không hợp lệ'));
      return;
    }
    setState(() => _busy = true);
    final r = await _do('screen_pair', {'code': code});
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      _toast(context, tr('Đã kết nối {0}', ['${r['name'] ?? ''}']));
      _status();
    }
  }

  Future<void> _say() async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Phụ đề / đọc to')),
        content: TextField(controller: ctl, autofocus: true, maxLines: 3, minLines: 1, decoration: InputDecoration(hintText: tr('Câu hiện trên màn hình và được đọc to'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
          FilledButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: Text(tr('Gửi'))),
        ],
      ),
    );
    ctl.dispose();
    if (text != null && text.isNotEmpty) await _do('show_say', {'text': text});
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

  Widget _autopilot(Pal pal) {
    final ap = (_st?['autopilot'] as Map?) ?? const {};
    final running = ap['running'] == true, paused = ap['paused'] == true;
    final secs = int.tryParse(_interval.text) ?? 15;
    return Row(children: [
      Icon(Icons.timer_outlined, color: pal.sub),
      const SizedBox(width: 8),
      Expanded(child: Text(running ? (paused ? tr('Tự động: đang tạm dừng') : tr('Tự động: đang chạy')) : tr('Tự động trình chiếu'))),
      if (!running) ...[
        SizedBox(
          width: 56,
          child: TextField(
            controller: _interval,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: InputDecoration(isDense: true, suffixText: tr('giây')),
          ),
        ),
        IconButton(
            icon: const Icon(Icons.play_arrow_rounded),
            tooltip: tr('Bắt đầu'),
            onPressed: () => _do('show_autopilot', {'action': 'start', 'interval_s': secs.clamp(3, 600)})),
      ] else ...[
        IconButton(
            icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
            tooltip: paused ? tr('Tiếp tục') : tr('Tạm dừng'),
            onPressed: () => _do('show_autopilot', {'action': paused ? 'resume' : 'pause'})),
        IconButton(icon: const Icon(Icons.stop_rounded), tooltip: tr('Dừng'), onPressed: () => _do('show_autopilot', {'action': 'stop'})),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final st = _st;
    final slides = _slides;
    final total = (st?['total'] as num?)?.toInt() ?? slides.length;
    final step = (st?['step'] as num?)?.toInt() ?? 0, steps = (st?['steps'] as num?)?.toInt() ?? 0;
    final cur = slides.isEmpty ? null : slides[(_slide - 1).clamp(0, slides.length - 1)];
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        title: Text('${st?['title'] ?? ''}', overflow: TextOverflow.ellipsis),
        actions: [
          const Center(child: _LiveDot()),
          IconButton(icon: const Icon(Icons.stop_circle_outlined), tooltip: tr('Kết thúc'), onPressed: _stop),
        ],
      ),
      body: st == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: _deck == null
                    ? const AspectRatio(aspectRatio: 16 / 9, child: Center(child: CircularProgressIndicator()))
                    : SlidePreview(
                        key: ValueKey('${_deck!['id']}#${_deck!['rev']}'),
                        client: _c,
                        deckId: '${_deck!['id']}',
                        slide: _slide,
                        step: step,
                        fallbackTitle: '${st['slide_title'] ?? ''}',
                        fallbackText: '${cur?['text'] ?? ''}',
                      ),
              ),
              Text(
                  steps > 0
                      ? tr('Trang {0}/{1} · bước {2}/{3}', ['$_slide', '$total', '$step', '$steps'])
                      : tr('Trang {0}/{1}', ['$_slide', '$total']),
                  style: TextStyle(color: pal.sub)),
              if ('${st['caption'] ?? ''}'.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 2), child: Text('${st['caption']}', style: TextStyle(color: pal.sub, fontStyle: FontStyle.italic))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  Expanded(child: _BigButton(icon: Icons.chevron_left_rounded, label: '', onTap: () => _do('show_prev'))),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _BigButton(icon: Icons.chevron_right_rounded, label: tr('Tới'), primary: true, onTap: () => _do('show_next'))),
                ]),
              ),
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
                  if (total > 0)
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: total,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (_, i) => ChoiceChip(
                          label: Text('${i + 1}'),
                          tooltip: i < slides.length ? '${slides[i]['title'] ?? ''}' : null,
                          selected: i + 1 == _slide,
                          onSelected: (_) => _do('show_goto', {'slide': i + 1, 'step': 0}),
                        ),
                      ),
                    ),
                  if (_notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(tr('Ghi chú người nói'), style: TextStyle(fontWeight: FontWeight.w700, color: pal.sub)),
                    const SizedBox(height: 4),
                    Text(_notes, style: TextStyle(fontSize: 15, color: pal.text)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.qr_code_scanner_rounded),
                    label: Text(isDesktop ? tr('Nhập mã để chiếu lên máy khác') : tr('Quét QR để chiếu lên máy khác')),
                    onPressed: _busy ? null : _pair,
                  ),
                  for (final s in _screens)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tv_rounded),
                      title: Text('${s['name'] ?? s['screen_id']}'),
                      subtitle: Text(tr('Ghép lúc {0}', [_when(s['paired_at'])])),
                      trailing: TextButton(
                        onPressed: () async {
                          await _do('screen_unpair', {'screen_id': s['screen_id']});
                          _status();
                        },
                        child: Text(tr('Ngắt')),
                      ),
                    ),
                  const Divider(height: 24),
                  _autopilot(pal),
                  ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.subtitles_outlined), title: Text(tr('Phụ đề / đọc to')), onTap: _say),
                  ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.link_rounded), title: Text(tr('Link cho khách')), onTap: _guestLink),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.stop_circle_outlined, color: Color(0xFFE53935)),
                    title: Text(tr('Kết thúc'), style: const TextStyle(color: Color(0xFFE53935))),
                    onTap: _stop,
                  ),
                ]),
              ),
            ]),
    );
  }
}

/// Ô nhập mã 8 ký tự hiện trên màn hình TV.
Future<String?> _askCode(BuildContext context) async {
  final ctl = TextEditingController();
  final r = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Nhập mã trên màn hình')),
      content: TextField(
        controller: ctl,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: 9,
        decoration: const InputDecoration(hintText: 'ABCD2345'),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text(tr('Kết nối'))),
      ],
    ),
  );
  ctl.dispose();
  return r;
}

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
