import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bảng màu tone xanh dương (bố cục theo WhatsApp iOS); có cả nền tối và nền sáng.
@immutable
class Pal extends ThemeExtension<Pal> {
  final Color bg, surface, surface2, text, sub, divider, accent, accentText;
  final Color chipSelBg, chipSelFg, outBubble, inBubble, quoteOut, quoteIn, quoteBar, tick, chatBg, doodle;
  final Color avatarBg, avatarFg, glass;
  /// Nền trang luồng công việc riêng (khác nền chat chính cho dễ phân biệt).
  final Color threadBg;

  const Pal({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.sub,
    required this.divider,
    required this.accent,
    required this.accentText,
    required this.chipSelBg,
    required this.chipSelFg,
    required this.outBubble,
    required this.inBubble,
    required this.quoteOut,
    required this.quoteIn,
    required this.quoteBar,
    required this.tick,
    required this.chatBg,
    required this.doodle,
    required this.avatarBg,
    required this.avatarFg,
    required this.glass,
    required this.threadBg,
  });

  static const dark = Pal(
    bg: Color(0xFF0B0B0B),
    surface: Color(0xFF1C1C1E),
    surface2: Color(0xFF2C2C2E),
    text: Colors.white,
    sub: Color(0xFF8E8E93),
    divider: Color(0xFF2A2A2C),
    accent: Color(0xFF2F8CFF),
    accentText: Color(0xFF5AA8FF),
    chipSelBg: Color(0xFF0F2A4A),
    chipSelFg: Color(0xFF8EC3FF),
    outBubble: Color(0xFF1F5FAE),
    inBubble: Color(0xFF262628),
    quoteOut: Color(0xFF184C8C),
    quoteIn: Color(0xFF1B1B1D),
    quoteBar: Color(0xFF5AA8FF),
    tick: Color(0xFF8FD3FF),
    chatBg: Color(0xFF0B0B0B),
    doodle: Color(0x10FFFFFF),
    avatarBg: Color(0xFF12374A),
    avatarFg: Color(0xFF64C3EE),
    glass: Color(0xB01C1C1E),
    threadBg: Color(0xFF15121D),
  );

  static const light = Pal(
    bg: Colors.white,
    surface: Color(0xFFF2F2F7),
    surface2: Color(0xFFE5E5EA),
    text: Color(0xFF111111),
    sub: Color(0xFF86868B),
    divider: Color(0xFFE3E3E8),
    accent: Color(0xFF1E7BFF),
    accentText: Color(0xFF0A66D9),
    chipSelBg: Color(0xFFDCEBFF),
    chipSelFg: Color(0xFF0B4A9E),
    outBubble: Color(0xFFB8D8FF),
    inBubble: Colors.white,
    quoteOut: Color(0xFFA2CBFA),
    quoteIn: Color(0xFFF0F0F2),
    quoteBar: Color(0xFF0A66D9),
    tick: Color(0xFF1E88E5),
    chatBg: Color(0xFFE8EEF6),
    doodle: Color(0x0D000000),
    avatarBg: Color(0xFFD9EEF7),
    avatarFg: Color(0xFF3B9ACB),
    glass: Color(0xCCF7F7F9),
    threadBg: Color(0xFFEFEAF7),
  );

  static Pal of(BuildContext context) => Theme.of(context).extension<Pal>()!;

  @override
  Pal copyWith() => this;

  @override
  Pal lerp(ThemeExtension<Pal>? other, double t) => t < .5 ? this : (other as Pal? ?? this);
}

