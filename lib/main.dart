import 'i18n/i18n.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'auth/auth_service.dart';
import 'data/servers.dart';
import 'state/app_state.dart';
import 'ui/call_screen.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

/// Phiên đăng nhập hiện tại; bọc toàn bộ app để mọi trang đều đọc được.
final session = ValueNotifier<AppState?>(null);
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  if (await AuthService.relayCallback(args)) exit(0);
  WidgetsFlutterBinding.ensureInitialized();
  await loadLanguage();
  runApp(const DndChatApp());
}

class DndChatApp extends StatelessWidget {
  const DndChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appLanguage,
      builder: (_, lang, _) => _app(lang),
    );
  }

  Widget _app(String lang) {
    return MaterialApp(
      title: 'Flygo Chat',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      locale: Locale(lang),
      supportedLocales: [for (final l in appLanguages.keys) Locale(l)],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) => ValueListenableBuilder<AppState?>(
        valueListenable: session,
        builder: (_, app, _) =>
            app == null ? child! : ChangeNotifierProvider<AppState>.value(value: app, child: child!),
      ),
      home: const Root(),
    );
  }
}

/// Quyết định hiện màn hình đăng nhập hay màn hình chính.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  AppState? _app;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: () => _app?.appResumed());
    ServerList.load().then((_) => AppState.restore()).then((a) {
      _attach(a);
      setState(() => _loading = false);
    }).catchError((_) => setState(() => _loading = false));
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  void _attach(AppState? a) {
    _app = a;
    session.value = a;
    a?.calls.onShowCallScreen = () {
      navigatorKey.currentState?.push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CallScreen()));
    };
    a?.addListener(_onAppChange);
    if (a != null && a.sessionExpired) _expired();
  }

  void _onAppChange() {
    if (_app?.sessionExpired == true) _expired();
  }

  void _expired() {
    final a = _app;
    if (a == null) return;
    a.removeListener(_onAppChange);
    a.logout();
    session.value = null;
    setState(() {
      _app = null;
      _error = tr('Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.');
    });
  }

  /// Chuyển máy chủ: đóng phiên hiện tại (không đăng xuất), mở phiên đã lưu
  /// của máy chủ mới, chưa có thì hiện màn đăng nhập.
  Future<void> _switchServer(String url) async {
    final old = _app;
    if (old != null) {
      old.removeListener(_onAppChange);
      old.disposeSession();
    }
    session.value = null;
    setState(() {
      _app = null;
      _loading = true;
      _error = null;
    });
    await ServerList.use(url);
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    try {
      _attach(await AppState.restore());
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loginPassword(String login, String password) => _login(password: (login, password));

  Future<void> _login({(String, String)? password}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = password != null
          ? await AuthService.loginWithPassword(password.$1, password.$2)
          : await AuthService.loginWithGoogle();
      await TokenStore.write(token);
      final a = AppState(token);
      await a.start(waitForSync: true);
      if (a.me == null) throw Exception(a.lastError ?? tr('Không kết nối được máy chủ'));
      setState(() => _attach(a));
    } on LoginCancelled {
      _error = tr('Chưa đăng nhập xong. Bấm nút để thử lại.');
    } catch (e) {
      final msg = e.toString();
      _error = password != null
          ? msg.replaceFirst('Exception: ', '')
          : msg.contains('CANCELED') || msg.contains('cancel')
              ? tr('Đã hủy đăng nhập.')
              : tr('Đăng nhập không thành công. Kiểm tra kết nối mạng và thử lại.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    final a = _app;
    if (a == null) return;
    a.removeListener(_onAppChange);
    await a.logout();
    session.value = null;
    setState(() => _app = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(body: Center(child: Icon(Icons.forum, size: 72, color: Pal.of(context).accent)));
    }
    final a = _app;
    if (a == null) {
      return LoginPage(
        busy: _busy,
        error: _error,
        onLogin: () => _login(),
        onPasswordLogin: _loginPassword,
        onSwitchServer: _switchServer,
      );
    }
    return HomePage(key: ValueKey(Object.hash(a, appLanguage.value)), onLogout: _logout, onSwitchServer: _switchServer);
  }
}
