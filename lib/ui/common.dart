import '../i18n/i18n.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../agent/agent_config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'image_edit.dart';
import 'theme.dart';

/// Ảnh đại diện tròn. Ai chưa đặt ảnh riêng thì hiện nền màu với biểu tượng
/// người hoặc nhóm, giống WhatsApp.
class Avatar extends StatelessWidget {
  final String? userId;
  final String name;
  final double size;
  final IconData? icon;
  /// Hiện vòng màu trạng thái (trực tuyến / vắng / đừng làm phiền); ngoại tuyến thì ảnh xám, mờ.
  final bool status;
  /// Nhóm có ảnh riêng (mốc [flygo-icon] trong mô tả) thì hiện ảnh đó.
  final MmChannel? channel;
  const Avatar({super.key, this.userId, required this.name, this.size = 48, this.icon, this.status = true, this.channel});

  static const _dark = [
    (Color(0xFF12374A), Color(0xFF64C3EE)),
    (Color(0xFF3A2A20), Color(0xFFE2A57E)),
    (Color(0xFF0F3B36), Color(0xFF4CC9B0)),
    (Color(0xFF2E2547), Color(0xFFA38BF0)),
  ];
  static const _light = [
    (Color(0xFFD5ECF7), Color(0xFF3B9ACB)),
    (Color(0xFFF3DED0), Color(0xFFB0714A)),
    (Color(0xFFCFEFE8), Color(0xFF1E9C84)),
    (Color(0xFFE3DCF7), Color(0xFF7059C9)),
  ];

  static const online = Color(0xFF22C55E);
  static const away = Color(0xFFF5B400);
  static const doNotDisturb = Color(0xFFE5484D);

  /// Màu vòng theo trạng thái; null = ngoại tuyến.
  static Color? statusColor(String status, Pal pal) => switch (status) {
        'online' => online,
        'away' => away,
        'dnd' => doNotDisturb,
        _ => null,
      };

  static const _grey = ColorFilter.matrix([
    .2126, .7152, .0722, 0, 0, //
    .2126, .7152, .0722, 0, 0, //
    .2126, .7152, .0722, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  Widget _picture(AppState app, bool dark, double size) {
    final key = (userId ?? name).codeUnits.fold<int>(0, (a, b) => a + b);
    final (bg, fg) = (dark ? _dark : _light)[key % 4];
    // Bot trợ lý AI chưa có ảnh: logo nền tảng (Claude / OpenAI) thay cho hình robot.
    final engine = userId == null ? null : engineOf(app.users[userId]);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
      child: engine != null
          ? EngineIcon(engine, size: size * .5, color: fg)
          : Icon(icon ?? Icons.person, color: fg, size: size * .5),
    );
    if (userId == null) {
      final iconId = channel?.iconFileId;
      if (iconId == null) return fallback;
      return ClipOval(
        child: Image.network(
          app.api.previewUrl(iconId),
          headers: app.api.headers,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
          frameBuilder: (_, child, frame, sync) => frame == null && !sync ? fallback : child,
        ),
      );
    }
    final u = app.users[userId];
    if (u == null || u.lastPictureUpdate <= 0) return fallback;
    return ClipOval(
      child: Image.network(
        app.api.avatarUrl(userId!, u.lastPictureUpdate),
        headers: app.api.headers,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        frameBuilder: (_, child, frame, sync) => frame == null && !sync ? fallback : child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final uid = userId;
    final st = uid == null || !status || app.users[uid]?.isBot == true ? null : app.statuses[uid];
    if (st == null) return _picture(app, dark, size);
    final color = statusColor(st, Pal.of(context));
    final ring = (size * .045).clamp(2.0, 4.0);
    final inner = size - ring * 2 - 3;
    Widget pic = _picture(app, dark, inner);
    if (color == null) pic = Opacity(opacity: .5, child: ColorFiltered(colorFilter: _grey, child: pic));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: color == null
          ? null
          : BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: ring)),
      child: pic,
    );
  }
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
}

List<String> get _weekdays => [tr('Thứ Hai'), tr('Thứ Ba'), tr('Thứ Tư'), tr('Thứ Năm'), tr('Thứ Sáu'), tr('Thứ Bảy'), tr('Chủ Nhật')];

