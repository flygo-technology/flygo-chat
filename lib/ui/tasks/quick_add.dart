import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/boards_api.dart';
import '../../api/mm_api.dart' show ApiException;
import '../../config.dart';
import '../../data/models.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../boards/boards_common.dart';
import '../common.dart';
import '../theme.dart';
import 'task_logic.dart';

/// Thêm việc nhanh: bảng dưới (tên, người làm, hạn chọn nhanh, bảng, ưu tiên), tạo việc từ tin nhắn chat, gửi thẻ việc vào
/// cuộc trò chuyện, nhớ bảng dùng lần trước, bật / tắt nhắc việc mỗi sáng.

// ---------------------------------------------------------------- tuỳ chọn lưu trên máy chủ (preferences flygo_chat)

class TaskPrefs {
  static final _last = <String, String>{};

  /// Nhắc việc mỗi sáng (trạm đẩy đọc preference flygo_chat/task_digest = "off" để bỏ qua). null = chưa tải.
  static final digest = ValueNotifier<bool?>(null);

  static String? lastBoard() => _last[serverKey];

  static Future<String?> _get(AppState app, String name) async {
    final me = app.me?.id;
    if (me == null) return null;
    try {
      final r = await app.api.get('/users/$me/preferences/flygo_chat/name/$name') as Map;
      return '${r['value'] ?? ''}';
    } on ApiException catch (_) {
      return null;
    }
  }

  static Future<void> _put(AppState app, String name, String value) async {
    final me = app.me?.id;
    if (me == null) return;
    await app.api.put('/users/$me/preferences', [
      {'user_id': me, 'category': 'flygo_chat', 'name': name, 'value': value},
    ]);
  }

  /// Tải bảng dùng lần trước + nhắc mỗi sáng (một lần mỗi máy chủ, lỗi thì bỏ qua).
  static Future<void> load(AppState app) async {
    try {
      final last = await _get(app, 'task_last_board');
      if (last != null && last.isNotEmpty) _last.putIfAbsent(serverKey, () => last);
      digest.value = await _get(app, 'task_digest') != 'off';
    } catch (_) {}
  }

  static void setLastBoard(AppState app, String boardId) {
    if (_last[serverKey] == boardId) return;
    _last[serverKey] = boardId;
    _put(app, 'task_last_board', boardId).catchError((_) {});
  }

  static Future<void> setDigest(AppState app, bool on) async {
    final old = digest.value;
    digest.value = on;
    try {
      await _put(app, 'task_digest', on ? 'on' : 'off');
    } catch (_) {
      digest.value = old;
      rethrow;
    }
  }
}

/// Công tắc "Nhắc việc mỗi sáng" (trang Bạn / Cài đặt).
class TaskDigestSwitch extends StatefulWidget {
  const TaskDigestSwitch({super.key});
  @override
  State<TaskDigestSwitch> createState() => _TaskDigestSwitchState();
}

class _TaskDigestSwitchState extends State<TaskDigestSwitch> {
  @override
  void initState() {
    super.initState();
    if (TaskPrefs.digest.value == null) TaskPrefs.load(context.read<AppState>());
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ValueListenableBuilder<bool?>(
      valueListenable: TaskPrefs.digest,
      builder: (context, v, _) => Switch.adaptive(
        value: v ?? true,
        activeTrackColor: pal.accent,
        onChanged: v == null
            ? null
            : (on) => TaskPrefs.setDigest(context.read<AppState>(), on).catchError((_) {
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Không lưu được. Kiểm tra kết nối mạng.'))));
                }),
      ),
    );
  }
}

// ---------------------------------------------------------------- bảng của team (dùng chung tab Việc và bảng thêm nhanh)

final _boardsCache = <String, List<TaskBoard>>{};

List<TaskBoard> cachedTaskBoards() => _boardsCache[serverKey] ?? const [];
void setCachedTaskBoards(List<TaskBoard> b) => _boardsCache[serverKey] = b;

Future<List<TaskBoard>> loadTaskBoards(AppState app) async {
  final have = cachedTaskBoards();
  if (have.isNotEmpty) return have;
  final team = app.teamId;
  if (team == null) return const [];
  final api = BoardsApi(app.api);
  if (!await api.available()) return const [];
  final b = await api.teamBoards(team);
  setCachedTaskBoards(b);
  return b;
}

