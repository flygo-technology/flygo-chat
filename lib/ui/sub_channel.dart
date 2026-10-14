import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'home_page.dart' show ChatHost;
import 'chat_page.dart' show ChatPage;
import 'theme.dart';

/// "Tiếp tục trong luồng riêng": mở luồng riêng đã có của tin, hoặc tạo mới.
Future<void> continueInSubChannel(BuildContext context, MmChannel parent, MmPost root) async {
  final app = context.read<AppState>();
  final existing = app.subChannelForPost(root.id);
  final id = existing?.id ??
      await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => CreateSubPage(parent: parent, root: root)));
  if (id == null || !context.mounted) return;
  openChannelAnywhere(context, id);
}

/// Mở một cuộc trò chuyện: máy tính mở ở cột giữa, điện thoại mở trang mới.
void openChannelAnywhere(BuildContext context, String channelId) {
  final host = ChatHost.of(context);
  if (host != null) return host.openChat(channelId);
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatPage(channelId: channelId)));
}

/// Tạo luồng riêng từ một tin: chọn thành viên trong nhóm (và trợ lý AI), đặt tên.
class CreateSubPage extends StatefulWidget {
  final MmChannel parent;
  final MmPost root;
  const CreateSubPage({super.key, required this.parent, required this.root});
  @override
  State<CreateSubPage> createState() => _CreateSubPageState();
}

class _CreateSubPageState extends State<CreateSubPage> {
  late final _name = TextEditingController(text: _defaultName());
  final Set<String> _picked = {};
  List<MmUser>? _members;
  bool _busy = false;

  String _defaultName() {
    final t = plainPreview(widget.root.message).replaceAll('\n', ' ').trim();
    if (t.isEmpty) return tr('Luồng riêng');
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.channelUsers(widget.parent.id).then((l) {
      if (!mounted) return;
      setState(() {
        _members = l.where((u) => u.id != app.me?.id).toList()
          ..sort((a, b) => (a.isBot ? 1 : 0).compareTo(b.isBot ? 1 : 0));
        // Người viết tin gốc mặc định được chọn.
        if (widget.root.userId != app.me?.id) _picked.add(widget.root.userId);
      });
    });
  }

  Future<void> _create() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    try {
      nav.pop(await app.createSubChannel(widget.parent, widget.root, name, _picked.toList()));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(tr('Không tạo được luồng riêng. Kiểm tra kết nối mạng.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final members = _members;
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Luồng riêng mới'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: tr('Tên luồng riêng'),
                prefixIcon: Icon(Icons.lock_outline, color: pal.sub),
                filled: true,
                fillColor: pal.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              tr('Chỉ những người được chọn (và trợ lý AI nếu chọn) mới xem được. Tin gốc sẽ được chép vào luồng.'),
              style: TextStyle(fontSize: 13, color: pal.sub),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: members == null
                ? Center(child: CircularProgressIndicator(color: pal.accent))
                : ListView(children: [
                    for (final u in members)
                      CheckboxListTile(
                        value: _picked.contains(u.id),
                        activeColor: pal.accent,
                        checkColor: Colors.white,
                        checkboxShape: const CircleBorder(),
                        onChanged: (v) => setState(() => v == true ? _picked.add(u.id) : _picked.remove(u.id)),
                        secondary: Avatar(userId: u.id, name: u.displayName, size: 40, icon: u.isBot ? Icons.smart_toy_outlined : null),
                        title: nameText(u.displayName, bot: u.isBot, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                        subtitle: Text('@${u.username}', style: TextStyle(color: pal.sub)),
                      ),
                  ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.lock_outline),
                  label: Text(tr('Tạo luồng riêng ({0} người)', [_picked.length + 1])),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Gửi kết luận từ luồng riêng về nhóm gốc.
Future<void> sendConclusionDialog(BuildContext context, MmChannel sub) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final ctl = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Gửi kết luận về nhóm')),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(hintText: tr('Tóm tắt kết quả để cả nhóm thấy...')),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
        TextButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: Text(tr('Gửi'))),
      ],
    ),
  );
  if (text == null || text.isEmpty) return;
  try {
    await app.sendConclusion(sub, text);
    messenger.showSnackBar(SnackBar(content: Text(tr('Đã gửi kết luận về nhóm.'))));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Không gửi được kết luận.'))));
  }
}

/// Dòng "🔒 Luồng riêng: tên" dưới tin gốc (chỉ người trong luồng riêng mới thấy).
class SubChannelChip extends StatelessWidget {
  final MmChannel sub;
  const SubChannelChip({super.key, required this.sub});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final unread = context.read<AppState>().unreadOf(sub.id);
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
      child: Material(
        color: const Color(0xFF7C5CC4).withValues(alpha: .14),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => openChannelAnywhere(context, sub.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 15, color: Color(0xFF7C5CC4)),
              const SizedBox(width: 5),
              Flexible(
                child: Text(tr('Luồng riêng: {0}', [sub.displayName]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF7C5CC4), fontWeight: FontWeight.w600)),
              ),
              if (unread > 0)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(10)),
                  child: Text('$unread', style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              Icon(Icons.chevron_right, size: 16, color: pal.sub),
            ]),
          ),
        ),
      ),
    );
  }
}
