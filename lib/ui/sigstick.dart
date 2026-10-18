import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Kho sticker SigStick (https://www.sigstick.com). Không có API chính thức: đọc dữ liệu
/// Next.js của trang `/stickers`. Ảnh không tải về máy chủ: tin nhắn chứa thẳng link cdn2.cdnstep.com.
class SigStickPack {
  final String id, title, author, cover;
  final List<String> stickers;
  final int downloads;
  const SigStickPack({
    required this.id,
    required this.title,
    this.author = '',
    required this.cover,
    required this.stickers,
    this.downloads = 0,
  });

  static SigStickPack? fromApi(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    final stickers = [
      for (final s in (j['stickers'] as List? ?? const []))
        if (s is Map && s['url'] is String) s['url'] as String,
    ];
    if (stickers.isEmpty) return null;
    final cover = (j['cover'] is Map ? (j['cover'] as Map)['url'] : null) as String? ?? stickers.first;
    return SigStickPack(
      id: id,
      title: '${j['title'] ?? ''}'.trim(),
      author: '${j['author'] ?? ''}'.trim(),
      cover: cover,
      stickers: stickers,
      downloads: (j['download'] as num?)?.toInt() ?? 0,
    );
  }

  /// Bản lưu trên máy: chỉ giữ link.
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'cover': cover, 'stickers': stickers};

  static SigStickPack? fromSaved(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final stickers = (j['stickers'] as List? ?? const []).whereType<String>().toList();
    if (stickers.isEmpty) return null;
    return SigStickPack(
      id: j['id'] as String,
      title: '${j['title'] ?? ''}',
      cover: j['cover'] as String? ?? stickers.first,
      stickers: stickers,
    );
  }
}

class SigStick {
  static const _host = 'www.sigstick.com';
  static const _ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
  static const _headers = {'User-Agent': _ua, 'Accept': 'application/json, text/html'};
  static String? _buildId;

  static Future<String> _build({bool refresh = false}) async {
    if (!refresh && _buildId != null) return _buildId!;
    final res = await http.get(Uri.https(_host, '/stickers'), headers: _headers).timeout(const Duration(seconds: 15));
    final m = RegExp(r'"buildId":"([^"]+)"').firstMatch(res.body);
    if (m == null) throw const HttpException('sigstick: buildId');
    return _buildId = m.group(1)!;
  }

  /// GET `/_next/data/<buildId>/<path>.json`; 404 (SigStick vừa triển khai bản mới) thì lấy lại buildId và thử một lần nữa.
  static Future<Map<String, dynamic>> _data(String path, [Map<String, String>? q]) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final b = await _build(refresh: attempt > 0);
      final res = await http
          .get(Uri.https(_host, '/_next/data/$b/$path.json', q), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 404 && attempt == 0) continue;
      if (res.statusCode != 200) throw HttpException('sigstick: ${res.statusCode}');
      return ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['pageProps'] as Map).cast<String, dynamic>();
    }
    throw const HttpException('sigstick: 404');
  }

  /// Tìm bộ sticker (tối đa 40 bộ). SigStick luôn cần từ khoá.
  static Future<List<SigStickPack>> search(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return [];
    final p = await _data('stickers', {'keyword': k});
    return [for (final j in (p['packs'] as List? ?? const [])) ?SigStickPack.fromApi(j)].take(40).toList();
  }

  /// Lấy một bộ theo id (dùng khi đồng bộ danh sách từ thiết bị khác).
  static Future<SigStickPack?> pack(String id) async => SigStickPack.fromApi((await _data('pack/$id'))['pack']);
}