/// Bảng mặc định cho việc mới: bảng dùng lần trước, rồi bảng "Việc chung", rồi bảng đầu tiên có cột người làm.
TaskBoard? defaultTaskBoard(List<TaskBoard> boards) {
  final last = TaskPrefs.lastBoard();
  return boards.where((b) => b.id == last).firstOrNull ??
      boards.where((b) => normText(b.title) == normText(tr('Việc chung')) || normText(b.title) == 'viec chung').firstOrNull ??
      boards.where((b) => b.assignee != null).firstOrNull ??
      boards.firstOrNull;
}

/// Trạng thái / ưu tiên mặc định của bảng mới (tên theo ngôn ngữ người tạo).
List<(String, String)> defaultStatuses() => [
      (tr('Chưa làm'), 'propColorGray'),
      (tr('Đang làm'), 'propColorBlue'),
      (tr('Chờ duyệt'), 'propColorYellow'),
      (tr('Xong'), 'propColorGreen'),
    ];
List<(String, String)> defaultPriorities() => [(tr('Cao'), 'propColorRed'), (tr('Trung bình'), 'propColorYellow'), (tr('Thấp'), 'propColorGray')];

// ---------------------------------------------------------------- tạo việc

/// Tạo việc trên bảng [board] (null: tạo bảng mới [newBoardName] mở cho cả team). Bảng riêng tư thì thêm người được giao
/// làm thành viên. [description]: khối chữ đầu tiên của thẻ (vd. trích tin nhắn + link tin gốc).
Future<MyTask> createBoardTask(AppState app,
    {required String title,
    TaskBoard? board,
    String? newBoardName,
    Set<String> people = const {},
    DateTime? due,
    String? statusName,
    String? priorityName,
    String description = ''}) async {
  final teamId = app.teamId;
  if (teamId == null) throw StateError('no team');
  final api = BoardsApi(app.api);
  var b = board;
  if (b == null) {
    final name = (newBoardName ?? '').trim().isEmpty ? tr('Việc chung') : newBoardName!.trim();
    (b, _) = await api.createBoard(teamId, name,
        statusName: tr('Trạng thái'),
        assigneeName: tr('Người làm'),
        dueName: tr('Hạn'),
        priorityName: tr('Ưu tiên'),
        statuses: defaultStatuses(),
        priorities: defaultPriorities());
    setCachedTaskBoards([...cachedTaskBoards(), b]);
  }
  final props = <String, dynamic>{};
  final st = b.status, pr = b.priority, as = b.assignee, du = b.due;
  PropOption? byName(PropTemplate? p, String? n) => n == null ? null : p?.options.where((o) => normText(o.value) == normText(n)).firstOrNull;
  final so = byName(st, statusName) ?? st?.options.where((o) => !isDoneStatus(o.value)).firstOrNull ?? st?.options.firstOrNull;
  if (st != null && so != null) props[st.id] = so.id;
  final po = byName(pr, priorityName);
  if (pr != null && po != null) props[pr.id] = po.id;
  if (as != null && people.isNotEmpty) props[as.id] = as.type == 'multiPerson' ? people.toList() : people.first;
  if (du != null && due != null) props[du.id] = dateValue(due);
  var card = await api.createCard(b.id, title, props);
  if (description.trim().isNotEmpty) {
    await api.addDescription(card, description.trim());
    try {
      card = await api.card(card.id);
    } catch (_) {}
  }
  if (!b.isOpen) {
    for (final id in people.where((id) => id != app.me?.id)) {
      await api.addMember(b.id, id).catchError((_) {});
    }
  }
  TaskPrefs.setLastBoard(app, b.id);
  return MyTask(b, card);
}

/// Gửi thẻ việc gọn vào cuộc trò chuyện: "(người được giao) được giao: tên việc · hạn ngày" + link (app hiện thành thẻ bấm được).
Future<void> announceTask(AppState app, MyTask t, String channelId, {String rootId = ''}) async {
  final me = app.me?.id;
  final others = t.assignees.where((id) => id != me).toList();
  // Tên in đậm, không @nhắc: người được giao đã nhận tin riêng từ bot nhắc việc (tránh hai thông báo cho một việc).
  final who = others.map((id) => '**${app.users[id]?.displayName ?? id}**').join(', ');
  final due = t.due;
  final head = others.isEmpty ? tr('Việc mới: {0}', [t.card.title]) : tr('{0} được giao: {1}', [who, t.card.title]);
  var view = '';
  try {
    view = await BoardsApi(app.api).firstViewId(t.board.id);
  } catch (_) {}
  final url = BoardsApi.webUrl(teamId: t.board.teamId, boardId: t.board.id, viewId: view, cardId: t.card.id);
  final text = '$head${due == null ? '' : ' · ${tr('hạn {0}', [dueDayLabel(due)])}'}\n$url';
  await app.send(channelId, text, rootId: rootId, replyKind: rootId.isEmpty ? '' : 'thread', props: {
    'flygo_task': {
      'v': 1,
      'kind': 'assigned',
      'by': ?me,
      'items': [taskItemJson(t, view: view)],
    },
  });
}

