import 'dart:async';

import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_info_page.dart';
import 'chat_list.dart';
import 'threads_view.dart';
import 'chat_page.dart';
import 'ai_panel.dart';
import 'common.dart';
import '../data/servers.dart';
import '../push/push_service.dart';
import 'server_picker.dart';
import 'status_ui.dart';
import 'agent_page.dart';
import 'attach_panel.dart' show TasksPage;
import 'call_history.dart';
import 'bot_page.dart';
import 'update_banner.dart';
import '../update/updater.dart';
import 'app_badge.dart';
import 'moderation.dart';
import 'theme.dart';

/// Màn hình chính. Màn hình rộng (máy tính) chia hai cột, màn hình hẹp
/// (điện thoại) có thanh tab nổi ở dưới như WhatsApp iOS.
class HomePage extends StatefulWidget {
  final Future<void> Function() onLogout;
  final void Function(String url) onSwitchServer;
  const HomePage({super.key, required this.onLogout, required this.onSwitchServer});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _selected;
  String? _infoFor;
  /// Máy tính: chủ đề đang mở ở cột phải (id kênh, id tin gốc).
  (String, String)? _thread;
  /// Độ rộng cột (máy tính, kéo thanh chia để đổi): danh sách chat, cột phải (luồng), cột thông tin.
  /// Cột phải chưa kéo lần nào thì rộng bằng chat chính.
  double _leftW = 380, _infoW = 380;
  double? _rightW;
  /// Luồng riêng tư mở ở cột phải: (chat chính, luồng riêng).
  (String, String)? _side;
  /// Navigator của cột phải. Đổi luồng ở cột phải thì tạo khoá mới: dùng lại cùng GlobalKey sẽ làm Flutter
  /// chuyển nguyên Navigator cũ (vẫn đang hiện luồng cũ) sang chỗ mới → bấm luồng bí mật tầng 2 không thấy trang mới.
  var _sideNav = GlobalKey<NavigatorState>();
  /// Nhóm đang tạm đóng cột trợ lý AI (bấm ✕); mở nhóm khác thì cột AI hiện lại.
  String? _aiHidden;
  final _leftNav = GlobalKey<NavigatorState>();
  String _query = '';
  ChatFilter _filter = ChatFilter.all;
  int _tab = 0;
  final _searchCtl = TextEditingController();

