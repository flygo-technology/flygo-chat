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
import 'ui/ai_panel.dart';
import 'ui/ai_consent.dart';
import 'ui/chat_page.dart';
import 'ui/desktop_tray.dart';
import 'ui/flags.dart';
import 'ui/home_page.dart';
import 'ui/reaction_usage.dart';
import 'ui/login_page.dart';
import 'ui/server_picker.dart' show kAddServer;
import 'ui/theme.dart';
import 'ui/urgent_alert.dart';

/// Phiên đăng nhập hiện tại; bọc toàn bộ app để mọi trang đều đọc được.
final session = ValueNotifier<AppState?>(null);
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  if (await AuthService.relayCallback(args)) exit(0);
  // Xin đồng ý trước khi gửi dữ liệu cho AI (AppState gọi, hiện trên cửa sổ đang mở).
  AppState.aiConsentPrompt = (privacy) async {
    final ctx = navigatorKey.currentContext;
    return ctx != null && ctx.mounted && await showAiConsentDialog(ctx, privacy);
  };
  if (Platform.isWindows) _registerWindowsScheme();
  kWindowChannel = args.where((a) => a.startsWith('--chat=')).map((a) => a.substring(7)).firstOrNull;
  final ai = args.where((a) => a.startsWith('--ai=')).map((a) => a.substring(5)).firstOrNull;
  if (ai != null) {
    final parts = ai.split('#');
    kWindowChannel = parts.first;
    kWindowAi = true;
    kWindowAiThread = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
  }
  final thread = args.where((a) => a.startsWith('--thread=')).map((a) => a.substring(9).split('#')).firstOrNull;
  if (thread != null && thread.length == 2 && thread[1].isNotEmpty) {
    kWindowChannel = thread[0];
    kWindowThread = thread[1];
  }
  final call = args.where((a) => a.startsWith('--call=')).map((a) => a.substring(7)).firstOrNull;
  if (call != null) {
    kWindowChannel = call;
    kWindowCall = true;
    kWindowCallVideo = args.contains('--call-video');
    kWindowCallMeeting = args.contains('--call-meeting');
  }
  ServerList.pinned = args.where((a) => a.startsWith('--server=')).map((a) => a.substring(9)).firstOrNull;
  kWindowAddServer = args.contains('--add-server');
  WidgetsFlutterBinding.ensureInitialized();
  await _migrateMacSandboxData();
  await loadLanguage();
  await ReactionUsage.load();
  await DesktopTray.init();
  Updater.start();
  try {
    await PushService.init();
  } catch (e) {
    debugPrint('[push] init: $e');
  }
  runApp(const FlygoChatApp());
  // Máy tính: cửa sổ vừa mở riêng (chat, trợ lý AI, luồng, cuộc họp, máy chủ khác, thêm máy chủ) thì đưa lên trước.
  if (isDesktop && (ServerList.pinned != null || kWindowChannel != null || kWindowAddServer)) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WindowToFront.activate();
      Future.delayed(const Duration(milliseconds: 600), WindowToFront.activate);
      Future.delayed(const Duration(milliseconds: 1500), WindowToFront.activate);
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
  /// Màn đăng nhập: email đã nhập, máy chủ của email không bật Google (hiện ô mật khẩu).
  String _email = '';
  bool _needPassword = false;
  /// Điện thoại đang "Thêm máy chủ mới": máy chủ đang dùng trước đó (nút Quay lại ở màn đăng nhập).
  String? _prevServer;
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
                child: Row(children: [
                  LangFlag(e.key),
                  const SizedBox(width: 14),
                  Text(e.value, style: TextStyle(fontSize: 17, fontWeight: e.key == device ? FontWeight.w700 : FontWeight.w400)),
                ]),
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
    // Cửa sổ "Thêm máy chủ mới": không mở phiên đã lưu, vào thẳng màn đăng nhập.
    ServerList.load().then((_) => kWindowAddServer ? null : AppState.restore()).then((a) {
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
    a?.urgentAlert.addListener(_onUrgent);
    if (a != null && kWindowChannel == null) {
      a.registerPush();
      a.calls.addListener(_onCallChange);
      PushService.onSystemDecline = (ch) => _app?.calls.declineFromSystem(ch);
      _onPushOpen();
      _onPushAccept();
    }
    if (a != null && a.sessionExpired) _expired();
  }

  /// Tin khẩn cấp: hiện toàn màn hình, đè lên mọi màn hình khác (máy tính: đưa cửa sổ lên trước).
  Future<void> _onUrgent() async {
    final a = _app, p = a?.urgentAlert.value;
    if (a == null || p == null) return;
    a.urgentAlert.value = null;
    if (isDesktop) {
      await DesktopTray.show();
      WindowToFront.activate();
    }
    navigatorKey.currentState?.push(PageRouteBuilder(
      opaque: true,
      fullscreenDialog: true,
      pageBuilder: (_, _, _) => UrgentAlertPage(app: a, post: p),
      transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
    ));
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
    MmPost? urgent;
    // Mở từ thông báo tin khẩn cấp (kể cả màn hình khoá): sau khi mở chat thì hiện toàn màn hình nếu chưa xác nhận.
    void showUrgent() {
      if (urgent case final u?) _app?.showUrgent(u);
    }
    if (postId != null && _app != null) {
      try {
        final p = MmPost((await _app!.api.get('/posts/$postId') as Map).cast());
        if (p.rootId.isNotEmpty && p.inThread) root = p.rootId;
        urgent = p;
      } catch (_) {}
    }
    if (isDesktop) {
      await DesktopTray.show();
      WindowToFront.activate();
      final hook = PushService.openChatHook;
      if (hook != null) {
        hook(id);
        if (root != null) PushService.openThreadHook?.call(id, root);
        showUrgent();
        return;
      }
    }
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(builder: (_) => ChatPage(channelId: id)));
    if (root != null) nav.push(MaterialPageRoute(builder: (_) => ThreadPage(channelId: id, rootId: root!)));
    showUrgent();
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
    a.urgentAlert.removeListener(_onUrgent);
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
    if (url == kAddServer) return _addServer();
    _prevServer = null;
    final old = _app;
    if (old != null) {
      old.removeListener(_onAppChange);
      old.urgentAlert.removeListener(_onUrgent);
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

  /// "Thêm máy chủ mới" (điện thoại): đóng phiên hiện tại (không đăng xuất), hiện màn đăng nhập.
  void _addServer() {
    final old = _app;
    if (old != null) {
      old.removeListener(_onAppChange);
      old.urgentAlert.removeListener(_onUrgent);
      old.disposeSession();
    }
    session.value = null;
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _prevServer = kServerUrl;
      _app = null;
      _error = null;
      _email = '';
      _needPassword = false;
    });
  }

  /// Tìm máy chủ chat theo tên miền email (hoặc dùng đúng [server] người dùng nhập) rồi chuyển sang máy chủ đó.
  /// Trả về máy chủ tìm được, null nếu không tìm thấy (đã hiện lỗi) hoặc máy chủ đó đã đăng nhập sẵn (đã vào app).
  Future<FoundServer?> _serverForEmail(String email, [String server = '']) async {
    setState(() {
      _busy = true;
      _error = null;
      _email = email;
      _needPassword = false;
    });
    final domain = ServerList.emailDomain(email);
    final manual = ServerList.normalize(server);
    final s = manual.isNotEmpty
        ? await ServerList.probe(manual, name: domain.isEmpty ? null : domain)
        : domain.isEmpty
            ? null
            : await ServerList.discover(email);
    if (!mounted) return null;
    if (s == null) {
      setState(() {
        _busy = false;
        _error = manual.isNotEmpty
            ? tr('Không kết nối được máy chủ {0}. Kiểm tra lại địa chỉ máy chủ.', [Uri.tryParse(manual)?.host ?? manual])
            : domain.isEmpty
            ? tr('Email chưa đúng. Nhập email công ty, ví dụ ten@congty.vn.')
            : tr('Không tìm thấy máy chủ chat của {0}. Kiểm tra lại email hoặc hỏi quản trị viên.', [domain]);
      });
      return null;
    }
    if (kWindowAddServer) {
      // Cửa sổ thêm máy chủ: không mở trùng máy chủ của cửa sổ chính (hai cửa sổ ghi chung một kho trên máy).
      if (s.url == ServerList.current) {
        setState(() {
          _busy = false;
          _error = tr('Máy chủ {0} đang mở ở cửa sổ chính.', [Uri.parse(s.url).host]);
        });
        return null;
      }
      // Cửa sổ này dành riêng cho máy chủ vừa tìm được, không đổi máy chủ của cửa sổ chính.
      ServerList.pinned = s.url;
    }
    if (s.url != kServerUrl || _prevServer != null || kWindowAddServer) {
      if (!ServerList.items.any((e) => e.url == s.url)) await ServerList.add(s.url, s.name, select: false);
      await _switchServer(s.url);
      if (_app != null) return null;
    }
    return s;
  }

  /// "Tiếp tục" ở màn đăng nhập: dò máy chủ theo email, rồi tự mở đăng nhập Google của máy chủ đó
  /// (máy chủ không bật Google thì hiện ô mật khẩu).
  Future<void> _loginEmail(String email, String server) async {
    final s = await _serverForEmail(email, server);
    if (s == null || !mounted) return;
    // Tài khoản demo@… / apple.review@… (để thử app, cho người duyệt App Store): luôn đăng nhập bằng mật khẩu.
    final e = email.trim().toLowerCase();
    final demo = e.startsWith('demo@') || e.startsWith('apple.review@');
    if (s.google && !demo) {
      await _login();
    } else {
      setState(() {
        _busy = false;
        _needPassword = true;
        if (!s.password && !demo) _error = tr('Máy chủ {0} chưa bật đăng nhập Google. Liên hệ quản trị viên.', [Uri.parse(s.url).host]);
      });
    }
  }

  Future<void> _loginPassword(String login, String password, String server) async {
    // Có địa chỉ máy chủ thì dùng máy chủ đó; đăng nhập bằng email thì tìm máy chủ theo tên miền trước.
    if (server.isNotEmpty || ServerList.emailDomain(login).isNotEmpty) {
      final s = await _serverForEmail(login, server);
      if (s == null || !mounted) return;
    }
    await _login(password: (login, password));
  }

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
    a.urgentAlert.removeListener(_onUrgent);
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
        email: _email,
        showPassword: _needPassword,
        onEmail: _loginEmail,
        onPasswordLogin: _loginPassword,
        // Máy tính: đăng nhập bằng QR quét từ điện thoại cùng mạng LAN.
        onQrLogin: !isDesktop
            ? null
            : () => navigatorKey.currentState?.push(MaterialPageRoute(
                builder: (_) => QrLoginPage(
                    server: kServerUrl,
                    onToken: (t, server, name) async {
                      // Máy tính theo máy chủ của điện thoại: chưa có trong danh sách thì thêm vào.
                      if (server != kServerUrl) {
                        ServerList.items.any((e) => e.url == server)
                            ? await ServerList.use(server)
                            : await ServerList.add(server, name);
                      }
                      _login(qrToken: t);
                    }))),
        onCancel: _prevServer == null ? null : () => _switchServer(_prevServer!),
      );
    }
    final w = kWindowChannel;
    if (w != null && kWindowCall) return CallWindow(key: ValueKey(a), app: a);
    if (w != null && kWindowThread != null) return ThreadPage(key: ValueKey(Object.hash(a, appLanguage.value)), channelId: w, rootId: kWindowThread!);
    if (w != null && kWindowAi) {
      return Scaffold(key: ValueKey(Object.hash(a, appLanguage.value)), body: AiPanel(groupId: w, thread: kWindowAiThread));
    }
    if (w != null) return ChatPage(key: ValueKey(Object.hash(a, appLanguage.value)), channelId: w, embedded: true);
    return HomePage(key: ValueKey(Object.hash(a, appLanguage.value)), onLogout: _logout, onSwitchServer: _switchServer);
  }
}

/// Cửa sổ riêng của cuộc họp (máy tính): vào cuộc họp ngay khi mở, rời cuộc họp thì đóng cửa sổ (thoát tiến trình).
class CallWindow extends StatefulWidget {
  final AppState app;
  const CallWindow({super.key, required this.app});
  @override
  State<CallWindow> createState() => _CallWindowState();
}

class _CallWindowState extends State<CallWindow> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.app.calls.addListener(_onCall);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      WindowToFront.activate();
      await widget.app.calls.startCall(kWindowChannel!, video: kWindowCallVideo, meeting: kWindowCallMeeting);
      _started = true;
      _onCall();
    });
  }

  void _onCall() {
    if (_started && !widget.app.calls.busy) exit(0);
  }

  @override
  void dispose() {
    widget.app.calls.removeListener(_onCall);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF202124),
        body: Center(child: Text(tr('Đang vào cuộc họp…'), style: const TextStyle(color: Colors.white70, fontSize: 16))),
      );
}
