import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'common.dart';
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
      child: _ExpressionPanel(onEmoji: onEmoji, onGif: (g) {
        Navigator.pop(ctx);
        onGif(g);
      }),
    ),
  );
}

class _ExpressionPanel extends StatelessWidget {
  final void Function(String) onEmoji;
  final void Function(GifPick) onGif;
  const _ExpressionPanel({required this.onEmoji, required this.onGif});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        Container(
          margin: const EdgeInsets.only(top: 8),
          width: 36,
          height: 5,
          decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(3)),
        ),
        TabBar(
          labelColor: pal.accentText,
          unselectedLabelColor: pal.sub,
          indicatorColor: pal.accent,
          dividerColor: pal.divider,
          tabs: const [
            Tab(icon: Icon(Icons.emoji_emotions_outlined), text: 'Biểu tượng'),
            Tab(icon: Icon(Icons.sticky_note_2_outlined), text: 'Sticker'),
            Tab(icon: Icon(Icons.gif_box_outlined), text: 'GIF'),
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
            _GiphyGrid(stickers: true, onPick: onGif),
            _GiphyGrid(stickers: false, onPick: onGif),
          ]),
        ),
      ]),
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
        _error = 'Máy chủ chưa bật GIF.';
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
          _error = 'Không tải được. Kiểm tra kết nối mạng.';
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
            hintText: widget.stickers ? 'Tìm sticker' : 'Tìm GIF',
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
        child: Text('Cung cấp bởi GIPHY', style: TextStyle(fontSize: 11, color: pal.sub)),
      ),
    ]);
  }
}