  bool get _wide => MediaQuery.sizeOf(context).width >= 860;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    PushService.openChatHook = _open;
    _app = context.read<AppState>();
    AppBadge.attach(_app);
    context.read<AppState>().loadLayout().then((m) {
      if (!mounted) return;
      setState(() {
        _leftW = m['left'] ?? _leftW;
        _infoW = m['info'] ?? _infoW;
        _rightW = m['right'];
      });
    });
    // Số luồng công việc đang dang dở (chấm trên tab Luồng).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadWorkThreads();
    });
  }

  /// Cột trái (máy tính) nằm trong bộ điều hướng riêng nên không tự dựng lại theo trang chính:
  /// mỗi lần đổi trạng thái thì báo cho nó dựng lại.
  final _leftTick = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _leftTick.value++;
  }

  void _selectTab(int i) {
    if (i == _tab) return;
    final app = context.read<AppState>();
    if (i == 3) app.markCallsSeen();
    if (i == 1) app.loadWorkThreads();
    setState(() => _tab = i);
  }

  /// Mở trang hồ sơ (ảnh đại diện góc trên bên trái).
  void _openProfile(NavigatorState? nav) => nav?.push(MaterialPageRoute(
      builder: (_) => _ProfilePage(onLogout: _confirmLogout, onSwitchServer: _switchServer)));

  Widget _meButton(NavigatorState? Function() nav) {
    final me = context.read<AppState>().me;
    return Tooltip(
      message: tr('Bạn'),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _openProfile(nav()),
        child: me == null ? const GlassCircle(icon: Icons.person_outline) : Avatar(userId: me.id, name: me.displayName, size: 40),
      ),
    );
  }

  /// Tiêu đề các tab không phải Chat: ảnh đại diện | tên tab.
  Widget _tabTitle(String title, NavigatorState? Function() nav) {
    final pal = Pal.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          if (!_wide) _meButton(nav) else const SizedBox(width: 40),
          Expanded(
            child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
          ),
          const SizedBox(width: 40),
        ]),
      ),
    );
  }

  /// Nội dung theo tab (dùng chung điện thoại và cột trái máy tính).
  Widget _tabBody(AppState app, double bottom, NavigatorState? Function() nav) => switch (_tab) {
        1 => ThreadsView(header: _tabTitle(tr('Luồng công việc'), nav), bottomPadding: bottom),
        2 => PeopleView(onOpen: _open, bottomPadding: bottom, header: _tabTitle(tr('Danh bạ'), nav)),
        3 => CallHistoryView(onOpen: _open, bottomPadding: bottom, header: _tabTitle(tr('Lịch sử cuộc gọi'), nav)),
        4 => TasksPage(leading: _wide ? const SizedBox(width: 40) : _meButton(nav), bottomPadding: bottom),
        _ => ChatList(
            header: _listHeader(),
            query: _query,
            filter: _filter,
            selectedId: _wide ? _selected : null,
            onOpen: _open,
            onSearchMessages: _searchMessages,
            bottomPadding: bottom,
          ),
      };

  Widget _tabBar(AppState app) => _TabBar(
        index: _tab,
        unread: app.chats.where((c) => c.unread > 0).length,
        threads: app.privateThreads.where((c) => !c.isClosed).length +
            app.workThreads.where((t) => !app.isThreadClosed(t.root.channelId, t.root.id)).length,
        missed: app.missedCalls,
        tasks: app.todos['in']?.length ?? 0,
        onTap: _selectTab,
      );

  @override
  void dispose() {
    if (PushService.openChatHook == _open) PushService.openChatHook = null;
    AppBadge.detach(_app);
    _leftTick.dispose();
    super.dispose();
  }

  /// Chọn máy chủ khác: máy tính mở cửa sổ riêng, điện thoại chuyển ngay trong app.
  void _switchServer(String url) {
    if (url == ServerList.current) return;
    if (isDesktop) {
      AppState.openServerWindow(url);
    } else {
      widget.onSwitchServer(url);
    }
  }

  /// Mở luồng bí mật ở cột phải. Luồng nhiều tầng / mở từ nơi khác (tab Luồng, nhóm khác đang chọn):
  /// chọn nhóm gốc ngoài cùng ở cột giữa rồi mở luồng ở cột phải, để luôn hiện trang mới.
  void _openSide(String id) {
    final app = context.read<AppState>();
    // Luồng bí mật sâu hơn mở từ luồng bí mật đang ở cột phải: đẩy chồng lên trong cột (nút quay lại
    // trở về luồng bí mật cha), không thay luồng đang mở.
    final cur = _side?.$2;
    if (cur != null && cur != id && _sideNav.currentState != null) {
      var p = app.channels[id]?.subParent;
      for (var i = 0; i < 10 && p != null; i++) {
        if (p == cur) {
          _sideNav.currentState!.push(MaterialPageRoute(builder: (_) => ChatPage(channelId: id)));
          return;
        }
        p = app.channels[p]?.subParent;
      }
    }
    final top = app.topParentOf(id);
    setState(() {
      if (_selected == null || (top != null && _selected != top && _selected != app.channels[id]?.subParent)) {
        _selected = top ?? _selected;
      }
      if (_side?.$2 != id) _sideNav = GlobalKey<NavigatorState>();
      _side = _selected == null ? null : (_selected!, id);
      _thread = null;
      _infoFor = null;
    });
    if (_selected == null) openChannelAnywhereFallback(id);
  }

  void openChannelAnywhereFallback(String id) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(channelId: id)));

  void _open(String channelId) {
    if (_wide) {
      setState(() {
        if (_infoFor != null && _infoFor != channelId) _infoFor = channelId;
        _selected = channelId;
      });
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(channelId: channelId)));
    }
  }

  /// Nút "+": bảng dưới (bottom sheet) — tạo nhóm, kênh, cuộc họp, trợ lý AI, bot cá nhân.
  Future<void> _plusMenu(BuildContext btn, NavigatorState? nav) async {
    if (nav == null) return;
    final pal = Pal.of(context);
    Widget item(BuildContext ctx, String v, IconData icon, Color color, String title, String sub) => InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(ctx, v),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 13, color: pal.sub)),
                ]),
              ),
              Icon(Icons.chevron_right, color: pal.sub),
            ]),
          ),
        );
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: pal.surface,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(tr('Tạo mới'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            item(ctx, 'private', Icons.group_add_rounded, const Color(0xFF2F80ED), tr('Tạo nhóm'),
                tr('Nhóm riêng tư, chỉ người được mời mới vào được')),
            item(ctx, 'public', Icons.tag_rounded, const Color(0xFF14A38B), tr('Tạo kênh'),
                tr('Kênh công khai, ai trong công ty cũng tham gia được')),
            item(ctx, 'meeting', Icons.videocam_rounded, const Color(0xFFF2994A), tr('Tạo cuộc họp'),
                tr('Họp video ngay với nhiều người')),
            item(ctx, 'agent', Icons.auto_awesome_rounded, const Color(0xFF9B51E0), tr('Tạo trợ lý AI'),
                tr('Trợ lý Claude / Codex chạy trên máy của bạn')),
            item(ctx, 'bot', Icons.smart_toy_outlined, pal.sub, tr('Tạo bot cá nhân'),
                tr('Cho phần mềm khác gửi tin vào, không có AI')),
          ]),
        ),
      ),
    );
    if (v == null || !mounted) return;
    if (v == 'agent') {
      nav.push(MaterialPageRoute(builder: (_) => const AgentPage()));
      return;
    }
    if (v == 'bot') {
      nav.push(MaterialPageRoute(builder: (_) => const BotEditPage()));
      return;
    }
    final kind = {'public': NewChatKind.publicGroup, 'private': NewChatKind.privateGroup, 'meeting': NewChatKind.meeting}[v]!;
    final id = await nav.push<String>(MaterialPageRoute(builder: (_) => NewChatPage(kind: kind)));
    if (id == null || !mounted) return;
    _open(id);
    if (kind == NewChatKind.meeting) context.read<AppState>().calls.startCall(id, meeting: true);
  }

  void _searchMessages() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchPage(terms: _query, onOpen: _open)));
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Đăng xuất?')),
        content: Text(tr('Tin nhắn lưu trên máy này sẽ bị xóa. Bạn có thể đăng nhập lại bằng Google bất cứ lúc nào.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Đăng xuất'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Đóng các trang đang mở chồng (trang cá nhân...) trước khi đăng xuất, tránh màn hình trắng.
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    _leftNav.currentState?.popUntil((r) => r.isFirst);
    await widget.onLogout();
  }

  Widget _topBar() {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        _meButton(() => Navigator.of(context)),
        const SizedBox(width: 4),
        Expanded(
          child: ServerTitle(onSelected: _switchServer),
        ),
        Builder(
          builder: (b) => GlassCircle(
            icon: Icons.add,
            color: pal.accent,
            iconColor: Colors.white,
            tooltip: tr('Tạo mới'),
            onTap: () => _plusMenu(b, Navigator.of(context)),
          ),
        ),
      ]),
    );
  }

  /// Thanh trên của cột danh sách (máy tính): ảnh đại diện | Chat | +.
  Widget _topBarWide() {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        _meButton(() => _leftNav.currentState),
        const SizedBox(width: 4),
        Expanded(
          child: ServerTitle(onSelected: _switchServer),
        ),
        Builder(
          builder: (b) => GlassCircle(
            icon: Icons.add,
            color: pal.accent,
            iconColor: Colors.white,
            tooltip: tr('Tạo mới'),
            onTap: () => _plusMenu(b, _leftNav.currentState),
          ),
        ),
      ]),
    );
  }

  Widget _listHeader() {
    final pal = Pal.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const UpdateBanner(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: TextField(
          controller: _searchCtl,
          onChanged: (v) => setState(() => _query = v),
          style: TextStyle(color: pal.text, fontSize: 16),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: pal.surface,
            hintText: tr('Tìm kiếm'),
            hintStyle: TextStyle(color: pal.sub),
            prefixIcon: Icon(Icons.search, color: pal.sub, size: 20),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.cancel, size: 18, color: pal.sub),
                    onPressed: () => setState(() {
                          _query = '';
                          _searchCtl.clear();
                        })),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
        ),
      ),
      SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            // Luồng công việc có tab riêng.
            for (final f in ChatFilter.values.where((f) => f != ChatFilter.threads))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _Chip(
                  label: chatFilterLabels[f]!,
                  selected: _filter == f,
                  onTap: () => setState(() => _filter = f),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 6),
    ]);
  }

  void _saveLayout() => context.read<AppState>().saveLayout({
        'left': _leftW,
        'info': _infoW,
        'right': ?_rightW,
      });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();

    if (_wide) {
      final hasChat = _selected != null && app.channels.containsKey(_selected);
      final showSide = hasChat && _side != null && _side!.$1 == _selected && app.channels.containsKey(_side!.$2);
      final showThread = hasChat && !showSide && _thread != null && _thread!.$1 == _selected;
      final showInfo = hasChat && _infoFor == _selected && !showThread && !showSide;
      // Cột phải mặc định: chat riêng với trợ lý AI của nhóm đang mở (khi không mở luồng / thông tin).
      final showAi = hasChat && !showThread && !showSide && !showInfo && _aiHidden != _selected &&
          app.showsAiFor(app.channels[_selected]!);
      return ChatHost(
        openChat: _open,
        openInfo: (id) => setState(() {
          _infoFor = _infoFor == id ? null : id;
          _thread = null;
          _side = null;
        }),
        openThread: (cid, root) => setState(() {
          _thread = (cid, root);
          _infoFor = null;
          _side = null;
        }),
        openSide: _openSide,
        openAi: (g) => setState(() {
          _selected = g;
          _aiHidden = null;
          _thread = null;
          _side = null;
          _infoFor = null;
        }),
        // Thông báo nổi phía trên thanh tab của cột trái.
        child: AboveNavSnackBars(
          navTop: 74,
          child: Scaffold(
          backgroundColor: pal.bg,
          body: SafeArea(
            child: LayoutBuilder(builder: (context, box) {
            final total = box.maxWidth;
            _leftW = _leftW.clamp(260.0, (total * .45).clamp(260.0, 700.0));
            final rest = total - _leftW;
            final hasRight = showThread || showSide || showAi;
            final rightW = hasRight ? (_rightW ?? rest / 2).clamp(320.0, (rest - 360).clamp(320.0, 2000.0)) : 0.0;
            _infoW = _infoW.clamp(300.0, 600.0);
            return Row(children: [
              SizedBox(
                width: _leftW,
                child: _ColumnNavigator(
                  navKey: _leftNav,
                  // Thanh tab nổi ở đáy cột trái; tab đang chọn quyết định nội dung cột.
                  root: ListenableBuilder(
                    listenable: _leftTick,
                    builder: (context, _) {
                      final app = context.watch<AppState>();
                      return Scaffold(
                        backgroundColor: pal.bg,
                        body: Stack(children: [
                          Positioned.fill(
                            child: Column(children: [
                              _topBarWide(),
                              const OfflineBanner(),
                              Expanded(child: _tabBody(app, 84, () => _leftNav.currentState)),
                            ]),
                          ),
                          Positioned(left: 12, right: 12, bottom: 10, child: _tabBar(app)),
                        ]),
                      );
                    },
                  ),
                ),
              ),
              _ResizeHandle(
                onDrag: (dx) => setState(() => _leftW += dx),
                onEnd: _saveLayout,
                onReset: () => setState(() => _leftW = 380),
              ),
              Expanded(
                child: !hasChat
                    ? const _Welcome()
                    : _ColumnNavigator(
                        key: ValueKey('chat-$_selected'),
                        root: ChatPage(channelId: _selected!, embedded: true),
                      ),
              ),
              if (hasRight)
                _ResizeHandle(
                  onDrag: (dx) => setState(() => _rightW = rightW - dx),
                  onEnd: _saveLayout,
                  // Bấm đúp: trở lại chia đôi với chat chính.
                  onReset: () => setState(() => _rightW = null),
                ),
              if (showThread) ...[
                SizedBox(
                  width: rightW,
                  child: _ColumnNavigator(
                    key: ValueKey('thread-${_thread!.$2}'),
                    root: ThreadPage(
                      channelId: _thread!.$1,
                      rootId: _thread!.$2,
                      onClose: () => setState(() => _thread = null),
                    ),
                  ),
                ),
              ],
              if (showSide) ...[
                // Luồng riêng tư ở cột phải. Trong cột: thông tin nhóm, luồng công việc riêng... mở chồng ngay trong cột.
                SizedBox(
                  width: rightW,
                  child: ChatHost(
                    openChat: _open,
                    openInfo: (id) => _sideNav.currentState?.push(MaterialPageRoute(builder: (_) => ChatInfoPage(channelId: id))),
                    openThread: (cid, root) =>
                        _sideNav.currentState?.push(MaterialPageRoute(builder: (_) => ThreadPage(channelId: cid, rootId: root))),
                    openSide: _openSide,
                    child: _ColumnNavigator(
                      key: ValueKey('side-${_side!.$2}'),
                      navKey: _sideNav,
                      root: ChatPage(channelId: _side!.$2, embedded: true, onClose: () => setState(() => _side = null)),
                    ),
                  ),
                ),
              ],
              if (showAi) ...[
                SizedBox(
                  width: rightW,
                  child: _ColumnNavigator(
                    key: ValueKey('ai-$_selected'),
                    root: AiPanel(groupId: _selected!, onClose: () => setState(() => _aiHidden = _selected)),
                  ),
                ),
              ],
              if (showInfo) ...[
                _ResizeHandle(
                  onDrag: (dx) => setState(() => _infoW -= dx),
                  onEnd: _saveLayout,
                  onReset: () => setState(() => _infoW = 380),
                ),
                SizedBox(
                  width: _infoW,
                  child: _ColumnNavigator(
                    key: ValueKey('info-$_selected'),
                    root: ChatInfoPage(channelId: _selected!, onClose: () => setState(() => _infoFor = null)),
                  ),
                ),
              ],
            ]);
            }),
          ),
        ),
        ),
      );
    }

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final Widget body = _tab == 0
        ? Column(children: [
            SafeArea(bottom: false, child: _topBar()),
            const OfflineBanner(),
            Expanded(child: _tabBody(app, 84 + bottomInset, () => Navigator.of(context))),
          ])
        : _tabBody(app, 84 + bottomInset, () => Navigator.of(context));

    // Thanh tab cao ~64: máy có thanh vuốt thì đáy thanh tab thấp hơn vùng an toàn 14, máy khác cách đáy 10.
    return AboveNavSnackBars(
      navTop: bottomInset > 0 ? 50 : 74,
      child: Scaffold(
      backgroundColor: pal.bg,
      body: Stack(children: [
        Positioned.fill(child: body),
        Positioned(
          left: 20,
          right: 20,
          // Máy có thanh vuốt (iPhone): thanh tab đè nhẹ lên vùng an toàn cho thấp gọn như WhatsApp.
          bottom: bottomInset > 0 ? bottomInset - 14 : 10,
          child: _tabBar(app),
        ),
      ]),
      ),
    );
  }
}

