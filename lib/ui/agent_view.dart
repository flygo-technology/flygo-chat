import '../i18n/i18n.dart';
import '../agent/agent_config.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

/// Hiển thị tin của bot AI (runner flygo-agent):
/// - props.flygo_agent: thẻ tiến trình (trạng thái + các bước), được sửa liên tục.
/// - props.flygo_agent_message: tin trả lời, nội dung markdown được sửa dần khi đang stream.
/// - props.flygo_agent_approval: yêu cầu duyệt — nút "Xác nhận" / "Từ chối" gửi cảm xúc +1 / -1.

Map<String, dynamic>? agentRunOf(MmPost p) => (p.props['flygo_agent'] as Map?)?.cast<String, dynamic>();
Map<String, dynamic>? agentMessageOf(MmPost p) => (p.props['flygo_agent_message'] as Map?)?.cast<String, dynamic>();
Map<String, dynamic>? agentApprovalOf(MmPost p) => (p.props['flygo_agent_approval'] as Map?)?.cast<String, dynamic>();

bool isAgentPost(MmPost p) => agentRunOf(p) != null || agentMessageOf(p) != null || agentApprovalOf(p) != null;

/// Nội dung hiển thị: bỏ dòng hashtag lọc (#flygo_ai #ai_...) và dòng "Thả 👍/👎" dự phòng cho client khác.
String agentDisplayText(MmPost p) {
  if (!isAgentPost(p)) return p.message;
  final lines = p.message.split('\n').where((l) {
    final t = l.trim();
    if (t.startsWith('#flygo_ai') || RegExp(r'^(#ai_\w+\s*)+$').hasMatch(t)) return false;
    if (t.contains(r'Thả 👍') || t.contains(r'Thả 👎')) return false;
    return true;
  }).toList();
  var out = lines.join('\n').trim();
  // Tin cuối mở đầu bằng "@chủ-việc" (để chủ việc nhận thông báo): bỏ cho gọn.
  if (p.props['flygo_agent_owner'] != null) out = out.replaceFirst(RegExp(r'^@[\w.\-]+\s*'), '');
  return out;
}

String _statusLabel(String s) => switch (s) {
  'thinking' => tr('Đang suy nghĩ'),
  'running' => tr('Đang làm'),
  'awaiting_approval' => tr('Chờ duyệt'),
  'done' => tr('Xong'),
  'error' => tr('Lỗi'),
  'cancelled' => tr('Đã dừng'),
  _ => s,
};

Color _statusColor(String s, Pal pal) => switch (s) {
  'done' => const Color(0xFF2E9D5B),
  'error' => Colors.redAccent,
  'awaiting_approval' => const Color(0xFFF5A623),
  'cancelled' => pal.sub,
  _ => pal.accentText,
};

IconData _kindIcon(String kind) => switch (kind) {
  'command' => Icons.terminal_rounded,
  'file' => Icons.description_outlined,
  'tool' => Icons.build_outlined,
  'search' => Icons.search_rounded,
  'thinking' => Icons.psychology_outlined,
  'approval' => Icons.verified_user_outlined,
  _ => Icons.circle_outlined,
};

/// Thẻ tiến trình: một dòng gọn (vòng quay + tên việc + "đang làm · N bước"), bấm để xem các bước.
class AgentRunCard extends StatefulWidget {
  final Map<String, dynamic> run;

  /// Gọn: không hiện tên việc (nằm chung với câu trả lời), chữ nhỏ hơn.
  final bool compact;

  /// Dạng gọn: tên bot đặt ngay sau biểu tượng trạng thái, cùng dòng với mô hình + mức suy nghĩ.
  final Widget? name;
  const AgentRunCard({super.key, required this.run, this.compact = false, this.name});
  @override
  State<AgentRunCard> createState() => _AgentRunCardState();
}

