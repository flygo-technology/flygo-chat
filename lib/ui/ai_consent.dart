import '../i18n/i18n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/servers.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Nội dung giải thích chung (hộp thoại xin đồng ý và màn xem lại trong tab Bạn).
String aiConsentText() => tr(
    'Các tính năng AI (trợ lý AI, Dịch AI, AI trong Trình chiếu, nhờ AI đọc luồng) gửi nội dung bạn yêu cầu, gồm tin nhắn, '
    'tệp và đoạn chat hoặc luồng bạn đính kèm, tới dịch vụ AI của bên thứ ba: Anthropic (Claude), OpenAI và Google Dịch '
    '(khi dịch). Dữ liệu đi qua trợ lý AI do doanh nghiệp của bạn vận hành, chỉ dùng để trả lời, tóm tắt hoặc dịch theo '
    'yêu cầu của bạn. App không gửi gì cho AI khi bạn không dùng các tính năng này.');

/// Hộp thoại xin đồng ý trước lần đầu gửi dữ liệu cho AI. Trả về true nếu người dùng bấm "Đồng ý".
Future<bool> showAiConsentDialog(BuildContext context, String? privacyUrl) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (d) {
      final pal = Pal.of(d);
      return AlertDialog(
        icon: Icon(Icons.auto_awesome_rounded, color: pal.accentText),
        title: Text(tr('Cho phép gửi dữ liệu cho AI?')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(aiConsentText(), style: TextStyle(color: pal.text, height: 1.4)),
            const SizedBox(height: 12),
            Text(tr('Không đồng ý thì các tính năng AI bị khoá. Bạn có thể đổi lựa chọn bất cứ lúc nào ở tab Bạn > AI.'),
                style: TextStyle(color: pal.sub, fontSize: 13, height: 1.4)),
            if (privacyUrl != null)
              TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => launchUrl(Uri.parse(privacyUrl), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                label: Text(tr('Chính sách quyền riêng tư')),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Không đồng ý'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Đồng ý'))),
        ],
      );
    },
  );
  return ok == true;
}

/// Tab Bạn > AI: xem lại nội dung, đồng ý hoặc rút lại đồng ý.
Future<void> showAiConsentSettings(BuildContext context) async {
  final app = context.read<AppState>();
  final privacy = (await ServerList.probe(kServerUrl))?.privacy;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (d) => ListenableBuilder(
      listenable: app,
      builder: (d, _) {
        final pal = Pal.of(d);
        final on = app.aiConsent == true;
        return AlertDialog(
          title: Text(tr('Dữ liệu gửi cho AI')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(aiConsentText(), style: TextStyle(color: pal.text, height: 1.4)),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Cho phép dùng tính năng AI')),
                subtitle: Text(on ? tr('Đã đồng ý') : tr('Chưa đồng ý: các tính năng AI bị khoá')),
                value: on,
                onChanged: (v) => app.setAiConsent(v),
              ),
              if (privacy != null)
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => launchUrl(Uri.parse(privacy), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                  label: Text(tr('Chính sách quyền riêng tư')),
                ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Đóng')))],
        );
      },
    ),
  );
}
