import '../i18n/i18n.dart';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Giao diện chat (dùng chung cho mọi thành viên, mốc `[flygo-theme <id>]` trong header kênh):
/// màu nền khung chat + màu chữ tương phản, bong bóng tin suy ra từ hai màu đó.
class ChatTheme {
  final String id;
  final String name;
  final Color bg, fg, accent;
  const ChatTheme(this.id, this.name, this.bg, this.fg, this.accent);

  bool get dark => bg.computeLuminance() < .4;
  Color get inBubble => Color.alphaBlend((dark ? Colors.white : Colors.black).withValues(alpha: dark ? .10 : .05), dark ? bg : Color.alphaBlend(Colors.white.withValues(alpha: .75), bg));
  Color get outBubble => Color.alphaBlend(accent.withValues(alpha: dark ? .42 : .30), bg);

  /// Bảng màu Pal cho vùng tin nhắn khi dùng giao diện này.
  Pal apply(Pal p) => Pal(
        bg: p.bg,
        surface: p.surface,
        surface2: p.surface2,
        text: fg,
        sub: fg.withValues(alpha: .62),
        divider: fg.withValues(alpha: .14),
        accent: accent,
        accentText: dark ? Color.lerp(accent, Colors.white, .35)! : Color.lerp(accent, Colors.black, .25)!,
        chipSelBg: p.chipSelBg,
        chipSelFg: p.chipSelFg,
        outBubble: outBubble,
        inBubble: inBubble,
        quoteOut: Color.alphaBlend(fg.withValues(alpha: .08), outBubble),
        quoteIn: Color.alphaBlend(fg.withValues(alpha: .06), inBubble),
        quoteBar: accent,
        tick: dark ? Color.lerp(accent, Colors.white, .45)! : accent,
        chatBg: bg,
        doodle: fg.withValues(alpha: .05),
        avatarBg: p.avatarBg,
        avatarFg: p.avatarFg,
        glass: p.glass,
        threadBg: bg,
      );
}

List<ChatTheme> get chatThemes => [
      ChatTheme('midnight', tr('Nửa đêm'), const Color(0xFF0F172A), const Color(0xFFE2E8F0), const Color(0xFF38BDF8)),
      ChatTheme('ink', tr('Mực tàu'), const Color(0xFF111111), const Color(0xFFF5F5F5), const Color(0xFFFF4D4D)),
      ChatTheme('forest', tr('Rừng thông'), const Color(0xFF0F2A1D), const Color(0xFFE6F4EA), const Color(0xFF34D399)),
      ChatTheme('ocean', tr('Biển sâu'), const Color(0xFF082F49), const Color(0xFFE0F2FE), const Color(0xFF22D3EE)),
      ChatTheme('wine', tr('Rượu vang'), const Color(0xFF3B0A1E), const Color(0xFFFCE7F3), const Color(0xFFF472B6)),
      ChatTheme('violet', tr('Tím than'), const Color(0xFF1E1B4B), const Color(0xFFEDE9FE), const Color(0xFFA78BFA)),
      ChatTheme('coffee', tr('Cà phê'), const Color(0xFF2B1D14), const Color(0xFFF5E6D3), const Color(0xFFF59E0B)),
      ChatTheme('slate', tr('Đá xám'), const Color(0xFF1F2937), const Color(0xFFF3F4F6), const Color(0xFF60A5FA)),
      ChatTheme('terminal', tr('Màn hình xanh'), const Color(0xFF020B05), const Color(0xFF4ADE80), const Color(0xFF22C55E)),
      ChatTheme('urgent', tr('Đỏ đen'), const Color(0xFF000000), const Color(0xFFFF3B30), const Color(0xFFFF3B30)),
      ChatTheme('paper', tr('Giấy trắng'), const Color(0xFFFAFAF7), const Color(0xFF1C1917), const Color(0xFF2563EB)),
      ChatTheme('sand', tr('Cát vàng'), const Color(0xFFF5EBDD), const Color(0xFF3F2E1E), const Color(0xFFC2410C)),
      ChatTheme('mint', tr('Bạc hà'), const Color(0xFFE7F7EF), const Color(0xFF0B3B2A), const Color(0xFF059669)),
      ChatTheme('sky', tr('Bầu trời'), const Color(0xFFE6F2FF), const Color(0xFF0B2545), const Color(0xFF1D4ED8)),
      ChatTheme('blush', tr('Hồng phấn'), const Color(0xFFFDECF2), const Color(0xFF4A0D2B), const Color(0xFFDB2777)),
      ChatTheme('lavender', tr('Oải hương'), const Color(0xFFF1ECFB), const Color(0xFF2E1065), const Color(0xFF7C3AED)),
      ChatTheme('lemon', tr('Chanh vàng'), const Color(0xFFFFF9DB), const Color(0xFF3D3200), const Color(0xFFCA8A04)),
      ChatTheme('peach', tr('Đào'), const Color(0xFFFFEDE3), const Color(0xFF4A1D0C), const Color(0xFFEA580C)),
      ChatTheme('stone', tr('Xi măng'), const Color(0xFFE7E5E4), const Color(0xFF1C1917), const Color(0xFF57534E)),
      ChatTheme('newsprint', tr('Báo giấy'), const Color(0xFFF2EFE6), const Color(0xFF111111), const Color(0xFFB91C1C)),
    ];