/// Mục việc trong props.flygo_task (thẻ trong chat, cũng là dạng trạm đẩy gửi nhắc việc).
Map<String, dynamic> taskItemJson(MyTask t, {String view = ''}) => {
      'team_id': t.board.teamId,
      'board_id': t.board.id,
      if (view.isNotEmpty) 'view_id': view,
      'card_id': t.card.id,
      'title': t.card.title,
      if (t.due != null) 'due': t.card.properties[t.board.due!.id],
      'assignees': t.assignees,
    };

// ---------------------------------------------------------------- bảng thêm nhanh

/// Mở bảng thêm việc nhanh. [channelId]: tạo từ một cuộc trò chuyện (hiện công tắc "Báo vào cuộc chat").
Future<MyTask?> showQuickAdd(BuildContext context,
    {String title = '',
    String description = '',
    Set<String>? people,
    DateTime? due,
    String? channelId,
    String rootId = '',
    String? quote}) {
  final pal = Pal.of(context);
  return showModalBottomSheet<MyTask>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    useRootNavigator: true,
    backgroundColor: pal.surface,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => QuickAddSheet(
        title: title, description: description, people: people, due: due, channelId: channelId, rootId: rootId, quote: quote),
  );
}

/// Bảng thêm việc nhanh. Trả về (pop) việc vừa tạo.
class QuickAddSheet extends StatefulWidget {
  final String title, description, rootId;
  final Set<String>? people;
  final DateTime? due;
  final String? channelId, quote;
  /// Danh sách bảng có sẵn (kiểm thử); null: lấy từ bộ nhớ / tải về.
  final List<TaskBoard>? boards;
  /// Thay thao tác tạo (kiểm thử).
  final Future<MyTask> Function(QuickAddDraft d)? onCreate;
  const QuickAddSheet(
      {super.key,
      this.title = '',
      this.description = '',
      this.people,
      this.due,
      this.channelId,
      this.rootId = '',
      this.quote,
      this.boards,
      this.onCreate});
  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

/// Nội dung đang soạn của bảng thêm nhanh.
class QuickAddDraft {
  final String title, description;
  final TaskBoard? board;
  final Set<String> people;
  final DateTime? due;
  final String? priority;
  const QuickAddDraft(this.title, this.description, this.board, this.people, this.due, this.priority);
}

enum _DuePick { none, today, tomorrow, weekend, nextWeek, custom }

class _QuickAddSheetState extends State<QuickAddSheet> {
  late final AppState _app = context.read<AppState>();
  late final _title = TextEditingController(text: widget.title);
  late List<TaskBoard> _boards = widget.boards ?? cachedTaskBoards();
  TaskBoard? _board;
  bool _boardsLoading = false;
  late final Set<String> _people = {...?widget.people, if (widget.people == null && _app.me != null) _app.me!.id};
  _DuePick _pick = _DuePick.none;
  DateTime? _due;
  String? _priority;
  late bool _announce = widget.channelId != null;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _board = defaultTaskBoard(_boards);
    if (widget.due != null) {
      _due = dayOf(widget.due!);
      _pick = _DuePick.custom;
    }
    if (_boards.isEmpty && widget.boards == null) _loadBoards();
  }

