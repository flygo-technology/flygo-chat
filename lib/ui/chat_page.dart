import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_info_page.dart';
import 'chat_list.dart';
import 'reactions.dart';
import 'common.dart';
import 'theme.dart';

class ChatPage extends StatefulWidget {
  final String channelId;
  final bool embedded;
  const ChatPage({super.key, required this.channelId, this.embedded = false});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scroll = ScrollController();
  late final AppState _app;
  MmPost? _replyTo;
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.openChannel(widget.channelId);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _app.closeChannel(widget.channelId);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingOlder) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _loadingOlder = true;
      _app.loadOlder(widget.channelId).whenComplete(() => _loadingOlder = false);
    }
  }

  void _openInfo() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatInfoPage(channelId: widget.channelId)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final ch = app.channels[widget.channelId];
    if (ch == null) return Scaffold(backgroundColor: pal.bg, body: const Center(child: CircularProgressIndicator()));
    final title = app.channelTitle(ch);
    final other = app.me == null ? null : ch.otherUserId(app.me!.id);
    final typing = app.typingIn(ch.id);
    final posts = app.postsOf(ch.id);

    final subtitle = typing.isNotEmpty
        ? (ch.isDirect ? 'đang soạn tin...' : '${typing.join(', ')} đang soạn tin...')
        : (ch.isDirect ? 'nhấn để xem thông tin liên lạc' : 'nhấn để xem thông tin nhóm');

    final header = Glass(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Row(children: [
            if (!widget.embedded) ...[
              GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.maybePop(context)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openInfo,
                child: Row(children: [
                  Avatar(userId: other, name: title, size: 42, icon: other == null ? Icons.groups : null),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: typing.isNotEmpty ? pal.accentText : pal.sub)),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            _HeaderPill(children: [
              if (ch.isDirect || ch.isGroupDm)
                IconButton(
                  icon: Icon(Icons.call_outlined, color: pal.text),
                  tooltip: 'Gọi thoại',
                  onPressed: app.calls.busy ? null : () => app.calls.startCall(ch.id),
                ),
              IconButton(
                icon: Icon(Icons.search, color: pal.text),
                tooltip: 'Tìm trong cuộc trò chuyện',
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => searchInChannel(context, ch.id))),
              ),
            ]),
          ]),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: pal.chatBg,
      body: Column(children: [
        header,
        const OfflineBanner(),
        Expanded(
          child: DoodleBackground(
            child: posts.isEmpty
                ? const Center(child: _EmptyChat())
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: posts.length,
                    itemBuilder: (context, i) {
                      final p = posts[i];
                      final older = i + 1 < posts.length ? posts[i + 1] : null;
                      final newer = i > 0 ? posts[i - 1] : null;
                      final showDay = older == null || !sameDay(older.createAt, p.createAt);
                      final firstInGroup = showDay ||
                          older.userId != p.userId ||
                          older.isSystem ||
                          p.createAt - older.createAt > 5 * 60 * 1000;
                      final lastInGroup = newer == null ||
                          newer.userId != p.userId ||
                          newer.isSystem ||
                          !sameDay(newer.createAt, p.createAt) ||
                          newer.createAt - p.createAt > 5 * 60 * 1000;
                      return Column(children: [
                        if (showDay) _DayChip(DateTime.fromMillisecondsSinceEpoch(p.createAt)),
                        p.isSystem
                            ? _SystemChip(p.message)
                            : _Bubble(
                                post: p,
                                channel: ch,
                                first: firstInGroup,
                                last: lastInGroup,
                                onReply: () => setState(() => _replyTo = p),
                              ),
                      ]);
                    },
                  ),
          ),
        ),
        Container(
          color: pal.chatBg,
          child: _Composer(
            channelId: ch.id,
            replyTo: _replyTo,
            onCancelReply: () => setState(() => _replyTo = null),
            onSent: () {
              setState(() => _replyTo = null);
              if (_scroll.hasClients) _scroll.jumpTo(0);
            },
          ),
        ),
      ]),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final List<Widget> children;
  const _HeaderPill({required this.children});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: pal.text.withValues(alpha: .08)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(14)),
      child: Text('Chưa có tin nhắn. Hãy gửi lời chào đầu tiên 👋',
          textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
    );
  }
}

