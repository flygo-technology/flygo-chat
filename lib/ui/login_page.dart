import '../i18n/i18n.dart';
import 'package:flutter/material.dart';

import 'server_picker.dart';
import 'theme.dart';

class LoginPage extends StatefulWidget {
  final bool busy;
  final String? error;
  final VoidCallback onLogin;
  final void Function(String login, String password) onPasswordLogin;
  final void Function(String url) onSwitchServer;
  /// Máy tính: đăng nhập bằng QR quét từ điện thoại (null = không có).
  final VoidCallback? onQrLogin;
  const LoginPage({
    super.key,
    required this.busy,
    this.error,
    required this.onLogin,
    required this.onPasswordLogin,
    required this.onSwitchServer,
    this.onQrLogin,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _password = false;
  final _user = TextEditingController();
  final _pass = TextEditingController();

  bool get busy => widget.busy;
  String? get error => widget.error;
  VoidCallback get onLogin => widget.onLogin;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Center(
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
                Text(tr('Nhắn tin nội bộ của công ty.\nĐăng nhập bằng tài khoản Google công ty để bắt đầu.'),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: pal.sub, height: 1.4)),
                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: pal.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    ),
                    onPressed: busy ? null : onLogin,
                    icon: busy
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.login),
                    label: Text(busy ? tr('Đang chờ đăng nhập...') : tr('Đăng nhập bằng Google'),
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
                const SizedBox(height: 40),
                if (_password) ...[
                  TextField(controller: _user, decoration: InputDecoration(labelText: tr('Email hoặc tên đăng nhập'))),
                  TextField(controller: _pass, obscureText: true, decoration: InputDecoration(labelText: tr('Mật khẩu'))),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: busy ? null : () => widget.onPasswordLogin(_user.text.trim(), _pass.text),
                      child: Text(tr('Đăng nhập')),
                    ),
                  ),
                ] else
                  TextButton(
                    onPressed: () => setState(() => _password = true),
                    child: Text(tr('Đăng nhập bằng tài khoản và mật khẩu'), style: TextStyle(color: pal.sub)),
                  ),
                const SizedBox(height: 16),
                ServerSelectButton(onSelected: widget.onSwitchServer),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
