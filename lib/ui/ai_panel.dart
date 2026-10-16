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

/// Thanh "đang gửi kèm tin" phía trên ô nhắn tin của cột AI (giống thanh trả lời): tên người gửi, xem trước tin,
/// nhãn "cả luồng", nút ✕ bỏ đính kèm. [ref] là flygo_ai_ref, [quote] là trích dẫn dự phòng khi tin không có ở máy.
class AiRefBar extends StatelessWidget {
  final Map<String, dynamic> ref;
  final String quote;
  final VoidCallback onCancel;
  const AiRefBar({super.key, required this.ref, required this.quote, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final p = app.findPost(ref['channel_id'] as String? ?? '', ref['post_id'] as String? ?? '');
    final uid = p?.userId ?? '';
    final who = p == null ? '' : (uid == app.me?.id ? tr('Bạn') : app.users[uid]?.displayName ?? '');
    final preview = p != null ? app.previewText(p) : quote.replaceFirst(RegExp(r'^>\s*'), '').replaceAll('**', '').trim();
    final where = app.channels[ref['channel_id']];
    final thread = (ref['root_id'] as String?)?.isNotEmpty == true;
    final color = uid.isEmpty ? pal.accentText : WaColors.sender(uid);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 4, color: color),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.reply_rounded, size: 15, color: color),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                        [
                          if (who.isNotEmpty) who,
                          if (where != null) app.channelTitle(where),
                          if (thread) tr('(cả luồng)'),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13.5)),
                  ),
                ]),
                Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13.5)),
              ]),
            ),
          ),
          IconButton(tooltip: tr('Bỏ đính kèm'), icon: Icon(Icons.close, size: 18, color: pal.sub), onPressed: onCancel),
        ]),
      ),
    );
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
  String _quote = '';

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
        // Tin đính kèm hiện thành thanh "đang gửi kèm" phía trên ô nhắn tin; ô nhắn tin để trống cho lời dặn.
        if (v.ref != null) {
          _ref = v.ref;
          _quote = v.text;
        } else if (v.text.isNotEmpty) {
          _ctl.text = v.text;
        }
      });
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
    AgentService.instance.myBots(context.read<AppState>()).then((b) async {
      // Nhóm đã có trợ lý của mình thì phiên mới mặc định dùng đúng trợ lý đó (mỗi chat một trợ lý).
      final inGroup = await _app.assistantIn(widget.groupId).catchError((_) => null);
      if (mounted) {
        setState(() {
          _bots = b;
          _target = (b.where((x) => x.id == inGroup).firstOrNull ?? b.firstOrNull)?.username;
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
    final ref = _ref;
    if (group == null || (text.isEmpty && ref == null) || bots.isEmpty || _sending) return;
    if (ref != null) text = '$_quote$text'.trim();
    // Mỗi phiên một trợ lý: phiên mới dùng trợ lý đang chọn.
    final pick = bots.where((b) => b.username == _target).firstOrNull ?? bots.first;
    setState(() => _sending = true);
    try {
      final c = await app.createAiChannel(group, [pick.id], title: _titleFrom(text));
      await app.send(c.id, text, props: {'flygo_ai_ref': ?ref});
      _ctl.clear();
      _ref = null;
      _quote = '';
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
  Future<void> _onDrop(MmPost post) async {
    final app = context.read<AppState>();
    final group = app.channels[widget.groupId];
    if (group == null) return;
    var target = AppState.kAiNewSession;
    if (app.aiChannelsFor(widget.groupId).isNotEmpty) {
      final t = await showAiSessions(context, widget.groupId, sendMode: true);
      if (t == null) return;
      target = t;
    }
    if (!mounted) return;
    askAiAbout(context, app, group, post, target: target, open: false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final sessions = app.aiChannelsFor(widget.groupId);
    final ai = app.aiChannelFor(widget.groupId);
    final Widget body;
    // ⋮ "Phiên mới" (trong trang chat của phiên) → chuyển sang soạn tin đầu tiên của phiên mới.
    if (ai != null && !_newSession) {
      // Tên chat ở đầu trang là danh sách phiên (bấm để đổi phiên); ⋮ là phiên mới / đổi tên / tách / lưu trữ.
      body = ChatPage(key: ValueKey('ai-${ai.id}'), channelId: ai.id, embedded: widget.embedded, onClose: widget.onClose);
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
        _onDrop(d.data);
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
              Expanded(
                child: sessions.isEmpty
                    ? Row(children: [
                        Icon(Icons.auto_awesome, color: pal.accentText),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(tr('Trợ lý AI · {0}', [group == null ? '' : app.channelTitle(group)]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
                        ),
                      ])
                    : AiSessionTitle(
                        groupId: widget.groupId,
                        label: tr('Phiên mới'),
                        selectedId: null,
                        onPicked: (id) {
                          setState(() => _newSession = false);
                          app.selectAiSession(widget.groupId, id);
                        },
                      ),
              ),
            ]),
          ),
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
          if (bots != null && bots.isNotEmpty && _ref != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
              child: AiRefBar(ref: _ref!, quote: _quote, onCancel: () => setState(() {
                _ref = null;
                _quote = '';
              })),
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
                      hintText: _ref != null ? tr('Dặn trợ lý cần làm gì với tin này…') : tr('Nhắn cho trợ lý…'),
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

/// Điện thoại: mở trợ lý AI của nhóm thành trang riêng.
void openAiPanel(BuildContext context, String groupId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiPanel(groupId: groupId, embedded: false)));

// ---------------------------------------------------------------- danh sách phiên + thao tác phiên
String aiSessionLabel(MmChannel c) => c.aiTitle.isNotEmpty ? c.aiTitle : tr('Phiên chính');

/// Trạng thái một phiên AI (theo tin mới nhất): đang chạy / chờ duyệt / xếp hàng / chờ trợ lý / xong / lỗi / đã dừng.
enum AiSessionState { running, approval, queued, waiting, done, error, stopped, idle }

AiSessionState aiSessionState(AppState app, MmChannel c) {
  final p = app.latest[c.id];
  if (p == null) return AiSessionState.idle;
  final r = agentRunOf(p);
  switch (r?['status']) {
    case 'thinking' || 'running':
      return AiSessionState.running;
    case 'awaiting_approval':
      return AiSessionState.approval;
    case 'queued':
      return AiSessionState.queued;
    case 'error':
      return AiSessionState.error;
    case 'stopped':
      return AiSessionState.stopped;
    case 'done':
      return AiSessionState.done;
  }
  // Tin cuối là của mình: đang chờ trợ lý nhận việc.
  if (p.userId == app.me?.id) return AiSessionState.waiting;
  return AiSessionState.done;
}

bool aiSessionRunning(AppState app, String channelId) {
  final c = app.channels[channelId];
  if (c == null) return false;
  final st = aiSessionState(app, c);
  return st == AiSessionState.running || st == AiSessionState.queued || st == AiSessionState.waiting;
}

/// Biểu tượng trạng thái: vòng quay khi đang chạy, chấm nhấp nháy khi chờ, dấu tích khi xong.
class AiStatusIcon extends StatefulWidget {
  final AiSessionState state;
  final double size;
  const AiStatusIcon(this.state, {super.key, this.size = 22});
  @override
  State<AiStatusIcon> createState() => _AiStatusIconState();
}

class _AiStatusIconState extends State<AiStatusIcon> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final sz = widget.size;
    Widget pulsing(IconData i, Color c) => FadeTransition(
        opacity: Tween(begin: .35, end: 1.0).animate(_pulse), child: Icon(i, size: sz, color: c));
    return SizedBox(
      width: sz,
      height: sz,
      child: switch (widget.state) {
        AiSessionState.running => CircularProgressIndicator(strokeWidth: 2.4, color: pal.accentText),
        AiSessionState.approval => pulsing(Icons.pause_circle_filled_rounded, Colors.orange),
        AiSessionState.queued => pulsing(Icons.hourglass_top_rounded, pal.sub),
        AiSessionState.waiting => pulsing(Icons.more_horiz_rounded, pal.accentText),
        AiSessionState.done => const Icon(Icons.check_circle_rounded, color: Color(0xFF2E9E5B)),
        AiSessionState.error => const Icon(Icons.error_rounded, color: Colors.redAccent),
        AiSessionState.stopped => Icon(Icons.stop_circle_outlined, color: pal.sub),
        AiSessionState.idle => Icon(Icons.chat_bubble_outline, size: sz - 2, color: pal.sub),
      },
    );
  }
}

String aiStateText(AiSessionState s) => switch (s) {
      AiSessionState.running => tr('Đang chạy'),
      AiSessionState.approval => tr('Chờ bạn duyệt'),
      AiSessionState.queued => tr('Đang xếp hàng'),
      AiSessionState.waiting => tr('Chờ trợ lý'),
      AiSessionState.done => tr('Đã trả lời'),
      AiSessionState.error => tr('Lỗi'),
      AiSessionState.stopped => tr('Đã dừng'),
      AiSessionState.idle => tr('Chưa có tin'),
    };

/// Popup lớn: danh sách phiên AI của nhóm (đang làm ở trên, đã xong ở dưới), trạng thái rõ ràng.
/// Bấm = chọn phiên; bấm giữ = tách / đổi tên / xong / lưu trữ; cuối danh sách có "Tạo phiên mới".
/// [sendMode]: chọn phiên để gửi tin vào ("Gửi cho trợ lý", kéo thả). Trả về id phiên hoặc [AppState.kAiNewSession].
Future<String?> showAiSessions(BuildContext context, String groupId, {bool sendMode = false}) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  Widget body(BuildContext ctx) => _AiSessionList(groupId: groupId, sendMode: sendMode);
  if (wide) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640), child: body(ctx)),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * .8, child: body(ctx)),
  );
}

