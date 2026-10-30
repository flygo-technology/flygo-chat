import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/panes/pane_layout.dart';
import 'package:flygo_chat/ui/panes/pane_view.dart';
import 'package:flygo_chat/ui/theme.dart';

/// Vùng chia ô dựng từ bố cục, kéo thả vào các vùng trái / phải / giữa, nút đóng ô.
void main() {
  late PaneLayout layout;
  final keys = <String, GlobalKey>{};
  final drops = <(String, PaneEdge, PaneContent)>[];
  final closed = <String>[];

  Widget app(void Function(void Function()) rebuild) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: PaneHost(
            describe: (c) => PaneLabel('T-${c.id}', const Icon(Icons.chat)),
            canPopOut: false,
            popOut: (_) {},
            child: Row(children: [
              SizedBox(
                width: 200,
                child: PaneDragSource(
                  content: const PaneContent.chat('x'),
                  child: Container(key: const Key('src'), height: 60, color: Colors.amber),
                ),
              ),
              Expanded(
                child: StatefulBuilder(
                  builder: (context, setState) => PaneArea(
                    layout: layout,
                    keyOf: (id) => keys.putIfAbsent(id, GlobalKey.new),
                    body: (_, l) => Column(children: [
                      Text('body-${l.content?.id ?? 'empty'}'),
                      SizedBox(width: 150, child: TextField(key: ValueKey('tf-${l.content?.id}'))),
                    ]),
                    describe: (c) => PaneLabel('T-${c.id}', const Icon(Icons.chat)),
                    unread: (_) => false,
                    onFocus: (id) => setState(() => layout.focus(id)),
                    onDrop: (t, e, d) => setState(() {
                      drops.add((t, e, d.content));
                      layout.drop(t, e, d.content, fromPane: d.fromPane);
                    }),
                    onClose: (id) => setState(() {
                      closed.add(id);
                      layout.close(id);
                    }),
                    onMaximize: (id) => setState(() => layout.toggleMaximize(id)),
                    onRatio: (s, r) => setState(() => layout.setRatio(s, r)),
                    onRatioEnd: () {},
                  ),
                ),
              ),
            ]),
          ),
        ),
      );

  setUp(() {
    layout = PaneLayout()..open(const PaneContent.chat('a'));
    keys.clear();
    drops.clear();
    closed.clear();
  });

  Future<void> dragTo(WidgetTester t, Offset to) async {
    final g = await t.startGesture(t.getCenter(find.byKey(const Key('src'))));
    await g.moveBy(const Offset(30, 0));
    await t.pump();
    await g.moveTo(to);
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
  }

  testWidgets('one pane: no header; drop on the right edge splits side by side', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app((f) => f()));
    expect(find.text('body-a'), findsOneWidget);
    expect(find.byTooltip('Đóng ô'), findsNothing);
    final area = t.getRect(find.byType(PaneArea));
    await dragTo(t, Offset(area.right - 20, area.center.dy));
    expect(drops.single.$2, PaneEdge.right);
    expect([for (final l in layout.leaves) l.content?.id], ['a', 'x']);
    expect(find.text('body-x'), findsOneWidget);
    // Hai ô: có đầu ô với nút đóng.
    expect(find.byTooltip('Đóng ô'), findsNWidgets(2));
    expect(find.text('T-x'), findsOneWidget);
  });

  testWidgets('drop in the middle replaces, close button removes a pane', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    layout.split(layout.focusedId, PaneEdge.bottom, const PaneContent.chat('b'));
    await t.pumpWidget(app((f) => f()));
    final top = t.getRect(find.ancestor(of: find.text('body-a'), matching: find.byType(DragTarget<PaneDragData>)));
    await dragTo(t, top.center);
    expect(drops.single.$2, PaneEdge.center);
    expect([for (final l in layout.leaves) l.content?.id], ['x', 'b']);
    await t.tap(find.byTooltip('Đóng ô').last);
    await t.pumpAndSettle();
    expect(layout.count, 1);
    expect(find.text('body-x'), findsOneWidget);
    expect(find.byTooltip('Đóng ô'), findsNothing);
  });

  testWidgets('full layout: edges only replace', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    layout.split(layout.focusedId, PaneEdge.right, const PaneContent.chat('b'));
    layout.split(layout.find(const PaneContent.chat('a'))!.id, PaneEdge.bottom, const PaneContent.chat('c'));
    layout.split(layout.find(const PaneContent.chat('b'))!.id, PaneEdge.bottom, const PaneContent.chat('d'));
    await t.pumpWidget(app((f) => f()));
    final r = t.getRect(find.ancestor(of: find.text('body-a'), matching: find.byType(DragTarget<PaneDragData>)));
    await dragTo(t, Offset(r.left + 6, r.center.dy));
    expect(drops.single.$2, PaneEdge.center);
    expect(layout.count, 4);
    expect(layout.find(const PaneContent.chat('x')), isNotNull);
  });

  testWidgets('splitting, moving and maximizing keep the pane state (text being typed)', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app((f) => f()));
    await t.enterText(find.byKey(const ValueKey('tf-a')), 'nháp dở');
    final area = t.getRect(find.byType(PaneArea));
    await dragTo(t, Offset(area.center.dx, area.bottom - 10));
    expect(layout.count, 2);
    expect(find.text('nháp dở'), findsOneWidget, reason: 'the first pane moved into a split without being rebuilt');
    await t.tap(find.byTooltip('Phóng to ô').first);
    await t.pumpAndSettle();
    expect(layout.maximizedId, isNotNull);
    await t.tap(find.byTooltip('Thu nhỏ ô'));
    await t.pumpAndSettle();
    expect(find.text('nháp dở'), findsOneWidget);
    layout.move(layout.find(const PaneContent.chat('a'))!.id, layout.find(const PaneContent.chat('x'))!.id, PaneEdge.center);
    await t.pumpWidget(app((f) => f()));
    expect([for (final l in layout.leaves) l.content?.id], ['x', 'a']);
    expect(find.text('nháp dở'), findsOneWidget);
  });
}
