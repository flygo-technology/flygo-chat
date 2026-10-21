import '../i18n/i18n.dart';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Giao diện chat (dùng chung cho mọi thành viên, mốc `[flygo-theme <id>]` trong header kênh).
/// Mỗi giao diện có hai chế độ ngày / đêm (theo chế độ sáng / tối của máy), sinh từ một sắc độ (hue) + độ bão hòa:
/// ngày = nền rất sáng + chữ rất tối, đêm = nền rất tối + chữ rất sáng — tương phản chữ/nền ≥ 7:1 (kiểm tra ở
/// test/chat_themes_test.dart).
class ChatTheme {
  final String id;
  final String name;
  final double hue, sat;
  const ChatTheme(this.id, this.name, this.hue, this.sat);

  Color _c(double s, double l) => HSLColor.fromAHSL(1, hue, s.clamp(0.0, 1.0), l).toColor();

  ChatThemeColors colors(bool dark) => dark
      ? ChatThemeColors(
          bg: _c(sat * .55, .10),
          fg: _c(sat * .30, .93),
          accent: _c(.70 * (sat > 0 ? 1 : 0), .62),
          inBubble: _c(sat * .40, .18),
          outBubble: _c(sat * .55, .27),
          dark: true,
        )
      : ChatThemeColors(
          bg: _c(sat * .70, .93),
          fg: _c(sat * .60, .13),
          accent: _c(.70 * (sat > 0 ? 1 : 0), .38),
          inBubble: _c(sat * .45, .99),
          outBubble: _c(sat * .70, .84),
          dark: false,
        );

  /// Bảng màu Pal cho vùng tin nhắn khi dùng giao diện này.
  Pal apply(Pal p, bool dark) {
    final c = colors(dark);
    return Pal(
      bg: p.bg,
      surface: p.surface,
      surface2: p.surface2,
      text: c.fg,
      sub: Color.lerp(c.fg, c.bg, .38)!,
      divider: c.fg.withValues(alpha: .14),
      accent: c.accent,
      accentText: c.accent,
      chipSelBg: p.chipSelBg,
      chipSelFg: p.chipSelFg,
      outBubble: c.outBubble,
      inBubble: c.inBubble,
      quoteOut: Color.alphaBlend(c.fg.withValues(alpha: .08), c.outBubble),
      quoteIn: Color.alphaBlend(c.fg.withValues(alpha: .06), c.inBubble),
      quoteBar: c.accent,
      tick: c.accent,
      chatBg: c.bg,
      doodle: c.fg.withValues(alpha: .05),
      avatarBg: p.avatarBg,
      avatarFg: p.avatarFg,
      glass: p.glass,
      threadBg: c.bg,
    );
  }
}

class ChatThemeColors {
  final Color bg, fg, accent, inBubble, outBubble;
  final bool dark;
  const ChatThemeColors({required this.bg, required this.fg, required this.accent, required this.inBubble, required this.outBubble, required this.dark});
}

