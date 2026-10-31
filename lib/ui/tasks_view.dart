import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'tasks/board_picker.dart';
import 'tasks/quick_add.dart';
import 'tasks/task_logic.dart';
import 'tasks/task_sheets.dart';
import 'tasks/task_tile.dart';
import 'theme.dart';

export 'tasks/task_logic.dart' show MyTask, TaskFilter;

// ---------------------------------------------------------------- dữ liệu tab Việc

/// Bộ nhớ tạm của tab Việc theo máy chủ (mở lại tab là thấy ngay, rồi tải mới).
class _TasksCache {
  bool? available;
  List<TaskBoard> boards = [];
  /// Mọi việc (thẻ) trên các bảng xem được; danh sách "của tôi" được lọc lại khi hiện.
  List<MyTask> tasks = [];
  TaskFilter filter = TaskFilter.all;
  /// Bảng đang lọc (null: mọi bảng) và chỉ hiện việc của tôi hay mọi việc trong bảng đó.
  String? boardId;
  bool mineOnly = false;
  /// Đã đọc bảng đang lọc từ preference của máy chủ chưa.
  bool boardPrefLoaded = false;
}

final _caches = <String, _TasksCache>{};

/// Số việc của tôi đã quá hạn (chấm đỏ trên tab Việc).
final tasksOverdue = ValueNotifier<int>(0);

/// Nạp sẵn dữ liệu tab Việc (kiểm thử / ảnh xem trước, không gọi mạng).
@visibleForTesting
void debugSeedTasks(List<TaskBoard> boards, List<MyTask> tasks, {TaskFilter filter = TaskFilter.all, String? boardId, bool mineOnly = false}) {
  final c = _caches[serverKey] ??= _TasksCache();
  c
    ..available = true
    ..boards = boards
    ..tasks = tasks
    ..filter = filter
    ..boardId = boardId
    ..mineOnly = mineOnly
    ..boardPrefLoaded = true;
}

/// Khối của bảng thành thẻ + số việc con / bình luận của từng thẻ.
List<MyTask> tasksFromBlocks(TaskBoard b, List<BoardBlock> blocks, bool Function(MyTask t) keep) {
  final cards = <String, MyTask>{};
  for (final x in blocks) {
    if (x.type != 'card' || x.deleteAt != 0) continue;
    final c = TaskCard.fromJson({
      'id': x.id, 'boardId': x.boardId, 'title': x.title, 'fields': x.fields, 'createdBy': x.createdBy,
      'modifiedBy': x.modifiedBy, 'createAt': x.createAt, 'updateAt': x.updateAt, 'deleteAt': x.deleteAt,
    });
    if (!c.isTemplate) cards[c.id] = MyTask(b, c);
  }
  for (final x in blocks) {
    if (x.deleteAt != 0) continue;
    final t = cards[x.parentId];
    if (t == null) continue;
    if (x.type == 'checkbox' && t.card.contentOrder.contains(x.id)) {
      t.checksTotal++;
      if (x.fields['value'] == true) t.checksDone++;
    } else if (x.type == 'comment') {
      t.comments++;
    }
  }
  return cards.values.where(keep).toList();
}

// ---------------------------------------------------------------- tab Việc

