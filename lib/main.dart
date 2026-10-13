import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'auth/auth_service.dart';
import 'state/app_state.dart';
import 'ui/call_screen.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

/// Phiên đăng nhập hiện tại; bọc toàn bộ app để mọi trang đều đọc được.
final session = ValueNotifier<AppState?>(null);
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DndChatApp());
}

class DndChatApp extends StatelessWidget {
  const DndChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flygo Chat',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      locale: const Locale('vi'),
      supportedLocales: const [Locale('vi'), Locale('en')],
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
    AppState.restore().then((a) {
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
      _error = 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.';
    });
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await AuthService.loginWithGoogle();
      await TokenStore.write(token);
      final a = AppState(token);
      await a.start(waitForSync: true);
      if (a.me == null) throw Exception(a.lastError ?? 'Không kết nối được máy chủ');
      setState(() => _attach(a));
    } on LoginCancelled {
      _error = 'Chưa đăng nhập xong. Bấm nút để thử lại.';
    } catch (e) {
      final msg = e.toString();
      _error = msg.contains('CANCELED') || msg.contains('cancel')
          ? 'Đã hủy đăng nhập.'
          : 'Đăng nhập không thành công. Kiểm tra kết nối mạng và thử lại.';
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
    if (a == null) return LoginPage(busy: _busy, error: _error, onLogin: _login);
    return HomePage(key: ValueKey(a), onLogout: _logout);
  }
}