/// Các bộ sticker đã thêm + sticker dùng gần đây. Khi thêm bộ, máy chủ Flygo chép ảnh về
/// (`POST $kPushUrl/stickers/import`) để tin nhắn không phải trỏ thẳng sang cdnstep; lỗi thì giữ link gốc. Lưu link trong `sticker_packs.json` (thư mục ứng dụng);
/// danh sách id bộ còn được đồng bộ lên preferences flygo_chat/sticker_packs để máy khác tự lấy lại.
class StickerPacks {
  static final saved = ValueNotifier<List<SigStickPack>>([]);
  static final recent = ValueNotifier<List<String>>([]);
  /// Id các bộ đang được thêm (đang chép ảnh về máy chủ).
  static final adding = ValueNotifier<Set<String>>({});
  static bool _loaded = false;
  static final _synced = <String>{};

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}sticker_packs.json');
  }

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map;
      saved.value = [for (final p in (j['packs'] as List? ?? const [])) ?SigStickPack.fromSaved(p)];
      recent.value = (j['recent'] as List? ?? const []).whereType<String>().toList();
    } catch (e) {
      debugPrint('[stickers] load: $e');
    }
  }

  static Future<void> _save() async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'packs': [for (final p in saved.value) p.toJson()],
        'recent': recent.value,
      }));
    } catch (e) {
      debugPrint('[stickers] save: $e');
    }
  }

  static bool has(String id) => saved.value.any((p) => p.id == id);

  static Future<void> add(SigStickPack p, [AppState? app]) async {
    await load();
    if (has(p.id) || adding.value.contains(p.id)) return;
    adding.value = {...adding.value, p.id};
    try {
      final hosted = app == null ? p : await _rehost(p, app);
      if (has(p.id)) return;
      saved.value = [...saved.value, hosted];
      await _save();
      if (app != null) unawaited(_push(app));
    } finally {
      adding.value = {...adding.value}..remove(p.id);
    }
  }

  /// Nhờ trạm đẩy chép ảnh của bộ về (tối đa 80 link mỗi lần, cùng link gốc → cùng link mới).
  /// Link nào lỗi / máy chủ chưa có endpoint thì giữ nguyên link gốc.
  static Future<SigStickPack> _rehost(SigStickPack p, AppState app) async {
    final all = [p.cover, ...p.stickers].where((u) => Uri.tryParse(u)?.host == 'cdn2.cdnstep.com').toSet().toList();
    final map = <String, String>{};
    await discoverPush(kServerUrl);
    for (var i = 0; i < all.length; i += 80) {
      try {
        final res = await http
            .post(Uri.parse('$kPushUrl/stickers/import'),
                headers: {
                  'Authorization': 'Bearer ${app.api.token}',
                  'X-MM-Server': kServerUrl,
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({
                  'pack': {'id': p.id, 'title': p.title},
                  'urls': all.sublist(i, (i + 80).clamp(0, all.length)),
                }))
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != 200) break;
        final urls = (jsonDecode(res.body) as Map)['urls'];
        if (urls is Map) {
          urls.forEach((k, v) {
            if (k is String && v is String && v.startsWith('https://')) map[k] = v;
          });
        }
      } catch (e) {
        debugPrint('[stickers] import: $e');
        break;
      }
    }
    return SigStickPack(
      id: p.id,
      title: p.title,
      author: p.author,
      cover: map[p.cover] ?? p.cover,
      stickers: [for (final u in p.stickers) map[u] ?? u],
      downloads: p.downloads,
    );
  }

  static Future<void> remove(String id, [AppState? app]) async {
    await load();
    saved.value = saved.value.where((p) => p.id != id).toList();
    await _save();
    if (app != null) unawaited(_push(app));
  }

  static Future<void> addRecent(String url) async {
    await load();
    recent.value = [url, ...recent.value.where((u) => u != url)].take(32).toList();
    await _save();
  }

  /// Danh sách gọn (id, tên ngắn) để vừa giới hạn độ dài giá trị preferences.
  static String _compact() {
    final out = <List<String>>[];
    for (final p in saved.value) {
      final t = p.title.length > 24 ? p.title.substring(0, 24) : p.title;
      out.add([p.id, t]);
      if (jsonEncode(out).length > 1800) {
        out.removeLast();
        break;
      }
    }
    return jsonEncode(out);
  }

  static Future<void> _push(AppState app) async {
    final me = app.me;
    if (me == null) return;
    try {
      await app.api.put('/users/${me.id}/preferences', [
        {'user_id': me.id, 'category': 'flygo_chat', 'name': 'sticker_packs', 'value': _compact()}
      ]);
    } catch (e) {
      debugPrint('[stickers] push: $e');
    }
  }

  /// Mỗi phiên một lần: thêm các bộ có trên máy chủ mà máy này chưa có (lấy lại link từ SigStick theo id).
  /// Bỏ bộ chỉ có hiệu lực trên máy đó cho tới khi danh sách được đẩy lên lại.
  static Future<void> sync(AppState app) async {
    await load();
    final me = app.me;
    if (me == null || !_synced.add('${app.api.hashCode}/${me.id}')) return;
    List remote;
    try {
      final r = (await app.api.get('/users/${me.id}/preferences/flygo_chat/name/sticker_packs') as Map).cast<String, dynamic>();
      remote = jsonDecode(r['value'] as String) as List;
    } catch (_) {
      // Chưa có trên máy chủ: đẩy danh sách của máy này lên.
      if (saved.value.isNotEmpty) await _push(app);
      return;
    }
    final missing = [
      for (final e in remote)
        if (e is List && e.isNotEmpty && e.first is String && !has(e.first as String)) e.first as String,
    ];
    var added = false;
    for (final id in missing) {
      try {
        final p = await SigStick.pack(id);
        if (p != null && !has(p.id)) {
          saved.value = [...saved.value, await _rehost(p, app)];
          added = true;
        }
      } catch (_) {}
    }
    // Bộ thêm lúc máy chủ chưa chép được ảnh (còn link cdnstep): thử chép lại.
    for (final p in [...saved.value]) {
      if (![p.cover, ...p.stickers].any((u) => Uri.tryParse(u)?.host == 'cdn2.cdnstep.com')) continue;
      final h = await _rehost(p, app);
      if (h.cover == p.cover && listEquals(h.stickers, p.stickers)) break; // máy chủ chưa sẵn sàng
      saved.value = [for (final x in saved.value) x.id == p.id ? h : x];
      added = true;
    }
    if (added) await _save();
    final remoteIds = {for (final e in remote) if (e is List && e.isNotEmpty) e.first};
    if (saved.value.any((p) => !remoteIds.contains(p.id))) await _push(app);
  }
}

