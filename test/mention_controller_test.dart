import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/mention_controller.dart';

void main() {
  MentionTextController make() => MentionTextController(isKnown: (u) => u == 'ba-claude' || u == 'buinam');
  TextEditingValue v(String t, int c) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: c));

  test('backspace at end of a mention removes the whole tag', () {
    final c = make()..value = v('hi @ba-claude ', 13);
    c.value = v('hi @ba-claud ', 12);
    expect(c.text, 'hi  ');
    expect(c.selection.baseOffset, 3);
  });
  test('backspace inside a mention removes it', () {
    final c = make()..value = v('@buinam ok', 4);
    c.value = v('@bunam ok', 3);
    expect(c.text, ' ok');
  });
  test('unknown tags and normal text delete one char', () {
    final c = make()..value = v('@nobody x', 7);
    c.value = v('@nobod x', 6);
    expect(c.text, '@nobod x');
    final d = make()..value = v('hello', 5);
    d.value = v('hell', 4);
    expect(d.text, 'hell');
  });
  test('deleting the space after a tag only deletes the space', () {
    final c = make()..value = v('@buinam x', 8);
    c.value = v('@buinamx', 7);
    expect(c.text, '@buinamx');
  });
}
