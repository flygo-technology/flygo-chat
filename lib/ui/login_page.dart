import 'dart:async';

import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/servers.dart';
import 'theme.dart';

/// Đăng nhập: nhập email công ty trước. Tên miền của email cho biết máy chủ chat của công ty: app tự dò và
/// điền sẵn ô máy chủ bên dưới, rồi tự mở đăng nhập Google của đúng máy chủ đó. Công ty dùng địa chỉ khác thì
/// sửa ô máy chủ (dùng được với mọi máy chủ Mattermost).
class LoginPage extends StatefulWidget {
  final bool busy;
  final String? error;
  /// Email đã nhập lần trước (điền sẵn).
  final String email;
  /// Máy chủ không bật Google: hiện ô mật khẩu.
  final bool showPassword;
  /// Bấm "Tiếp tục": dùng máy chủ ở ô máy chủ (rỗng = dò theo email) rồi đăng nhập Google.
  final void Function(String email, String server) onEmail;
  final void Function(String login, String password, String server) onPasswordLogin;
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
  final _server = TextEditingController();
  /// Người dùng đã tự sửa ô máy chủ: không tự điền theo email nữa.
  bool _serverEdited = false;
  bool _finding = false;
  /// Máy chủ ở ô máy chủ (đã hỏi được), để hiện link chính sách / điều khoản của máy chủ đó.
  FoundServer? _found;
  Timer? _debounce;
  int _seq = 0;

  bool get busy => widget.busy;
  String? get error => widget.error;

  @override
  void initState() {
    super.initState();
    if (widget.email.isNotEmpty) _onEmailChanged(widget.email);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _user.dispose();
    _pass.dispose();
    _server.dispose();
    super.dispose();
  }

  /// Gõ email: điền ngay địa chỉ đoán theo tên miền, rồi dò thật (chờ ngừng gõ) để thay bằng máy chủ tìm được.
  void _onEmailChanged(String v) {
    if (_serverEdited) return;
    _server.text = ServerList.guess(v);
    _found = null;
    _schedule(() => ServerList.discover(v));
  }

  /// Tự sửa ô máy chủ: hỏi đúng địa chỉ đó (chờ ngừng gõ).
  void _onServerChanged(String v) {
    _serverEdited = v.trim().isNotEmpty;
    _found = null;
    if (!_serverEdited) {
      _onEmailChanged(_user.text);
      return;
    }
    _schedule(() => ServerList.probe(ServerList.normalize(v)));
  }

  void _schedule(Future<FoundServer?> Function() find) {
    _debounce?.cancel();
    final seq = ++_seq;
    setState(() => _finding = false);
    _debounce = Timer(const Duration(milliseconds: 700), () async {
      if (!mounted || seq != _seq) return;
      setState(() => _finding = true);
      final f = await find();
      if (!mounted || seq != _seq) return;
      setState(() {
        _finding = false;
        _found = f;
        if (f != null && !_serverEdited) _server.text = Uri.parse(f.url).host;
      });
    });
  }

  void _continue() {
    final e = _user.text.trim();
    if (e.isEmpty || busy) return;
    // Ô máy chủ chỉ là gợi ý khi chưa sửa: gửi rỗng để màn chính tự dò theo email như cũ.
    final server = _serverEdited ? _server.text.trim() : (_found != null ? _found!.url : '');
    if (_password || widget.showPassword) {
      widget.onPasswordLogin(e, _pass.text, server);
    } else {
      widget.onEmail(e, server);
    }
  }

  Widget _legal(Pal pal) {
    final f = _found;
    final links = [
      if (f?.privacy != null) (tr('Chính sách quyền riêng tư'), f!.privacy!),
      if (f?.terms != null) (tr('Điều khoản sử dụng'), f!.terms!),
    ];
    if (links.isEmpty) return const SizedBox.shrink();
    final link = TextStyle(color: pal.accentText, decoration: TextDecoration.underline, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(children: [
        Text(tr('Khi tiếp tục, bạn đồng ý với các chính sách của máy chủ {0}:', [Uri.parse(f!.url).host]),
            textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 13, height: 1.4)),
        Wrap(alignment: WrapAlignment.center, spacing: 16, children: [
          for (final (label, url) in links)
            InkWell(
              onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(label, style: link)),
            ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      // Bấm ra ngoài ô nhập: ẩn bàn phím (thấy được link chính sách bên dưới).
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                Text(tr('Nhắn tin, gọi thoại và video cho doanh nghiệp.\nNhập email công ty, app tự tìm máy chủ của công ty bạn.'),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: pal.sub, height: 1.4)),
                const SizedBox(height: 32),
                TextField(
                  controller: _user,
                  enabled: !busy,
                  autofocus: widget.email.isEmpty,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: _password || widget.showPassword ? TextInputAction.next : TextInputAction.go,
                  onChanged: _onEmailChanged,
                  onSubmitted: (_) => _password || widget.showPassword ? null : _continue(),
                  style: TextStyle(color: pal.text, fontSize: 16),
                  decoration: InputDecoration(
                    labelText: tr('Email công ty'),
                    hintText: tr('ten@congty.vn'),
                    prefixIcon: const Icon(Icons.alternate_email_rounded),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _server,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  onChanged: _onServerChanged,
                  style: TextStyle(color: pal.text, fontSize: 15),
                  decoration: InputDecoration(
                    labelText: tr('Địa chỉ máy chủ'),
                    hintText: tr('chat.congty.vn'),
                    helperText: _serverEdited
                        ? tr('Dùng được với mọi máy chủ Mattermost.')
                        : tr('Tự điền theo email. Chỉ sửa khi công ty dùng địa chỉ khác.'),
                    helperMaxLines: 2,
                    prefixIcon: const Icon(Icons.dns_outlined),
                    suffixIcon: _finding
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                        : _found != null
                            ? const Icon(Icons.check_circle_rounded, color: Color(0xFF27AE60))
                            : null,
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
                _legal(pal),
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
      ),
    );
  }
}