class _DayChip extends StatelessWidget {
  final DateTime d;
  const _DayChip(this.d);
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(10)),
        child: Text(dayLabel(d), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: pal.sub)),
      ),
    );
  }
}

class _SystemChip extends StatelessWidget {
  final String text;
  const _SystemChip(this.text);
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 40),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(10)),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: pal.sub)),
      ),
    );
  }
}

// ------------------------------------------------------------------ bong bóng tin nhắn
class _Bubble extends StatelessWidget {
  final MmPost post;
  final MmChannel channel;
  final bool first;
  final bool last;
  final VoidCallback onReply;
  const _Bubble({required this.post, required this.channel, required this.first, required this.last, required this.onReply});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final mine = post.userId == app.me?.id;
    final showName = !mine && first && !channel.isDirect;
    final sender = app.users[post.userId];
    final width = MediaQuery.sizeOf(context).width;
    final maxW = width > 900 ? width * .5 : width * .8;
    final root = post.rootId.isEmpty ? null : app.findPost(post.channelId, post.rootId);
    final reactions = post.reactions;
    final bubbleColor = mine ? pal.outBubble : pal.inBubble;
    final metaColor = pal.text.withValues(alpha: .55);
    final time = hhmm(DateTime.fromMillisecondsSinceEpoch(post.createAt));
    final meta = Row(mainAxisSize: MainAxisSize.min, children: [
      if (post.editAt > 0) Text('Đã sửa  ', style: TextStyle(fontSize: 12, color: metaColor, fontStyle: FontStyle.italic)),
      Text(time, style: TextStyle(fontSize: 12, color: metaColor)),
      if (mine) ...[const SizedBox(width: 3), statusIcon(post, app, pal, size: 16)],
    ]);
    final metaWidth = (post.editAt > 0 ? 52.0 : 0) + (mine ? 62.0 : 42.0);

    const r = Radius.circular(18);
    const tailR = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: !mine && last ? tailR : r,
      bottomRight: mine && last ? tailR : r,
    );

    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (showName)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text('~${sender?.displayName ?? 'Người dùng'}',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WaColors.sender(post.userId))),
        ),
      if (post.rootId.isNotEmpty) _Quote(root: root, mine: mine),
      for (final f in post.files) _FileView(file: f),
      if (post.message.isNotEmpty)
        Stack(children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: SelectableText.rich(
              TextSpan(children: [..._linkify(post.message, pal), WidgetSpan(child: SizedBox(width: metaWidth, height: 12))]),
              style: TextStyle(fontSize: 17, color: pal.text, height: 1.3),
            ),
          ),
          Positioned(right: 0, bottom: 0, child: meta),
        ])
      else
        Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(top: 3), child: meta)),
    ]);

    Widget bubble = GestureDetector(
      onLongPress: () => _actions(context, app, mine),
      onSecondaryTap: () => _actions(context, app, mine),
      onDoubleTap: post.sendState == SendState.sent ? () => app.toggleReaction(post, '+1') : null,
      onTap: post.sendState == SendState.failed ? () => _failedActions(context, app) : null,
      child: CustomPaint(
        painter: last ? _TailPainter(color: bubbleColor, mine: mine) : null,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxW),
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          decoration: BoxDecoration(color: bubbleColor, borderRadius: radius),
          child: content,
        ),
      ),
    );

    if (reactions.isNotEmpty) {
      final total = reactions.values.fold<int>(0, (a, b) => a + b.length);
      bubble = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          Transform.translate(
            offset: const Offset(0, -6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: GestureDetector(
                onTap: () => showReactionDetails(context, app, post),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: pal.surface2,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: pal.chatBg, width: 2),
                  ),
                  child: Text([...reactions.keys.take(3).map(emojiOf), if (total > 1) ' $total'].join(),
                      style: TextStyle(fontSize: 15, color: pal.text)),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: 14, right: 14, top: first ? 8 : 2),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: post.sendState == SendState.sent && _isDesktop(context)
            ? _HoverReact(mine: mine, onReact: () => _actions(context, app, mine), child: bubble)
            : bubble,
      ),
    );
  }

  void _actions(BuildContext context, AppState app, bool mine) {
    if (post.sendState != SendState.sent && post.sendState != SendState.failed) return;
    showMessageMenu(
      context: context,
      app: app,
      post: post,
      mine: mine,
      actions: [
        if (post.sendState == SendState.sent) MenuAction(Icons.reply, 'Trả lời', onReply),
        if (post.message.isNotEmpty)
          MenuAction(Icons.copy, 'Sao chép', () {
            Clipboard.setData(ClipboardData(text: post.message));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã sao chép')));
          }),
        if (post.reactions.isNotEmpty)
          MenuAction(Icons.emoji_emotions_outlined, 'Xem cảm xúc', () => showReactionDetails(context, app, post)),
        if (mine && post.sendState == SendState.sent)
          MenuAction(Icons.delete_outline, 'Xóa', danger: true, () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                title: const Text('Xóa tin nhắn này?'),
                content: const Text('Tin nhắn sẽ bị xóa với mọi người trong cuộc trò chuyện.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Hủy')),
                  TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Xóa')),
                ],
              ),
            );
            if (ok == true) app.deletePost(post);
          }),
      ],
    );
  }

  void _failedActions(BuildContext context, AppState app) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Tin nhắn chưa gửi được', style: TextStyle(fontWeight: FontWeight.w600))),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Gửi lại'),
            onTap: () {
              Navigator.pop(ctx);
              app.retry(post);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Bỏ tin này'),
            onTap: () {
              Navigator.pop(ctx);
              app.discard(post);
            },
          ),
        ]),
      ),
    );
  }
}