bool _desktopPlatform(BuildContext context) =>
    const {TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}.contains(Theme.of(context).platform);

/// Mở kho sticker. Điện thoại: trang mới. Máy tính: hộp thoại (có điều hướng riêng cho trang chi tiết bộ);
/// [tapGroup] giữ bảng biểu cảm nổi không bị đóng khi bấm trong hộp thoại.
Future<void> openStickerStore(BuildContext context, AppState app, {Object? tapGroup}) {
  if (!_desktopPlatform(context)) {
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => StickerStorePage(app: app)));
  }
  return showDialog(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      Widget dialog = Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: SizedBox(
          width: 560.0.clamp(320.0, size.width - 40),
          height: 700.0.clamp(360.0, size.height - 60),
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute(
              builder: (_) => StickerStorePage(app: app, onClose: () => Navigator.of(ctx).pop()),
            ),
          ),
        ),
      );
      if (tapGroup != null) dialog = TapRegion(groupId: tapGroup, child: dialog);
      return dialog;
    },
  );
}

class StickerStorePage extends StatefulWidget {
  final AppState app;

  /// Có khi mở trong hộp thoại (máy tính): nút đóng ở thanh tiêu đề.
  final VoidCallback? onClose;
  const StickerStorePage({super.key, required this.app, this.onClose});

  @override
  State<StickerStorePage> createState() => _StickerStorePageState();
}

