import '../i18n/i18n.dart';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';

/// Cấu hình chạy của trợ lý AI cho từng tin: mô hình + mức suy nghĩ.
/// Bot khai báo trong mốc mô tả: "[flygo-agent engine=codex models=gpt-5.6-sol efforts=low,medium,high default=gpt-5.6-sol:medium]".
/// App gửi lựa chọn trong `props.flygo_agent_config = {"username bot": {"model": …, "effort": …}}`.
class AgentOptions {
  final String engine;
  final List<String> models;
  final List<String> efforts;
  final String defModel;
  final String defEffort;
  const AgentOptions(this.engine, this.models, this.efforts, this.defModel, this.defEffort);
}

/// Mô hình Claude (đủ như trong app Claude): các bản mới nhất trước, sau đó các bản cũ hơn.
const kClaudeModels = [
  'claude-opus-5-5',
  'claude-fable-5-1',
  'claude-sonnet-5-5',
  'claude-haiku-5-5',
  'claude-haiku-4-5',
  'claude-sonnet-5',
  'claude-opus-5',
  'claude-fable-5',
  'claude-opus-4-8',
  'claude-opus-4-7',
];

/// Tên hiển thị của mô hình: "claude-opus-5-5" → "Opus 5.5", "opus" → "Opus", "gpt-5.6-sol" → "GPT-5.6 Sol".
String modelLabel(String m) {
  final c = RegExp(r'^claude-([a-z]+)-(\d+)(?:-(\d+))?').firstMatch(m);
  String cap(String x) => x.isEmpty ? x : x[0].toUpperCase() + x.substring(1);
  if (c != null) return '${cap(c[1]!)} ${c[2]}${c[3] == null ? '' : '.${c[3]}'}';
  if (const {'opus', 'sonnet', 'haiku', 'fable'}.contains(m)) return cap(m);
  final g = RegExp(r'^gpt-([\d.]+)(?:-([a-z]+))?$').firstMatch(m);
  if (g != null) return 'GPT-${g[1]}${g[2] == null ? '' : ' ${cap(g[2]!)}'}';
  return m;
}

/// Mô tả ngắn cho các mô hình chính (giống app Claude).
String? modelHint(String m) => switch (m) {
      'claude-opus-5-5' || 'opus' => tr('Dành cho công việc phức tạp và tác vụ hằng ngày'),
      'claude-fable-5-1' || 'fable' => tr('Dành cho thử thách khó nhất'),
      'claude-sonnet-5-5' || 'sonnet' => tr('Hiệu quả nhất cho tác vụ đơn giản hơn'),
      'claude-haiku-5-5' || 'haiku' => tr('Nhanh nhất cho câu trả lời tức thì'),
      _ => null,
    };

final _marker = RegExp(r'\[flygo-agent([^\]]*)\]');
String? _attr(String attrs, String key) => RegExp('(?:^|\\s)$key=([^\\s\\]]+)').firstMatch(attrs)?.group(1);

