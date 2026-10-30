import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/boards_api.dart';
import '../api/mm_api.dart';
import '../config.dart';
import '../i18n/i18n.dart';
import '../state/app_state.dart';
import 'attach_panel.dart' show TasksPage;
import 'boards/boards_common.dart';
import 'boards/board_page.dart' show openBoard;
import 'boards/boards_home.dart';
import 'boards/card_detail.dart' show openBoardCard;
import 'common.dart';
import 'theme.dart';

// ---------------------------------------------------------------- dữ liệu tab Việc

/// Một việc của tôi: thẻ + bảng chứa nó.
class MyTask {
  final TaskBoard board;
  TaskCard card;
  MyTask(this.board, this.card);

  PropOption? get status {
    final p = board.status;
    final v = p == null ? null : card.str(p.id);
    return p?.options.where((o) => o.id == v).firstOrNull;
  }

  PropOption? get priority {
    final p = board.priority;
    final v = p == null ? null : card.str(p.id);
    return p?.options.where((o) => o.id == v).firstOrNull;
  }

  DateTime? get due => card.date(board.due?.id);
  bool get done => isDoneStatus(status?.value ?? '');
  bool get overdue {
    final d = due;
    if (d == null || done) return false;
    final now = DateTime.now();
    return d.isBefore(DateTime(now.year, now.month, now.day));
  }

  List<String> get assignees {
    final p = board.assignee;
    return p == null ? board.people(card).toList() : card.list(p.id);
  }
}

/// Bộ nhớ tạm của tab Việc theo máy chủ (mở lại tab là thấy ngay, rồi tải mới).
class _TasksCache {
  bool? available;
  List<TaskBoard> boards = [];
  List<MyTask> mine = [];
}

final _caches = <String, _TasksCache>{};

/// Số việc của tôi đã quá hạn (chấm đỏ trên tab Việc).
final tasksOverdue = ValueNotifier<int>(0);

// ---------------------------------------------------------------- tab Việc

/// Tab "Việc": việc được giao cho tôi trên các bảng Boards của team (nhóm theo trạng thái), tạo việc nhanh, vào danh sách bảng.
class TasksView extends StatefulWidget {
  final Widget header;
  final double bottomPadding;
  /// Khoảng cách từ đáy tới nút tạo việc (ngay trên thanh tab).
  final double fabBottom;
  const TasksView({super.key, required this.header, required this.bottomPadding, required this.fabBottom});
  @override
  State<TasksView> createState() => _TasksViewState();
}