String two(int n) => n.toString().padLeft(2, '0');
String hhmm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
String ddmmyyyy(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Giờ hiển thị trong danh sách chat, giống WhatsApp.
String listTime(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = _day(DateTime.now()).difference(_day(d)).inDays;
  if (diff == 0) return hhmm(d);
  if (diff == 1) return tr('Hôm qua');
  if (diff < 7) return _weekdays[d.weekday - 1];
  return ddmmyyyy(d);
}

/// Nhãn ngày giữa các tin nhắn.
String dayLabel(DateTime d) {
  final diff = _day(DateTime.now()).difference(_day(d)).inDays;
  if (diff == 0) return tr('Hôm nay');
  if (diff == 1) return tr('Hôm qua');
  if (diff < 7) return _weekdays[d.weekday - 1];
  return ddmmyyyy(d);
}

bool sameDay(int a, int b) =>
    _day(DateTime.fromMillisecondsSinceEpoch(a)) == _day(DateTime.fromMillisecondsSinceEpoch(b));

String fileSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Emoji nhanh và bảng emoji theo tên của máy chủ chat (để app cũ hiển thị đúng).
const quickReactions = ['+1', 'heart', 'joy', 'open_mouth', 'cry', 'pray'];

/// (tên trên máy chủ chat, ký tự) theo thứ tự hiển thị trong bảng chọn.
const emojiList = <(String, String)>[
  ('+1', '👍'), ('heart', '❤️'), ('joy', '😂'), ('open_mouth', '😮'), ('cry', '😢'), ('pray', '🙏'),
  ('grinning', '😀'), ('smile', '😄'), ('laughing', '😆'), ('sweat_smile', '😅'), ('rofl', '🤣'),
  ('blush', '😊'), ('slightly_smiling_face', '🙂'), ('upside_down_face', '🙃'), ('wink', '😉'),
  ('heart_eyes', '😍'), ('star_struck', '🤩'), ('kissing_heart', '😘'), ('yum', '😋'), ('sunglasses', '😎'),
  ('hugging_face', '🤗'), ('thinking_face', '🤔'), ('neutral_face', '😐'), ('expressionless', '😑'),
  ('roll_eyes', '🙄'), ('grimacing', '😬'), ('relieved', '😌'), ('sleeping', '😴'), ('sob', '😭'),
  ('scream', '😱'), ('astonished', '😲'), ('flushed', '😳'), ('rage', '😡'), ('partying_face', '🥳'),
  ('-1', '👎'), ('ok_hand', '👌'), ('clap', '👏'), ('raised_hands', '🙌'), ('muscle', '💪'),
  ('handshake', '🤝'), ('v', '✌️'), ('wave', '👋'), ('point_up', '☝️'), ('fire', '🔥'), ('tada', '🎉'),
  ('100', '💯'), ('star', '⭐'), ('sparkles', '✨'), ('white_check_mark', '✅'), ('heavy_check_mark', '✔️'),
  ('x', '❌'), ('warning', '⚠️'), ('eyes', '👀'), ('rocket', '🚀'), ('bulb', '💡'), ('moneybag', '💰'),
  ('chart_with_upwards_trend', '📈'), ('chart_with_downwards_trend', '📉'), ('pushpin', '📌'),
  ('paperclip', '📎'), ('telephone_receiver', '📞'), ('date', '📅'), ('clock1', '🕐'), ('coffee', '☕'),
  ('ramen', '🍜'), ('beers', '🍻'), ('birthday', '🎂'), ('gift', '🎁'), ('office', '🏢'), ('house', '🏠'),
  ('car', '🚗'), ('broken_heart', '💔'), ('green_heart', '💚'), ('blue_heart', '💙'),
  ('calendar', '📆'), ('airplane', '✈️'), ('palm_tree', '🌴'), ('face_with_thermometer', '🤒'),
  ('fork_and_knife', '🍴'), ('computer', '💻'), ('headphones', '🎧'), ('no_entry', '⛔'), ('books', '📚'),
  ('hospital', '🏥'), ('baby', '👶'), ('moon', '🌙'),
];

final Map<String, String> emojiMap = {
  for (final (n, c) in emojiList) n: c,
  'thumbsup': '👍', 'thumbsdown': '👎', 'grin': '😁', 'smiley': '😃', 'kissing': '😗',
  'face_with_rolling_eyes': '🙄', 'hugs': '🤗', 'white_heart': '🤍', 'heart_eyes_cat': '😻',
  // Số (trả lời câu hỏi của trợ lý bằng cảm xúc).
  'zero': '0️⃣', 'one': '1️⃣', 'two': '2️⃣', 'three': '3️⃣', 'four': '4️⃣', 'five': '5️⃣',
  'six': '6️⃣', 'seven': '7️⃣', 'eight': '8️⃣', 'nine': '9️⃣', 'keycap_ten': '🔟', 'x': '❌',
};
String emojiOf(String name) => emojiMap[name] ?? ':$name:';

/// Thanh báo mất mạng.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final online = context.select<AppState, bool>((a) => a.online);
    if (online) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      color: dark ? const Color(0xFF3A3000) : const Color(0xFFFFF3C4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Icon(Icons.cloud_off, size: 18, color: dark ? const Color(0xFFE8C547) : const Color(0xFF8A6D00)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(tr('Đang chờ kết nối mạng. Tin nhắn sẽ được gửi khi có mạng.'),
              style: TextStyle(color: dark ? const Color(0xFFF2DC8C) : const Color(0xFF5C4A00), fontSize: 13)),
        ),
      ]),
    );
  }
}


