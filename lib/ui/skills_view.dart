import 'dart:convert';

import '../i18n/i18n.dart';

import 'package:flutter/material.dart';
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

/// Kỹ năng của một trợ lý của mình. [home] khác null: trợ lý chạy trên máy này, app sửa thẳng tệp kỹ năng.
class _BotSkills {
  final AgentBot bot;
  final List<AgentSkill> skills;
  final String? home;
  final String role;
  _BotSkills(this.bot, this.skills, this.home, this.role);
  bool get editable => home != null;
}

/// Tab "Skill" trong "Các trợ lý": kỹ năng của từng trợ lý của mình (tên, mô tả, vai trò) + thêm / sửa / xoá.
/// - Trợ lý chạy trên máy tính này: đọc qua CLI runner (`flygo-agent skills --json`), sửa thẳng tệp SKILL.md.
/// - Trợ lý chạy máy khác: chỉ xem danh sách runner đăng lên máy chủ (props.flygo_skills của tài khoản bot);
///   muốn sửa thì mở app trên máy đó hoặc chat riêng với trợ lý (công cụ skill_save / skill_delete của runner).
class SkillsView extends StatefulWidget {
  final double bottomPadding;
  final void Function(String channelId) onOpen;
  const SkillsView({super.key, required this.onOpen, this.bottomPadding = 0});
  @override
  State<SkillsView> createState() => _SkillsViewState();
}

class _SkillsViewState extends State<SkillsView> {
  final svc = AgentService.instance;
  List<_BotSkills>? _items;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final bots = await svc.myBots(app)
        ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      final out = <_BotSkills>[];
      for (final b in bots) {
        Map<String, dynamic>? local;
        if (isDesktop && AgentService.isHere(b)) local = await svc.skillsOf(b);
        if (local != null && local['home'] is String) {
          out.add(
            _BotSkills(
              b,
              [
                for (final x in (local['skills'] as List? ?? const []))
                  if (x is Map) AgentSkill.of(x),
              ],
              local['home'] as String,
              b.role.isNotEmpty ? b.role : '${local['role_line'] ?? ''}',
            ),
          );
          continue;
        }
        // Máy khác: bản runner đăng lên tài khoản bot ({v, at, skills:[…]}, có thể là chuỗi JSON hoặc danh sách).
        try {
          await app.refreshUser(b.id);
        } catch (_) {}
        dynamic raw = (app.users[b.id]?.raw['props'] as Map?)?['flygo_skills'];
        if (raw is String && raw.isNotEmpty) raw = jsonDecode(raw);
        final list = raw is Map ? raw['skills'] : raw;
        out.add(
          _BotSkills(
            b,
            [
              for (final x in (list is List ? list : const []))
                if (x is Map) AgentSkill.of(x),
            ],
            null,
            b.role,
          ),
        );
      }
      if (mounted) setState(() => (_items = out, _error = null));
    } catch (_) {
      if (mounted) setState(() => _error = tr('Không tải được danh sách kỹ năng.'));
    }
  }

  Future<void> _edit(_BotSkills b, [AgentSkill? k]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SkillEditPage(
          bot: b.bot,
          home: b.home!,
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
      builder: (_) => SkillEditPage(bot: b.bot, home: b.home, skill: k, readOnly: true),
    ),
  );

  Future<void> _delete(_BotSkills b, AgentSkill k) async {
    final messenger = ScaffoldMessenger.of(context);
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
      await deleteSkillFile(b.home!, k.name);
      await _load();
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không xoá được kỹ năng.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Nút ＋: thêm kỹ năng cho một trợ lý chạy trên máy này (nhiều trợ lý thì chọn).
  Future<void> _add() async {
    final editable = (_items ?? const <_BotSkills>[]).where((b) => b.editable).toList();
    if (editable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        toast(Text(tr('Chỉ thêm kỹ năng được trên máy tính đang chạy trợ lý. Hoặc chat riêng với trợ lý để dạy kỹ năng mới.'))),
      );
      return;
    }
    final b = editable.length == 1
        ? editable.first
        : await showModalBottomSheet<_BotSkills>(
            context: context,
            showDragHandle: true,
            useSafeArea: true,
            backgroundColor: Pal.of(context).surface,
            constraints: const BoxConstraints(maxWidth: 560),
            builder: (ctx) => SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('Chọn trợ lý'),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Pal.of(ctx).text),
                  ),
                  const SizedBox(height: 8),
                  for (final e in editable)
                    ListTile(
                      leading: Avatar(userId: e.bot.id, name: e.bot.displayName, size: 40, icon: Icons.smart_toy_outlined, status: false),
                      title: Text(e.bot.displayName),
                      trailing: EngineIcon(e.bot.engine, size: 18, color: Pal.of(ctx).sub),
                      onTap: () => Navigator.pop(ctx, e),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
    if (b != null && mounted) _edit(b);
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
    return Stack(
      children: [
        RefreshIndicator(
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
        ),
        if (items?.any((b) => b.editable) == true)
          Positioned(
            right: 20,
            bottom: PlusFab.bottomOf(context),
            child: PlusFab(heroTag: 'skills-fab', tooltip: tr('Thêm kỹ năng'), onPressed: _busy ? null : _add),
          ),
      ],
    );
  }

  List<Widget> _bot(Pal pal, _BotSkills b) {
    final own = b.skills.where((k) => k.source == 'bot').toList();
    final other = b.skills.where((k) => k.source != 'bot').toList();
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
      // Đầu mục: trợ lý (bấm để mở trang chi tiết: vai trò, mô hình…), vai trò, nơi chạy; ＋ khi sửa được ở đây.
      InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AgentDetailPage(bot: b.bot))).then((_) => _load()),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 6),
          child: Row(
            children: [
              Avatar(userId: b.bot.id, name: b.bot.displayName, size: 36, icon: Icons.smart_toy_outlined, status: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    nameText(
                      b.bot.displayName,
                      bot: true,
                      engine: b.bot.engine,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pal.text),
                    ),
                    Text(
                      b.role.isNotEmpty ? b.role : tr('Chưa đặt vai trò'),
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
                  onPressed: _busy ? null : () => _edit(b),
                ),
            ],
          ),
        ),
      ),
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
      // Trợ lý chạy máy khác: chỉ xem; sửa trên máy đó hoặc nhờ chính trợ lý (chat riêng).
      if (!b.editable)
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 2, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('Trợ lý chạy trên máy {0}: chỉ xem được ở đây. Muốn thêm / sửa, mở app trên máy đó hoặc chat riêng với trợ lý.', [
                    b.bot.host ?? '?',
                  ]),
                  style: TextStyle(fontSize: 12.5, color: pal.sub),
                ),
              ),
              TextButton(onPressed: () => _chatWith(b.bot), child: Text(tr('Chat riêng'))),
            ],
          ),
        ),
      Divider(height: 1, indent: 16, color: pal.divider),
    ];
  }
}

