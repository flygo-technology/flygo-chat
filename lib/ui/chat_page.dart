import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'attach_panel.dart';
import 'chat_info_page.dart';
import 'expression_panel.dart';
import 'chat_list.dart';
import 'forward_page.dart';
import 'home_page.dart' show ChatHost;
import 'markdown_view.dart';
import 'media_picker.dart';
import 'media_view.dart';
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
  MmPost? _editing;
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

  bool _showDown = false;

  void _onScroll() {
    final down = _scroll.position.pixels > 600;
    if (down != _showDown) setState(() => _showDown = down);
    if (_loadingOlder) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _loadingOlder = true;
      _app.loadOlder(widget.channelId).whenComplete(() => _loadingOlder = false);
    }
  }

  void _openInfo() {
    final host = ChatHost.of(context);
    if (host != null) return host.openInfo(widget.channelId);
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
        ? (ch.isDirect ? tr('đang soạn tin...') : tr('{0} đang soạn tin...', [typing.join(', ')]))
        : ch.header.trim().isNotEmpty
            ? plainPreview(ch.header)
            : (ch.isDirect ? tr('nhấn để xem thông tin liên lạc') : tr('nhấn để xem thông tin nhóm'));
    final subtitleIsHeader = typing.isEmpty && ch.header.trim().isNotEmpty;

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
                  ch.isSelfDm
                      ? const Avatar(name: '', size: 42, icon: Icons.cloud)
                      : Avatar(userId: other, name: title, size: 42, icon: other == null ? Icons.groups : null),
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
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: subtitleIsHeader ? FontWeight.w600 : FontWeight.normal,
                              color: typing.isNotEmpty || subtitleIsHeader ? pal.accentText : pal.sub)),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            _HeaderPill(children: [
              IconButton(
                tooltip: tr('Công việc'),
                icon: Badge(
                  isLabelVisible: app.openTodosIn(ch.id) > 0,
                  backgroundColor: pal.accent,
                  textColor: Colors.black,
                  label: Text('${app.openTodosIn(ch.id)}'),
                  child: Icon(Icons.task_alt, color: pal.text),
                ),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TasksPage(channelId: ch.id))),
              ),
              IconButton(
                tooltip: tr('Cài đặt cuộc trò chuyện'),
                icon: Icon(Icons.grid_view_rounded, color: pal.text),
                onPressed: _openInfo,
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
        if (ch.banner != null) _ChannelBanner(banner: ch.banner!),
        if (app.pinnedIn(ch.id).isNotEmpty) _PinnedBanner(channelId: ch.id),
        const OfflineBanner(),
        Expanded(
          child: DoodleBackground(
            child: Stack(children: [
              Positioned.fill(child: posts.isEmpty
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
                            : p.isCall
                                ? _CallCard(post: p, channel: ch)
                                : _Bubble(
                                post: p,
                                channel: ch,
                                first: firstInGroup,
                                last: lastInGroup,
                                onReply: () => setState(() => _replyTo = p),
                                onEdit: (p) => setState(() {
                                  _editing = p;
                                  _replyTo = null;
                                }),
                              ),
                      ]);
                    },
                  )),
              if (_showDown)
                Positioned(
                  right: 14,
                  bottom: 12,
                  child: Material(
                    color: pal.surface,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(Icons.keyboard_double_arrow_down_rounded, color: pal.text),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        Container(
          color: pal.chatBg,
          child: _Composer(
            channelId: ch.id,
            replyTo: _replyTo,
            editing: _editing,
            onCancelEdit: () => setState(() => _editing = null),
            onCancelReply: () => setState(() => _replyTo = null),
            onSent: () {
              setState(() {
                _replyTo = null;
                _editing = null;
              });
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
      child: Text(tr('Chưa có tin nhắn. Hãy gửi lời chào đầu tiên 👋'),
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
final _gifRe = RegExp(r'^!\[[^\]]*\]\((https?://\S+?)\)$');

class _Bubble extends StatelessWidget {
  final MmPost post;
  final MmChannel channel;
  final bool first;
  final bool last;
  final VoidCallback onReply;
  final void Function(MmPost) onEdit;
  const _Bubble(
      {required this.post, required this.channel, required this.first, required this.last, required this.onReply, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final mine = post.userId == app.me?.id;
    final showName = !mine && first && !channel.isDirect;
    final sender = app.users[post.userId];
    if (post.isRecalled) {
      return Padding(
        padding: EdgeInsets.only(left: 14, right: 14, top: first ? 8 : 2),
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: pal.surface2.withValues(alpha: .7),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: pal.divider),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.block, size: 15, color: pal.sub),
              const SizedBox(width: 6),
              Text(mine ? tr('Bạn đã thu hồi một tin nhắn') : tr('Tin nhắn đã được thu hồi'),
                  style: TextStyle(fontSize: 14.5, fontStyle: FontStyle.italic, color: pal.sub)),
              const SizedBox(width: 8),
              Text(hhmm(DateTime.fromMillisecondsSinceEpoch(post.createAt)), style: TextStyle(fontSize: 11.5, color: pal.sub)),
            ]),
          ),
        ),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    final maxW = width > 900 ? width * .5 : width * .8;
    final root = post.rootId.isEmpty ? null : app.findPost(post.channelId, post.rootId);
    final reactions = post.reactions;
    final bubbleColor = mine ? pal.outBubble : pal.inBubble;
    final metaColor = pal.text.withValues(alpha: .55);
    final time = hhmm(DateTime.fromMillisecondsSinceEpoch(post.createAt));
    Widget metaIn(Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
          if (post.editAt > 0) ...[Icon(Icons.edit, size: 12, color: c), const SizedBox(width: 4)],
          Text(time, style: TextStyle(fontSize: 12, color: c)),
          if (mine) ...[const SizedBox(width: 3), statusIcon(post, app, pal, size: 16)],
        ]);
    final meta = metaIn(metaColor);
    final gif = _gifRe.firstMatch(post.message.trim());
    final images = gif != null
        ? [ChatImage(url: gif.group(1), aspect: (post.props['dnd_media_aspect'] as num?)?.toDouble() ?? 1)]
        : imagesOf(post);
    final isSticker = post.props['dnd_sticker'] == true;
    final sendingMedia = post.sendState == SendState.sending && post.localFiles.isNotEmpty;
    final imagesOnly = images.isNotEmpty &&
        (post.message.isEmpty || gif != null) &&
        post.rootId.isEmpty &&
        !post.isForwarded &&
        post.priority.isEmpty &&
        !post.isBurnOnRead &&
        post.files.where((f) => !f.isImage).isEmpty &&
        post.localFiles.where((f) => !(f['mime'] as String? ?? '').startsWith('image/')).isEmpty;
    final metaWidth = (post.editAt > 0 ? 18.0 : 0) + (mine ? 62.0 : 42.0);

    const r = Radius.circular(18);
    const tailR = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: !mine && last ? tailR : r,
      bottomRight: mine && last ? tailR : r,
    );

    final textStyle = TextStyle(fontSize: 17, color: pal.text, height: 1.3);
    final bor = post.isBurnOnRead;
    final hidden = bor && !mine && post.raw['_revealed_at'] == null && post.message.isEmpty;
    final long = post.message.length > 700 || '\n'.allMatches(post.message).length > 14;
    final collapsed = long && !app.expanded.contains(post.id);

    Widget body;
    if (hidden) {
      body = GestureDetector(
        onTap: () => app.reveal(post).catchError((_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Không mở được tin. Tin có thể đã tự hủy.'))));
          }
        }),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(TextSpan(children: [
            const TextSpan(text: '🔥 '),
            TextSpan(text: tr('Tin nhắn tự hủy · Nhấn để xem'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
            WidgetSpan(child: SizedBox(width: metaWidth, height: 12)),
          ]), style: textStyle),
        ),
      );
    } else if (post.message.isEmpty) {
      body = const SizedBox.shrink();
    } else if (!app.renderMarkdown) {
      body = Text.rich(TextSpan(children: [TextSpan(text: post.message), WidgetSpan(child: SizedBox(width: metaWidth, height: 12))]),
          style: textStyle);
    } else if (MarkdownView.isSimple(post.message)) {
      body = Text.rich(
        TextSpan(children: [..._linkify(post.message, pal), WidgetSpan(child: SizedBox(width: metaWidth, height: 12))]),
        style: textStyle,
      );
    } else {
      body = MarkdownView(text: post.message, style: textStyle, trailingSpace: metaWidth);
    }
    if (collapsed) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0, .8, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320), child: ClipRect(child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: body))),
        ),
        GestureDetector(
          onTap: () => app.expand(post.id),
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(tr('Xem thêm'), style: TextStyle(color: pal.tick, fontWeight: FontWeight.w600, fontSize: 15.5)),
          ),
        ),
      ]);
    }

    final acks = post.ackUserIds;
    final iAcked = acks.contains(app.me?.id);
    final revealedAt = post.raw['_revealed_at'] as int?;
    final readMs = (post.props['read_duration'] as num?)?.toInt() ?? 600000;

    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (showName)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: GestureDetector(
            onTap: sender == null ? null : () => openDirectWith(context, app, sender),
            child: Text('~${sender?.displayName ?? 'Người dùng'}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WaColors.sender(post.userId))),
          ),
        ),
      if (post.priority.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(post.priority == 'urgent' ? tr('🚨 KHẨN CẤP') : tr('❗ QUAN TRỌNG'),
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .4,
                  color: post.priority == 'urgent' ? Colors.redAccent : const Color(0xFFF5A623))),
        ),
      if (post.isForwarded)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shortcut, size: 15, color: pal.sub),
            const SizedBox(width: 4),
            Text(tr('Đã chuyển tiếp'), style: TextStyle(fontSize: 13.5, fontStyle: FontStyle.italic, color: pal.sub)),
          ]),
        ),
      if (bor && mine)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(tr('🔥 Tự hủy sau khi đọc'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: pal.sub)),
        ),
      if (post.rootId.isNotEmpty) _Quote(root: root, mine: mine),
      if (!hidden && images.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 2),
          child: ChatMedia(post: post, images: images, sending: sendingMedia, maxWidth: maxW - 22),
        ),
      if (!hidden)
        for (final f in post.files.where((f) => !f.isImage)) _FileView(file: f),
      if (!hidden)
        for (final f in post.localFiles.where((f) => !(f['mime'] as String? ?? '').startsWith('image/')))
          Container(
            margin: const EdgeInsets.only(bottom: 4, top: 2),
            width: 260,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: pal.text.withValues(alpha: .06), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.insert_drive_file, color: pal.sub),
              const SizedBox(width: 8),
              Expanded(child: Text(f['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text))),
              if (post.sendState == SendState.sending)
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: pal.sub)),
            ]),
          ),
      if (post.message.isNotEmpty || hidden)
        Stack(children: [
          Padding(padding: const EdgeInsets.only(bottom: 2), child: body),
          Positioned(right: 0, bottom: 0, child: meta),
        ])
      else
        Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(top: 3), child: meta)),
      if (revealedAt != null && !mine) _BurnCountdown(until: revealedAt + readMs),
      if (post.requestedAck)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: mine || iAcked
              ? Text(
                  mine ? tr('✓ {0} người đã xác nhận đã đọc', [acks.length]) : tr('✓ Bạn đã xác nhận đã đọc'),
                  style: TextStyle(fontSize: 13, color: pal.accentText, fontWeight: FontWeight.w600),
                )
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: pal.accentText,
                    side: BorderSide(color: pal.accentText),
                    shape: const StadiumBorder(),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => app.acknowledge(post),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(tr('Xác nhận đã đọc')),
                ),
        ),
    ]);

    final bubbleKey = GlobalKey();
    Widget bubble = GestureDetector(
      key: bubbleKey,
      onLongPress: () => _actions(context, app, mine, anchor: _rectOf(bubbleKey)),
      onSecondaryTap: () => _actions(context, app, mine, anchor: _rectOf(bubbleKey)),
      onDoubleTap: post.sendState == SendState.sent ? () => app.toggleReaction(post, 'heart') : null,
      onTap: post.sendState == SendState.failed ? () => _failedActions(context, app) : null,
      child: imagesOnly
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3, left: 4),
                  child: GestureDetector(
                    onTap: sender == null ? null : () => openDirectWith(context, app, sender),
                    child: Text('~${sender?.displayName ?? 'Người dùng'}',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WaColors.sender(post.userId))),
                  ),
                ),
              ChatMedia(
                  post: post,
                  images: images,
                  sending: sendingMedia,
                  maxWidth: isSticker ? 150 : maxW,
                  sticker: isSticker,
                  overlay: metaIn(Colors.white)),
            ])
          : CustomPaint(
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

    final row = Padding(
      padding: EdgeInsets.only(left: 14, right: 14, top: first ? 8 : 2),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: post.sendState == SendState.sent && _isDesktop(context)
            ? _HoverReact(mine: mine, onReact: () => _actions(context, app, mine, anchor: _rectOf(bubbleKey)), child: bubble)
            : bubble,
      ),
    );
    return post.sendState == SendState.sent ? _SwipeToReply(onReply: onReply, child: row) : row;
  }

  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _actions(BuildContext context, AppState app, bool mine, {Rect? anchor}) {
    if (post.sendState != SendState.sent && post.sendState != SendState.failed) return;
    showMessageMenu(
      context: context,
      app: app,
      post: post,
      mine: mine,
      anchor: anchor,
      actions: [
        if (post.sendState == SendState.sent) MenuAction(Icons.reply, tr('Trả lời'), onReply),
        if (mine && post.sendState == SendState.sent && post.message.isNotEmpty && !post.isBurnOnRead)
          MenuAction(Icons.edit_outlined, tr('Sửa'), () => onEdit(post)),
        if (post.sendState == SendState.sent)
          MenuAction(post.isPinned ? Icons.push_pin : Icons.push_pin_outlined, post.isPinned ? tr('Bỏ ghim') : 'Ghim',
              () => app.setPinned(post, !post.isPinned).catchError((_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Không ghim được tin này.'))));
                    }
                  })),
        if (post.sendState == SendState.sent && post.message.isNotEmpty)
          MenuAction(Icons.add_task, tr('Tạo việc từ tin này'), () {
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CreateTaskPage(
                    channelId: post.channelId, initialTitle: plainPreview(post.message).characters.take(80).toString())));
          }),
        if (post.sendState == SendState.sent && !post.isBurnOnRead)
          MenuAction(Icons.shortcut, tr('Chuyển tiếp'), () {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => ForwardPage(post: post)));
          }),
        if (post.files.any((f) => f.isImage || f.isVideo) && !post.isBurnOnRead)
          MenuAction(Icons.download, tr('Tải xuống'), () => saveMedia(context, post.files.where((f) => f.isImage || f.isVideo).toList())),
        if (post.message.isNotEmpty)
          MenuAction(Icons.copy, tr('Sao chép'), () {
            Clipboard.setData(ClipboardData(text: post.message));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Đã sao chép'))));
          }),
        if (post.reactions.isNotEmpty)
          MenuAction(Icons.emoji_emotions_outlined, tr('Xem cảm xúc'), () => showReactionDetails(context, app, post)),
        if (mine && post.sendState == SendState.sent)
          MenuAction(Icons.undo, tr('Thu hồi'), danger: true, () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                title: Text(tr('Thu hồi tin nhắn này?')),
                content: Text(tr('Mọi người trong cuộc trò chuyện sẽ thấy "Tin nhắn đã được thu hồi".')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
                  TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Thu hồi'))),
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
          ListTile(title: Text(tr('Tin nhắn chưa gửi được'), style: TextStyle(fontWeight: FontWeight.w600))),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(tr('Gửi lại')),
            onTap: () {
              Navigator.pop(ctx);
              app.retry(post);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(tr('Bỏ tin này')),
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

/// Thẻ cuộc gọi trong khung chat: đang diễn ra (nút Tham gia) hoặc đã kết thúc
/// (thời lượng). Nhóm/kênh thì gọi là "cuộc họp".
class _CallCard extends StatelessWidget {
  final MmPost post;
  final MmChannel channel;
  const _CallCard({required this.post, required this.channel});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final mine = post.userId == app.me?.id;
    final meeting = !channel.isDirect;
    final end = post.callEnd;
    final ongoing = end == null;
    final starter = mine ? tr('Bạn') : (app.users[post.userId]?.displayName ?? '');
    final d = Duration(milliseconds: (end ?? DateTime.now().millisecondsSinceEpoch) - post.callStart);
    final dur = d.inHours > 0
        ? tr('{0} giờ {1} phút', [d.inHours, d.inMinutes % 60])
        : d.inMinutes > 0
            ? tr('{0} phút {1} giây', [d.inMinutes, d.inSeconds % 60])
            : tr('{0} giây', [d.inSeconds]);
    final title = ongoing
        ? (meeting ? tr('Cuộc họp đang diễn ra') : tr('Cuộc gọi đang diễn ra'))
        : (meeting ? tr('Cuộc họp đã kết thúc') : tr('Cuộc gọi thoại'));
    final sub = ongoing
        ? tr('{0} đã bắt đầu · {1}', [starter, hhmm(DateTime.fromMillisecondsSinceEpoch(post.callStart))])
        : '${hhmm(DateTime.fromMillisecondsSinceEpoch(post.callStart))} · $dur';
    final color = ongoing ? pal.accent : pal.surface2;
    final inCall = app.calls.busy && app.calls.channelId == channel.id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 270,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine ? pal.outBubble : pal.inBubble,
            borderRadius: BorderRadius.circular(18),
            border: ongoing ? Border.all(color: pal.accent, width: 1.4) : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(meeting ? Icons.groups_rounded : (ongoing ? Icons.call : Icons.call_end_rounded),
                    color: ongoing ? Colors.black : pal.text, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: pal.text)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 13, color: pal.sub)),
                ]),
              ),
            ]),
            if (ongoing && !inCall) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.black),
                  onPressed: app.calls.busy ? null : () => app.calls.startCall(channel.id),
                  icon: const Icon(Icons.call, size: 18),
                  label: Text(meeting ? tr('Tham gia cuộc họp') : tr('Tham gia')),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Banner màu của kênh (vd. dòng chữ cam "24AFF").
