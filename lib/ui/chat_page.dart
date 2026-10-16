import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_view.dart';
import 'ai_panel.dart';
import 'attach_panel.dart';
import 'chat_info_page.dart';
import 'clip.dart';
import 'expression_panel.dart';
import 'chat_list.dart';
import 'forward_page.dart';
import 'home_page.dart' show ChatHost;
import 'links.dart';
import 'open_file.dart';
import 'sub_channel.dart';
import '../agent/agent_config.dart';
import 'markdown_view.dart';
import 'media_picker.dart';
import 'media_view.dart';
import 'moderation.dart';
import 'reactions.dart';
import 'common.dart';
import 'status_ui.dart';
import 'theme.dart';

class ChatPage extends StatefulWidget {
  final String channelId;
  final bool embedded;
  /// Đang mở ở cột phải (luồng riêng tư): hiện nút đóng.
  final VoidCallback? onClose;
  const ChatPage({super.key, required this.channelId, this.embedded = false, this.onClose});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scroll = ScrollController();
  late final AppState _app;
  MmPost? _replyTo;
  MmPost? _editing;
  bool _loadingOlder = false;
  bool _dragging = false;
  final _composer = GlobalKey<_ComposerState>();

  /// Khóa của từng tin đang hiển thị, để cuộn tới đúng tin.
  final Map<String, GlobalKey> _keys = {};
  String? _highlight;

  /// Tin chưa đọc lúc mở chat: vạch "N tin chưa đọc" + nút tua tới tin chưa đọc đầu tiên.
  int _unreadSince = 0;
  bool _unreadJumped = false;
  bool _unreadAutoDone = false;

  // Tìm ngay trong khung chat: ô tìm dưới đầu chat, kết quả khớp (mới nhất trước), mũi tên lên/xuống để chuyển.
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();
  List<String> _matches = [];
  int _matchIdx = 0;
  /// Ô tìm trong chat: tạm ẩn (Sếp sẽ quyết cách mở sau); [_openSearch] để bật lại.
  bool _searchOpen = false;

  Timer? _searchDebounce;
  int _searchSeq = 0;

  /// Bỏ dấu tiếng Việt + chữ thường để so khớp ("dang" khớp "Đang").
  static String _fold(String s) {
    const a = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
    const b = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
    final l = s.toLowerCase();
    final out = StringBuffer();
    for (final ch in l.split('')) {
      final i = a.indexOf(ch);
      out.write(i < 0 ? ch : b[i]);
    }
    return out.toString();
  }

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _matches = [];
        _matchIdx = 0;
      });
      return;
    }
    // Khớp ngay trong các tin đã tải, rồi hỏi máy chủ để tìm cả tin cũ hơn.
    final f = _fold(query);
    final local = [
      for (final p in _app.postsOf(widget.channelId))
        if (!p.threadOnly && !p.isSystem && _fold(agentDisplayText(p)).contains(f)) p.id
    ];
    setState(() {
      _matches = local;
      _matchIdx = 0;
    });
    if (local.isNotEmpty) _jumpToPost(local.first);
    final seq = ++_searchSeq;
    _searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      final ch = _app.channels[widget.channelId];
      final team = _app.teamId;
      if (ch == null || team == null) return;
      try {
        final r = await _app.api.search(team, 'in:${ch.name} $query');
        if (!mounted || seq != _searchSeq) return;
        final byId = <String, int>{
          for (final p in _app.postsOf(widget.channelId)) p.id: p.createAt,
          for (final p in r)
            if (p.channelId == widget.channelId && p.rootId.isEmpty) p.id: p.createAt,
        };
        final all = {..._matches, ...r.where((p) => p.channelId == widget.channelId && p.rootId.isEmpty).map((p) => p.id)}.toList()
          ..sort((x, y) => (byId[y] ?? 0).compareTo(byId[x] ?? 0));
        final cur = _matches.isEmpty ? null : _matches[_matchIdx];
        setState(() {
          _matches = all;
          _matchIdx = cur == null ? 0 : all.indexOf(cur).clamp(0, all.length - 1);
        });
        if (cur == null && all.isNotEmpty) _jumpToPost(all.first);
      } catch (_) {}
    });
  }

  /// Chuyển kết quả: [older] = lên (tin cũ hơn), ngược lại xuống (tin mới hơn).
  void _stepMatch(bool older) {
    if (_matches.isEmpty) return;
    final n = _matches.length;
    setState(() => _matchIdx = (older ? _matchIdx + 1 : _matchIdx - 1 + n) % n);
    _jumpToPost(_matches[_matchIdx]);
  }

  void _clearSearch() {
    _searchCtl.clear();
    _searchFocus.unfocus();
    _onSearchChanged('');
    setState(() => _searchOpen = false);
  }

  Widget _searchBox(Pal pal) {
    final q = _searchCtl.text.trim();
    final count = _matches.isEmpty ? (q.isEmpty ? '' : '0/0') : '${_matchIdx + 1}/${_matches.length}';
    Widget arrow(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          tooltip: tip,
          visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
          icon: Icon(icon, size: 22, color: onTap == null ? pal.sub.withValues(alpha: .4) : pal.text),
          onPressed: onTap,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: _FloatPill(
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(children: [
          Icon(Icons.search, size: 18, color: pal.sub),
          const SizedBox(width: 8),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): () => _stepMatch(true),
                const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _stepMatch(false),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => _stepMatch(true),
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => _stepMatch(false),
                const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
              },
              child: TextField(
                controller: _searchCtl,
                focusNode: _searchFocus,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  _stepMatch(true);
                  _searchFocus.requestFocus();
                },
                style: TextStyle(fontSize: 14, color: pal.text),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  hintText: tr('Tìm trong cuộc trò chuyện'),
                  hintStyle: TextStyle(fontSize: 14, color: pal.sub),
                ),
              ),
            ),
          ),
          if (q.isEmpty) arrow(Icons.close_rounded, tr('Đóng'), _clearSearch),
          if (q.isNotEmpty) ...[
            Text(count, style: TextStyle(fontSize: 13, color: pal.sub, fontFeatures: const [ui.FontFeature.tabularFigures()])),
            const SizedBox(width: 2),
            arrow(Icons.keyboard_arrow_up_rounded, tr('Kết quả cũ hơn'), _matches.length > 1 ? () => _stepMatch(true) : null),
            arrow(Icons.keyboard_arrow_down_rounded, tr('Kết quả mới hơn'), _matches.length > 1 ? () => _stepMatch(false) : null),
            arrow(Icons.close_rounded, tr('Xóa'), _clearSearch),
          ],
        ]),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    // Mốc "tin chưa đọc": lần xem cuối trước khi mở chat (mở chat sẽ đánh dấu đã xem).
    if (_app.unreadOf(widget.channelId) > 0) _unreadSince = _app.members[widget.channelId]?.lastViewedAt ?? 0;
    _app.openChannel(widget.channelId);
    _app.myBotIds().then((_) {
      if (mounted) setState(() {});
    });
    _scroll.addListener(_onScroll);
    _app.jumpRequest.addListener(_onJumpRequest);
  }

  void _onJumpRequest() {
    final r = _app.jumpRequest.value;
    if (r == null || r.$1 != widget.channelId || !mounted) return;
    _app.jumpRequest.value = null;
    // Đóng các trang mở chồng lên khung chat (cài đặt, tin đã ghim...).
    final route = ModalRoute.of(context);
    if (route != null) Navigator.of(context).popUntil((x) => x == route);
    _jumpToPost(r.$2);
  }

  /// Cuộn tới tin [id]: tải thêm tin cũ nếu chưa có, rồi cuộn dần tới khi tin được dựng, nháy sáng tin đó.
  Future<void> _jumpToPost(String id) async {
    final cid = widget.channelId;
    bool loaded() => _app.postsOf(cid).any((p) => p.id == id);
    for (var n = 0; n < 40 && !loaded() && _app.hasMore[cid] != false; n++) {
      await _app.loadOlder(cid);
    }
    if (!mounted) return;
    if (!loaded()) {
      ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không tìm thấy tin này trong lịch sử trò chuyện.'))));
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    for (var n = 0; n < 300 && mounted && _scroll.hasClients; n++) {
      final ctx = _keys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        setState(() => _highlight = id);
        await Scrollable.ensureVisible(ctx, alignment: .4, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        Future.delayed(const Duration(milliseconds: 1600), () {
          if (mounted && _highlight == id) setState(() => _highlight = null);
        });
        return;
      }
      final posts = _app.postsOf(cid);
      final target = posts.indexWhere((p) => p.id == id);
      var maxBuilt = -1;
      for (var i = 0; i < posts.length; i++) {
        if (_keys[posts[i].id]?.currentContext != null) maxBuilt = i;
      }
      final pos = _scroll.position;
      final step = pos.viewportDimension * .8;
      // Danh sách đảo ngược: tin cũ hơn (chỉ số lớn hơn) nằm ở vị trí cuộn lớn hơn.
      _scroll.jumpTo((target > maxBuilt ? pos.pixels + step : pos.pixels - step).clamp(0.0, pos.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  void dispose() {
    _app.jumpRequest.removeListener(_onJumpRequest);
    _app.closeChannel(widget.channelId);
    _scroll.dispose();
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool _showDown = false;
  /// Chiều cao phần đầu nổi (đầu khung chat + tin ghim + ô tìm kiếm) để danh sách tin chừa chỗ.
  double _topInset = 120;

  void _onScroll() {
    final down = _scroll.position.pixels > 600;
    if (down != _showDown) setState(() => _showDown = down);
    // Cuộn tới tin mới nhất: ghi nhận đã đọc hết (kể cả tin đến trong lúc đang xem ở đoạn trên).
    if (_scroll.position.pixels < 80 && _app.unreadAllOf(widget.channelId) > 0) _app.markViewed(widget.channelId);
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
    // Câu trả lời chỉ thuộc chủ đề không hiện ở chat chính.
    final posts = app.postsOf(ch.id).where((p) => !p.threadOnly).toList();
    // Tin chưa đọc (người khác gửi, sau lần xem cuối): tin cũ nhất trong số đó là chỗ đặt vạch "chưa đọc".
    final unread = _unreadSince <= 0
        ? const <MmPost>[]
        : posts.where((p) => p.createAt > _unreadSince && p.userId != app.me?.id && !p.isSystem).toList();
    final firstUnreadId = unread.isEmpty ? null : unread.last.id;
    final spots = app.unreadThreadSpots(ch.id);
    if (firstUnreadId != null && !_unreadAutoDone) {
      _unreadAutoDone = true;
      // Nhiều tin chưa đọc: mở chat thì tua tới tin chưa đọc đầu tiên (như WhatsApp).
      if (unread.length > 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() => _unreadJumped = true);
            _jumpToPost(firstUnreadId);
          }
        });
      }
    }

    final parentCh = ch.subParent == null ? null : app.channels[ch.subParent];
    final subtitle = ch.isSub
        ? tr('🔒 Luồng bí mật · {0}', [parentCh == null ? tr('nhóm gốc') : app.channelTitle(parentCh)])
        : ch.header.trim().isNotEmpty
            ? plainPreview(ch.header)
            : ch.isDirect && other != null && other != app.me?.id && app.users[other]?.isBot != true
                ? statusLine(app, other)
                : (ch.isDirect ? tr('nhấn để xem thông tin liên lạc') : tr('nhấn để xem thông tin nhóm'));
    final subtitleIsHeader = ch.header.trim().isNotEmpty;

    // Đầu khung chat kiểu WhatsApp: thanh có nền — quay lại, ảnh chat, tên chat; góc phải gọi video, gọi thoại, ⋮.
    final header = Container(
      decoration: BoxDecoration(color: pal.bg, border: Border(bottom: BorderSide(color: pal.divider, width: .5))),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 60,
          child: Row(children: [
            if (widget.onClose != null)
              IconButton(icon: Icon(Icons.close, color: pal.text), onPressed: widget.onClose)
            else if (!widget.embedded)
              IconButton(icon: Icon(Icons.arrow_back, color: pal.text), onPressed: () => Navigator.maybePop(context))
            else
              const SizedBox(width: 12),
            if (ch.isAi && ch.aiGroup != null)
              Expanded(child: AiSessionTitle(groupId: ch.aiGroup!, label: aiSessionLabel(ch), selectedId: ch.id))
            else
              Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openInfo,
                child: Row(children: [
                  ch.isSelfDm
                      ? const Avatar(name: '', size: 40, icon: Icons.cloud)
                      : Avatar(userId: other, name: title, size: 40, icon: other == null ? chatIcon(ch) : null, channel: ch),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                      nameText(title,
                          bot: app.users[other]?.isBot == true, engine: engineOf(app.users[other]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: subtitleIsHeader ? FontWeight.w600 : FontWeight.normal,
                              color: subtitleIsHeader ? pal.accentText : pal.sub)),
                    ]),
                  ),
                ]),
              ),
            ),
            // Nút trợ lý AI của nhóm (trước nút gọi): máy tính mở cột phải, điện thoại mở trang riêng.
            if (app.showsAiFor(ch))
              IconButton(
                tooltip: tr('Trợ lý AI'),
                icon: Badge(
                  isLabelVisible: (app.aiChannelFor(ch.id) != null) && app.unreadAllOf(app.aiChannelFor(ch.id)!.id) > 0,
                  smallSize: 8,
                  child: Icon(Icons.auto_awesome, color: pal.accentText),
                ),
                onPressed: () {
                  final host = ChatHost.of(context);
                  if (widget.embedded && host?.openAi != null) {
                    host!.openAi!(ch.id);
                  } else {
                    openAiPanel(context, ch.id);
                  }
                },
              ),
            // Bỏ nút gọi điện / video ở đầu chat (gọi từ trang cài đặt chat). ⋮ mở thẳng cài đặt chat.
            // Chat AI cột phải không có cài đặt.
            if (!ch.isAi)
              IconButton(tooltip: tr('Cài đặt cuộc trò chuyện'), icon: Icon(Icons.more_vert, color: pal.text), onPressed: _openInfo)
            else
              AiSessionMenu(channel: ch),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
    // Phần nổi phía trên danh sách tin: đầu khung chat, dải cuộc gọi, tin đã ghim, ô tìm kiếm.
    final top = _SizeReporter(
      onSize: (sz) {
        if (mounted && (sz.height - _topInset).abs() > .5) setState(() => _topInset = sz.height);
      },
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        _OngoingCallBanner(key: ValueKey('call:${ch.id}'), channel: ch),
        if (ch.banner != null) _ChannelBanner(banner: ch.banner!),
        if (app.pinnedIn(ch.id).isNotEmpty) _PinnedBanner(channelId: ch.id),
        if (_searchOpen) _searchBox(pal),
        const OfflineBanner(),
        const SizedBox(height: 4),
      ]),
    );

    final page = Scaffold(
      backgroundColor: pal.chatBg,
      body: Column(children: [
        Expanded(
          child: DoodleBackground(
            // Luồng riêng tư: nền khác chat thường (giống luồng công việc riêng) cho dễ phân biệt.
            color: ch.isSub
                ? pal.threadBg
                : ch.isAi
                    ? Color.alphaBlend(pal.accent.withValues(alpha: .07), pal.chatBg)
                    : null,
            child: Stack(children: [
              // Chạm vào khung tin nhắn: đóng bàn phím (các bảng ảnh, sticker... là bảng nổi, chạm ra ngoài tự đóng).
              Positioned.fill(child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  _composer.currentState?.closePanel();
                },
                child: posts.isEmpty
                ? Padding(padding: EdgeInsets.only(top: _topInset), child: const Center(child: _EmptyChat()))
                : ListView.builder(
                    controller: _scroll,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    reverse: true,
                    padding: EdgeInsets.only(top: _topInset + 8, bottom: 8),
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
                      return AnimatedContainer(
                        key: _keys.putIfAbsent(p.id, GlobalKey.new),
                        duration: const Duration(milliseconds: 250),
                        color: _highlight == p.id ? pal.accent.withValues(alpha: .18) : Colors.transparent,
                        child: Column(children: [
                        if (showDay) _DayChip(DateTime.fromMillisecondsSinceEpoch(p.createAt)),
                        if (p.id == firstUnreadId) _UnreadDivider(count: unread.length),
                        p.isSystem
                            ? _SystemChip(p.message)
                            : p.isCallRing
                            ? _SystemChip('${p.callRingText} · ${hhmm(DateTime.fromMillisecondsSinceEpoch(p.createAt))}')
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
                      ]));
                    },
                  ))),
              // Chat chính đã đọc hết nhưng còn tin chưa đọc trong luồng / luồng bí mật: nút tua tới tin gốc của luồng đó.
              if ((firstUnreadId == null || _unreadJumped) && spots.isNotEmpty)
                Positioned(
                  right: 14,
                  top: _topInset + 10,
                  child: Material(
                    color: pal.accent,
                    shape: const StadiumBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => _jumpToPost(spots.first.$1),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.forum_outlined, size: 17, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(tr('{0} tin chưa đọc trong luồng', [spots.fold<int>(0, (a, b) => a + b.$2)]),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5)),
                        ]),
                      ),
                    ),
                  ),
                ),
              // Nút tua tới tin chưa đọc đầu tiên.
              if (firstUnreadId != null && !_unreadJumped)
                Positioned(
                  right: 14,
                  top: _topInset + 10,
                  child: Material(
                    color: pal.accent,
                    shape: const StadiumBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () {
                        setState(() => _unreadJumped = true);
                        _jumpToPost(firstUnreadId);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.keyboard_double_arrow_up_rounded, size: 18, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(tr('{0} tin chưa đọc', [unread.length]),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5)),
                        ]),
                      ),
                    ),
                  ),
                ),
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
              Positioned(top: 0, left: 0, right: 0, child: top),
            ]),
          ),
        ),
        // Ai đang soạn tin: hiện ngay trên ô nhắn tin.
        _TypingBar(names: typing, direct: ch.isDirect ? title : null, bg: pal.chatBg),
        // Tin nhắn riêng với trợ lý AI của người khác: không cho nhắn (bảo mật).
        if (ch.isDirect && other != null && app.users[other]?.isBot == true && app.myBotsKnown && !app.isMyBot(other))
          Container(
            width: double.infinity,
            color: pal.chatBg,
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.shield_outlined, size: 17, color: pal.sub),
              const SizedBox(width: 8),
              Flexible(
                child: Text(tr('Chỉ chủ của trợ lý mới nhắn riêng được. Hãy gọi trợ lý trong nhóm có chủ của nó.'),
                    textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 14)),
              ),
            ]),
          )
        else
        // Kênh khoá gửi tin và mình chưa được cấp quyền: thay ô nhắn tin bằng dòng thông báo.
        if (!app.canPost(ch.id))
          Container(
            width: double.infinity,
            color: pal.chatBg,
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_outline, size: 17, color: pal.sub),
              const SizedBox(width: 8),
              Flexible(
                child: Text(tr('Chỉ người được cấp quyền mới gửi tin trong kênh này'),
                    textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 14)),
              ),
            ]),
          )
        else
        Container(
          color: pal.chatBg,
          child: _Composer(
            key: _composer,
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
    // Kéo tệp từ máy tính thả vào khung chat: tệp được đính kèm, con trỏ vào ô soạn tin.
    if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return page;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _composer.currentState?.stage([for (final f in d.files) (f.path, f.name)]);
      },
      child: Stack(children: [
        page,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: pal.accent.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: pal.accent, width: 2.5),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                  decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(16)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.file_download_outlined, color: Colors.white),
                    const SizedBox(width: 10),
                    Text(tr('Thả tệp tin xuống để gửi'),
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Mở chủ đề của tin [rootId]: điện thoại mở trang mới, máy tính mở cột bên phải chat chính.
void openThread(BuildContext context, String channelId, String rootId) {
  final host = ChatHost.of(context);
  if (host != null) return host.openThread(channelId, rootId);
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ThreadPage(channelId: channelId, rootId: rootId)));
}