class _AiSessionList extends StatelessWidget {
  final String groupId;
  final bool sendMode;
  const _AiSessionList({required this.groupId, required this.sendMode});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final group = app.channels[groupId];
    final all = app.aiChannelsFor(groupId);
    final open = all.where((c) => !c.aiDone).toList();
    final done = all.where((c) => c.aiDone).toList();
    final current = app.aiChannelFor(groupId)?.id;
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text(t.toUpperCase(),
              style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w700, color: pal.sub)),
        );
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
        child: Row(children: [
          Icon(sendMode ? Icons.send_rounded : Icons.auto_awesome, color: pal.accentText),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(sendMode ? tr('Gửi cho trợ lý') : tr('Các phiên với trợ lý'),
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: pal.text)),
              Text(group == null ? '' : app.channelTitle(group),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
            ]),
          ),
          IconButton(icon: Icon(Icons.close, color: pal.sub), onPressed: () => Navigator.pop(context)),
        ]),
      ),
      if (!sendMode)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(tr('Bấm để mở phiên, bấm giữ để tách / đổi tên / đánh dấu xong.'),
              style: TextStyle(fontSize: 12.5, color: pal.sub)),
        ),
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 8), children: [
          if (open.isNotEmpty) header(tr('Đang làm')),
          for (final c in open) _AiSessionTile(channel: c, selected: c.id == current && !sendMode),
          if (done.isNotEmpty) header(tr('Đã xong')),
          for (final c in done) _AiSessionTile(channel: c, selected: c.id == current && !sendMode),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                side: BorderSide(color: pal.accent),
              ),
              onPressed: () => Navigator.pop(context, AppState.kAiNewSession),
              icon: Icon(Icons.add_comment_outlined, color: pal.accentText),
              label: Text(tr('Tạo phiên mới'),
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: pal.accentText)),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _AiSessionTile extends StatelessWidget {
  final MmChannel channel;
  final bool selected;
  const _AiSessionTile({required this.channel, required this.selected});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final c = channel;
    final st = aiSessionState(app, c);
    final last = app.latest[c.id];
    final unread = app.unreadAllOf(c.id);
    final preview = last == null ? '' : app.previewText(last).replaceAll('\n', ' ');
    final at = last?.createAt ?? (c.lastPostAt > 0 ? c.lastPostAt : c.createAt);
    final busy = st == AiSessionState.running || st == AiSessionState.approval;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? pal.accent.withValues(alpha: .12) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.pop(context, c.id),
          onLongPress: () => _sessionOptions(context, c),
          onSecondaryTap: () => _sessionOptions(context, c),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: busy ? pal.accent.withValues(alpha: .14) : pal.text.withValues(alpha: .05),
                ),
                child: AiStatusIcon(st),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(aiSessionLabel(c),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: unread > 0 || selected ? FontWeight.w700 : FontWeight.w600,
                              color: c.aiDone ? pal.sub : pal.text)),
                    ),
                    const SizedBox(width: 8),
                    Text(listTime(at), style: TextStyle(fontSize: 12, color: unread > 0 ? pal.accentText : pal.sub)),
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    Text(aiStateText(st),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: switch (st) {
                              AiSessionState.running || AiSessionState.waiting => pal.accentText,
                              AiSessionState.approval => Colors.orange,
                              AiSessionState.error => Colors.redAccent,
                              AiSessionState.done => const Color(0xFF2E9E5B),
                              _ => pal.sub,
                            })),
                    if (preview.isNotEmpty) ...[
                      Text(' · ', style: TextStyle(color: pal.sub)),
                      Expanded(
                        child: Text(preview,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
                      ),
                    ] else
                      const Spacer(),
                    if (unread > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(10)),
                        child: Text('$unread',
                            style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _sessionOptions(BuildContext context, MmChannel c) async {
    final pal = Pal.of(context);
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(aiSessionLabel(c),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          for (final (v, i, t) in _sessionActions(c))
            ListTile(leading: Icon(i, color: pal.sub), title: Text(t), onTap: () => Navigator.pop(ctx, v)),
        ]),
      ),
    );
    if (a != null && context.mounted) await runAiSessionAction(context, c, a);
  }
}

