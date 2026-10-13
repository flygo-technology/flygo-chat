import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Chọn các cuộc trò chuyện để chuyển tiếp tin nhắn (tối đa 5, giống WhatsApp).
class ForwardPage extends StatefulWidget {
  final MmPost post;
  const ForwardPage({super.key, required this.post});
  @override
  State<ForwardPage> createState() => _ForwardPageState();
}

class _ForwardPageState extends State<ForwardPage> {
  final Set<String> _picked = {};
  String _q = '';
  bool _sending = false;

  Future<void> _send() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await app.forward(widget.post, _picked.toList());
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text(tr('Đã chuyển tiếp tới {0} cuộc trò chuyện', [_picked.length]))));
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text(tr('Chuyển tiếp không thành công. Kiểm tra kết nối mạng.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final q = _q.toLowerCase();
    final chats = app.chats.where((c) => q.isEmpty || c.title.toLowerCase().contains(q)).toList();
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              GlassCircle(icon: Icons.close, onTap: () => Navigator.pop(context)),
              Expanded(
                child: Text(tr('Chuyển tiếp tới...'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              const SizedBox(width: 44),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: TextStyle(color: pal.text),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: pal.surface,
                hintText: tr('Tìm kiếm'),
                hintStyle: TextStyle(color: pal.sub),
                prefixIcon: Icon(Icons.search, size: 20, color: pal.sub),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: chats.length,
              itemBuilder: (_, i) {
                final c = chats[i];
                final on = _picked.contains(c.channel.id);
                return ListTile(
                  leading: Avatar(userId: c.avatarUserId, name: c.title, size: 44, icon: c.avatarUserId == null ? (c.channel.isSelfDm ? Icons.cloud : Icons.groups) : null),
                  title: Text(c.title, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                  trailing: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: on ? pal.accent : pal.sub, size: 26),
                  onTap: () => setState(() {
                    if (on) {
                      _picked.remove(c.channel.id);
                    } else if (_picked.length < 5) {
                      _picked.add(c.channel.id);
                    } else {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(tr('Chỉ chuyển tiếp tối đa 5 cuộc trò chuyện một lần'))));
                    }
                  }),
                );
              },
            ),
          ),
          if (_picked.isNotEmpty)
            Container(
              color: pal.surface,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _picked.map((id) => app.channels[id] == null ? '' : app.channelTitle(app.channels[id]!)).join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: pal.text),
                  ),
                ),
                const SizedBox(width: 10),
                _sending
                    ? SizedBox(width: 48, height: 48, child: Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(color: pal.accent, strokeWidth: 2)))
                    : Material(
                        color: pal.accent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _send,
                          child: const SizedBox(width: 48, height: 48, child: Icon(Icons.send_rounded, color: Colors.black)),
                        ),
                      ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Phát video đính kèm (tải trực tiếp từ máy chủ, có xác thực).
class VideoPlayerPage extends StatefulWidget {
  final MmFile file;
  const VideoPlayerPage({super.key, required this.file});
  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerController _v;
  String? _err;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _v = VideoPlayerController.networkUrl(Uri.parse(app.api.fileUrl(widget.file.id)), httpHeaders: app.api.headers)
      ..initialize().then((_) {
        _v.play();
        setState(() {});
      }).catchError((_) => setState(() => _err = tr('Không phát được video')));
    _v.addListener(() => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EscToPop(child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.file.name, style: const TextStyle(fontSize: 16)),
      ),
      body: Center(
        child: _err != null
            ? Text(_err!, style: const TextStyle(color: Colors.white70))
            : !_v.value.isInitialized
                ? const CircularProgressIndicator(color: Colors.white)
                : GestureDetector(
                    onTap: () => _v.value.isPlaying ? _v.pause() : _v.play(),
                    child: Stack(alignment: Alignment.center, children: [
                      AspectRatio(aspectRatio: _v.value.aspectRatio, child: VideoPlayer(_v)),
                      if (!_v.value.isPlaying) const Icon(Icons.play_circle_fill, color: Colors.white70, size: 72),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: VideoProgressIndicator(_v, allowScrubbing: true, padding: const EdgeInsets.all(12)),
                      ),
                    ]),
                  ),
      ),
    ));
  }
}
