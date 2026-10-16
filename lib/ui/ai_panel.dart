import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'agent_page.dart';
import 'agent_view.dart';
import 'chat_page.dart';
import 'common.dart';
import 'home_page.dart' show ChatHost;
import 'theme.dart';

/// Hỏi trợ lý về một tin ở nhóm: điền sẵn trích dẫn vào cột AI và đính kèm tham chiếu (flygo_ai_ref) để
/// trợ lý tự đọc tin / cả luồng. [target]: null = phiên đang mở, [AppState.kAiNewSession] = phiên mới,
/// còn lại = id kênh phiên AI. [open]: mở cột AI (menu "Hỏi trợ lý"); kéo thả thì cột đã mở sẵn.
void askAiAbout(BuildContext context, AppState app, MmChannel channel, MmPost post,
    {String? target, bool open = true}) {
  final who = post.userId == app.me?.id ? tr('Bạn') : (app.users[post.userId]?.displayName ?? '');
  var body = app.previewText(post).replaceAll('\n', ' ');
  if (body.length > 300) body = '${body.substring(0, 300)}…';
  // Tin trong luồng → cả luồng; tin gốc đã có luồng → cả luồng của tin đó.
  final root = post.rootId.isNotEmpty ? post.rootId : (app.threadSummary(post.channelId, post.id) != null ? post.id : '');
  final text = root.isEmpty ? '> **$who:** $body\n\n' : '> **$who** ${tr('(cả luồng)')}: $body\n\n';
  app.aiAsk.value = (
    groupId: channel.id,
    text: text,
    target: target,
    ref: {'channel_id': post.channelId, 'post_id': post.id, if (root.isNotEmpty) 'root_id': root},
  );
  if (!open) return;
  final host = ChatHost.of(context);
  if (host?.openAi != null) {
    host!.openAi!(channel.id);
  } else {
    openAiPanel(context, channel.id);
  }
}

/// Cột phải "Trợ lý AI" của một nhóm: các phiên làm việc riêng của mình với trợ lý AI, gắn với nhóm đó.
/// Mỗi phiên là một kênh riêng tư (mình + bot); chưa có phiên nào thì chỉ hiện ô nhắn tin, tin đầu tiên mới tạo phiên.
/// Máy tính: kéo tin từ chat chính thả vào đây → chọn tạo phiên mới hoặc thêm vào một phiên đang có.
class AiPanel extends StatefulWidget {
  final String groupId;
  /// Có thì hiện nút đóng (điện thoại: trang riêng có nút quay lại thay vào).
  final VoidCallback? onClose;
  final bool embedded;
  const AiPanel({super.key, required this.groupId, this.onClose, this.embedded = true});
  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _ctl = TextEditingController();
  List<AgentBot>? _bots;
  String? _target; // bot được gọi ở tin đầu tiên
  bool _sending = false;
  bool _dragOver = false;

  /// Đang soạn tin đầu tiên của một phiên mới (bấm ＋ hoặc "Hỏi trợ lý (phiên mới)").
  bool _newSession = false;
  Map<String, dynamic>? _ref;

  late final AppState _app;

