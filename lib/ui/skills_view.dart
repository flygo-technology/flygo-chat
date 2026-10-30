import 'dart:convert';

import '../i18n/i18n.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import '../agent/agent_skills.dart';
import '../config.dart';
import '../state/app_state.dart';
import 'agent_detail_page.dart';
import 'common.dart';
import 'theme.dart';

/// Một kỹ năng của trợ lý. [source]: bot (riêng của bot), base (lớp chung trên máy), engine (của Claude / Codex).
class AgentSkill {
  final String name;
  final String description;
  final String source;

  /// Đường dẫn SKILL.md trên máy này (chỉ khi trợ lý chạy ở đây).
  final String? path;
  AgentSkill(this.name, this.description, this.source, this.path);
  factory AgentSkill.of(Map m) => AgentSkill(
    '${m['name'] ?? ''}',
    '${m['description'] ?? ''}',
    '${m['source'] ?? 'bot'}',
    m['path'] is String ? m['path'] as String : null,
  );
}

/// Lệnh kỹ năng gửi trợ lý chạy ở máy khác qua máy chủ A2A (chỉ chủ trợ lý): máy chủ kiểm tra quyền rồi chuyển cho
/// runner trên máy của trợ lý. [action]: list | read | save | delete.
Future<Map<String, dynamic>> skillCommand(AppState app, String botId, String action, {Map<String, dynamic> body = const {}}) async {
  final r = await http
      .post(Uri.parse('$kPushUrl/a2a/skills'),
          headers: {
            'Authorization': 'Bearer ${app.api.token}',
            'X-MM-Server': kServerUrl,
            'Content-Type': 'application/json',
            'User-Agent': kUserAgent,
          },
          body: jsonEncode({'bot_id': botId, 'action': action, ...body}))
      .timeout(const Duration(seconds: 25));
  final m = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
  if (r.statusCode != 200 || m['ok'] == false) {
    throw Exception(r.statusCode == 503 ? tr('Trợ lý đang tắt máy hoặc mất kết nối.') : (m['error'] ?? 'HTTP ${r.statusCode}'));
  }
  return m;
}

/// Nơi sửa kỹ năng của một trợ lý: tệp trên máy này, hoặc từ xa qua máy chủ (trợ lý đang chạy ở máy khác), hoặc chỉ xem.
enum SkillAccess { local, remote, readOnly }

/// Kỹ năng của một trợ lý của mình. [home]: thư mục của bot trên máy này (sửa thẳng tệp).
class _BotSkills {
  final AgentBot bot;
  final List<AgentSkill> skills;
  final String? home;
  final String role;
  final SkillAccess access;
  _BotSkills(this.bot, this.skills, this.home, this.role, this.access);
  bool get editable => access != SkillAccess.readOnly;
}

/// Tab "Skill" trong "Các trợ lý": kỹ năng của từng trợ lý của mình, mỗi trợ lý một mục mở / thu gọn được
/// (tên, vai trò, số kỹ năng, nơi chạy) + thêm / sửa / xoá trong từng mục.
/// - Trợ lý chạy trên máy tính này: đọc qua CLI runner (`flygo-agent skills --json`), sửa thẳng tệp SKILL.md.
/// - Trợ lý chạy máy khác và đang trực tuyến: đọc / sửa từ xa qua máy chủ (POST /a2a/skills, chỉ chủ trợ lý).
/// - Trợ lý đang tắt: chỉ xem danh sách runner đăng lên máy chủ (props.flygo_skills của tài khoản bot).
class SkillsView extends StatefulWidget {
  final double bottomPadding;
  final void Function(String channelId) onOpen;
  const SkillsView({super.key, required this.onOpen, this.bottomPadding = 0});
  @override
  State<SkillsView> createState() => _SkillsViewState();
}

class _SkillsViewState extends State<SkillsView> {
  static const _prefKey = 'skills_expanded';
  final svc = AgentService.instance;
  List<_BotSkills>? _items;
  String? _error;
  bool _busy = false;