/// Cho các trang trong cột chat biết đang ở giao diện máy tính nhiều cột:
/// mở chat khác, mở/đóng cột cài đặt.
class ChatHost extends InheritedWidget {
  final void Function(String channelId) openChat;
  final void Function(String channelId) openInfo;
  /// Mở chủ đề ở cột bên phải chat chính.
  final void Function(String channelId, String rootId) openThread;
  /// Mở một cuộc trò chuyện (luồng riêng tư) ở cột bên phải, giữ nguyên chat chính ở giữa.
  final void Function(String channelId)? openSide;
  /// Máy tính: hiện cột trợ lý AI của nhóm (đóng luồng / thông tin đang mở ở cột phải).
  final void Function(String groupId)? openAi;
  const ChatHost(
      {super.key, required this.openChat, required this.openInfo, required this.openThread, this.openSide, this.openAi, required super.child});
  static ChatHost? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ChatHost>();
  @override
  bool updateShouldNotify(ChatHost old) => false;
}

/// Mỗi cột có bộ điều hướng riêng: trang con mở trong cột, có nút quay lại.
class _ColumnNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState>? navKey;
  final Widget root;
  const _ColumnNavigator({super.key, this.navKey, required this.root});
  @override
  Widget build(BuildContext context) => ClipRect(
        child: Navigator(
          key: navKey,
          onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => root),
        ),
      );
}

