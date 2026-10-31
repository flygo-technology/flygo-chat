import '../../api/boards_models.dart';
import '../../i18n/i18n.dart';

/// Phần logic thuần của tab Việc (không phụ thuộc giao diện, kiểm thử được): việc của tôi, bộ lọc nhanh, nhóm theo thời gian,
/// chọn ngày nhanh, trạng thái "xong" / mở lại.

// ---------------------------------------------------------------- một việc

/// Một việc: thẻ + bảng chứa nó, kèm số việc con / bình luận (tải cùng các khối của bảng).
class MyTask {
  final TaskBoard board;
  TaskCard card;
  int checksDone, checksTotal, comments;
  MyTask(this.board, this.card, {this.checksDone = 0, this.checksTotal = 0, this.comments = 0});

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

  DateProp? get dueProp => board.due == null ? null : DateProp.parse(card.properties[board.due!.id]);
  DateTime? get due => card.date(board.due?.id);
  bool get done => isDoneStatus(status?.value ?? '');

  /// Quá hạn: hạn trước hôm nay (theo ngày) và chưa xong.
  bool overdueAt(DateTime now) {
    final d = due;
    return d != null && !done && dayOf(d).isBefore(dayOf(now));
  }

  bool get overdue => overdueAt(DateTime.now());

  /// Người làm: thuộc tính "người làm" của bảng; bảng không có thì mọi người trong các thuộc tính người.
  List<String> get assignees {
    final p = board.assignee;
    return p == null ? board.people(card).toList() : card.list(p.id);
  }

  /// Việc của [me]: có tên trong một thuộc tính người của thẻ.
  bool isMine(String me) => board.people(card).contains(me);

  /// Việc [me] giao cho người khác: thẻ do [me] tạo và có người làm khác [me].
  bool assignedBy(String me) => card.createdBy == me && assignees.any((id) => id != me);

  String get key => '${board.id}/${card.id}';
}

// ---------------------------------------------------------------- ngày

DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// Chủ nhật cuối tuần này (tuần bắt đầu từ thứ 2).
DateTime endOfWeek(DateTime now) => addDays(now, 7 - now.weekday);

/// Thứ 2 tuần sau.
DateTime nextMonday(DateTime now) => addDays(now, 8 - now.weekday);

/// "Cuối tuần": thứ 7 tuần này (đang thứ 7 / chủ nhật thì là hôm nay).
DateTime weekendOf(DateTime now) => now.weekday >= DateTime.saturday ? dayOf(now) : addDays(now, DateTime.saturday - now.weekday);

/// Giá trị hạn mới cho ngày [day]; hạn cũ có giờ thì giữ giờ đó.
String dueValueFor(DateTime day, DateProp? old) {
  final s = old?.start;
  if (old != null && old.includeTime && s != null) {
    return DateProp.encode(DateTime(day.year, day.month, day.day, s.hour, s.minute), includeTime: true);
  }
  return DateProp.encode(day);
}

/// Thứ trong tuần dạng ngắn.
String weekdayShort(DateTime d) => switch (d.weekday) {
      DateTime.monday => tr('T2'),
      DateTime.tuesday => tr('T3'),
      DateTime.wednesday => tr('T4'),
      DateTime.thursday => tr('T5'),
      DateTime.friday => tr('T6'),
      DateTime.saturday => tr('T7'),
      _ => tr('CN'),
    };

/// Ngày ngắn kèm thứ: "T7 1/11".
String dueDayLabel(DateTime d) => '${weekdayShort(d)} ${d.day}/${d.month}';

// ---------------------------------------------------------------- nhóm theo thời gian

/// Nhóm theo hạn trên màn hình Việc của tôi.
enum DueBucket { overdue, today, tomorrow, thisWeek, later, none, done }

DueBucket bucketOf(MyTask t, DateTime now) {
  if (t.done) return DueBucket.done;
  final d = t.due;
  if (d == null) return DueBucket.none;
  final day = dayOf(d), today = dayOf(now);
  if (day.isBefore(today)) return DueBucket.overdue;
  if (day == today) return DueBucket.today;
  if (day == addDays(now, 1)) return DueBucket.tomorrow;
  if (!day.isAfter(endOfWeek(now))) return DueBucket.thisWeek;
  return DueBucket.later;
}

