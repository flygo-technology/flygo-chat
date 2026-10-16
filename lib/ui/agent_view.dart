import 'dart:convert';
import '../i18n/i18n.dart';
import '../agent/agent_config.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// Câu hỏi trắc nghiệm của trợ lý (props.flygo_agent_question):
/// {id, question, options:[{label, description?}], multi?:bool, allow_other?:bool, status:'pending'|'answered', answer?}.
Map<String, dynamic>? agentQuestionOf(MmPost p) => (p.props['flygo_agent_question'] as Map?)?.cast<String, dynamic>();

/// Claude Code tự hỏi bằng công cụ AskUserQuestion: runner cũ đưa ra như một yêu cầu duyệt có tiêu đề
/// "AskUserQuestion {json}". Đổi thành câu hỏi trắc nghiệm (câu đầu tiên) để hiện thẻ lựa chọn.
Map<String, dynamic>? askUserQuestionOf(MmPost p, Map<String, dynamic> approval) {
  for (final t in [approval['title'], approval['detail']]) {
    if (t is! String) continue;
    final i = t.indexOf('AskUserQuestion');
    if (i < 0) continue;
    final j = t.indexOf('{', i);
    if (j < 0) continue;
    Map<String, dynamic>? q;
    try {
      final m = (jsonDecode(t.substring(j)) as Map).cast<String, dynamic>();
      final qs = m['questions'] as List? ?? const [];
      if (qs.isNotEmpty) q = (qs.first as Map).cast<String, dynamic>();
    } catch (_) {
      // Runner cắt ngắn tiêu đề (JSON dở dang): lấy câu hỏi và các lựa chọn đọc được.
      final raw = t.substring(j);
      String? str(String key) => RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(raw)?.group(1);
      final question = str('question');
      if (question != null) {
        final opts = <Map<String, String>>[];
        for (final m in RegExp(r'"label"\s*:\s*"((?:[^"\\]|\\.)*)"(?:\s*,\s*"description"\s*:\s*"((?:[^"\\]|\\.)*)")?')
            .allMatches(raw)) {
          opts.add({'label': m.group(1)!, if (m.group(2) != null) 'description': m.group(2)!});
        }
        final multi = RegExp(r'"multiSelect"\s*:\s*true').hasMatch(raw) ||
            RegExp(r'chọn (được )?nhiều|nhiều lựa chọn|multiple', caseSensitive: false).hasMatch(question);
        if (opts.isNotEmpty) q = {'question': question, 'options': opts, 'multiSelect': multi};
      }
    }
    if (q == null) continue;
    return {
      'id': p.id,
      'question': q['question'],
      'options': q['options'] ?? const [],
      'multi': q['multiSelect'] == true,
      'allow_other': true,
      'status': approval['status'] ?? 'pending',
      'kind': 'ask_user_question',
    };
  }
  return null;
}

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
  'report' => Icons.campaign_outlined,
  'message' => Icons.forum_outlined,
  _ => Icons.circle_outlined,
};

/// Thẻ tiến trình: một dòng gọn (vòng quay + tên việc + "đang làm · N bước"), bấm để xem các bước.
class AgentRunCard extends StatefulWidget {
  final Map<String, dynamic> run;

  /// Gọn: không hiện tên việc (nằm chung với câu trả lời), chữ nhỏ hơn.
  final bool compact;

  /// Dạng gọn: tên bot đặt ngay sau biểu tượng trạng thái, cùng dòng với mô hình + mức suy nghĩ.
  final Widget? name;

  /// Khoá giữ trạng thái mở/đóng danh sách bước (id tin): tin đang chạy được dựng lại liên tục (chữ viết dần,
  /// đổi bố cục khi dài ra), thẻ có thể bị tạo lại và tự thu gọn nếu chỉ giữ trạng thái trong widget.
  final String? openKey;
  const AgentRunCard({super.key, required this.run, this.compact = false, this.name, this.openKey});
  @override
  State<AgentRunCard> createState() => _AgentRunCardState();
}

