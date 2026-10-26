import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../theme.dart';
import 'board_page.dart';
import 'boards_common.dart';

/// Trang chính của Boards: các bảng của team (bảng mở + bảng mình là thành viên) theo nhóm như thanh bên của bản web,
/// tìm bảng, tạo bảng (trống hoặc từ mẫu), đổi tên / biểu tượng, nhân bản, chuyển nhóm, xoá; tạo / đổi tên / xoá nhóm.
class BoardsHomePage extends StatefulWidget {
  const BoardsHomePage({super.key});
  @override
  State<BoardsHomePage> createState() => _BoardsHomePageState();
}

class _BoardsHomePageState extends State<BoardsHomePage> {
  late final AppState _app = context.read<AppState>();
  late final BoardsApi _api = BoardsApi(_app.api);
  List<TaskBoard> _boards = [];
  List<BoardCategory> _cats = [];
  bool _loading = false;
  Object? _error;
  String _q = '';
  final _collapsed = <String>{};
  StreamSubscription<BoardsEvent>? _sub;
  Timer? _debounce;

  String get _team => _app.teamId ?? '';
  String get _me => _app.me?.id ?? '';

  @override
  void initState() {
    super.initState();
    _app.boardsSubscribe();
    _load();
    // Người khác tạo / sửa / xoá bảng, đổi nhóm: tải lại (gộp nhiều sự kiện liền nhau).
    _sub = BoardsApi.events.stream.listen((e) {
      if (const {'UPDATE_BOARD', 'UPDATE_CATEGORY', 'UPDATE_BOARD_CATEGORY', 'REORDER_CATEGORIES', 'UPDATE_MEMBER', 'DELETE_MEMBER'}.contains(e.action)) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 600), _load);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_team.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Future.wait([_api.teamBoards(_team), _api.categories(_team)]);
      _boards = r[0] as List<TaskBoard>;
      _cats = r[1] as List<BoardCategory>;
      _collapsed
        ..clear()
        ..addAll([for (final c in _cats) if (c.collapsed) c.id]);
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Nhóm bảng: theo nhóm của mình; bảng chưa thuộc nhóm nào vào nhóm hệ thống "Boards" (như bản web).
  List<(BoardCategory?, List<TaskBoard>)> _groups() {
    final q = normText(_q);
    final byId = {for (final b in _boards) b.id: b};
    final placed = <String>{};
    final out = <(BoardCategory?, List<TaskBoard>)>[];
    for (final c in _cats) {
      final l = [
        for (final id in c.boardIds)
          if (byId[id] != null && !c.hidden.contains(id)) byId[id]!,
      ];
      placed.addAll(c.boardIds);
      out.add((c, l));
    }
    final rest = _boards.where((b) => !placed.contains(b.id)).toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    if (rest.isNotEmpty) {
      final i = out.indexWhere((g) => g.$1?.isSystem == true);
      if (i >= 0) {
        out[i] = (out[i].$1, [...out[i].$2, ...rest]);
      } else {
        out.add((null, rest));
      }
    }
    return [
      for (final (c, l) in out)
        if (q.isEmpty || l.any((b) => normText(b.title).contains(q)))
          (c, q.isEmpty ? l : l.where((b) => normText(b.title).contains(q)).toList())
        else if (q.isEmpty && c != null && !c.isSystem)
          (c, l),
    ];
  }

  Future<void> _run(String what, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) boardsError(context, what, e);
    }
    await _load();
  }

  Future<void> _create() async {
    final made = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => CreateBoardPage(teamId: _team)));
    if (made == null || !mounted) return;
    await _load();
    if (mounted) await openBoard(context, made);
    await _load();
  }

  Future<void> _boardMenu(TaskBoard b, BoardCategory? cat, String v) async {
    switch (v) {
      case 'rename':
        final t = await askText(context, tr('Đổi tên bảng'), b.title);
        if (t != null && t.trim().isNotEmpty) await _run(tr('Không đổi tên được'), () => _api.patchBoard(b.id, title: t.trim()));
      case 'icon':
        final e = await pickBoardsIcon(context);
        if (e != null) await _run(tr('Không lưu được'), () => _api.patchBoard(b.id, icon: e));
      case 'dup':
        await _run(tr('Không nhân bản được'), () => _api.duplicateBoard(b.id));
      case 'move':
        final to = await boardsSheet<String>(
          context,
          (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final c in _cats)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(c.isSystem ? tr('Boards') : c.name),
                  trailing: c.id == cat?.id ? const Icon(Icons.check_rounded) : null,
                  onTap: () => Navigator.pop(ctx, c.id),
                ),
              ListTile(leading: const Icon(Icons.create_new_folder_outlined), title: Text(tr('Nhóm mới...')), onTap: () => Navigator.pop(ctx, '')),
            ]),
          ),
          scroll: false,
        );
        if (to == null || !mounted) return;
        if (to.isEmpty) {
          final name = await askText(context, tr('Tên nhóm mới'), '');
          if (name == null || name.trim().isEmpty) return;
          await _run(tr('Không tạo được nhóm'), () async {
            await _api.createCategory(_team, _me, name.trim());
            final cats = await _api.categories(_team);
            final nc = cats.where((c) => c.name == name.trim() && !c.isSystem).lastOrNull;
            if (nc != null) await _api.moveBoardToCategory(_team, b.id, nc.id, cat?.id ?? '');
          });
        } else if (to != cat?.id) {
          await _run(tr('Không chuyển được'), () => _api.moveBoardToCategory(_team, b.id, to, cat?.id ?? ''));
        }
      case 'del':
        if (!await confirmBoards(context, tr('Xoá bảng?'), tr('Bảng "{0}" cùng mọi thẻ sẽ bị xoá.', [b.title]))) return;
        await _run(tr('Không xoá được'), () => _api.deleteBoard(b.id));
    }
  }

  Future<void> _catMenu(BoardCategory c, String v) async {
    switch (v) {
      case 'rename':
        final t = await askText(context, tr('Đổi tên nhóm'), c.name);
        if (t != null && t.trim().isNotEmpty) await _run(tr('Không đổi tên được'), () => _api.updateCategory(_team, _me, c, name: t.trim()));
      case 'del':
        if (!await confirmBoards(context, tr('Xoá nhóm?'), tr('Các bảng trong nhóm "{0}" chuyển về nhóm Boards; bảng không bị xoá.', [c.name]))) return;
        await _run(tr('Không xoá được'), () => _api.deleteCategory(_team, c.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final groups = _groups();
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Tìm bảng'), isDense: true, border: const OutlineInputBorder()),
        ),
      ),
    ];
    if (_error != null && _boards.isEmpty) {
      children.add(BoardsNotice(icon: Icons.cloud_off_rounded, title: tr('Không tải được danh sách bảng'), body: '$_error'));
    } else if (!_loading && _boards.isEmpty) {
      children.add(BoardsNotice(
        icon: Icons.dashboard_customize_outlined,
        title: tr('Chưa có bảng nào'),
        body: tr('Tạo bảng để quản lý việc của nhóm: Kanban, bảng, lịch...'),
        action: FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add_rounded), label: Text(tr('Tạo bảng'))),
      ));
    }
    for (final (c, list) in groups) {
      final key = c?.id ?? '_';
      final closed = _q.isEmpty && _collapsed.contains(key);
      children.add(InkWell(
        onTap: () {
          setState(() => closed ? _collapsed.remove(key) : _collapsed.add(key));
          if (c != null) _api.updateCategory(_team, _me, c, collapsed: !closed).catchError((_) {});
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            Icon(closed ? Icons.chevron_right_rounded : Icons.expand_more_rounded, size: 20, color: pal.sub),
            const SizedBox(width: 4),
            Expanded(
              child: Text('${(c == null || c.isSystem ? tr('Boards') : c.name).toUpperCase()} · ${list.length}',
                  style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
            ),
            if (c != null && !c.isSystem)
              PopupMenuButton<String>(
                tooltip: tr('Thêm'),
                icon: Icon(Icons.more_horiz_rounded, size: 20, color: pal.sub),
                onSelected: (v) => _catMenu(c, v),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'rename', child: Text(tr('Đổi tên nhóm'))),
                  PopupMenuItem(value: 'del', child: Text(tr('Xoá nhóm'), style: const TextStyle(color: Color(0xFFE53935)))),
                ],
              ),
          ]),
        ),
      ));
      if (closed) continue;
      for (final b in list) {
        children.add(ListTile(
          leading: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(10)),
            child: b.icon.isEmpty ? Icon(Icons.dashboard_outlined, color: pal.sub) : Text(b.icon, style: const TextStyle(fontSize: 22)),
          ),
          title: Row(children: [
            Flexible(child: Text(b.title.isEmpty ? tr('(Không có tên)') : b.title, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text, fontWeight: FontWeight.w500))),
            if (!b.isOpen) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.lock_outline_rounded, size: 15, color: pal.sub)),
          ]),
          subtitle: b.description.isEmpty ? null : Text(b.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub)),
          onTap: () async {
            await openBoard(context, b.id);
            _load();
          },
          trailing: PopupMenuButton<String>(
            tooltip: tr('Thêm'),
            icon: Icon(Icons.more_vert_rounded, color: pal.sub),
            onSelected: (v) => _boardMenu(b, c, v),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(tr('Đổi tên'))),
              PopupMenuItem(value: 'icon', child: Text(tr('Đổi biểu tượng'))),
              PopupMenuItem(value: 'dup', child: Text(tr('Nhân bản'))),
              PopupMenuItem(value: 'move', child: Text(tr('Chuyển nhóm'))),
              PopupMenuItem(value: 'del', child: Text(tr('Xoá bảng'), style: const TextStyle(color: Color(0xFFE53935)))),
            ],
          ),
        ));
      }
    }
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        title: Text(tr('Tất cả bảng')),
        actions: [
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(
            tooltip: tr('Nhóm mới'),
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () async {
              final name = await askText(context, tr('Tên nhóm mới'), '');
              if (name != null && name.trim().isNotEmpty) await _run(tr('Không tạo được nhóm'), () => _api.createCategory(_team, _me, name.trim()));
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-board',
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr('Tạo bảng')),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.only(bottom: 96), children: children),
      ),
    );
  }
}

