import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/mm_api.dart';
import '../data/models.dart';
import '../i18n/i18n.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Trang bảo mật tài khoản Google (tài khoản đăng nhập bằng Google đổi mật khẩu ở đây).
const kGoogleSecurityUrl = 'https://myaccount.google.com/security';

/// Dấu "phải đổi mật khẩu lần đầu" trong props của người dùng (máy chủ chat không có cờ này nên dùng dấu riêng).
///
/// Quản trị viên đặt dấu cho tài khoản mới (giá trị chuỗi "true"). `mmctl user ...` không sửa được props, nên gọi API
/// bằng token quản trị, nhớ gửi kèm các props đang có (máy chủ thay cả props khi patch):
///   PUT /api/v4/users/{id}/patch  {"props": {...props đang có, "flygo_must_change_password": "true"}}
/// Đổi xong, app tự bỏ dấu (PUT /api/v4/users/me/patch, giữ các props khác).
/// Không dùng last_password_update == create_at làm dấu hiệu: tài khoản dùng để duyệt app trên App Store không bao giờ
/// được bị bắt đổi mật khẩu.
const kMustChangePasswordProp = 'flygo_must_change_password';

/// Tài khoản đăng nhập bằng Google / SSO: không có mật khẩu trên máy chủ chat.
bool usesSsoLogin(MmUser u) => ((u.raw['auth_service'] as String?) ?? '').isNotEmpty;

/// Có dấu phải đổi mật khẩu lần đầu (bỏ qua tài khoản Google / SSO).
bool mustChangePassword(MmUser u) {
  final props = u.raw['props'];
  return !usesSsoLogin(u) && props is Map && '${props[kMustChangePasswordProp]}'.toLowerCase() == 'true';
}

/// Chính sách mật khẩu của máy chủ (GET /config/client?format=old).
class PasswordPolicy {
  final int minLength;
  final bool lower, upper, number, symbol;
  const PasswordPolicy({this.minLength = 8, this.lower = false, this.upper = false, this.number = false, this.symbol = false});

  /// Giới hạn của máy chủ (bcrypt chỉ dùng 72 byte đầu).
  static const maxLength = 72;

  /// Ký tự đặc biệt máy chủ chấp nhận.
  static const symbols = ' !"\\#\$%&\'()*+,-./:;<=>?@[]^_`|~';

  factory PasswordPolicy.fromConfig(Map c) => PasswordPolicy(
        minLength: int.tryParse('${c['PasswordMinimumLength']}') ?? 8,
        lower: '${c['PasswordRequireLowercase']}' == 'true',
        upper: '${c['PasswordRequireUppercase']}' == 'true',
        number: '${c['PasswordRequireNumber']}' == 'true',
        symbol: '${c['PasswordRequireSymbol']}' == 'true',
      );

  /// Các yêu cầu để hiện dưới ô mật khẩu mới.
  List<String> get rules => [
        tr('Ít nhất {0} ký tự', [minLength]),
        if (lower) tr('Có chữ thường (a-z)'),
        if (upper) tr('Có chữ hoa (A-Z)'),
        if (number) tr('Có chữ số (0-9)'),
        if (symbol) tr('Có ký tự đặc biệt (!@#...)'),
      ];

  /// Các yêu cầu mật khẩu chưa đạt (rỗng = hợp lệ).
  List<String> problems(String p) => [
        if (p.length < minLength) tr('Mật khẩu cần ít nhất {0} ký tự.', [minLength]),
        if (p.length > maxLength) tr('Mật khẩu dài tối đa {0} ký tự.', [maxLength]),
        if (lower && !p.contains(RegExp('[a-z]'))) tr('Mật khẩu cần có chữ thường (a-z).'),
        if (upper && !p.contains(RegExp('[A-Z]'))) tr('Mật khẩu cần có chữ hoa (A-Z).'),
        if (number && !p.contains(RegExp('[0-9]'))) tr('Mật khẩu cần có chữ số (0-9).'),
        if (symbol && !p.split('').any(symbols.contains)) tr('Mật khẩu cần có ký tự đặc biệt (!@#...).'),
      ];
}