bool _isDesktop(BuildContext context) => const {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(Theme.of(context).platform);

/// Trên máy tính: rê chuột vào tin nhắn thì hiện nút thả cảm xúc bên cạnh.
class _HoverReact extends StatefulWidget {
  final bool mine;
  final VoidCallback onReact;
  final Widget child;
  const _HoverReact({required this.mine, required this.onReact, required this.child});
  @override
  State<_HoverReact> createState() => _HoverReactState();
}

class _HoverReactState extends State<_HoverReact> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final button = AnimatedOpacity(
      opacity: _hover ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: GlassCircle(
          icon: Icons.add_reaction_outlined,
          size: 32,
          color: pal.surface,
          iconColor: pal.sub,
          tooltip: 'Thả cảm xúc',
          onTap: _hover ? widget.onReact : null,
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.mine) button,
        Flexible(child: widget.child),
        if (!widget.mine) button,
      ]),
    );
  }
}

/// Đuôi nhỏ ở góc dưới của bong bóng cuối nhóm, giống WhatsApp iOS.
class _TailPainter extends CustomPainter {
  final Color color;
  final bool mine;
  _TailPainter({required this.color, required this.mine});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final path = Path();
    final b = size.height;
    if (mine) {
      final x = size.width;
      path
        ..moveTo(x - 14, b)
        ..quadraticBezierTo(x - 2, b, x + 6, b)
        ..quadraticBezierTo(x - 2, b - 4, x - 2, b - 14)
        ..close();
    } else {
      path
        ..moveTo(14, b)
        ..quadraticBezierTo(2, b, -6, b)
        ..quadraticBezierTo(2, b - 4, 2, b - 14)
        ..close();
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color || old.mine != mine;
}

final _urlRe = RegExp(r'https?://[^\s<>()]+');

/// Chữ thường, link bấm được, @tên được tô màu.
List<InlineSpan> _linkify(String text, Pal pal) {
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in _urlRe.allMatches(text)) {
    if (m.start > i) spans.addAll(_mentions(text.substring(i, m.start), pal));
    final url = m.group(0)!;
    spans.add(TextSpan(
      text: url,
      style: TextStyle(color: pal.tick, decoration: TextDecoration.underline, decorationColor: pal.tick),
      mouseCursor: SystemMouseCursors.click,
      recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    ));
    i = m.end;
  }
  if (i < text.length) spans.addAll(_mentions(text.substring(i), pal));
  return spans;
}