/// Tạo bảng: bảng trống (tên, biểu tượng, mở cho team hay riêng tư) hoặc từ mẫu có sẵn của plugin / của team.
/// Trả về id bảng mới.
class CreateBoardPage extends StatefulWidget {
  final String teamId;
  const CreateBoardPage({super.key, required this.teamId});
  @override
  State<CreateBoardPage> createState() => _CreateBoardPageState();
}

class _CreateBoardPageState extends State<CreateBoardPage> {
  late final BoardsApi _api = BoardsApi(context.read<AppState>().api);
  final _name = TextEditingController();
  String _icon = '📋';
  bool _open = true;
  bool _busy = false;
  List<TaskBoard>? _templates;

  @override
  void initState() {
    super.initState();
    _api.templates(widget.teamId).then((t) {
      if (mounted) setState(() => _templates = t);
    }).catchError((_) {
      if (mounted) setState(() => _templates = []);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _blank() async {
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      final status = PropTemplate(newBoardsId(), tr('Trạng thái'), 'select', [
        PropOption(newBoardsId(), tr('Chưa làm'), 'propColorGray'),
        PropOption(newBoardsId(), tr('Đang làm'), 'propColorBlue'),
        PropOption(newBoardsId(), tr('Xong'), 'propColorGreen'),
      ]);
      final (b, _) = await _api.createBlankBoard(widget.teamId, _name.text.trim().isEmpty ? tr('Bảng mới') : _name.text.trim(),
          icon: _icon, open: _open, props: [status], viewName: tr('Kanban'));
      nav.pop(b.id);
    } catch (e) {
      if (mounted) {
        boardsError(context, tr('Không tạo được bảng'), e);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _fromTemplate(TaskBoard t) async {
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      final r = await _api.duplicateBoard(t.id, toTeam: widget.teamId);
      final b = r.boards.firstOrNull;
      if (b == null) throw Exception(tr('Máy chủ không trả về bảng mới'));
      final name = _name.text.trim();
      if (name.isNotEmpty) await _api.patchBoard(b.id, title: name);
      if (!_open && b.isOpen) await _api.patchBoard(b.id, type: 'P');
      nav.pop(b.id);
    } catch (e) {
      if (mounted) {
        boardsError(context, tr('Không tạo được bảng'), e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final w = MediaQuery.sizeOf(context).width;
    final cols = (w / 260).floor().clamp(1, 4);
    final tw = (w.clamp(0, 1100) - 32 - (cols - 1) * 10) / cols;
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text(tr('Tạo bảng'))),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Row(children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final e = await pickBoardsIcon(context);
                if (e != null) setState(() => _icon = e);
              },
              child: Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(12)),
                child: Text(_icon, style: const TextStyle(fontSize: 28)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(labelText: tr('Tên bảng'), border: const OutlineInputBorder()),
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Mở cho cả team')),
            subtitle: Text(_open ? tr('Ai trong team cũng thấy và sửa được') : tr('Chỉ người được mời mới thấy')),
            value: _open,
            onChanged: (v) => setState(() => _open = v),
          ),
          const SizedBox(height: 4),
          FilledButton.icon(onPressed: _blank, icon: const Icon(Icons.add_rounded), label: Text(tr('Tạo bảng trống'))),
          const SizedBox(height: 24),
          Text(tr('Hoặc bắt đầu từ mẫu').toUpperCase(), style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
          const SizedBox(height: 10),
          if (_templates == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_templates!.isEmpty)
            Text(tr('Máy chủ không có mẫu nào'), style: TextStyle(color: pal.sub))
          else
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final t in _templates!)
                SizedBox(
                  width: tw,
                  child: Material(
                    color: pal.surface,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _fromTemplate(t),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(t.icon.isEmpty ? '📋' : t.icon, style: const TextStyle(fontSize: 22)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(t.title, style: TextStyle(fontWeight: FontWeight.w600, color: pal.text), overflow: TextOverflow.ellipsis)),
                          ]),
                          if (t.description.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(t.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: pal.sub)),
                          ],
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
        ]),
      ),
    );
  }
}