/// Lỗi máy chủ trả về khi đổi mật khẩu, viết lại cho dễ hiểu.
String passwordErrorText(Object e) {
  if (e is ApiException) {
    final id = e.id;
    if (id.contains('check_user_password') || id.contains('update_password.incorrect') || id.contains('invalid_password')) {
      return tr('Mật khẩu hiện tại không đúng.');
    }
    if (id.contains('too_many') || e.status == 429) return tr('Nhập sai quá nhiều lần. Vui lòng thử lại sau.');
    if (id.contains('oauth') || id.contains('sso')) return tr('Tài khoản này đăng nhập bằng Google nên không có mật khẩu để đổi.');
    if (id.contains('is_valid.pwd')) return tr('Mật khẩu mới chưa đạt yêu cầu của máy chủ: {0}', [e.message]);
    if (e.status == 403) return tr('Bạn không có quyền đổi mật khẩu.');
    if (e.message.isNotEmpty) return tr('Không đổi được mật khẩu: {0}', [e.message]);
  }
  return tr('Không đổi được mật khẩu. Kiểm tra kết nối mạng.');
}

/// Trang "Mật khẩu" (mở từ mục Cá nhân của trang Bạn).
class PasswordPage extends StatelessWidget {
  const PasswordPage({super.key});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final me = context.select<AppState, MmUser?>((a) => a.me);
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(tr('Mật khẩu'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
      ),
      body: me != null && usesSsoLogin(me)
          ? const _SsoNotice()
          : PasswordForm(onDone: () {
              ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã đổi mật khẩu'))));
              Navigator.of(context).maybePop();
            }),
    );
  }
}

/// Tài khoản Google / SSO: giải thích, mở trang bảo mật Google thay cho biểu mẫu.
class _SsoNotice extends StatelessWidget {
  const _SsoNotice();
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(24, 32, 24, 24), children: [
      Icon(Icons.shield_outlined, size: 64, color: pal.accent),
      const SizedBox(height: 16),
      Text(tr('Tài khoản đăng nhập bằng Google: đổi mật khẩu trong tài khoản Google'),
          textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
      const SizedBox(height: 8),
      Text(tr('Tài khoản này không có mật khẩu riêng trên máy chủ chat. Mật khẩu Google đổi xong dùng luôn cho lần đăng nhập sau.'),
          textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: pal.sub)),
      const SizedBox(height: 24),
      Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(tr('Mở tài khoản Google')),
          onPressed: () => launchUrl(Uri.parse(kGoogleSecurityUrl), mode: LaunchMode.externalApplication),
        ),
      ),
    ]);
  }
}