class _ChannelBanner extends StatelessWidget {
  final Map<String, dynamic> banner;
  const _ChannelBanner({required this.banner});
  @override
  Widget build(BuildContext context) {
    final hex = (banner['background_color'] as String? ?? '#b64d05').replaceFirst('#', '');
    final color = Color(int.tryParse('FF$hex', radix: 16) ?? 0xFFB64D05);
    final light = color.computeLuminance() > .55;
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(plainPreview(banner['text'] as String? ?? ''),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: light ? Colors.black : Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5)),
    );
  }
}

/// Thanh tin ghim dưới tên kênh: 1 tin thì hiện nội dung, nhiều tin thì hiện số lượng.
class _PinnedBanner extends StatelessWidget {
  final String channelId;
  const _PinnedBanner({required this.channelId});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final list = app.pinnedIn(channelId);
    final text = list.length == 1 ? app.previewText(list.first) : tr('Đã ghim {0} tin nhắn', [list.length]);
    return Material(
      color: pal.surface,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PinnedPage(channelId: channelId))),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.divider, width: .6))),
          child: Row(children: [
            Icon(Icons.push_pin, size: 18, color: pal.sub),
            const SizedBox(width: 10),
            Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text, fontSize: 14.5))),
            Icon(Icons.chevron_right, size: 20, color: pal.sub),
          ]),
        ),
      ),
    );
  }
}

