import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/api/boards_models.dart';
import 'package:flygo_chat/data/models.dart';
import 'package:flygo_chat/state/app_state.dart';
import 'package:flygo_chat/ui/tasks/quick_add.dart';
import 'package:flygo_chat/ui/tasks/task_chat.dart';
import 'package:flygo_chat/ui/tasks/task_tile.dart';
import 'package:flygo_chat/ui/tasks_view.dart';
import 'package:flygo_chat/ui/theme.dart';
import 'package:provider/provider.dart';

/// Giao diện tab Việc với dữ liệu giả (không gọi mạng): thẻ việc (bấm vòng tròn, vuốt), bảng thêm nhanh, thẻ việc trong chat,
/// màn hình Việc của tôi ở cỡ điện thoại / máy tính, sáng / tối.
void main() {
  const st = PropTemplate('s', 'Trạng thái', 'select', [PropOption('todo', 'Chưa làm', 'propColorGray'), PropOption('done', 'Xong', 'propColorGreen')]);
  const board = TaskBoard('b', 't', 'O', 'Việc chung', '', 'editor', [st, PropTemplate('a', 'Người làm', 'multiPerson'), PropTemplate('h', 'Hạn', 'date')]);
  final app = AppState('test')
    ..me = MmUser({'id': 'me', 'username': 'me', 'first_name': 'Tôi'})
    ..todos['my'] = [{}];
  app.users['me'] = app.me!;
  app.users['u2'] = MmUser({'id': 'u2', 'username': 'lan', 'first_name': 'Lan'});

  MyTask task(String id, {DateTime? due, String status = 'todo', List<String> who = const ['me'], int checks = 0, int done = 0}) => MyTask(
      board, TaskCard(id, 'b', 'Việc số $id cần làm trong tuần', '', 'me', {'s': status, 'a': who, 'h': ?(due == null ? null : DateProp.encode(due))}, const [], 0),
      checksTotal: checks, checksDone: done, comments: checks);

  Widget wrap(Widget child, {Brightness b = Brightness.light}) => ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(theme: buildTheme(b), home: Scaffold(body: child)),
      );

  group('TaskTile', () {
    testWidgets('bấm vòng tròn = đánh dấu xong; hiện tiến độ việc con', (t) async {
      var toggled = 0;
      final tk = task('1', due: DateTime.now(), checks: 5, done: 2);
      await t.pumpWidget(wrap(TaskTile(task: tk, onTap: () {}, onToggleDone: () => toggled++, onSnooze: () {})));
      expect(find.text('2/5'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
      await t.tap(find.byType(DoneCircle));
      await t.pump();
      expect(toggled, 1);
    });

    testWidgets('việc xong: vòng tròn đã tích, chữ gạch ngang', (t) async {
      await t.pumpWidget(wrap(TaskTile(task: task('2', status: 'done'), onTap: () {})));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });

    testWidgets('vuốt phải = xong, vuốt trái = dời hạn; thẻ vẫn ở lại', (t) async {
      var done = 0, snooze = 0;
      await t.pumpWidget(wrap(TaskTile(task: task('3', due: DateTime.now()), onTap: () {}, onToggleDone: () => done++, onSnooze: () => snooze++)));
      await t.drag(find.byType(Dismissible), const Offset(500, 0));
      await t.pumpAndSettle();
      expect(done, 1);
      expect(snooze, 0);
      await t.drag(find.byType(Dismissible), const Offset(-500, 0));
      await t.pumpAndSettle();
      expect(snooze, 1);
      expect(find.byType(TaskTile), findsOneWidget);
    });

    testWidgets('nhấn giữ mở menu', (t) async {
      var menu = 0;
      await t.pumpWidget(wrap(TaskTile(task: task('4'), onTap: () {}, onMenu: () => menu++)));
      await t.longPress(find.text('Việc số 4 cần làm trong tuần'));
      expect(menu, 1);
    });

    testWidgets('chip hạn quá hạn màu đỏ', (t) async {
      final now = DateTime(2026, 11, 4, 9);
      await t.pumpWidget(wrap(DueChip(DateTime(2026, 11, 2), now: now)));
      final icon = t.widget<Icon>(find.byIcon(Icons.error_outline_rounded));
      expect(icon.color, kTaskRed);
    });
  });

  group('QuickAddSheet', () {
    testWidgets('gõ tên, chọn hạn "Mai", bấm Thêm việc', (t) async {
      QuickAddDraft? got;
      await t.pumpWidget(wrap(QuickAddSheet(
        boards: const [board],
        onCreate: (d) async {
          got = d;
          return MyTask(d.board!, TaskCard('n', 'b', d.title, '', 'me', const {}, const [], 0));
        },
      )));
      final save = find.byKey(const ValueKey('quick-add-save'));
      expect(t.widget<FilledButton>(save).onPressed, isNull, reason: 'chưa có tên thì chưa bấm được');
      await t.enterText(find.byKey(const ValueKey('quick-add-title')), 'Gửi báo giá');
      await t.tap(find.text('Mai'));
      await t.pump();
      await t.tap(save);
      await t.pump();
      expect(got?.title, 'Gửi báo giá');
      expect(got?.board?.id, 'b');
      expect(got?.people, {'me'});
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      expect(got?.due, DateTime(tomorrow.year, tomorrow.month, tomorrow.day));
    });

    testWidgets('tạo từ chat: có công tắc "Báo vào cuộc chat", người làm điền sẵn', (t) async {
      await t.pumpWidget(wrap(QuickAddSheet(boards: const [board], title: 'Kiểm tra hợp đồng', people: const {'u2'}, channelId: 'c1', quote: 'Kiểm tra hợp đồng giúp anh')));
      expect(find.text('Báo vào cuộc chat'), findsOneWidget);
      expect(find.text('Lan'), findsWidgets);
      expect(find.text('Kiểm tra hợp đồng giúp anh'), findsOneWidget);
    });
  });

  testWidgets('thẻ việc trong chat', (t) async {
    final post = MmPost({
      'id': 'p1', 'channel_id': 'c1', 'user_id': 'me', 'message': 'x', 'create_at': 0,
      'props': {
        'flygo_task': {
          'v': 1, 'kind': 'digest',
          'items': [
            {'board_id': 'b', 'card_id': 'c1', 'title': 'Gửi báo giá', 'due': DateProp.encode(DateTime.now()), 'assignees': ['me']},
            {'board_id': 'b', 'card_id': 'c2', 'title': 'Họp khách', 'assignees': ['u2']},
          ],
        },
      },
    });
    await t.pumpWidget(wrap(TaskPostCard(app: app, post: post, width: 320)));
    expect(find.text('Việc hôm nay của bạn'), findsOneWidget);
    expect(find.text('Gửi báo giá'), findsOneWidget);
    expect(find.text('Họp khách'), findsOneWidget);
  });

  group('Việc của tôi', () {
    final now = DateTime.now();
    final tasks = [
      task('a', due: now.subtract(const Duration(days: 2))),
      task('b', due: now, checks: 4, done: 1),
      task('c', due: now.add(const Duration(days: 1))),
      task('d'),
      task('e', status: 'done'),
    ];
    for (final size in const [Size(390, 844), Size(1300, 900)]) {
      for (final b in Brightness.values) {
        testWidgets('dựng ${size.width.toInt()} ${b.name}', (t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          debugSeedTasks(const [board], [...tasks]);
          await t.pumpWidget(wrap(const TasksView(header: SizedBox(height: 8), bottomPadding: 0, fabBottom: 16), b: b));
          await t.pump(const Duration(milliseconds: 50));
          expect(t.takeException(), isNull);
          expect(find.text('Quá hạn'), findsWidgets);
          expect(find.text('Hôm nay'), findsWidgets);
          // Lọc "Quá hạn": chỉ còn việc a.
          final chip = find.descendant(of: find.byType(ListView).first, matching: find.text('Quá hạn')).first;
          await t.ensureVisible(chip);
          await t.pump();
          await t.tap(chip);
          await t.pump();
          expect(find.byType(TaskTile), findsOneWidget);
          await t.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });
}
