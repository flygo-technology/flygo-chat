import 'dart:async';
import 'dart:io' show Platform;

import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_info_page.dart';
import 'chat_list.dart';
import 'threads_view.dart';
import 'chat_page.dart';
import 'ai_panel.dart';
import 'ai_consent.dart';
import 'common.dart';
import '../data/servers.dart';
import '../push/push_service.dart';
import 'server_picker.dart';
import 'status_ui.dart';
import 'agent_page.dart';
import 'agents_view.dart';
import 'qr_login.dart';
import 'mini_app_view.dart';
import 'password_page.dart';
import 'schedules_view.dart';
import 'call_history.dart';
import 'bot_page.dart';
import 'update_banner.dart';
import 'app_badge.dart';
import 'desktop_tray.dart';
import 'flags.dart';
import 'moderation.dart';
import 'tasks_view.dart';
import '../api/boards_api.dart' show isBoardsUrl, parseBoardsPath;
import 'boards/board_page.dart' show openBoard;
import 'boards/boards_home.dart' show BoardsHomePage;
import 'boards/card_detail.dart' show openBoardCard;
import 'links.dart' show internalLinkHook;
import 'panes/pane_layout.dart';
import 'panes/pane_view.dart';
import 'popout_windows.dart';
import 'theme.dart';

/// Màn hình chính. Màn hình rộng (máy tính) chia hai cột, vùng nội dung chia được tới 4 ô; màn hình hẹp
/// (điện thoại) có thanh tab nổi ở dưới như WhatsApp iOS.
class HomePage extends StatefulWidget {
  final Future<void> Function() onLogout;
  final void Function(String url) onSwitchServer;
  /// Cửa sổ riêng của một mục thanh tab (`--section=`): chỉ hiện mục đó, mở chat chồng lên như điện thoại.
  final String? solo;
  const HomePage({super.key, required this.onLogout, required this.onSwitchServer, this.solo});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ---------------------------------------------------------------- chia ô (máy tính)
  /// Các ô của vùng nội dung (1–4 ô). Một ô: giao diện như trước (chat giữa + cột phải luồng / AI / thông tin).
  PaneLayout _panes = PaneLayout();
  /// Người dùng đã đổi bố cục trước khi bố cục đã lưu đọc xong: không ghi đè.
  bool _panesTouched = false;
  bool _panesPruned = false;
  Timer? _paneSave;
  String _paneSig = '';
  final Map<String, GlobalKey> _paneKeys = {};
  /// Navigator của từng ô, đổi nội dung ô thì tạo khoá mới (xem [_sideNav]).
  final Map<String, (String, GlobalKey<NavigatorState>)> _paneNavs = {};
  final Map<String, FocusScopeNode> _paneScopes = {};

  /// Cuộc trò chuyện ở ô đang chọn (một ô: cuộc đang mở ở giữa như trước).
  String? get _selected {
    final c = _panes.focused.content;
    return c != null && c.isChat ? c.id : null;
  }

  bool get _multi => _wide && _panes.isMulti;
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
  /// Cột AI đang mở phiên AI của luồng nào: (nhóm, id tin gốc); null = AI của cả nhóm.
  (String, String)? _aiThread;
  ChatFilter _filter = ChatFilter.all;
  /// Tab lọc trong trang Chat (Luồng công việc có tab riêng) và key từng tab để cuộn tab đang chọn vào tầm nhìn.
  static final _filters = [for (final f in ChatFilter.values) if (f != ChatFilter.threads) f];
  final _filterKeys = {for (final f in ChatFilter.values) f: GlobalKey()};