class _TasksViewState extends State<TasksView> {
  late final AppState _app = context.read<AppState>();
  late final BoardsApi _boards = BoardsApi(_app.api);
  _TasksCache get _c => _caches[serverKey] ??= _TasksCache();
  bool _loading = false;
  String? _error;
  /// Nhóm đang mở / đóng (khóa = tên trạng thái); nhóm "xong" mặc định đóng.
  final Map<String, bool> _open = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    if (_app.todos.values.every((l) => l.isEmpty)) _app.loadTodos();
  }

  Future<void> _refresh() async {
    final teamId = _app.teamId, me = _app.me?.id;
    if (teamId == null || me == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await _boards.available();
      _c.available = ok;
      if (ok) {
        final boards = await _boards.teamBoards(teamId);
        final mine = <MyTask>[];
        // Tải thẻ từng bảng song song (tối đa 6 bảng một lúc); bảng lỗi quyền thì bỏ qua.
        for (var i = 0; i < boards.length; i += 6) {
          await Future.wait(boards.skip(i).take(6).map((b) async {
            try {
              for (final c in await _boards.cards(b.id)) {
                if (b.people(c).contains(me)) mine.add(MyTask(b, c));
              }
            } on ApiException catch (_) {}
          }));
        }
        _c.boards = boards;
        _c.mine = mine;
        tasksOverdue.value = mine.where((t) => t.overdue).length;
      } else {
        tasksOverdue.value = 0;
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Nhóm theo trạng thái: theo thứ tự phương án trong bảng, chưa có trạng thái ở đầu, "xong" ở cuối.
  List<(String, Color?, bool, List<MyTask>)> _groups() {
    final pal = Pal.of(context);
    final by = <String, (String, Color?, bool, int, List<MyTask>)>{};
    for (final t in _c.mine) {
      final s = t.status;
      final key = s == null ? '' : normText(s.value);
      final idx = s == null ? -1 : t.board.status!.options.indexOf(s);
      final g = by[key];
      if (g == null) {
        by[key] = (s?.value ?? tr('Chưa có trạng thái'), s == null ? null : boardsColor(s.color, pal.sub), t.done, idx, [t]);
      } else {
        g.$5.add(t);
        if (idx < g.$4) by[key] = (g.$1, g.$2, g.$3, idx, g.$5);
      }
    }
    final list = by.values.toList()
      ..sort((a, b) => a.$3 != b.$3 ? (a.$3 ? 1 : -1) : a.$4.compareTo(b.$4));
    for (final g in list) {
      // Quá hạn trước, rồi theo hạn gần nhất; không có hạn xếp sau.
      g.$5.sort((a, b) {
        final da = a.due, db = b.due;
        if (da == null || db == null) return da == null ? (db == null ? b.card.updateAt.compareTo(a.card.updateAt) : 1) : -1;
        return da.compareTo(db);
      });
    }
    return [for (final g in list) (g.$1, g.$2, g.$3, g.$5)];
  }

  Future<void> _create() async {
    final teamId = _app.teamId;
    if (teamId == null) return;
    final made = await Navigator.of(context).push<MyTask>(MaterialPageRoute(builder: (_) => CreateBoardTaskPage(boards: _c.boards)));
    if (made == null || !mounted) return;
    setState(() {
      if (!_c.boards.any((b) => b.id == made.board.id)) _c.boards = [..._c.boards, made.board];
      if (made.assignees.contains(_app.me?.id)) _c.mine = [..._c.mine, made];
    });
    ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã tạo việc "{0}"', [made.card.title])), icon: Icons.task_alt_rounded));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final c = _c;
    final todoCount = (app.todos['my']?.length ?? 0) + (app.todos['in']?.length ?? 0);
    final children = <Widget>[
      widget.header,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(children: [
          // Tiêu đề là menu chọn bảng: Toàn bộ bảng (việc của tôi), từng bảng, tạo bảng mới.
          Flexible(
            child: c.available == false
                ? Text(tr('Việc của tôi'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: pal.text))
                : PopupMenuButton<String>(
                    tooltip: tr('Chọn bảng'),
                    position: PopupMenuPosition.under,
                    onSelected: _pickBoard,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: '',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.task_alt_rounded),
                          title: Text(tr('Toàn bộ bảng')),
                          subtitle: Text(tr('Toàn bộ việc của tôi')),
                        ),
                      ),
                      if (c.boards.isNotEmpty) const PopupMenuDivider(),
                      for (final b in [...c.boards]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())))
                        PopupMenuItem(
                          value: b.id,
                          child: Row(children: [
                            SizedBox(width: 28, child: Text(b.icon.isEmpty ? '📋' : b.icon, style: const TextStyle(fontSize: 18))),
                            const SizedBox(width: 8),
                            Expanded(child: Text(b.title.isEmpty ? tr('Bảng chưa đặt tên') : b.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ]),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: '+',
                        child: Row(children: [
                          Icon(Icons.add_rounded, color: pal.accentText),
                          const SizedBox(width: 12),
                          Text(tr('Tạo bảng mới'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ],
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                        child: Text(tr('Toàn bộ bảng'),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: pal.text)),
                      ),
                      Icon(Icons.arrow_drop_down_rounded, color: pal.text, size: 28),
                    ]),
                  ),
          ),
          const Spacer(),
          if (_loading) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
        ]),
      ),
    ];
    if (c.available == false) {
      children.add(_notice(pal, Icons.extension_off_outlined, tr('Máy chủ chưa bật Boards'),
          tr('Quản trị viên cần cài và bật plugin Boards để dùng bảng việc. Việc nhanh (Todo) vẫn dùng được bên dưới.')));
    } else if (_error != null && c.mine.isEmpty) {
      children.add(_notice(pal, Icons.cloud_off_rounded, tr('Không tải được việc'), _error!));
    } else if (c.available == true && c.mine.isEmpty && !_loading) {
      children.add(_notice(pal, Icons.task_alt_rounded, tr('Chưa có việc nào giao cho bạn'),
          tr('Bấm + để tạo việc, hoặc nhờ trợ lý AI giao việc trong nhóm chat.')));
    }
    for (final (name, color, done, tasks) in _groups()) {
      final key = name;
      final open = _open[key] ?? !done;
      children.add(InkWell(
        onTap: () => setState(() => _open[key] = !open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color ?? pal.sub, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${name.toUpperCase()} · ${tasks.length}',
                  style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
            ),
            Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: pal.sub, size: 20),
          ]),
        ),
      ));
      if (open) {
        for (final t in tasks) {
          children.add(_TaskTile(task: t, onTap: () => _openTask(t)));
        }
      }
    }
    // Việc nhanh của plugin Todo (giữ nguyên trang Công việc cũ).
    if (app.todoAvailable && todoCount > 0) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(tr('Việc nhanh (Todo)').toUpperCase(),
            style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
      ));
      children.add(ListTile(
        leading: Icon(Icons.checklist_rounded, color: pal.accentText),
        title: Text(tr('{0} việc đang chờ', [todoCount]), style: TextStyle(color: pal.text)),
        trailing: Icon(Icons.chevron_right_rounded, color: pal.sub),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TasksPage())),
      ));
    }
    return Stack(children: [
      Positioned.fill(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(bottom: widget.bottomPadding + 72),
            children: children,
          ),
        ),
      ),
      if (c.available != false)
        Positioned(
          right: 20,
          bottom: widget.fabBottom,
          child: PlusFab(heroTag: 'new-board-task', tooltip: tr('Tạo việc'), onPressed: _create),
        ),
    ]);
  }

  Widget _notice(Pal pal, IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 12),
        child: Column(children: [
          Icon(icon, size: 48, color: pal.sub),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
        ]),
      );

  /// Chọn trong menu tiêu đề: '' = toàn bộ việc của tôi (màn này), '+' = tạo bảng mới, còn lại = mở bảng đó.
  Future<void> _pickBoard(String v) async {
    if (v.isEmpty) return;
    var id = v;
    if (v == '+') {
      final teamId = _app.teamId;
      if (teamId == null) return;
      final made = await Navigator.of(context, rootNavigator: true).push<String>(MaterialPageRoute(builder: (_) => CreateBoardPage(teamId: teamId)));
      if (made == null || !mounted) return;
      id = made;
    }
    await openBoard(context, id);
    if (mounted) _refresh();
  }

  /// Bấm một việc: mở trang chi tiết của thẻ (xem trước, có nút Sửa).
  Future<void> _openTask(MyTask t) async {
    await openBoardCard(context, t.board.id, t.card.id);
    if (mounted) _refresh();
  }
}