class _ProfilePage extends StatelessWidget {
  final VoidCallback onLogout;
  final void Function(String url) onSwitchServer;
  const _ProfilePage({required this.onLogout, required this.onSwitchServer});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        body: Stack(children: [
          ProfileView(onLogout: onLogout, onSwitchServer: onSwitchServer),
          Positioned(
            left: 16,
            top: MediaQuery.paddingOf(context).top + 10,
            child: GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
          ),
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: selected ? pal.chipSelBg : Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: selected ? pal.chipSelBg : pal.divider, width: 1.2)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: selected ? pal.chipSelFg : pal.sub)),
        ),
      ),
    );
  }
}

/// Thanh tab nổi dạng viên thuốc, kính mờ: Chat · Luồng · Danh bạ · Lịch sử (cuộc gọi) · Công việc.
class _TabBar extends StatelessWidget {
  final int index;
  final int unread;
  final int threads;
  final int missed;
  final int tasks;
  final ValueChanged<int> onTap;
  const _TabBar({
    required this.index,
    required this.unread,
    required this.threads,
    required this.missed,
    required this.tasks,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget item(int i, IconData icon, String label, int count, {Color? badge}) {
      final sel = i == index;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(i),
          child: Container(
            // 5 mục: lề ngang hẹp cho vừa điện thoại nhỏ.
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: sel ? pal.text.withValues(alpha: .10) : Colors.transparent,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              IconTheme(
                data: IconThemeData(color: pal.text.withValues(alpha: sel ? 1 : .8), size: 26),
                child: Badge(
                  isLabelVisible: count > 0,
                  backgroundColor: badge ?? pal.accent,
                  textColor: Colors.white,
                  label: Text(count > 99 ? '99+' : '$count'),
                  child: Icon(icon),
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: pal.text)),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: pal.text.withValues(alpha: .08)),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: Glass(
        radius: BorderRadius.circular(36),
        child: Row(children: [
          item(0, Icons.chat_bubble_outline, tr('Chat'), unread),
          item(1, Icons.forum_outlined, tr('Luồng'), threads),
          item(2, Icons.contacts_outlined, tr('Danh bạ'), 0),
          item(3, Icons.call_outlined, tr('Lịch sử'), missed, badge: const Color(0xFFE53935)),
          item(4, Icons.task_alt_outlined, tr('Công việc'), tasks),
        ]),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return DoodleBackground(
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
            child: const Icon(Icons.forum, color: Colors.white, size: 52),
          ),
          const SizedBox(height: 24),
          Text('Flygo Chat', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: pal.text)),
          const SizedBox(height: 10),
          Text(tr('Chọn một cuộc trò chuyện bên trái để bắt đầu nhắn tin.'), style: TextStyle(fontSize: 15, color: pal.sub)),
          const SizedBox(height: 28),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 14, color: pal.sub),
            const SizedBox(width: 6),
            Text(tr('Tin nhắn lưu trên máy chủ riêng của công ty'), style: TextStyle(fontSize: 13, color: pal.sub)),
          ]),
        ]),
      ),
    );
  }
}