final _mentionRe = RegExp(r'@[a-z0-9._-]+', caseSensitive: false);
List<InlineSpan> _mentions(String text, Pal pal) {
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in _mentionRe.allMatches(text)) {
    if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
    spans.add(TextSpan(text: m.group(0), style: TextStyle(color: pal.tick, fontWeight: FontWeight.w500)));
    i = m.end;
  }
  if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
  return spans;
}

class _Quote extends StatelessWidget {
  final MmPost? root;
  final bool mine;
  const _Quote({required this.root, required this.mine});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final r = root;
    final name = r == null ? '' : (r.userId == app.me?.id ? 'Bạn' : app.users[r.userId]?.displayName ?? '');
    final color = r == null ? pal.sub : (r.userId == app.me?.id ? pal.accentText : WaColors.sender(r.userId));
    return Container(
      margin: const EdgeInsets.only(bottom: 6, top: 2),
      decoration: BoxDecoration(color: mine ? pal.quoteOut : pal.quoteIn, borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 4, color: color),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 12, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (name.isNotEmpty) Text(name, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 15)),
                Text(r == null ? 'Tin nhắn gốc' : app.previewText(r),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: pal.text.withValues(alpha: .75), fontSize: 14.5)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _FileView extends StatelessWidget {
  final MmFile file;
  const _FileView({required this.file});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    if (file.isImage) {
      final aspect = file.width > 0 && file.height > 0 ? file.width / file.height : 4 / 3;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 2),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageViewer(file: file))),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300, maxHeight: 360),
              child: AspectRatio(
                aspectRatio: aspect.clamp(.5, 2.5),
                child: Image.network(app.api.previewUrl(file.id),
                    headers: app.api.headers,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Container(color: pal.surface2, child: Center(child: Icon(Icons.image_not_supported, color: pal.sub)))),
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 4, top: 2),
      width: 280,
      decoration: BoxDecoration(color: pal.text.withValues(alpha: .06), borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.insert_drive_file, color: Color(0xFF7C83F2), size: 34),
        title: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, color: pal.text)),
        subtitle: Text(fileSize(file.size), style: TextStyle(color: pal.sub)),
        trailing: Icon(Icons.download, color: pal.sub),
        onTap: () => openFile(context, file),
      ),
    );
  }
}

Future<void> openFile(BuildContext context, MmFile file) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text('Đang tải ${file.name}...')));
  try {
    final f = await app.download(file);
    await launchUrl(Uri.file(f.path));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Không tải được file. Kiểm tra kết nối mạng.')));
  }
}

class ImageViewer extends StatelessWidget {
  final MmFile file;
  const ImageViewer({super.key, required this.file});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(file.name, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Tải về',
            onPressed: () async {
              final f = await app.download(file);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Đã lưu: ${f.path}')));
              }
            },
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(child: Image.network(app.api.fileUrl(file.id), headers: app.api.headers)),
      ),
    );
  }
}

// ------------------------------------------------------------------ ô soạn tin
final _emojiPalette = [for (final (_, c) in emojiList) c];

class _Composer extends StatefulWidget {
  final String channelId;
  final MmPost? replyTo;
  final VoidCallback onCancelReply;
  final VoidCallback onSent;
  const _Composer({required this.channelId, this.replyTo, required this.onCancelReply, required this.onSent});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  DateTime _lastTyping = DateTime(2000);
  bool _uploading = false;

  bool get _desktop =>
      Theme.of(context).platform == TargetPlatform.macOS ||
      Theme.of(context).platform == TargetPlatform.windows ||
      Theme.of(context).platform == TargetPlatform.linux;

