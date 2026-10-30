import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/panes/pane_layout.dart';

const a = PaneContent.chat('a'), b = PaneContent.chat('b'), c = PaneContent.chat('c'), d = PaneContent.chat('d');
const e = PaneContent.chat('e');
const agents = PaneContent.section(PaneSections.agents);

List<PaneContent?> contents(PaneLayout l) => [for (final x in l.leaves) x.content];

void main() {
  test('starts with one empty pane, open fills the focused pane', () {
    final l = PaneLayout();
    expect(l.count, 1);
    expect(l.focused.content, isNull);
    l.open(a);
    expect(contents(l), [a]);
    l.open(b);
    expect(contents(l), [b], reason: 'one pane: opening replaces it like before');
  });

  test('split on every edge keeps reading order', () {
    final l = PaneLayout()..open(a);
    final p1 = l.focusedId;
    l.split(p1, PaneEdge.right, b);
    expect(contents(l), [a, b]);
    expect((l.root as PaneSplit).horizontal, isTrue);
    l.split(p1, PaneEdge.left, c);
    expect(contents(l), [c, a, b]);
    final pb = l.find(b)!.id;
    l.split(pb, PaneEdge.bottom, d);
    expect(contents(l), [c, a, b, d]);
    expect(l.focused.content, d, reason: 'the new pane gets focus');
  });

  test('max 4 panes: split refused, drop on edge falls back to nothing, center replaces', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.split(l.find(a)!.id, PaneEdge.bottom, c);
    l.split(l.find(b)!.id, PaneEdge.bottom, d);
    expect(l.count, 4);
    expect(l.isFull, isTrue);
    expect(l.split(l.find(a)!.id, PaneEdge.right, e), isNull);
    expect(l.canSplitWith(e), isFalse);
    expect(l.canSplitWith(a), isTrue, reason: 'moving an existing pane keeps the count');
    expect(l.drop(l.find(a)!.id, PaneEdge.center, e), isTrue);
    expect(l.find(e), isNotNull);
    expect(l.find(a), isNull);
    expect(l.count, 4);
  });

  test('2x2 grid from json and back', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.split(l.find(a)!.id, PaneEdge.bottom, c);
    l.split(l.find(b)!.id, PaneEdge.bottom, d);
    final s = l.root as PaneSplit;
    expect(s.horizontal, isTrue);
    expect((s.first as PaneSplit).horizontal, isFalse);
    expect((s.second as PaneSplit).horizontal, isFalse);
    l.setRatio(s.id, .3);
    l.focus(l.find(c)!.id);
    final r = PaneLayout.fromJson(jsonDecode(jsonEncode(l.toJson())));
    expect(contents(r), [a, c, b, d]);
    expect((r.root as PaneSplit).ratio, closeTo(.3, 1e-9));
    expect(r.focused.content, c);
    expect([for (final x in r.leaves) x.id], [for (final x in l.leaves) x.id], reason: 'pane ids survive a restart');
  });

  test('close removes the pane, sibling takes its place, focus goes to the last used pane', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.split(l.find(b)!.id, PaneEdge.bottom, c);
    l.focus(l.find(a)!.id);
    l.focus(l.find(c)!.id);
    l.close(l.find(c)!.id);
    expect(contents(l), [a, b]);
    expect(l.focused.content, a);
    l.close(l.find(a)!.id);
    expect(contents(l), [b]);
    expect(l.root, isA<PaneLeaf>());
    l.close(l.focusedId);
    expect(l.count, 1, reason: 'the last pane only becomes empty');
    expect(l.focused.content, isNull);
  });

  test('move: center swaps, edge relocates and keeps the pane object', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.split(l.find(b)!.id, PaneEdge.right, c);
    final pa = l.find(a)!;
    expect(l.move(pa.id, l.find(c)!.id, PaneEdge.center), isTrue);
    expect(contents(l), [c, b, a]);
    expect(identical(l.find(a), pa), isTrue);
    expect(l.move(pa.id, l.find(c)!.id, PaneEdge.top), isTrue);
    expect(contents(l), [a, c, b]);
    expect(identical(l.find(a), pa), isTrue);
    expect(l.count, 3);
    expect(l.move(pa.id, pa.id, PaneEdge.left), isFalse);
  });

  test('swapping siblings of the same split', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.move(l.find(a)!.id, l.find(b)!.id, PaneEdge.center);
    expect(contents(l), [b, a]);
  });

  test('a conversation is never shown in two panes', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.open(a);
    expect(contents(l), [a, b]);
    expect(l.focused.content, a);
    // Kéo chat đang có ở ô khác vào cạnh một ô: chuyển ô đó, không nhân đôi.
    l.drop(l.find(b)!.id, PaneEdge.bottom, a);
    expect(contents(l).where((x) => x == a).length, 1);
    expect(l.count, 2);
  });

  test('opening from a list pane keeps the list and reuses the last chat pane', () {
    final l = PaneLayout()..open(agents);
    final list = l.focusedId;
    final t = l.openFrom(list, a);
    expect(contents(l), [agents, a], reason: 'no chat pane yet: split the list pane');
    l.focus(list);
    final t2 = l.openFrom(list, b);
    expect(t2.id, t.id);
    expect(contents(l), [agents, b]);
    expect(l.focused.content, b);
  });

  test('prune drops conversations that no longer exist', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.split(l.find(b)!.id, PaneEdge.bottom, agents);
    l.prune((x) => x != b);
    expect(contents(l), [a, agents]);
  });

  test('maximize survives json, reset when only one pane', () {
    final l = PaneLayout()..open(a);
    l.split(l.focusedId, PaneEdge.right, b);
    l.toggleMaximize(l.find(b)!.id);
    final r = PaneLayout.fromJson(jsonDecode(jsonEncode(l.toJson())));
    expect(r.maximizedId, r.find(b)!.id);
    r.close(r.find(b)!.id);
    expect(r.maximizedId, isNull);
  });

  test('fromJson tolerates garbage, too many panes and duplicate ids', () {
    expect(PaneLayout.fromJson(null).count, 1);
    expect(PaneLayout.fromJson('x').count, 1);
    expect(PaneLayout.fromJson({'root': 5}).count, 1);
    Map<String, Object?> leaf(String id, String c) => {'id': id, 'c': c};
    Map<String, Object?> split(Object a, Object b) => {'id': 's', 'h': true, 'r': 9, 'a': a, 'b': b};
    final j = {
      'root': split(split(leaf('p1', 'chat:a'), leaf('p1', 'chat:b')), split(leaf('p3', 'section:bogus'), split(leaf('p4', 'chat:d'), leaf('p5', 'chat:e')))),
      'focus': 'nope',
    };
    final l = PaneLayout.fromJson(j);
    expect(l.count, 4);
    expect(contents(l), [a, b, null, d]);
    expect({for (final x in l.leaves) x.id}.length, 4);
    expect((l.root as PaneSplit).ratio, PaneLayout.maxRatio);
    expect(l.leaf(l.focusedId), isNotNull);
    // Id mới không trùng id đã đọc.
    l.close(l.leaves[2].id);
    final n = l.split(l.leaves.first.id, PaneEdge.left, e)!;
    expect(l.leaves.where((x) => x.id == n.id).length, 1);
  });

  test('content keys round-trip', () {
    expect(PaneContent.parse(a.key), a);
    expect(PaneContent.parse(agents.key), agents);
    expect(PaneContent.parse('section:nope'), isNull);
    expect(PaneContent.parse('chat:'), isNull);
    expect(PaneSections.ofTab(PaneSections.tabOf(PaneSections.tasks)), PaneSections.tasks);
  });
}