/// Tuỳ chọn của bot trợ lý AI (null nếu không phải bot trợ lý AI).
AgentOptions? agentOptionsOf(MmUser u) {
  if (!u.isBot) return null;
  final m = _marker.firstMatch(u.raw['bot_description'] as String? ?? '');
  if (m == null) return null;
  final a = m.group(1)!;
  final engine = _attr(a, 'engine') ?? 'codex';
  List<String> list(String k, List<String> fb) {
    final v = (_attr(a, k) ?? '').split(',').where((s) => s.isNotEmpty).toList();
    return v.isEmpty ? fb : v;
  }

  // Runner ghi danh sách mô hình thật của máy vào mốc (models=…); chưa có thì dùng danh sách đầy đủ mặc định.
  final models = list(
      'models',
      engine == 'claude'
          ? kClaudeModels
          : ['gpt-6-astra', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna']);
  final efforts = list('efforts', engine == 'claude' ? ['low', 'medium', 'high', 'xhigh', 'max'] : ['low', 'medium', 'high', 'xhigh']);
  final def = (_attr(a, 'default') ?? '').split(':');
  final dm = def.isNotEmpty && models.contains(def[0]) ? def[0] : models.first;
  final de = def.length > 1 && efforts.contains(def[1])
      ? def[1]
      : engine == 'claude' && efforts.contains('high')
          ? 'high'
          : (efforts.contains('medium') ? 'medium' : efforts.first);
  return AgentOptions(engine, models, efforts, dm, de);
}

/// Thứ hạng mức suy nghĩ (1..5) để vẽ vạch sóng.
int effortLevel(String e) => switch (e) {
      'minimal' || 'low' => 1,
      'medium' => 2,
      'high' => 3,
      'xhigh' => 4,
      'max' => 5,
      _ => 2,
    };

/// Mức suy nghĩ dạng vạch sóng điện thoại: số vạch đậm = mức.
class EffortBars extends StatelessWidget {
  final String effort;
  final Color color;
  final double height;
  final int total;
  const EffortBars({super.key, required this.effort, required this.color, this.height = 12, this.total = 5});
  @override
  Widget build(BuildContext context) {
    final lv = effortLevel(effort);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (var i = 1; i <= total; i++)
        Container(
          width: height / 4,
          height: height * i / total,
          margin: EdgeInsets.only(left: i == 1 ? 0 : height / 8),
          decoration: BoxDecoration(
            color: i <= lv ? color : color.withValues(alpha: .25),
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
    ]);
  }
}

String effortLabel(String e) => switch (e) {
      'minimal' => tr('Tối thiểu'),
      'low' => tr('Thấp'),
      'medium' => tr('Trung bình'),
      'high' => tr('Cao'),
      'xhigh' => tr('Rất cao'),
      'max' => tr('Tối đa'),
      _ => e,
    };

/// Chọn mô hình (menu) + mức thông minh (thanh kéo). Trả về (model, effort) hoặc null nếu huỷ.
Future<(String, String)?> pickAgentConfig(BuildContext context, MmUser bot, AgentOptions o, String model, String effort) {
  return showModalBottomSheet<(String, String)>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      var m = model;
      var ei = o.efforts.indexOf(effort).clamp(0, o.efforts.length - 1);
      return StatefulBuilder(builder: (ctx, set) {
        final pal = Pal.of(ctx);
        final e = o.efforts[ei];
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
            decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(26)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(width: 36, height: 4, decoration: BoxDecoration(color: pal.divider, borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 16),
              Text(bot.displayName, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
              const SizedBox(height: 2),
              Text(tr('Cấu hình cho tin nhắn này'), style: TextStyle(fontSize: 13, color: pal.sub)),
              const SizedBox(height: 20),
              // Mô hình: menu chọn.
              Text(tr('Mô hình').toUpperCase(), style: TextStyle(fontSize: 11.5, letterSpacing: .8, color: pal.sub, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(color: pal.bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: pal.divider)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: m,
                    isExpanded: true,
                    borderRadius: BorderRadius.circular(14),
                    dropdownColor: pal.surface,
                    icon: Icon(Icons.expand_more_rounded, color: pal.sub),
                    style: TextStyle(fontSize: 15.5, color: pal.text, fontWeight: FontWeight.w600),
                    items: [for (final x in o.models) DropdownMenuItem(value: x, child: Text(modelLabel(x)))],
                    onChanged: (v) => v == null ? null : set(() => m = v),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              // Mức thông minh: thanh kéo + vạch sóng.
              Row(children: [
                Text(tr('Mức thông minh').toUpperCase(),
                    style: TextStyle(fontSize: 11.5, letterSpacing: .8, color: pal.sub, fontWeight: FontWeight.w600)),
                const Spacer(),
                EffortBars(effort: e, color: pal.accent, height: 14),
                const SizedBox(width: 8),
                Text(effortLabel(e), style: TextStyle(fontSize: 14, color: pal.text, fontWeight: FontWeight.w600)),
              ]),
              SliderTheme(
                data: SliderTheme.of(ctx).copyWith(
                  trackHeight: 4,
                  activeTrackColor: pal.accent,
                  inactiveTrackColor: pal.divider,
                  thumbColor: pal.accent,
                  overlayColor: pal.accent.withValues(alpha: .12),
                  tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
                  activeTickMarkColor: Colors.white70,
                  inactiveTickMarkColor: pal.sub,
                ),
                child: Slider(
                  value: ei.toDouble(),
                  min: 0,
                  max: (o.efforts.length - 1).toDouble(),
                  divisions: o.efforts.length > 1 ? o.efforts.length - 1 : null,
                  onChanged: (v) => set(() => ei = v.round()),
                ),
              ),
              Row(children: [
                Text(tr('Nhanh'), style: TextStyle(fontSize: 12, color: pal.sub)),
                const Spacer(),
                Text(tr('Kỹ hơn'), style: TextStyle(fontSize: 12, color: pal.sub)),
              ]),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: pal.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(ctx, (m, o.efforts[ei])),
                  child: Text(tr('Áp dụng'), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}


/// Ô trong menu bật ra: thanh kéo chọn mức thông minh, đổi là áp dụng ngay.
class EffortSliderEntry extends PopupMenuEntry<Never> {
  final AgentOptions options;
  final String effort;
  final ValueChanged<String> onChanged;
  const EffortSliderEntry({super.key, required this.options, required this.effort, required this.onChanged});
  @override
  double get height => 110;
  @override
  bool represents(void value) => false;
  @override
  State<EffortSliderEntry> createState() => _EffortSliderEntryState();
}

class _EffortSliderEntryState extends State<EffortSliderEntry> {
  late int _i = widget.options.efforts.indexOf(widget.effort).clamp(0, widget.options.efforts.length - 1);
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final efforts = widget.options.efforts;
    final e = efforts[_i];
    return SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text(tr('Mức thông minh'), style: TextStyle(fontSize: 13, color: pal.sub, fontWeight: FontWeight.w600)),
            const Spacer(),
            EffortBars(effort: e, color: pal.accent, height: 14),
            const SizedBox(width: 8),
            Text(effortLabel(e), style: TextStyle(fontSize: 14, color: pal.text, fontWeight: FontWeight.w600)),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: pal.accent,
              inactiveTrackColor: pal.divider,
              thumbColor: pal.accent,
              overlayColor: pal.accent.withValues(alpha: .12),
              tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
              activeTickMarkColor: Colors.white70,
              inactiveTickMarkColor: pal.sub,
            ),
            child: Slider(
              value: _i.toDouble(),
              min: 0,
              max: (efforts.length - 1).toDouble(),
              divisions: efforts.length > 1 ? efforts.length - 1 : null,
              onChanged: (v) => setState(() => _i = v.round()),
              onChangeEnd: (v) => widget.onChanged(efforts[v.round()]),
            ),
          ),
          Row(children: [
            Text(tr('Nhanh'), style: TextStyle(fontSize: 12, color: pal.sub)),
            const Spacer(),
            Text(tr('Kỹ hơn'), style: TextStyle(fontSize: 12, color: pal.sub)),
          ]),
        ]),
      ),
    );
  }
}

/// Chế độ quyền của trợ lý (runner 0.6.33+): props.flygo_models của bot = JSON {modes:[{id,label,description}], default_mode}.
/// Rỗng nếu runner chưa khai báo (app không hiện mục "Quyền").
List<({String id, String label, String description})> agentModesOf(MmUser? u) {
  final raw = (u?.raw['props'] as Map?)?['flygo_models'];
  try {
    final m = raw is String ? jsonDecode(raw) as Map : raw as Map?;
    return [
      for (final x in (m?['modes'] as List? ?? const []))
        (id: '${(x as Map)['id']}', label: '${x['label'] ?? x['id']}', description: '${x['description'] ?? ''}'),
    ];
  } catch (_) {
    return const [];
  }
}

/// Chế độ quyền mặc định của bot (props.flygo_models.default_mode), null nếu không có.
String? agentDefaultModeOf(MmUser? u) {
  final raw = (u?.raw['props'] as Map?)?['flygo_models'];
  try {
    final m = raw is String ? jsonDecode(raw) as Map : raw as Map?;
    return m?['default_mode'] as String?;
  } catch (_) {
    return null;
  }
}