List<(String, IconData, String)> _sessionActions(MmChannel c) => [
      ('fork', Icons.call_split, tr('Tách phiên (fork)')),
      ('rename', Icons.edit_outlined, tr('Đổi tên phiên')),
      c.aiDone
          ? ('undone', Icons.replay_rounded, tr('Mở lại phiên'))
          : ('done', Icons.check_circle_outline_rounded, tr('Đánh dấu xong')),
      ('archive', Icons.archive_outlined, tr('Lưu trữ phiên')),
    ];

Future<String?> _askTitle(BuildContext context, String title, String initial) {
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

/// Thao tác với một phiên AI: new / fork / rename / done / undone / archive.
Future<void> runAiSessionAction(BuildContext context, MmChannel c, String action) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final groupId = c.aiGroup;
  if (groupId == null) return;
  try {
    switch (action) {
      case 'new':
        app.aiAsk.value = (groupId: groupId, text: '', target: AppState.kAiNewSession, ref: null);
      case 'rename':
        final t = await _askTitle(context, tr('Đổi tên phiên'), c.aiTitle);
        if (t != null) await app.renameAiSession(c, t);
      case 'fork':
        final t = await _askTitle(context, tr('Tách phiên'), '${aiSessionLabel(c)} (2)');
        if (t == null) return;
        await app.forkAiSession(c, t);
        messenger.showSnackBar(toast(Text(tr('Đã tách phiên. Trợ lý nhớ những gì đã bàn ở phiên gốc.')), icon: Icons.call_split));
      case 'done':
        await app.setAiDone(c, true);
        messenger.showSnackBar(toast(Text(tr('Đã đánh dấu xong')), icon: Icons.check_circle_rounded));
      case 'undone':
        await app.setAiDone(c, false);
      case 'archive':
        if (!context.mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text(tr('Lưu trữ phiên "{0}"?', [aiSessionLabel(c)])),
            content: Text(tr('Phiên sẽ ẩn khỏi danh sách. Trợ lý dừng làm việc ở phiên này.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
              TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Lưu trữ'))),
            ],
          ),
        );
        if (ok != true) return;
        if (app.aiSelected[groupId] == c.id) app.aiSelected.remove(groupId);
        await app.archiveChannel(c.id);
    }
  } catch (_) {
    messenger.showSnackBar(toast(Text(tr('Không thực hiện được. Kiểm tra kết nối mạng.'))));
  }
}

