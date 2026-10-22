import '../i18n/i18n.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Đăng nhập: luôn nhập email công ty trước. Tên miền của email cho biết máy chủ chat của công ty
/// (tự dò, không cần chọn máy chủ), rồi tự mở đăng nhập Google của đúng máy chủ đó.
class LoginPage extends StatefulWidget {
  final bool busy;
  final String? error;
  /// Email đã nhập lần trước (điền sẵn).
  final String email;
  /// Máy chủ không bật Google: hiện ô mật khẩu.
  final bool showPassword;
  /// Bấm "Tiếp tục": dò máy chủ theo email rồi đăng nhập Google.
  final void Function(String email) onEmail;
  final void Function(String login, String password) onPasswordLogin;
  /// Đang thêm máy chủ mới: nút quay lại máy chủ đang dùng (null = không có).
  final VoidCallback? onCancel;
  /// Máy tính: đăng nhập bằng QR quét từ điện thoại (null = không có).
  final VoidCallback? onQrLogin;
  const LoginPage({
    super.key,
    required this.busy,
    this.error,
    this.email = '',
    this.showPassword = false,
    required this.onEmail,
    required this.onPasswordLogin,
    this.onCancel,
    this.onQrLogin,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _password = false;
  late final _user = TextEditingController(text: widget.email);
  final _pass = TextEditingController();

  bool get busy => widget.busy;
  String? get error => widget.error;

  void _continue() {
    final e = _user.text.trim();
    if (e.isEmpty || busy) return;
    if (_password || widget.showPassword) {
      widget.onPasswordLogin(e, _pass.text);
    } else {
      widget.onEmail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
                  child: const Icon(Icons.forum, color: Colors.white, size: 64),
                ),
                const SizedBox(height: 32),
                Text(tr('Chào mừng đến với Flygo Chat'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: pal.text)),
                const SizedBox(height: 12),
                Text(tr('Nhắn tin nội bộ của công ty.\nNhập email công ty, app tự tìm máy chủ và mở đăng nhập Google.'),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: pal.sub, height: 1.4)),
                const SizedBox(height: 32),
                TextField(
                  controller: _user,
                  enabled: !busy,
                  autofocus: widget.email.isEmpty,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: _password || widget.showPassword ? TextInputAction.next : TextInputAction.go,
                  onSubmitted: (_) => _password || widget.showPassword ? null : _continue(),
                  style: TextStyle(color: pal.text, fontSize: 16),
                  decoration: InputDecoration(
                    labelText: tr('Email công ty'),
                    hintText: tr('ten@congty.vn'),
                    prefixIcon: const Icon(Icons.alternate_email_rounded),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                if (_password || widget.showPassword) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    enabled: !busy,
                    autofocus: widget.showPassword,
                    obscureText: true,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _continue(),
                    style: TextStyle(color: pal.text, fontSize: 16),
                    decoration: InputDecoration(
                      labelText: tr('Mật khẩu'),
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: pal.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    ),
                    onPressed: busy ? null : _continue,
                    icon: busy
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Icon(_password || widget.showPassword ? Icons.login : Icons.arrow_forward_rounded),
                    label: Text(
                        busy
                            ? tr('Đang đăng nhập...')
                            : _password || widget.showPassword
                                ? tr('Đăng nhập')
                                : tr('Tiếp tục'),
                        style: const TextStyle(fontSize: 16)),
                  ),
                ),
                if (widget.onQrLogin != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26))),
                      onPressed: busy ? null : widget.onQrLogin,
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: Text(tr('Đăng nhập bằng QR'), style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
                if (busy) ...[
                  const SizedBox(height: 12),
                  Text(tr('Hoàn tất đăng nhập trong trình duyệt rồi quay lại đây.'),
                      textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 13)),
                ],
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 24),
                if (!widget.showPassword)
                  TextButton(
                    onPressed: busy ? null : () => setState(() => _password = !_password),
                    child: Text(_password ? tr('Đăng nhập bằng Google') : tr('Đăng nhập bằng mật khẩu'),
                        style: TextStyle(color: pal.sub)),
                  ),
                if (widget.onCancel != null)
                  TextButton.icon(
                    onPressed: busy ? null : widget.onCancel,
                    icon: Icon(Icons.arrow_back_rounded, size: 18, color: pal.sub),
                    label: Text(tr('Quay lại'), style: TextStyle(color: pal.sub)),
                  ),
              ]),
            ),
          ),
          ),
        ),
      ),
    );
  }
}
