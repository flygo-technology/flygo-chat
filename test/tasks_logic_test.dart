import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/api/boards_models.dart';
import 'package:flygo_chat/ui/tasks/task_logic.dart';

/// Logic tab Việc: nhóm theo hạn, bộ lọc nhanh + số đếm, ngày chọn nhanh, xong / mở lại, permalink, tên việc từ tin nhắn.
void main() {
  const st = PropTemplate('s', 'Trạng thái', 'select', [
    PropOption('todo', 'Chưa làm', 'propColorGray'),
    PropOption('doing', 'Đang làm', 'propColorBlue'),
    PropOption('done', 'Xong', 'propColorGreen'),
  ]);
  const pr = PropTemplate('p', 'Ưu tiên', 'select', [PropOption('hi', 'Cao', 'propColorRed'), PropOption('lo', 'Thấp', 'propColorGray')]);
  const board = TaskBoard('b', 't', 'O', 'Việc chung', '', 'editor', [st, PropTemplate('a', 'Người làm', 'multiPerson'), PropTemplate('h', 'Hạn', 'date'), pr]);
  // Thứ 4, 4/11/2026, 10:00.
  final now = DateTime(2026, 11, 4, 10);

  MyTask task(String id, {DateTime? due, String status = 'todo', List<String> who = const ['me'], String by = 'me', String? prio, int upd = 0}) =>
      MyTask(board, TaskCard(id, 'b', 'Task $id', '', by, {'s': status, 'a': who, 'h': ?(due == null ? null : DateProp.encode(due)), 'p': ?prio}, const [], upd));

  group('bucketOf', () {
    test('theo ngày', () {
      expect(bucketOf(task('1', due: DateTime(2026, 11, 3)), now), DueBucket.overdue);
      expect(bucketOf(task('2', due: DateTime(2026, 11, 4)), now), DueBucket.today);
      expect(bucketOf(task('3', due: DateTime(2026, 11, 5)), now), DueBucket.tomorrow);
      expect(bucketOf(task('4', due: DateTime(2026, 11, 8)), now), DueBucket.thisWeek, reason: 'chủ nhật cùng tuần');
      expect(bucketOf(task('5', due: DateTime(2026, 11, 9)), now), DueBucket.later, reason: 'thứ 2 tuần sau');
      expect(bucketOf(task('6'), now), DueBucket.none);
      expect(bucketOf(task('7', due: DateTime(2026, 11, 1), status: 'done'), now), DueBucket.done, reason: 'xong thì không quá hạn');
    });
  });

  group('bộ lọc', () {
    final tasks = [
      task('late', due: DateTime(2026, 11, 2)),
      task('today', due: DateTime(2026, 11, 4)),
      task('fri', due: DateTime(2026, 11, 6)),
      task('next', due: DateTime(2026, 11, 12)),
      task('nodue'),
      task('done', due: DateTime(2026, 11, 4), status: 'done'),
      task('gave', due: DateTime(2026, 11, 4), who: ['u2'], by: 'me'),
      task('other', due: DateTime(2026, 11, 4), who: ['u2'], by: 'u3'),
    ];
    List<String> ids(TaskFilter f) => [for (final g in groupTasks(tasks, f, 'me', now)) for (final t in g.$2) t.card.id];

    test('Hôm nay gồm cả quá hạn, không gồm việc xong', () => expect(ids(TaskFilter.today), ['late', 'today']));
    test('Tuần này tới hết chủ nhật', () => expect(ids(TaskFilter.week), ['late', 'today', 'fri']));
    test('Quá hạn', () => expect(ids(TaskFilter.overdue), ['late']));
    test('Tôi giao: thẻ tôi tạo, người khác làm', () => expect(ids(TaskFilter.assignedByMe), ['gave']));
    test('Tất cả: việc của tôi, nhóm theo thời gian, xong ở cuối', () {
      final g = groupTasks(tasks, TaskFilter.all, 'me', now);
      expect([for (final x in g) x.$1], [DueBucket.overdue, DueBucket.today, DueBucket.thisWeek, DueBucket.later, DueBucket.none, DueBucket.done]);
      expect(ids(TaskFilter.all).last, 'done');
    });
    test('số đếm chỉ tính việc chưa xong', () {
      final c = filterCounts(tasks, 'me', now);
      expect(c[TaskFilter.today], 2);
      expect(c[TaskFilter.week], 3);
      expect(c[TaskFilter.overdue], 1);
      expect(c[TaskFilter.assignedByMe], 1);
      expect(c[TaskFilter.all], 5);
    });
    test('tóm tắt', () => expect(taskSummary(tasks, 'me', now), isNotEmpty));
  });

  test('trong nhóm: hạn gần trước, rồi ưu tiên cao', () {
    final d = DateTime(2026, 11, 6);
    final list = [task('lo', due: d, prio: 'lo'), task('hi', due: d, prio: 'hi'), task('none', due: d), task('early', due: DateTime(2026, 11, 5))];
    final g = groupTasks(list, TaskFilter.all, 'me', now);
    expect([for (final x in g) for (final t in x.$2) t.card.id], ['early', 'hi', 'lo', 'none']);
  });

  test('ngày chọn nhanh', () {
    expect(nextMonday(now), DateTime(2026, 11, 9));
    expect(weekendOf(now), DateTime(2026, 11, 7));
    expect(weekendOf(DateTime(2026, 11, 8, 9)), DateTime(2026, 11, 8), reason: 'chủ nhật: hôm nay');
    expect(endOfWeek(now), DateTime(2026, 11, 8));
    expect(addDays(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
  });

  test('dời hạn giữ giờ của hạn cũ', () {
    final old = DateProp.parse(DateProp.encode(DateTime(2026, 11, 4, 15, 30), includeTime: true));
    final v = DateProp.parse(dueValueFor(DateTime(2026, 11, 9), old))!;
    expect(v.includeTime, isTrue);
    expect(v.start, DateTime(2026, 11, 9, 15, 30));
    expect(DateProp.parse(dueValueFor(DateTime(2026, 11, 9), null))!.start, DateTime(2026, 11, 9));
  });

  test('xong / mở lại', () {
    expect(doneOptionOf(st)?.id, 'done');
    expect(reopenOptionOf(st, 'doing')?.id, 'doing');
    expect(reopenOptionOf(st, 'done')?.id, 'todo');
    expect(reopenOptionOf(st)?.id, 'todo');
    expect(doneOptionOf(const PropTemplate('x', 'Status', 'select', [PropOption('a', 'To do', '')])), isNull);
  });

  test('permalink tin nhắn', () {
    const server = 'https://chat.example.com';
    const id = 'abcdefghijklmnopqrstuvwxyz';
    expect(permalinkPostId(Uri.parse('$server/team/pl/$id'), server), id);
    expect(permalinkPostId(Uri.parse('https://other.example.com/team/pl/$id'), server), isNull);
    expect(permalinkPostId(Uri.parse('$server/boards/team/t/b'), server), isNull);
    expect(sourcePostIdIn(['> trích\n\n[Tin nhắn gốc]($server/team/pl/$id) · An'], server), id);
    expect(sourcePostIdIn(['không có link'], server), isNull);
  });

  test('tên việc từ tin nhắn', () {
    expect(taskTitleFromMessage('\n\n**Gửi báo giá** cho khách\nchi tiết sau'), 'Gửi báo giá cho khách');
    expect(taskTitleFromMessage('- mua mực in'), 'mua mực in');
    final long = taskTitleFromMessage('a' * 200, max: 50);
    expect(long.length, 50);
    expect(long.endsWith('…'), isTrue);
  });
}