/// Tên chat ở đầu cột AI: bấm mở popup danh sách phiên.
class AiSessionTitle extends StatelessWidget {
  final String groupId;
  final String label;
  final String? selectedId;
  /// Mặc định: chọn phiên đó làm phiên đang mở ("＋ Tạo phiên mới" → soạn tin đầu của phiên mới).
  final void Function(String channelId)? onPicked;
  const AiSessionTitle({super.key, required this.groupId, required this.label, required this.selectedId, this.onPicked});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final group = app.channels[groupId];
    final sessions = app.aiChannelsFor(groupId);
    final otherUnread = sessions.where((c) => c.id != selectedId).fold<int>(0, (n, c) => n + app.unreadAllOf(c.id));
    final otherBusy = sessions.where((c) => c.id != selectedId && aiSessionRunning(app, c.id)).length;
    final cur = app.channels[selectedId];
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final id = await showAiSessions(context, groupId);
        if (id == null) return;
        if (id == AppState.kAiNewSession) {
          app.aiAsk.value = (groupId: groupId, text: '', target: AppState.kAiNewSession, ref: null);
        } else if (onPicked != null) {
          onPicked!(id);
        } else {
          app.selectAiSession(groupId, id);
        }
      },
      child: Row(children: [
        Badge(
          isLabelVisible: otherUnread > 0,
          smallSize: 8,
          child: cur == null ? Icon(Icons.auto_awesome, color: pal.accentText) : AiStatusIcon(aiSessionState(app, cur), size: 22),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Row(children: [
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              Icon(Icons.arrow_drop_down, color: pal.text),
            ]),
            Text(
                otherBusy > 0
                    ? tr('{0} phiên khác đang chạy', [otherBusy])
                    : tr('Trợ lý AI · {0}', [group == null ? '' : app.channelTitle(group)]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: otherBusy > 0 ? pal.accentText : pal.sub)),
          ]),
        ),
      ]),
    );
  }
}

