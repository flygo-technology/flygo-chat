import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'common.dart';
import 'sigstick.dart';
import 'theme.dart';

/// Kết quả chọn trong bảng biểu cảm.
sealed class Expression {}

class EmojiPick extends Expression {
  final String char;
  EmojiPick(this.char);
}

/// GIF hoặc sticker từ Giphy: [url] là ảnh gửi đi, [sticker] để hiện không nền.
class GifPick extends Expression {
  final String url;
  final bool sticker;
  final double aspect;
  GifPick(this.url, {this.sticker = false, this.aspect = 1});
}

/// Bảng biểu cảm 3 tab vuốt qua lại: Biểu tượng, Sticker, GIF.
/// Chọn emoji thì chèn vào ô soạn (bảng vẫn mở); chọn sticker/GIF thì gửi luôn.
Future<void> showExpressionPanel(BuildContext context,
    {required void Function(String) onEmoji, required void Function(GifPick) onGif}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * .5,
      child: ExpressionPanel(onEmoji: onEmoji, onGif: (g) {
        Navigator.pop(ctx);
        onGif(g);
      }),
    ),
  );
}

class ExpressionPanel extends StatelessWidget {
  final void Function(String) onEmoji;
  final void Function(GifPick) onGif;

  /// Nhóm TapRegion của bảng nổi trên máy tính (để hộp thoại kho sticker không làm đóng bảng).
  final Object? tapGroup;
  const ExpressionPanel({super.key, required this.onEmoji, required this.onGif, this.tapGroup});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        // Thanh tab gọn một dòng: biểu tượng bên trái, tên bên phải.
        TabBar(
          labelColor: pal.accentText,
          unselectedLabelColor: pal.sub,
          indicatorColor: pal.accent,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: pal.divider,
          labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 13.5),
          tabs: [
            for (final (icon, label) in [
              (Icons.emoji_emotions_outlined, tr('Biểu tượng')),
              (Icons.sticky_note_2_outlined, tr('Sticker')),
              (Icons.gif_box_outlined, tr('GIF')),
            ])
              Tab(
                height: 40,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 19),
                  const SizedBox(width: 6),
                  Text(label),
                ]),
              ),
          ],
        ),
        Expanded(
          child: TabBarView(children: [
            GridView.extent(
              maxCrossAxisExtent: 48,
              padding: const EdgeInsets.all(10),
              children: [
                for (final (_, c) in emojiList)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onEmoji(c),
                    child: Center(child: Text(c, style: const TextStyle(fontSize: 28))),
                  ),
              ],
            ),
            _StickerTab(onPick: onGif, tapGroup: tapGroup),
            _GiphyGrid(stickers: false, onPick: onGif),
          ]),
        ),
      ]),
    );
  }
}

/// Tab Sticker: dải chọn nguồn (nút mở kho SigStick, gần đây, GIPHY, các bộ đã thêm) + lưới sticker.
class _StickerTab extends StatefulWidget {
  final void Function(GifPick) onPick;
  final Object? tapGroup;
  const _StickerTab({required this.onPick, this.tapGroup});
  @override
  State<_StickerTab> createState() => _StickerTabState();
}

class _StickerTabState extends State<_StickerTab> with AutomaticKeepAliveClientMixin {
  static const _recent = '#recent', _giphy = '#giphy';

