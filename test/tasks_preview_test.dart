// Ảnh xem trước tab Việc (chạy tay): TASKS_OUT=<thư mục> flutter test test/tasks_preview_test.dart
// Cần phông Roboto + MaterialIcons trong bộ nhớ đệm của Flutter (bin/cache/artifacts/material_fonts).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/api/boards_models.dart';
import 'package:flygo_chat/data/models.dart';
import 'package:flygo_chat/state/app_state.dart';
import 'package:flygo_chat/ui/boards/board_store.dart';
import 'package:flygo_chat/ui/boards/card_detail.dart';
import 'package:flygo_chat/ui/tasks/quick_add.dart';
import 'package:flygo_chat/ui/tasks/task_chat.dart';
import 'package:flygo_chat/ui/tasks_view.dart';
import 'package:flygo_chat/ui/theme.dart';
import 'package:provider/provider.dart';

Future<void> _fonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/tools/flutter'}/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final b = File('$dir/$f');
      if (b.existsSync()) l.addFont(Future.value(ByteData.sublistView(b.readAsBytesSync())));
    }
    await l.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

void main() {
  final out = Platform.environment['TASKS_OUT'];
  const st = PropTemplate('s', 'Trạng thái', 'select', [
    PropOption('todo', 'Chưa làm', 'propColorGray'),
    PropOption('doing', 'Đang làm', 'propColorBlue'),
    PropOption('review', 'Chờ duyệt', 'propColorYellow'),
    PropOption('done', 'Xong', 'propColorGreen'),
  ]);
  const pr = PropTemplate('p', 'Ưu tiên', 'select', [PropOption('hi', 'Cao', 'propColorRed'), PropOption('mid', 'Trung bình', 'propColorYellow')]);
  const props = [st, PropTemplate('a', 'Người làm', 'multiPerson'), PropTemplate('h', 'Hạn', 'date'), pr];
  const b1 = TaskBoard('b1', 't', 'O', 'Việc chung', '', 'editor', props);
  const b2 = TaskBoard('b2', 't', 'O', 'Kinh doanh', '', 'editor', props);
  final app = AppState('test')
    ..me = MmUser({'id': 'me', 'username': 'ba', 'first_name': 'Ba'})
    ..todos['my'] = [{}, {}];
  for (final (id, n) in [('me', 'Ba'), ('u2', 'Lan'), ('u3', 'Minh')]) {
    app.users[id] = MmUser({'id': id, 'username': n.toLowerCase(), 'first_name': n});
  }
  final now = DateTime.now();
  MyTask t(TaskBoard b, String id, String title, {DateTime? due, String s = 'todo', List<String> who = const ['me'], String? p, int c = 0, int d = 0, int cm = 0, String by = 'me'}) =>
      MyTask(b, TaskCard(id, b.id, title, '', by, {'s': s, 'a': who, 'h': ?(due == null ? null : DateProp.encode(due)), 'p': ?p}, const [], 0),
          checksTotal: c, checksDone: d, comments: cm);
  final tasks = [
    t(b2, '1', 'Gửi báo giá thang máy cho khách Hải Phòng', due: now.subtract(const Duration(days: 2)), s: 'doing', p: 'hi', c: 5, d: 2, cm: 3),
    t(b1, '2', 'Chốt lịch bảo trì tháng 11', due: now, who: ['me', 'u2'], cm: 1),
    t(b1, '3', 'Duyệt hồ sơ nhập khẩu lô linh kiện', due: now, s: 'review', p: 'mid'),
    t(b2, '4', 'Gọi lại cho anh Minh về hợp đồng', due: now.add(const Duration(days: 1))),
    t(b1, '5', 'Cập nhật bảng giá phụ tùng', due: now.add(const Duration(days: 9)), c: 3, d: 3),
    t(b1, '6', 'Đọc tài liệu quy trình mới'),
    t(b1, '7', 'Nộp báo cáo tuần', s: 'done'),
    t(b2, '8', 'Lan soạn hợp đồng mẫu', due: now.add(const Duration(days: 2)), who: ['u2']),
  ];

  Future<void> shot(WidgetTester tester, String name, Size size, Brightness b, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        home: RepaintBoundary(key: key, child: child),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('ảnh xem trước tab Việc', (tester) async {
    if (out == null) return;
    await tester.runAsync(_fonts);
    for (final b in Brightness.values) {
      debugSeedTasks(const [b1, b2], [...tasks]);
      await shot(tester, 'tasks-${b.name}', const Size(390, 1100), b,
          const Scaffold(body: SafeArea(child: TasksView(header: SizedBox(height: 4), bottomPadding: 0, fabBottom: 16))));
    }
    debugSeedTasks(const [b1, b2], [...tasks]);
    await shot(tester, 'tasks-desktop', const Size(1200, 900), Brightness.light,
        const Scaffold(body: TasksView(header: SizedBox(height: 4), bottomPadding: 0, fabBottom: 16)));
    await shot(tester, 'quick-add', const Size(390, 760), Brightness.light,
        Scaffold(body: Align(alignment: Alignment.bottomCenter, child: Material(child: QuickAddSheet(boards: const [b1, b2], title: 'Kiểm tra hợp đồng', people: const {'u2'}, channelId: 'c', quote: 'Em kiểm tra giúp anh hợp đồng này nhé')))));
    final s = BoardStore(app.api, 'b1', 'me')
      ..board = b1
      ..loaded = true;
    s.cards['c1'] = TaskCard('c1', 'b1', 'Gửi báo giá thang máy cho khách Hải Phòng', '', 'u3',
        {'s': 'doing', 'a': ['me'], 'h': DateProp.encode(now.subtract(const Duration(days: 1))), 'p': 'hi'}, const ['t1', 'x1', 'x2', 'x3'], 0);
    s.blocks['t1'] = const BoardBlock('t1', 'b1', 'c1', 'text', 'Khách cần **báo giá 2 phương án** trước thứ 6.\n\n[Tin nhắn gốc](https://chat.example.com/team/pl/abcdefghijklmnopqrstuvwxyz) · Minh', {});
    s.blocks['x1'] = const BoardBlock('x1', 'b1', 'c1', 'checkbox', 'Lấy giá nhà cung cấp', {'value': true});
    s.blocks['x2'] = const BoardBlock('x2', 'b1', 'c1', 'checkbox', 'Tính chi phí lắp đặt', {'value': false});
    s.blocks['x3'] = const BoardBlock('x3', 'b1', 'c1', 'checkbox', 'Gửi file cho khách', {'value': false});
    s.blocks['m1'] = BoardBlock('m1', 'b1', 'c1', 'comment', 'Anh gửi trước 5h chiều nhé', const {}, createdBy: 'u3', createAt: now.millisecondsSinceEpoch);
    s.blocks['m2'] = BoardBlock('m2', 'b1', 'c1', 'comment', 'Dạ em gửi ạ', const {}, createdBy: 'me', createAt: now.millisecondsSinceEpoch);
    for (final b in Brightness.values) {
      await shot(tester, 'detail-${b.name}', const Size(390, 1000), b, Scaffold(body: SafeArea(child: CardDetail(store: s, cardId: 'c1'))));
    }
    await shot(tester, 'detail-edit', const Size(390, 1000), Brightness.light, Scaffold(body: SafeArea(child: CardDetail(store: s, cardId: 'c1', editing: true))));
    final post = MmPost({
      'id': 'p1', 'channel_id': 'c1', 'user_id': 'me', 'message': 'x', 'create_at': 0,
      'props': {
        'flygo_task': {
          'v': 1, 'kind': 'assigned', 'by': 'me',
          'items': [{'board_id': 'b1', 'card_id': 'c1', 'title': 'Kiểm tra hợp đồng mua bán', 'due': DateProp.encode(now.add(const Duration(days: 1))), 'assignees': ['u2']}],
        },
      },
    });
    await shot(tester, 'chat-card', const Size(390, 260), Brightness.dark, Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: TaskPostCard(app: app, post: post, width: 320))));
    s.dispose();
  });
}
