import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/data/models.dart';
import 'package:flygo_chat/ui/password_page.dart';

void main() {
  test('policy from server config', () {
    final p = PasswordPolicy.fromConfig({
      'PasswordMinimumLength': '10',
      'PasswordRequireLowercase': 'true',
      'PasswordRequireUppercase': 'true',
      'PasswordRequireNumber': 'true',
      'PasswordRequireSymbol': 'true',
    });
    expect(p.problems('short').length, 4);
    expect(p.problems('Abcdefgh1!'), isEmpty);
    expect(p.problems('abcdefgh1!').length, 1);
    expect(p.problems('${'A' * 73}a1!').length, 1);
    expect(const PasswordPolicy().problems('12345678'), isEmpty);
  });

  test('first-login marker', () {
    MmUser u(Map<String, dynamic> extra) => MmUser({'id': 'u1', ...extra});
    expect(mustChangePassword(u({})), isFalse);
    expect(mustChangePassword(u({'props': {kMustChangePasswordProp: 'true'}})), isTrue);
    expect(mustChangePassword(u({'props': {kMustChangePasswordProp: 'false'}})), isFalse);
    // Tài khoản Google không có mật khẩu: không bắt đổi.
    expect(mustChangePassword(u({'auth_service': 'google', 'props': {kMustChangePasswordProp: 'true'}})), isFalse);
    expect(usesSsoLogin(u({'auth_service': ''})), isFalse);
  });
}