/// Tab "Việc": việc của tôi trên các bảng Boards của team, lọc nhanh (Hôm nay / Tuần này / Quá hạn / Tôi giao / Tất cả),
/// nhóm theo thời gian, đánh dấu xong / dời hạn bằng một chạm hoặc vuốt, thêm việc nhanh bằng bảng dưới.
/// Nút "Bảng" mở danh sách bảng (kèm số việc); chọn một bảng để lọc việc trong bảng đó (của tôi / tất cả).
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
  bool _showDone = false;
  StreamSubscription<BoardsEvent>? _sub;
  /// Trạng thái trước khi đánh dấu xong (để "Hoàn tác" / "Mở lại" về đúng chỗ cũ).
  final Map<String, String?> _prevStatus = {};

  String get _me => _app.me?.id ?? '';

  @override
  void initState() {
    super.initState();
    _refresh();
    TaskPrefs.load(_app);
    _loadBoardPref();
    _app.boardsSubscribe();
    _sub = BoardsApi.events.stream.listen(_onEvent);
    if (_app.todos.values.every((l) => l.isEmpty)) _app.loadTodos();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Đọc bảng đang lọc đã lưu (một lần mỗi máy chủ): `<id bảng>|all` hoặc `<id bảng>|mine`.
  Future<void> _loadBoardPref() async {
    final c = _c;
    if (c.boardPrefLoaded) return;
    c.boardPrefLoaded = true;
    String? v;
    try {
      v = await TaskPrefs.boardFilter(_app);
    } catch (_) {}
    if (v == null || v.isEmpty || !mounted || c.boardId != null) return;
    final i = v.lastIndexOf('|');
    setState(() {
      c.boardId = i < 0 ? v : v!.substring(0, i);
      c.mineOnly = i >= 0 && v!.substring(i + 1) == 'mine';
    });
  }

  /// Lọc theo bảng [id] (null: mọi bảng) và lưu lại cho lần sau.
  void _selectBoard(String? id, {bool? mineOnly}) {
    setState(() {
      _c.boardId = id;
      if (mineOnly != null) _c.mineOnly = mineOnly;
    });
    TaskPrefs.setBoardFilter(_app, id == null ? '' : '$id|${_c.mineOnly ? 'mine' : 'all'}');
  }

  /// Bảng đang lọc (null nếu không lọc hoặc bảng không còn).
  TaskBoard? get _board => _c.boardId == null ? null : _c.boards.where((b) => b.id == _c.boardId).firstOrNull;

  /// Người khác sửa thẻ (realtime): cập nhật việc đang hiện, không tải lại cả màn.
  void _onEvent(BoardsEvent e) {
    if (e.action != 'UPDATE_BLOCK') return;
    final m = e.block;
    if (m == null || m['type'] != 'card') return;
    final b = _c.boards.where((x) => x.id == m['boardId']).firstOrNull;
    if (b == null) return;
    final blk = BoardBlock.fromJson(m);
    final list = tasksFromBlocks(b, [blk], (_) => true);
    final i = _c.tasks.indexWhere((t) => t.card.id == blk.id);
    setState(() {
      if (blk.deleteAt != 0 || list.isEmpty) {
        if (i >= 0) _c.tasks.removeAt(i);
      } else if (i >= 0) {
        _c.tasks[i].card = list.first.card;
      } else {
        _c.tasks.add(list.first);
      }
      _updateBadge();
    });
  }

  void _updateBadge() => tasksOverdue.value = _c.tasks.where((t) => t.isMine(_me) && t.overdue).length;

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
        final tasks = <MyTask>[];
        // Tải khối từng bảng song song (tối đa 6 bảng một lúc): thẻ + việc con + bình luận; bảng lỗi quyền thì bỏ qua.
        for (var i = 0; i < boards.length; i += 6) {
          await Future.wait(boards.skip(i).take(6).map((b) async {
            try {
              tasks.addAll(tasksFromBlocks(b, await _boards.allBlocks(b.id), (_) => true));
            } on ApiException catch (_) {}
          }));
        }
        _c.boards = boards;
        _c.tasks = tasks;
        setCachedTaskBoards(boards);
        _updateBadge();
      } else {
        tasksOverdue.value = 0;
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------------- thao tác trên một việc

  /// Ghi thuộc tính thẻ (luôn gửi đủ bộ thuộc tính), cập nhật ngay trên màn hình; lỗi thì trả lại như cũ.
  Future<bool> _setProp(MyTask t, String propId, Object? value) async {
    final old = t.card;
    final all = {...old.properties, propId: value};
    setState(() {
      t.card = old.copyWith(properties: all);
      _updateBadge();
    });
    try {
      t.card = await _boards.patchCard(old.id, properties: all);
      if (mounted) setState(_updateBadge);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          t.card = old;
          _updateBadge();
        });
        boardsError(context, tr('Không lưu được'), e);
      }
      return false;
    }
  }

  Future<void> _toggleDone(MyTask t) async {
    final st = t.board.status;
    if (st == null) {
      ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Bảng này chưa có cột Trạng thái'))));
      return;
    }
    final wasDone = t.done;
    final cur = t.status?.id;
    final target = wasDone ? reopenOptionOf(st, _prevStatus[t.key]) : doneOptionOf(st);
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Bảng này chưa có trạng thái "Xong"'))));
      return;
    }
    HapticFeedback.mediumImpact();
    if (!wasDone) _prevStatus[t.key] = cur;
    final messenger = ScaffoldMessenger.of(context);
    if (!await _setProp(t, st.id, target.id)) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(toast(
      Text(wasDone ? tr('Đã mở lại "{0}"', [t.card.title]) : tr('Đã xong "{0}"', [t.card.title])),
      icon: wasDone ? Icons.replay_rounded : Icons.check_circle_rounded,
    ).withUndo(() => _setProp(t, st.id, cur ?? '')));
  }

  Future<void> _snooze(MyTask t) async {
    final du = t.board.due;
    if (du == null) {
      ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Bảng này chưa có cột Hạn'))));
      return;
    }
    final old = t.card.properties[du.id];
    final v = await pickSnooze(context, t.dueProp);
    if (v == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!await _setProp(t, du.id, v)) return;
    final d = t.due;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(toast(Text(d == null ? tr('Đã bỏ hạn') : tr('Đã dời hạn sang {0}', [dueDayLabel(d)])), icon: Icons.schedule_rounded)
        .withUndo(() => _setProp(t, du.id, old ?? '')));
  }

  Future<void> _changeStatus(MyTask t) async {
    final st = t.board.status;
    if (st == null) return;
    final o = await pickStatus(context, st, t.status?.id);
    if (o == null || o.id == t.status?.id) return;
    if (isDoneStatus(o.value)) _prevStatus[t.key] = t.status?.id;
    if (await _setProp(t, st.id, o.id) && isDoneStatus(o.value)) HapticFeedback.mediumImpact();
  }

  Future<void> _reassign(MyTask t) async {
    final as = t.board.assignee;
    if (as == null) return;
    final multi = as.type == 'multiPerson';
    final r = await PeoplePicker.show(context, selected: t.card.list(as.id).toSet(), multi: multi);
    if (r == null) return;
    if (await _setProp(t, as.id, multi ? r.toList() : (r.firstOrNull ?? ''))) {
      if (!t.board.isOpen) {
        for (final id in r.where((id) => id != _me)) {
          await _boards.addMember(t.board.id, id).catchError((_) {});
        }
      }
    }
  }

  Future<void> _menu(MyTask t) async {
    HapticFeedback.selectionClick();
    final v = await showTaskMenu(context, t);
    if (!mounted) return;
    switch (v) {
      case 'done':
        await _toggleDone(t);
      case 'status':
        await _changeStatus(t);
      case 'snooze':
        await _snooze(t);
      case 'assign':
        await _reassign(t);
      case 'board':
        await openBoard(context, t.board.id);
        if (mounted) _refresh();
      case 'open':
        await _openTask(t);
    }
  }

  /// Bấm một việc: mở trang chi tiết của thẻ (xem trước, có nút Sửa).
  Future<void> _openTask(MyTask t) async {
    await openBoardCard(context, t.board.id, t.card.id);
    if (mounted) _refresh();
  }

  Future<void> _quickAdd() async {
    final assign = _c.filter == TaskFilter.assignedByMe ? <String>{} : null;
    final made = await showQuickAdd(context, people: assign, boardId: _board?.id);
    if (made == null || !mounted) return;
    setState(() {
      if (!_c.boards.any((b) => b.id == made.board.id)) _c.boards = [..._c.boards, made.board];
      _c.tasks = [..._c.tasks, made];
      _updateBadge();
    });
    ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã tạo việc "{0}"', [made.card.title])), icon: Icons.task_alt_rounded));
  }

  // ---------------------------------------------------------------- bảng

  /// Nút "Bảng": danh sách bảng ở bảng dưới (kèm số việc). Chọn bảng = lọc việc theo bảng; nút mở = bảng đầy đủ.
  Future<void> _boardsSheet() async {
    final pal = Pal.of(context);
    final list = [..._c.boards]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final v = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: pal.surface,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => BoardPickerSheet(boards: list, tasks: _c.tasks, me: _me, selected: _board?.id),
    );
    if (v == null || !mounted) return;
    if (v.isEmpty) return _selectBoard(null);
    if (v.startsWith('b:')) return _selectBoard(v.substring(2), mineOnly: false);
    if (v.startsWith('o:')) return _openFullBoard(v.substring(2));
    if (v == '*') {
      await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const BoardsHomePage()));
      if (mounted) _refresh();
      return;
    }
    if (v == '+') {
      final teamId = _app.teamId;
      if (teamId == null) return;
      final made = await Navigator.of(context, rootNavigator: true).push<String>(MaterialPageRoute(builder: (_) => CreateBoardPage(teamId: teamId)));
      if (made == null || !mounted) return;
      _selectBoard(made, mineOnly: false);
      await _openFullBoard(made);
    }
  }

  /// Mở trang bảng đầy đủ (Kanban / Bảng / Lịch / Thư viện), quay lại thì tải mới.
  Future<void> _openFullBoard(String id) async {
    await openBoard(context, id);
    if (mounted) _refresh();
  }

  /// Hàng lọc theo bảng: chip `Bảng: <tên>` (bấm ✕ để bỏ), "Tất cả / Của tôi", "Mở bảng".
  Widget _boardFilterRow(TaskBoard b) {
    final pal = Pal.of(context);
    final name = b.title.isEmpty ? tr('Bảng chưa đặt tên') : b.title;
    Widget scope(String label, bool mine) => ChoiceChip(
          key: ValueKey(mine ? 'board-scope-mine' : 'board-scope-all'),
          label: Text(label),
          selected: _c.mineOnly == mine,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _selectBoard(b.id, mineOnly: mine),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        InputChip(
          key: const ValueKey('board-filter-chip'),
          avatar: b.icon.isEmpty ? Icon(Icons.dashboard_outlined, size: 18, color: pal.chipSelFg) : Text(b.icon),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(tr('Bảng: {0}', [name]), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          labelStyle: TextStyle(color: pal.chipSelFg, fontWeight: FontWeight.w600),
          backgroundColor: pal.chipSelBg,
          side: BorderSide(color: pal.accent.withValues(alpha: .5)),
          deleteIconColor: pal.chipSelFg,
          deleteButtonTooltipMessage: tr('Bỏ lọc bảng'),
          onDeleted: () => _selectBoard(null),
          onPressed: _boardsSheet,
        ),
        scope(tr('Tất cả'), false),
        scope(tr('Của tôi'), true),
        ActionChip(
          key: const ValueKey('board-open-full'),
          avatar: Icon(Icons.view_kanban_outlined, size: 18, color: pal.accentText),
          label: Text(tr('Mở bảng')),
          visualDensity: VisualDensity.compact,
          onPressed: () => _openFullBoard(b.id),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- giao diện

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final c = _c;
    final now = DateTime.now();
    final me = _me;
    final todoCount = (app.todos['my']?.length ?? 0) + (app.todos['in']?.length ?? 0);
    final board = _board;
    // Đang lọc một bảng: chỉ việc của bảng đó; "Tất cả" thì gồm cả việc của người khác.
    final visible = board == null ? c.tasks : c.tasks.where((t) => t.board.id == board.id).toList();
    final mineOnly = board == null || c.mineOnly;
    final counts = filterCounts(visible, me, now, mineOnly: mineOnly);
    final groups = groupTasks(visible, c.filter, me, now, mineOnly: mineOnly);
    final ready = c.available == true;
    final children = <Widget>[
      widget.header,
      // Tiêu đề + tóm tắt + nút Bảng
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                board == null ? tr('Việc của tôi') : '${board.icon.isEmpty ? '' : '${board.icon} '}${board.title.isEmpty ? tr('Bảng chưa đặt tên') : board.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: pal.text),
              ),
              const SizedBox(height: 2),
              Text(
                c.available == false
                    ? tr('Máy chủ chưa bật Boards')
                    : _loading && c.tasks.isEmpty
                        ? tr('Đang tải việc…')
                        : board != null
                            ? boardSummary(visible, me)
                            : taskSummary(c.tasks, me, now),
                style: TextStyle(color: pal.sub, fontSize: 14),
              ),
            ]),
          ),
          if (c.available != false)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: OutlinedButton.icon(
                key: const ValueKey('tasks-boards-button'),
                onPressed: _boardsSheet,
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, side: BorderSide(color: pal.divider)),
                icon: const Icon(Icons.dashboard_outlined, size: 18),
                label: Text(tr('Bảng')),
              ),
            ),
        ]),
      ),
      if (c.available != false) ...[
        // Chip lọc nhanh
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            children: [
              for (final f in TaskFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _FilterPill(
                    label: filterLabel(f),
                    count: counts[f] ?? 0,
                    selected: c.filter == f,
                    alert: f == TaskFilter.overdue && (counts[f] ?? 0) > 0,
                    onTap: () => setState(() => c.filter = f),
                  ),
                ),
            ],
          ),
        ),
        if (board != null) _boardFilterRow(board),
        // Ô thêm việc nhanh
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Material(
            color: pal.surface,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: const ValueKey('tasks-quick-add'),
              borderRadius: BorderRadius.circular(14),
              onTap: _quickAdd,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(children: [
                  Icon(Icons.add_circle_outline_rounded, color: pal.accentText),
                  const SizedBox(width: 12),
                  Text(tr('Thêm việc…'), style: TextStyle(color: pal.sub, fontSize: 15.5)),
                ]),
              ),
            ),
          ),
        ),
      ],
    ];
    if (c.available == false) {
      children.add(TasksEmpty(
        icon: Icons.extension_off_outlined,
        color: pal.sub,
        title: tr('Máy chủ chưa bật Boards'),
        body: tr('Quản trị viên cần cài và bật plugin Boards để dùng bảng việc. Việc nhanh (Todo) vẫn dùng được bên dưới.'),
      ));
    } else if (_error != null && c.tasks.isEmpty) {
      children.add(TasksEmpty(icon: Icons.cloud_off_rounded, color: pal.sub, title: tr('Không tải được việc'), body: _error!, action: tr('Thử lại'), onAction: _refresh));
    } else if (_loading && c.tasks.isEmpty) {
      children.add(const TaskSkeleton());
    } else if (ready && groups.where((g) => g.$1 != DueBucket.done).isEmpty) {
      children.add(board != null
          ? TasksEmpty(
              icon: Icons.dashboard_outlined,
              title: tr('Không có việc nào phù hợp ở bảng này'),
              body: tr('Thử bộ lọc khác, xem "Tất cả" việc của bảng, hoặc thêm việc mới.'),
              action: tr('Thêm việc'),
              onAction: _quickAdd)
          : _empty(c.filter));
    }
    for (final (bucket, tasks) in groups) {
      final isDone = bucket == DueBucket.done;
      if (isDone) {
        children.add(InkWell(
          onTap: () => setState(() => _showDone = !_showDone),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
            child: Row(children: [
              Icon(Icons.check_circle_outline_rounded, size: 18, color: pal.sub),
              const SizedBox(width: 8),
              Text(tr('Đã xong · {0}', [tasks.length]), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: pal.sub)),
              const Spacer(),
              Text(_showDone ? tr('Ẩn') : tr('Hiện'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
            ]),
          ),
        ));
        if (!_showDone) continue;
      } else {
        final color = switch (bucket) {
          DueBucket.overdue => kTaskRed,
          DueBucket.today => kTaskOrange,
          _ => pal.text,
        };
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
          child: Row(children: [
            Text(bucketLabel(bucket), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: (bucket == DueBucket.overdue || bucket == DueBucket.today ? color : pal.sub).withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
              child: Text('${tasks.length}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: bucket == DueBucket.overdue || bucket == DueBucket.today ? color : pal.sub)),
            ),
          ]),
        ));
      }
      for (final t in tasks) {
        children.add(TaskTile(
          key: ValueKey('tile-${t.key}'),
          task: t,
          now: now,
          onTap: () => _openTask(t),
          onToggleDone: t.board.status == null ? null : () => _toggleDone(t),
          onSnooze: t.board.due == null ? null : () => _snooze(t),
          onMenu: () => _menu(t),
        ));
      }
    }
    // Việc nhanh của plugin Todo: một dòng gọn ở cuối.
    if (app.todoAvailable && todoCount > 0) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 4),
        child: Material(
          color: pal.surface.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TasksPage())),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Icon(Icons.checklist_rounded, size: 20, color: pal.sub),
                const SizedBox(width: 10),
                Expanded(child: Text(tr('Việc nhanh (Todo) · {0} đang chờ', [todoCount]), style: TextStyle(color: pal.sub, fontSize: 14))),
                Icon(Icons.chevron_right_rounded, color: pal.sub, size: 20),
              ]),
            ),
          ),
        ),
      ));
    }
    return Stack(children: [
      Positioned.fill(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: LayoutBuilder(builder: (context, box) {
            // Màn rộng (máy tính / ô lớn): giữ cột nội dung vừa mắt ở giữa.
            final side = box.maxWidth > 820 ? (box.maxWidth - 760) / 2 : 0.0;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(left: side, right: side, bottom: widget.bottomPadding + 88),
              children: children,
            );
          }),
        ),
      ),
      if (c.available != false)
        Positioned(
          right: 20,
          bottom: widget.fabBottom,
          child: PlusFab(heroTag: 'new-board-task', tooltip: tr('Thêm việc'), onPressed: _quickAdd),
        ),
    ]);
  }

  Widget _empty(TaskFilter f) => switch (f) {
        TaskFilter.today => TasksEmpty(
            icon: Icons.wb_sunny_outlined,
            color: kTaskOrange,
            title: tr('Hôm nay không có việc đến hạn'),
            body: tr('Thảnh thơi rồi! Thêm việc mới hoặc xem việc của tuần này.'),
            action: tr('Thêm việc'),
            onAction: _quickAdd),
        TaskFilter.week => TasksEmpty(
            icon: Icons.date_range_rounded,
            title: tr('Tuần này chưa có việc nào'),
            body: tr('Đặt hạn cho việc để chúng hiện ở đây.'),
            action: tr('Thêm việc'),
            onAction: _quickAdd),
        TaskFilter.overdue => TasksEmpty(
            icon: Icons.verified_outlined,
            color: kTaskGreen,
            title: tr('Không có việc quá hạn'),
            body: tr('Tuyệt vời, bạn đang đúng tiến độ.')),
        TaskFilter.assignedByMe => TasksEmpty(
            icon: Icons.send_outlined,
            title: tr('Bạn chưa giao việc cho ai'),
            body: tr('Giao việc cho đồng nghiệp ở đây, hoặc nhấn giữ một tin nhắn trong chat rồi chọn "Tạo việc".'),
            action: tr('Giao việc'),
            onAction: _quickAdd),
        TaskFilter.all => TasksEmpty(
            icon: Icons.task_alt_rounded,
            title: tr('Chưa có việc nào giao cho bạn'),
            body: tr('Thêm việc cho mình, hoặc nhấn giữ một tin nhắn trong chat rồi chọn "Tạo việc".'),
            action: tr('Thêm việc'),
            onAction: _quickAdd),
      };
}

/// Chip lọc nhanh có số đếm.
class _FilterPill extends StatelessWidget {
  final String label;
  final int count;
  final bool selected, alert;
  final VoidCallback onTap;
  const _FilterPill({required this.label, required this.count, required this.selected, required this.onTap, this.alert = false});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final fg = selected ? pal.chipSelFg : pal.text;
    return Material(
      color: selected ? pal.chipSelBg : pal.surface,
      shape: StadiumBorder(side: BorderSide(color: selected ? pal.accent.withValues(alpha: .5) : Colors.transparent)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(color: fg, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, fontSize: 14)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: alert ? kTaskRed : (selected ? pal.accent : pal.surface2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: alert || selected ? Colors.white : pal.sub)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

extension _Undo on SnackBar {
  /// Thêm nút "Hoàn tác" vào thông báo nhỏ.
  SnackBar withUndo(VoidCallback undo) => SnackBar(
        content: content,
        behavior: behavior,
        shape: shape,
        margin: margin,
        padding: padding,
        width: width,
        backgroundColor: backgroundColor,
        elevation: elevation,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: tr('Hoàn tác'), onPressed: undo),
      );
}