final _shortcodeRe = RegExp(r':([a-z0-9_+\-]+):');

/// Đổi `:ten_emoji:` thành ký tự emoji nếu biết.
String replaceShortcodes(String t) =>
    t.replaceAllMapped(_shortcodeRe, (m) => emojiMap[m.group(1)] ?? m.group(0)!);

/// Bỏ ký hiệu markdown để làm dòng xem trước gọn gàng.
String plainPreview(String t) => replaceShortcodes(t)
    .replaceAll(RegExp(r'\*\*|__|`{1,3}|^#+\s*', multiLine: true), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

final _inlineRe = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])');

/// Markdown nội dòng tối giản: **đậm**, *nghiêng*, _nghiêng_, `mã`.
List<InlineSpan> inlineMarkdown(String text, TextStyle? code, List<InlineSpan> Function(String) plain) {
  final spans = <InlineSpan>[];
  var i = 0;
  for (final m in _inlineRe.allMatches(text)) {
    if (m.start > i) spans.addAll(plain(text.substring(i, m.start)));
    if (m.group(1) != null) {
      spans.add(TextSpan(children: plain(m.group(1)!), style: const TextStyle(fontWeight: FontWeight.w700)));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(text: m.group(2), style: code));
    } else {
      spans.add(TextSpan(children: plain(m.group(3) ?? m.group(4)!), style: const TextStyle(fontStyle: FontStyle.italic)));
    }
    i = m.end;
  }
  if (i < text.length) spans.addAll(plain(text.substring(i)));
  return spans;
}

/// Logo của bộ máy chạy trợ lý: Claude (cam) hoặc OpenAI/Codex (theo màu chữ); khác thì biểu tượng robot.
class EngineIcon extends StatelessWidget {
  final String engine;
  final double size;
  final Color? color;
  const EngineIcon(this.engine, {super.key, this.size = 16, this.color});

  static String? assetOf(String engine) {
    final e = engine.toLowerCase();
    if (e.contains('claude') || e.contains('anthropic')) return 'assets/engines/claude.svg';
    if (e.contains('codex') || e.contains('openai') || e.contains('gpt')) return 'assets/engines/openai.svg';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final asset = assetOf(engine);
    final c = color ?? Pal.of(context).text;
    if (asset == null) return Icon(Icons.smart_toy_outlined, size: size, color: c);
    final claude = asset.endsWith('claude.svg');
    return SvgPicture.asset(asset,
        width: size, height: size, colorFilter: ColorFilter.mode(claude ? const Color(0xFFD97757) : c, BlendMode.srcIn));
  }
}

/// Bộ máy của bot trợ lý AI (claude / codex …) theo mốc [flygo-agent engine=…]; null nếu không phải bot trợ lý.
String? engineOf(MmUser? u) => u == null ? null : agentOptionsOf(u)?.engine;

