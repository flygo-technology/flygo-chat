import 'package:flutter_test/flutter_test.dart';
import 'package:dnd_chat/ui/common.dart';

void main() {
  test('initials', () {
    expect(initials('Bùi Năm'), 'BN');
    expect(initials('dang'), 'D');
  });
}