  /// Mục đang mở / thu gọn theo id trợ lý (lưu trên máy). Chưa có thì: một trợ lý -> mở; nhiều -> chỉ mở trợ lý đầu.
  Map<String, bool> _expanded = {};

  @override
  void initState() {
    super.initState();
    context.read<AppState>().uiPref<Map>(_prefKey).then((m) {
      if (!mounted || m == null) return;
      setState(() => _expanded = {for (final e in m.entries) '${e.key}': e.value == true, ..._expanded});
    });
    _load();
  }

  bool _isOpen(_BotSkills b) {
    final v = _expanded[b.bot.id];
    if (v != null) return v;
    final items = _items ?? const <_BotSkills>[];
    return items.length == 1 || (items.isNotEmpty && items.first.bot.id == b.bot.id);
  }

  void _toggle(_BotSkills b) {
    final app = context.read<AppState>();
    setState(() => _expanded[b.bot.id] = !_isOpen(b));
    app.setUiPref(_prefKey, Map<String, bool>.from(_expanded));
  }

  void _open(_BotSkills b) {
    if (_isOpen(b)) return;
    _toggle(b);
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final bots = await svc.myBots(app)
        ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      final out = await Future.wait(bots.map((b) => _loadBot(app, b)));
      if (mounted) setState(() => (_items = out, _error = null));
    } catch (_) {
      if (mounted) setState(() => _error = tr('Không tải được danh sách kỹ năng.'));
    }
  }

  Future<_BotSkills> _loadBot(AppState app, AgentBot b) async {
    List<AgentSkill> parse(dynamic list) => [
      for (final x in (list is List ? list : const []))
        if (x is Map) AgentSkill.of(x),
    ];
    // Trợ lý chạy trên máy này: đọc thẳng qua CLI runner, sửa tệp.
    Map<String, dynamic>? local;
    if (isDesktop && AgentService.isHere(b)) local = await svc.skillsOf(b);
    if (local != null && local['home'] is String) {
      return _BotSkills(b, parse(local['skills']), local['home'] as String, b.role.isNotEmpty ? b.role : '${local['role_line'] ?? ''}', SkillAccess.local);
    }
    // Máy khác, trợ lý đang trực tuyến: hỏi runner qua máy chủ (sửa được từ xa).
    try {
      final r = await skillCommand(app, b.id, 'list');
      return _BotSkills(b, parse(r['skills']), null, b.role.isNotEmpty ? b.role : '${r['role'] ?? ''}', SkillAccess.remote);
    } catch (_) {}
    // Trợ lý đang tắt: bản runner đăng lên tài khoản bot ({v, at, skills:[…]}, có thể là chuỗi JSON hoặc danh sách).
    try {
      await app.refreshUser(b.id);
    } catch (_) {}
    dynamic raw = (app.users[b.id]?.raw['props'] as Map?)?['flygo_skills'];
    if (raw is String && raw.isNotEmpty) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        raw = null;
      }
    }
    return _BotSkills(b, parse(raw is Map ? raw['skills'] : raw), null, b.role, SkillAccess.readOnly);
  }

  Future<void> _edit(_BotSkills b, [AgentSkill? k]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SkillEditPage(
          bot: b.bot,
          home: b.home,
          remote: b.access == SkillAccess.remote,
          skill: k,
          taken: {
            for (final s in b.skills)
              if (s.source == 'bot') s.name,
          },
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _view(_BotSkills b, AgentSkill k) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SkillEditPage(bot: b.bot, home: b.home, remote: b.access == SkillAccess.remote && k.source != 'engine', skill: k, readOnly: true),
    ),
  );

  Future<void> _delete(_BotSkills b, AgentSkill k) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Xoá kỹ năng "{0}"?', [k.name])),
        content: Text(tr('Trợ lý không dùng kỹ năng này nữa từ lượt sau. Không khôi phục được.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr('Xoá'), style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      if (b.access == SkillAccess.remote) {
        await skillCommand(app, b.bot.id, 'delete', body: {'name': k.name});
      } else {
        await deleteSkillFile(b.home!, k.name);
      }
      await _load();
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không xoá được kỹ năng.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chatWith(AgentBot b) async {
    final app = context.read<AppState>();
    try {
      widget.onOpen(await app.openDirect(b.id));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final items = _items;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(bottom: widget.bottomPadding + 90),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(_error!, style: TextStyle(color: pal.sub)),
              ),
            )
          else if (items == null)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 60, 32, 20),
              child: Text(
                tr('Bạn chưa có trợ lý AI nào của riêng mình.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: pal.sub),
              ),
            )
          else
            for (final b in items) ..._bot(pal, b),
        ],
      ),
    );
  }

  /// Nhãn nơi chạy của trợ lý ở đầu mục.
  Widget _badge(Pal pal, _BotSkills b) {
    final (text, icon, color) = switch (b.access) {
      SkillAccess.local => (tr('Trên máy này'), Icons.computer_rounded, pal.accentText),
      SkillAccess.remote => (tr('Từ xa'), Icons.cloud_done_outlined, pal.accentText),
      SkillAccess.readOnly => (tr('Ngoại tuyến'), Icons.cloud_off_outlined, pal.sub),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  List<Widget> _bot(Pal pal, _BotSkills b) {
    final own = b.skills.where((k) => k.source == 'bot').toList();
    final other = b.skills.where((k) => k.source != 'bot').toList();
    final open = _isOpen(b);
    Widget tile(AgentSkill k) {
      // Kỹ năng chung (base) sửa được: lưu thành bản riêng của bot. Chỉ xoá được kỹ năng riêng.
      final canEdit = b.editable && k.source != 'engine';
      final canDelete = b.editable && k.source == 'bot';
      return ListTile(
        contentPadding: const EdgeInsets.fromLTRB(28, 0, 8, 0),
        leading: Icon(switch (k.source) {
          'base' => Icons.folder_shared_outlined,
          'bot' => Icons.bolt_outlined,
          _ => Icons.extension_outlined,
        }, color: pal.accentText),
        title: Text(
          k.name,
          style: TextStyle(color: pal.text, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            if (k.source == 'base') tr('Kỹ năng chung trên máy'),
            if (k.source == 'engine') tr('Kỹ năng sẵn có của AI'),
            if (k.description.isNotEmpty) k.description,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: pal.sub, fontSize: 13),
        ),
        onTap: () => canEdit ? _edit(b, k) : _view(b, k),
        trailing: canDelete
            ? PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: pal.sub),
                onSelected: (v) => v == 'edit' ? _edit(b, k) : _delete(b, k),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(tr('Sửa'))),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(tr('Xoá'), style: const TextStyle(color: Colors.redAccent)),
                  ),
                ],
              )
            : null,
      );
    }

    return [
      // Đầu mục: bấm để mở / thu gọn; ảnh trợ lý mở trang chi tiết (vai trò, mô hình…); ＋ thêm kỹ năng khi sửa được.
      InkWell(
        onTap: () => _toggle(b),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AgentDetailPage(bot: b.bot))).then((_) => _load()),
                child: Avatar(userId: b.bot.id, name: b.bot.displayName, size: 36, icon: Icons.smart_toy_outlined, status: false),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: nameText(
                            b.bot.displayName,
                            bot: true,
                            engine: b.bot.engine,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pal.text),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _badge(pal, b),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [b.role.isNotEmpty ? b.role : tr('Chưa đặt vai trò'), tr('{0} kỹ năng', [b.skills.length])].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: b.role.isNotEmpty ? pal.accentText : pal.sub),
                    ),
                  ],
                ),
              ),
              if (b.editable)
                IconButton(
                  tooltip: tr('Thêm kỹ năng'),
                  icon: Icon(Icons.add_rounded, color: pal.text),
                  onPressed: _busy
                      ? null
                      : () {
                          _open(b);
                          _edit(b);
                        },
                ),
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: pal.sub),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
      if (open) ...[
        for (final k in own) tile(k),
        for (final k in other) tile(k),
        if (b.skills.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 2, 16, 8),
            child: Text(
              b.editable || b.bot.host != null ? tr('Chưa có kỹ năng nào.') : tr('Trợ lý chưa chạy trên máy nào.'),
              style: TextStyle(color: pal.sub, fontSize: 13.5),
            ),
          ),
        // Trợ lý đang tắt: chỉ xem; bật trợ lý (hoặc mở app trên máy đó) để sửa, hoặc nhờ chính trợ lý (chat riêng).
        if (!b.editable)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 2, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Trợ lý đang tắt hoặc mất kết nối: chỉ xem được danh sách. Bật trợ lý trên máy {0} để thêm / sửa kỹ năng từ đây.', [b.bot.host ?? '?']),
                    style: TextStyle(fontSize: 12.5, color: pal.sub),
                  ),
                ),
                TextButton(onPressed: () => _chatWith(b.bot), child: Text(tr('Chat riêng'))),
              ],
            ),
          ),
        const SizedBox(height: 4),
      ],
      Divider(height: 1, indent: 16, color: pal.divider),
    ];
  }
}

