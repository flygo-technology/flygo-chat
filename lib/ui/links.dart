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
    i = m.start + t.length;
  }
  if (i < text.length) spans.addAll(plain(text.substring(i)));
  return spans;
}

/// Nút dưới tin có số điện thoại / link: "Sao chép" + "Gọi điện" hoặc "Sao chép link" + "Mở link".
class LinkActions extends StatelessWidget {
  final List<FoundLink> links;
  const LinkActions({super.key, required this.links});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final many = links.length > 1;
    Widget btn(IconData icon, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 6, top: 4),
          child: Material(
            color: pal.text.withValues(alpha: .07),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 15, color: pal.accentText),
                  const SizedBox(width: 5),
                  Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.accentText)),
                ]),
              ),
            ),
          ),
        );
    void copy(FoundLink l) {
      Clipboard.setData(ClipboardData(text: l.isPhone ? l.dial : l.uri.toString()));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Đã sao chép'))));
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final l in links.take(3))
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (many)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: pal.sub)),
              ),
            Wrap(children: [
              if (l.isPhone) ...[
                btn(Icons.copy_rounded, tr('Sao chép'), () => copy(l)),
                btn(Icons.call_outlined, tr('Gọi điện'), l.open),
              ] else ...[
                btn(Icons.link_rounded, tr('Sao chép link'), () => copy(l)),
                btn(Icons.open_in_new_rounded, tr('Mở link'), l.open),
              ],
            ]),
          ]),
      ]),
    );
  }
}

final _mentionRe = RegExp(r'@[a-z0-9._-]+', caseSensitive: false);

/// @tên được tô màu; bấm vào thì gọi [onTap] với tên đăng nhập (không có @).
List<InlineSpan> mentionSpans(String text, Pal pal, void Function(String username)? onTap) {
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in _mentionRe.allMatches(text)) {
    if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
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