class _AgentRunCardState extends State<AgentRunCard> {
  /// Các thẻ người dùng đã bấm mở (theo [AgentRunCard.openKey]), sống suốt phiên app.
  static final _opened = <String>{};
  bool _openLocal = false;

  bool get _open => widget.openKey == null ? _openLocal : _opened.contains(widget.openKey);
  void _toggle() => setState(() {
        final k = widget.openKey;
        if (k == null) {
          _openLocal = !_openLocal;
        } else if (!_opened.remove(k)) {
          _opened.add(k);
        }
      });

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
        : [if (cfg['model'] is String) modelLabel(cfg['model'] as String), if (cfg['effort'] != null) effortLabel(cfg['effort'] as String)].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: steps.isEmpty ? null : _toggle,
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
                  Text('${widget.name != null ? ' · ' : ''}${modelLabel('${cfg!['model']}')}', style: TextStyle(fontSize: 12.5, color: pal.sub)),
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

  Future<void> _alwaysAllow(BuildContext context, AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 34),
        title: Text(tr('Luôn cho phép?')),
        content: Text(tr(
            'Trợ lý sẽ được chạy mọi lệnh, sửa mọi tệp mà KHÔNG hỏi duyệt nữa trong cuộc trò chuyện này. Chỉ dùng khi bạn tin tưởng việc đang giao.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Hủy'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr('Luôn cho phép')),
          ),
        ],
      ),
    );
    if (ok == true) await app.toggleReaction(post, 'unlock');
  }

  /// Thẻ duyệt passkey: còn chờ và chưa hết hạn → nút "🔐 Xác thực passkey" mở trang xác thực; còn lại hiện trạng thái.
  Widget _passkey(BuildContext context, Pal pal) {
    final status = approval['status'] as String? ?? 'pending';
    final exp = DateTime.tryParse(approval['expires_at'] as String? ?? '');
    final expired = status == 'expired' || (status == 'pending' && exp != null && exp.isBefore(DateTime.now()));
    final url = approval['url'] as String?;
    if (status == 'pending' && !expired && url != null) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF6C4CE0),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
        ),
        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        icon: const Icon(Icons.fingerprint_rounded, size: 20),
        label: Text(tr('Xác thực passkey')),
      );
    }
    final (icon, text, color) = switch (expired ? 'expired' : status) {
      'approved' || 'used' => (Icons.verified_rounded, tr('Đã xác thực passkey'), const Color(0xFF2E9D5B)),
      'denied' => (Icons.cancel_rounded, tr('Đã từ chối'), Colors.redAccent),
      'expired' => (Icons.timer_off_outlined, tr('Hết hạn xác thực'), pal.sub),
      _ => (Icons.info_outline, status, pal.sub),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
    ]);
  }

  /// Kết quả duyệt: Đã phê duyệt / Đã phê duyệt toàn quyền / Đã từ chối.
  Widget _decision(String status, Pal pal) {
    final (icon, text, color) = switch (status) {
      'accepted' => (Icons.check_circle_rounded, tr('Đã phê duyệt'), const Color(0xFF2E9D5B)),
      'always' => (Icons.lock_open_rounded, tr('Đã phê duyệt toàn quyền'), Colors.redAccent),
      'declined' => (Icons.cancel_rounded, tr('Đã từ chối'), Colors.redAccent),
      'expired' => (Icons.timer_off_outlined, tr('Hết hạn duyệt'), pal.sub),
      _ => (Icons.info_outline, status, pal.sub),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final status = approval['status'] as String? ?? 'pending';
    final detail = (approval['detail'] as String? ?? '').trim();
    final mine = post.reactions.entries.where((e) => e.value.contains(app.me?.id)).map((e) => e.key).firstOrNull;
    final owner = post.props['flygo_agent_owner'] as String?;
    final canApprove = app.isMyBot(post.userId) || (owner != null && owner == app.me?.id);
    final ownerName = owner == null ? tr('chủ trợ lý') : (app.users[owner]?.displayName ?? tr('chủ trợ lý'));
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
            // Báo cáo ra ngoài: hiện như văn bản thường (nhiều dòng), còn lệnh / tệp thì chữ đơn cách.
            child: approval['kind'] == 'report'
                ? SelectableText(detail, style: TextStyle(fontSize: 14, color: pal.text, height: 1.4))
                : Text(
                    detail,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: pal.text, height: 1.3),
                  ),
          ),
        const SizedBox(height: 8),
        // Duyệt bằng passkey (thao tác nhạy cảm qua ContextForge): nút mở trang xác thực; thả cảm xúc không duyệt được.
        if (approval['kind'] == 'passkey')
          _passkey(context, pal)
        // Chỉ chủ trợ lý duyệt được (runner bỏ qua người khác): người khác thấy dòng chờ thay vì nút bấm không tác dụng.
        else if (status == 'pending' && !canApprove)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.hourglass_top_rounded, size: 16, color: pal.sub),
            const SizedBox(width: 6),
            Flexible(
              child: Text(tr('Chờ {0} duyệt', [ownerName]),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: pal.sub)),
            ),
          ])
        // Đã bấm: các lựa chọn biến mất ngay, hiện kết quả luôn (không chờ trợ lý cập nhật tin).
        else if (status == 'pending' && (mine == '+1' || mine == '-1' || mine == 'unlock'))
          _decision(mine == '-1' ? 'declined' : (mine == 'unlock' ? 'always' : 'accepted'), pal)
        else if (status == 'pending')
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
              // Chủ bot: cho phép luôn — duyệt yêu cầu này và để trợ lý chạy không cần hỏi duyệt nữa
              // (chế độ bỏ qua quyền) trong cuộc trò chuyện / luồng này. Runner đọc reaction 🔓 (unlock).
              if (app.isMyBot(post.userId)) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: mine == 'unlock' ? null : () => _alwaysAllow(context, app),
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text(tr('Luôn cho phép')),
                ),
              ],
            ],
          )
        else
          _decision(status, pal),
      ],
    );
  }
}