/// Thêm / sửa / xem một kỹ năng: tên, mô tả (trợ lý dựa vào mô tả để biết khi nào dùng), nội dung markdown.
class SkillEditPage extends StatefulWidget {
  final AgentBot bot;

  /// Thư mục của bot trên máy này (null: trợ lý chạy máy khác, chỉ xem tên + mô tả).
  final String? home;
  final AgentSkill? skill;
  final bool readOnly;

  /// Tên các kỹ năng riêng đã có (không cho trùng khi thêm / đổi tên).
  final Set<String> taken;
  const SkillEditPage({super.key, required this.bot, required this.home, this.skill, this.readOnly = false, this.taken = const {}});
  @override
  State<SkillEditPage> createState() => _SkillEditPageState();
}

class _SkillEditPageState extends State<SkillEditPage> {
  late final _name = TextEditingController(text: widget.skill?.name ?? '');
  late final _desc = TextEditingController(text: widget.skill?.description ?? '');
  final _body = TextEditingController();
  bool _loading = false, _busy = false;
  String _orig = '';

  @override
  void initState() {
    super.initState();
    final p = widget.skill?.path;
    if (p != null) {
      _loading = true;
      readSkillFile(p).then((d) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          if (d != null) {
            _desc.text = d.description;
            _body.text = d.body;
          }
          _orig = _state;
        });
      });
    } else {
      _orig = _state;
    }
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
    setState(() => _busy = true);
    try {
      // Sửa kỹ năng chung (lớp base) = tạo bản riêng của bot cùng tên (bản riêng thắng).
      await saveSkillFile(
        widget.home!,
        _name.text.trim(),
        _desc.text,
        _body.text,
        oldName: widget.skill?.source == 'bot' ? widget.skill?.name : null,
      );
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
    final ro = widget.readOnly || widget.home == null;
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
            if (widget.home == null && widget.skill != null)
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
                child: Text(tr('Có hiệu lực từ lượt trả lời sau của trợ lý.'), style: TextStyle(color: pal.sub, fontSize: 12.5)),
              ),
          ],
        ),
      ),
    );
  }
}