  Future<void> _loadBoards() async {
    setState(() => _boardsLoading = true);
    try {
      final b = await loadTaskBoards(_app);
      if (!mounted) return;
      setState(() {
        _boards = b;
        _board = defaultTaskBoard(b);
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _boardsLoading = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime? _dueOf(_DuePick p) {
    final n = DateTime.now();
    return switch (p) {
      _DuePick.none => null,
      _DuePick.today => dayOf(n),
      _DuePick.tomorrow => addDays(n, 1),
      _DuePick.weekend => weekendOf(n),
      _DuePick.nextWeek => nextMonday(n),
      _DuePick.custom => _due,
    };
  }

  Future<void> _choose(_DuePick p) async {
    if (p == _pick && p != _DuePick.custom) {
      setState(() => _pick = _DuePick.none);
      return;
    }
    if (p == _DuePick.custom) {
      final n = DateTime.now();
      final d = await showDatePicker(context: context, initialDate: _due ?? addDays(n, 1), firstDate: DateTime(n.year - 1), lastDate: DateTime(n.year + 5));
      if (d == null) return;
      setState(() {
        _due = d;
        _pick = _DuePick.custom;
      });
      return;
    }
    setState(() => _pick = p);
  }

  Future<void> _pickPeople() async {
    final r = await PeoplePicker.show(context, selected: _people);
    if (r != null) setState(() => _people..clear()..addAll(r));
  }

  Future<void> _pickBoard() async {
    final pal = Pal.of(context);
    final r = await boardsSheet<String>(context, scroll: false, (c) {
      final list = [..._boards]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * .7),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr('Chọn bảng'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            for (final b in list)
              ListTile(
                leading: SizedBox(width: 28, child: Center(child: b.icon.isEmpty ? Icon(Icons.dashboard_outlined, color: pal.sub) : Text(b.icon, style: const TextStyle(fontSize: 20)))),
                title: Text(b.title.isEmpty ? tr('Bảng chưa đặt tên') : b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: b.id == _board?.id ? Icon(Icons.check_rounded, color: pal.accentText) : null,
                onTap: () => Navigator.pop(c, b.id),
              ),
            ListTile(
              leading: Icon(Icons.add_rounded, color: pal.accentText),
              title: Text(tr('Bảng mới "{0}"', [tr('Việc chung')]), style: TextStyle(color: pal.accentText)),
              onTap: () => Navigator.pop(c, ''),
            ),
          ]),
        ),
      );
    });
    if (r == null) return;
    setState(() {
      _board = r.isEmpty ? null : _boards.where((b) => b.id == r).firstOrNull;
      _priority = null;
    });
  }

  QuickAddDraft get _draft => QuickAddDraft(_title.text.trim(), widget.description, _board, {..._people}, _dueOf(_pick), _priority);

  Future<void> _save() async {
    final d = _draft;
    if (d.title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final t = widget.onCreate != null
          ? await widget.onCreate!(d)
          : await createBoardTask(_app,
              title: d.title, board: d.board, people: d.people, due: d.due, priorityName: d.priority, description: d.description);
      await _afterCreate(t);
      nav.pop(t);
    } catch (e) {
      messenger.showSnackBar(toast(Text(tr('Không tạo được việc: {0}', [e]))));
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _afterCreate(MyTask t) async {
    final ch = widget.channelId;
    if (_announce && ch != null && widget.onCreate == null) {
      await announceTask(_app, t, ch, rootId: widget.rootId).catchError((_) {});
    }
  }

  /// Mở trang tạo việc đầy đủ (mô tả, trạng thái...) với nội dung đang soạn.
  Future<void> _more() async {
    final nav = Navigator.of(context);
    final d = _draft;
    final t = await nav.push<MyTask>(MaterialPageRoute(
      builder: (_) => CreateBoardTaskPage(
        boards: _boards,
        title: d.title,
        description: d.description,
        people: d.people,
        due: d.due,
        boardId: d.board?.id,
        priority: d.priority,
      ),
    ));
    if (t == null || !mounted) return;
    await _afterCreate(t);
    nav.pop(t);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = _board;
    final canAssign = b == null || b.assignee != null;
    final canDue = b == null || b.due != null;
    final priorities = b == null ? [for (final (v, _) in defaultPriorities()) (v, '')] : [for (final o in b.priority?.options ?? const <PropOption>[]) (o.value, o.color)];
    final ready = _title.text.trim().isNotEmpty && !_saving;
    Widget label(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
          child: Text(s, style: TextStyle(color: pal.sub, fontSize: 13, fontWeight: FontWeight.w600)),
        );
    String pickText(_DuePick p) => switch (p) {
          _DuePick.today => tr('Hôm nay'),
          _DuePick.tomorrow => tr('Mai'),
          _DuePick.weekend => tr('Cuối tuần'),
          _DuePick.nextWeek => tr('Tuần sau'),
          _DuePick.custom => _pick == _DuePick.custom && _due != null ? dueDayLabel(_due!) : tr('Chọn ngày'),
          _DuePick.none => '',
        };
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('Việc mới'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text))),
            TextButton(onPressed: _saving ? null : _more, child: Text(tr('Thêm chi tiết…'))),
          ]),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('quick-add-title'),
            controller: _title,
            autofocus: widget.title.isEmpty,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            style: TextStyle(fontSize: 17, color: pal.text),
            decoration: InputDecoration(
              hintText: tr('Cần làm gì?'),
              filled: true,
              fillColor: pal.bg,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
          ),
          if ((widget.quote ?? '').isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: pal.quoteBar, width: 3)),
                color: pal.bg.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                Icon(Icons.chat_bubble_outline_rounded, size: 16, color: pal.sub),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.quote!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13))),
              ]),
            ),
          if (canAssign) ...[
            label(tr('Người làm')),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final id in _people)
                InputChip(
                  avatar: Avatar(userId: id, name: _app.users[id]?.displayName ?? '?', size: 22, status: false),
                  label: Text(id == _app.me?.id ? tr('Tôi') : (_app.users[id]?.displayName ?? id)),
                  onDeleted: () => setState(() => _people.remove(id)),
                ),
              ActionChip(avatar: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: Text(tr('Giao cho…')), onPressed: _pickPeople),
            ]),
          ],
          if (canDue) ...[
            label(tr('Hạn')),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in const [_DuePick.today, _DuePick.tomorrow, _DuePick.weekend, _DuePick.nextWeek, _DuePick.custom])
                ChoiceChip(
                  avatar: p == _DuePick.custom ? const Icon(Icons.event_rounded, size: 16) : null,
                  label: Text(pickText(p)),
                  selected: _pick == p,
                  onSelected: (_) => _choose(p),
                ),
            ]),
          ],
          label(tr('Bảng')),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ActionChip(
              avatar: b == null || b.icon.isEmpty ? const Icon(Icons.dashboard_outlined, size: 18) : Text(b.icon),
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                      _boardsLoading
                          ? tr('Đang tải bảng…')
                          : b == null
                              ? tr('Bảng mới "{0}"', [tr('Việc chung')])
                              : (b.title.isEmpty ? tr('Bảng chưa đặt tên') : b.title),
                      overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_drop_down_rounded, size: 20),
              ]),
              onPressed: _boardsLoading ? null : _pickBoard,
            ),
          ]),
          if (priorities.isNotEmpty) ...[
            label(tr('Ưu tiên')),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (name, color) in priorities)
                ChoiceChip(
                  avatar: Icon(Icons.flag_rounded, size: 16, color: boardsColor(color, pal.sub)),
                  label: Text(name),
                  selected: _priority != null && normText(_priority!) == normText(name),
                  onSelected: (sel) => setState(() => _priority = sel ? name : null),
                ),
            ]),
          ],
          if (widget.channelId != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _announce,
                activeTrackColor: pal.accent,
                onChanged: (v) => setState(() => _announce = v),
                title: Text(tr('Báo vào cuộc chat'), style: TextStyle(color: pal.text)),
                subtitle: Text(tr('Gửi thẻ việc vào cuộc trò chuyện này'), style: TextStyle(color: pal.sub, fontSize: 13)),
              ),
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              key: const ValueKey('quick-add-save'),
              onPressed: ready ? _save : null,
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.add_task_rounded),
              label: Text(tr('Thêm việc'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- tạo việc từ tin nhắn

/// "Tạo việc" từ menu nhấn giữ tin nhắn: tên lấy từ nội dung tin, mô tả trích tin + link tin gốc, người làm mặc định là
/// người gửi (tin của mình hoặc của bot thì là mình), thẻ việc gửi lại vào cuộc trò chuyện (tắt được).
Future<void> createTaskFromMessage(BuildContext context, AppState app, MmPost post, {bool announce = true}) async {
  final messenger = ScaffoldMessenger.of(context);
  final me = app.me?.id;
  final author = app.users[post.userId];
  final text = post.message.trim();
  final title = taskTitleFromMessage(text);
  final permalink = '$kServerUrl/$kTeamName/pl/${post.id}';
  final name = author?.displayName ?? '';
  final quoted = text.split('\n').map((l) => '> $l').join('\n');
  final longer = text.isNotEmpty && text.replaceAll(RegExp(r'\s+'), ' ') != title;
  final description = [
    if (longer) quoted,
    '[${tr('Tin nhắn gốc')}]($permalink)${name.isEmpty ? '' : ' · $name'}',
  ].join('\n\n');
  final assignee = post.userId != me && author != null && !author.isBot ? post.userId : me;
  final t = await showQuickAdd(
    context,
    title: title,
    description: description,
    people: {?assignee},
    channelId: announce ? post.channelId : null,
    rootId: post.inThread ? post.rootId : '',
    quote: plainPreview(text),
  );
  if (t != null) {
    messenger.showSnackBar(toast(Text(tr('Đã tạo việc "{0}"', [t.card.title])), icon: Icons.task_alt_rounded));
  }
}

// ---------------------------------------------------------------- trang tạo việc đầy đủ

/// Tạo việc với đủ chi tiết (mô tả, trạng thái, ưu tiên, bảng mới). Trả về việc vừa tạo.
class CreateBoardTaskPage extends StatefulWidget {
  final List<TaskBoard> boards;
  final String title, description;
  final Set<String>? people;
  final DateTime? due;
  final String? boardId, priority;
  const CreateBoardTaskPage(
      {super.key, required this.boards, this.title = '', this.description = '', this.people, this.due, this.boardId, this.priority});
  @override
  State<CreateBoardTaskPage> createState() => _CreateBoardTaskPageState();
}

class _CreateBoardTaskPageState extends State<CreateBoardTaskPage> {
  static const _newBoard = '__new';
  late final AppState _app = context.read<AppState>();
  late final _title = TextEditingController(text: widget.title);
  late final _desc = TextEditingController(text: widget.description);
  late final _boardName = TextEditingController(text: tr('Việc chung'));
  late String _boardId = widget.boards.any((b) => b.id == widget.boardId)
      ? widget.boardId!
      : (defaultTaskBoard(widget.boards)?.id ?? _newBoard);
  late final Set<String> _people = {...?widget.people, if (widget.people == null && _app.me != null) _app.me!.id};
  late DateTime? _due = widget.due;
  String? _statusName;
  late String? _priorityName = widget.priority;
  bool _saving = false;

  TaskBoard? get _board => widget.boards.where((b) => b.id == _boardId).firstOrNull;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _boardName.dispose();
    super.dispose();
  }

  Future<void> _pickPeople() async {
    final r = await PeoplePicker.show(context, selected: _people);
    if (r != null) setState(() => _people..clear()..addAll(r));
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: _due ?? now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 5));
    if (d != null) setState(() => _due = d);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final t = await createBoardTask(_app,
          title: title,
          board: _board,
          newBoardName: _boardName.text,
          people: _people,
          due: _due,
          statusName: _statusName,
          priorityName: _priorityName,
          description: _desc.text);
      nav.pop(t);
    } catch (e) {
      messenger.showSnackBar(toast(Text(tr('Không tạo được việc: {0}', [e]))));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final b = _board;
    final statuses = b == null ? [for (final (v, _) in defaultStatuses()) v] : [for (final o in b.status?.options ?? const <PropOption>[]) o.value];
    final priorities = b == null ? [for (final (v, _) in defaultPriorities()) v] : [for (final o in b.priority?.options ?? const <PropOption>[]) o.value];
    final canAssign = b == null || b.assignee != null;
    final canDue = b == null || b.due != null;
    Widget label(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
          child: Text(s, style: TextStyle(color: pal.sub, fontSize: 13, fontWeight: FontWeight.w600)),
        );
    final field = InputDecoration(filled: true, fillColor: pal.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none));
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: Text(tr('Việc mới'))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _saving || _title.text.trim().isEmpty ? null : _save,
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.add_task_rounded),
              label: Text(tr('Tạo việc'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            TextField(
              controller: _title,
              autofocus: widget.title.isEmpty,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 17),
              decoration: field.copyWith(hintText: tr('Tên việc')),
            ),
            const SizedBox(height: 12),
            TextField(controller: _desc, minLines: 3, maxLines: 8, decoration: field.copyWith(hintText: tr('Mô tả (không bắt buộc)'))),
            label(tr('Bảng')),
            DropdownButtonFormField<String>(
              initialValue: _boardId,
              isExpanded: true,
              decoration: field.copyWith(isDense: true),
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
              TextField(controller: _boardName, decoration: field.copyWith(labelText: tr('Tên bảng'), isDense: true)),
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
                  label: Text(_due == null ? tr('Chọn ngày') : dueDayLabel(_due!)),
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
        ),
      ),
    );
  }
}

/// Đọc props.flygo_task của một tin (thẻ việc trong chat / nhắc việc của trạm đẩy).
Map<String, dynamic>? taskPropsOf(MmPost p) {
  final v = p.props['flygo_task'];
  if (v is Map) return v.cast<String, dynamic>();
  if (v is String && v.startsWith('{')) {
    try {
      return (jsonDecode(v) as Map).cast<String, dynamic>();
    } catch (_) {}
  }
  return null;
}