String bucketLabel(DueBucket b) => switch (b) {
      DueBucket.overdue => tr('Quá hạn'),
      DueBucket.today => tr('Hôm nay'),
      DueBucket.tomorrow => tr('Ngày mai'),
      DueBucket.thisWeek => tr('Tuần này'),
      DueBucket.later => tr('Sau đó'),
      DueBucket.none => tr('Không có hạn'),
      DueBucket.done => tr('Đã xong'),
    };

// ---------------------------------------------------------------- bộ lọc nhanh

enum TaskFilter { today, week, overdue, assignedByMe, all }

String filterLabel(TaskFilter f) => switch (f) {
      TaskFilter.today => tr('Hôm nay'),
      TaskFilter.week => tr('Tuần này'),
      TaskFilter.overdue => tr('Quá hạn'),
      TaskFilter.assignedByMe => tr('Tôi giao'),
      TaskFilter.all => tr('Tất cả'),
    };

/// Việc có thuộc bộ lọc không. "Hôm nay" / "Tuần này" gồm cả việc quá hạn (vẫn cần làm ngay); việc đã xong chỉ hiện ở
/// "Tất cả" và "Tôi giao" (nhóm "Đã xong" cuối danh sách).
/// [mineOnly] false (đang xem một bảng, chế độ "Tất cả"): tính cả việc của người khác.
bool matchesFilter(MyTask t, TaskFilter f, String me, DateTime now, {bool mineOnly = true}) {
  final mine = !mineOnly || t.isMine(me);
  switch (f) {
    case TaskFilter.assignedByMe:
      return t.assignedBy(me);
    case TaskFilter.all:
      return mine;
    case TaskFilter.today:
    case TaskFilter.week:
    case TaskFilter.overdue:
      if (!mine || t.done) return false;
      final b = bucketOf(t, now);
      if (f == TaskFilter.overdue) return b == DueBucket.overdue;
      if (f == TaskFilter.today) return b == DueBucket.overdue || b == DueBucket.today;
      return b == DueBucket.overdue || b == DueBucket.today || b == DueBucket.tomorrow || b == DueBucket.thisWeek;
  }
}

/// Số việc CHƯA XONG của từng bộ lọc (hiện trên chip).
Map<TaskFilter, int> filterCounts(Iterable<MyTask> tasks, String me, DateTime now, {bool mineOnly = true}) => {
      for (final f in TaskFilter.values) f: tasks.where((t) => !t.done && matchesFilter(t, f, me, now, mineOnly: mineOnly)).length,
    };

/// Thứ hạng ưu tiên (cao trước): theo thứ tự phương án trong bảng, không có ưu tiên xếp sau.
int _prioRank(MyTask t) {
  final p = t.priority, opts = t.board.priority?.options;
  if (p == null || opts == null) return 1 << 20;
  return opts.indexOf(p);
}

/// Các nhóm theo thời gian (bỏ nhóm trống), trong nhóm: hạn gần trước, rồi ưu tiên cao, rồi việc mới sửa.
List<(DueBucket, List<MyTask>)> groupTasks(Iterable<MyTask> tasks, TaskFilter f, String me, DateTime now, {bool mineOnly = true}) {
  final by = <DueBucket, List<MyTask>>{};
  for (final t in tasks) {
    if (!matchesFilter(t, f, me, now, mineOnly: mineOnly)) continue;
    (by[bucketOf(t, now)] ??= []).add(t);
  }
  int cmp(MyTask a, MyTask b) {
    final da = a.due, db = b.due;
    if (da != null && db != null && da != db) return da.compareTo(db);
    if ((da == null) != (db == null)) return da == null ? 1 : -1;
    final p = _prioRank(a).compareTo(_prioRank(b));
    if (p != 0) return p;
    return b.card.updateAt.compareTo(a.card.updateAt);
  }

  return [
    for (final b in DueBucket.values)
      if (by[b] != null) (b, by[b]!..sort(b == DueBucket.done ? (x, y) => y.card.updateAt.compareTo(x.card.updateAt) : cmp)),
  ];
}

