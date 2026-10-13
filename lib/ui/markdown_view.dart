import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'common.dart';
import 'theme.dart';

/// Hiển thị markdown của Mattermost thành widget: đoạn văn, tiêu đề, danh sách,
/// khối mã, trích dẫn, bảng, đường kẻ; trong dòng có đậm, nghiêng, gạch,
/// mã, link, @nhắc tên và :emoji:.
class MarkdownView extends StatelessWidget {
  final String text;
  final TextStyle style;
  /// Khoảng trống chừa ở cuối đoạn cuối cùng để đặt giờ gửi.
  final double trailingSpace;
  const MarkdownView({super.key, required this.text, required this.style, this.trailingSpace = 0});

  static final _doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );

  /// Tin chỉ có một đoạn văn bình thường (không có khối) thì hiển thị gọn trong dòng.
  static bool isSimple(String text) {
    final nodes = _doc.parse(replaceShortcodes(text));
    return nodes.length == 1 && nodes.first is md.Element && (nodes.first as md.Element).tag == 'p';
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final nodes = _doc.parse(replaceShortcodes(text));
    final blocks = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final last = i == nodes.length - 1;
      final w = _block(context, pal, nodes[i], last ? trailingSpace : 0);
      if (w != null) blocks.add(w);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < blocks.length; i++) ...[
        if (i > 0) const SizedBox(height: 6),
        blocks[i],
      ],
    ]);
  }

  Widget? _block(BuildContext context, Pal pal, md.Node node, double trailing) {
    if (node is md.Text) return _para(pal, [node], style, trailing);
    if (node is! md.Element) return null;
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'p':
        return _para(pal, children, style, trailing);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final size = {'h1': 1.35, 'h2': 1.25, 'h3': 1.15}[node.tag] ?? 1.05;
        return _para(pal, children,
            style.copyWith(fontSize: (style.fontSize ?? 17) * size, fontWeight: FontWeight.w700), trailing);
      case 'ul' || 'ol':
        return _list(context, pal, node, 0);
      case 'pre':
        final code = node.textContent.replaceAll(RegExp(r'\n$'), '');
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: pal.text.withValues(alpha: .07), borderRadius: BorderRadius.circular(8)),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(code, style: style.copyWith(fontFamily: 'monospace', fontSize: 13.5, height: 1.35)),
          ),
        );
      case 'blockquote':
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 3, decoration: BoxDecoration(color: pal.sub, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final c in children)
                  ?_block(context, pal, c, 0),
              ]),
            ),
          ]),
        );
      case 'hr':
        return Divider(color: pal.divider, height: 12);
      case 'table':
        return _table(pal, node);
      default:
        return _para(pal, children, style, trailing);
    }
  }

  Widget _para(Pal pal, List<md.Node> nodes, TextStyle st, double trailing) => Text.rich(
        TextSpan(children: [
          ..._inline(pal, nodes, st),
          if (trailing > 0) WidgetSpan(child: SizedBox(width: trailing, height: 12)),
        ]),
        style: st,
      );

  Widget _list(BuildContext context, Pal pal, md.Element list, int depth) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = (list.children ?? const <md.Node>[]).whereType<md.Element>().toList();
    return Padding(
      padding: EdgeInsets.only(left: depth * 14.0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: ordered ? 24 : 16,
                child: Text(ordered ? '${start + i}.' : '•', style: style.copyWith(color: pal.sub)),
              ),
              Expanded(child: _listItem(context, pal, items[i], depth)),
            ]),
          ),
      ]),
    );
  }

  Widget _listItem(BuildContext context, Pal pal, md.Element li, int depth) {
    final inline = <md.Node>[];
    final blocks = <Widget>[];
    for (final c in li.children ?? const <md.Node>[]) {
      if (c is md.Element && (c.tag == 'ul' || c.tag == 'ol')) {
        blocks.add(_list(context, pal, c, depth + 1));
      } else if (c is md.Element && c.tag == 'p') {
        inline.addAll(c.children ?? const []);
      } else if (c is md.Element && c.tag == 'input') {
        inline.add(md.Text(c.attributes['checked'] != null ? '☑ ' : '☐ '));
      } else {
        inline.add(c);
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (inline.isNotEmpty) _para(pal, inline, style, 0),
      ...blocks,
    ]);
  }

  Widget _table(Pal pal, md.Element table) {
    final rows = <List<md.Element>>[];
    var header = 0;
    for (final section in table.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final tr in section.children ?? const <md.Node>[]) {
        if (tr is md.Element && tr.tag == 'tr') {
          rows.add((tr.children ?? const []).whereType<md.Element>().toList());
          if (section.tag == 'thead') header++;
        }
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: pal.divider, width: .8, borderRadius: BorderRadius.circular(6)),
        children: [
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: BoxDecoration(color: r < header ? pal.text.withValues(alpha: .06) : null),
              children: [
                for (var c = 0; c < cols; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: c < rows[r].length
                        ? Text.rich(
                            TextSpan(
                                children: _inline(pal, rows[r][c].children ?? const [],
                                    r < header ? style.copyWith(fontWeight: FontWeight.w600) : style)),
                            style: (r < header ? style.copyWith(fontWeight: FontWeight.w600) : style)
                                .copyWith(fontSize: (style.fontSize ?? 17) - 2),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  List<InlineSpan> _inline(Pal pal, List<md.Node> nodes, TextStyle st) {
    final out = <InlineSpan>[];
    for (final n in nodes) {
      if (n is md.Text) {
        out.addAll(_mentions(pal, n.text));
        continue;
      }
      if (n is! md.Element) continue;
      final kids = n.children ?? const <md.Node>[];
      switch (n.tag) {
        case 'strong':
          out.add(TextSpan(children: _inline(pal, kids, st), style: const TextStyle(fontWeight: FontWeight.w700)));
        case 'em':
          out.add(TextSpan(children: _inline(pal, kids, st), style: const TextStyle(fontStyle: FontStyle.italic)));
        case 'del':
          out.add(TextSpan(children: _inline(pal, kids, st), style: const TextStyle(decoration: TextDecoration.lineThrough)));
        case 'code':
          out.add(TextSpan(
            text: n.textContent,
            style: TextStyle(fontFamily: 'monospace', fontSize: (st.fontSize ?? 17) - 2, backgroundColor: pal.text.withValues(alpha: .08)),
          ));
        case 'br':
          out.add(const TextSpan(text: '\n'));
        case 'a':
          final href = n.attributes['href'] ?? '';
          out.add(TextSpan(
            children: _inline(pal, kids, st),
            style: TextStyle(color: pal.tick, decoration: TextDecoration.underline, decorationColor: pal.tick),
            mouseCursor: SystemMouseCursors.click,
            recognizer: TapGestureRecognizer()
              ..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication),
          ));
        case 'img':
          final src = n.attributes['src'] ?? '';
          out.add(TextSpan(
            text: '🖼 ${n.attributes['alt']?.isNotEmpty == true ? n.attributes['alt'] : 'ảnh'}',
            style: TextStyle(color: pal.tick),
            recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(src), mode: LaunchMode.externalApplication),
          ));
        default:
          out.addAll(_inline(pal, kids, st));
      }
    }
    return out;
  }

  static final _autoLink = RegExp(r'(https?://[^\s<>()]+)|(@[a-z0-9._-]+)', caseSensitive: false);

  List<InlineSpan> _mentions(Pal pal, String text) {
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in _autoLink.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      final s = m.group(0)!;
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: s,
          style: TextStyle(color: pal.tick, decoration: TextDecoration.underline, decorationColor: pal.tick),
          recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(s), mode: LaunchMode.externalApplication),
        ));
      } else {
        spans.add(TextSpan(text: s, style: TextStyle(color: pal.tick, fontWeight: FontWeight.w500)));
      }
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return spans;
  }
}
