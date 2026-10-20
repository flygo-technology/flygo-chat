import 'i18n/i18n.dart';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'auth/auth_service.dart';
import 'calls/call_service.dart';
import 'agent/agent_service.dart';
import 'push/push_service.dart';
import 'update/updater.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_to_front/window_to_front.dart';
import 'config.dart';
import 'data/servers.dart';
import 'data/models.dart';
import 'ui/qr_login.dart';
import 'state/app_state.dart';
import 'ui/call_screen.dart';
import 'ui/chat_page.dart';
import 'ui/desktop_tray.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

/// Phiên đăng nhập hiện tại; bọc toàn bộ app để mọi trang đều đọc được.
final session = ValueNotifier<AppState?>(null);
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  if (await AuthService.relayCallback(args)) exit(0);
  if (Platform.isWindows) _registerWindowsScheme();
  kWindowChannel = args.where((a) => a.startsWith('--chat=')).map((a) => a.substring(7)).firstOrNull;
  ServerList.pinned = args.where((a) => a.startsWith('--server=')).map((a) => a.substring(9)).firstOrNull;
  WidgetsFlutterBinding.ensureInitialized();
  await _migrateMacSandboxData();
  await loadLanguage();
  await DesktopTray.init();
  Updater.start();
  try {
    await PushService.init();
  } catch (e) {
    debugPrint('[push] init: $e');
  }
  runApp(const FlygoChatApp());
  // Máy tính: cửa sổ vừa mở cho máy chủ khác thì đưa lên trước.
  if (ServerList.pinned != null && isDesktop) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WindowToFront.activate();
      Future.delayed(const Duration(milliseconds: 600), WindowToFront.activate);
    });
  }
}

/// macOS: bản cũ chạy trong sandbox, dữ liệu nằm ở ~/Library/Containers/vn.flygo.chat. Bản mới
/// (không sandbox, để chạy được trợ lý AI) chép dữ liệu đó sang thư mục mới ở lần mở đầu tiên.
Future<void> _migrateMacSandboxData() async {
  if (!Platform.isMacOS) return;
  try {
    final dir = await getApplicationSupportDirectory();
    final home = Platform.environment['HOME'] ?? '';
    final old = Directory('$home/Library/Containers/vn.flygo.chat/Data/Library/Application Support/vn.flygo.chat');
    if (dir.path.contains('/Library/Containers/') || !old.existsSync()) return;
    final marker = File('${dir.path}/.migrated_from_sandbox');
    if (marker.existsSync()) return;
    await dir.create(recursive: true);
    for (final e in old.listSync()) {
      if (e is! File) continue;
      final target = File('${dir.path}/${e.uri.pathSegments.last}');
      if (!target.existsSync()) await e.copy(target.path);
    }
    await marker.writeAsString(DateTime.now().toIso8601String());
  } catch (e) {
    debugPrint('[migrate] $e');
  }
}

/// Windows: đăng ký liên kết flygochat:// (đăng nhập Google trả về app) cho người dùng hiện tại.
void _registerWindowsScheme() {
  final exe = Platform.resolvedExecutable;
  const key = r'HKCU\Software\Classes\flygochat';
  for (final a in [
    ['add', key, '/ve', '/d', 'URL:Flygo Chat', '/f'],
    ['add', key, '/v', 'URL Protocol', '/d', '', '/f'],
    ['add', '$key\\shell\\open\\command', '/ve', '/d', '"$exe" "%1"', '/f'],
  ]) {
    Process.run('reg', a).catchError((_) => ProcessResult(0, 1, '', ''));
  }
}