/// Biểu mẫu đổi mật khẩu: mật khẩu hiện tại, mật khẩu mới, nhập lại; kiểm tra theo chính sách của máy chủ.
class PasswordForm extends StatefulWidget {
  final VoidCallback onDone;
  /// Đổi mật khẩu lần đầu: đổi xong thì bỏ dấu bắt buộc.
  final bool firstTime;
  const PasswordForm({super.key, required this.onDone, this.firstTime = false});
  @override
  State<PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<PasswordForm> {
  final _cur = TextEditingController(), _new = TextEditingController(), _again = TextEditingController();
  bool _showCur = false, _showNew = false, _showAgain = false, _busy = false, _tried = false;
  String? _curErr, _newErr, _againErr, _error;
  PasswordPolicy _policy = const PasswordPolicy();

  @override
  void initState() {
    super.initState();
    _loadPolicy();
  }

  Future<void> _loadPolicy() async {
    final p = await context.read<AppState>().passwordPolicy();
    if (mounted && p != null) setState(() => _policy = p);
  }

  @override
  void dispose() {
    _cur.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  /// Kiểm tra trước khi gửi; trả về true khi hợp lệ.
  bool _validate() {
    final cur = _cur.text, nw = _new.text;
    final probs = _policy.problems(nw);
    setState(() {
      _curErr = cur.isEmpty ? tr('Nhập mật khẩu hiện tại.') : null;
      _newErr = nw.isEmpty
          ? tr('Nhập mật khẩu mới.')
          : probs.isNotEmpty
              ? probs.join('\n')
              : nw == cur
                  ? tr('Mật khẩu mới phải khác mật khẩu hiện tại.')
                  : null;
      _againErr = _again.text != nw ? tr('Mật khẩu nhập lại không khớp.') : null;
    });
    return _curErr == null && _newErr == null && _againErr == null;
  }

  Future<void> _submit() async {
    _tried = true;
    if (_busy || !_validate()) return;
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.changePassword(_cur.text, _new.text);
      if (widget.firstTime) await app.clearMustChangePassword();
      if (mounted) widget.onDone();
    } catch (e) {
      if (!mounted) return;
      final msg = passwordErrorText(e);
      setState(() {
        if (msg == tr('Mật khẩu hiện tại không đúng.')) {
          _curErr = msg;
        } else {
          _error = msg;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, bool show, VoidCallback toggle, String? err,
      {TextInputAction action = TextInputAction.next, List<String> hints = const [AutofillHints.newPassword]}) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: c,
        enabled: !_busy,
        obscureText: !show,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: hints,
        textInputAction: action,
        onChanged: (_) {
          if (_tried) _validate();
        },
        onSubmitted: action == TextInputAction.done ? (_) => _submit() : null,
        style: TextStyle(color: pal.text, fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          errorText: err,
          errorMaxLines: 6,
          prefixIcon: const Icon(Icons.lock_outline_rounded),
          suffixIcon: IconButton(
            tooltip: show ? tr('Ẩn mật khẩu') : tr('Hiện mật khẩu'),
            icon: Icon(show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: toggle,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return AutofillGroup(
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
        _field(_cur, tr('Mật khẩu hiện tại'), _showCur, () => setState(() => _showCur = !_showCur), _curErr,
            hints: const [AutofillHints.password]),
        _field(_new, tr('Mật khẩu mới'), _showNew, () => setState(() => _showNew = !_showNew), _newErr),
        _field(_again, tr('Nhập lại mật khẩu mới'), _showAgain, () => setState(() => _showAgain = !_showAgain), _againErr,
            action: TextInputAction.done),
        // Yêu cầu của máy chủ.
        Text(tr('Mật khẩu mới cần:'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.sub)),
        const SizedBox(height: 4),
        for (final r in _policy.rules) Text('• $r', style: TextStyle(fontSize: 13, color: pal.sub)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 14)),
          ),
        const SizedBox(height: 22),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
              : Text(tr('Đổi mật khẩu')),
        ),
      ]),
    );
  }
}

/// Bắt đổi mật khẩu lần đầu: tài khoản có dấu [kMustChangePasswordProp] (và không đăng nhập bằng Google) thấy màn hình
/// "Đổi mật khẩu lần đầu" thay cho [child], không đóng được trừ khi đổi xong hoặc đăng xuất.
class PasswordGate extends StatefulWidget {
  final Widget child;
  final Future<void> Function() onLogout;
  const PasswordGate({super.key, required this.child, required this.onLogout});
  @override
  State<PasswordGate> createState() => _PasswordGateState();
}

class _PasswordGateState extends State<PasswordGate> {
  /// Đã đổi trong phiên này: không bắt lại dù chưa bỏ được dấu trên máy chủ (mạng lỗi lúc patch).
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    final must = context.select<AppState, bool>((a) => a.me != null && mustChangePassword(a.me!));
    if (!must || _done) return widget.child;
    final pal = Pal.of(context);
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: pal.bg,
          surfaceTintColor: Colors.transparent,
          title: Text(tr('Đổi mật khẩu lần đầu'), style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
          actions: [TextButton(onPressed: widget.onLogout, child: Text(tr('Đăng xuất')))],
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(tr('Quản trị viên yêu cầu bạn đổi mật khẩu trước khi dùng ứng dụng. Mật khẩu hiện tại là mật khẩu được cấp.'),
                style: TextStyle(fontSize: 14, color: pal.sub)),
          ),
          Expanded(
            child: PasswordForm(
              firstTime: true,
              onDone: () {
                setState(() => _done = true);
                ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã đổi mật khẩu'))));
              },
            ),
          ),
        ]),
      ),
    );
  }
}
