import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/api/boards_models.dart';
import 'package:flygo_chat/data/models.dart';
import 'package:flygo_chat/state/app_state.dart';
import 'package:flygo_chat/ui/boards/card_detail.dart' show CardPage;
import 'package:flygo_chat/ui/tasks/board_picker.dart';
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

  group('Lọc theo bảng', () {
    const board2 = TaskBoard('b2', 't', 'O', 'Kinh doanh', '💼', 'editor', [st, PropTemplate('a', 'Người làm', 'multiPerson'), PropTemplate('h', 'Hạn', 'date')]);
    MyTask on(TaskBoard b, String id, {List<String> who = const ['me'], String status = 'todo'}) =>
        MyTask(b, TaskCard(id, b.id, 'Việc $id', '', 'u2', {'s': status, 'a': who}, const [], 0));
    final tasks = [
      on(board, '1'),
      on(board, '2', who: ['u2']),
      on(board2, '3'),
      on(board2, '4', who: ['u2']),
      on(board2, '5', who: ['u2']),
      on(board2, '6', status: 'done'),
    ];

    Future<void> phone(WidgetTester t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
    }

    testWidgets('bảng dưới liệt kê bảng kèm số việc; chọn bảng thì lọc', (t) async {
      await phone(t);
      debugSeedTasks(const [board, board2], [...tasks]);
      await t.pumpWidget(wrap(const TasksView(header: SizedBox(height: 8), bottomPadding: 0, fabBottom: 16)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('tasks-boards-button')));
      await t.pumpAndSettle();
      expect(find.byType(BoardPickerSheet), findsOneWidget);
      expect(find.text('Tất cả bảng'), findsOneWidget);
      // Việc chung: 1 của tôi / 2 đang mở; Kinh doanh: 1 của tôi / 3 đang mở (việc xong không tính).
      expect(find.text('1 việc của bạn · 2 đang mở'), findsOneWidget);
      expect(find.text('1 việc của bạn · 3 đang mở'), findsOneWidget);
      expect(find.text('2 việc của bạn đang mở'), findsOneWidget);
      expect(find.text('Tạo bảng mới'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('board-pick-b2')));
      await t.pumpAndSettle();
      expect(find.byType(BoardPickerSheet), findsNothing);
      // Mặc định "Tất cả" việc của bảng: 3 việc đang mở + nhóm Đã xong (đang ẩn).
      expect(find.byKey(const ValueKey('board-filter-chip')), findsOneWidget);
      expect(find.text('Bảng: Kinh doanh'), findsOneWidget);
      expect(find.byType(TaskTile), findsNWidgets(3));
      // "Của tôi": chỉ còn việc 3.
      await t.tap(find.byKey(const ValueKey('board-scope-mine')));
      await t.pump();
      expect(find.byType(TaskTile), findsOneWidget);
      expect(find.text('Việc 3'), findsOneWidget);
      // Bỏ lọc bảng: về việc của tôi trên mọi bảng (1 và 3).
      await t.tap(find.byTooltip('Bỏ lọc bảng'));
      await t.pump();
      expect(find.byKey(const ValueKey('board-filter-chip')), findsNothing);
      expect(find.byType(TaskTile), findsNWidgets(2));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('bấm một việc mở trang chi tiết toàn màn hình', (t) async {
      await phone(t);
      debugSeedTasks(const [board, board2], [...tasks], boardId: 'b2');
      await t.pumpWidget(wrap(const TasksView(header: SizedBox(height: 8), bottomPadding: 0, fabBottom: 16)));
      await t.pump();
      await t.tap(find.text('Việc 4'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(CardPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final route = ModalRoute.of(t.element(find.byType(CardPage)));
      expect(route, isA<PageRoute<dynamic>>());
      expect(route!.isCurrent, isTrue);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