/// Tab Danh bạ (giữa thanh tab): bấm vào ai là mở tin nhắn riêng.
class PeopleView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final double bottomPadding;
  final bool pickMode;
  /// Tiêu đề thay cho chữ "Danh bạ" mặc định (vd. tiêu đề tab có ảnh đại diện).
  final Widget? header;
  const PeopleView({super.key, required this.onOpen, this.bottomPadding = 0, this.pickMode = false, this.header});
  @override
  State<PeopleView> createState() => _PeopleViewState();
}

class _PeopleViewState extends State<PeopleView> {
  String _q = '';
  bool _busy = false;

  Future<void> _start(MmUser u) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = await context.read<AppState>().openDirect(u.id);
      widget.onOpen(id);
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không mở được cuộc trò chuyện. Kiểm tra kết nối mạng.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final q = _q.toLowerCase();
    final people = app.people
        .where((u) => q.isEmpty || u.displayName.toLowerCase().contains(q) || u.username.contains(q) || u.email.contains(q))
        .toList();
    return Column(children: [
      if (widget.header != null)
        widget.header!
      else if (!widget.pickMode)
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
            child: Text(tr('Danh bạ'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(
          autofocus: widget.pickMode,
          onChanged: (v) => setState(() => _q = v),
          style: TextStyle(color: pal.text),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: pal.surface,
            hintText: tr('Tìm theo tên hoặc email'),
            hintStyle: TextStyle(color: pal.sub),
            prefixIcon: Icon(Icons.search, size: 20, color: pal.sub),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
        ),
      ),
      if (_busy) LinearProgressIndicator(color: pal.accent, minHeight: 2),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(tr('{0} người', [people.length]), style: TextStyle(color: pal.sub, fontSize: 13)),
        ),
      ),
      Expanded(
        child: ListView.builder(
          padding: EdgeInsets.only(bottom: widget.bottomPadding),
          itemCount: people.length,
          itemBuilder: (_, i) {
            final u = people[i];
            return InkWell(
              onTap: _busy ? null : () => _start(u),
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(children: [
                  Avatar(userId: u.id, name: u.displayName, size: 46),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.divider, width: .6))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(u.displayName, style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: pal.text)),
                        Text(u.email, style: TextStyle(color: pal.sub, fontSize: 14)),
                      ]),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

/// Nút "+": tạo nhóm mới. Tick chọn thành viên → Tiếp → đặt tên nhóm → tạo và mở
/// luôn khung chat. Chọn 1 người và bỏ trống tên thì mở chat riêng với người đó.
enum NewChatKind { publicGroup, privateGroup, meeting }

/// Chọn thành viên rồi đặt tên để tạo nhóm công khai, riêng tư hoặc cuộc họp.
class NewChatPage extends StatefulWidget {
  final NewChatKind kind;
  const NewChatPage({super.key, this.kind = NewChatKind.privateGroup});
  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
  final List<String> _picked = [];
  String _q = '';
  bool _busy = false;
  /// Trợ lý AI của mình (để thêm vào nhóm cùng người); bot khác chỉ hiện khi mình có quyền gọi.
  Set<String>? _myBots;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().myBotIds().then((v) {
      if (mounted) setState(() => _myBots = v);
    });
  }

  Future<void> _next() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final kind = widget.kind;
    final now = DateTime.now();
    final ctl = TextEditingController(
        text: kind == NewChatKind.meeting ? tr('Cuộc họp {0} {1}', [hhmm(now), '${two(now.day)}/${two(now.month)}']) : '');
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(kind == NewChatKind.meeting
            ? tr('Tên cuộc họp')
            : kind == NewChatKind.publicGroup
                ? tr('Tên kênh')
                : tr('Tên nhóm')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: tr('Ví dụ: Phòng kế toán')),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
                kind == NewChatKind.publicGroup
                    ? tr('Kênh công khai: mọi người trong công ty tìm và tham gia được.')
                    : kind == NewChatKind.meeting
                        ? tr('Tạo nhóm riêng tư và bắt đầu cuộc họp ngay.')
                        : tr('Nhóm riêng tư: chỉ người được mời mới thấy và tham gia.'),
                style: TextStyle(fontSize: 13, color: Pal.of(d).sub)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
          TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text(tr('Tạo'))),
        ],
      ),
    );
    if (name == null) return;
    final n = name.trim();
    if (n.isEmpty) {
      messenger.showSnackBar(toast(Text(kind == NewChatKind.publicGroup ? tr('Hãy đặt tên cho kênh.') : tr('Hãy đặt tên cho nhóm.'))));
      return;
    }
    setState(() => _busy = true);
    try {
      nav.pop(await app.createGroup(n, _picked, public: kind == NewChatKind.publicGroup));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(toast(Text(tr('Không tạo được nhóm. Kiểm tra kết nối mạng.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final q = _q.toLowerCase();
    final mine = _myBots ?? const <String>{};
    final people = app.peopleAndBots
        .where((u) => !u.isBot || (engineOf(u) != null && app.canCallBot(u, mine)))
        .where((u) => q.isEmpty || u.displayName.toLowerCase().contains(q) || u.username.contains(q) || u.email.contains(q))
        .toList();
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(children: [
                GlassCircle(icon: Icons.close, onTap: () => Navigator.pop(context)),
                Expanded(
                  child: Column(children: [
                    Text(
                        switch (widget.kind) {
                          NewChatKind.publicGroup => tr('Kênh mới'),
                          NewChatKind.privateGroup => tr('Nhóm mới'),
                          NewChatKind.meeting => tr('Cuộc họp mới'),
                        },
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
                    Text(tr('Đã chọn {0}', [_picked.length]), style: TextStyle(fontSize: 13, color: pal.sub)),
                  ]),
                ),
                const SizedBox(width: 44),
              ]),
            ),
            if (_picked.isNotEmpty)
              SizedBox(
                height: 78,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                  for (final id in _picked)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: GestureDetector(
                        onTap: () => setState(() => _picked.remove(id)),
                        child: Column(children: [
                          Stack(children: [
                            Avatar(userId: id, name: app.users[id]?.displayName ?? '?', size: 48),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: CircleAvatar(radius: 9, backgroundColor: pal.surface2, child: Icon(Icons.close, size: 12, color: pal.text)),
                            ),
                          ]),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 56,
                            child: Text(app.users[id]?.displayName.split(' ').last ?? '',
                                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11.5, color: pal.sub)),
                          ),
                        ]),
                      ),
                    ),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                style: TextStyle(color: pal.text),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: pal.surface,
                  hintText: tr('Tìm theo tên hoặc email'),
                  hintStyle: TextStyle(color: pal.sub),
                  prefixIcon: Icon(Icons.search, size: 20, color: pal.sub),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            if (_busy) LinearProgressIndicator(color: pal.accent, minHeight: 2),
            Expanded(
              child: ListView(children: [
                for (final u in people)
                  CheckboxListTile(
                    value: _picked.contains(u.id),
                    activeColor: pal.accent,
                    checkColor: Colors.white,
                    checkboxShape: const CircleBorder(),
                    onChanged: (v) => setState(() => v == true ? _picked.add(u.id) : _picked.remove(u.id)),
                    secondary: Avatar(userId: u.id, name: u.displayName, size: 44),
                    title: nameText(u.displayName,
                        bot: u.isBot, engine: engineOf(u), style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                    subtitle: Text(u.isBot ? '@${u.username}' : u.email, style: TextStyle(color: pal.sub)),
                  ),
              ]),
            ),
            if (_picked.isNotEmpty || widget.kind == NewChatKind.publicGroup)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                      onPressed: _busy ? null : _next,
                      child: Text(tr('Tiếp ({0})', [_picked.length]), style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Tab Bạn: thông tin tài khoản.
/// Tên người dùng hợp lệ của Mattermost: 3–22 ký tự, bắt đầu bằng chữ, chỉ a-z 0-9 . - _
final _usernameRe = RegExp(r'^[a-z][a-z0-9._-]{2,21}$');

Future<void> _renameMe(BuildContext context, AppState app, MmUser me) async {
  final nameCtl = TextEditingController(text: me.displayName);
  final userCtl = TextEditingController(text: me.username);
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final un = userCtl.text.trim().toLowerCase();
      final unError = un.isEmpty || _usernameRe.hasMatch(un) ? null : tr('3–22 ký tự, bắt đầu bằng chữ, chỉ gồm a-z, 0-9, dấu . - _');
      return AlertDialog(
        title: Text(tr('Đổi tên')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtl,
            autofocus: true,
            maxLength: 64,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr('Tên hiển thị')),
          ),
          TextField(
            controller: userCtl,
            maxLength: 22,
            autocorrect: false,
            onChanged: (_) => set(() {}),
            decoration: InputDecoration(labelText: tr('Tên người dùng'), prefixText: '@', errorText: unError),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Hủy'))),
          FilledButton(onPressed: unError != null ? null : () => Navigator.pop(ctx, true), child: Text(tr('Lưu'))),
        ],
      );
    }),
  );
  final name = nameCtl.text.trim(), username = userCtl.text.trim().toLowerCase();
  nameCtl.dispose();
  userCtl.dispose();
  if (ok != true) return;
  try {
    await app.renameMe(name: name == me.displayName ? null : name, username: username);
  } catch (e) {
    final taken = e.toString().contains('exists') || e.toString().contains('taken');
    messenger.showSnackBar(SnackBar(
        content: Text(taken
            ? tr('Tên người dùng này đã có người dùng.')
            : tr('Không đổi được tên. Máy chủ có thể không cho đổi tên người dùng với tài khoản đăng nhập bằng Google.'))));
  }
}

