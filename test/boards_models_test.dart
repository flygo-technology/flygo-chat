import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/api/boards_api.dart';

void main() {
  const st = PropTemplate('s', 'Status', 'select', [PropOption('o1', 'Todo', ''), PropOption('o2', 'Done', '')]);
  const pts = PropTemplate('n', 'Points', 'number');
  const due = PropTemplate('d', 'Due', 'date');
  const board = TaskBoard('b', 't', 'O', 'B', '', 'editor', [st, pts, due]);
  TaskCard card(String id, String title, Map<String, dynamic> p, {int createAt = 0}) =>
      TaskCard(id, 'b', title, '', 'u', p, const [], 0, createAt: createAt);
  final a = card('a', 'Alpha', {'s': 'o2', 'n': '5', 'd': DateProp.encode(DateTime(2026, 10, 20))});
  final b = card('b', 'beta', {'s': 'o1', 'n': '12'});
  final c = card('c', '', {'n': '1'}, createAt: 5);

  BoardView view(Map<String, dynamic> f) => BoardView(BoardBlock('v', 'b', 'b', 'view', 'V', {...BoardView.defaultFields('board'), ...f}));

  test('filter includes / isEmpty / contains / date', () {
    bool met(Map<String, dynamic> g, TaskCard x) => filterMet(FilterGroup.fromJson(g), board.props, x);
    final inc = {'operation': 'and', 'filters': [{'propertyId': 's', 'condition': 'includes', 'values': ['o1']}]};
    expect([a, b, c].where((x) => met(inc, x)).map((x) => x.id), ['b']);
    final empty = {'operation': 'and', 'filters': [{'propertyId': 's', 'condition': 'isEmpty', 'values': []}]};
    expect([a, b, c].where((x) => met(empty, x)).map((x) => x.id), ['c']);
    final or = {'operation': 'or', 'filters': [
      {'propertyId': 'title', 'condition': 'contains', 'values': ['alp']},
      {'propertyId': 's', 'condition': 'includes', 'values': ['o1']},
    ]};
    expect([a, b, c].where((x) => met(or, x)).map((x) => x.id), ['a', 'b']);
    final before = {'operation': 'and', 'filters': [{'propertyId': 'd', 'condition': 'isBefore', 'values': ['${DateTime.utc(2026, 10, 21).millisecondsSinceEpoch}']}]};
    expect([a, b, c].where((x) => met(before, x)).map((x) => x.id), ['a']);
  });

  test('sort: manual order, number, select, title', () {
    expect(sortCards([a, b, c], board, view({'cardOrder': ['b', 'a']})).map((x) => x.id), ['b', 'a', 'c']);
    expect(sortCards([a, b, c], board, view({'sortOptions': [{'propertyId': 'n', 'reversed': true}]})).map((x) => x.id), ['b', 'a', 'c']);
    expect(sortCards([a, b, c], board, view({'sortOptions': [{'propertyId': 's', 'reversed': false}]})).map((x) => x.id), ['b', 'a', 'c']);
    expect(sortCards([c, b, a], board, view({'sortOptions': [{'propertyId': kTitleColumn, 'reversed': false}]})).map((x) => x.id), ['a', 'b', 'c']);
  });

  test('new card meets view filter', () {
    final g = FilterGroup.fromJson({'operation': 'and', 'filters': [{'propertyId': 's', 'condition': 'includes', 'values': ['o2']}]});
    expect(propsMeetingFilter(g, board.props), {'s': 'o2'});
  });

  test('date value round trip and range', () {
    final v = DateProp.encode(DateTime(2026, 3, 4), end: DateTime(2026, 3, 6));
    final d = DateProp.parse(v)!;
    expect(d.start, DateTime(2026, 3, 4));
    expect(d.end, DateTime(2026, 3, 6));
    expect(DateProp.parse('${DateTime.utc(2026, 1, 2).millisecondsSinceEpoch}')!.start, DateTime(2026, 1, 2));
    expect(DateProp.parse(''), isNull);
  });

  test('card from block form and nested content order', () {
    final k = TaskCard.fromJson({
      'id': 'k', 'boardId': 'b', 'title': 'T', 'type': 'card',
      'fields': {'icon': '🔥', 'properties': {'s': 'o1'}, 'contentOrder': ['x', ['y', 'z']]},
    });
    expect(k.icon, '🔥');
    expect(k.str('s'), 'o1');
    expect(k.contentOrder, ['x', 'y', 'z']);
  });

  test('boards links', () {
    expect(parseBoardsPath(Uri.parse('https://chat.example.com/boards/team/t1/b1/v1/c1')), ('b1', 'v1', 'c1'));
    expect(parseBoardsPath(Uri.parse('https://chat.example.com/boards/team/t1/b1')), ('b1', null, null));
    expect(parseBoardsPath(Uri.parse('https://chat.example.com/boards/team/t1/shared/b1/v1')), ('b1', 'v1', null));
    expect(parseBoardsPath(Uri.parse('https://chat.example.com/boards')), isNull);
  });

  test('member roles', () {
    expect(const BoardMember('b', 'u', admin: true).role, 'admin');
    expect(const BoardMember('b', 'u', minimumRole: 'commenter').role, 'commenter');
    expect(roleAtLeast('editor', 'commenter'), isTrue);
    expect(roleAtLeast('viewer', 'editor'), isFalse);
    expect(BoardMember.roleJson('b', 'u', 'commenter')['schemeEditor'], isFalse);
  });
}