  /// Nguồn đang chọn, nhớ giữa các lần mở bảng.
  static String? _sel;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    StickerPacks.load().then((_) {
      if (mounted) setState(() {});
      StickerPacks.sync(app);
    });
  }

  String _current() {
    final packs = StickerPacks.saved.value;
    final s = _sel;
    if (s == _giphy) return s!;
    if (s == _recent && StickerPacks.recent.value.isNotEmpty) return s!;
    if (s != null && packs.any((p) => p.id == s)) return s;
    if (StickerPacks.recent.value.isNotEmpty) return _recent;
    return packs.isNotEmpty ? packs.first.id : _giphy;
  }

  void _send(String url) {
    StickerPacks.addRecent(url);
    widget.onPick(GifPick(url, sticker: true));
  }

  Widget _source(String id, String tooltip, Widget child, String current, Pal pal) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _sel = id),
            child: Container(
              width: 40,
              height: 40,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: current == id ? pal.surface2 : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: child,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final pal = Pal.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([StickerPacks.saved, StickerPacks.recent]),
      builder: (context, _) {
        final current = _current();
        final packs = StickerPacks.saved.value;
        final pack = packs.where((p) => p.id == current).firstOrNull;
        final List<String>? urls = current == _recent ? StickerPacks.recent.value : pack?.stickers;
        return Column(children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              children: [
                IconButton(
                  tooltip: tr('Thêm sticker'),
                  icon: Icon(Icons.add_circle_outline, color: pal.accentText),
                  onPressed: () => openStickerStore(context, context.read<AppState>(), tapGroup: widget.tapGroup),
                ),
                if (StickerPacks.recent.value.isNotEmpty)
                  _source(_recent, tr('Gần đây'), Icon(Icons.history, color: pal.sub), current, pal),
                _source(_giphy, tr('Sticker GIPHY'), Icon(Icons.gif_box_outlined, color: pal.sub), current, pal),
                for (final p in packs) _source(p.id, p.title, stickerImage(p.cover, size: 30), current, pal),
              ],
            ),
          ),
          Divider(height: 1, color: pal.divider),
          Expanded(
            child: urls == null
                ? _GiphyGrid(stickers: true, onPick: widget.onPick)
                : GridView.builder(
                    key: PageStorageKey('stickers-$current'),
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 88, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: urls.length,
                    itemBuilder: (_, i) => InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _send(urls[i]),
                      child: Padding(padding: const EdgeInsets.all(3), child: stickerImage(urls[i], size: 88)),
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}

class _GiphyGrid extends StatefulWidget {
  final bool stickers;
  final void Function(GifPick) onPick;
  const _GiphyGrid({required this.stickers, required this.onPick});
  @override
  State<_GiphyGrid> createState() => _GiphyGridState();
}

class _GiphyGridState extends State<_GiphyGrid> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  Timer? _debounce;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load(String q) async {
    final key = await context.read<AppState>().giphyKey();
    if (key == null) {
      setState(() {
        _loading = false;
        _error = tr('Máy chủ chưa bật GIF.');
      });
      return;
    }
    setState(() => _loading = true);
    final kind = widget.stickers ? 'stickers' : 'gifs';
    final path = q.trim().isEmpty ? 'trending' : 'search';
    final uri = Uri.https('api.giphy.com', '/v1/$kind/$path', {
      'api_key': key,
      'limit': '48',
      'rating': 'g',
      'lang': 'vi',
      if (q.trim().isNotEmpty) 'q': q.trim(),
    });
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = (jsonDecode(res.body) as Map)['data'] as List;
      if (!mounted) return;
      setState(() {
        _items = [for (final d in data) (d as Map).cast<String, dynamic>()];
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = tr('Không tải được. Kiểm tra kết nối mạng.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final pal = Pal.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: TextField(
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 400), () => _load(v));
          },
          style: TextStyle(color: pal.text),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: pal.surface2,
            hintText: widget.stickers ? tr('Tìm sticker') : tr('Tìm GIF'),
            hintStyle: TextStyle(color: pal.sub),
            prefixIcon: Icon(Icons.search, color: pal.sub, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      Expanded(
        child: _loading
            ? Center(child: CircularProgressIndicator(color: pal.accent))
            : _error != null
                ? Center(child: Text(_error!, style: TextStyle(color: pal.sub)))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final images = (_items[i]['images'] as Map).cast<String, dynamic>();
                      final preview = (images['fixed_width_small'] ?? images['preview_gif'] ?? images['fixed_width']) as Map;
                      final send = (images['fixed_width'] ?? images['downsized'] ?? images['original']) as Map;
                      final w = double.tryParse('${send['width']}') ?? 1;
                      final h = double.tryParse('${send['height']}') ?? 1;
                      return GestureDetector(
                        onTap: () => widget.onPick(GifPick(send['url'] as String, sticker: widget.stickers, aspect: w / h)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            color: widget.stickers ? Colors.transparent : pal.surface2,
                            child: Image.network(preview['url'] as String,
                                fit: widget.stickers ? BoxFit.contain : BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox.shrink()),
                          ),
                        ),
                      );
                    },
                  ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(tr('Cung cấp bởi GIPHY'), style: TextStyle(fontSize: 11, color: pal.sub)),
      ),
    ]);
  }
}