  void _setFilter(ChatFilter f) {
    setState(() => _filter = f);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _filterKeys[f]!.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: .5, duration: const Duration(milliseconds: 200));
    });
  }

  /// Vuốt ngang trên danh sách chat: sang trái = tab kế tiếp, sang phải = tab trước.
  void _swipeFilter(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() < 300) return;
    final i = _filters.indexOf(_filter) + (v < 0 ? 1 : -1);
    if (i >= 0 && i < _filters.length) _setFilter(_filters[i]);
  }
  int _tab = 0;
  final _searchCtl = TextEditingController();

  bool get _wide => widget.solo == null && MediaQuery.sizeOf(context).width >= 860;
  late final AppState _app;
  final _soloNav = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    if (widget.solo != null) {
      // Cửa sổ riêng của một mục: không nhận thông báo / link, không chấm số trên biểu tượng app (cửa sổ chính lo).
      _app = context.read<AppState>();
      _tab = PaneSections.tabOf(widget.solo!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AppState>().loadWorkThreads();
      });
      return;
    }
    PushService.openChatHook = _open;
    // Link thẻ / bảng Boards trong tin nhắn: mở màn hình Boards gốc của app.
    internalLinkHook = _openInternalLink;
    PushService.openThreadHook = _hostOpenThread;
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
    // Bố cục chia ô đã lưu của máy chủ này.
    _app.loadPanes().then((j) {
      if (!mounted || j == null || _panesTouched) return;
      setState(() => _panes = PaneLayout.fromJson(j));
      _panesPruned = false;
      _syncPaneFocus();
    });
    // Phím tắt chia ô: Ctrl/Cmd+1..4, Ctrl/Cmd+W, Ctrl/Cmd+K.
    HardwareKeyboard.instance.addHandler(_onKey);
    // Cửa sổ riêng tách từ các ô: mở lại các cửa sổ còn mở lúc thoát app lần trước.
    if (isDesktop) PopoutWindows.startMain();
    // Số luồng công việc đang dang dở (chấm trên tab Luồng).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadWorkThreads();
    });
  }

  // ---------------------------------------------------------------- chia ô
  GlobalKey _paneKey(String id) => _paneKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'pane-$id'));

  FocusScopeNode _scopeOf(String id) => _paneScopes.putIfAbsent(id, () => FocusScopeNode(debugLabel: 'pane-$id'));

  GlobalKey<NavigatorState> _navFor(PaneLeaf l) {
    final k = l.content?.key ?? '';
    final cur = _paneNavs[l.id];
    if (cur != null && cur.$1 == k) return cur.$2;
    final n = GlobalKey<NavigatorState>();
    _paneNavs[l.id] = (k, n);
    return n;
  }

  /// Sau mỗi lần đổi bố cục: lưu (gộp các lần đổi liên tiếp) và báo AppState ô nào đang chọn.
  void _panesChanged() {
    _panesTouched = true;
    _paneSave?.cancel();
    _paneSave = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _app.savePanes(_panes.toJson()).catchError((_) {});
    });
    _syncPaneFocus();
  }

  /// AppState chỉ tự đánh dấu đã đọc ở ô đang chọn (màn chia ô), báo không hiện thông báo cho các ô đang hiện.
  void _syncPaneFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.solo != null) return;
      final multi = _multi;
      final max = multi ? _panes.maximizedId : null;
      final hidden = <String>{
        if (max != null)
          for (final l in _panes.leaves)
            if (l.id != max && l.content?.isChat == true) l.content!.id,
      };
      // Một ô (hoặc điện thoại): như trước, mọi chat đang mở đều là chat đang đọc.
      final focus = multi ? _selected : null;
      final sig = '$multi|$focus|${hidden.join(',')}';
      if (sig == _paneSig) return;
      _paneSig = sig;
      _app.setPaneFocus(multi: multi, channelId: focus, hidden: hidden);
    });
  }

  void _focusPane(String id, {bool keyboard = false}) {
    if (id != _panes.focusedId) {
      setState(() => _panes.focus(id));
      _panesChanged();
    }
    if (keyboard) {
      final scope = _scopeOf(id);
      scope.requestFocus();
      if (scope.focusedChild == null) scope.nextFocus();
    }
  }

  void _closePane(String id) {
    setState(() => _panes.close(id));
    _paneNavs.remove(id);
    _paneKeys.remove(id);
    // Ô vẫn còn trong cây tới khung hình sau: huỷ FocusScopeNode sau khi ô đã gỡ.
    final scope = _paneScopes.remove(id);
    if (scope != null) WidgetsBinding.instance.addPostFrameCallback((_) => scope.dispose());
    _panesChanged();
  }

  /// Mở chat [channelId] từ ô [fromId] (ô danh sách thì mở ở ô chat khác / chia đôi). Trả về id ô hiện chat đó.
  String _openFromPane(String fromId, String channelId) {
    late PaneLeaf l;
    setState(() => l = _panes.openFrom(fromId, PaneContent.chat(channelId)));
    _panesChanged();
    return l.id;
  }

  /// Mở trang chồng lên trong ô [paneId] (sau khung hình: ô / navigator có thể vừa được tạo).
  void _pushInPane(String paneId, WidgetBuilder builder) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _paneNavs[paneId]?.$2.currentState?.push(MaterialPageRoute(builder: builder));
    });
  }

  void _onDrop(String targetId, PaneEdge edge, PaneDragData d) {
    setState(() => _panes.drop(targetId, edge, d.content, fromPane: d.fromPane));
    _panesChanged();
  }

  /// Tách nội dung ra cửa sổ riêng (máy tính). Kéo từ một ô thì đóng ô đó.
  Future<void> _popOut(PaneDragData d) async {
    final messenger = ScaffoldMessenger.of(context);
    final r = await PopoutWindows.open(d.content);
    if (!mounted) return;
    final msg = popoutNotice(r);
    if (msg != null) messenger.showSnackBar(toast(Text(msg)));
    final from = d.fromPane;
    if (from != null && (r == PopoutResult.opened || r == PopoutResult.alreadyOpen) && _panes.isMulti) _closePane(from);
  }

  (IconData, String) _sectionInfo(String s) => switch (s) {
        PaneSections.agents => (Icons.auto_awesome_outlined, tr('Các trợ lý')),
        PaneSections.tasks => (Icons.task_alt_rounded, tr('Việc')),
        PaneSections.threads => (Icons.forum_outlined, tr('Luồng')),
        PaneSections.apps => (Icons.apps_rounded, tr('Bạn')),
        _ => (Icons.chat_bubble_outline, tr('Chat')),
      };

  PaneLabel _describe(PaneContent c) {
    final pal = Pal.of(context);
    if (c.isSection) {
      final (icon, label) = _sectionInfo(c.id);
      return PaneLabel(label, Icon(icon, size: 18, color: pal.accentText));
    }
    final app = _app;
    final ch = app.channels[c.id];
    if (ch == null) return PaneLabel(tr('Cuộc trò chuyện'), Icon(Icons.chat_bubble_outline, size: 18, color: pal.sub));
    final title = app.channelTitle(ch);
    final other = ch.isDirect && app.me != null ? ch.otherUserId(app.me!.id) : null;
    return PaneLabel(
        title, Avatar(userId: other, name: title, size: 22, status: false, icon: other == null ? chatIcon(ch) : null, channel: ch));
  }

  /// ChatHost của một ô: một ô thì như trước (luồng / thông tin / AI ở cột phải); từ hai ô thì mở chồng ngay trong ô
  /// (ô chat) hoặc mở ở ô chat khác (ô danh sách).
  Widget _paneHost(String id, Widget child) {
    bool chatPane() => _panes.leaf(id)?.content?.isChat == true;
    return ChatHost(
      openChat: (c) => _multi || !chatPane() ? _openFromPane(id, c) : _open(c),
      openInfo: (c) => _multi ? _pushInPane(id, (_) => ChatInfoPage(channelId: c)) : _hostOpenInfo(c),
      openThread: (cid, root) {
        if (!_multi) return _hostOpenThread(cid, root);
        final target = chatPane() && _panes.leaf(id)?.content?.id == cid ? id : _openFromPane(id, cid);
        _pushInPane(target, (_) => ThreadPage(channelId: cid, rootId: root));
      },
      openSide: (c) {
        if (!_multi) return _openSide(c);
        chatPane() ? _pushInPane(id, (_) => ChatPage(channelId: c)) : _openFromPane(id, c);
      },
      openAi: (g, {thread}) {
        if (!_multi) return _hostOpenAi(g, thread: thread);
        final target = chatPane() && _panes.leaf(id)?.content?.id == g ? id : _openFromPane(id, g);
        _pushInPane(target, (ctx) => AiPanel(groupId: g, thread: thread, onClose: () => Navigator.of(ctx).maybePop()));
      },
      child: child,
    );
  }

  Widget _paneBody(BuildContext context, PaneLeaf l) {
    final app = context.read<AppState>();
    final c = l.content;
    final Widget inner = c == null || (c.isChat && !app.channels.containsKey(c.id))
        ? const _Welcome()
        : _ColumnNavigator(
            key: ValueKey(c.key),
            navKey: _navFor(l),
            root: c.isChat ? ChatPage(channelId: c.id, embedded: true) : _paneSection(l.id, c.id),
          );
    return FocusScope(node: _scopeOf(l.id), child: _paneHost(l.id, inner));
  }

  /// Một mục thanh tab hiện trong ô: mở chat thì mở ở ô chat khác (không thay chính ô danh sách).
  Widget _paneSection(String paneId, String section) {
    NavigatorState? nav() => _paneNavs[paneId]?.$2.currentState;
    void open(String id) => _openFromPane(paneId, id);
    return Builder(builder: (context) {
      final app = context.watch<AppState>();
      return Scaffold(
        backgroundColor: Pal.of(context).bg,
        body: section == PaneSections.chats
            ? _PaneChatList(onOpen: open, onSearchMessages: (q) => nav()?.push(MaterialPageRoute(builder: (_) => SearchPage(terms: q, onOpen: open))))
            : _sectionBody(PaneSections.tabOf(section), app, 16, nav, open: open, header: const SizedBox(height: 4)),
      );
    });
  }

  /// Phím tắt màn chia ô (máy tính): Ctrl/Cmd+1..4 chọn ô, Ctrl/Cmd+W đóng ô, Ctrl/Cmd+K chuyển nhanh tới chat.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted || !_wide) return false;
    final kb = HardwareKeyboard.instance;
    final mod = Platform.isMacOS ? kb.isMetaPressed : kb.isControlPressed;
    if (!mod || kb.isAltPressed || kb.isShiftPressed) return false;
    // Đang mở trang / hộp thoại chồng lên màn hình chính: để trang đó xử lý.
    if (!(ModalRoute.isCurrentOf(context) ?? false)) return false;
    final k = e.logicalKey;
    const digits = [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4];
    final i = digits.indexOf(k);
    if (i >= 0) {
      final leaves = _panes.leaves;
      if (i >= leaves.length) return false;
      _focusPane(leaves[i].id, keyboard: true);
      return true;
    }
    if (k == LogicalKeyboardKey.keyW) {
      if (!_panes.isMulti) return false;
      _closePane(_panes.focusedId);
      return true;
    }
    if (k == LogicalKeyboardKey.keyK) {
      showQuickSwitcher(context).then((id) {
        if (id != null && mounted) _open(id);
      });
      return true;
    }
    return false;
  }

  /// Vùng nội dung (máy tính): các ô.
  Widget _paneArea(AppState app) {
    // Bố cục đọc từ máy: bỏ ô của cuộc trò chuyện không còn (đã rời / bị xoá) khi đã đồng bộ xong.
    if (!_panesPruned && app.ready) {
      _panesPruned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _panes.prune((c) => !c.isChat || app.channels.containsKey(c.id)));
        _syncPaneFocus();
      });
    }
    return PaneArea(
      layout: _panes,
      keyOf: _paneKey,
      body: _paneBody,
      describe: _describe,
      unread: (l) => l.content?.isChat == true && app.unreadOf(l.content!.id) > 0,
      onFocus: _focusPane,
      onDrop: _onDrop,
      onClose: _closePane,
      onMaximize: (id) {
        setState(() => _panes.toggleMaximize(id));
        _panesChanged();
      },
      onPopOut: isDesktop ? (id) => _popOut(PaneDragData(_panes.leaf(id)!.content!, fromPane: id)) : null,
      onRatio: (sid, r) => setState(() => _panes.setRatio(sid, r)),
      onRatioEnd: _panesChanged,
    );
  }

  /// Cột trái (máy tính) nằm trong bộ điều hướng riêng nên không tự dựng lại theo trang chính:
  /// mỗi lần đổi trạng thái thì báo cho nó dựng lại.
  final _leftTick = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _leftTick.value++;
  }

  /// Link Boards của máy chủ đang dùng: mở màn hình gốc của app (thẻ, bảng, hoặc danh sách bảng), không mở web.
  bool _openInternalLink(Uri u) {
    if (!isBoardsUrl(u) || !mounted) return false;
    final p = parseBoardsPath(u);
    if (p == null) {
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const BoardsHomePage()));
    } else if (p.$3 != null) {
      openBoardCard(context, p.$1, p.$3!);
    } else {
      openBoard(context, p.$1, viewId: p.$2);
    }
    return true;
  }

  void _selectTab(int i) {
    if (i == _tab) return;
    final app = context.read<AppState>();
    if (i == 1) app.loadWorkThreads();
    setState(() => _tab = i);
  }

  /// Mở trang hồ sơ (ảnh đại diện góc trên bên trái).
  void _openProfile(NavigatorState? nav) => nav?.push(MaterialPageRoute(
      builder: (_) => _ProfilePage(onLogout: _confirmLogout, onSwitchServer: _switchServer)));

  // ---------------------------------------------------------------- vuốt 3 ngón lên: chọn máy chủ
  final Map<int, Offset> _touchStart = {};
  final Map<int, Offset> _touchNow = {};
  bool _swipeFired = false;

  /// Vuốt 3 ngón từ dưới lên: mở bảng chọn máy chủ.
  Widget _threeFingerSwipe(Widget child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          _touchStart[e.pointer] = e.position;
          _touchNow[e.pointer] = e.position;
          if (_touchStart.length == 1) _swipeFired = false;
        },
        onPointerMove: (e) {
          if (!_touchStart.containsKey(e.pointer)) return;
          _touchNow[e.pointer] = e.position;
          if (_swipeFired || _touchStart.length != 3) return;
          final dys = [for (final k in _touchStart.keys) _touchNow[k]!.dy - _touchStart[k]!.dy];
          final dxs = [for (final k in _touchStart.keys) (_touchNow[k]!.dx - _touchStart[k]!.dx).abs()];
          // Cả 3 ngón cùng đi lên ≥ 80px, lệch ngang ít.
          if (dys.every((d) => d < -80) && dxs.every((d) => d < 120)) {
            _swipeFired = true;
            HapticFeedback.mediumImpact();
            showServerPicker(context).then((url) {
              if (url != null && mounted) _switchServer(url);
            });
          }
        },
        onPointerUp: (e) {
          _touchStart.remove(e.pointer);
          _touchNow.remove(e.pointer);
        },
        onPointerCancel: (e) {
          _touchStart.remove(e.pointer);
          _touchNow.remove(e.pointer);
        },
        child: child,
      );

  /// Nút ＋ (tạo tin nhắn / nhóm / …) nổi ngay trên thanh tab.
  Widget _newButton(NavigatorState? Function() nav) => Builder(
        builder: (b) => PlusFab(heroTag: 'new-chat', tooltip: tr('Tạo mới'), onPressed: () => _plusMenu(b, nav())),
      );

  /// Tiêu đề các tab không phải Chat: ảnh đại diện | tên tab.
  Widget _tabTitle(String title, NavigatorState? Function() nav) {
    final pal = Pal.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          const SizedBox(width: 40),
          Expanded(
            child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
          ),
          const SizedBox(width: 40),
        ]),
      ),
    );
  }

  /// Nội dung theo tab (dùng chung điện thoại và cột trái máy tính).
  Widget _tabBody(AppState app, double bottom, NavigatorState? Function() nav) => _sectionBody(_tab, app, bottom, nav);

  /// Nội dung một mục thanh tab: [open] = mở chat (mặc định ở ô đang chọn), [header] thay tiêu đề mục (ô đã có đầu ô).
  Widget _sectionBody(int tab, AppState app, double bottom, NavigatorState? Function() nav,
          {void Function(String id)? open, Widget? header}) =>
      switch (!app.hasUsableAgents && tab == 2 ? 0 : tab) {
        1 => ThreadsView(header: header ?? _tabTitle(tr('Luồng công việc'), nav), bottomPadding: bottom),
        2 => AgentsView(
            onOpen: open ?? _open,
            selectedId: _wide && open == null ? _selected : null,
            bottomPadding: bottom,
            header: header ?? _tabTitle(tr('Các trợ lý'), nav)),
        3 => _apps(app, bottom, nav, open: open),
        4 => TasksView(
            header: header ?? _tabTitle(tr('Việc'), nav),
            bottomPadding: bottom,
            fabBottom: header != null || widget.solo != null ? 16 : (_wide ? 96 : PlusFab.bottomOf(context)),
          ),
        _ => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: _swipeFilter,
            child: ChatList(
              header: _listHeader(),
              query: _query,
              filter: _filter,
              selectedId: _wide ? _selected : null,
              onOpen: _open,
              onSearchMessages: _searchMessages,
              bottomPadding: bottom,
            ),
          ),
      };

  /// Mở một trang từ tab Apps (cột trái trên máy tính, trang mới trên điện thoại).
  void _push(NavigatorState? Function() nav, String title, Widget Function(BuildContext ctx) body) =>
      (nav() ?? Navigator.of(context)).push(MaterialPageRoute(
          builder: (ctx) => Scaffold(
                backgroundColor: Pal.of(ctx).bg,
                appBar: AppBar(title: Text(title)),
                body: body(ctx),
              )));

  /// Tab Apps: lưới các ứng dụng (Hẹn giờ khi có trợ lý AI, Danh bạ, Lịch sử cuộc gọi, Bạn, Ngôn ngữ, Bot, Trợ lý, Chặn).
  Widget _apps(AppState app, double bottom, NavigatorState? Function() nav, {void Function(String id)? open}) {
    final pal = Pal.of(context);
    void openChat(BuildContext ctx, String id) {
      Navigator.of(ctx).pop();
      (open ?? _open)(id);
    }

    final me = app.me;
    final work = <(IconData, Color, String, int, VoidCallback)>[
      (Icons.contacts_rounded, const Color(0xFF2F80ED), tr('Danh bạ'), 0,
          () => _push(nav, tr('Danh bạ'), (ctx) => PeopleView(header: const SizedBox.shrink(), onOpen: (id) => openChat(ctx, id)))),
      (Icons.call_rounded, const Color(0xFFE53935), tr('Lịch sử cuộc gọi'), app.missedCalls, () {
        app.markCallsSeen();
        _push(nav, tr('Lịch sử cuộc gọi'), (ctx) => CallHistoryView(header: const SizedBox.shrink(), onOpen: (id) => openChat(ctx, id)));
      }),
    ];
    final auto = <(IconData, Color, String, int, VoidCallback)>[
      if (app.hasUsableAgents)
        (Icons.alarm_rounded, const Color(0xFFF2994A), tr('Hẹn giờ'), 0,
            () => _push(nav, tr('Hẹn giờ'), (_) => const SchedulesView(header: SizedBox.shrink()))),
      (Icons.auto_awesome_rounded, const Color(0xFFD97757), tr('Trợ lý'), 0,
          () => (nav() ?? Navigator.of(context)).push(MaterialPageRoute(builder: (_) => const AgentPage()))),
      (Icons.power_outlined, const Color(0xFF607D8B), tr('Bot'), 0,
          () => (nav() ?? Navigator.of(context)).push(MaterialPageRoute(builder: (_) => const BotsPage()))),
    ];
    final personal = <(IconData, Color, String, int, VoidCallback)>[
      (Icons.settings_rounded, const Color(0xFF14A38B), tr('Cài đặt'), 0, () => _openProfile(nav())),
      // Điện thoại: quét QR để đăng nhập máy tính cùng mạng LAN (ngay sau Cài đặt).
      if (!isDesktop)
        (Icons.qr_code_scanner_rounded, const Color(0xFF00A3A3), tr('Đăng nhập QR'), 0,
            () => (nav() ?? Navigator.of(context)).push(MaterialPageRoute(builder: (_) => const QrScanPage()))),
      (Icons.translate_rounded, const Color(0xFF9B51E0), tr('Ngôn ngữ'), 0, () => _pickLanguage(context)),
      (Icons.password_rounded, const Color(0xFFF2C94C), tr('Mật khẩu'), 0,
          () => (nav() ?? Navigator.of(context)).push(MaterialPageRoute(builder: (_) => const PasswordPage()))),
      (Icons.block_rounded, const Color(0xFF8E8E93), tr('Chặn'), 0,
          () => (nav() ?? Navigator.of(context)).push(MaterialPageRoute(builder: (_) => const BlockedUsersPage()))),
      (Icons.system_update_rounded, const Color(0xFF27AE60), tr('Cập nhật'), 0, () => showUpdateDialog(context)),
      // App phục vụ theo từng tên miền: chính sách quyền riêng tư và điều khoản là của máy chủ đang dùng (link trong
      // cấu hình máy chủ). Yêu cầu xoá tài khoản (App Store bắt buộc) gửi cho quản trị viên của máy chủ đó.
      (Icons.privacy_tip_outlined, const Color(0xFF5B6CFF), tr('Quyền riêng tư'), 0, () => openServerLegal(context)),
      (Icons.gavel_rounded, const Color(0xFF8D6E63), tr('Điều khoản'), 0, () => openServerLegal(context, terms: true)),
      // Đồng ý gửi dữ liệu cho AI: xem lại, rút lại.
      (Icons.auto_awesome_outlined, const Color(0xFFD97757), tr('AI'), 0, () => showAiConsentSettings(context)),
    ];
    Widget appTile(Widget icon, Color color, String label, int badge, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Badge(
              isLabelVisible: badge > 0,
              label: Text(badge > 99 ? '99+' : '$badge'),
              backgroundColor: const Color(0xFFE53935),
              textColor: Colors.white,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(18)),
                child: Center(child: icon),
              ),
            ),
            const SizedBox(height: 8),
            Text(label, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.text)),
          ]),
        ),
      );
    }

    Widget tile((IconData, Color, String, int, VoidCallback) it) {
      final (icon, color, label, badge, onTap) = it;
      return appTile(Icon(icon, color: color, size: 30), color, label, badge, onTap);
    }

    // Mini app: biểu tượng của app (ảnh / emoji) trên nền xám nhạt; mờ khi cần cập nhật Flygo.
    Widget miniTile(Widget icon, String label, bool dim, VoidCallback onTap) =>
        Opacity(opacity: dim ? .45 : 1, child: appTile(icon, pal.sub, label, 0, onTap));

    Widget grid(String title, List<Widget> tiles) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(title.toUpperCase(),
                  style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
            ),
            LayoutBuilder(builder: (ctx, c) {
              // Điện thoại: 4 cột; màn rộng hơn thì thêm cột (tối đa 6).
              final cols = (c.maxWidth / 96).floor().clamp(4, 6);
              final w = (c.maxWidth - 24) / cols;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(children: [for (final t in tiles) SizedBox(width: w, child: t)]),
              );
            }),
          ],
        );

    Widget section(String title, List<(IconData, Color, String, int, VoidCallback)> items) => grid(title, [for (final it in items) tile(it)]);

    return ListView(padding: EdgeInsets.only(bottom: bottom + 16), children: [
      const SafeArea(bottom: false, child: SizedBox(height: 8)),
      // Chọn / chuyển máy chủ.
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ServerSelectButton(onSelected: _switchServer)),
      const SizedBox(height: 16),
      // Ảnh đại diện + tên (như trang Bạn); bấm để mở cài đặt.
      if (me != null)
        Center(
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _openProfile(nav()),
            child: Avatar(userId: me.id, name: me.displayName, size: 96, status: false),
          ),
        ),
      const SizedBox(height: 12),
      if (me != null)
        Text(me.displayName, textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: pal.text)),
      if (me != null)
        Text('@${me.username}', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: pal.sub)),
      const SizedBox(height: 16),
      // Hoạt động và trạng thái.
      const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: StatusSection(plain: true)),
      section(tr('Công việc'), work),
      // Mini app của máy chủ (registry), ẩn khi không có.
      MiniAppsSection(key: ValueKey(kServerUrl), section: grid, tile: miniTile),
      section(tr('Tự động hóa'), auto),
      section(tr('Cá nhân'), personal),
      // Xoá tài khoản / Đăng xuất: nút nhỏ căn giữa ở cuối trang, phải BẤM GIỮ để tránh bấm nhầm.
      // Cửa sổ riêng không đăng xuất (phiên dùng chung với cửa sổ chính).
      if (!isChildWindow) ...[
      const SizedBox(height: 20),
      Center(
        child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 4, children: [
          _holdButton(pal, Icons.person_remove_rounded, tr('Xoá tài khoản'), pal.sub,
              () => requestAccountDeletion(context, context.read<AppState>())),
          _holdButton(pal, Icons.logout_rounded, tr('Đăng xuất'), const Color(0xFFE53935), _confirmLogout),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(tr('Bấm giữ để thực hiện'), textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: pal.sub)),
      ),
      ],
    ]);
  }

  /// Nút nhỏ chỉ chạy khi bấm giữ; bấm thường thì nhắc "Bấm giữ để …".
  Widget _holdButton(Pal pal, IconData icon, String label, Color color, VoidCallback onHold) => Tooltip(
        message: tr('Bấm giữ để {0}', [label.toLowerCase()]),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Bấm giữ để {0}', [label.toLowerCase()])))),
          onLongPress: () {
            HapticFeedback.mediumImpact();
            onHold();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(border: Border.all(color: color.withValues(alpha: .4)), borderRadius: BorderRadius.circular(18)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );

  Widget _tabBar(AppState app) => ValueListenableBuilder<int>(
      valueListenable: tasksOverdue,
      builder: (_, overdue, _) => _TabBar(
        index: _tab,
        unread: app.chats.where((c) => c.unread > 0).length,
        threads: app.privateThreads.where((c) => !c.isClosed).length +
            app.workThreads.where((t) => !app.isThreadClosed(t.root.channelId, t.root.id)).length,
        missed: app.missedCalls,
        agents: app.agentUnread,
        // Chưa có trợ lý AI nào: ẩn tab Agents (Hẹn giờ trong Apps cũng ẩn).
        hasAgents: app.hasUsableAgents,
        me: app.me,
        tasks: app.todos['in']?.length ?? 0,
        work: overdue,
        onTap: _selectTab,
      ));

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    // Bố cục chưa kịp lưu (vừa đổi xong thì đóng cửa sổ / đổi ngôn ngữ): lưu ngay.
    if (_paneSave?.isActive == true) _app.savePanes(_panes.toJson()).catchError((_) {});
    _paneSave?.cancel();
    for (final s in _paneScopes.values) {
      s.dispose();
    }
    if (internalLinkHook == _openInternalLink) internalLinkHook = null;
    if (PushService.openChatHook == _open) {
      PushService.openChatHook = null;
      PushService.openThreadHook = null;
    }
    if (widget.solo == null) AppBadge.detach(_app);
    _leftTick.dispose();
    super.dispose();
  }

  /// Chọn máy chủ khác: máy tính mở cửa sổ riêng, điện thoại chuyển ngay trong app.
  void _switchServer(String url) {
    if (url == ServerList.current) return;
    if (isDesktop) {
      // Thêm máy chủ mới: cửa sổ riêng mở thẳng màn đăng nhập.
      url == kAddServer ? AppState.openAddServerWindow() : AppState.openServerWindow(url);
    } else {
      widget.onSwitchServer(url);
    }
  }

  /// Mở luồng bí mật ở cột phải. Luồng nhiều tầng / mở từ nơi khác (tab Luồng, nhóm khác đang chọn):
  /// chọn nhóm gốc ngoài cùng ở cột giữa rồi mở luồng ở cột phải, để luôn hiện trang mới.
  void _openSide(String id) {
    final app = context.read<AppState>();
    // Nhiều ô: mở chồng trong ô đang chọn (nút quay lại trở về chat cha).
    if (_multi) {
      _pushInPane(_panes.focusedId, (_) => ChatPage(channelId: id));
      return;
    }
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
      if (top != null && (_selected == null || (_selected != top && _selected != app.channels[id]?.subParent))) {
        _panes.open(PaneContent.chat(top));
      }
      if (_side?.$2 != id) _sideNav = GlobalKey<NavigatorState>();
      _side = _selected == null ? null : (_selected!, id);
      _thread = null;
      _infoFor = null;
    });
    _panesChanged();
    if (_selected == null) openChannelAnywhereFallback(id);
  }

  void openChannelAnywhereFallback(String id) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(channelId: id)));

  void _open(String channelId) {
    if (widget.solo != null) {
      _soloNav.currentState?.push(MaterialPageRoute(builder: (_) => ChatPage(channelId: channelId)));
    } else if (_wide) {
      setState(() {
        if (_infoFor != null && _infoFor != channelId) _infoFor = channelId;
        final c = PaneContent.chat(channelId);
        // Ô đang chọn là một danh sách (vd. "Các trợ lý"): mở ở ô chat khác, giữ danh sách.
        _panes.isMulti && _panes.focused.content?.isSection == true ? _panes.openFrom(_panes.focusedId, c) : _panes.open(c);
      });
      _panesChanged();
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
            item(ctx, 'direct', Icons.person_add_alt_1_rounded, const Color(0xFF27AE60), tr('Nhắn tin riêng'),
                tr('Chọn người trong danh bạ để nhắn tin 1-1')),
            item(ctx, 'private', Icons.group_add_rounded, const Color(0xFF2F80ED), tr('Tạo nhóm'),
                tr('Nhóm riêng tư, chỉ người được mời mới vào được')),
            item(ctx, 'public', Icons.tag_rounded, const Color(0xFF14A38B), tr('Tạo kênh'),
                tr('Kênh công khai, ai trong công ty cũng tham gia được')),
            item(ctx, 'meeting', Icons.videocam_rounded, const Color(0xFFF2994A), tr('Tạo cuộc họp'),
                tr('Họp video ngay với nhiều người')),
            item(ctx, 'agent', Icons.auto_awesome_rounded, const Color(0xFF9B51E0), tr('Tạo trợ lý AI'),
                tr('Trợ lý Claude / Codex chạy trên máy của bạn')),
            item(ctx, 'bot', Icons.power_outlined, pal.sub, tr('Tạo bot tích hợp'),
                tr('Cho phần mềm khác gửi tin vào, không có AI')),
          ]),
        ),
      ),
    );
    if (v == null || !mounted) return;
    if (v == 'direct') {
      nav.push(MaterialPageRoute(
          builder: (ctx) => Scaffold(
                appBar: AppBar(title: Text(tr('Danh bạ'))),
                body: PeopleView(header: const SizedBox.shrink(), onOpen: (id) {
                  Navigator.of(ctx).pop();
                  _open(id);
                }),
              )));
      return;
    }
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        Expanded(
          child: ServerTitle(onSelected: _switchServer),
        ),
      ]),
    );
  }

  /// Thanh trên của cột danh sách (máy tính): tên máy chủ (nút ＋ và ảnh đại diện ở dưới).
  Widget _topBarWide() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        Expanded(
          child: ServerTitle(onSelected: _switchServer),
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
      // Bộ lọc dạng tab (gạch chân), cuộn ngang khi chật.
      SizedBox(
        height: 42,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.divider, width: .6))),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              // Luồng công việc có tab riêng.
              for (final f in _filters)
                InkWell(
                  key: _filterKeys[f],
                  onTap: () => _setFilter(f),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: _filter == f ? pal.accent : Colors.transparent, width: 2.5)),
                    ),
                    child: Text(chatFilterLabels[f]!,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: _filter == f ? FontWeight.w700 : FontWeight.w500,
                            color: _filter == f ? pal.accentText : pal.sub)),
                  ),
                ),
            ],
          ),
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

  /// Cột phải (một ô): thông tin của chat đang mở.
  void _hostOpenInfo(String id) {
    if (_multi) return _pushInPane(_panes.focusedId, (_) => ChatInfoPage(channelId: id));
    setState(() {
      _infoFor = _infoFor == id ? null : id;
      _thread = null;
      _side = null;
    });
  }

  /// Mở luồng (chủ đề) của chat: một ô thì ở cột phải, nhiều ô thì chồng trong ô của chat đó.
  void _hostOpenThread(String cid, String root) {
    if (_multi) {
      final target = _panes.find(PaneContent.chat(cid))?.id ?? _openFromPane(_panes.focusedId, cid);
      _focusPane(target);
      _pushInPane(target, (_) => ThreadPage(channelId: cid, rootId: root));
      return;
    }
    setState(() {
      _thread = (cid, root);
      _infoFor = null;
      _side = null;
    });
  }

  /// Mở trợ lý AI của nhóm [g]: một ô thì ở cột AI bên phải, nhiều ô thì chồng trong ô của nhóm đó.
  void _hostOpenAi(String g, {String? thread}) {
    if (_multi) {
      final target = _panes.find(PaneContent.chat(g))?.id ?? _openFromPane(_panes.focusedId, g);
      _focusPane(target);
      _pushInPane(target, (ctx) => AiPanel(groupId: g, thread: thread, onClose: () => Navigator.of(ctx).maybePop()));
      return;
    }
    setState(() {
      _panes.open(PaneContent.chat(g));
      _aiThread = thread == null ? null : (g, thread);
      _aiHidden = null;
      _thread = null;
      _side = null;
      _infoFor = null;
    });
    _panesChanged();
  }

  /// Cửa sổ riêng của một mục thanh tab: mục đó chiếm cả cửa sổ, chat mở chồng lên (như điện thoại).
  Widget _soloBody(AppState app) {
    final pal = Pal.of(context);
    final section = widget.solo!;
    return AboveNavSnackBars(
      navTop: 24,
      child: Scaffold(
        backgroundColor: pal.bg,
        body: SafeArea(
          child: _ColumnNavigator(
            navKey: _soloNav,
            root: ListenableBuilder(
              listenable: _leftTick,
              builder: (context, _) {
                final app = context.watch<AppState>();
                return Scaffold(
                  backgroundColor: pal.bg,
                  body: Column(children: [
                    const OfflineBanner(),
                    Expanded(
                      child: section == PaneSections.chats
                          ? _PaneChatList(
                              onOpen: _open,
                              onSearchMessages: (q) => _soloNav.currentState
                                  ?.push(MaterialPageRoute(builder: (_) => SearchPage(terms: q, onOpen: _open))))
                          : _sectionBody(_tab, app, 16, () => _soloNav.currentState),
                    ),
                  ]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    if (widget.solo != null) return _soloBody(app);
    _syncPaneFocus();

    if (_wide) {
      final multi = _panes.isMulti;
      // Nhiều ô: luồng / thông tin / AI mở ngay trong ô, không có cột phải.
      final hasChat = !multi && _selected != null && app.channels.containsKey(_selected);
      final showSide = hasChat && _side != null && _side!.$1 == _selected && app.channels.containsKey(_side!.$2);
      final showThread = hasChat && !showSide && _thread != null && _thread!.$1 == _selected;
      final showInfo = hasChat && _infoFor == _selected && !showThread && !showSide;
      // Cột phải mặc định: chat riêng với trợ lý AI của nhóm đang mở (khi không mở luồng / thông tin).
      final showAi = hasChat && !showThread && !showSide && !showInfo && _aiHidden != _selected &&
          app.showsAiFor(app.channels[_selected]!);
      // Phiên AI của một luồng (mở từ nút AI trong trang luồng); đổi sang chat khác thì về AI của cả nhóm.
      final aiThread = _aiThread != null && _aiThread!.$1 == _selected ? _aiThread!.$2 : null;
      return PaneHost(
        describe: _describe,
        canPopOut: isDesktop,
        popOut: _popOut,
        child: ChatHost(
        openChat: _open,
        openInfo: _hostOpenInfo,
        openThread: _hostOpenThread,
        openSide: _openSide,
        openAi: _hostOpenAi,
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
                          if (_tab == 0) Positioned(right: 16, bottom: 96, child: _newButton(() => _leftNav.currentState)),
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
              // Vùng nội dung: 1–4 ô (kéo chat / mục thanh tab vào để chia ô).
              Expanded(child: _paneArea(app)),
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
                    key: ValueKey('ai-$_selected-${aiThread ?? ''}'),
                    root: AiPanel(groupId: _selected!, thread: aiThread, onClose: () => setState(() => _aiHidden = _selected)),
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
      child: _threeFingerSwipe(Scaffold(
      backgroundColor: pal.bg,
      body: Stack(children: [
        Positioned.fill(child: body),
        if (_tab == 0)
          Positioned(right: 20, bottom: PlusFab.bottomOf(context), child: _newButton(() => Navigator.of(context))),
        Positioned(
          left: 20,
          right: 20,
          // Máy có thanh vuốt (iPhone): thanh tab đè nhẹ lên vùng an toàn cho thấp gọn như WhatsApp.
          bottom: bottomInset > 0 ? bottomInset - 14 : 10,
          child: _tabBar(app),
        ),
      ]),
      )),
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
  /// Mở cột AI bên phải (máy tính); [thread]: phiên AI của luồng công việc riêng đó.
  final void Function(String groupId, {String? thread})? openAi;
  const ChatHost(
      {super.key, required this.openChat, required this.openInfo, required this.openThread, this.openSide, this.openAi, required super.child});
  static ChatHost? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ChatHost>();
  @override
  bool updateShouldNotify(ChatHost old) => false;
}

/// Mỗi cột có bộ điều hướng riêng: trang con mở trong cột, có nút quay lại.
/// Cột có điều hướng riêng. Trang gốc luôn là [root] của lần build mới nhất (route chỉ tạo một lần nên phải
/// chuyển qua ValueNotifier — trước đây trang gốc giữ màu cũ khi máy đổi sáng/tối lúc app đang mở).
class _ColumnNavigator extends StatefulWidget {
  final GlobalKey<NavigatorState>? navKey;
  final Widget root;
  const _ColumnNavigator({super.key, this.navKey, required this.root});
  @override
  State<_ColumnNavigator> createState() => _ColumnNavigatorState();
}

class _ColumnNavigatorState extends State<_ColumnNavigator> {
  late final _root = ValueNotifier<Widget>(widget.root);

  @override
  void didUpdateWidget(_ColumnNavigator old) {
    super.didUpdateWidget(old);
    _root.value = widget.root;
  }

  @override
  void dispose() {
    _root.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        child: Navigator(
          key: widget.navKey,
          onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => ValueListenableBuilder<Widget>(valueListenable: _root, builder: (_, w, _) => w)),
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

/// Thanh tab nổi dạng viên thuốc, kính mờ: Chat · Agents (khi có trợ lý AI) · Việc · Luồng · Apps.
/// Chỉ số tab cố định theo nội dung (0 Chat, 1 Luồng, 2 Agents, 3 Apps, 4 Việc), không theo vị trí trên thanh.
class _TabBar extends StatelessWidget {
  final int index;
  final int unread;
  final int threads;
  final int missed;
  final int agents;
  final bool hasAgents;
  /// Ô cuối là ảnh đại diện của mình (mở trang Apps).
  final MmUser? me;
  final int tasks;
  /// Số việc (Boards) của tôi đã quá hạn.
  final int work;
  final ValueChanged<int> onTap;
  const _TabBar({
    required this.index,
    required this.unread,
    required this.threads,
    required this.missed,
    required this.agents,
    this.hasAgents = true,
    this.me,
    required this.tasks,
    this.work = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget item(int i, IconData icon, String label, int count, {Color? badge, Widget? avatar}) {
      final sel = i == index;
      return Expanded(
        // Máy tính: kéo một mục (Chat, Các trợ lý, Việc, Luồng, Bạn) vào vùng nội dung để mở thành một ô.
        child: PaneDragSource(
        content: PaneContent.section(PaneSections.ofTab(i)),
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
                  child: avatar == null
                      ? Icon(icon)
                      : Container(
                          padding: const EdgeInsets.all(1.5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: sel ? pal.accent : Colors.transparent, width: 1.5),
                          ),
                          child: avatar,
                        ),
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
          if (hasAgents) item(2, Icons.auto_awesome_outlined, tr('Các trợ lý'), agents),
          item(4, Icons.task_alt_rounded, tr('Việc'), work, badge: const Color(0xFFE53935)),
          item(1, Icons.forum_outlined, tr('Luồng'), threads),
          item(3, Icons.apps_rounded, tr('Bạn'), missed, badge: const Color(0xFFE53935),
              avatar: me == null ? null : Avatar(userId: me!.id, name: me!.displayName, size: 28, status: false)),
        ]),
      ),
    );
  }
}

/// Mục "Chat" mở trong một ô / cửa sổ riêng: ô tìm và bộ lọc riêng, không dùng chung với cột trái.
class _PaneChatList extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final void Function(String query) onSearchMessages;
  const _PaneChatList({required this.onOpen, required this.onSearchMessages});
  @override
  State<_PaneChatList> createState() => _PaneChatListState();
}

class _PaneChatListState extends State<_PaneChatList> {
  String _q = '';
  ChatFilter _filter = ChatFilter.all;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: TextField(
          onChanged: (v) => setState(() => _q = v),
          style: TextStyle(color: pal.text, fontSize: 15),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: pal.surface,
            hintText: tr('Tìm kiếm'),
            hintStyle: TextStyle(color: pal.sub),
            prefixIcon: Icon(Icons.search, color: pal.sub, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final f in ChatFilter.values)
            if (f != ChatFilter.threads)
              InkWell(
                onTap: () => setState(() => _filter = f),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: _filter == f ? pal.accent : Colors.transparent, width: 2.5)),
                  ),
                  child: Text(chatFilterLabels[f]!,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: _filter == f ? FontWeight.w700 : FontWeight.w500,
                          color: _filter == f ? pal.accentText : pal.sub)),
                ),
              ),
        ]),
      ),
      const SizedBox(height: 4),
    ]);
    return ChatList(
      header: header,
      query: _q,
      filter: _filter,
      onOpen: widget.onOpen,
      onSearchMessages: () => widget.onSearchMessages(_q),
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
                    onChanged: (v) => setState(() {
                      // Mỗi chat chỉ một trợ lý AI: chọn trợ lý này thì bỏ trợ lý đã chọn trước.
                      if (v == true && engineOf(u) != null) _picked.removeWhere((id) => engineOf(app.users[id]) != null);
                      v == true ? _picked.add(u.id) : _picked.remove(u.id);
                    }),
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
/// Tên người dùng hợp lệ của máy chủ chat: 3–22 ký tự, bắt đầu bằng chữ, chỉ a-z 0-9 . - _
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
        if (DesktopTray.supported) ...[
          const SizedBox(height: 16),
          InfoGroup(children: [
            ValueListenableBuilder<bool>(
              valueListenable: DesktopTray.closeToTray,
              builder: (_, v, _) => InfoRow(
                icon: Icons.move_to_inbox_outlined,
                title: tr('Chạy ẩn khi đóng cửa sổ'),
                trailing: Switch.adaptive(value: v, activeTrackColor: pal.accent, onChanged: DesktopTray.setCloseToTray),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: DesktopTray.autostart,
              builder: (_, v, _) => InfoRow(
                icon: Icons.power_settings_new,
                title: tr('Mở cùng Windows'),
                trailing: Switch.adaptive(value: v, activeTrackColor: pal.accent, onChanged: DesktopTray.setAutostart),
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
                tr('Bấm X thì Flygo Chat thu xuống khay hệ thống (góc phải thanh taskbar) và vẫn nhận tin nhắn, cuộc gọi. Muốn thoát hẳn: chuột phải vào biểu tượng ở khay → Thoát.'),
                style: TextStyle(fontSize: 13, color: pal.sub)),
          ),
        ],
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
              leading: LangFlag(e.key),
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
        // Giới hạn giá trị theo bề ngang của chính hàng (không theo cả màn hình): trên máy tính trang này chỉ
        // chiếm một cột, giá trị dài (email) từng chiếm hết chỗ làm tiêu đề bị ngắt mỗi dòng một chữ.
        child: LayoutBuilder(
          builder: (context, box) => Row(children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 16),
            Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, color: color))),
            // Không dùng Flexible: nó chia đôi chiều ngang với tiêu đề, làm số đếm lệch vào giữa.
            if (value != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * .55),
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