ThemeData buildTheme(Brightness b) {
  final pal = b == Brightness.dark ? Pal.dark : Pal.light;
  final base = ThemeData(useMaterial3: true, brightness: b);
  return base.copyWith(
    scaffoldBackgroundColor: pal.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: pal.accent, brightness: b, primary: pal.accent, onPrimary: Colors.white, surface: pal.bg),
    extensions: [pal],
    dividerColor: pal.divider,
    textSelectionTheme: TextSelectionThemeData(cursorColor: pal.accent, selectionColor: pal.accent.withValues(alpha: .35)),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: pal.surface,
      surfaceTintColor: Colors.transparent,
      // Trên máy tính bảng trượt lên không trải hết chiều ngang cửa sổ.
      constraints: const BoxConstraints(maxWidth: 520),
    ),
    dialogTheme: DialogThemeData(backgroundColor: pal.surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: pal.surface2, surfaceTintColor: Colors.transparent),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: pal.surface2,
        contentTextStyle: TextStyle(color: pal.text)),
    textTheme: base.textTheme.apply(bodyColor: pal.text, displayColor: pal.text),
    iconTheme: IconThemeData(color: pal.text),
  );
}

/// Nút tròn kiểu kính mờ (nút quay lại, nút "…").
class GlassCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final Color? iconColor;
  final double size;
  final String? tooltip;
  const GlassCircle({super.key, required this.icon, this.onTap, this.color, this.iconColor, this.size = 44, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final w = Material(
      color: color ?? pal.surface,
      shape: CircleBorder(side: BorderSide(color: pal.text.withValues(alpha: .08))),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: size, height: size, child: Icon(icon, color: iconColor ?? pal.text, size: size * .5)),
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// Lớp kính mờ cho thanh trên và thanh tab nổi.
class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  const Glass({super.key, required this.child, this.radius = BorderRadius.zero});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(color: pal.glass, child: child),
      ),
    );
  }
}

/// Họa tiết chìm cho nền khung chat (tự vẽ bằng biểu tượng Material).
class DoodleBackground extends StatelessWidget {
  final Widget child;
  /// Màu nền khác (vd. luồng công việc riêng); mặc định là nền chat.
  final Color? color;
  const DoodleBackground({super.key, required this.child, this.color});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      color: color ?? pal.chatBg,
      child: CustomPaint(painter: _DoodlePainter(pal.doodle), child: child),
    );
  }
}

class _DoodlePainter extends CustomPainter {
  final Color color;
  _DoodlePainter(this.color);
  static const _icons = [
    Icons.favorite_border, Icons.local_cafe_outlined, Icons.music_note_outlined, Icons.star_border,
    Icons.camera_alt_outlined, Icons.cloud_outlined, Icons.emoji_emotions_outlined, Icons.eco_outlined,
    Icons.headphones_outlined, Icons.lightbulb_outline, Icons.pets_outlined, Icons.wb_sunny_outlined,
    Icons.local_florist_outlined, Icons.directions_bike_outlined, Icons.cake_outlined, Icons.anchor_outlined,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 64.0;
    final rnd = Random(7);
    for (double y = 0; y < size.height + cell; y += cell) {
      for (double x = 0; x < size.width + cell; x += cell) {
        final icon = _icons[rnd.nextInt(_icons.length)];
        final tp = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 26, color: color),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.translate(x + rnd.nextDouble() * 20, y + rnd.nextDouble() * 20);
        canvas.rotate((rnd.nextDouble() - .5) * .8);
        tp.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_DoodlePainter old) => old.color != color;
}


/// Bấm Esc (máy tính) để đóng trang hiện tại.
class EscToPop extends StatelessWidget {
  final Widget child;
  const EscToPop({super.key, required this.child});
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
        child: Focus(autofocus: true, child: child),
      );
}

/// Màn hình chính có thanh tab nổi ở đáy: thông báo (SnackBar) nổi phía trên thanh tab, không bị che.
/// [navTop]: khoảng từ mép trên thanh tab tới đáy vùng an toàn (SnackBar nổi tự tránh vùng an toàn).
class AboveNavSnackBars extends StatelessWidget {
  final double navTop;
  final Widget child;
  const AboveNavSnackBars({super.key, required this.navTop, required this.child});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        snackBarTheme: theme.snackBarTheme.copyWith(insetPadding: EdgeInsets.fromLTRB(15, 5, 15, navTop + 8)),
      ),
      child: child,
    );
  }
}