ChatTheme? chatThemeById(String? id) => id == null ? null : chatThemes.where((t) => t.id == id).firstOrNull;

/// Màu nền banner gợi ý.
const bannerColors = [
  'B64D05', 'D32F2F', 'C2185B', '7B1FA2', '303F9F', '1976D2', '0097A7', '00796B',
  '388E3C', 'F9A825', '5D4037', '455A64', '111111', 'FFFFFF',
];

/// Bảng chọn giao diện chat. Trả về id (chuỗi rỗng = mặc định), null = huỷ.
Future<String?> pickChatTheme(BuildContext context, String? current) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        final pal = Pal.of(ctx);
        Widget tile(ChatTheme? t) {
          final on = (t?.id ?? '') == (current ?? '');
          final bg = t?.bg ?? pal.chatBg, fg = t?.fg ?? pal.text;
          return GestureDetector(
            onTap: () => Navigator.pop(ctx, t?.id ?? ''),
            child: Container(
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: on ? pal.accent : pal.divider, width: on ? 3 : 1),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: t?.inBubble ?? pal.inBubble, borderRadius: BorderRadius.circular(10)),
                    child: Text('Aa', style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 34,
                    height: 16,
                    decoration: BoxDecoration(color: t?.outBubble ?? pal.outBubble, borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const Spacer(),
                Text(t?.name ?? tr('Mặc định'),
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                    style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ]),
            ),
          );
        }

        return SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .75,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(tr('Giao diện chat'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(tr('Đổi cho mọi người trong cuộc trò chuyện này.'), style: TextStyle(color: pal.sub, fontSize: 13)),
            ),
            Expanded(
              child: GridView.count(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: .95,
                children: [tile(null), for (final t in chatThemes) tile(t)],
              ),
            ),
          ]),
        );
      },
    );

/// Sửa banner (chữ + màu nền). Trả về banner mới; text rỗng = bỏ banner; null = huỷ.
Future<({String color, String text})?> editBanner(BuildContext context, ({String color, String text})? cur) {
  final ctl = TextEditingController(text: cur?.text ?? '');
  var color = cur?.color ?? bannerColors.first;
  return showModalBottomSheet<({String color, String text})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final pal = Pal.of(ctx);
      final c = Color(int.parse('FF$color', radix: 16));
      final fg = c.computeLuminance() > .55 ? Colors.black : Colors.white;
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Banner'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
          const SizedBox(height: 4),
          Text(tr('Dải thông báo dưới tên chat, mọi người trong cuộc trò chuyện đều thấy.'), style: TextStyle(color: pal.sub, fontSize: 13)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(10)),
            child: Text(ctl.text.trim().isEmpty ? tr('Xem trước banner') : ctl.text.trim(),
                textAlign: TextAlign.center, maxLines: 2, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            maxLength: 200,
            onChanged: (_) => set(() {}),
            decoration: InputDecoration(
              hintText: tr('Nội dung banner'),
              filled: true,
              fillColor: pal.surface2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final h in bannerColors)
              GestureDetector(
                onTap: () => set(() => color = h),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Color(int.parse('FF$h', radix: 16)),
                    shape: BoxShape.circle,
                    border: Border.all(color: h == color ? pal.accent : pal.divider, width: h == color ? 3 : 1),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            if (cur != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, (color: color, text: '')),
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                child: Text(tr('Bỏ banner')),
              ),
            const Spacer(),
            FilledButton(onPressed: () => Navigator.pop(ctx, (color: color, text: ctl.text.trim())), child: Text(tr('Lưu'))),
          ]),
        ]),
      );
    }),
  );
}