  /// Lời hỏi gửi tới cột AI: phiên mới (hoặc chưa có phiên nào) thì điền vào ô nhắn tin đầu tiên ở đây;
  /// phiên đang có thì để ô nhắn tin của phiên đó nhận.
  void _onAsk() {
    final v = _app.aiAsk.value;
    if (v == null || v.groupId != widget.groupId || !mounted) return;
    final hasSession = _app.aiChannelFor(widget.groupId) != null;
    if (v.target == AppState.kAiNewSession || !hasSession) {
      _app.aiAsk.value = null;
      setState(() {
        _newSession = true;
        _ref = v.ref;
      });
      final cur = _ctl.text.trimRight();
      _ctl.text = cur.isEmpty ? v.text : '$cur\n\n${v.text}';
      _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    } else if (v.target != null && v.target != _app.aiChannelFor(widget.groupId)?.id) {
      // Thêm vào một phiên khác phiên đang mở: chuyển sang phiên đó, ô nhắn tin của nó sẽ nhận lời hỏi.
      setState(() => _newSession = false);
      _app.selectAiSession(widget.groupId, v.target!);
    } else if (_newSession) {
      setState(() => _newSession = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.aiAsk.addListener(_onAsk);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAsk());
    AgentService.instance.myBots(context.read<AppState>()).then((b) {
      if (mounted) {
        setState(() {
          _bots = b;
          _target = b.isEmpty ? null : b.first.username;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _bots = const []);
    });
  }

  @override
  void didUpdateWidget(AiPanel old) {
    super.didUpdateWidget(old);
    if (old.groupId != widget.groupId) {
      _newSession = false;
      _ref = null;
      _ctl.clear();
    }
  }

  @override
  void dispose() {
    _app.aiAsk.removeListener(_onAsk);
    _ctl.dispose();
    super.dispose();
  }

  /// Tên phiên tự đặt từ tin đầu tiên (bỏ trích dẫn, @tag).
  static String _titleFrom(String text) {
    var t = text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^>\s*'), '').replaceAll(RegExp(r'\*\*'), '').trim())
        .where((l) => l.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'@[\w.\-]+\s*'), '')
        .trim();
    if (t.length > 40) t = '${t.substring(0, 40)}…';
    return t;
  }

  Future<void> _sendFirst() async {
    final app = context.read<AppState>();
    final group = app.channels[widget.groupId];
    final bots = _bots ?? const <AgentBot>[];
    var text = _ctl.text.trim();
    if (group == null || text.isEmpty || bots.isEmpty || _sending) return;
    // Nhiều trợ lý: gọi đúng trợ lý đang chọn (thêm @ nếu chưa tag ai).
    if (!text.contains('@') && _target != null && bots.length > 1) text = '@$_target $text';
    setState(() => _sending = true);
    try {
      final c = await app.createAiChannel(group, [for (final b in bots) b.id], title: _titleFrom(text));
      final ref = _ref;
      await app.send(c.id, text, props: {'flygo_ai_ref': ?ref});
      _ctl.clear();
      _ref = null;
      if (mounted) setState(() => _newSession = false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(toast(Text(tr('Không tạo được chat với trợ lý. Kiểm tra kết nối mạng.'))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------------------------------------------------------------- kéo thả
  Future<void> _onDrop(MmPost post, Offset at) async {
    final app = context.read<AppState>();
    final group = app.channels[widget.groupId];
    if (group == null) return;
    final sessions = app.aiChannelsFor(widget.groupId);
    String? target = AppState.kAiNewSession;
    if (sessions.isNotEmpty) {
      final current = app.aiChannelFor(widget.groupId);
      final pal = Pal.of(context);
      target = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
        items: [
          PopupMenuItem(
            value: AppState.kAiNewSession,
            child: Row(children: [
              Icon(Icons.add_comment_outlined, size: 18, color: pal.accentText),
              const SizedBox(width: 10),
              Text(tr('Tạo phiên mới'), style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
          const PopupMenuDivider(),
          for (final c in sessions)
            PopupMenuItem(
              value: c.id,
              child: Row(children: [
                Icon(c.id == current?.id ? Icons.radio_button_checked : Icons.chat_bubble_outline,
                    size: 16, color: c.id == current?.id ? pal.accentText : pal.sub),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(tr('Thêm vào: {0}', [_sessionLabel(c)]), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
        ],
      );
      if (target == null) return;
    }
    if (!mounted) return;
    askAiAbout(context, app, group, post, target: target, open: false);
  }

  String _sessionLabel(MmChannel c) {
    final t = c.aiTitle;
    if (t.isNotEmpty) return t;
    return tr('Phiên chính');
  }

  // ---------------------------------------------------------------- thao tác phiên
  Future<String?> _askTitle(String title, String initial) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(hintText: tr('Tên phiên')),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
          TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text(tr('Lưu'))),
        ],
      ),
    );
  }

  Future<void> _sessionAction(String action, MmChannel c) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'rename':
          final t = await _askTitle(tr('Đổi tên phiên'), c.aiTitle);
          if (t != null) await app.renameAiSession(c, t);
        case 'fork':
          final t = await _askTitle(tr('Tách phiên'), '${_sessionLabel(c)} (2)');
          if (t == null) return;
          await app.forkAiSession(c, t);
          messenger.showSnackBar(toast(Text(tr('Đã tách phiên. Trợ lý nhớ những gì đã bàn ở phiên gốc.')), icon: Icons.call_split));
        case 'archive':
          final ok = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: Text(tr('Lưu trữ phiên "{0}"?', [_sessionLabel(c)])),
              content: Text(tr('Phiên sẽ ẩn khỏi danh sách. Trợ lý dừng làm việc ở phiên này.')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
                TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Lưu trữ'))),
              ],
            ),
          );
          if (ok != true) return;
          app.aiSelected.remove(widget.groupId);
          await app.archiveChannel(c.id);
      }
    } catch (_) {
      messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
    }
  }

  /// Thanh phiên ở đầu cột AI: các phiên (cuộn ngang), nút ＋ phiên mới, ⋯ thao tác với phiên đang mở.
  Widget _sessionBar(AppState app, Pal pal, List<MmChannel> sessions, MmChannel? current) {
    return Container(
      color: Color.alphaBlend(pal.accent.withValues(alpha: .07), pal.surface),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final c in sessions)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _SessionChip(
                    label: _sessionLabel(c),
                    selected: !_newSession && c.id == current?.id,
                    unread: app.unreadAllOf(c.id),
                    running: _running(app, c.id),
                    onTap: () {
                      setState(() => _newSession = false);
                      app.selectAiSession(widget.groupId, c.id);
                    },
                  ),
                ),
              if (_newSession)
                _SessionChip(label: tr('Phiên mới'), selected: true, unread: 0, running: false, onTap: () {}),
            ]),
          ),
        ),
        IconButton(
          tooltip: tr('Phiên mới'),
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.add_comment_outlined, color: pal.accentText, size: 20),
          onPressed: () => setState(() {
            _newSession = true;
            _ref = null;
          }),
        ),
        if (current != null && !_newSession)
          PopupMenuButton<String>(
            tooltip: tr('Thao tác với phiên'),
            icon: Icon(Icons.more_horiz, color: pal.sub, size: 20),
            onSelected: (a) => _sessionAction(a, current),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(tr('Đổi tên phiên'))),
              PopupMenuItem(value: 'fork', child: Text(tr('Tách phiên (fork)'))),
              PopupMenuItem(value: 'archive', child: Text(tr('Lưu trữ phiên'))),
            ],
          ),
      ]),
    );
  }

  /// Phiên đang có trợ lý chạy (thẻ tiến trình của tin mới nhất đang suy nghĩ / chạy / chờ).
  static bool _running(AppState app, String channelId) {
    final p = app.latest[channelId];
    final r = p == null ? null : agentRunOf(p);
    final s = r?['status'];
    return s == 'thinking' || s == 'running' || s == 'queued';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final sessions = app.aiChannelsFor(widget.groupId);
    final ai = app.aiChannelFor(widget.groupId);
    final Widget body;
    if (ai != null && !_newSession) {
      // Thanh phiên nằm trên cùng (điện thoại: tránh tai thỏ), trang chat bên dưới không chừa lề trên lần nữa.
      body = Column(children: [
        SafeArea(bottom: false, child: _sessionBar(app, pal, sessions, ai)),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: ChatPage(key: ValueKey('ai-${ai.id}'), channelId: ai.id, embedded: widget.embedded, onClose: widget.onClose),
          ),
        ),
      ]);
    } else {
      body = _intro(app, pal, sessions, ai);
    }
    return DragTarget<MmPost>(
      onWillAcceptWithDetails: (_) {
        setState(() => _dragOver = true);
        return true;
      },
      onLeave: (_) => setState(() => _dragOver = false),
      onAcceptWithDetails: (d) {
        setState(() => _dragOver = false);
        _onDrop(d.data, d.offset);
      },
      builder: (context, _, _) => Stack(children: [
        body,
        if (_dragOver)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: pal.accent.withValues(alpha: .10),
                  border: Border.all(color: pal.accent, width: 2),
                ),
                alignment: Alignment.center,
                child: Material(
                  color: pal.surface,
                  elevation: 3,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_awesome, color: pal.accentText),
                      const SizedBox(width: 10),
                      Text(tr('Thả để hỏi trợ lý'), style: TextStyle(fontWeight: FontWeight.w600, color: pal.text)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  /// Chưa có phiên nào, hoặc đang soạn tin đầu tiên của phiên mới.
  Widget _intro(AppState app, Pal pal, List<MmChannel> sessions, MmChannel? current) {
    final group = app.channels[widget.groupId];
    final bots = _bots;
    return Scaffold(
      backgroundColor: pal.chatBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(children: [
              if (widget.onClose != null)
                IconButton(icon: Icon(Icons.close, color: pal.text), onPressed: widget.onClose)
              else if (!widget.embedded)
                IconButton(icon: Icon(Icons.arrow_back, color: pal.text), onPressed: () => Navigator.maybePop(context))
              else
                const SizedBox(width: 12),
              Icon(Icons.auto_awesome, color: pal.accentText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('Trợ lý AI · {0}', [group == null ? '' : app.channelTitle(group)]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
              ),
            ]),
          ),
          if (sessions.isNotEmpty) _sessionBar(app, pal, sessions, current),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(sessions.isEmpty ? Icons.auto_awesome : Icons.add_comment_outlined, size: 46, color: pal.accentText),
                  const SizedBox(height: 12),
                  Text(sessions.isEmpty ? tr('Hỏi trợ lý về nhóm này') : tr('Phiên làm việc mới'),
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
                  const SizedBox(height: 6),
                  Text(
                      sessions.isEmpty
                          ? tr('Trợ lý đọc được tin nhắn của nhóm. Cuộc trò chuyện ở đây chỉ mình bạn thấy.')
                          : tr('Mỗi phiên xử lý một việc riêng, chạy song song với các phiên khác.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: pal.sub)),
                  if (isDesktop) ...[
                    const SizedBox(height: 6),
                    Text(tr('Mẹo: giữ chuột lên một tin ở chat chính rồi kéo sang đây.'),
                        textAlign: TextAlign.center, style: TextStyle(color: pal.sub, fontSize: 12.5)),
                  ],
                  const SizedBox(height: 16),
                  if (bots == null)
                    const CircularProgressIndicator()
                  else if (bots.isEmpty) ...[
                    Text(tr('Bạn chưa có trợ lý AI.'), style: TextStyle(color: pal.sub)),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentPage())),
                      icon: const Icon(Icons.add),
                      label: Text(tr('Tạo trợ lý AI')),
                    ),
                  ] else
                    Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                      for (final b in bots)
                        ChoiceChip(
                          selected: _target == b.username,
                          showCheckmark: false,
                          avatar: EngineIcon(b.engine, size: 16, color: pal.text),
                          label: Text('@${b.username}'),
                          onSelected: (_) => setState(() => _target = b.username),
                        ),
                    ]),
                ]),
              ),
            ),
          ),
          if (bots != null && bots.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendFirst(),
                    style: TextStyle(color: pal.text, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: tr('Nhắn cho trợ lý…'),
                      filled: true,
                      fillColor: pal.surface,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                  onPressed: _sending ? null : _sendFirst,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Một phiên trong thanh phiên: tên, vòng quay khi trợ lý đang chạy, số tin chưa đọc.
class _SessionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final int unread;
  final bool running;
  final VoidCallback onTap;
  const _SessionChip(
      {required this.label, required this.selected, required this.unread, required this.running, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: selected ? pal.accent.withValues(alpha: .18) : pal.chatBg,
      shape: StadiumBorder(side: BorderSide(color: selected ? pal.accent : pal.text.withValues(alpha: .12))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (running) ...[
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: pal.accentText)),
              const SizedBox(width: 6),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: selected ? pal.accentText : pal.text,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
            ),
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(10)),
                child: Text('$unread', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Điện thoại: mở trợ lý AI của nhóm thành trang riêng.
void openAiPanel(BuildContext context, String groupId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiPanel(groupId: groupId, embedded: false)));