// ---------------------------------------------------------------- dung lượng ngữ cảnh
/// Ngữ cảnh của phiên trợ lý trong chat [channelId]: số token đang dùng / tối đa, lấy từ lượt chạy gần nhất
/// (flygo_agent.usage; runner mới ghi thêm contextTokens + contextWindow). null nếu chưa có lượt nào.
({int used, int max, String model})? agentContextOf(AppState app, String channelId) {
  for (final p in app.postsOf(channelId)) {
    final r = agentRunOf(p);
    final all = (r?['usage'] as Map?)?.cast<String, dynamic>();
    if (all == null) continue;
    // Claude (snake_case, nhiều lượt gọi trong một lượt chạy): ngữ cảnh hiện tại = lượt gọi cuối cùng.
    final its = all['iterations'];
    final u = its is List && its.isNotEmpty && its.last is Map ? (its.last as Map).cast<String, dynamic>() : all;
    int n(String k) {
      final snake = k.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
      final alt = {
        'cachedInputTokens': 'cache_read_input_tokens',
        'cacheWriteInputTokens': 'cache_creation_input_tokens',
      }[k];
      return ((u[k] ?? all[k] ?? u[snake] ?? (alt == null ? null : u[alt])) as num?)?.toInt() ?? 0;
    }
    final engine = r?['engine'] as String? ?? '';
    final model = ((r?['config'] as Map?)?['model'] as String?) ?? '';
    // Codex: inputTokens đã gồm phần đọc từ cache; Claude: tách riêng cache đọc / ghi.
    final used = n('contextTokens') > 0
        ? n('contextTokens')
        : (engine == 'codex' ? n('inputTokens') : n('inputTokens') + n('cachedInputTokens') + n('cacheWriteInputTokens')) +
            n('outputTokens');
    final max = n('contextWindow') > 0 ? n('contextWindow') : (engine == 'codex' ? 400000 : 200000);
    if (used <= 0) continue;
    return (used: used, max: max, model: model);
  }
  return null;
}

