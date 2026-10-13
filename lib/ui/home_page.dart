import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_list.dart';
import 'chat_page.dart';
import 'common.dart';
import 'server_picker.dart';
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
  String _query = '';
  ChatFilter _filter = ChatFilter.all;
  int _tab = 0;
  final _searchCtl = TextEditingController();

  bool get _wide => MediaQuery.sizeOf(context).width >= 860;

  void _open(String channelId) {
    if (_wide) {
      setState(() {
        _selected = channelId;
        _tab = 0;
      });
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(channelId: channelId)));
    }
  }

  Future<void> _newChat() async {
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const NewChatPage()));
    if (id != null) _open(id);
  }

  void _searchMessages() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchPage(terms: _query, onOpen: _open)));
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Đăng xuất?'),
        content: const Text('Tin nhắn lưu trên máy này sẽ bị xóa. Bạn có thể đăng nhập lại bằng Google bất cứ lúc nào.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Hủy')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Đăng xuất')),
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
          child: Text('Chat',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
        ),
        GlassCircle(
          icon: Icons.add,
          color: pal.accent,
          iconColor: Colors.black,
          tooltip: 'Đoạn chat mới',
          onTap: _newChat,
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
            hintText: 'Tìm kiếm',
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
      return Scaffold(
        backgroundColor: pal.bg,
        body: SafeArea(
          child: Row(children: [
            SizedBox(
              width: 400,
              child: Column(children: [
                _topBar(),
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
                _DesktopFooter(onLogout: _confirmLogout),
              ]),
            ),
            VerticalDivider(width: 1, color: pal.divider),
            Expanded(
              child: _selected == null || !app.channels.containsKey(_selected)
                  ? const _Welcome()
                  : ChatPage(key: ValueKey(_selected), channelId: _selected!, embedded: true),
            ),
          ]),
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
              bottomPadding: 96 + bottomInset,
            ),
          ),
        ]),
      1 => PeopleView(onOpen: _open, bottomPadding: 96 + bottomInset),
      _ => ProfileView(onLogout: _confirmLogout, onSwitchServer: widget.onSwitchServer, bottomPadding: 96 + bottomInset),
    };

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(children: [
        Positioned.fill(child: body),
        Positioned(
          left: 20,
          right: 20,
          bottom: bottomInset + 10,
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
                textColor: Colors.black,
                label: Text('$unread'),
                child: const Icon(Icons.chat_bubble_outline),
              ),
              'Chat'),
          item(1, const Icon(Icons.people_outline), 'Danh bạ'),
          item(
              2,
              app.me == null
                  ? const Icon(Icons.person_outline)
                  : Avatar(userId: app.me!.id, name: app.me!.displayName, size: 28),
              'Bạn'),
        ]),
      ),
    );
  }
}

class _DesktopFooter extends StatelessWidget {
  final VoidCallback onLogout;
  const _DesktopFooter({required this.onLogout});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final me = context.select<AppState, MmUser?>((a) => a.me);
    if (me == null) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: pal.divider))),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Avatar(userId: me.id, name: me.displayName, size: 36),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(me.displayName, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
            Text(me.email, style: TextStyle(color: pal.sub, fontSize: 12)),
          ]),
        ),
        IconButton(icon: Icon(Icons.logout, color: pal.sub), tooltip: 'Đăng xuất', onPressed: onLogout),
      ]),
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
          Text('Chọn một cuộc trò chuyện bên trái để bắt đầu nhắn tin.', style: TextStyle(fontSize: 15, color: pal.sub)),
          const SizedBox(height: 28),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 14, color: pal.sub),
            const SizedBox(width: 6),
            Text('Tin nhắn lưu trên máy chủ riêng của công ty', style: TextStyle(fontSize: 13, color: pal.sub)),
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
      messenger.showSnackBar(const SnackBar(content: Text('Không mở được cuộc trò chuyện. Kiểm tra kết nối mạng.')));
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
            child: Text('Danh bạ',
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
            hintText: 'Tìm theo tên hoặc email',
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
          child: Text('${people.length} người', style: TextStyle(color: pal.sub, fontSize: 13)),
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

/// Trang chọn liên hệ khi bấm nút "+".
class NewChatPage extends StatelessWidget {
  const NewChatPage({super.key});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              GlassCircle(icon: Icons.close, onTap: () => Navigator.pop(context)),
              Expanded(
                child: Text('Đoạn chat mới',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              const SizedBox(width: 44),
            ]),
          ),
          Expanded(child: PeopleView(pickMode: true, onOpen: (id) => Navigator.pop(context, id))),
        ]),
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
        Text('Bạn', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
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
        InfoGroup(children: [
          InfoRow(icon: Icons.mail_outline, title: 'Email', value: me.email),
          InfoRow(icon: Icons.dns_outlined, title: 'Máy chủ', value: Uri.parse(kServerUrl).host),
          InfoRow(
              icon: app.online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              title: 'Kết nối',
              value: app.online ? 'Đang trực tuyến' : 'Ngoại tuyến'),
        ]),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(
            icon: Icons.text_format,
            title: 'Hiển thị định dạng',
            trailing: Switch.adaptive(
              value: app.renderMarkdown,
              activeTrackColor: pal.accent,
              onChanged: app.setRenderMarkdown,
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text('Bật: chữ đậm, danh sách, bảng, khối mã hiển thị đẹp. Tắt: hiện chữ thô như khi gõ.',
              style: TextStyle(fontSize: 13, color: pal.sub)),
        ),
        const SizedBox(height: 16),
        InfoGroup(children: [
          InfoRow(icon: Icons.logout, title: 'Đăng xuất', danger: true, onTap: onLogout),
        ]),
      ]),
    );
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
          if (value != null)
            Flexible(
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

  void _run(String q) {
    if (q.trim().isEmpty) return;
    final app = context.read<AppState>();
    setState(() {
      _res = null;
      _err = null;
    });
    var terms = q.trim();
    final ch = widget.channelId == null ? null : app.channels[widget.channelId];
    if (ch != null && !ch.isDirect && !ch.isGroupDm) terms = '$terms in:${ch.name}';
    app.api.search(app.teamId!, terms).then((r) {
      setState(() => _res = ch == null ? r : r.where((p) => p.channelId == ch.id).toList());
    }).catchError((_) {
      setState(() => _err = 'Không tìm được. Cần có kết nối mạng.');
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
                  style: TextStyle(color: pal.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: pal.surface,
                    hintText: 'Tìm tin nhắn',
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
                        ? Center(child: Text('Không có tin nhắn nào phù hợp', style: TextStyle(color: pal.sub)))
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