class ProfileView extends StatelessWidget {
  final VoidCallback onLogout;
  final void Function(String url) onSwitchServer;
  final double bottomPadding;
  const ProfileView({super.key, required this.onLogout, required this.onSwitchServer, this.bottomPadding = 0});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final me = app.me;
    if (me == null) return const SizedBox.shrink();
    return SafeArea(
      bottom: false,
      child: ListView(padding: EdgeInsets.fromLTRB(16, 18, 16, bottomPadding + MediaQuery.paddingOf(context).bottom + 32), children: [
        Text(tr('Bạn'), textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
        const SizedBox(height: 14),
        ServerSelectButton(onSelected: onSwitchServer),
        const SizedBox(height: 22),
        Center(
          child: EditableAvatar(
            size: 120,
            avatar: Avatar(userId: me.id, name: me.displayName, size: 120, status: false),
            onPicked: (n, b) => app.setUserImage(me.id, n, b),
          ),
        ),
        const SizedBox(height: 16),
        // Tên + nút sửa tên bên phải.
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(width: 40),
          Flexible(
            child: Text(me.displayName,
                textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          IconButton(
            tooltip: tr('Đổi tên'),
            icon: Icon(Icons.edit_outlined, size: 22, color: pal.sub),
            onPressed: () => _renameMe(context, app, me),
          ),
        ]),
        const SizedBox(height: 4),
        Text('@${me.username}', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: pal.sub)),
        const SizedBox(height: 28),
        const StatusSection(),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(icon: Icons.mail_outline, title: tr('Email'), value: me.email),
          InfoRow(icon: Icons.dns_outlined, title: tr('Máy chủ'), value: Uri.parse(kServerUrl).host),
          InfoRow(
              icon: app.online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              title: tr('Kết nối'),
              value: app.online ? tr('Đang trực tuyến') : tr('Ngoại tuyến')),
        ]),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(
            icon: Icons.translate,
            title: tr('Ngôn ngữ'),
            value: appLanguages[appLanguage.value],
            onTap: () => _pickLanguage(context),
          ),
          InfoRow(
            icon: Icons.text_format,
            title: tr('Hiển thị định dạng'),
            trailing: Switch.adaptive(
              value: app.renderMarkdown,
              activeTrackColor: pal.accent,
              onChanged: app.setRenderMarkdown,
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(tr('Bật: chữ đậm, danh sách, bảng, khối mã hiển thị đẹp. Tắt: hiện chữ thô như khi gõ.'),
              style: TextStyle(fontSize: 13, color: pal.sub)),
        ),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(
            icon: Icons.auto_awesome_outlined,
            title: tr('Trợ lý AI'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage())),
          ),
          InfoRow(
            icon: Icons.smart_toy_outlined,
            title: tr('Quản lý bot'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BotsPage())),
          ),
        ]),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(
            icon: Icons.system_update_outlined,
            title: tr('Phiên bản'),
            value: Updater.currentVersion.isEmpty ? null : '${Updater.currentVersion} (${Updater.currentBuild})',
            onTap: () => showUpdateDialog(context),
          ),
        ]),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(
            icon: Icons.block,
            title: tr('Người đã chặn'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BlockedUsersPage())),
          ),
          InfoRow(icon: Icons.privacy_tip_outlined, title: tr('Chính sách quyền riêng tư'), onTap: openPrivacyPolicy),
          InfoRow(
            icon: Icons.person_remove_outlined,
            title: tr('Yêu cầu xoá tài khoản'),
            onTap: () => requestAccountDeletion(context, context.read<AppState>()),
          ),
        ]),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(icon: Icons.logout, title: tr('Đăng xuất'), danger: true, onTap: onLogout),
        ]),
      ]),
    );
  }
}