String _kTokens(int n) => n >= 1000000 ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M' : '${(n / 1000).round()}k';

/// Vòng tròn ngữ cảnh ở góc trên bên phải chat trợ lý: phần trăm đã dùng; bấm xem chi tiết.
class AgentContextRing extends StatelessWidget {
  final String channelId;
  const AgentContextRing({super.key, required this.channelId});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final c = agentContextOf(app, channelId);
    if (c == null) return const SizedBox.shrink();
    final f = (c.used / c.max).clamp(0.0, 1.0);
    final color = f >= .85 ? Colors.redAccent : (f >= .6 ? const Color(0xFFF5A623) : const Color(0xFF2E9D5B));
    final pct = (f * 100).round();
    return Tooltip(
      message: tr('Ngữ cảnh: {0} / {1} token ({2}%)', [_kTokens(c.used), _kTokens(c.max), pct]),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text(tr('Ngữ cảnh của trợ lý')),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Đang dùng: {0} token', [_kTokens(c.used)])),
              Text(tr('Tối đa: {0} token', [_kTokens(c.max)])),
              Text(tr('Đã dùng: {0}%', [pct])),
              if (c.model.isNotEmpty) Text(tr('Mô hình: {0}', [modelLabel(c.model)])),
              const SizedBox(height: 10),
              Text(tr('Gần đầy thì trợ lý tự tóm tắt bớt lịch sử; muốn bắt đầu lại sạch hãy tạo phiên mới.'),
                  style: TextStyle(fontSize: 13, color: pal.sub)),
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Đóng')))],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 26,
            height: 26,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: f,
                strokeWidth: 3,
                backgroundColor: pal.text.withValues(alpha: .12),
                color: color,
              ),
              Text('$pct', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: pal.text)),
            ]),
          ),
        ),
      ),
    );
  }
}


// ---------------------------------------------------------------- câu hỏi trắc nghiệm của trợ lý
/// Thẻ câu hỏi trắc nghiệm: các lựa chọn (một hoặc nhiều), "Khác…" để tự nhập. Trả lời = gửi một tin vào đúng chỗ
/// (cùng luồng nếu có) kèm props.flygo_agent_answer {post_id, question_id, choices, other}; runner nhận tin đó là câu trả lời.
class AgentQuestionCard extends StatefulWidget {
  final MmPost post;
  final Map<String, dynamic> question;
  const AgentQuestionCard({super.key, required this.post, required this.question});

  /// Khoá cố định theo tin: tin của trợ lý được sửa liên tục làm bố cục bong bóng đổi, GlobalKey giữ nguyên thẻ
  /// (lựa chọn và ô "Khác…" đang gõ không mất focus, không nhảy xuống ô nhắn tin).
  static final _keys = <String, GlobalKey>{};
  static GlobalKey keyFor(String postId) => _keys.putIfAbsent(postId, () => GlobalKey(debugLabel: 'q-$postId'));
  @override
  State<AgentQuestionCard> createState() => _AgentQuestionCardState();
}

class _AgentQuestionCardState extends State<AgentQuestionCard> {
  // Tin của trợ lý đang chạy được sửa liên tục (thẻ có thể bị dựng lại): giữ lựa chọn theo id tin để không mất.
  static final _pickedById = <String, Set<String>>{};
  static final _otherById = <String, bool>{};
  static final _otherTextById = <String, String>{};
  static final _sentById = <String, String>{}; // id tin → 'answered' | 'cancelled'

  String get _id => widget.post.id;
  Set<String> get _picked => _pickedById.putIfAbsent(_id, () => <String>{});
  bool get _other => _otherById[_id] ?? false;
  set _other(bool v) => _otherById[_id] = v;
  bool get _sent => _sentById.containsKey(_id);
  late final TextEditingController _otherCtl = TextEditingController(text: _otherTextById[_id] ?? '')
    ..addListener(() => _otherTextById[_id] = _otherCtl.text);

  @override
  void dispose() {
    _otherCtl.dispose();
    super.dispose();
  }

