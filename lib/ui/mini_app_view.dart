import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/mini_apps.dart';
import '../config.dart' show isDesktop;
import '../i18n/i18n.dart';
import '../state/app_state.dart';
import 'show_page.dart';
import 'theme.dart';

/// Mở mini app [app] (tại [path] nếu có): xin URL mở app ngay lúc bấm rồi mở webview toàn màn hình;
/// Windows / Linux mở bằng trình duyệt hệ thống.
Future<void> openMiniApp(BuildContext context, MiniApp app, {String? path}) async {
  final token = context.read<AppState>().token;
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context, rootNavigator: true);
  // App có màn hình native trong Flygo (vd Trình chiếu): mở màn hình đó, tự xin phiên bằng launch token.
  if (app.nativeScreen == 'show') {
    final code = path == null ? null : RegExp(r'^/pair/([A-Za-z0-9]{8})').firstMatch(path)?.group(1)?.toUpperCase();
    await nav.push(MaterialPageRoute(builder: (_) => ShowHome(app: app, mmToken: token, pairCode: code)));
    return;
  }
  try {
    final url = await MiniApps.launch(token, app, path: path);
    if (!MiniApps.inAppWebView) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    await nav.push(MaterialPageRoute(builder: (_) => MiniAppPage(app: app, url: url)));
  } catch (e) {
    messenger.showSnackBar(toast(Text('$e')));
  }
}

/// Nội dung QR [raw] khớp scan_prefixes của một mini app: hỏi xác nhận rồi mở app đó. Trả về true nếu đã xử lý
/// (mở hoặc người dùng huỷ); false nếu không khớp app nào (xử lý như QR thường).
Future<bool> openScannedMiniApp(BuildContext context, String raw) async {
  final hit = await MiniApps.forScan(context.read<AppState>().token, raw);
  if (hit == null || !context.mounted) return false;
  final (app, path) = hit;
  final go = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      icon: MiniAppIcon(app, size: 40),
      title: Text(tr('Mở {0}?', [app.name])),
      content: Text(Uri.parse(app.origin).host),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Mở'))),
      ],
    ),
  );
  if (go == true && context.mounted) await openMiniApp(context, app, path: path);
  return true;
}

/// Biểu tượng mini app: ảnh https hoặc emoji.
class MiniAppIcon extends StatelessWidget {
  final MiniApp app;
  final double size;
  const MiniAppIcon(this.app, {super.key, this.size = 30});
  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.apps_rounded, size: size, color: Pal.of(context).accentText);
    if (app.iconIsUrl) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * .22),
        child: Image.network(app.icon, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      );
    }
    if (app.icon.isEmpty) return fallback;
    return SizedBox(width: size, height: size, child: Center(child: Text(app.icon, style: TextStyle(fontSize: size * .8, height: 1))));
  }
}

/// Mục "Ứng dụng" trong tab Apps: lưới mini app từ registry của máy chủ (ẩn khi máy chủ không có registry
/// hoặc không có app nào người dùng được dùng). Tải lại mỗi lần mở tab (dùng bản đã tải trong 10 phút).
class MiniAppsSection extends StatefulWidget {
  /// Vẽ một mục (tiêu đề + lưới) giống các mục khác trong tab Apps.
  final Widget Function(String title, List<Widget> tiles) section;
  /// Ô của một app (biểu tượng, tên, mờ khi cần cập nhật, bấm để mở).
  final Widget Function(Widget icon, String label, bool dim, VoidCallback onTap) tile;
  const MiniAppsSection({super.key, required this.section, required this.tile});
  @override
  State<MiniAppsSection> createState() => _MiniAppsSectionState();
}

class _MiniAppsSectionState extends State<MiniAppsSection> {
  List<MiniApp> _apps = MiniApps.cached;

