import '../i18n/i18n.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

/// Link (có hoặc không có http) và số điện thoại Việt Nam / quốc tế, cho phép
/// khoảng trắng, dấu chấm, gạch ngang giữa các số: "0888 220 997", "+84 888.220.997".
final linkRe = RegExp(
  r'(https?://[^\s<>()]+|www\.[^\s<>()]+)'
  r'|((?<![\w+])(?:\+84|\+\d{2}|0)(?:[ .\-]?\d){8,10}(?![\w]))',
  caseSensitive: false,
);

class FoundLink {
  final String text;
  final bool isPhone;
  const FoundLink(this.text, this.isPhone);

  /// Số chỉ còn chữ số (giữ dấu +) để gọi.
  String get dial => text.replaceAll(RegExp(r'[^\d+]'), '');
  Uri get uri => isPhone
      ? Uri(scheme: 'tel', path: dial)
      : Uri.parse(text.toLowerCase().startsWith('www.') ? 'https://$text' : _trimPunct(text));

  Future<void> open() => launchUrl(uri, mode: LaunchMode.externalApplication);
}

String _trimPunct(String s) => s.replaceFirst(RegExp(r'[.,;:!?]+$'), '');

/// Link và số điện thoại trong một tin (không trùng, theo thứ tự xuất hiện).
List<FoundLink> findLinks(String text) {
  final seen = <String>{};
  final out = <FoundLink>[];
  for (final m in linkRe.allMatches(text)) {
    final phone = m.group(2) != null;
    final t = phone ? m.group(2)!.trim() : _trimPunct(m.group(1)!);
    final key = phone ? t.replaceAll(RegExp(r'\D'), '') : t;
    if (seen.add(key)) out.add(FoundLink(t, phone));
  }
  return out;
}

/// Chia chữ thành các đoạn: link / số điện thoại bấm được, phần còn lại qua [plain].
List<InlineSpan> linkSpans(String text, Pal pal, List<InlineSpan> Function(String) plain) {
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in linkRe.allMatches(text)) {
    final raw = m.group(0)!;
    final phone = m.group(2) != null;
    final t = phone ? raw : _trimPunct(raw);
    if (m.start > i) spans.addAll(plain(text.substring(i, m.start)));
    final link = FoundLink(phone ? t.trim() : t, phone);
    spans.add(TextSpan(
      text: t,
      style: TextStyle(color: pal.tick, decoration: TextDecoration.underline, decorationColor: pal.tick),
      mouseCursor: SystemMouseCursors.click,
      recognizer: TapGestureRecognizer()..onTap = link.open,
    ));
    spans.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: InlineLinkButtons(link: link)));
    i = m.start + t.length;
  }
  if (i < text.length) spans.addAll(plain(text.substring(i)));
  return spans;
}

/// Hai nút nhỏ ngay sau link / số điện thoại: sao chép và mở link / gọi điện.
class InlineLinkButtons extends StatelessWidget {
  final FoundLink link;
  const InlineLinkButtons({super.key, required this.link});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget btn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(3), child: Icon(icon, size: 15, color: pal.accentText)),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(width: 3),
      btn(Icons.copy_rounded, link.isPhone ? tr('Sao chép') : tr('Sao chép link'), () {
        Clipboard.setData(ClipboardData(text: link.isPhone ? link.dial : link.uri.toString()));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Đã sao chép'))));
      }),
      btn(link.isPhone ? Icons.call_outlined : Icons.open_in_new_rounded, link.isPhone ? tr('Gọi điện') : tr('Mở link'), link.open),
    ]);
  }
}

final _mentionRe = RegExp(r'@[a-z0-9._-]+|(?<![\w&])#[\p{L}\p{N}_]+', caseSensitive: false, unicode: true);

/// @tên được tô màu; bấm vào thì gọi [onTap] với tên đăng nhập (không có @).
List<InlineSpan> mentionSpans(String text, Pal pal, void Function(String username)? onTap) {
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in _mentionRe.allMatches(text)) {
    if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
    if (m.group(0)!.startsWith('#')) {
      // Hashtag: chip nhỏ.
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: pal.accent.withValues(alpha: .14), borderRadius: BorderRadius.circular(8)),
          child: Text(m.group(0)!, style: TextStyle(fontSize: 13.5, color: pal.accentText, fontWeight: FontWeight.w600)),
        ),
      ));
      i = m.end;
      continue;
    }
    final name = m.group(0)!.substring(1).replaceFirst(RegExp(r'[._-]+$'), '');
    spans.add(TextSpan(
      text: m.group(0),
      style: TextStyle(color: pal.tick, fontWeight: FontWeight.w500),
      mouseCursor: onTap == null ? null : SystemMouseCursors.click,
      recognizer: onTap == null ? null : (TapGestureRecognizer()..onTap = () => onTap(name)),
    ));
    i = m.end;
  }
  if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
  return spans;
}