/// Thêm / sửa / xem một kỹ năng: tên, mô tả (trợ lý dựa vào mô tả để biết khi nào dùng), nội dung markdown.
class SkillEditPage extends StatefulWidget {
  final AgentBot bot;

  /// Thư mục của bot trên máy này (null: trợ lý chạy máy khác).
  final String? home;

  /// Trợ lý chạy máy khác đang trực tuyến: đọc / lưu nội dung qua máy chủ ([skillCommand]).
  final bool remote;
  final AgentSkill? skill;
  final bool readOnly;

  /// Tên các kỹ năng riêng đã có (không cho trùng khi thêm / đổi tên).
  final Set<String> taken;
  const SkillEditPage({super.key, required this.bot, required this.home, this.remote = false, this.skill, this.readOnly = false, this.taken = const {}});
  @override
  State<SkillEditPage> createState() => _SkillEditPageState();
}

class _SkillEditPageState extends State<SkillEditPage> {
  late final _name = TextEditingController(text: widget.skill?.name ?? '');
  late final _desc = TextEditingController(text: widget.skill?.description ?? '');
  final _body = TextEditingController();
  bool _loading = false, _busy = false, _loadFailed = false;
  String _orig = '';

  /// Xem được nội dung: tệp trên máy này hoặc đọc từ xa.
  bool get _hasBody => widget.home != null || widget.remote;

