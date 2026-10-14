import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/mm_api.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Quản lý bot cá nhân: tạo, sửa, sao chép token. Không có xóa — phải nhờ quản trị viên.
class BotsPage extends StatefulWidget {
  const BotsPage({super.key});
  @override
  State<BotsPage> createState() => _BotsPageState();
}

class _BotsPageState extends State<BotsPage> {
  List<Map<String, dynamic>>? _bots;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().myBots();
      if (mounted) setState(() => _bots = b);
    } catch (e) {
      if (mounted) setState(() => _error = tr('Không tải được danh sách bot.'));
    }
  }

  Future<void> _edit([Map<String, dynamic>? bot]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => BotEditPage(bot: bot)));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final bots = _bots;
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Quản lý bot'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          actions: [IconButton(tooltip: tr('Tạo bot'), icon: Icon(Icons.add, color: pal.accentText), onPressed: () => _edit())],
        ),
        body: _error != null
            ? Center(child: Text(_error!, style: TextStyle(color: pal.sub)))
            : bots == null
                ? Center(child: CircularProgressIndicator(color: pal.accent))
                : ListView(padding: const EdgeInsets.all(16), children: [
                    Text(
                      tr('Bot dùng token để AI agent hoặc phần mềm gửi và đọc tin thay bạn. Muốn xóa bot, hãy nhờ quản trị viên.'),
                      style: TextStyle(color: pal.sub, fontSize: 13.5),
                    ),
                    const SizedBox(height: 14),
                    if (bots.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Center(child: Text(tr('Bạn chưa có bot nào.'), style: TextStyle(color: pal.sub))),
                      ),
                    for (final b in bots) _BotCard(bot: b, onEdit: () => _edit(b)),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: pal.accentText,
                        side: BorderSide(color: pal.accentText),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add),
                      label: Text(tr('Tạo bot mới')),
                    ),
                  ]),
      ),
    );
  }
}

class _BotCard extends StatelessWidget {
  final Map<String, dynamic> bot;
  final VoidCallback onEdit;
  const _BotCard({required this.bot, required this.onEdit});

  Future<void> _copyToken(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final id = bot['user_id'] as String;
    var token = await app.botToken(id);
    if (token == null) {
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr('Tạo token mới?')),
          content: Text(tr('Máy chủ chỉ hiện token một lần lúc tạo, máy này chưa lưu token của bot. Tạo token mới (token cũ vẫn dùng được)?')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
            TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Tạo token'))),
          ],
        ),
      );
      if (ok != true) return;
      try {
        token = await app.newBotToken(id);
      } catch (_) {
        messenger.showSnackBar(SnackBar(content: Text(tr('Không tạo được token.'))));
        return;
      }
    }
    await Clipboard.setData(ClipboardData(text: token));
    messenger.showSnackBar(SnackBar(content: Text(tr('Đã sao chép token của bot'))));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final name = (bot['display_name'] as String? ?? '').isEmpty ? bot['username'] as String : bot['display_name'] as String;
    final desc = bot['description'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          EditableAvatar(
            size: 44,
            avatar: Avatar(userId: bot['user_id'] as String, name: name, size: 44, icon: Icons.smart_toy_outlined),
            onPicked: (n, b) => context.read<AppState>().setUserImage(bot['user_id'] as String, n, b),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
              Text('@${bot['username']}', style: TextStyle(color: pal.sub, fontSize: 13.5)),
            ]),
          ),
          IconButton(tooltip: tr('Sửa'), icon: Icon(Icons.edit_outlined, color: pal.text), onPressed: onEdit),
        ]),
        if (desc.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(desc, style: TextStyle(color: pal.sub))),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: pal.accentText),
            onPressed: () => _copyToken(context),
            icon: const Icon(Icons.key_outlined, size: 18),
            label: Text(tr('Sao chép token')),
          ),
        ),
      ]),
    );
  }
}

