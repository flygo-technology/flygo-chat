import '../i18n/i18n.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';

/// Cấu hình chạy của trợ lý AI cho từng tin: mô hình + mức suy nghĩ.
/// Bot khai báo trong mốc mô tả: "[flygo-agent engine=codex models=gpt-5.5 efforts=low,medium,high default=gpt-5.5:medium]".
/// App gửi lựa chọn trong `props.flygo_agent_config = {"username bot": {"model": …, "effort": …}}`.
class AgentOptions {
  final String engine;
  final List<String> models;
  final List<String> efforts;
  final String defModel;
  final String defEffort;
  const AgentOptions(this.engine, this.models, this.efforts, this.defModel, this.defEffort);
}

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

  final models = list('models', engine == 'claude' ? ['opus', 'sonnet'] : ['gpt-5.5']);
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

String effortLabel(String e) => switch (e) {
      'minimal' => tr('Tối thiểu'),
      'low' => tr('Thấp'),
      'medium' => tr('Trung bình'),
      'high' => tr('Cao'),
      'xhigh' => tr('Rất cao'),
      'max' => tr('Tối đa'),
      _ => e,
    };

/// Chọn mô hình + mức suy nghĩ cho bot. Trả về (model, effort) hoặc null nếu huỷ.
Future<(String, String)?> pickAgentConfig(BuildContext context, MmUser bot, AgentOptions o, String model, String effort) {
  return showModalBottomSheet<(String, String)>(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      var m = model, e = effort;
      return StatefulBuilder(builder: (ctx, set) {
        final pal = Pal.of(ctx);
        Widget chip(String label, bool sel, VoidCallback onTap) => Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: sel,
                onSelected: (_) => onTap(),
                selectedColor: pal.accent,
                labelStyle: TextStyle(color: sel ? Colors.white : pal.text, fontWeight: FontWeight.w600),
                showCheckmark: false,
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Cấu hình {0}', [bot.displayName]), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: pal.text)),
              const SizedBox(height: 14),
              Text(tr('Mô hình'), style: TextStyle(color: pal.sub, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(children: [for (final x in o.models) chip(x, x == m, () => set(() => m = x))]),
              const SizedBox(height: 8),
              Text(tr('Mức suy nghĩ'), style: TextStyle(color: pal.sub, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(children: [for (final x in o.efforts) chip(effortLabel(x), x == e, () => set(() => e = x))]),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(ctx, (m, e)),
                  child: Text(tr('Dùng cấu hình này')),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}