/// Đếm ngược thời gian còn lại của tin tự hủy đã mở.
class _BurnCountdown extends StatefulWidget {
  final int until;
  const _BurnCountdown({required this.until});
  @override
  State<_BurnCountdown> createState() => _BurnCountdownState();
}

class _BurnCountdownState extends State<_BurnCountdown> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = Duration(milliseconds: widget.until - DateTime.now().millisecondsSinceEpoch);
    final text = left.isNegative
        ? tr('🔥 Tin đã tự hủy')
        : tr('🔥 Tự hủy sau {0}:{1}', [left.inMinutes, (left.inSeconds % 60).toString().padLeft(2, '0')]);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: Pal.of(context).sub, fontWeight: FontWeight.w600)),
    );
  }
}

/// Vuốt tin nhắn từ phải sang trái để trả lời.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const _SwipeToReply({required this.child, required this.onReply});
  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> with SingleTickerProviderStateMixin {
  static const _trigger = 64.0;
  static const _max = 90.0;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => _dx = _from * (1 - Curves.easeOut.transform(_back.value))));
  double _dx = 0;
  double _from = 0;
  bool _armed = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _back.stop();
    setState(() => _dx = (_dx + d.delta.dx).clamp(-_max, 0));
    final armed = _dx <= -_trigger;
    if (armed && !_armed) HapticFeedback.lightImpact();
    _armed = armed;
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final progress = (-_dx / _trigger).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(alignment: Alignment.centerRight, children: [
        Positioned(
          right: 18,
          child: Opacity(
            opacity: progress,
            child: Transform.scale(
              scale: .6 + .4 * progress,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: pal.surface, shape: BoxShape.circle),
                child: Icon(Icons.reply, size: 20, color: pal.text),
              ),
            ),
          ),
        ),
        Transform.translate(offset: Offset(_dx, 0), child: widget.child),
      ]),
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
          tooltip: tr('Thả cảm xúc'),
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
List<InlineSpan> _linkify(String raw, Pal pal) {
  final text = replaceShortcodes(raw);
  final code = TextStyle(fontFamily: 'monospace', fontSize: 15, backgroundColor: pal.text.withValues(alpha: .08));
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in _urlRe.allMatches(text)) {
    if (m.start > i) spans.addAll(inlineMarkdown(text.substring(i, m.start), code, (t) => _mentions(t, pal)));
    final url = m.group(0)!;
    spans.add(TextSpan(
      text: url,
      style: TextStyle(color: pal.tick, decoration: TextDecoration.underline, decorationColor: pal.tick),
      mouseCursor: SystemMouseCursors.click,
      recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    ));
    i = m.end;
  }
  if (i < text.length) spans.addAll(inlineMarkdown(text.substring(i), code, (t) => _mentions(t, pal)));
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
    final name = r == null ? '' : (r.userId == app.me?.id ? tr('Bạn') : app.users[r.userId]?.displayName ?? '');
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
                Text(r == null ? tr('Tin nhắn gốc') : app.previewText(r),
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
    if (file.mime.startsWith('audio/')) return AudioMessage(file: file);
    if (file.isVideo) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 2),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPlayerPage(file: file))),
          child: Container(
            width: 260,
            height: 170,
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
            child: Stack(alignment: Alignment.center, children: [
              const Icon(Icons.play_circle_fill, color: Colors.white, size: 58),
              Positioned(
                left: 10,
                bottom: 8,
                right: 10,
                child: Row(children: [
                  const Icon(Icons.videocam, color: Colors.white70, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('${file.name} · ${fileSize(file.size)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                ]),
              ),
            ]),
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

/// Lưu ảnh/video vào thư viện ảnh của máy (máy tính: thư mục Tải về).
Future<void> saveMedia(BuildContext context, List<MmFile> files) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text(tr('Đang tải {0} mục...', [files.length]))));
  try {
    for (final f in files) {
      final local = await app.download(f);
      if (Platform.isAndroid || Platform.isIOS) {
        if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
        f.isVideo ? await Gal.putVideo(local.path, album: 'Flygo Chat') : await Gal.putImage(local.path, album: 'Flygo Chat');
      }
    }
    messenger.showSnackBar(SnackBar(
        content: Text(Platform.isAndroid || Platform.isIOS ? tr('Đã lưu vào thư viện ảnh') : tr('Đã lưu vào thư mục Tải về'))));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Không lưu được. Kiểm tra quyền truy cập ảnh và kết nối mạng.'))));
  }
}

Future<void> openFile(BuildContext context, MmFile file) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text(tr('Đang tải {0}...', [file.name]))));
  try {
    final f = await app.download(file);
    await launchUrl(Uri.file(f.path));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Không tải được file. Kiểm tra kết nối mạng.'))));
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
            tooltip: tr('Tải về'),
            onPressed: () async {
              final f = await app.download(file);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Đã lưu: {0}', [f.path]))));
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

class _Composer extends StatefulWidget {
  final String channelId;
  final MmPost? replyTo;
  final MmPost? editing;
  final VoidCallback onCancelEdit;
  final VoidCallback onCancelReply;
  final VoidCallback onSent;
  const _Composer(
      {required this.channelId, this.replyTo, this.editing, required this.onCancelEdit, required this.onCancelReply, required this.onSent});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  DateTime _lastTyping = DateTime(2000);

  bool get _desktop =>
      Theme.of(context).platform == TargetPlatform.macOS ||
      Theme.of(context).platform == TargetPlatform.windows ||
      Theme.of(context).platform == TargetPlatform.linux;

  @override
  void didUpdateWidget(covariant _Composer old) {
    super.didUpdateWidget(old);
    if (widget.replyTo != null && widget.replyTo != old.replyTo) _focus.requestFocus();
    if (widget.editing != null && widget.editing != old.editing) {
      _ctl.text = widget.editing!.message;
      _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
      _focus.requestFocus();
    }
    if (widget.editing == null && old.editing != null) _ctl.clear();
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
    final editing = widget.editing;
    if (editing != null) {
      final messenger = ScaffoldMessenger.of(context);
      context.read<AppState>().editPost(editing, text).catchError((_) {
        messenger.showSnackBar(SnackBar(content: Text(tr('Không sửa được tin. Kiểm tra kết nối mạng.'))));
      });
      _ctl.clear();
      setState(() {});
      widget.onSent();
      return;
    }
    context.read<AppState>().send(widget.channelId, text, rootId: _rootId);
    _ctl.clear();
    setState(() {});
    widget.onSent();
  }

  /// Gửi file: tin hiện ngay với ảnh trên máy, tải lên chạy nền.
  Future<void> _sendFiles(List<(String?, String, Future<List<int>> Function())> files, {String caption = ''}) async {
    if (files.isEmpty) return;
    final app = context.read<AppState>();
    final dir = await getTemporaryDirectory();
    final items = <(String, String, String, double)>[];
    for (final (path0, name, read) in files.take(10)) {
      var path = path0;
      if (path == null || !File(path).existsSync()) {
        final f = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$name');
        await f.writeAsBytes(await read());
        path = f.path;
      }
      final mime = _mimeOf(name);
      items.add((path, name, mime, mime.startsWith('image/') ? await _aspectOf(path) : 1.0));
    }
    final text = caption.isNotEmpty ? caption : _ctl.text.trim();
    _ctl.clear();
    widget.onSent();
    await app.sendMedia(widget.channelId, items, text: text, rootId: _rootId);
    if (!mounted) return;
    if (app.uploadTooLarge) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('File quá lớn so với giới hạn của máy chủ.'))));
    }
  }

  static String _mimeOf(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      '3gp' => 'video/3gpp',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
  }

  /// Tỉ lệ khung ảnh, đọc từ đầu file, không giải mã cả ảnh.
  static Future<double> _aspectOf(String path) async {
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

  Future<void> _pickDocuments({bool images = false}) async {
    final files = await FilePicker.pickFiles(type: images ? FileType.image : FileType.any);
    await _sendFiles([for (final f in files) (f.path, f.name, f.xFile.readAsBytes)]);
  }

  /// Dấu "+": điện thoại mở bảng ảnh (máy ảnh trực tiếp + ảnh trong máy);
  /// máy tính mở hộp chọn file.
  /// Nút 📷: bảng ảnh (máy ảnh trực tiếp + ảnh trong máy). Máy tính: chọn ảnh.
  Future<void> _photos() async {
    if (_desktop) return _pickDocuments(images: true);
    final r = await showMediaPicker(context);
    if (r == null || !mounted) return;
    if (r.openGallery) return _gallery();
    await _sendFiles([for (final m in r.files) (m.path, m.name, File(m.path).readAsBytes)], caption: r.caption);
  }

  /// Bộ chọn ảnh của hệ điều hành: không cần quyền truy cập thư viện.
  Future<void> _gallery() async {
    final files = await FilePicker.pickFiles(type: FileType.media);
    await _sendFiles([for (final f in files) (f.path, f.name, f.xFile.readAsBytes)]);
  }

  Future<void> _camera({bool video = false}) async {
    final r = await Navigator.of(context).push<MediaPickResult>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => CameraCapturePage(videoMode: video)),
    );
    if (r == null || !mounted) return;
    await _sendFiles([for (final m in r.files) (m.path, m.name, File(m.path).readAsBytes)], caption: r.caption);
  }

  /// Nút "+": Chọn file, Tạo việc, Quay video, Chụp ảnh, Thư viện, Ghi âm.
  Future<void> _attach() async {
    final a = await showAttachPanel(context);
    if (a == null || !mounted) return;
    switch (a) {
      case AttachAction.file:
        await _pickDocuments();
      case AttachAction.task:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CreateTaskPage(channelId: widget.channelId)));
      case AttachAction.video:
        await _camera(video: true);
      case AttachAction.photo:
        await _camera();
      case AttachAction.gallery:
        await _gallery();
      case AttachAction.voice:
        final path = await showVoiceRecorder(context);
        if (path != null) await _sendFiles([(path, path.split('/').last, File(path).readAsBytes)]);
    }
  }

  void _expressions() {
    showExpressionPanel(
      context,
      onEmoji: (e) {
        final sel = _ctl.selection;
        final t = _ctl.text;
        final start = sel.isValid ? sel.start : t.length;
        final end = sel.isValid ? sel.end : t.length;
        _ctl.value = TextEditingValue(text: t.replaceRange(start, end, e), selection: TextSelection.collapsed(offset: start + e.length));
        setState(() {});
      },
      onGif: (g) {
        context.read<AppState>().send(widget.channelId, '![${g.sticker ? 'sticker' : 'GIF'}](${g.url})',
            rootId: _rootId, props: {if (g.sticker) 'dnd_sticker': true, 'dnd_media_aspect': g.aspect});
        widget.onSent();
      },
    );
  }

  // ---------------------------------------------------------------- gợi ý @tên
  List<MmUser> _mentionList = [];
  int _mentionStart = -1;

  Future<void> _updateMentions() async {
    final t = _ctl.text;
    final pos = _ctl.selection.baseOffset < 0 ? t.length : _ctl.selection.baseOffset;
    final before = t.substring(0, pos.clamp(0, t.length));
    final m = RegExp(r'(^|\s)@([\w.\-]*)$').firstMatch(before);
    if (m == null) {
      if (_mentionList.isNotEmpty) setState(() => _mentionList = []);
      _mentionStart = -1;
      return;
    }
    _mentionStart = pos - m.group(2)!.length - 1;
    final q = m.group(2)!.toLowerCase();
    final app = context.read<AppState>();
    final all = await app.channelUsers(widget.channelId);
    if (!mounted) return;
    setState(() {
      _mentionList = all
          .where((u) => u.id != app.me?.id && !u.isBot)
          .where((u) => q.isEmpty || u.username.toLowerCase().contains(q) || u.displayName.toLowerCase().contains(q))
          .take(6)
          .toList();
    });
  }

  void _insertMention(MmUser u) {
    final t = _ctl.text;
    final end = _ctl.selection.baseOffset < 0 ? t.length : _ctl.selection.baseOffset;
    final insert = '@${u.username} ';
    _ctl.value = TextEditingValue(
      text: t.replaceRange(_mentionStart, end, insert),
      selection: TextSelection.collapsed(offset: _mentionStart + insert.length),
    );
    setState(() => _mentionList = []);
    _focus.requestFocus();
  }

  /// Bấm giữ nút gửi: hẹn giờ, tin quan trọng/khẩn cấp có xác nhận đã đọc, tự hủy.
  Future<void> _sendOptions() async {
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.mediumImpact();
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ch = app.channels[widget.channelId];
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        final pal = Pal.of(ctx);
        Widget item(String v, IconData icon, String title, String sub, {Color? color}) => ListTile(
              leading: Icon(icon, color: color ?? pal.text),
              title: Text(title, style: TextStyle(color: color ?? pal.text, fontWeight: FontWeight.w500)),
              subtitle: Text(sub, style: TextStyle(color: pal.sub, fontSize: 13)),
              onTap: () => Navigator.pop(ctx, v),
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 10),
            item('schedule', Icons.schedule_send_outlined, tr('Hẹn giờ gửi'), tr('Chọn thời điểm tin được gửi đi')),
            item('important', Icons.priority_high, tr('Tin quan trọng'), tr('Gắn nhãn QUAN TRỌNG, người nhận bấm xác nhận đã đọc'),
                color: const Color(0xFFF5A623)),
            item('urgent', Icons.campaign_outlined, tr('Tin khẩn cấp'), tr('Gắn nhãn KHẨN CẤP, người nhận bấm xác nhận đã đọc'),
                color: Colors.redAccent),
            if (ch != null && !(ch.isDirect && ch.otherUserId(app.me!.id) == app.me!.id))
              item('burn', Icons.local_fire_department_outlined, tr('Tự hủy sau khi đọc'),
                  tr('Người nhận phải bấm để xem, tin tự xóa sau 10 phút')),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'schedule':
        final now = DateTime.now();
        final date = await showDatePicker(
            context: context, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
        if (date == null || !mounted) return;
        final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
        if (time == null) return;
        final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        if (at.isBefore(DateTime.now())) {
          messenger.showSnackBar(SnackBar(content: Text(tr('Thời điểm hẹn đã qua.'))));
          return;
        }
        try {
          await app.schedule(widget.channelId, text, at, rootId: _rootId);
          _ctl.clear();
          setState(() {});
          widget.onSent();
          messenger.showSnackBar(SnackBar(content: Text(tr('Đã hẹn gửi lúc {0} ngày {1}', [hhmm(at), ddmmyyyy(at)]))));
        } catch (_) {
          messenger.showSnackBar(SnackBar(content: Text(tr('Hẹn giờ không thành công. Kiểm tra kết nối mạng.'))));
        }
      case 'important' || 'urgent':
        app.send(widget.channelId, text, rootId: _rootId, priority: choice, requestAck: true);
        _ctl.clear();
        setState(() {});
        widget.onSent();
      case 'burn':
        app.send(widget.channelId, text, rootId: _rootId, burnOnRead: true);
        _ctl.clear();
        setState(() {});
        widget.onSent();
    }
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
          if (app.scheduledIn(widget.channelId).isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => ScheduledPage(channelId: widget.channelId))),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6, left: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(14)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.schedule_send_outlined, size: 16, color: pal.accentText),
                    const SizedBox(width: 6),
                    Text(tr('Có {0} tin hẹn giờ chờ gửi', [app.scheduledIn(widget.channelId).length]),
                        style: TextStyle(color: pal.accentText, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          if (_mentionList.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                color: pal.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12)],
              ),
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
                for (final u in _mentionList)
                  ListTile(
                    dense: true,
                    leading: Avatar(userId: u.id, name: u.displayName, size: 34),
                    title: Text(u.displayName, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                    subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
                    onTap: () => _insertMention(u),
                  ),
              ]),
            ),
          if (widget.editing != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                Icon(Icons.edit, size: 18, color: pal.accentText),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Sửa tin nhắn'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600, fontSize: 13.5)),
                    Text(plainPreview(widget.editing!.message),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13)),
                  ]),
                ),
                IconButton(icon: Icon(Icons.close, size: 18, color: pal.sub), onPressed: widget.onCancelEdit),
              ]),
            ),
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
                        Text(r.userId == app.me?.id ? tr('Bạn') : app.users[r.userId]?.displayName ?? '',
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
            GlassCircle(icon: Icons.add, size: 46, tooltip: tr('Đính kèm'), onTap: _attach),
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
                          hintText: tr('Nhắn tin'),
                          hintStyle: TextStyle(color: pal.sub),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onChanged: (_) {
                          setState(() {});
                          _updateMentions();
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
                    tooltip: tr('Biểu tượng cảm xúc'),
                    onPressed: _expressions,
                  ),
                ]),
              ),
            ),
            if (!hasText) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.photo_camera_outlined, color: pal.text, size: 27),
                tooltip: tr('Gửi ảnh'),
                onPressed: _photos,
              ),
            ],
            const SizedBox(width: 4),
            Material(
              color: pal.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: hasText ? _send : null,
                onLongPress: hasText ? _sendOptions : null,
                onSecondaryTap: hasText ? _sendOptions : null,
                child: const SizedBox(width: 46, height: 46, child: Icon(Icons.send_rounded, color: Colors.black, size: 22)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