/// Dòng "💬 N trả lời · người trả lời gần nhất" dưới tin gốc.
class _ThreadChip extends StatelessWidget {
  final String channelId;
  final String rootId;
  final VoidCallback onTap;
  const _ThreadChip({required this.channelId, required this.rootId, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final unread = app.threadUnread(channelId, rootId);
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
      child: Material(
        color: pal.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.forum_outlined, size: 15, color: pal.accentText),
              const SizedBox(width: 5),
              Text(tr('Luồng riêng'), style: TextStyle(fontSize: 13, color: pal.accentText, fontWeight: FontWeight.w600)),
              if (unread > 0)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(10)),
                  child: Text('$unread', style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Trang chủ đề: tin gốc ở trên, các câu trả lời bên dưới, ô nhắn tin riêng.
class ThreadPage extends StatefulWidget {
  /// Chữ điền sẵn vào ô nhắn tin khi mở luồng (vd. "@trợ-lý "), theo id tin gốc.
  static final Map<String, String> prefill = {};
  final String channelId;
  final String rootId;
  /// Máy tính: đóng cột chủ đề.
  final VoidCallback? onClose;
  const ThreadPage({super.key, required this.channelId, required this.rootId, this.onClose});
  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage> {
  final _scroll = ScrollController();
  MmPost? _root;
  MmPost? _editing;
  final _composer = GlobalKey<_ComposerState>();

  @override
  void initState() {
    super.initState();
    final app = _app = context.read<AppState>();
    _root = app.findPost(widget.channelId, widget.rootId);
    WidgetsBinding.instance.addPostFrameCallback((_) => app.markThreadSeen(widget.rootId));
    final pre = ThreadPage.prefill.remove(widget.rootId);
    if (pre != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _composer.currentState;
        if (c == null) return;
        c._ctl.text = pre;
        c._ctl.selection = TextSelection.collapsed(offset: pre.length);
        c._focus.requestFocus();
        c.setState(() {});
      });
    }
    app.loadThread(widget.rootId).then((r) {
      if (mounted && r != null) setState(() => _root = r);
    });
  }

  late final AppState _app;

  @override
  void dispose() {
    // Rời luồng: các tin đã thấy coi như đã xem.
    final app = _app, root = widget.rootId;
    Future.microtask(() => app.markThreadSeen(root));
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final ch = app.channels[widget.channelId];
    final root = app.findPost(widget.channelId, widget.rootId) ?? _root;
    final replies = app.threadReplies(widget.channelId, widget.rootId);
    // Trợ lý AI (runner ≤0.3.3): thẻ tiến trình và câu trả lời là hai tin riêng, nối nhau bằng run_id.
    // Có câu trả lời thì ẩn thẻ, gắn dữ liệu thẻ vào câu trả lời mới nhất của lượt → một bong bóng như chat chính.
    final cards = <String, MmPost>{}, answers = <String, MmPost>{};
    for (final p in replies) {
      final run = agentRunOf(p), msg = agentMessageOf(p);
      if (run != null && msg == null && run['run_id'] is String) {
        cards[run['run_id'] as String] = p;
      } else if (run == null && msg != null && msg['run_id'] is String) {
        final id = msg['run_id'] as String;
        final prev = answers[id];
        if (prev == null || p.createAt >= prev.createAt) answers[id] = p;
      }
    }
    final hiddenCards = {for (final e in cards.entries) if (answers.containsKey(e.key)) e.value.id};
    final runFor = {for (final e in answers.entries) if (cards[e.key] != null) e.value.id: agentRunOf(cards[e.key]!)};
    final cardOnly = {for (final e in cards.entries) if (!answers.containsKey(e.key)) e.value.id};
    // Danh sách đảo ngược (mới nhất ở dưới cùng): câu trả lời mới nhất trước, tin gốc cuối.
    final items = [...replies.reversed.where((p) => !hiddenCards.contains(p.id)), ?root];
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.threadBg,
        body: Column(children: [
          Expanded(
            child: DoodleBackground(
              color: pal.threadBg,
              child: Stack(children: [
              Positioned.fill(child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  _composer.currentState?.closePanel();
                },
                child: root == null || ch == null
                    ? Center(child: CircularProgressIndicator(color: pal.accent))
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 62, bottom: 8),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final p = items[i];
                          final isRoot = p.id == widget.rootId;
                          final older = i + 1 < items.length ? items[i + 1] : null;
                          final newer = i > 0 ? items[i - 1] : null;
                          final first = isRoot || older == null || older.id == widget.rootId || older.userId != p.userId;
                          final last = newer == null || newer.userId != p.userId || isRoot;
                          final bubble = p.isSystem
                              ? _SystemChip(p.message)
                              : _Bubble(
                                  post: p,
                                  channel: ch,
                                  first: first,
                                  last: last,
                                  inThreadView: true,
                                  agentRunOverride: runFor[p.id],
                                  agentCombined: cardOnly.contains(p.id),
                                  onReply: () {
                                    _composer.currentState?.mentionBotOf(p);
                                    _composer.currentState?._focus.requestFocus();
                                  },
                                  onEdit: (p) => setState(() => _editing = p),
                                );
                          if (!isRoot) return bubble;
                          return Column(children: [
                            bubble,
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                              child: Row(children: [
                                Text(tr('{0} trả lời', [replies.length - hiddenCards.length]),
                                    style: TextStyle(fontSize: 13, color: pal.sub, fontWeight: FontWeight.w600)),
                                const SizedBox(width: 8),
                                Expanded(child: Divider(color: pal.divider)),
                              ]),
                            ),
                          ]);
                        },
                      ),
              )),
              // Đầu trang nổi trên nền luồng (không có thanh nền).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                    child: Row(children: [
                      GlassCircle(
                        icon: widget.onClose != null ? Icons.close : Icons.arrow_back_ios_new,
                        onTap: widget.onClose ?? () => Navigator.maybePop(context),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: _FloatPill(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(tr('Luồng công việc riêng'),
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
                            Text(ch == null ? '' : app.channelTitle(ch),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: pal.sub)),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              ]),
            ),
          ),
          _TypingBar(names: app.typingIn(widget.channelId, widget.rootId), bg: pal.threadBg),
          Container(
            color: pal.threadBg,
            child: _Composer(
              key: _composer,
              channelId: widget.channelId,
              threadRoot: widget.rootId,
              editing: _editing,
              onCancelEdit: () => setState(() => _editing = null),
              onCancelReply: () {},
              onSent: () {
                setState(() => _editing = null);
                if (_scroll.hasClients) _scroll.jumpTo(0);
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// Ba chấm nhấp nháy lần lượt (đang soạn tin).
/// "X đang soạn tin..." ngay trên ô nhắn tin (chat chính hoặc trang luồng).
/// Vỏ nút bo tròn cùng kiểu với "Mở luồng riêng" / "Bí mật" (dùng làm nút mở menu).
class _ChipLook extends StatelessWidget {
  final Pal pal;
  final Widget child;
  const _ChipLook({required this.pal, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: ShapeDecoration(color: pal.surface, shape: StadiumBorder(side: BorderSide(color: pal.divider))),
        child: Center(widthFactor: 1, child: child),
      );
}

class _TypingBar extends StatelessWidget {
  final List<String> names;
  /// Chat 1-1: tên người kia.
  final String? direct;
  final Color bg;
  const _TypingBar({required this.names, this.direct, required this.bg});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final typing = names;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      child: typing.isEmpty
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              color: bg,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(children: [
                _TypingDots(color: pal.accentText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    direct != null || typing.length == 1
                        ? tr('{0} đang soạn tin...', [direct ?? typing.first])
                        : typing.length == 2
                            ? tr('{0} và {1} đang soạn tin...', [typing[0], typing[1]])
                            : tr('{0} người đang soạn tin...', [typing.length]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: pal.accentText),
                  ),
                ),
              ]),
            ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  final Color color;
  const _TypingDots({required this.color});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: .3 + .7 * (((_c.value * 3 - i) % 3) < 1 ? 1 : 0)),
              ),
            ),
        ]),
      );
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