  @override
  void initState() {
    super.initState();
    final k = widget.skill;
    final p = k?.path;
    if (p != null) {
      _loading = true;
      readSkillFile(p).then((d) => _fill(d == null ? null : (d.description, d.body)));
    } else if (widget.remote && k != null && k.source != 'engine') {
      _loading = true;
      skillCommand(context.read<AppState>(), widget.bot.id, 'read', body: {'name': k.name})
          .then((r) => _fill(('${r['description'] ?? ''}', '${r['body'] ?? ''}')))
          .catchError((_) => _fill(null));
    } else {
      _orig = _state;
    }
  }

  void _fill((String, String)? d) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadFailed = d == null && widget.remote;
      if (d != null) {
        _desc.text = d.$1;
        _body.text = d.$2;
      }
      _orig = _state;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _body.dispose();
    super.dispose();
  }

  String get _state => '${_name.text}\u0000${_desc.text}\u0000${_body.text}';

  String? get _nameError {
    final raw = _name.text.trim();
    if (raw.isEmpty) return null;
    final s = skillSlug(raw);
    if (s.isEmpty) return tr('Tên chỉ gồm chữ, số và dấu gạch ngang.');
    if (s != widget.skill?.name && widget.taken.contains(s)) return tr('Đã có kỹ năng tên này.');
    return null;
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      // Sửa kỹ năng chung (lớp base) = tạo bản riêng của bot cùng tên (bản riêng thắng).
      final oldName = widget.skill?.source == 'bot' ? widget.skill?.name : null;
      if (widget.home != null) {
        await saveSkillFile(widget.home!, _name.text.trim(), _desc.text, _body.text, oldName: oldName);
      } else {
        final name = skillSlug(_name.text.trim());
        if (name.isEmpty) throw const FormatException('invalid skill name');
        await skillCommand(app, widget.bot.id, 'save',
            body: {'name': name, 'old_name': ?oldName, 'description': _desc.text.trim(), 'content': _body.text});
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không lưu được kỹ năng.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final ro = widget.readOnly || !_hasBody || _loadFailed;
    final canSave = !ro && !_busy && !_loading && _name.text.trim().isNotEmpty && _nameError == null && _desc.text.trim().isNotEmpty;
    final slug = skillSlug(_name.text.trim());
    InputDecoration deco(String label, {String? hint, String? helper, String? error}) => InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 3,
      errorText: error,
      filled: true,
      fillColor: pal.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    );
    return EscToPop(
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(
            ro ? tr('Kỹ năng') : (widget.skill == null ? tr('Thêm kỹ năng') : tr('Sửa kỹ năng')),
            style: TextStyle(color: pal.text, fontWeight: FontWeight.w600),
          ),
          actions: [if (!ro) TextButton(onPressed: canSave && _state != _orig ? _save : null, child: Text(tr('Lưu')))],
          bottom: _busy || _loading
              ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
              : null,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
          children: [
            Row(
              children: [
                Avatar(userId: widget.bot.id, name: widget.bot.displayName, size: 28, icon: Icons.smart_toy_outlined, status: false),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.bot.displayName,
                    style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              readOnly: ro,
              autofocus: widget.skill == null && !ro,
              onChanged: (_) => setState(() {}),
              decoration: deco(
                tr('Tên kỹ năng'),
                hint: tr('VD: xu-ly-hoa-don-vat'),
                helper: !ro && slug.isNotEmpty && slug != _name.text.trim() ? tr('Lưu với tên: {0}', [slug]) : null,
                error: ro ? null : _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              readOnly: ro,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: deco(tr('Mô tả'), helper: ro ? null : tr('Trợ lý dựa vào mô tả để biết khi nào dùng kỹ năng này.')),
            ),
            const SizedBox(height: 12),
            if (_loadFailed)
              Text(tr('Không đọc được nội dung kỹ năng từ trợ lý.'), style: TextStyle(color: pal.sub, fontSize: 13))
            else if ((!_hasBody || widget.skill?.source == 'engine' && widget.skill?.path == null) && widget.skill != null)
              Text(
                tr('Nội dung kỹ năng nằm trên máy chạy trợ lý, chỉ xem được tên và mô tả ở đây.'),
                style: TextStyle(color: pal.sub, fontSize: 13),
              )
            else
              TextField(
                controller: _body,
                readOnly: ro,
                minLines: 12,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontFamily: 'monospace', fontSize: 13.5, color: pal.text, height: 1.4),
                decoration: deco(tr('Nội dung (markdown)'), hint: tr('Các bước, quy tắc, ví dụ… trợ lý làm theo khi dùng kỹ năng.')),
              ),
            if (!ro && widget.skill?.source == 'base')
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  tr('Đây là kỹ năng chung trên máy: lưu sẽ tạo bản riêng của trợ lý này (thay bản chung).'),
                  style: TextStyle(color: pal.sub, fontSize: 12.5),
                ),
              ),
            if (!ro)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  widget.remote ? tr('Lưu thẳng lên máy đang chạy trợ lý. Có hiệu lực từ lượt trả lời sau.') : tr('Có hiệu lực từ lượt trả lời sau của trợ lý.'),
                  style: TextStyle(color: pal.sub, fontSize: 12.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