Future<void> _pickLanguage(BuildContext context) async {
  final lang = await showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(tr('Ngôn ngữ'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
          ),
          for (final e in appLanguages.entries)
            ListTile(
              title: Text(e.value, style: TextStyle(color: pal.text, fontSize: 16)),
              trailing: e.key == appLanguage.value ? Icon(Icons.check_circle, color: pal.accent) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
  if (lang != null && lang != appLanguage.value) {
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    await setLanguage(lang);
  }
}

/// Khối bo tròn chứa các dòng, như trang cài đặt của WhatsApp iOS.
class InfoGroup extends StatelessWidget {
  final List<Widget> children;
  const InfoGroup({super.key, required this.children});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i < children.length - 1) items.add(Divider(height: 1, thickness: .6, indent: 56, color: pal.divider));
    }
    return Container(
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
    );
  }
}

class InfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? value;
  final bool danger;
  final VoidCallback? onTap;
  final Widget? trailing;
  const InfoRow(
      {super.key, required this.icon, required this.title, this.value, this.danger = false, this.onTap, this.trailing});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final color = danger ? Colors.redAccent : pal.text;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 16),
          Expanded(child: Text(title, style: TextStyle(fontSize: 17, color: color))),
          // Không dùng Flexible: nó chia đôi chiều ngang với tiêu đề, làm số đếm lệch vào giữa.
          if (value != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .45),
              child: Text(value!,
                  textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: pal.sub)),
            ),
          ?trailing,
          if (onTap != null && !danger) ...[
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, color: pal.sub),
          ],
        ]),
      ),
    );
  }
}