/// Vạch "N tin chưa đọc" phía trên tin chưa đọc đầu tiên.
class _UnreadDivider extends StatelessWidget {
  final int count;
  const _UnreadDivider({required this.count});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: pal.accent.withValues(alpha: .12),
      alignment: Alignment.center,
      child: Text(tr('{0} tin chưa đọc', [count]),
          style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600, fontSize: 13)),
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
  /// Đang hiển thị trong trang chủ đề (không hiện trích dẫn tin gốc và dòng "N trả lời").
  final bool inThreadView;
  /// Trong luồng (runner ≤0.3.3 đăng thẻ tiến trình và câu trả lời thành hai tin): thẻ của lượt này,
  /// ghép vào câu trả lời để hiện một bong bóng như ở chat chính.
  final Map<String, dynamic>? agentRunOverride;
  /// Thẻ tiến trình chưa có câu trả lời: vẫn hiện kiểu gộp (dòng trạng thái + con trỏ đang viết).
  final bool agentCombined;
  const _Bubble(
      {required this.post,
      required this.channel,
      required this.first,
      required this.last,
      required this.onReply,
      required this.onEdit,
      this.inThreadView = false,
      this.agentRunOverride,
      this.agentCombined = false});

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
    // Tin của bot (trợ lý AI): được rộng hết khung chat.
    final maxW = app.users[post.userId]?.isBot == true ? double.infinity : (width > 900 ? width * .5 : width * .8);
    final root = post.rootId.isEmpty ? null : app.findPost(post.channelId, post.rootId);
    // 🛑 trên tin của trợ lý AI là lệnh dừng gửi runner, không hiện thành cảm xúc.
    final reactions = post.props.containsKey('flygo_agent') || post.props.containsKey('flygo_agent_message')
        ? (Map.of(post.reactions)..remove('octagonal_sign')..remove('unlock')..remove('arrow_forward'))
        : post.reactions;
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
        ? [ChatImage(url: gif.group(1), aspect: (post.props['flygo_media_aspect'] ?? post.props['dnd_media_aspect'] as num?)?.toDouble() ?? 1)]
        : imagesOf(post);
    final isSticker = (post.props['flygo_sticker'] ?? post.props['dnd_sticker']) == true;
    final sendingMedia = post.sendState == SendState.sending && post.localFiles.isNotEmpty;
    final imagesOnly = images.isNotEmpty &&
        (post.message.isEmpty || gif != null) &&
        post.rootId.isEmpty &&
        !post.isForwarded &&
        post.priority.isEmpty &&
        !post.isBurnOnRead &&
        post.files.where((f) => !f.isImage).isEmpty &&
        post.localFiles.where((f) => !(f['mime'] as String? ?? '').startsWith('image/')).isEmpty;
    // Tin chỉ có một video: hiện video trần, không bọc khung bong bóng (giờ gửi đè góc dưới video).
    final localVideos = post.localFiles.where((f) => (f['mime'] as String? ?? '').startsWith('video/')).toList();
    final serverVideos = post.files.where((f) => f.isVideo).toList();
    final videoOnly = !imagesOnly &&
        post.message.isEmpty &&
        post.rootId.isEmpty &&
        !post.isForwarded &&
        post.priority.isEmpty &&
        !post.isBurnOnRead &&
        localVideos.length + serverVideos.length == 1 &&
        post.files.length == serverVideos.length &&
        post.localFiles.length == localVideos.length;
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
    // Bấm @tên trong tin: mở tin nhắn riêng với người đó.
    void onMention(String username) {
      final u = app.users.values.where((x) => x.username == username).firstOrNull;
      if (u != null) openDirectWith(context, app, u);
    }
    final bor = post.isBurnOnRead;
    final hidden = bor && !mine && post.raw['_revealed_at'] == null && post.message.isEmpty;
    final long = post.message.length > 700 || '\n'.allMatches(post.message).length > 14;
    final collapsed = long && !app.expanded.contains(post.id);

    // Tin của bot AI: thẻ tiến trình, tin đang viết dần, yêu cầu duyệt.
    final agentRun = agentRunOverride ?? agentRunOf(post);
    final agentMsg = agentMessageOf(post) ?? (agentCombined && agentRun != null ? const <String, dynamic>{} : null);
    final approval = agentApprovalOf(post);
    // Runner 0.3+: một tin ở chat chính mang cả thẻ tiến trình lẫn câu trả lời đang viết dần.
    // Chưa có chữ thì nội dung tin chỉ là dòng tóm tắt của thẻ ("🤖 …"): không hiện lặp lại.
    final combined = agentRun != null && agentMsg != null;
    final runActive = combined && (agentRun['status'] == 'thinking' || agentRun['status'] == 'running');
    var msgText = agentDisplayText(post);
    if (combined && post.message.trimLeft().startsWith('🤖')) msgText = '';
    final streaming = agentMsg?['streaming'] == true || runActive;

    Widget body;
    if (agentRun != null && !combined) {
      body = Padding(
        padding: EdgeInsets.only(right: metaWidth, bottom: 6),
        child: AgentRunCard(run: agentRun, openKey: post.id),
      );
    } else if (approval != null && !combined) {
      body = Padding(padding: const EdgeInsets.only(bottom: 14), child: AgentApprovalBar(post: post, approval: approval));
    } else if (hidden) {
      body = GestureDetector(
        onTap: () => app.reveal(post).catchError((_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không mở được tin. Tin có thể đã tự hủy.'))));
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
    } else if (msgText.isEmpty) {
      body = streaming ? const StreamingCursor() : const SizedBox.shrink();
    } else if (!app.renderMarkdown) {
      body = Text.rich(
          TextSpan(children: [
            ...linkSpans(msgText, pal, (t) => [TextSpan(text: t)]),
            WidgetSpan(child: SizedBox(width: metaWidth, height: 12)),
          ]),
          style: textStyle);
    } else if (MarkdownView.isSimple(msgText)) {
      body = Text.rich(
        TextSpan(children: [
          ..._linkify(msgText, pal, onMention),
          if (streaming) const WidgetSpan(alignment: PlaceholderAlignment.middle, child: StreamingCursor()),
          WidgetSpan(child: SizedBox(width: metaWidth, height: 12)),
        ]),
        style: textStyle,
      );
    } else {
      body = MarkdownView(text: msgText, style: textStyle, trailingSpace: metaWidth, onMention: onMention);
      if (streaming) {
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [body, const StreamingCursor()]);
      }
    }
    if (combined) {
      // Dòng trạng thái gọn (bấm để xem các bước) phía trên câu trả lời.
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        body,
        // Đang chạy: nút Dừng cho chủ bot (thả 🛑 lên tin, runner dừng lượt này).
        if (runActive && post.props['flygo_agent_owner'] == app.me?.id)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: _AgentStopButton(post: post),
          ),
        // Lượt bị dừng giữa chừng (trợ lý khởi động lại / cập nhật): nút Tiếp tục (thả ▶️, runner chạy lại lượt này).
        if (agentRun['status'] == 'stopped' &&
            agentRun['interrupted'] == true &&
            (post.props['flygo_agent_owner'] == app.me?.id || app.isMyBot(post.userId)))
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: _AgentResumeButton(post: post),
          ),
        // Yêu cầu duyệt nằm ngay trong câu trả lời (runner gắn vào cùng tin).
        if (approval != null && (approval['status'] as String? ?? 'pending') == 'pending')
          Padding(padding: const EdgeInsets.only(top: 6, bottom: 14), child: AgentApprovalBar(post: post, approval: approval)),
      ]);
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
            // Chừa chỗ cho giờ gửi (đè góc phải dưới), không thì giờ đè lên chữ khi nội dung hẹp.
            padding: EdgeInsets.only(top: 4, bottom: 2, right: metaWidth + 8),
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
      // Trả lời của trợ lý AI: một dòng "trạng thái · logo · tên bot · mô hình · mức suy nghĩ" (bấm để xem các bước).
      if (combined)
        Padding(
          padding: EdgeInsets.only(right: msgText.isEmpty ? metaWidth : 0, bottom: 4),
          child: AgentRunCard(
            run: agentRun,
            openKey: post.id,
            compact: true,
            name: !showName
                ? null
                : GestureDetector(
                    onTap: sender == null ? null : () => openDirectWith(context, app, sender),
                    child: Text('~${sender?.displayName ?? 'Người dùng'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WaColors.sender(post.userId))),
                  ),
          ),
        ),
      if (showName && !combined)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: GestureDetector(
            onTap: sender == null ? null : () => openDirectWith(context, app, sender),
            child: nameText('~${sender?.displayName ?? 'Người dùng'}',
                bot: sender?.isBot == true, engine: engineOf(sender),
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
      if (post.rootId.isNotEmpty && post.replyKind == 'thread_broadcast' && !inThreadView)
        GestureDetector(
          onTap: () => openThread(context, post.channelId, post.rootId),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.forum_outlined, size: 14, color: pal.accentText),
              const SizedBox(width: 4),
              Text(tr('Trả lời trong luồng công việc riêng'), style: TextStyle(fontSize: 12.5, color: pal.accentText, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      if (post.rootId.isNotEmpty && !inThreadView) _Quote(root: root, mine: mine),
      if (!hidden && images.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 2),
          child: ChatMedia(post: post, images: images, sending: sendingMedia, maxWidth: maxW - 22),
        ),
      if (!hidden)
        for (final f in post.files.where((f) => !f.isImage)) _FileView(file: f),
      // Video đang gửi: hiện khung hình video kèm vòng tải.
      if (!hidden)
        for (final f in post.localFiles.where((f) => (f['mime'] as String? ?? '').startsWith('video/')))
          ChatVideo(localPath: f['path'] as String?, sending: post.sendState == SendState.sending),
      if (!hidden)
        for (final f in post.localFiles.where((f) {
          final m = f['mime'] as String? ?? '';
          return !m.startsWith('image/') && !m.startsWith('video/');
        }))
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
      if (post.message.isNotEmpty || hidden || agentRun != null || approval != null || streaming)
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
      child: videoOnly
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3, left: 4),
                  child: nameText('~${sender?.displayName ?? 'Người dùng'}',
                      bot: sender?.isBot == true, engine: engineOf(sender),
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WaColors.sender(post.userId))),
                ),
              Stack(children: [
                serverVideos.isNotEmpty
                    ? ChatVideo(file: serverVideos.first)
                    : ChatVideo(localPath: localVideos.first['path'] as String?, sending: post.sendState == SendState.sending),
                Positioned(
                  right: 8,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)),
                    child: metaIn(Colors.white),
                  ),
                ),
              ]),
            ])
          : imagesOnly
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3, left: 4),
                  child: GestureDetector(
                    onTap: sender == null ? null : () => openDirectWith(context, app, sender),
                    child: nameText('~${sender?.displayName ?? 'Người dùng'}',
                bot: sender?.isBot == true, engine: engineOf(sender),
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

    if (reactions.isNotEmpty && approval == null) {
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

    // Chip luồng bí mật dưới tin: ở chat chính (tin gốc) và cả tin trả lời trong trang luồng (luồng con nhiều tầng).
    final sub = (!inThreadView && post.rootId.isNotEmpty) ? null : app.subChannelForPost(post.id);
    if (sub != null) {
      bubble = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [bubble, SubChannelChip(sub: sub)],
      );
    }
    // Người không ở trong luồng riêng tư: không thấy nhãn luồng (chỉ thành viên luồng mới thấy chip ở trên).
    final thread = inThreadView || post.rootId.isNotEmpty ? null : app.threadSummary(post.channelId, post.id);
    if (thread != null) {
      bubble = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          _ThreadChip(channelId: post.channelId, rootId: post.id, onTap: () => openThread(context, post.channelId, post.id)),
        ],
      );
    }

    // Máy tính: giữ chuột lên tin rồi kéo sang cột AI để hỏi trợ lý (tạo phiên mới hoặc thêm vào phiên đang có).
    // Dùng giữ-rồi-kéo để không phá việc bôi đen chữ bằng chuột.
    if (isDesktop && post.sendState == SendState.sent && !channel.isAi && app.showsAiFor(channel)) {
      bubble = LongPressDraggable<MmPost>(
        data: post,
        delay: const Duration(milliseconds: 250),
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          color: pal.surface,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome, size: 16, color: pal.accentText),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(app.previewText(post).replaceAll('\n', ' '),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.text)),
                ),
              ]),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: .5, child: bubble),
        child: bubble,
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

  /// Lưu / chia sẻ các tệp của tin (điện thoại: bảng chia sẻ để lưu vào Tệp, Drive, gửi Zalo...;
  /// máy tính: tải về thư mục Tải về).
  Future<void> _shareFiles(BuildContext context, AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(toast(Text(tr('Đang tải {0} tệp...', [post.files.length]))));
    try {
      final paths = [for (final f in post.files) (await app.download(f)).path];
      if (Platform.isAndroid || Platform.isIOS) {
        await SharePlus.instance.share(ShareParams(files: [for (final p in paths) XFile(p)]));
      } else {
        messenger.showSnackBar(toast(Text(tr('Đã lưu vào thư mục Tải về'))));
      }
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không tải được file. Kiểm tra kết nối mạng.'))));
    }
  }

  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _actions(BuildContext context, AppState app, bool mine, {Rect? anchor}) {
    if (post.sendState != SendState.sent && post.sendState != SendState.failed) return;
    final sender = app.users[post.userId];
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
                      ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không ghim được tin này.'))));
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
        if (post.files.isNotEmpty && !post.isBurnOnRead)
          MenuAction(Icons.ios_share, isDesktop ? tr('Tải tệp về máy') : tr('Lưu / Chia sẻ'), () => _shareFiles(context, app)),
        if (imagesOf(post).isNotEmpty && !post.isBurnOnRead)
          MenuAction(Icons.image_outlined, tr('Sao chép ảnh'), () => copyChatImage(context, imagesOf(post).first)),
        // Luồng riêng tư: tin của mình hoặc của trợ lý AI của mình → gửi y hệt ra nhóm ngoài.
        if (channel.isSub && post.sendState == SendState.sent && (mine || app.isMyBot(post.userId)))
          MenuAction(Icons.campaign_outlined, tr('Báo ra ngoài'), () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await app.reportToParent(channel, post);
              messenger.showSnackBar(toast(Text(tr('Đã báo ra nhóm ngoài'))));
            } catch (_) {
              messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
            }
          }),
        // Tin trong luồng (của mình hoặc trợ lý AI của mình) → gửi y hệt thành tin mới ở chat chính.
        if (!channel.isSub && post.rootId.isNotEmpty && post.sendState == SendState.sent && (mine || app.isMyBot(post.userId)))
          MenuAction(Icons.reply_all_outlined, tr('Gửi ra nhóm chính'), () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await app.shareThreadPost(post);
              messenger.showSnackBar(toast(Text(tr('Đã gửi ra nhóm chính'))));
            } catch (_) {
              messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
            }
          }),
        // Nhóm: hỏi trợ lý AI về tin này (cột phải điền sẵn trích dẫn).
        // Gửi tin cho trợ lý: chọn phiên đang có hoặc tạo phiên mới (popup danh sách phiên).
        if (post.sendState == SendState.sent && app.showsAiFor(channel))
          MenuAction(Icons.auto_awesome, tr('Gửi cho trợ lý'), () async {
            var target = AppState.kAiNewSession;
            if (app.aiChannelsFor(channel.id).isNotEmpty) {
              final t = await showAiSessions(context, channel.id, sendMode: true);
              if (t == null) return;
              target = t;
            }
            if (context.mounted) askAiAbout(context, app, channel, post, target: target);
          }),
        // Cột AI: đưa tin ra nhóm chính — để trợ lý đăng (thả 📤, runner đăng dưới tên bot) hoặc tự gửi dưới tên mình.
        if (channel.isAi && post.sendState == SendState.sent && (post.message.isNotEmpty || post.files.isNotEmpty)) ...[
          MenuAction(Icons.smart_toy_outlined, tr('Gửi ra ngoài bằng bot'), () async {
            final messenger = ScaffoldMessenger.of(context);
            await app.toggleReaction(post, 'outbox_tray');
            messenger.showSnackBar(toast(Text(tr('Đã nhờ trợ lý gửi ra nhóm'))));
          }),
          MenuAction(Icons.outbox_outlined, tr('Gửi ra ngoài'), () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await app.shareAiPostOut(post, channel.aiGroup!);
              messenger.showSnackBar(toast(Text(tr('Đã gửi ra nhóm chính'))));
            } catch (_) {
              messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
            }
          }),
        ],
        if (post.message.isNotEmpty)
          MenuAction(Icons.copy, tr('Sao chép'), () {
            Clipboard.setData(ClipboardData(text: post.message));
            ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã sao chép'))));
          }),
        if (post.reactions.isNotEmpty)
          MenuAction(Icons.emoji_emotions_outlined, tr('Xem cảm xúc'), () => showReactionDetails(context, app, post)),
        if (!mine && post.sendState == SendState.sent) ...[
          MenuAction(Icons.flag_outlined, tr('Báo cáo'), () => reportPostDialog(context, app, post)),
          if (sender != null && !sender.isBot)
            MenuAction(Icons.block, tr('Chặn {0}', [sender.displayName]), danger: true, () => blockUserDialog(context, app, sender)),
        ],
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
                  style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                  onPressed: app.calls.busy ? null : () => app.calls.join(channel.id),
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