  /// Huỷ câu hỏi: câu hỏi AskUserQuestion (đang chờ duyệt công cụ) → từ chối công cụ; câu hỏi của runner → gửi trả lời "huỷ".
  Future<void> _cancel(AppState app) async {
    setState(() => _sentById[_id] = 'cancelled');
    try {
      // Huỷ: thả 👎 lên tin câu hỏi (cả câu hỏi của runner lẫn yêu cầu AskUserQuestion cũ), không tạo tin nhắn.
      await app.toggleReaction(widget.post, '-1');
    } catch (_) {
      if (mounted) setState(() => _sentById.remove(_id));
    }
  }

  static const _numbers = ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];

  Future<void> _submit(AppState app, List<String> choices, String other) async {
    if (choices.isEmpty && other.trim().isEmpty) return;
    setState(() => _sentById[_id] = 'answered');
    final q = widget.question;
    // Câu hỏi của runner (props.flygo_agent_question): trả lời bằng cảm xúc số trên chính tin câu hỏi, không tạo tin
    // nhắn (một lựa chọn: 1️⃣…; nhiều lựa chọn: các số rồi ✅). "Khác" thì gửi tin thường cùng chỗ, runner nhận làm câu trả lời.
    if (q['kind'] != 'ask_user_question') {
      final labels = [
        for (final o in (q['options'] as List? ?? const [])) o is Map ? (o['label'] as String? ?? '') : '$o',
      ];
      final idx = [for (final c in choices) labels.indexOf(c)].where((i) => i >= 0 && i < _numbers.length).toList();
      try {
        if (other.trim().isNotEmpty) {
          final text = [...choices, other.trim()].join(', ');
          await app.send(widget.post.channelId, text, rootId: widget.post.rootId);
        } else if (idx.length == choices.length && idx.isNotEmpty) {
          await app.addReactions(widget.post, [
            for (final i in idx) _numbers[i],
            if (q['multi'] == true) 'white_check_mark',
          ]);
        } else {
          // Quá 9 lựa chọn: gửi câu trả lời dạng props (runner vẫn hỗ trợ).
          await app.send(widget.post.channelId, choices.join(', '), rootId: widget.post.rootId, props: {
            'flygo_agent_answer': {'post_id': widget.post.id, 'question_id': q['id'], 'choices': choices},
          });
        }
      } catch (_) {
        if (mounted) setState(() => _sentById.remove(_id));
      }
      return;
    }
    final bot = app.users[widget.post.userId];
    final parts = [...choices, if (other.trim().isNotEmpty) other.trim()];
    // Kênh nhiều người: gắn @trợ lý để runner chắc chắn nhận (chat AI / 1-1 thì không cần).
    final ch = app.channels[widget.post.channelId];
    final tag = ch != null && !ch.isAi && !ch.isDirect && bot != null ? '@${bot.username} ' : '';
    try {
      await app.send(widget.post.channelId, '$tag${parts.join(', ')}',
          rootId: widget.post.rootId,
          props: {
            'flygo_agent_answer': {
              'post_id': widget.post.id,
              'question_id': q['id'],
              'choices': choices,
              if (other.trim().isNotEmpty) 'other': other.trim(),
              // Câu hỏi AskUserQuestion của Claude (đang chờ duyệt công cụ): runner trả lời yêu cầu đó bằng lựa chọn này.
              if (q['kind'] == 'ask_user_question') 'kind': 'ask_user_question',
              if (q['kind'] == 'ask_user_question') 'question': q['question'],
            },
          });
      // Runner cũ chỉ hiểu 👍 cho yêu cầu công cụ AskUserQuestion: duyệt luôn để lượt chạy không đứng chờ;
      // câu trả lời đã nằm trong tin vừa gửi (trợ lý đọc ở lượt kế tiếp).
      if (q['kind'] == 'ask_user_question' && !(widget.post.reactions['+1']?.contains(app.me?.id) ?? false)) {
        await app.toggleReaction(widget.post, '+1');
      }
    } catch (_) {
      if (mounted) setState(() => _sentById.remove(_id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final q = widget.question;
    final options = [
      for (final o in (q['options'] as List? ?? const []))
        o is Map ? (o['label'] as String? ?? '', o['description'] as String? ?? '') : ('$o', ''),
    ];
    final multi = q['multi'] == true;
    final allowOther = q['allow_other'] != false;
    final answered = (q['status'] as String? ?? 'pending') != 'pending' || _sent;
    final answer = q['answer'];
    Widget optionTile((String, String) o) {
      final sel = _picked.contains(o.$1);
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: sel ? pal.accent.withValues(alpha: .16) : pal.text.withValues(alpha: .05),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12), side: BorderSide(color: sel ? pal.accent : Colors.transparent, width: 1.4)),
          child: InkWell(
            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            // Chọn xong mới gửi bằng nút Xác nhận (cả một lựa chọn lẫn nhiều lựa chọn).
            onTap: answered
                ? null
                : () => setState(() {
                      if (!multi) {
                        _picked
                          ..clear()
                          ..add(o.$1);
                        _other = false;
                      } else {
                        sel ? _picked.remove(o.$1) : _picked.add(o.$1);
                      }
                    }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(children: [
                Icon(
                    multi
                        ? (sel ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
                        : (sel ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    size: 20,
                    color: sel ? pal.accentText : pal.sub),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(o.$1, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: pal.text)),
                    if (o.$2.isNotEmpty) Text(o.$2, style: TextStyle(fontSize: 13, color: pal.sub)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: pal.accent.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: pal.accent.withValues(alpha: .25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.help_outline_rounded, size: 18, color: pal.accentText),
          const SizedBox(width: 6),
          Expanded(
            child: Text(q['question'] as String? ?? '',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: pal.text)),
          ),
        ]),
        if (!answered)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(multi ? tr('Chọn một hoặc nhiều, rồi bấm Xác nhận') : tr('Chọn một, rồi bấm Xác nhận'),
                style: TextStyle(fontSize: 12.5, color: pal.sub)),
          ),
        const SizedBox(height: 10),
        if (q['status'] == 'expired' && _sentById[_id] == null)
          Row(children: [
            Icon(Icons.timer_off_outlined, size: 18, color: pal.sub),
            const SizedBox(width: 6),
            Text(tr('Câu hỏi đã hết hạn'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: pal.sub)),
          ])
        else if (answered && (_sentById[_id] == 'cancelled' || q['status'] == 'cancelled'))
          Row(children: [
            Icon(Icons.cancel_rounded, size: 18, color: pal.sub),
            const SizedBox(width: 6),
            Text(tr('Đã huỷ'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: pal.sub)),
          ])
        else if (answered)
          Row(children: [
            const Icon(Icons.check_circle_rounded, size: 18, color: Color(0xFF2E9D5B)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                  answer is String && answer.isNotEmpty ? tr('Đã trả lời: {0}', [answer]) : tr('Đã trả lời'),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2E9D5B))),
            ),
          ])
        else ...[
          for (final o in options) optionTile(o),
          if (allowOther)
            _other
                ? Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _otherCtl,
                        autofocus: true,
                        minLines: 1,
                        maxLines: 4,
                        style: TextStyle(color: pal.text),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: tr('Nhập câu trả lời khác…'),
                          filled: true,
                          fillColor: pal.surface,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ])
                : TextButton.icon(
                    onPressed: () => setState(() {
                      _other = true;
                      if (!multi) _picked.clear();
                    }),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(tr('Khác…')),
                  ),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent, minimumSize: const Size(64, 44)),
              onPressed: () => _cancel(app),
              child: Text(tr('Huỷ')),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(shape: const StadiumBorder()),
              onPressed: _picked.isEmpty && (!_other || _otherCtl.text.trim().isEmpty)
                  ? null
                  : () => _submit(app, _picked.toList(), _other ? _otherCtl.text : ''),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(tr('Xác nhận')),
            ),
          ]),
        ],
      ]),
    );
  }
}