class FlygoChatApp extends StatelessWidget {
  const FlygoChatApp({super.key});

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
      builder: (context, child) => CenteredToasts(
        child: ValueListenableBuilder<AppState?>(
          valueListenable: session,
          builder: (_, app, _) =>
              app == null ? child! : ChangeNotifierProvider<AppState>.value(value: app, child: child!),
        ),
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

  Future<void> _askLanguage() async {
    final nav = navigatorKey.currentState;
    final ctx = nav?.overlay?.context ?? context;
    final device = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    final lang = await showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (d) => SimpleDialog(
        title: const Text('Chọn ngôn ngữ · Language'),
        children: [
          for (final e in appLanguages.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(d, e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(e.value,
                    style: TextStyle(fontSize: 17, fontWeight: e.key == device ? FontWeight.w700 : FontWeight.w400)),
              ),
            ),
        ],
      ),
    );
    await setLanguage(lang ?? (appLanguages.containsKey(device) ? device : 'vi'));
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // Máy tính: runner trợ lý AI đi kèm app — cập nhật bản đã cài nếu app mang bản mới hơn.
    AgentService.instance.syncBundledRunner();
    _life = AppLifecycleListener(
      onResume: () => _app?.appResumed(),
      onStateChange: (s) => PushService.appFocused = s == AppLifecycleState.resumed,
      // Thoát app: dừng các trợ lý AI đang chạy trong app (đưa bot về offline).
      onExitRequested: () async {
        await AgentService.instance.stopAll();
        return AppExitResponse.exit;
      },
    );
    PushService.openChannel.addListener(_onPushOpen);
    // Lần đầu mở app: chọn ngôn ngữ.
    if (!languageChosen) WidgetsBinding.instance.addPostFrameCallback((_) => _askLanguage());
    PushService.acceptCall.addListener(_onPushAccept);
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
    if (a != null && kWindowChannel == null) {
      a.registerPush();
      a.calls.addListener(_onCallChange);
      PushService.onSystemDecline = (ch) => _app?.calls.declineFromSystem(ch);
      _onPushOpen();
      _onPushAccept();
    }
    if (a != null && a.sessionExpired) _expired();
  }

  /// Bấm vào thông báo tin nhắn: mở cuộc trò chuyện đó.
  Future<void> _onPushOpen() async {
    final id = PushService.openChannel.value;
    if (id == null || _app == null) return;
    PushService.openChannel.value = null;
    // Thông báo từ máy chủ khác: điện thoại chuyển sang máy chủ đó trước.
    final url = ServerList.urlForServerId(PushService.openServerId ?? '');
    PushService.openServerId = null;
    if (url != null && url != kServerUrl && !isDesktop) {
      await _switchServer(url);
      if (_app == null) return;
    }
    // Tin trong luồng: mở thẳng vào luồng (sau khi mở chat chính).
    final postId = PushService.openPostId;
    PushService.openPostId = null;
    String? root;
    if (postId != null && _app != null) {
      try {
        final p = MmPost((await _app!.api.get('/posts/$postId') as Map).cast());
        if (p.rootId.isNotEmpty && p.inThread) root = p.rootId;
      } catch (_) {}
    }
    if (isDesktop) {
      await DesktopTray.show();
      WindowToFront.activate();
      final hook = PushService.openChatHook;
      if (hook != null) {
        hook(id);
        if (root != null) PushService.openThreadHook?.call(id, root);
        return;
      }
    }
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(builder: (_) => ChatPage(channelId: id)));
    if (root != null) nav.push(MaterialPageRoute(builder: (_) => ThreadPage(channelId: id, rootId: root!)));
  }

  /// Bấm "Trả lời" trên màn hình cuộc gọi của hệ điều hành.
  void _onPushAccept() {
    final id = PushService.acceptCall.value;
    final a = _app;
    if (id == null || a == null) return;
    PushService.acceptCall.value = null;
    a.calls.acceptFromSystem(id, video: PushService.acceptVideo);
    PushService.acceptVideo = false;
  }

  /// Cuộc gọi trong app kết thúc: đóng luôn màn hình cuộc gọi của hệ điều hành.
  CallPhase? _lastCallPhase;

  void _onCallChange() {
    final p = _app?.calls.phase;
    // Cuộc gọi đến khi cửa sổ đang ẩn dưới khay: hiện cửa sổ lên.
    if (p == CallPhase.incoming && _lastCallPhase != CallPhase.incoming) DesktopTray.show();
    _lastCallPhase = p;
    PushService.inCallChannel =
        p == CallPhase.outgoing || p == CallPhase.connecting || p == CallPhase.active ? _app?.calls.channelId : null;
    if (p == CallPhase.ended || p == CallPhase.idle) PushService.endCalls();
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

  Future<void> _login({(String, String)? password, String? qrToken}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = qrToken ??
          (password != null
              ? await AuthService.loginWithPassword(password.$1, password.$2)
              : await AuthService.loginWithGoogle());
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
        // Máy tính: đăng nhập bằng QR quét từ điện thoại cùng mạng LAN.
        onQrLogin: !isDesktop
            ? null
            : () => navigatorKey.currentState?.push(MaterialPageRoute(
                builder: (_) => QrLoginPage(server: kServerUrl, onToken: (t) => _login(qrToken: t)))),
        onSwitchServer: _switchServer,
      );
    }
    final w = kWindowChannel;
    if (w != null) return ChatPage(key: ValueKey(Object.hash(a, appLanguage.value)), channelId: w, embedded: true);
    return HomePage(key: ValueKey(Object.hash(a, appLanguage.value)), onLogout: _logout, onSwitchServer: _switchServer);
  }
}
