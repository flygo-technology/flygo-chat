import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/api/boards_api.dart';
import 'package:flygo_chat/state/app_state.dart';
import 'package:flygo_chat/ui/boards/board_store.dart';
import 'package:flygo_chat/ui/boards/calendar_view.dart';
import 'package:flygo_chat/ui/boards/card_detail.dart';
import 'package:flygo_chat/ui/boards/gallery_view.dart';
import 'package:flygo_chat/ui/boards/kanban_view.dart';
import 'package:flygo_chat/ui/boards/table_view.dart';
import 'package:flygo_chat/ui/boards/view_options.dart';
import 'package:flygo_chat/ui/theme.dart';
import 'package:provider/provider.dart';

/// Dựng thử các view của Boards với dữ liệu giả (không gọi mạng) ở cỡ điện thoại và máy tính: không lỗi bố cục.
void main() {
  const st = PropTemplate('s', 'Status', 'select', [PropOption('o1', 'Todo', 'propColorGray'), PropOption('o2', 'Done', 'propColorGreen')]);
  const props = [st, PropTemplate('n', 'Points', 'number'), PropTemplate('d', 'Due', 'date'), PropTemplate('k', 'OK', 'checkbox'), PropTemplate('u', 'Link', 'url')];
  final app = AppState('test');

  BoardStore store() {
    final s = BoardStore(app.api, 'b', 'me')
      ..board = const TaskBoard('b', 't', 'O', 'Board', '🧪', 'editor', props)
      ..loaded = true;
    s.views = [
      for (final t in ['board', 'table', 'calendar', 'gallery'])
        BoardView(BoardBlock('v$t', 'b', 'b', 'view', t, BoardView.defaultFields(t, groupById: 's', dateId: 'd', visible: ['s', 'n', 'd', 'k', 'u']))),
    ];
    final now = DateTime.now();
    for (var i = 0; i < 12; i++) {
      s.cards['c$i'] = TaskCard('c$i', 'b', i == 3 ? '' : 'Card number $i with a fairly long title', i.isEven ? '🔥' : '',
          'me', {'s': i % 3 == 0 ? 'o1' : (i % 3 == 1 ? 'o2' : ''), 'n': '$i', 'd': DateProp.encode(DateTime(now.year, now.month, 1 + i)), 'k': i.isEven ? 'true' : '', 'u': 'example.com'},
          i == 0 ? ['t1', 'x1'] : const [], 0, createAt: i);
    }
    s.blocks['t1'] = const BoardBlock('t1', 'b', 'c0', 'text', '**Hello** world', {});
    s.blocks['x1'] = const BoardBlock('x1', 'b', 'c0', 'checkbox', 'Sub task', {'value': true});
    s.blocks['m1'] = const BoardBlock('m1', 'b', 'c0', 'comment', 'A comment', {}, createdBy: 'me', createAt: 1);
    return s;
  }

  Future<void> pump(WidgetTester t, Size size, Widget Function(BoardStore s) build) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = store();
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: build(s))),
    ));
    await t.pump(const Duration(milliseconds: 50));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    s.dispose();
  }

  for (final size in const [Size(390, 844), Size(1400, 900)]) {
    final tag = size.width < 600 ? 'phone' : 'desktop';
    testWidgets('kanban $tag', (t) => pump(t, size, (s) {
          final v = s.view('vboard')!;
          return KanbanView(store: s, view: v, cards: s.cardsFor(v), onOpen: (_) {}, onAdd: (_) async {});
        }));
    testWidgets('table $tag', (t) => pump(t, size, (s) {
          final v = s.view('vtable')!;
          return TableView(store: s, view: v, cards: s.cardsFor(v), onOpen: (_) {}, onAdd: () {});
        }));
    testWidgets('calendar $tag', (t) => pump(t, size, (s) {
          final v = s.view('vcalendar')!;
          return CalendarView(store: s, view: v, cards: s.cardsFor(v), onOpen: (_) {}, onAdd: (_) async {});
        }));
    testWidgets('gallery $tag', (t) => pump(t, size, (s) {
          final v = s.view('vgallery')!;
          return GalleryView(store: s, view: v, cards: s.cardsFor(v), onOpen: (_) {}, onAdd: () {});
        }));
    testWidgets('card detail $tag', (t) => pump(t, size, (s) => CardDetail(store: s, cardId: 'c0')));
    testWidgets('filter + sort sheets $tag', (t) => pump(t, size, (s) {
          final v = s.view('vtable')!;
          return Column(children: [
            Expanded(child: FilterSheet(store: s, view: v)),
            SortSheet(store: s, view: v),
          ]);
        }));
  }
}