/// Tạo bot mới ([bot] null) hoặc sửa bot.
class BotEditPage extends StatefulWidget {
  final Map<String, dynamic>? bot;
  const BotEditPage({super.key, this.bot});
  @override
  State<BotEditPage> createState() => _BotEditPageState();
}

class _BotEditPageState extends State<BotEditPage> {
  late final _name = TextEditingController(text: widget.bot?['display_name'] as String? ?? '');
  late final _user = TextEditingController(text: widget.bot?['username'] as String? ?? '');
  late final _desc = TextEditingController(text: widget.bot?['description'] as String? ?? '');
  bool _userTouched = false;
  bool _busy = false;
  String? _error;

  static final _validUser = RegExp(r'^[a-z][a-z0-9._-]{2,21}$');

  /// Gợi ý tên đăng nhập từ tên bot: bỏ dấu, chữ thường.
  static String _slug(String s) {
    const from = r'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
    const to = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().characters) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    var r = b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (r.isEmpty) return '';
    if (!RegExp(r'^[a-z]').hasMatch(r)) r = 'bot-$r';
    return r.length > 22 ? r.substring(0, 22) : r;
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final user = _user.text.trim().toLowerCase();
    if (_name.text.trim().isEmpty) {
      setState(() => _error = tr('Hãy đặt tên cho bot.'));
      return;
    }
    if (!_validUser.hasMatch(user)) {
      setState(() => _error = tr('Tên đăng nhập 3–22 ký tự, bắt đầu bằng chữ, chỉ gồm a-z, 0-9, dấu . _ -'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.bot == null) {
        final id = await app.createBot(user, _name.text.trim(), _desc.text.trim());
        final token = await app.botToken(id);
        if (token != null && mounted) await _showToken(token);
      } else {
        await app.updateBot(widget.bot!['user_id'] as String, user, _name.text.trim(), _desc.text.trim());
      }
      nav.pop(true);
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.status == 403
            ? tr('Tài khoản chưa được phép tạo bot. Hãy nhờ quản trị viên.')
            : e.message.contains('username') || e.status == 400
                ? tr('Tên đăng nhập đã có người dùng hoặc không hợp lệ.')
                : e.message;
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _error = tr('Không lưu được. Kiểm tra kết nối mạng.');
      });
    }
  }

  Future<void> _showToken(String token) => showDialog(
        context: context,
        builder: (d) {
          final pal = Pal.of(d);
          return AlertDialog(
            title: Text(tr('Token của bot')),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Dán token này vào AI agent hoặc phần mềm cần gửi tin bằng bot. Giữ bí mật như mật khẩu.'),
                  style: TextStyle(color: pal.sub, fontSize: 13.5)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(10)),
                child: SelectableText(token, style: TextStyle(fontFamily: 'monospace', color: pal.text)),
              ),
            ]),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: token));
                  Navigator.pop(d);
                },
                child: Text(tr('Sao chép và đóng')),
              ),
            ],
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    InputDecoration deco(String label, {String? hint, String? prefix}) => InputDecoration(
          labelText: label,
          hintText: hint,
          prefixText: prefix,
          filled: true,
          fillColor: pal.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        );
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(widget.bot == null ? tr('Tạo bot cá nhân') : tr('Sửa bot'),
              style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _name,
            autofocus: widget.bot == null,
            decoration: deco(tr('Tên bot'), hint: tr('Ví dụ: Trợ lý kế toán')),
            onChanged: (v) {
              if (widget.bot == null && !_userTouched) _user.text = _slug(v);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            decoration: deco(tr('Tên đăng nhập'), prefix: '@'),
            onChanged: (_) => _userTouched = true,
          ),
          const SizedBox(height: 12),
          TextField(controller: _desc, minLines: 2, maxLines: 4, decoration: deco(tr('Mô tả (không bắt buộc)'))),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          const SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
              onPressed: _busy ? null : _save,
              child: Text(widget.bot == null ? tr('Tạo bot') : tr('Lưu'), style: const TextStyle(fontSize: 16)),
            ),
          ),
        ]),
      ),
    );
  }
}