/// Tên người / cuộc trò chuyện; tài khoản bot luôn có biểu tượng bot cố định ở cuối
/// (tên dài thì chỉ cắt phần tên, biểu tượng vẫn hiện).
Widget nameText(String name,
    {bool bot = false, String? engine, TextStyle? style, int? maxLines = 1, TextOverflow? overflow = TextOverflow.ellipsis, TextAlign? textAlign}) {
  final text = Text(name, style: style, maxLines: maxLines, overflow: overflow, textAlign: textAlign);
  if (!bot) return text;
  return Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: textAlign == TextAlign.center ? MainAxisAlignment.center : MainAxisAlignment.start,
    // Bot: biểu tượng nền tảng (Claude / OpenAI, không rõ thì robot) đứng trước tên, cao bằng chữ.
    children: [
      Padding(
        padding: const EdgeInsets.only(right: 5),
        child: EngineIcon(engine ?? '', size: (style?.fontSize ?? 16) * 1.15, color: style?.color),
      ),
      Flexible(child: text),
    ],
  );
}

/// Biểu tượng cho cuộc trò chuyện không có ảnh người: Cloud của tôi, kênh công khai (loa), nhóm riêng tư.
IconData chatIcon(MmChannel c) => c.isSelfDm ? Icons.cloud : c.isSub ? Icons.lock_outline : (c.isPublic ? Icons.campaign : Icons.groups);

/// Chọn một ảnh làm ảnh đại diện (điện thoại cho cắt / xoay trước). Trả về (tên, dữ liệu).
Future<(String, Uint8List)?> pickAvatarImage(BuildContext context) async {
  final files = await FilePicker.pickFiles(type: FileType.image);
  final f = files.firstOrNull;
  if (f == null || f.path == null) return null;
  var path = f.path!;
  if (!context.mounted) return null;
  if (Platform.isAndroid || Platform.isIOS) {
    final edited = await editImage(context, path);
    if (edited == null) return null;
    path = edited;
  }
  return (path.split(Platform.pathSeparator).last, await File(path).readAsBytes());
}

/// Ảnh đại diện bấm được để đổi (biểu tượng máy ảnh nhỏ ở góc).
class EditableAvatar extends StatelessWidget {
  final Widget avatar;
  final double size;
  final Future<void> Function(String name, Uint8List bytes) onPicked;
  const EditableAvatar({super.key, required this.avatar, required this.size, required this.onPicked});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return GestureDetector(
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final r = await pickAvatarImage(context);
        if (r == null) return;
        try {
          await onPicked(r.$1, r.$2);
          messenger.showSnackBar(toast(Text(tr('Đã đổi ảnh đại diện'))));
        } catch (_) {
          messenger.showSnackBar(toast(Text(tr('Không đổi được ảnh. Bạn có thể không có quyền.'))));
        }
      },
      child: Stack(clipBehavior: Clip.none, children: [
        avatar,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.all(size > 60 ? 7 : 3),
            decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle, border: Border.all(color: pal.bg, width: 2)),
            child: Icon(Icons.photo_camera, size: size > 60 ? 18 : 11, color: Colors.white),
          ),
        ),
      ]),
    );
  }
}

/// Tab có chữ và số đếm trong ô màu (thay cho "(N)").
class CountTab extends StatelessWidget {
  final String label;
  final int count;
  const CountTab({super.key, required this.label, required this.count});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Tab(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label),
        // Không có gì thì không hiện số 0.
        if (count > 0) ...[
        const SizedBox(width: 6),
        Container(
          constraints: const BoxConstraints(minWidth: 20),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(color: pal.accent.withValues(alpha: .16), borderRadius: BorderRadius.circular(10)),
          child: Text('$count',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pal.accentText)),
        ),
        ],
      ]),
    );
  }
}

/// Nút ＋ tròn nổi ngay trên thanh tab (tab Chat, tab Agents): nền màu nhấn mờ.
class PlusFab extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final Object heroTag;
  const PlusFab({super.key, required this.tooltip, required this.onPressed, required this.heroTag});

  /// Khoảng cách từ đáy màn hình tới nút (ngay trên thanh tab).
  static double bottomOf(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return (inset > 0 ? inset - 14 : 10) + 88;
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return FloatingActionButton(
      heroTag: heroTag,
      tooltip: tooltip,
      onPressed: onPressed,
      elevation: 2,
      backgroundColor: pal.accent.withValues(alpha: .55),
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
      child: const Icon(Icons.add, size: 28),
    );
  }
}

/// Hộp thoại nhập một dòng chữ (đổi tên…). Trả về chữ đã nhập, null nếu huỷ.
Future<String?> askText(BuildContext context, String title, String initial) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text(tr('Lưu'))),
      ],
    ),
  );
}