class _TaskTile extends StatelessWidget {
  final MyTask task;
  final VoidCallback onTap;
  const _TaskTile({required this.task, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final due = task.due, pr = task.priority;
    final red = task.overdue ? const Color(0xFFE53935) : pal.sub;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          Icon(task.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: task.done ? const Color(0xFF43A047) : pal.sub, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(task.card.title.isEmpty ? tr('(Không có tiêu đề)') : task.card.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                      color: task.done ? pal.sub : pal.text,
                      decoration: task.done ? TextDecoration.lineThrough : null)),
              const SizedBox(height: 3),
              Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${task.board.icon.isEmpty ? '' : '${task.board.icon} '}${task.board.title}',
                    style: TextStyle(fontSize: 12.5, color: pal.sub), overflow: TextOverflow.ellipsis),
                if (due != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.event_rounded, size: 13, color: red),
                    const SizedBox(width: 3),
                    Text(dueText(due),
                        style: TextStyle(fontSize: 12.5, color: red, fontWeight: task.overdue ? FontWeight.w600 : null)),
                  ]),
                if (pr != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: boardsColor(pr.color, pal.sub).withValues(alpha: .15), borderRadius: BorderRadius.circular(6)),
                    child: Text(pr.value, style: TextStyle(fontSize: 11.5, color: boardsColor(pr.color, pal.sub))),
                  ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          AvatarStack(task.assignees),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- tạo việc nhanh