class _AgentRunCardState extends State<AgentRunCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final r = widget.run;
    final status = r['status'] as String? ?? 'running';
    final steps = [for (final s in (r['steps'] as List? ?? const [])) (s as Map).cast<String, dynamic>()];
    final active = status == 'thinking' || status == 'running';
    final title = (r['title'] as String? ?? '').trim();
    final engine = r['engine'] as String? ?? '';
    final error = r['error'] as String?;
    // Mô hình + mức suy nghĩ đã dùng cho lượt này (runner 0.3+ ghi vào config).
    final cfg = (r['config'] as Map?)?.cast<String, dynamic>();
    final cfgText = cfg == null
        ? ''
        : [cfg['model'], if (cfg['effort'] != null) effortLabel(cfg['effort'] as String)].whereType<String>().join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: steps.isEmpty ? null : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: active
                      ? CircularProgressIndicator(strokeWidth: 2, color: pal.accentText)
                      : Icon(
                          status == 'done'
                              ? Icons.check_circle_rounded
                              : status == 'error'
                              ? Icons.error_rounded
                              : status == 'awaiting_approval'
                              ? Icons.pause_circle_filled_rounded
                              : Icons.stop_circle_outlined,
                          size: 16,
                          color: _statusColor(status, pal),
                        ),
                ),
                const SizedBox(width: 8),
                if (!widget.compact)
                  Flexible(
                    child: Text(
                      title.isEmpty ? (engine.isEmpty ? tr('Trợ lý AI') : engine) : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: pal.text),
                    ),
                  ),
                if (!widget.compact) const SizedBox(width: 8),
                // Dạng gọn (trong câu trả lời): chỉ biểu tượng trạng thái, tên mô hình và vạch mức suy nghĩ.
                if (!widget.compact)
                  Text(
                    steps.isEmpty ? _statusLabel(status) : tr('{0} · {1} bước', [_statusLabel(status).toLowerCase(), steps.length]),
                    style: TextStyle(fontSize: 13, color: _statusColor(status, pal)),
                  ),
                if (!widget.compact && cfgText.isNotEmpty) Text(' · $cfgText', style: TextStyle(fontSize: 12.5, color: pal.sub)),
                if (widget.compact) ...[
                  EngineIcon(engine, size: 15, color: pal.text),
                  const SizedBox(width: 6),
                ],
                if (widget.compact && widget.name != null) Flexible(child: widget.name!),
                if (widget.compact && cfg?['model'] != null) ...[
                  Text('${widget.name != null ? ' · ' : ''}${cfg!['model']}', style: TextStyle(fontSize: 12.5, color: pal.sub)),
                  const SizedBox(width: 6),
                ],
                if (widget.compact && cfg?['effort'] != null)
                  Tooltip(message: effortLabel(cfg!['effort'] as String), child: EffortBars(effort: cfg['effort'] as String, color: pal.sub)),
                if (steps.isNotEmpty) Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: pal.sub),
              ],
            ),
          ),
        ),
        if ((cfg?['note'] as String? ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              cfg!['note'] as String,
              style: TextStyle(fontSize: 12.5, color: pal.sub, fontStyle: FontStyle.italic),
            ),
          ),
        if (error != null && error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error, style: const TextStyle(fontSize: 13, color: Colors.redAccent)),
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: 0)
              : Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final s in steps) _StepRow(step: s)],
                  ),
                ),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final Map<String, dynamic> step;
  const _StepRow({required this.step});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final status = step['status'] as String? ?? 'done';
    final detail = (step['detail'] as String? ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: status == 'running'
                ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: pal.accentText))
                : Icon(
                    status == 'error'
                        ? Icons.error_outline
                        : status == 'waiting'
                        ? Icons.hourglass_top_rounded
                        : _kindIcon(step['kind'] as String? ?? ''),
                    size: 15,
                    color: status == 'error' ? Colors.redAccent : pal.sub,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AgentTitle(step['title'] as String? ?? '', style: TextStyle(fontSize: 13.5, color: pal.text)),
                if (detail.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(color: pal.text.withValues(alpha: .06), borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      detail,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: pal.sub, height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiêu đề bước / yêu cầu duyệt. Runner ghi lệnh shell dạng "\$ lệnh" (có thể sau "Chờ duyệt: "):
/// bỏ "\$ " và hiện lệnh như một khối bash (chữ đơn cách, tên lệnh tô màu).
class AgentTitle extends StatelessWidget {
  final String title;
  final TextStyle style;
  const AgentTitle(this.title, {super.key, required this.style});

  static final _cmd = RegExp(r'^(.*?:\s*)?\$ (.+)$', dotAll: true);

  @override
  Widget build(BuildContext context) {
    final m = _cmd.firstMatch(title);
    if (m == null) return Text(title, style: style);
    final pal = Pal.of(context);
    final label = (m.group(1) ?? '').trim();
    final cmd = m.group(2)!.trim();
    final sp = cmd.indexOf(RegExp(r'\s'));
    final head = sp < 0 ? cmd : cmd.substring(0, sp);
    final rest = sp < 0 ? '' : cmd.substring(sp);
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.35, color: pal.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (label.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(label, style: style)),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
        decoration: BoxDecoration(
          color: pal.text.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: pal.text.withValues(alpha: .08)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('bash', style: TextStyle(fontSize: 10, color: pal.sub, fontWeight: FontWeight.w600, letterSpacing: .4)),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(style: mono, children: [
              TextSpan(text: head, style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
              TextSpan(text: rest),
            ]),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ]),
      ),
    ]);
  }
}