  @override
  void initState() {
    super.initState();
    MiniApps.list(context.read<AppState>().token).then((a) {
      if (mounted) setState(() => _apps = a);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (_apps.isEmpty) return const SizedBox.shrink();
    return widget.section(tr('Ứng dụng'), [
      for (final a in _apps)
        widget.tile(MiniAppIcon(a), a.needsUpdate ? '${a.name}\n${tr('Cần cập nhật Flygo')}' : a.name, a.needsUpdate,
            a.needsUpdate ? () => ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Cần cập nhật Flygo')))) : () => openMiniApp(context, a)),
    ]);
  }
}

/// Webview của một mini app: chỉ điều hướng trong origin của app (link khác mở trình duyệt hệ thống), không mang
/// token / cookie của máy chủ chat. Cầu nối JS `FlygoApp` (scanQr, share, close, openExternal) chỉ trả lời trang của app.
class MiniAppPage extends StatefulWidget {
  final MiniApp app;
  final Uri url;
  const MiniAppPage({super.key, required this.app, required this.url});
  @override
  State<MiniAppPage> createState() => _MiniAppPageState();
}

class _MiniAppPageState extends State<MiniAppPage> {
  late final WebViewController _web;
  int _progress = 0;

  MiniApp get _app => widget.app;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FlygoApp', onMessageReceived: (m) => _onBridge(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onNavigationRequest: (req) {
          final u = Uri.tryParse(req.url);
          if (u == null) return NavigationDecision.prevent;
          if (_app.owns(u) || u.scheme == 'about' || u.scheme == 'blob' || u.scheme == 'data') return NavigationDecision.navigate;
          // Ra ngoài origin của app: trình duyệt hệ thống, webview đứng yên.
          if (req.isMainFrame && (u.scheme == 'https' || u.scheme == 'http' || u.scheme == 'mailto' || u.scheme == 'tel')) {
            launchUrl(u, mode: LaunchMode.externalApplication);
          }
          return req.isMainFrame ? NavigationDecision.prevent : NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.url);
  }

  /// "Tải lại": xin URL mở app mới (cookie phiên của app có thể đã hết hạn), giữ trang đang xem nếu được.
  Future<void> _reload() async {
    final cur = Uri.tryParse(await _web.currentUrl() ?? '');
    if (!mounted) return;
    final token = context.read<AppState>().token;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = cur != null && _app.owns(cur) && !cur.path.startsWith('/launch')
          ? '${cur.path}${cur.hasQuery ? '?${cur.query}' : ''}${cur.hasFragment ? '#${cur.fragment}' : ''}'
          : null;
      await _web.loadRequest(await MiniApps.launch(token, _app, path: path));
    } catch (e) {
      messenger.showSnackBar(toast(Text('$e')));
    }
  }

  Future<void> _onBridge(String raw) async {
    Object? id;
    Future<void> reply(Object? result, [String? error]) =>
        _web.runJavaScript('window.__flygoReply && window.__flygoReply(${jsonEncode(id)}, ${jsonEncode(result)}, ${jsonEncode(error)})');
    try {
      final cur = Uri.tryParse(await _web.currentUrl() ?? '');
      if (cur == null || !_app.owns(cur)) return;
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      id = m['id'];
      final params = (m['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (!mounted) return;
      switch (m['method']) {
        case 'scanQr':
          // Máy tính không có máy quét: báo lỗi để app chuyển sang nhập mã.
          if (isDesktop) return await reply(null, 'unsupported');
          final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanOncePage()));
          return await (code == null ? reply(null, 'cancelled') : reply(code));
        case 'share':
          await SharePlus.instance.share(ShareParams(text: '${params['text'] ?? ''}'));
          return await reply(true);
        case 'close':
          await reply(true);
          if (mounted) Navigator.of(context).maybePop();
          return;
        case 'openExternal':
          final u = Uri.tryParse('${params['url'] ?? ''}');
          if (u == null || (u.scheme != 'https' && u.scheme != 'http')) return await reply(null, 'bad url');
          return await reply(await launchUrl(u, mode: LaunchMode.externalApplication));
        default:
          return await reply(null, 'unknown method');
      }
    } catch (e) {
      await reply(null, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Nút quay lại: lùi trong app trước, hết trang mới đóng.
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: tr('Đóng'), onPressed: () => Navigator.of(context).pop()),
          titleSpacing: 0,
          title: Row(children: [
            MiniAppIcon(_app, size: 26),
            const SizedBox(width: 10),
            Flexible(child: Text(_app.name, overflow: TextOverflow.ellipsis)),
          ]),
          actions: [IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: tr('Tải lại'), onPressed: _reload)],
          bottom: _progress < 100
              ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress / 100, minHeight: 2))
              : null,
        ),
        body: WebViewWidget(controller: _web),
      ),
    );
  }
}

/// Quét một mã QR cho mini app (cầu nối scanQr): trả về nội dung mã, hoặc null nếu đóng.
class ScanOncePage extends StatefulWidget {
  const ScanOncePage({super.key});
  @override
  State<ScanOncePage> createState() => _ScanOncePageState();
}

class _ScanOncePageState extends State<ScanOncePage> {
  final _ctl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(tr('Quét mã QR'))),
        body: MobileScanner(
          controller: _ctl,
          onDetect: (cap) {
            final raw = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
            if (raw == null || _done) return;
            _done = true;
            Navigator.of(context).pop(raw);
          },
        ),
      );
}
