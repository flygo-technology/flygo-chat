import 'package:flutter_test/flutter_test.dart';
import 'package:dnd_chat/ui/common.dart';

void main() {
  test('initials', () {
    expect(initials('Bùi Năm'), 'BN');
    expect(initials('dang'), 'D');
  });
  test('preview strips markdown and maps shortcodes', () {
    expect(plainPreview(':warning: **Vẫn còn sự cố:** `abc`'), '⚠️ Vẫn còn sự cố: abc');
    expect(replaceShortcodes(':+1: :khong_co:'), '👍 :khong_co:');
  });
}