  @override
  void didUpdateWidget(covariant _Composer old) {
    super.didUpdateWidget(old);
    if (widget.replyTo != null && widget.replyTo != old.replyTo) _focus.requestFocus();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _rootId {
    final r = widget.replyTo;
    return r == null ? '' : (r.rootId.isNotEmpty ? r.rootId : r.id);
  }

  void _send() {
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    context.read<AppState>().send(widget.channelId, text, rootId: _rootId);
    _ctl.clear();
    setState(() {});
    widget.onSent();
  }

  Future<void> _attach({bool images = false}) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(type: images ? FileType.image : FileType.any);
    if (files.isEmpty) return;
    if (!app.online) {
      messenger.showSnackBar(const SnackBar(content: Text('Cần có mạng để gửi file.')));
      return;
    }
    setState(() => _uploading = true);
    try {
      final ids = <String>[];
      for (final f in files.take(10)) {
        ids.addAll(await app.upload(widget.channelId, f.name, await f.xFile.readAsBytes()));
      }
      await app.send(widget.channelId, _ctl.text.trim(), rootId: _rootId, fileIds: ids);
      _ctl.clear();
      widget.onSent();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Gửi file không thành công.')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _emoji() {
    final pal = Pal.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: GridView.count(
          crossAxisCount: 8,
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          children: [
            for (final e in _emojiPalette)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  final sel = _ctl.selection;
                  final t = _ctl.text;
                  final start = sel.isValid ? sel.start : t.length;
                  final end = sel.isValid ? sel.end : t.length;
                  _ctl.value = TextEditingValue(
                    text: t.replaceRange(start, end, e),
                    selection: TextSelection.collapsed(offset: start + e.length),
                  );
                  setState(() {});
                },
                child: Center(child: Text(e, style: TextStyle(fontSize: 28, color: pal.text))),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final r = widget.replyTo;
    final hasText = _ctl.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (r != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6, left: 54, right: 54),
              decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(14)),
              clipBehavior: Clip.antiAlias,
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(width: 4, color: WaColors.sender(r.userId)),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.userId == app.me?.id ? 'Bạn' : app.users[r.userId]?.displayName ?? '',
                            style: TextStyle(color: WaColors.sender(r.userId), fontWeight: FontWeight.w600, fontSize: 13.5)),
                        Text(app.previewText(r),
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13.5)),
                      ]),
                    ),
                  ),
                  IconButton(icon: Icon(Icons.close, size: 18, color: pal.sub), onPressed: widget.onCancelReply),
                ]),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _uploading
                ? SizedBox(
                    width: 46,
                    height: 46,
                    child: Padding(
                        padding: const EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent)))
                : GlassCircle(icon: Icons.add, size: 46, tooltip: 'Đính kèm file', onTap: _attach),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 46),
                decoration: BoxDecoration(
                  color: pal.surface,
                  borderRadius: BorderRadius.circular(23),
                  border: Border.all(color: pal.text.withValues(alpha: .06)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, e) {
                        if (_desktop &&
                            e is KeyDownEvent &&
                            e.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _send();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _ctl,
                        focusNode: _focus,
                        autofocus: _desktop,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        style: TextStyle(fontSize: 17, color: pal.text),
                        decoration: InputDecoration(
                          hintText: 'Nhắn tin',
                          hintStyle: TextStyle(color: pal.sub),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onChanged: (_) {
                          setState(() {});
                          if (DateTime.now().difference(_lastTyping).inSeconds >= 3) {
                            _lastTyping = DateTime.now();
                            app.notifyTyping(widget.channelId);
                          }
                        },
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.sentiment_satisfied_alt_outlined, color: pal.text.withValues(alpha: .85)),
                    tooltip: 'Biểu tượng cảm xúc',
                    onPressed: _emoji,
                  ),
                ]),
              ),
            ),
            if (!hasText) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.photo_camera_outlined, color: pal.text, size: 27),
                tooltip: 'Gửi ảnh',
                onPressed: () => _attach(images: true),
              ),
            ],
            const SizedBox(width: 4),
            Material(
              color: pal.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: hasText ? _send : null,
                child: const SizedBox(width: 46, height: 46, child: Icon(Icons.send_rounded, color: Colors.black, size: 22)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
