import 'dart:async';

import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_info_page.dart';
import 'chat_list.dart';
import 'chat_page.dart';
import 'common.dart';
import 'server_picker.dart';
import 'status_ui.dart';
import 'bot_page.dart';
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
  final _leftNav = GlobalKey<NavigatorState>();
  String _query = '';
  ChatFilter _filter = ChatFilter.all;
  int _tab = 0;
  final _searchCtl = TextEditingController();

  bool get _wide => MediaQuery.sizeOf(context).width >= 860;

  void _open(String channelId) {
    if (_wide) {
      setState(() {
        if (_infoFor != null && _infoFor != channelId) _infoFor = channelId;
        _selected = channelId;
        _tab = 0;
      });
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(channelId: channelId)));
    }
  }

  /// Nút "+": tạo nhóm công khai / riêng tư, cuộc họp, bot cá nhân.
  Future<void> _plusMenu(BuildContext btn, NavigatorState? nav) async {
    if (nav == null) return;
    final pal = Pal.of(context);
    final box = btn.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height + 6), ancestor: overlay);
    PopupMenuItem<String> item(String v, IconData icon, String label) => PopupMenuItem(
          value: v,
          child: Row(children: [
            Icon(icon, size: 21, color: pal.text),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: pal.text, fontSize: 15.5)),
          ]),
        );
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, overlay.size.width - pos.dx - box.size.width, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        item('public', Icons.tag, tr('Tạo kênh')),
        item('private', Icons.group_add_outlined, tr('Tạo nhóm')),
        item('meeting', Icons.video_call_outlined, tr('Tạo cuộc họp')),
        item('bot', Icons.smart_toy_outlined, tr('Tạo bot cá nhân')),
      ],
    );
    if (v == null || !mounted) return;
    if (v == 'bot') {
      nav.push(MaterialPageRoute(builder: (_) => const BotEditPage()));
      return;
    }
    final kind = {'public': NewChatKind.publicGroup, 'private': NewChatKind.privateGroup, 'meeting': NewChatKind.meeting}[v]!;
    final id = await nav.push<String>(MaterialPageRoute(builder: (_) => NewChatPage(kind: kind)));
    if (id == null || !mounted) return;
    _open(id);
    if (kind == NewChatKind.meeting) context.read<AppState>().calls.startCall(id);
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
    if (ok == true) await widget.onLogout();
  }

  Widget _topBar() {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        const SizedBox(width: 44),
        Expanded(
          child: Text(tr('Chat'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
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
    final app = context.read<AppState>();
    final me = app.me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        Tooltip(
          message: tr('Bạn'),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _leftNav.currentState?.push(MaterialPageRoute(
                builder: (_) => _ProfilePage(onLogout: _confirmLogout, onSwitchServer: widget.onSwitchServer))),
            child: me == null
                ? const GlassCircle(icon: Icons.person_outline)
                : Avatar(userId: me.id, name: me.displayName, size: 40),
          ),
        ),
        Expanded(
          child: Text(tr('Chat'),
              textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
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
            for (final f in ChatFilter.values)
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

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();

    if (_wide) {
      final hasChat = _selected != null && app.channels.containsKey(_selected);
      final showInfo = hasChat && _infoFor == _selected;
      return ChatHost(
        openChat: _open,
        openInfo: (id) => setState(() => _infoFor = _infoFor == id ? null : id),
        child: Scaffold(
          backgroundColor: pal.bg,
          body: SafeArea(
            child: Row(children: [
              SizedBox(
                width: 380,
                child: _ColumnNavigator(
                  navKey: _leftNav,
                  root: Column(children: [
                    _topBarWide(),
                    const OfflineBanner(),
                    Expanded(
                      child: ChatList(
                        header: _listHeader(),
                        query: _query,
                        filter: _filter,
                        selectedId: _selected,
                        onOpen: _open,
                        onSearchMessages: _searchMessages,
                      ),
                    ),
                  ]),
                ),
              ),
              VerticalDivider(width: 1, color: pal.divider),
              Expanded(
                child: !hasChat
                    ? const _Welcome()
                    : _ColumnNavigator(
                        key: ValueKey('chat-$_selected'),
                        root: ChatPage(channelId: _selected!, embedded: true),
                      ),
              ),
              if (showInfo) ...[
                VerticalDivider(width: 1, color: pal.divider),
                SizedBox(
                  width: 380,
                  child: _ColumnNavigator(
                    key: ValueKey('info-$_selected'),
                    root: ChatInfoPage(channelId: _selected!, onClose: () => setState(() => _infoFor = null)),
                  ),
                ),
              ],
            ]),
          ),
        ),
      );
    }

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final Widget body = switch (_tab) {
      0 => Column(children: [
          SafeArea(bottom: false, child: _topBar()),
          const OfflineBanner(),
          Expanded(
            child: ChatList(
              header: _listHeader(),
              query: _query,
              filter: _filter,
              onOpen: _open,
              onSearchMessages: _searchMessages,
              bottomPadding: 84 + bottomInset,
            ),
          ),
        ]),
      1 => PeopleView(onOpen: _open, bottomPadding: 84 + bottomInset),
      _ => ProfileView(onLogout: _confirmLogout, onSwitchServer: widget.onSwitchServer, bottomPadding: 84 + bottomInset),
    };

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(children: [
        Positioned.fill(child: body),
        Positioned(
          left: 20,
          right: 20,
          // Máy có thanh vuốt (iPhone): thanh tab đè nhẹ lên vùng an toàn cho thấp gọn như WhatsApp.
          bottom: bottomInset > 0 ? bottomInset - 14 : 10,
          child: _TabBar(
            index: _tab,
            unread: app.chats.where((c) => c.unread > 0).length,
            onTap: (i) => setState(() => _tab = i),
          ),
        ),
      ]),
    );
  }
}

/// Cho các trang trong cột chat biết đang ở giao diện máy tính nhiều cột:
/// mở chat khác, mở/đóng cột cài đặt.
class ChatHost extends InheritedWidget {
  final void Function(String channelId) openChat;
  final void Function(String channelId) openInfo;
  const ChatHost({super.key, required this.openChat, required this.openInfo, required super.child});
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

/// Thanh tab nổi dạng viên thuốc, kính mờ.
class _TabBar extends StatelessWidget {
  final int index;
  final int unread;
  final ValueChanged<int> onTap;
  const _TabBar({required this.index, required this.unread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.read<AppState>();
    Widget item(int i, Widget icon, String label) {
      final sel = i == index;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(i),
          child: Container(
            margin: const EdgeInsets.all(5),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: sel ? pal.text.withValues(alpha: .10) : Colors.transparent,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              IconTheme(data: IconThemeData(color: pal.text.withValues(alpha: sel ? 1 : .8), size: 26), child: icon),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(fontSize: 11.5, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: pal.text)),
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
          item(
              0,
              Badge(
                isLabelVisible: unread > 0,
                backgroundColor: pal.accent,
                textColor: Colors.white,
                label: Text('$unread'),
                child: const Icon(Icons.chat_bubble_outline),
              ),
              tr('Chat')),
          item(1, const Icon(Icons.people_outline), tr('Danh bạ')),
          item(
              2,
              app.me == null
                  ? const Icon(Icons.person_outline)
                  : Avatar(userId: app.me!.id, name: app.me!.displayName, size: 28),
              tr('Bạn')),
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

/// Tab Danh bạ: bấm vào ai là mở tin nhắn riêng.
class PeopleView extends StatefulWidget {
  final void Function(String channelId) onOpen;
  final double bottomPadding;
  final bool pickMode;
  const PeopleView({super.key, required this.onOpen, this.bottomPadding = 0, this.pickMode = false});
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
      messenger.showSnackBar(SnackBar(content: Text(tr('Không mở được cuộc trò chuyện. Kiểm tra kết nối mạng.'))));
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
      if (!widget.pickMode)
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
      messenger.showSnackBar(SnackBar(content: Text(kind == NewChatKind.publicGroup ? tr('Hãy đặt tên cho kênh.') : tr('Hãy đặt tên cho nhóm.'))));
      return;
    }
    setState(() => _busy = true);
    try {
      nav.pop(await app.createGroup(n, _picked, public: kind == NewChatKind.publicGroup));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(tr('Không tạo được nhóm. Kiểm tra kết nối mạng.'))));
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
                    title: Text(u.displayName, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                    subtitle: Text(u.email, style: TextStyle(color: pal.sub)),
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
      child: ListView(padding: EdgeInsets.fromLTRB(16, 18, 16, bottomPadding), children: [
        Text(tr('Bạn'), textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
        const SizedBox(height: 14),
        ServerSelectButton(onSelected: onSwitchServer),
        const SizedBox(height: 22),
        Center(child: Avatar(userId: me.id, name: me.displayName, size: 120)),
        const SizedBox(height: 16),
        Text(me.displayName,
            textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: pal.text)),
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
            icon: Icons.smart_toy_outlined,
            title: tr('Quản lý bot'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BotsPage())),
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