List<ChatTheme> get chatThemes => [
      ChatTheme('midnight', tr('Nửa đêm'), 222, .55),
      ChatTheme('ocean', tr('Biển sâu'), 200, .70),
      ChatTheme('teal', tr('Ngọc lam'), 178, .60),
      ChatTheme('forest', tr('Rừng thông'), 145, .45),
      ChatTheme('mint', tr('Bạc hà'), 160, .55),
      ChatTheme('lime', tr('Cốm non'), 95, .50),
      ChatTheme('lemon', tr('Chanh vàng'), 52, .75),
      ChatTheme('sand', tr('Cát vàng'), 38, .55),
      ChatTheme('peach', tr('Đào'), 22, .75),
      ChatTheme('coral', tr('San hô'), 8, .70),
      ChatTheme('rose', tr('Hoa hồng'), 345, .65),
      ChatTheme('blush', tr('Hồng phấn'), 328, .55),
      ChatTheme('wine', tr('Rượu vang'), 335, .35),
      ChatTheme('violet', tr('Tím than'), 268, .50),
      ChatTheme('lavender', tr('Oải hương'), 255, .60),
      ChatTheme('indigo', tr('Chàm'), 236, .45),
      ChatTheme('slate', tr('Đá xám'), 215, .18),
      ChatTheme('coffee', tr('Cà phê'), 26, .30),
      ChatTheme('stone', tr('Xi măng'), 30, .07),
      ChatTheme('ink', tr('Mực tàu'), 0, 0),
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
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        Widget tile(ChatTheme? t) {
          final on = (t?.id ?? '') == (current ?? '');
          final c = t?.colors(dark);
          final bg = c?.bg ?? pal.chatBg, fg = c?.fg ?? pal.text;
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
                    decoration: BoxDecoration(color: c?.inBubble ?? pal.inBubble, borderRadius: BorderRadius.circular(10)),
                    child: Text('Aa', style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 34,
                    height: 16,
                    decoration: BoxDecoration(color: c?.outBubble ?? pal.outBubble, borderRadius: BorderRadius.circular(8)),
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
              child: Text(tr('Đổi cho mọi người trong cuộc trò chuyện này. Mỗi giao diện tự đổi theo chế độ ngày / đêm của máy.'),
                  style: TextStyle(color: pal.sub, fontSize: 13)),
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

/// Bảng màu kiểu Claude app cho chat 1-1 với trợ lý (đo từ app Claude trên Android: nền #151515, chữ #E0E0DF,
/// tin người dùng #0D0D0D, ô nhập #20201F, nút #313131; bản sáng theo tông giấy ngà của Claude).
Pal claudePal(Pal p, bool dark) {
  const orange = Color(0xFFD97757);
  return dark
      ? Pal(
          bg: const Color(0xFF151515),
          surface: const Color(0xFF20201F),
          surface2: const Color(0xFF313131),
          text: const Color(0xFFE0E0DF),
          sub: const Color(0xFF9B9A96),
          divider: const Color(0xFF2E2E2C),
          accent: orange,
          accentText: const Color(0xFFE48B6E),
          chipSelBg: p.chipSelBg,
          chipSelFg: p.chipSelFg,
          outBubble: const Color(0xFF0D0D0D),
          inBubble: const Color(0xFF151515),
          quoteOut: const Color(0xFF242423),
          quoteIn: const Color(0xFF242423),
          quoteBar: orange,
          tick: const Color(0xFF9B9A96),
          chatBg: const Color(0xFF151515),
          doodle: const Color(0x00000000),
          avatarBg: p.avatarBg,
          avatarFg: p.avatarFg,
          glass: const Color(0xE6151515),
          threadBg: const Color(0xFF151515),
        )
      : Pal(
          bg: const Color(0xFFFAF9F5),
          surface: Colors.white,
          surface2: const Color(0xFFF0EEE6),
          text: const Color(0xFF141413),
          sub: const Color(0xFF6F6E69),
          divider: const Color(0xFFE6E3D9),
          accent: orange,
          accentText: const Color(0xFFB9532F),
          chipSelBg: p.chipSelBg,
          chipSelFg: p.chipSelFg,
          outBubble: const Color(0xFFF0EEE6),
          inBubble: const Color(0xFFFAF9F5),
          quoteOut: const Color(0xFFE6E3D9),
          quoteIn: const Color(0xFFF0EEE6),
          quoteBar: orange,
          tick: const Color(0xFF6F6E69),
          chatBg: const Color(0xFFFAF9F5),
          doodle: const Color(0x00000000),
          avatarBg: p.avatarBg,
          avatarFg: p.avatarFg,
          glass: const Color(0xE6FAF9F5),
          threadBg: const Color(0xFFFAF9F5),
        );
}

/// Bảng màu kiểu ChatGPT cho chat 1-1 với trợ lý Codex (đo từ app ChatGPT Android, bản sáng: nền #FCFCFC, chữ #0D0D0D,
/// tin người dùng #F2F2F2, ô nhập trắng nổi, nút gửi tròn đen; bản tối theo bảng màu tối của ChatGPT).
Pal gptPal(Pal p, bool dark) => dark
    ? Pal(
        bg: const Color(0xFF212121),
        surface: const Color(0xFF303030),
        surface2: const Color(0xFF3A3A3A),
        text: const Color(0xFFECECEC),
        sub: const Color(0xFF9B9B9B),
        divider: const Color(0xFF3A3A3A),
        accent: Colors.white,
        accentText: const Color(0xFF8AB4F8),
        chipSelBg: p.chipSelBg,
        chipSelFg: p.chipSelFg,
        outBubble: const Color(0xFF303030),
        inBubble: const Color(0xFF212121),
        quoteOut: const Color(0xFF3A3A3A),
        quoteIn: const Color(0xFF2A2A2A),
        quoteBar: const Color(0xFF8AB4F8),
        tick: const Color(0xFF9B9B9B),
        chatBg: const Color(0xFF212121),
        doodle: const Color(0x00000000),
        avatarBg: p.avatarBg,
        avatarFg: p.avatarFg,
        glass: const Color(0xE6212121),
        threadBg: const Color(0xFF212121),
      )
    : Pal(
        bg: const Color(0xFFFCFCFC),
        surface: Colors.white,
        surface2: const Color(0xFFF2F2F2),
        text: const Color(0xFF0D0D0D),
        sub: const Color(0xFF6B6B6B),
        divider: const Color(0xFFE6E6E6),
        accent: const Color(0xFF0D0D0D),
        accentText: const Color(0xFF2964AA),
        chipSelBg: p.chipSelBg,
        chipSelFg: p.chipSelFg,
        outBubble: const Color(0xFFF2F2F2),
        inBubble: const Color(0xFFFCFCFC),
        quoteOut: const Color(0xFFE6E6E6),
        quoteIn: const Color(0xFFF2F2F2),
        quoteBar: const Color(0xFF0D0D0D),
        tick: const Color(0xFF6B6B6B),
        chatBg: const Color(0xFFFCFCFC),
        doodle: const Color(0x00000000),
        avatarBg: p.avatarBg,
        avatarFg: p.avatarFg,
        glass: const Color(0xE6FCFCFC),
        threadBg: const Color(0xFFFCFCFC),
      );