class _StickerStorePageState extends State<StickerStorePage> {
  static const _chips = ['mèo', 'cat', 'meme', 'chó', 'love', 'hello', 'cảm ơn', 'capybara', 'bear'];
  final _ctl = TextEditingController();
  Timer? _debounce;
  String _keyword = _chips.first;
  List<SigStickPack> _packs = [];
  bool _loading = true;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    StickerPacks.load();
    _search(_keyword);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    q = q.trim();
    if (q.isEmpty) q = _chips.first;
    final seq = ++_seq;
    setState(() {
      _keyword = q;
      _loading = true;
      _error = null;
    });
    try {
      final packs = await SigStick.search(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _packs = packs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = tr('Không tải được. Kiểm tra kết nối mạng.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        automaticallyImplyLeading: widget.onClose == null,
        title: Text(tr('Kho sticker')),
        actions: [
          if (widget.onClose != null) IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: TextField(
            controller: _ctl,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) {
              _debounce?.cancel();
              _search(v);
            },
            onChanged: (v) {
              _debounce?.cancel();
              if (v.trim().isEmpty) return;
              _debounce = Timer(const Duration(milliseconds: 500), () => _search(v));
            },
            style: TextStyle(color: pal.text),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: pal.surface2,
              hintText: tr('Tìm bộ sticker'),
              hintStyle: TextStyle(color: pal.sub),
              prefixIcon: Icon(Icons.search, color: pal.sub, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final c in _chips)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    label: Text(c),
                    selected: _keyword == c,
                    selectedColor: pal.chipSelBg,
                    labelStyle: TextStyle(color: _keyword == c ? pal.chipSelFg : pal.text),
                    onSelected: (_) {
                      _debounce?.cancel();
                      _ctl.text = c;
                      _search(c);
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: pal.accent))
              : _error != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!, style: TextStyle(color: pal.sub)),
                        TextButton(onPressed: () => _search(_keyword), child: Text(tr('Thử lại'))),
                      ]),
                    )
                  : _packs.isEmpty
                      ? Center(child: Text(tr('Không tìm thấy bộ sticker nào'), style: TextStyle(color: pal.sub)))
                      : ListenableBuilder(
                          listenable: Listenable.merge([StickerPacks.saved, StickerPacks.adding]),
                          builder: (context, _) => ListView.separated(
                            padding: const EdgeInsets.only(bottom: 12),
                            itemCount: _packs.length,
                            separatorBuilder: (_, _) => Divider(height: 1, indent: 80, color: pal.divider),
                            itemBuilder: (_, i) => _packTile(_packs[i], pal),
                          ),
                        ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 2),
          child: Text(tr('Nguồn: SigStick'), style: TextStyle(fontSize: 11, color: pal.sub)),
        ),
      ]),
    );
  }

  Widget _packTile(SigStickPack p, Pal pal) {
    final added = StickerPacks.has(p.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: SizedBox(width: 54, height: 54, child: stickerImage(p.cover, size: 54)),
      title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text)),
      subtitle: Text(
        [if (p.author.isNotEmpty) p.author, tr('{0} sticker', [p.stickers.length])].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: pal.sub, fontSize: 12.5),
      ),
      trailing: StickerPacks.adding.value.contains(p.id)
          ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)))
          : IconButton(
        tooltip: added ? tr('Bỏ bộ') : tr('Thêm bộ sticker'),
        icon: Icon(added ? Icons.check_circle : Icons.add_circle_outline, color: added ? pal.accent : pal.sub),
        onPressed: () => added ? StickerPacks.remove(p.id, widget.app) : StickerPacks.add(p, widget.app),
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StickerPackPage(pack: p, app: widget.app))),
    );
  }
}

class StickerPackPage extends StatelessWidget {
  final SigStickPack pack;
  final AppState app;
  const StickerPackPage({super.key, required this.pack, required this.app});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        title: Text(pack.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 110, mainAxisSpacing: 8, crossAxisSpacing: 8),
            itemCount: pack.stickers.length,
            itemBuilder: (_, i) => stickerImage(pack.stickers[i]),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: ListenableBuilder(
              listenable: Listenable.merge([StickerPacks.saved, StickerPacks.adding]),
              builder: (context, _) {
                final added = StickerPacks.has(pack.id);
                final busy = StickerPacks.adding.value.contains(pack.id);
                return SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: busy
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: pal.accent),
                          icon: const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)),
                          label: Text(tr('Đang thêm...')),
                          onPressed: null,
                        )
                      : added
                      ? OutlinedButton.icon(
                          icon: const Icon(Icons.remove_circle_outline),
                          label: Text(tr('Bỏ bộ')),
                          onPressed: () => StickerPacks.remove(pack.id, app),
                        )
                      : FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: pal.accent),
                          icon: const Icon(Icons.add),
                          label: Text(tr('Thêm bộ sticker')),
                          onPressed: () => StickerPacks.add(pack, app),
                        ),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

/// Ảnh sticker từ link (PNG tĩnh hoặc WebP động); thu nhỏ khi giải mã cho đỡ tốn bộ nhớ.
Widget stickerImage(String url, {double size = 110}) => Image.network(
      url,
      fit: BoxFit.contain,
      cacheWidth: (size * 2).round(),
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.grey),
    );