/// Con trỏ nhấp nháy cuối tin đang được bot viết dần.
class StreamingCursor extends StatefulWidget {
  const StreamingCursor({super.key});
  @override
  State<StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<StreamingCursor> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _c,
    child: Container(width: 8, height: 16, margin: const EdgeInsets.only(top: 2), color: Pal.of(context).accentText),
  );
}

/// Yêu cầu duyệt của bot: đang chờ thì hiện 2 nút, xong thì hiện kết quả.
class AgentApprovalBar extends StatelessWidget {
  final MmPost post;
  final Map<String, dynamic> approval;
  const AgentApprovalBar({super.key, required this.post, required this.approval});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final status = approval['status'] as String? ?? 'pending';
    final detail = (approval['detail'] as String? ?? '').trim();
    final mine = post.reactions.entries.where((e) => e.value.contains(app.me?.id)).map((e) => e.key).firstOrNull;
    Widget header = Row(
      children: [
        Icon(_kindIcon(approval['kind'] as String? ?? 'approval'), size: 17, color: const Color(0xFFF5A623)),
        const SizedBox(width: 6),
        Expanded(
          child: AgentTitle(
            approval['title'] as String? ?? tr('Yêu cầu duyệt'),
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: pal.text),
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        if (detail.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: pal.text.withValues(alpha: .06), borderRadius: BorderRadius.circular(8)),
            child: Text(
              detail,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: pal.text, height: 1.3),
            ),
          ),
        const SizedBox(height: 8),
        if (status == 'pending')
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: mine == '+1' ? const Color(0xFF2E9D5B) : pal.accent,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  shape: const StadiumBorder(),
                ),
                onPressed: mine == '+1' ? null : () => app.toggleReaction(post, '+1'),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(tr('Xác nhận')),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  visualDensity: VisualDensity.compact,
                  shape: const StadiumBorder(),
                ),
                onPressed: mine == '-1' ? null : () => app.toggleReaction(post, '-1'),
                icon: const Icon(Icons.close_rounded, size: 18),
                label: Text(tr('Từ chối')),
              ),
            ],
          )
        else
          Text(
            switch (status) {
              'accepted' => tr('✓ Đã xác nhận'),
              'declined' => tr('✕ Đã từ chối'),
              'expired' => tr('Hết hạn duyệt'),
              _ => status,
            },
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: status == 'accepted' ? const Color(0xFF2E9D5B) : (status == 'declined' ? Colors.redAccent : pal.sub),
            ),
          ),
      ],
    );
  }
}