/// ⋮ góc phải của phiên AI: phiên mới, tách, đổi tên, xong, lưu trữ.
class AiSessionMenu extends StatelessWidget {
  final MmChannel channel;
  const AiSessionMenu({super.key, required this.channel});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return PopupMenuButton<String>(
      tooltip: tr('Thao tác với phiên'),
      icon: Icon(Icons.more_vert, color: pal.text),
      onSelected: (a) => runAiSessionAction(context, channel, a),
      itemBuilder: (_) => [
        for (final (v, i, t) in [('new', Icons.add_comment_outlined, tr('Phiên mới')), ..._sessionActions(channel)])
          PopupMenuItem(
            value: v,
            child: Row(children: [Icon(i, size: 18, color: pal.sub), const SizedBox(width: 12), Text(t)]),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- kết nối agent khác (A2A)
/// Chọn agent khác để trao đổi qua A2A: các phiên AI của mình (mọi nhóm, chưa xong) và các chat / luồng mà trợ lý
/// của mình đang làm dở. Mỗi mục hiện trạng thái, nhóm, giờ và tin gần nhất để biết agent đang làm tới đâu.
/// Trả về {session_id, bot_id, username, title, group} hoặc null.
Future<Map<String, dynamic>?> pickA2aPeer(BuildContext context, String currentId) {
  final app = context.read<AppState>();
  int at(MmChannel c) => app.latest[c.id]?.createAt ?? (c.lastPostAt > 0 ? c.lastPostAt : c.createAt);
  final sessions = app.channels.values
      .where((c) => c.isAi && c.aiOwner == app.me?.id && c.deleteAt == 0 && !c.aiDone && c.id != currentId)
      .toList()
    ..sort((a, b) => at(b).compareTo(at(a)));
  // Chat thường (nhóm, kênh, luồng bí mật) mà tin mới nhất là của trợ lý của mình.
  final chats = app.channels.values.where((c) {
    if (c.isAi || c.deleteAt != 0 || c.id == currentId) return false;
    final p = app.latest[c.id];
    return p != null && app.isMyBot(p.userId) && agentRunOf(p) != null;
  }).toList()
    ..sort((a, b) => at(b).compareTo(at(a)));
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      Widget header(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Text(t.toUpperCase(),
                style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w700, color: pal.sub)),
          );
      Widget tile(MmChannel c, {required bool session}) {
        final last = app.latest[c.id];
        final st = session ? aiSessionState(app, c) : _chatState(app, last);
        final group = session ? app.channels[c.aiGroup] : null;
        final title = session ? aiSessionLabel(c) : app.channelTitle(c);
        final where = session ? (group == null ? '' : app.channelTitle(group)) : _chatKind(c);
        final preview = last == null ? '' : app.previewText(last).replaceAll('\n', ' ');
        return InkWell(
          onTap: () async {
            final nav = Navigator.of(ctx);
            MmUser? bot;
            if (!session && last != null && app.isMyBot(last.userId)) bot = app.users[last.userId];
            bot ??= (await app.channelUsers(c.id)).where((u) => u.isBot && app.isAssistant(u.id)).firstOrNull;
            if (bot == null) {
              nav.pop();
              return;
            }
            nav.pop(<String, dynamic>{
              'session_id': c.id,
              'bot_id': bot.id,
              'username': bot.username,
              'title': title,
              'group': session ? c.aiGroup : c.id,
              'kind': session ? 'ai_session' : 'chat',
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: pal.text.withValues(alpha: .05)),
                child: AiStatusIcon(st),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: pal.text)),
                    ),
                    Text(listTime(at(c)), style: TextStyle(fontSize: 12, color: pal.sub)),
                  ]),
                  Text(
                      [
                        aiStateText(st),
                        if (where.isNotEmpty) where,
                        if (last != null && app.users[last.userId]?.isBot == true) '@${app.users[last.userId]!.username}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: pal.accentText)),
                  if (preview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(preview,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
                    ),
                ]),
              ),
            ]),
          ),
        );
      }

      return SizedBox(
        height: MediaQuery.sizeOf(ctx).height * .8,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(tr('Kết nối agent khác'), style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(tr('Trợ lý của phiên này sẽ trao đổi trực tiếp với agent được chọn (A2A) để giao việc chéo.'),
                style: TextStyle(fontSize: 13, color: pal.sub)),
          ),
          Expanded(
            child: sessions.isEmpty && chats.isEmpty
                ? Center(child: Text(tr('Chưa có phiên AI nào khác đang làm.'), style: TextStyle(color: pal.sub)))
                : ListView(children: [
                    if (sessions.isNotEmpty) header(tr('Phiên AI của tôi')),
                    for (final c in sessions) tile(c, session: true),
                    if (chats.isNotEmpty) header(tr('Trợ lý đang làm trong các chat')),
                    for (final c in chats) tile(c, session: false),
                  ]),
          ),
        ]),
      );
    },
  );
}

AiSessionState _chatState(AppState app, MmPost? p) {
  final r = p == null ? null : agentRunOf(p);
  return switch (r?['status']) {
    'thinking' || 'running' => AiSessionState.running,
    'awaiting_approval' => AiSessionState.approval,
    'queued' => AiSessionState.queued,
    'error' => AiSessionState.error,
    'stopped' => AiSessionState.stopped,
    'done' => AiSessionState.done,
    _ => AiSessionState.idle,
  };
}

String _chatKind(MmChannel c) =>
    c.isSub ? tr('Luồng bí mật') : (c.isDirect ? tr('Chat riêng') : (c.isGroupDm ? tr('Nhóm nhỏ') : tr('Nhóm')));