/// Một dòng tóm tắt dưới tiêu đề "Việc của tôi".
String taskSummary(Iterable<MyTask> tasks, String me, DateTime now) {
  var today = 0, overdue = 0, open = 0;
  for (final t in tasks) {
    if (!t.isMine(me) || t.done) continue;
    open++;
    final b = bucketOf(t, now);
    if (b == DueBucket.today) today++;
    if (b == DueBucket.overdue) overdue++;
  }
  if (today > 0 && overdue > 0) return tr('Hôm nay có {0} việc · {1} việc quá hạn', [today, overdue]);
  if (today > 0) return tr('Hôm nay có {0} việc cần làm', [today]);
  if (overdue > 0) return tr('{0} việc đã quá hạn, xử lý sớm nhé', [overdue]);
  if (open > 0) return tr('Hôm nay không có việc đến hạn · {0} việc đang mở', [open]);
  return tr('Bạn đã xong hết việc');
}

/// Một dòng tóm tắt khi đang lọc một bảng: số việc đang mở, trong đó của [me].
String boardSummary(Iterable<MyTask> tasks, String me) {
  var open = 0, mine = 0;
  for (final t in tasks) {
    if (t.done) continue;
    open++;
    if (t.isMine(me)) mine++;
  }
  if (open == 0) return tr('Bảng không còn việc đang mở');
  return mine > 0 ? tr('{0} việc đang mở · {1} của bạn', [open, mine]) : tr('{0} việc đang mở', [open]);
}

/// Số việc chưa xong theo bảng: (của [me], tất cả).
Map<String, (int, int)> boardOpenCounts(Iterable<MyTask> tasks, String me) {
  final r = <String, (int, int)>{};
  for (final t in tasks) {
    if (t.done) continue;
    final (m, a) = r[t.board.id] ?? (0, 0);
    r[t.board.id] = (m + (t.isMine(me) ? 1 : 0), a + 1);
  }
  return r;
}

// ---------------------------------------------------------------- trạng thái xong / mở lại

/// Phương án "xong" của thuộc tính trạng thái (null: bảng chưa có trạng thái kiểu xong).
PropOption? doneOptionOf(PropTemplate? status) => status?.options.where((o) => isDoneStatus(o.value)).firstOrNull;

/// Phương án khi mở lại việc: trạng thái trước đó (nếu còn và chưa phải xong), không thì phương án chưa-xong đầu tiên.
PropOption? reopenOptionOf(PropTemplate? status, [String? previousId]) {
  if (status == null) return null;
  final prev = status.options.where((o) => o.id == previousId && !isDoneStatus(o.value)).firstOrNull;
  return prev ?? status.options.where((o) => !isDoneStatus(o.value)).firstOrNull;
}

// ---------------------------------------------------------------- liên kết tin nhắn gốc

/// Id tin trong permalink của máy chủ chat `<máy chủ>/<team>/pl/<id>` (null nếu không phải).
String? permalinkPostId(Uri u, String serverUrl) {
  final s = Uri.tryParse(serverUrl);
  if (s == null || s.host.isEmpty || u.host != s.host) return null;
  final seg = u.pathSegments.where((x) => x.isNotEmpty).toList();
  final i = seg.indexOf('pl');
  if (i < 1 || i + 1 >= seg.length) return null;
  final id = seg[i + 1];
  return RegExp(r'^[a-z0-9]{26}$').hasMatch(id) ? id : null;
}

/// Tìm permalink tin nhắn gốc trong nội dung thẻ (khối chữ do "Tạo việc từ tin nhắn" thêm vào).
String? sourcePostIdIn(Iterable<String> texts, String serverUrl) {
  final re = RegExp(r'https?://[^\s)\]>]+/pl/[a-z0-9]{26}');
  for (final t in texts) {
    for (final m in re.allMatches(t)) {
      final id = permalinkPostId(Uri.parse(m.group(0)!), serverUrl);
      if (id != null) return id;
    }
  }
  return null;
}

/// Tiêu đề việc từ nội dung tin: dòng có chữ đầu tiên, bỏ dấu markdown đầu dòng, tối đa [max] ký tự.
String taskTitleFromMessage(String message, {int max = 120}) {
  final line = message
      .split('\n')
      .map((l) => l.trim().replaceFirst(RegExp(r'^(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)'), '').trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  final s = line.replaceAll(RegExp(r'\*\*|__|`'), '');
  return s.length <= max ? s : '${s.substring(0, max - 1).trimRight()}…';
}