/// Nền viên thuốc mờ cho các nút nổi trên đầu khung chat (không có thanh nền chạy hết chiều ngang).
class _FloatPill extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  const _FloatPill({required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 2), this.radius = 26});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: pal.surface.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: pal.text.withValues(alpha: .08)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Báo kích thước con sau mỗi lần dựng (để chừa chỗ cho phần đầu nổi phía trên danh sách tin).
class _SizeReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const _SizeReporter({required this.onSize, super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);
  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  ValueChanged<Size> onSize;
  Size? _last;
  _RenderSizeReporter(this.onSize);
  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      final s = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onSize(s));
    }
  }
}

/// Dải "Đang họp · N người · Tham gia" dưới đầu khung chat khi kênh có cuộc gọi / cuộc họp đang diễn ra
/// mà mình chưa vào.
class _OngoingCallBanner extends StatefulWidget {
  final MmChannel channel;
  const _OngoingCallBanner({super.key, required this.channel});
  @override
  State<_OngoingCallBanner> createState() => _OngoingCallBannerState();
}

class _OngoingCallBannerState extends State<_OngoingCallBanner> {
  @override
  void initState() {
    super.initState();
    context.read<AppState>().calls.refreshChannel(widget.channel.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final ch = widget.channel;
    final calls = app.calls;
    final people = calls.ongoing[ch.id];
    final inThis = calls.busy && calls.channelId == ch.id;
    if (people == null || people.isEmpty || inThis) return const SizedBox.shrink();
    final label = ch.isDirect
        ? tr('Cuộc gọi đang diễn ra')
        : tr('Đang họp · {0} người', [people.length]);
    return Material(
      color: pal.accent,
      child: InkWell(
        onTap: calls.busy ? null : () => calls.join(ch.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Icon(ch.isDirect ? Icons.call : Icons.groups_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: Text(tr('Tham gia'), style: TextStyle(color: pal.accent, fontWeight: FontWeight.w700, fontSize: 13.5)),
            ),
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

/// Thanh tin ghim dưới tên kênh: chạm để nhảy tới tin ghim (nhiều tin thì lần lượt
/// từ mới đến cũ), nút danh sách để xem tất cả.
class _PinnedBanner extends StatefulWidget {
  final String channelId;
  const _PinnedBanner({required this.channelId});
  @override
  State<_PinnedBanner> createState() => _PinnedBannerState();
}

class _PinnedBannerState extends State<_PinnedBanner> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final list = app.pinnedIn(widget.channelId);
    if (list.isEmpty) return const SizedBox.shrink();
    final i = _i % list.length;
    final p = list[i];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: _FloatPill(
        radius: 16,
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () {
              app.requestJump(widget.channelId, p.id);
              setState(() => _i = i + 1);
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 14, top: 4, bottom: 4),
              child: Row(children: [
                Icon(Icons.push_pin, size: 18, color: pal.accentText),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(list.length == 1 ? tr('Tin đã ghim') : tr('Tin ghim {0}/{1}', [i + 1, list.length]),
                        style: TextStyle(color: pal.accentText, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    Text(app.previewText(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text, fontSize: 14.5)),
                  ]),
                ),
                IconButton(
                  tooltip: tr('Tất cả tin đã ghim'),
                  icon: Icon(Icons.format_list_bulleted, size: 20, color: pal.sub),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PinnedPage(channelId: widget.channelId))),
                ),
              ]),
            ),
          ),
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

/// Chữ thường, link và số điện thoại bấm được, @tên được tô màu (bấm để nhắn riêng).
List<InlineSpan> _linkify(String raw, Pal pal, void Function(String)? onMention) {
  final text = replaceShortcodes(raw);
  final code = TextStyle(fontFamily: 'monospace', fontSize: 15, backgroundColor: pal.text.withValues(alpha: .08));
  return linkSpans(text, pal, (t) => inlineMarkdown(t, code, (x) => mentionSpans(x, pal, onMention)));
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
    if (file.isVideo) return ChatVideo(file: file);
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
  messenger.showSnackBar(toast(Text(tr('Đang tải {0} mục...', [files.length]))));
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
    messenger.showSnackBar(toast(Text(tr('Không lưu được. Kiểm tra quyền truy cập ảnh và kết nối mạng.'))));
  }
}

Future<void> openFile(BuildContext context, MmFile file) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(toast(Text(tr('Đang tải {0}...', [file.name]))));
  try {
    final f = await app.download(file);
    if (Platform.isAndroid || Platform.isIOS) {
      // Điện thoại: mở bằng ứng dụng phù hợp (Android không cho mở file:// trực tiếp).
      await openLocalFile(f.path, mime: file.mime.isEmpty ? null : file.mime, title: file.name);
    } else {
      await launchUrl(Uri.file(f.path));
    }
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không tải được file. Kiểm tra kết nối mạng.'))));
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
                ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã lưu: {0}', [f.path]))));
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
  /// Ô nhắn tin trong trang chủ đề: mọi tin gửi là trả lời trong chủ đề của tin này.
  final String? threadRoot;
  const _Composer(
      {super.key,
      this.threadRoot,
      required this.channelId, this.replyTo, this.editing, required this.onCancelEdit, required this.onCancelReply, required this.onSent});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _ctl = TextEditingController();
  // Máy tính: Enter gửi, Shift+Enter / Ctrl+Enter xuống dòng. Bắt phím ngay trên ô nhập (trước khi ô nhập tự xuống dòng);
  // đang gõ dấu (bộ gõ còn chữ đang ghép) thì để Enter chốt chữ như thường.
  // Danh sách gợi ý @tên: mũi tên lên/xuống chọn, Enter (hoặc Tab) chèn, Esc đóng.
  late final _focus = FocusNode(onKeyEvent: (node, e) {
    if (!_desktop || (e is! KeyDownEvent && e is! KeyRepeatEvent)) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (_mentionList.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
        final n = _mentionList.length;
        setState(() => _mentionIndex = (_mentionIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : n - 1)) % n);
        _revealMention();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(() => _mentionList = []);
        return KeyEventResult.handled;
      }
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final enter = key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;
    if (_mentionList.isNotEmpty && (enter || key == LogicalKeyboardKey.tab)) {
      _insertMention(_mentionList[_mentionIndex.clamp(0, _mentionList.length - 1)]);
      return KeyEventResult.handled;
    }
    if (!enter || HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    // Ctrl+Enter: ô nhập không tự xuống dòng với tổ hợp này, chèn tay ký tự xuống dòng tại con trỏ.
    if (HardwareKeyboard.instance.isControlPressed) {
      final v = _ctl.value;
      final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
      _ctl.value = v.replaced(TextRange(start: sel.start, end: sel.end), '\n');
      return KeyEventResult.handled;
    }
    if (_ctl.value.composing.isValid && !_ctl.value.composing.isCollapsed) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  });
  int _mentionIndex = 0;
  final _mentionScroll = ScrollController();
  static const _mentionRowH = 58.0;
  /// Cuộn danh sách gợi ý để dòng đang chọn (bằng mũi tên) luôn nằm trong tầm nhìn.
  void _revealMention() {
    if (!_mentionScroll.hasClients) return;
    final pos = _mentionScroll.position;
    final top = 4 + _mentionIndex * _mentionRowH;
    final bottom = top + _mentionRowH;
    if (top < pos.pixels) {
      _mentionScroll.jumpTo(top - 4);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _mentionScroll.jumpTo((bottom + 4 - pos.viewportDimension).clamp(0, pos.maxScrollExtent));
    }
  }
  DateTime _lastTyping = DateTime(2000);
  /// Trả lời một tin của bot: điền sẵn "@bot " ở đầu ô nhắn tin (xóa đi thì bot không tự trả lời).
  void mentionBotOf(MmPost p) {
    final u = context.read<AppState>().users[p.userId];
    if (u == null || !u.isBot) return;
    final tag = '@${u.username} ';
    if (_ctl.text.contains('@${u.username}')) return;
    _ctl.value = TextEditingValue(text: tag + _ctl.text, selection: TextSelection.collapsed(offset: tag.length + _ctl.text.length));
    setState(() {});
  }

  /// Tệp kéo thả vào, chờ gửi kèm nội dung đang soạn.
  final List<(String, String)> _staged = [];

  /// Bộ nhớ tạm có ảnh / tệp (để hiện "Dán ảnh").
  bool _clipHasMedia = false;

  Future<void> _refreshClip() async {
    final has = await clipboardHasMedia();
    if (mounted && has != _clipHasMedia) setState(() => _clipHasMedia = has);
  }

  Future<void> _pasteMedia() async {
    final files = await readClipboardMedia();
    if (files.isNotEmpty && mounted) stage(files);
  }

  /// Tệp vừa chọn (tài liệu, ảnh, ảnh chụp): đưa vào danh sách chờ phía trên ô nhắn tin,
  /// chỉ gửi khi bấm gửi. [caption] (từ màn xem lại ảnh) điền vào ô nhắn tin.
  void _stageFiles(List<(String, String)> files, {String caption = ''}) {
    if (caption.trim().isNotEmpty && _ctl.text.trim().isEmpty) {
      _ctl.text = caption.trim();
      _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    }
    stage(files);
  }

  void stage(List<(String, String)> files) {
    if (files.isEmpty) return;
    setState(() => _staged.addAll(files.where((f) => !_staged.any((s) => s.$1 == f.$1))));
    _focus.requestFocus();
  }

  bool get _desktop =>
      Theme.of(context).platform == TargetPlatform.macOS ||
      Theme.of(context).platform == TargetPlatform.windows ||
      Theme.of(context).platform == TargetPlatform.linux;

  @override
  void didUpdateWidget(covariant _Composer old) {
    super.didUpdateWidget(old);
    if (widget.replyTo != null && widget.replyTo != old.replyTo) {
      mentionBotOf(widget.replyTo!);
      _focus.requestFocus();
    }
    if (widget.editing != null && widget.editing != old.editing) {
      _ctl.text = widget.editing!.message;
      _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
      _focus.requestFocus();
    }
    if (widget.editing == null && old.editing != null) _ctl.clear();
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        closePanel();
        _refreshClip();
      }
    });
    _aiApp = context.read<AppState>();
    _aiApp.aiAsk.addListener(_onAiAsk);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAiAsk());
  }

  late final AppState _aiApp;

  /// Tin / luồng ở nhóm đính kèm vào tin sắp gửi cho trợ lý (từ "Hỏi trợ lý" hoặc kéo thả).
  Map<String, dynamic>? _aiRef;
  String _aiQuote = '';

  /// Agent khác (phiên AI đang chạy) được kết nối vào tin gửi đi: trợ lý của phiên này trao đổi với chúng
  /// qua A2A (props flygo_a2a_peers). Giữ nguyên sau khi gửi cho tới khi bỏ.
  final List<Map<String, dynamic>> _a2aPeers = [];

  // ---------------------------------------------------------------- chọn trợ lý trong chat AI cột phải
  String? _aiBot;

  /// Trợ lý của mình trong chat AI cột phải (rỗng nếu không phải chat AI).
  List<MmUser> _aiBots(AppState app) {
    if (app.channels[widget.channelId]?.isAi != true) return const [];
    final l = app.users.values.where((u) => u.isBot && app.isMyBot(u.id) && engineOf(u) != null).toList()
      ..sort((a, b) => a.username.compareTo(b.username));
    return l;
  }

  String? _aiBotName(AppState app) {
    final l = _aiBots(app);
    if (l.isEmpty) return null;
    if (_aiBot == null || !l.any((u) => u.username == _aiBot)) {
      _aiBot = l.first.username;
      // Mặc định chèn sẵn @trợ lý vào ô nhắn tin trống.
      if (_ctl.text.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _ctl.text.isEmpty) _pickAiBot(_aiBot!);
        });
      }
    }
    return _aiBot;
  }

  /// Nút chọn chung trợ lý + mô hình trong chat AI cột phải.
  Widget _aiModelPicker(AppState app, Pal pal) {
    final bots = _aiBots(app);
    final cur = bots.where((b) => b.username == _aiBotName(app)).firstOrNull ?? bots.first;
    final curO = agentOptionsOf(cur);
    final curModel = curO == null ? '' : _configOf(app, cur, curO).$1;
    return PopupMenuButton<(MmUser, String)>(
      tooltip: tr('Chọn trợ lý và mô hình'),
      color: pal.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      position: PopupMenuPosition.over,
      offset: Offset(0, -(bots.fold<int>(0, (n, b) => n + 1 + (agentOptionsOf(b)?.models.length ?? 0)) * 40.0 + 22)),
      onSelected: (v) async {
        final (bot, model) = v;
        _pickAiBot(bot.username);
        final o = agentOptionsOf(bot);
        if (o != null) await app.setAgentConfig(bot.id, model, _configOf(app, bot, o).$2);
        if (mounted) setState(() {});
      },
      itemBuilder: (_) => [
        for (final b in bots) ...[
          PopupMenuItem<(MmUser, String)>(
            enabled: false,
            height: 36,
            child: Row(children: [
              EngineIcon(engineOf(b) ?? '', size: 16, color: pal.text),
              const SizedBox(width: 8),
              Text('@${b.username}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.sub)),
            ]),
          ),
          for (final m in agentOptionsOf(b)?.models ?? const <String>[])
            PopupMenuItem<(MmUser, String)>(
              value: (b, m),
              height: 40,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.only(left: 24),
                child: Text(m,
                    style: TextStyle(
                        fontSize: 14,
                        color: b.id == cur.id && m == curModel ? pal.accentText : pal.text,
                        fontWeight: b.id == cur.id && m == curModel ? FontWeight.w700 : FontWeight.normal)),
              ),
            ),
        ],
      ],
      child: _ChipLook(
        pal: pal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          EngineIcon(engineOf(cur) ?? '', size: 15, color: pal.text),
          const SizedBox(width: 7),
          Text('@${cur.username}${curModel.isEmpty ? '' : ' · $curModel'}', style: TextStyle(fontSize: 13, color: pal.text)),
          Icon(Icons.expand_more_rounded, size: 17, color: pal.sub),
        ]),
      ),
    );
  }

  /// Chọn trợ lý: thay @tên ở đầu ô nhắn tin (hoặc chèn mới).
  void _pickAiBot(String username) {
    final rest = _ctl.text.replaceFirst(RegExp(r'^\s*@[\w.\-]+\s*'), '');
    final text = '@$username $rest';
    _ctl.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() => _aiBot = username);
  }

  /// Chat AI cột phải: nhận "Hỏi trợ lý" từ nhóm → điền sẵn trích dẫn vào ô nhắn tin.
  void _onAiAsk() {
    final v = _aiApp.aiAsk.value;
    if (v == null || !mounted || widget.threadRoot != null) return;
    if (_aiApp.channels[widget.channelId]?.aiGroup != v.groupId) return;
    // Phiên mới: cột AI tạo phiên rồi chuyển lời hỏi sang phiên đó; tin dành cho phiên khác thì bỏ qua.
    if (v.target != null && v.target != widget.channelId) return;
    _aiApp.aiAsk.value = null;
    // Tin đính kèm hiện thành thanh "đang gửi kèm" (như trả lời tin); ô nhắn tin giữ nguyên để dặn thêm.
    if (v.ref != null) {
      _aiRef = v.ref;
      _aiQuote = v.text;
    } else if (v.text.isNotEmpty) {
      final cur = _ctl.text.trimRight();
      _ctl.text = cur.isEmpty ? v.text : '$cur\n\n${v.text}';
    }
    _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    _focus.requestFocus();
    setState(() {});
  }

  @override
  void dispose() {
    _aiApp.aiAsk.removeListener(_onAiAsk);
    _ctl.dispose();
    _focus.dispose();
    _mentionScroll.dispose();
    super.dispose();
  }

  String get _rootId {
    if (widget.threadRoot != null) return widget.threadRoot!;
    final r = widget.replyTo;
    return r == null ? '' : (r.rootId.isNotEmpty ? r.rootId : r.id);
  }

  /// Trong luồng công việc riêng: tin chỉ nằm trong luồng (không gửi ra chat chính).
  /// Chat chính: trả lời (trích dẫn) một tin là 'quote' — vẫn ở chat chính, bot cũng trả lời ở chat chính,
  /// không tạo luồng riêng (chỉ nút "Mở luồng riêng" mới tạo luồng).
  String get _replyKind => widget.threadRoot != null ? 'thread' : (widget.replyTo != null ? 'quote' : '');

  /// Chat chính: cách gửi tin — '' (bình thường), 'open' (mở luồng riêng ai cũng xem được),
  /// 'secret' (luồng bí mật: kênh con chỉ người được mời/tag vào được).
  String _threadMode = '';

  /// Những người và bot được tag trong nội dung đang soạn.
  /// Trợ lý AI sẽ nhận tin này: bot được tag (@tên) hoặc bot ở chat 1-1.
  List<(MmUser, AgentOptions)> _taggedAgents(AppState app) {
    final out = <(MmUser, AgentOptions)>[];
    final direct = _directBot(app);
    final names = RegExp(r'@([a-z0-9._-]+)', caseSensitive: false).allMatches(_ctl.text).map((m) => m.group(1)!.toLowerCase()).toSet();
    for (final u in app.users.values) {
      if (!u.isBot || (u.id != direct?.id && !names.contains(u.username.toLowerCase()))) continue;
      final o = agentOptionsOf(u);
      if (o != null) out.add((u, o));
    }
    return out;
  }

  (String, String) _configOf(AppState app, MmUser bot, AgentOptions o) {
    final c = app.agentConfig[bot.id];
    final m = c?['model'], e = c?['effort'];
    return (m != null && o.models.contains(m) ? m : o.defModel, e != null && o.efforts.contains(e) ? e : o.defEffort);
  }

  /// props.flygo_agent_config cho tin gửi trợ lý AI (null nếu không có trợ lý nào).
  Map<String, dynamic>? _agentProps(AppState app) {
    final agents = _taggedAgents(app);
    if (agents.isEmpty) return null;
    return {
      'flygo_agent_config': {
        for (final (u, o) in agents)
          u.username: {'model': _configOf(app, u, o).$1, 'effort': _configOf(app, u, o).$2},
      },
    };
  }

  /// Bot ở đầu bên kia của chat 1-1 (null nếu không phải chat 1-1 với bot).
  MmUser? _directBot(AppState app) {
    final ch = app.channels[widget.channelId];
    if (ch == null || !ch.isDirect || app.me == null) return null;
    final u = app.users[ch.otherUserId(app.me!.id)];
    return u != null && u.isBot ? u : null;
  }

  /// Ô "Bắt đầu công việc trong luồng riêng tư" luôn hiện ở chat chính của nhóm / kênh, và ở chat 1-1 với bot.
  bool _canPrivateThread(AppState app) {
    final ch = app.channels[widget.channelId];
    if (widget.threadRoot != null || widget.editing != null || _rootId.isNotEmpty || ch == null || ch.isGroupDm) return false;
    // Chat AI cột phải đã là riêng tư: chỉ có "Mở luồng riêng", không có "Bí mật".
    if (ch.isAi) return true;
    return !ch.isDirect || _directBot(app) != null;
  }

  List<MmUser> _taggedPeople(AppState app) {
    if (!_canPrivateThread(app)) return const [];
    final bot = _directBot(app);
    if (bot != null) return [bot];
    final names = RegExp(r'@([a-z0-9._-]+)', caseSensitive: false)
        .allMatches(_ctl.text)
        .map((m) => m.group(1)!.toLowerCase().replaceAll(RegExp(r'[._-]+$'), ''))
        .toSet();
    if (names.isEmpty) return const [];
    return app.users.values.where((u) => names.contains(u.username.toLowerCase()) && u.id != app.me?.id).toList();
  }

  /// Gửi tin vào chat chính, rồi mở luồng riêng tư với những người/bot được tag (tin vừa gửi là tin gốc).
  /// Tin ở chat chính mang `flygo_private_thread` để bot không trả lời ngoài chat chính, chỉ trả lời trong luồng.
  Future<void> _sendToPrivateThread(String text, List<MmUser> people) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ch = app.channels[widget.channelId]!;
    final saved = await app.send(widget.channelId, text, props: {'flygo_private_thread': true, ...?_agentProps(app)});
    if (saved == null) {
      messenger.showSnackBar(toast(Text(tr('Không tạo được luồng riêng. Kiểm tra kết nối mạng.'))));
      return;
    }
    final plain = plainPreview(text).replaceAll('\n', ' ').trim();
    final name = plain.length > 40 ? '${plain.substring(0, 40)}…' : plain;
    try {
      final id = await app.createSubChannel(ch, saved, name.isEmpty ? tr('Luồng riêng') : name, [for (final u in people) u.id]);
      if (mounted) openPrivateThread(context, id);
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không tạo được luồng riêng. Kiểm tra kết nối mạng.'))));
    }
  }

  /// "Mở luồng riêng": gửi tin bình thường vào chat này (ai cũng thấy), rồi mở ngay luồng của tin đó.
  /// Bot thấy `flygo_open_thread` thì trả lời trong luồng dưới tin gốc.
  Future<void> _sendOpenThread(String text) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final saved = await app.send(widget.channelId, text, props: {'flygo_open_thread': true, ...?_agentProps(app)});
    if (saved == null) {
      messenger.showSnackBar(toast(Text(tr('Không mở được luồng. Kiểm tra kết nối mạng.'))));
      return;
    }
    if (mounted) openThread(context, widget.channelId, saved.id);
  }

  void _send() {
    var text = _ctl.text.trim();
    // Cột AI có tin đính kèm: gửi trích dẫn + lời dặn (lời dặn có thể để trống).
    if (_aiRef != null && widget.editing == null && _staged.isEmpty) text = '$_aiQuote$text'.trim();
    if (_staged.isNotEmpty && widget.editing == null) {
      final files = [for (final (path, name) in _staged) (path, name, File(path).readAsBytes)];
      setState(_staged.clear);
      _sendFiles(files, caption: text);
      return;
    }
    if (text.isEmpty) return;
    final editing = widget.editing;
    if (editing != null) {
      final messenger = ScaffoldMessenger.of(context);
      context.read<AppState>().editPost(editing, text).catchError((_) {
        messenger.showSnackBar(toast(Text(tr('Không sửa được tin. Kiểm tra kết nối mạng.'))));
      });
      _ctl.clear();
      setState(() {});
      widget.onSent();
      return;
    }
    final app = context.read<AppState>();
    if (_threadMode == 'secret' && _canPrivateThread(app)) {
      _sendToPrivateThread(text, _taggedPeople(app));
    } else if (_threadMode == 'open' && _canPrivateThread(app)) {
      _sendOpenThread(text);
    } else {
      final ref = _aiRef;
      app.send(widget.channelId, text,
          rootId: _rootId,
          replyKind: _replyKind,
          props: {
            ...?_agentProps(app),
            'flygo_ai_ref': ?ref,
            if (_a2aPeers.isNotEmpty) 'flygo_a2a_peers': [for (final x in _a2aPeers) Map.of(x)],
          });
    }
    _aiRef = null;
    _aiQuote = '';
    _ctl.clear();
    setState(() => _threadMode = '');
    // Chat AI: chèn sẵn lại @trợ lý đang chọn cho tin tiếp theo.
    if (_aiBot != null && _aiBots(app).isNotEmpty) _pickAiBot(_aiBot!);
    widget.onSent();
  }

  /// Gửi file: tin hiện ngay với ảnh trên máy, tải lên chạy nền.
  Future<void> _sendFiles(List<(String?, String, Future<List<int>> Function())> files, {String caption = ''}) async {
    if (files.isEmpty) return;
    final app = context.read<AppState>();
    final dir = await getTemporaryDirectory();
    final items = <(String, String, String, double)>[];
    for (final (path0, name0, read) in files.take(10)) {
      var path = path0;
      // Tên tệp rỗng (thư viện ảnh iPhone) thì lấy theo đường dẫn; máy chủ không nhận tệp không tên.
      var name = name0.trim();
      if (name.isEmpty) name = (path ?? '').split(Platform.pathSeparator).last;
      if (name.isEmpty) name = 'file_${DateTime.now().millisecondsSinceEpoch}';
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
    await app.sendMedia(widget.channelId, items, text: text, rootId: _rootId, replyKind: _replyKind);
    if (!mounted) return;
    if (app.uploadTooLarge) {
      ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('File quá lớn so với giới hạn của máy chủ.'))));
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

  Future<void> _pickDocuments({bool images = false, bool media = false}) async {
    final files = await FilePicker.pickFiles(type: media ? FileType.media : (images ? FileType.image : FileType.any));
    _stageFiles([for (final f in files) if (f.path != null) (f.path!, f.name)]);
  }

  /// Dấu "+": điện thoại mở bảng ảnh (máy ảnh trực tiếp + ảnh trong máy);
  /// máy tính mở hộp chọn file.
  /// Nút 📷: bảng ảnh (máy ảnh trực tiếp + ảnh trong máy). Máy tính: chọn ảnh.
  Future<void> _photos() async {
    if (_desktop) return _pickDocuments(images: true);
    _focus.unfocus();
    closePanel();
    final r = await showMediaPicker(context);
    if (r == null || !mounted) return;
    if (r.openGallery) return _gallery();
    _stageFiles([for (final m in r.files) (m.path, m.name)], caption: r.caption);
  }

  /// Bộ chọn ảnh của hệ điều hành: không cần quyền truy cập thư viện.
  Future<void> _gallery() async {
    final files = await FilePicker.pickFiles(type: FileType.media);
    _stageFiles([for (final f in files) if (f.path != null) (f.path!, f.name)]);
  }

  Future<void> _camera({bool video = false}) async {
    final r = await Navigator.of(context).push<MediaPickResult>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => CameraCapturePage(videoMode: video)),
    );
    if (r == null || !mounted) return;
    _stageFiles([for (final m in r.files) (m.path, m.name)], caption: r.caption);
  }

  /// Nút "+": Chọn file, Tạo việc, Quay video, Chụp ảnh, Thư viện, Ghi âm.
  Future<void> _attach() async {
    _focus.unfocus();
    closePanel();
    final a = await showAttachPanel(context);
    if (a == null || !mounted) return;
    await _runAttach(a);
  }

  /// Máy tính: "+" mở danh sách dọc ngay phía trên nút (như WhatsApp bản máy tính).
  Future<void> _attachMenu(BuildContext btn) async {
    closePanel();
    final pal = Pal.of(context);
    final box = btn.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    const items = [
      (AttachAction.file, Icons.description, 'Tài liệu', Color(0xFF7F66FF)),
      (AttachAction.gallery, Icons.photo_library, 'Ảnh và video', Color(0xFF1F7AEC)),
      (AttachAction.voice, Icons.mic, 'Ghi âm', Color(0xFFFA6533)),
      (AttachAction.task, Icons.task_alt, 'Tạo việc', Color(0xFF02A698)),
    ];
    const itemH = 48.0;
    final a = await showMenu<AttachAction>(
      context: context,
      position: RelativeRect.fromLTRB(
          topLeft.dx, topLeft.dy - items.length * itemH - 20, overlay.size.width - topLeft.dx - 240, overlay.size.height - topLeft.dy),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      constraints: const BoxConstraints(minWidth: 230),
      items: [
        for (final (v, icon, label, color) in items)
          PopupMenuItem(
            value: v,
            height: itemH,
            child: Row(children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 14),
              Text(tr(label), style: TextStyle(color: pal.text, fontSize: 15.5)),
            ]),
          ),
      ],
    );
    if (a == null || !mounted) return;
    await _runAttach(a);
  }

  /// Ghi âm rồi gửi tin nhắn thoại.
  Future<void> _voice() async {
    _focus.unfocus();
    closePanel();
    await _handleVoice(await showVoiceRecorder(context));
  }

  /// Kết quả ghi âm: gửi tin thoại, hoặc điền chữ đã nhận diện vào ô nhắn tin.
  Future<void> _handleVoice(VoiceResult? r) async {
    if (r == null) return;
    if (r.text != null) {
      // Chuyển thành văn bản: điền vào ô nhắn tin (nối sau nội dung đang soạn), người dùng sửa rồi tự gửi.
      final cur = _ctl.text;
      final t = cur.isEmpty || cur.endsWith(' ') || cur.endsWith('\n') ? '$cur${r.text}' : '$cur ${r.text}';
      _ctl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
      setState(() {});
      _focus.requestFocus();
      return;
    }
    final path = r.path!;
    await _sendFiles([(path, path.split('/').last, File(path).readAsBytes)]);
  }

  Future<void> _runAttach(AttachAction a) async {
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
        // Máy tính không có thư viện ảnh của máy: chọn ảnh / video từ ổ đĩa.
        _desktop ? await _pickDocuments(media: true) : await _gallery();
      case AttachAction.voice:
        await _handleVoice(await showVoiceRecorder(context));
    }
  }

  /// Bảng biểu tượng / sticker / GIF nằm dưới ô nhắn tin (đẩy ô nhắn tin lên như bàn phím).
  bool _panel = false;

  /// Máy tính: bảng biểu tượng nổi phía trên ô nhắn tin (không đẩy khung chat).
  final _panelLink = LayerLink();
  final _panelOverlay = OverlayPortalController();
  static const _panelTapGroup = 'flygo-expression-panel';

  void closePanel() {
    if (_panel) setState(() => _panel = false);
    if (_panelOverlay.isShowing) _panelOverlay.hide();
  }

  void _expressions() {
    if (_panel) {
      closePanel();
      _focus.requestFocus();
      return;
    }
    if (_desktop) {
      setState(() => _panel = true);
      _panelOverlay.show();
      return;
    }
    _focus.unfocus();
    setState(() => _panel = true);
  }

  Widget _expressionPanel() => ExpressionPanel(
      tapGroup: _desktop ? _panelTapGroup : null,
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
            rootId: _rootId, replyKind: _replyKind, props: {if (g.sticker) 'flygo_sticker': true, 'flygo_media_aspect': g.aspect});
        widget.onSent();
      },
    );

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
    final members = await app.channelUsers(widget.channelId);
    final myBots = await app.myBotIds();
    if (!mounted) return;
    // Người và bot trong kênh trước, sau đó tới những người / bot khác trong công ty.
    final ids = {for (final u in members) u.id};
    final others = app.users.values.where((u) => !ids.contains(u.id) && u.deleteAt == 0).toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    bool match(MmUser u) => q.isEmpty || u.username.toLowerCase().contains(q) || u.displayName.toLowerCase().contains(q);
    // Nhắc cả nhóm (không có trong tin nhắn riêng).
    final ch = app.channels[widget.channelId];
    final specials = ch == null || ch.isDirect
        ? const <MmUser>[]
        : [
            MmUser({'id': '__all', 'username': 'all', 'first_name': tr('Thông báo tới mọi người trong kênh'), '_special': true}),
            MmUser({'id': '__channel', 'username': 'channel', 'first_name': tr('Thông báo tới mọi người trong kênh'), '_special': true}),
            MmUser({'id': '__here', 'username': 'here', 'first_name': tr('Thông báo tới người đang trực tuyến'), '_special': true}),
          ].where((u) => q.isEmpty || u.username.startsWith(q)).toList();
    if (_mentionScroll.hasClients) _mentionScroll.jumpTo(0);
    setState(() {
      _mentionIndex = 0;
      _mentionList = [
        // Trợ lý AI của mình luôn ở đầu danh sách (kể cả khi chưa có trong nhóm: gửi tin sẽ tự thêm vào).
        // Bot khác chỉ hiện khi mình có quyền gọi.
        ...[
          ...[...members, ...others].where((u) => myBots.contains(u.id)),
          ...[...members, ...others].where((u) => !myBots.contains(u.id)),
        ].where((u) => u.id != app.me?.id && match(u) && app.canCallBot(u, myBots)).take(8),
        ...specials,
      ];
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
          messenger.showSnackBar(toast(Text(tr('Thời điểm hẹn đã qua.'))));
          return;
        }
        try {
          await app.schedule(widget.channelId, text, at, rootId: _rootId);
          _ctl.clear();
          setState(() {});
          widget.onSent();
          messenger.showSnackBar(toast(Text(tr('Đã hẹn gửi lúc {0} ngày {1}', [hhmm(at), ddmmyyyy(at)]))));
        } catch (_) {
          messenger.showSnackBar(toast(Text(tr('Hẹn giờ không thành công. Kiểm tra kết nối mạng.'))));
        }
      case 'important' || 'urgent':
        app.send(widget.channelId, text, rootId: _rootId, replyKind: _replyKind, priority: choice, requestAck: true);
        _ctl.clear();
        setState(() {});
        widget.onSent();
      case 'burn':
        app.send(widget.channelId, text, rootId: _rootId, replyKind: _replyKind, burnOnRead: true);
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
    final hasText = _ctl.text.trim().isNotEmpty || _staged.isNotEmpty || _aiRef != null;
    final composer = SafeArea(
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
              // Material riêng để màu dòng đang chọn vẽ trên nền hộp (không bị nền hộp che mất).
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  controller: _mentionScroll,
                  itemExtent: _mentionRowH,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                for (final (i, u) in _mentionList.indexed)
                  u.raw['_special'] == true
                      ? ListTile(
                          dense: true,
                          selected: _desktop && i == _mentionIndex,
                          selectedTileColor: pal.accent.withValues(alpha: .28),
                          leading: CircleAvatar(
                            radius: 17,
                            backgroundColor: pal.accent.withValues(alpha: .15),
                            child: Icon(u.username == 'here' ? Icons.wifi_tethering : Icons.campaign, size: 19, color: pal.accentText),
                          ),
                          title: Text('@${u.username}', style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
                          subtitle: Text(u.raw['first_name'] as String, style: TextStyle(color: pal.sub)),
                          onTap: () => _insertMention(u),
                        )
                      : ListTile(
                          dense: true,
                          selected: _desktop && i == _mentionIndex,
                          selectedTileColor: pal.accent.withValues(alpha: .28),
                          leading: Avatar(userId: u.id, name: u.displayName, size: 34, icon: u.isBot ? Icons.smart_toy_outlined : null),
                          title: nameText(u.displayName, bot: u.isBot, engine: engineOf(u), style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                          subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
                          onTap: () => _insertMention(u),
                        ),
              ]),
              ),
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
          if (_aiRef != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: AiRefBar(
                ref: _aiRef!,
                quote: _aiQuote,
                onCancel: () => setState(() {
                  _aiRef = null;
                  _aiQuote = '';
                }),
              ),
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
          // Một hàng nút chọn cùng kiểu: trợ lý AI được tag (mô hình + mức suy nghĩ cho tin này),
          // "Mở luồng riêng", "Bí mật".
          if (_taggedAgents(app).isNotEmpty || _canPrivateThread(app) || app.channels[widget.channelId]?.isAi == true)
            // Nghe AppState: đổi mô hình / mức thông minh (ở máy này hoặc máy khác) là nút cập nhật ngay.
            ListenableBuilder(
              listenable: app,
              builder: (context, _) => Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 8, 6),
                child: Wrap(spacing: 8, runSpacing: 4, children: [
                  // Chat AI cột phải: MỘT nút chọn chung "trợ lý + mô hình" (Claude / OpenAI…); chọn là chèn @tên
                  // vào ô nhắn tin và lưu mô hình cho trợ lý đó. Nút mức thông minh giữ nguyên bên cạnh.
                  if (_aiBots(app).isNotEmpty) _aiModelPicker(app, pal),
                  // Chat AI: kết nối agent khác (phiên AI đang chạy) để hai agent trao đổi qua A2A.
                  if (app.channels[widget.channelId]?.isAi == true) ...[
                    for (final peer in _a2aPeers)
                      InputChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        avatar: Icon(Icons.swap_horiz_rounded, size: 16, color: pal.accentText),
                        label: Text('@${peer['username']} · ${peer['title']}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.accentText)),
                        onDeleted: () => setState(() => _a2aPeers.remove(peer)),
                      ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      tooltip: tr('Kết nối agent khác để giao việc chéo (A2A)'),
                      avatar: Icon(Icons.add, size: 16, color: pal.accentText),
                      label: Text(_a2aPeers.isEmpty ? tr('Agent') : tr('Thêm'), style: TextStyle(fontSize: 13, color: pal.accentText)),
                      onPressed: () async {
                        final peer = await pickA2aPeer(context, widget.channelId);
                        if (peer != null && !_a2aPeers.any((x) => x['session_id'] == peer['session_id'])) {
                          setState(() => _a2aPeers.add(peer));
                        }
                      },
                    ),
                  ],
                  for (final (bot, o) in _taggedAgents(app)) ...[
                    // Nút 1: tên bot + mô hình → menu chọn mô hình (chat AI cột phải đã có nút chọn chung).
                    if (app.channels[widget.channelId]?.isAi != true)
                    PopupMenuButton<String>(
                      tooltip: tr('Mô hình'),
                      color: pal.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      constraints: const BoxConstraints(minWidth: 180),
                      // Mở lên phía trên nút (menu cao = số mô hình × 40 + lề 16).
                      position: PopupMenuPosition.over,
                      offset: Offset(0, -(o.models.length * 40.0 + 22)),
                      onSelected: (m) async {
                        await app.setAgentConfig(bot.id, m, _configOf(app, bot, o).$2);
                        if (mounted) setState(() {});
                      },
                      itemBuilder: (_) => [
                        for (final m in o.models)
                          PopupMenuItem(
                            value: m,
                            height: 40,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            // Mô hình đang dùng: tô nền + chữ đậm màu nhấn (không dùng dấu tích).
                            child: Container(
                              width: double.infinity,
                              height: 36,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: m == _configOf(app, bot, o).$1 ? pal.accent.withValues(alpha: .18) : null,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(m,
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: m == _configOf(app, bot, o).$1 ? pal.accentText : pal.text,
                                      fontWeight: m == _configOf(app, bot, o).$1 ? FontWeight.w600 : FontWeight.normal)),
                            ),
                          ),
                      ],
                      child: _ChipLook(
                        pal: pal,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          EngineIcon(o.engine, size: 15, color: pal.sub),
                          const SizedBox(width: 7),
                          Text('@${bot.username} · ${_configOf(app, bot, o).$1}', style: TextStyle(fontSize: 13, color: pal.sub)),
                          Icon(Icons.expand_more_rounded, size: 17, color: pal.sub),
                        ]),
                      ),
                    ),
                    // Nút 2: vạch mức thông minh → thanh kéo.
                    PopupMenuButton<Never>(
                      tooltip: tr('Mức thông minh'),
                      color: pal.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      position: PopupMenuPosition.over,
                      offset: const Offset(0, -132.0),
                      itemBuilder: (_) => [
                        EffortSliderEntry(
                          options: o,
                          effort: _configOf(app, bot, o).$2,
                          onChanged: (e) async {
                            await app.setAgentConfig(bot.id, _configOf(app, bot, o).$1, e);
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                      child: _ChipLook(
                        pal: pal,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: EffortBars(effort: _configOf(app, bot, o).$2, color: pal.accentText),
                        ),
                      ),
                    ),
                  ],
                  // Chat AI không mở luồng: mỗi việc là một phiên riêng (danh sách phiên ở đầu cột AI).
                  if (_canPrivateThread(app) && app.channels[widget.channelId]?.isAi != true)
                    for (final (mode, icon, label) in [
                      ('open', Icons.forum_outlined, tr('Mở luồng riêng')),
                      ('secret', Icons.lock_outline_rounded, tr('Bí mật')),
                    ])
                      FilterChip(
                        selected: _threadMode == mode,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        avatar: Icon(icon, size: 16, color: _threadMode == mode ? pal.accentText : pal.sub),
                        label: Text(label,
                            style: TextStyle(
                                fontSize: 13,
                                color: _threadMode == mode ? pal.accentText : pal.sub,
                                fontWeight: _threadMode == mode ? FontWeight.w600 : FontWeight.normal)),
                        backgroundColor: pal.surface,
                        selectedColor: pal.accent.withValues(alpha: .16),
                        side: BorderSide(color: _threadMode == mode ? pal.accent : pal.divider),
                        shape: const StadiumBorder(),
                        tooltip: mode == 'open'
                            ? tr('Gửi tin vào chat này và mở luồng riêng, ai trong chat cũng xem được')
                            : tr('Mở luồng bí mật, chỉ những người được mời mới vào được'),
                        onSelected: (v) => setState(() => _threadMode = v ? mode : ''),
                      ),
                ]),
              ),
            ),
            ),
          if (_staged.isNotEmpty)
            Container(
              height: 76,
              margin: const EdgeInsets.only(bottom: 6),
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final f in _staged)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Stack(clipBehavior: Clip.none, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _mimeOf(f.$2).startsWith('image/')
                            ? Image.file(File(f.$1), width: 72, height: 72, fit: BoxFit.cover)
                            : Container(
                                width: 140,
                                height: 72,
                                padding: const EdgeInsets.all(8),
                                color: pal.surface,
                                child: Row(children: [
                                  Icon(Icons.insert_drive_file_outlined, color: pal.accentText),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(f.$2,
                                        maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: pal.text)),
                                  ),
                                ]),
                              ),
                      ),
                      Positioned(
                        right: -6,
                        top: -6,
                        child: GestureDetector(
                          onTap: () => setState(() => _staged.remove(f)),
                          child: CircleAvatar(radius: 11, backgroundColor: pal.surface2, child: Icon(Icons.close, size: 14, color: pal.text)),
                        ),
                      ),
                    ]),
                  ),
              ]),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 46),
                decoration: BoxDecoration(
                  color: pal.surface,
                  borderRadius: BorderRadius.circular(23),
                  border: Border.all(color: pal.text.withValues(alpha: .06)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  // Máy tính: "+" và biểu tượng nằm trong ô, bên trái. Điện thoại: chỉ biểu tượng.
                  if (_desktop)
                    Builder(
                      builder: (b) => IconButton(
                        icon: Icon(Icons.add, color: pal.text.withValues(alpha: .85)),
                        tooltip: tr('Đính kèm'),
                        onPressed: () => _attachMenu(b),
                      ),
                    ),
                  TapRegion(
                    groupId: _panelTapGroup,
                    child: IconButton(
                      icon: Icon(_panel && !_desktop ? Icons.keyboard_outlined : Icons.sentiment_satisfied_alt_outlined,
                          color: _panel && _desktop ? pal.accentText : pal.text.withValues(alpha: .85)),
                      tooltip: _panel && !_desktop ? tr('Bàn phím') : tr('Biểu tượng cảm xúc'),
                      onPressed: _expressions,
                    ),
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, e) {
                        // Cmd/Ctrl+V: nếu bộ nhớ tạm có ảnh / tệp thì đính kèm (chữ vẫn dán như thường).
                        if (_desktop &&
                            e is KeyDownEvent &&
                            e.logicalKey == LogicalKeyboardKey.keyV &&
                            (HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed)) {
                          _pasteMedia();
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _ctl,
                        focusNode: _focus,
                        onTap: _refreshClip,
                        // Điện thoại: menu dán có thêm "Dán ảnh" khi bộ nhớ tạm có ảnh.
                        contextMenuBuilder: (ctx, st) {
                          final items = [...st.contextMenuButtonItems];
                          if (_clipHasMedia && !_desktop) {
                            items.insert(0, ContextMenuButtonItem(
                              label: tr('Dán ảnh'),
                              onPressed: () {
                                st.hideToolbar();
                                _pasteMedia();
                              },
                            ));
                          }
                          return AdaptiveTextSelectionToolbar.buttonItems(anchors: st.contextMenuAnchors, buttonItems: items);
                        },
                        // Android: ảnh dán / chọn từ bàn phím (Gboard, Samsung Keyboard).
                        contentInsertionConfiguration: ContentInsertionConfiguration(
                          onContentInserted: (c) async {
                            final data = c.data;
                            if (data == null || data.isEmpty) return;
                            final ext = c.mimeType.split('/').last.replaceAll('jpeg', 'jpg');
                            final dir = await getTemporaryDirectory();
                            final name = 'paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
                            final f = File('${dir.path}/$name');
                            await f.writeAsBytes(data);
                            stage([(f.path, name)]);
                          },
                        ),
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
                            app.notifyTyping(widget.channelId, widget.threadRoot ?? '');
                          }
                        },
                      ),
                    ),
                  ),
                  if (!_desktop) ...[
                    IconButton(
                      icon: Transform.rotate(angle: .6, child: Icon(Icons.attach_file, color: pal.text.withValues(alpha: .85))),
                      tooltip: tr('Đính kèm'),
                      onPressed: _attach,
                    ),
                    if (!hasText)
                      IconButton(
                        icon: Icon(Icons.photo_camera_outlined, color: pal.text.withValues(alpha: .85)),
                        tooltip: tr('Gửi ảnh'),
                        onPressed: _photos,
                      ),
                  ] else
                    const SizedBox(width: 12),
                ]),
              ),
            ),
            const SizedBox(width: 6),
            // Chưa gõ gì: nút ghi âm; có nội dung: nút gửi.
            Material(
              color: pal.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: hasText ? _send : _voice,
                onLongPress: hasText && _staged.isEmpty ? _sendOptions : null,
                onSecondaryTap: hasText && _staged.isEmpty ? _sendOptions : null,
                // Không bọc Tooltip: Tooltip chiếm thao tác giữ lâu của nút gửi (menu hẹn giờ, ưu tiên...).
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Icon(hasText ? Icons.send_rounded : Icons.mic_rounded,
                        key: ValueKey(hasText), color: Colors.white, size: hasText ? 22 : 24),
                  ),
                ),
              ),
            ),
          ]),
          if (_panel && !_desktop)
            Container(
              height: (MediaQuery.sizeOf(context).height * .38).clamp(240.0, 360.0),
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
              clipBehavior: Clip.antiAlias,
              child: _expressionPanel(),
            ),
        ]),
      ),
    );
    if (!_desktop) return composer;
    return CompositedTransformTarget(
      link: _panelLink,
      child: OverlayPortal(
        controller: _panelOverlay,
        overlayChildBuilder: (_) => CompositedTransformFollower(
          link: _panelLink,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(10, -4),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: TapRegion(
              groupId: _panelTapGroup,
              onTapOutside: (_) => closePanel(),
              child: Material(
                color: pal.surface,
                elevation: 10,
                shadowColor: Colors.black45,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(width: 420, height: 380, child: _expressionPanel()),
              ),
            ),
          ),
        ),
        child: composer,
      ),
    );
  }
}

