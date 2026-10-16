import 'package:flutter/material.dart';

/// Ô nhắn tin hiểu @tag: tag của người / bot có thật hiện thành ô màu liền khối, và xoá là xoá trọn cả tag
/// (một lần Backspace khi con trỏ ở cuối tag hoặc trong tag), không phải xoá từng ký tự.
class MentionTextController extends TextEditingController {
  /// Tên người dùng (không có @) có thật không: chỉ tag có thật mới thành khối.
  final bool Function(String username) isKnown;
  Color chipColor;
  Color chipText;
  MentionTextController({required this.isKnown, this.chipColor = const Color(0x332F80ED), this.chipText = const Color(0xFF2F80ED)});

  static final _re = RegExp(r'@([a-zA-Z0-9][a-zA-Z0-9._-]*)');
  TextEditingValue _prev = TextEditingValue.empty;

  /// Các khoảng [start, end) của tag có thật trong [text].
  List<(int, int)> _mentions(String text) => [
        for (final m in _re.allMatches(text))
          if ((m.start == 0 || !RegExp(r'[\w.]').hasMatch(text[m.start - 1])) &&
              isKnown(m.group(1)!.toLowerCase().replaceAll(RegExp(r'[._-]+$'), '')))
            (m.start, m.start + 1 + m.group(1)!.replaceAll(RegExp(r'[._-]+$'), '').length),
      ];

  @override
  set value(TextEditingValue next) {
    final old = _prev;
    // Xoá đúng một ký tự (Backspace / Delete) chạm vào một tag → xoá trọn tag.
    if (next.composing.isCollapsed &&
        old.text.length - next.text.length == 1 &&
        next.selection.isCollapsed &&
        old.selection.isCollapsed) {
      final at = next.selection.baseOffset; // vị trí ký tự bị xoá trong chuỗi cũ
      if (at >= 0 && old.text.startsWith(next.text.substring(0, at)) && old.text.endsWith(next.text.substring(at))) {
        for (final (s, e) in _mentions(old.text)) {
          if (at >= s && at < e) {
            final rest = old.text.substring(e);
            final text = old.text.substring(0, s) + rest;
            next = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: s));
            break;
          }
        }
      }
    }
    _prev = next;
    super.value = next;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text;
    final ms = _mentions(t);
    if (ms.isEmpty || (withComposing && value.composing.isValid && !value.composing.isCollapsed)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final chip = (style ?? const TextStyle()).copyWith(
      color: chipText,
      fontWeight: FontWeight.w600,
      background: Paint()
        ..color = chipColor
        ..style = PaintingStyle.fill,
    );
    final spans = <InlineSpan>[];
    var i = 0;
    for (final (s, e) in ms) {
      if (s > i) spans.add(TextSpan(text: t.substring(i, s)));
      spans.add(TextSpan(text: t.substring(s, e), style: chip));
      i = e;
    }
    if (i < t.length) spans.add(TextSpan(text: t.substring(i)));
    return TextSpan(style: style, children: spans);
  }
}