/// Tạo việc trên một bảng (chưa có bảng nào thì tạo bảng "Việc chung" mở cho cả team). Trả về việc vừa tạo.
class CreateBoardTaskPage extends StatefulWidget {
  final List<TaskBoard> boards;
  const CreateBoardTaskPage({super.key, required this.boards});
  @override
  State<CreateBoardTaskPage> createState() => _CreateBoardTaskPageState();
}

class _CreateBoardTaskPageState extends State<CreateBoardTaskPage> {
  static const _newBoard = '__new';
  late final AppState _app = context.read<AppState>();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  late final _boardName = TextEditingController(text: tr('Việc chung'));
  late String _boardId = widget.boards.isEmpty ? _newBoard : widget.boards.first.id;
  late final Set<String> _people = {if (_app.me != null) _app.me!.id};
  DateTime? _due;
  String? _statusName, _priorityName;
  bool _saving = false;

  TaskBoard? get _board => widget.boards.where((b) => b.id == _boardId).firstOrNull;

  /// Trạng thái / ưu tiên mặc định của bảng mới (tên theo ngôn ngữ người tạo).
  List<(String, String)> get _defStatuses => [
        (tr('Chưa làm'), 'propColorGray'),
        (tr('Đang làm'), 'propColorBlue'),
        (tr('Chờ duyệt'), 'propColorYellow'),
        (tr('Xong'), 'propColorGreen'),
      ];
  List<(String, String)> get _defPriorities => [(tr('Cao'), 'propColorRed'), (tr('Trung bình'), 'propColorYellow'), (tr('Thấp'), 'propColorGray')];

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _boardName.dispose();
    super.dispose();
  }

  Future<void> _pickPeople() async {
    final me = _app.me?.id;
    final users = _app.users.values.where((u) => !u.isBot && u.deleteAt == 0).toList()
      ..sort((a, b) => a.id == me ? -1 : b.id == me ? 1 : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final picked = await boardsSheet<Set<String>>(context, (_) => PeoplePicker(users: users, selected: _people));
    if (picked != null) setState(() => _people..clear()..addAll(picked));
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _due = d);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final teamId = _app.teamId;
    if (title.isEmpty || teamId == null || _saving) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final api = BoardsApi(_app.api);
    try {
      var board = _board;
      if (board == null) {
        final name = _boardName.text.trim().isEmpty ? tr('Việc chung') : _boardName.text.trim();
        (board, _) = await api.createBoard(teamId, name,
            statusName: tr('Trạng thái'),
            assigneeName: tr('Người làm'),
            dueName: tr('Hạn'),
            priorityName: tr('Ưu tiên'),
            statuses: _defStatuses,
            priorities: _defPriorities);
      }
      final props = <String, dynamic>{};
      final st = board.status, pr = board.priority, as = board.assignee, du = board.due;
      PropOption? byName(PropTemplate? p, String? n) =>
          n == null ? null : p?.options.where((o) => normText(o.value) == normText(n)).firstOrNull;
      final so = byName(st, _statusName) ?? st?.options.firstOrNull;
      if (st != null && so != null) props[st.id] = so.id;
      final po = byName(pr, _priorityName);
      if (pr != null && po != null) props[pr.id] = po.id;
      if (as != null && _people.isNotEmpty) props[as.id] = as.type == 'multiPerson' ? _people.toList() : _people.first;
      if (du != null && _due != null) props[du.id] = dateValue(_due!);
      final card = await api.createCard(board.id, title, props);
      if (_desc.text.trim().isNotEmpty) await api.addDescription(card, _desc.text.trim());
      // Bảng riêng tư: thêm người được giao làm thành viên để họ thấy việc (bảng mở thì cả team đã thấy).
      if (!board.isOpen) {
        for (final id in _people.where((id) => id != _app.me?.id)) {
          await api.addMember(board.id, id).catchError((_) {});
        }
      }
      nav.pop(MyTask(board, card));
    } catch (e) {
      messenger.showSnackBar(toast(Text(tr('Không tạo được việc: {0}', [e]))));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = _board;
    final statuses = b == null ? [for (final (v, _) in _defStatuses) v] : [for (final o in b.status?.options ?? const <PropOption>[]) o.value];
    final priorities =
        b == null ? [for (final (v, _) in _defPriorities) v] : [for (final o in b.priority?.options ?? const <PropOption>[]) o.value];
    final canAssign = b == null || b.assignee != null;
    final canDue = b == null || b.due != null;
    Widget label(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
          child: Text(s, style: TextStyle(color: pal.sub, fontSize: 13, fontWeight: FontWeight.w600)),
        );
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        title: Text(tr('Việc mới')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving || _title.text.trim().isEmpty ? null : _save,
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(tr('Tạo')),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        TextField(
          controller: _title,
          autofocus: true,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr('Tên việc'), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _desc,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(labelText: tr('Mô tả (không bắt buộc)'), border: const OutlineInputBorder()),
        ),
        label(tr('Bảng')),
        DropdownButtonFormField<String>(
          initialValue: _boardId,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            for (final x in widget.boards)
              DropdownMenuItem(value: x.id, child: Text('${x.icon.isEmpty ? '' : '${x.icon} '}${x.title}', overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: _newBoard, child: Text(tr('+ Tạo bảng mới (mở cho cả nhóm)'))),
          ],
          onChanged: (v) => setState(() {
            _boardId = v ?? _boardId;
            _statusName = null;
            _priorityName = null;
          }),
        ),
        if (b == null) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _boardName,
            decoration: InputDecoration(labelText: tr('Tên bảng'), border: const OutlineInputBorder(), isDense: true),
          ),
        ],
        if (canAssign) ...[
          label(tr('Người làm')),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final id in _people)
              InputChip(
                avatar: Avatar(userId: id, name: _app.users[id]?.displayName ?? '?', size: 22, status: false),
                label: Text(_app.users[id]?.displayName ?? id),
                onDeleted: () => setState(() => _people.remove(id)),
              ),
            ActionChip(avatar: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: Text(tr('Thêm người')), onPressed: _pickPeople),
          ]),
        ],
        if (canDue) ...[
          label(tr('Hạn')),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _pickDue,
              icon: const Icon(Icons.event_rounded, size: 18),
              label: Text(_due == null ? tr('Chọn ngày') : dueText(_due!)),
            ),
            if (_due != null) IconButton(icon: const Icon(Icons.close_rounded), tooltip: tr('Bỏ hạn'), onPressed: () => setState(() => _due = null)),
          ]),
        ],
        if (statuses.isNotEmpty) ...[
          label(tr('Trạng thái')),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final (i, s) in statuses.indexed)
              ChoiceChip(
                label: Text(s),
                selected: _statusName == null ? i == 0 : normText(_statusName!) == normText(s),
                onSelected: (_) => setState(() => _statusName = s),
              ),
          ]),
        ],
        if (priorities.isNotEmpty) ...[
          label(tr('Ưu tiên')),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final s in priorities)
              ChoiceChip(
                label: Text(s),
                selected: _priorityName != null && normText(_priorityName!) == normText(s),
                onSelected: (sel) => setState(() => _priorityName = sel ? s : null),
              ),
          ]),
        ],
      ]),
    );
  }
}
