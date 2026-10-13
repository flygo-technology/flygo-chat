import 'package:flutter/material.dart';

import 'theme.dart';

class LoginPage extends StatelessWidget {
  final bool busy;
  final String? error;
  final VoidCallback onLogin;
  const LoginPage({super.key, required this.busy, this.error, required this.onLogin});

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
                Text('Chào mừng đến với DND Chat',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: pal.text)),
                const SizedBox(height: 12),
                Text('Nhắn tin nội bộ của công ty.\nĐăng nhập bằng tài khoản Google công ty để bắt đầu.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: pal.sub, height: 1.4)),
                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: pal.accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    ),
                    onPressed: busy ? null : onLogin,
                    icon: busy
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.login),
                    label: Text(busy ? 'Đang chờ đăng nhập...' : 'Đăng nhập bằng Google',
                        style: const TextStyle(fontSize: 16)),
                  ),
                ),
                if (busy) ...[
                  const SizedBox(height: 12),
                  Text('Hoàn tất đăng nhập trong trình duyệt rồi quay lại đây.',
                      textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 13)),
                ],
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 40),
                Text('Máy chủ: chat.flygo.vn', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: pal.sub)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
