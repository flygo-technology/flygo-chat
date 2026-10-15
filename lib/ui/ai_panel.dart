import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import '../state/app_state.dart';
import 'agent_page.dart';
import 'chat_page.dart';
import 'common.dart';
import 'theme.dart';

/// Cột phải "Trợ lý AI" của một nhóm: chat riêng của mình với các trợ lý AI của mình, gắn với nhóm đó.
/// Chưa nhắn lần nào thì chỉ hiện ô nhắn tin; tin đầu tiên mới tạo chat (kênh riêng tư mình + bot).
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

  late final AppState _app;

  /// "Hỏi trợ lý" khi chưa có chat AI: điền sẵn trích dẫn vào ô nhắn tin đầu tiên.
  void _onAsk() {
    final v = _app.aiAsk.value;
    if (v == null || v.groupId != widget.groupId || !mounted || _app.aiChannelFor(widget.groupId) != null) return;
    _app.aiAsk.value = null;
    _ctl.text = v.text;
    _ctl.selection = TextSelection.collapsed(offset: v.text.length);
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
  void dispose() {
    _app.aiAsk.removeListener(_onAsk);
    _ctl.dispose();
    super.dispose();
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
      final c = await app.createAiChannel(group, [for (final b in bots) b.id]);
      await app.send(c.id, text);
      _ctl.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('Không tạo được chat với trợ lý. Kiểm tra kết nối mạng.'))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final ai = app.aiChannelFor(widget.groupId);
    if (ai != null) {
      return ChatPage(key: ValueKey('ai-${ai.id}'), channelId: ai.id, embedded: widget.embedded, onClose: widget.onClose);
    }
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
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.auto_awesome, size: 46, color: pal.accentText),
                  const SizedBox(height: 12),
                  Text(tr('Hỏi trợ lý về nhóm này'),
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
                  const SizedBox(height: 6),
                  Text(tr('Trợ lý đọc được tin nhắn của nhóm. Cuộc trò chuyện ở đây chỉ mình bạn thấy.'),
                      textAlign: TextAlign.center, style: TextStyle(color: pal.sub)),
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

/// Điện thoại: mở trợ lý AI của nhóm thành trang riêng.
void openAiPanel(BuildContext context, String groupId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiPanel(groupId: groupId, embedded: false)));