/// Nút "Dừng" dưới câu trả lời đang chạy của trợ lý AI (chỉ chủ bot thấy).
/// Nút "Tiếp tục" cho lượt bị dừng giữa chừng: thả ▶️ (arrow_forward), runner chạy lại đúng lượt đó.
class _AgentResumeButton extends StatefulWidget {
  final MmPost post;
  const _AgentResumeButton({required this.post});
  @override
  State<_AgentResumeButton> createState() => _AgentResumeButtonState();
}

class _AgentResumeButtonState extends State<_AgentResumeButton> {
  bool _sent = false;
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: pal.accent,
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
      ),
      onPressed: _sent
          ? null
          : () async {
              setState(() => _sent = true);
              final app = context.read<AppState>();
              final already = widget.post.reactions['arrow_forward']?.contains(app.me?.id) ?? false;
              if (!already) await app.toggleReaction(widget.post, 'arrow_forward');
            },
      icon: _sent
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.play_arrow_rounded, size: 18),
      label: Text(_sent ? tr('Đang tiếp tục...') : tr('Tiếp tục')),
    );
  }
}

class _AgentStopButton extends StatefulWidget {
  final MmPost post;
  const _AgentStopButton({required this.post});
  @override
  State<_AgentStopButton> createState() => _AgentStopButtonState();
}

class _AgentStopButtonState extends State<_AgentStopButton> {
  bool _sent = false;
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.redAccent,
        side: BorderSide(color: Colors.redAccent.withValues(alpha: .6)),
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
      ),
      onPressed: _sent
          ? null
          : () async {
              setState(() => _sent = true);
              final app = context.read<AppState>();
              final already = widget.post.reactions['octagonal_sign']?.contains(app.me?.id) ?? false;
              if (!already) await app.toggleReaction(widget.post, 'octagonal_sign');
            },
      icon: _sent
          ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: pal.sub))
          : const Icon(Icons.stop_rounded, size: 18),
      label: Text(_sent ? tr('Đang dừng...') : tr('Dừng')),
    );
  }
}