/// Tìm tin nhắn trên máy chủ (toàn bộ hoặc trong một cuộc trò chuyện).
class SearchPage extends StatefulWidget {
  final String terms;
  final String? channelId;
  final void Function(String channelId) onOpen;
  const SearchPage({super.key, required this.terms, this.channelId, required this.onOpen});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  List<MmPost>? _res;
  String? _err;
  late final TextEditingController _ctl = TextEditingController(text: widget.terms);

  @override
  void initState() {
    super.initState();
    if (widget.terms.isNotEmpty) _run(widget.terms);
  }

  Timer? _debounce;
  int _seq = 0;

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(q));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _run(String q) {
    if (q.trim().isEmpty) {
      setState(() => _res = null);
      return;
    }
    final app = context.read<AppState>();
    final seq = ++_seq;
    setState(() {
      _res = null;
      _err = null;
    });
    // Tìm cả từ đang gõ dở: thêm * vào cuối từ cuối cùng.
    var terms = q.trim();
    if (RegExp(r'[\w\u00C0-\u1EF9]$').hasMatch(terms) && !terms.contains('"')) terms = '$terms*';
    final ch = widget.channelId == null ? null : app.channels[widget.channelId];
    if (ch != null && !ch.isDirect && !ch.isGroupDm) terms = '$terms in:${ch.name}';
    app.api.search(app.teamId!, terms).then((r) {
      if (!mounted || seq != _seq) return;
      setState(() => _res = ch == null ? r : r.where((p) => p.channelId == ch.id).toList());
    }).catchError((_) {
      if (mounted && seq == _seq) setState(() => _err = tr('Không tìm được. Cần có kết nối mạng.'));
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _ctl,
                  autofocus: widget.terms.isEmpty,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _run,
                  onChanged: _changed,
                  style: TextStyle(color: pal.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: pal.surface,
                    hintText: tr('Tìm tin nhắn'),
                    hintStyle: TextStyle(color: pal.sub),
                    prefixIcon: Icon(Icons.search, size: 20, color: pal.sub),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ]),
          ),
          Expanded(
            child: _err != null
                ? Center(child: Text(_err!, style: TextStyle(color: pal.sub)))
                : _res == null
                    ? (_ctl.text.isEmpty
                        ? const SizedBox.shrink()
                        : Center(child: CircularProgressIndicator(color: pal.accent)))
                    : _res!.isEmpty
                        ? Center(child: Text(tr('Không có tin nhắn nào phù hợp'), style: TextStyle(color: pal.sub)))
                        : ListView.separated(
                            itemCount: _res!.length,
                            separatorBuilder: (_, _) => Divider(height: 1, indent: 72, color: pal.divider),
                            itemBuilder: (_, i) {
                              final p = _res![i];
                              final ch = app.channels[p.channelId];
                              return ListTile(
                                leading:
                                    Avatar(userId: p.userId, name: app.users[p.userId]?.displayName ?? '?', size: 42),
                                title: Text(
                                    '${app.users[p.userId]?.displayName ?? ''}${ch == null ? '' : ' · ${app.channelTitle(ch)}'}',
                                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: pal.text)),
                                subtitle: Text(p.message,
                                    maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub)),
                                trailing: Text(listTime(p.createAt), style: TextStyle(fontSize: 12, color: pal.sub)),
                                onTap: ch == null
                                    ? null
                                    : () {
                                        Navigator.pop(context);
                                        widget.onOpen(p.channelId);
                                      },
                              );
                            },
                          ),
          ),
        ]),
      ),
    );
  }
}

/// Thanh chia cột kéo được (máy tính): kéo để đổi độ rộng, bấm đúp để trở về mặc định.
class _ResizeHandle extends StatelessWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onEnd;
  final VoidCallback onReset;
  const _ResizeHandle({required this.onDrag, required this.onEnd, required this.onReset});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onEnd(),
        onDoubleTap: () {
          onReset();
          onEnd();
        },
        child: SizedBox(width: 7, child: Center(child: VerticalDivider(width: 1, color: pal.divider))),
      ),
    );
  }
}
