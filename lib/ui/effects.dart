import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

// Hiệu ứng tin nhắn (nút "Hiệu ứng" cạnh "Luồng riêng"):
// - Hình ảnh: gửi kèm props.flygo_fx = {visual}; người nhận mở chat thấy tin thì phát một lần.
// - Cảnh báo: tin quan trọng / khẩn cấp (bắt xác nhận đã đọc) — dùng metadata priority sẵn có của Mattermost.
// - Tự hủy: người nhận bấm để xem, tin tự xoá sau 10 phút.
// - Màu nền: props.flygo_fx.bg = mã nền gradient (fxBackgrounds).
// Hẹn giờ gửi là nút riêng (showScheduleSheet).

/// Âm thanh (tin cũ gửi kèm props.flygo_fx.sound vẫn phát; không còn chọn mới): mã → (tên, tệp trong assets/ringtones).
Map<String, (String, String)> get fxSounds => {
      'chime': (tr('Leng keng'), 'ringtones/ring_chime.mp3'),
      'bell': (tr('Chuông'), 'ringtones/ring_bell.mp3'),
      'birthday': (tr('Chúc mừng sinh nhật'), 'ringtones/ring_happy_birthday.mp3'),
      'jingle': (tr('Giáng sinh'), 'ringtones/ring_jingle_bells.mp3'),
      'digital': (tr('Báo động'), 'ringtones/ring_digital.mp3'),
    };

/// Hình ảnh: mã → (tên, các biểu tượng rơi trên màn hình).
Map<String, (String, List<String>)> get fxVisuals => {
      'fireworks': (tr('Pháo hoa'), ['🎆', '🎇', '✨']),
      'hearts': (tr('Trái tim'), ['❤️', '💖', '💕']),
      'balloons': (tr('Bóng bay'), ['🎈', '🎈', '🎉']),
      'confetti': (tr('Hoa giấy'), ['🎊', '🎉', '✨']),
      'money': (tr('Tiền về'), ['💰', '💵', '🪙']),
    };

/// Màu nền tin nhắn: mã → (tên, 2 màu gradient). Vẽ phủ mờ lên màu bong bóng nên chữ vẫn đọc được ở cả nền sáng / tối.
Map<String, (String, List<Color>)> get fxBackgrounds => {
      'sunset': (tr('Hoàng hôn'), const [Color(0xFFFF7E5F), Color(0xFFFEB47B)]),
      'ocean': (tr('Đại dương'), const [Color(0xFF2193B0), Color(0xFF6DD5ED)]),
      'mint': (tr('Bạc hà'), const [Color(0xFF11998E), Color(0xFF38EF7D)]),
      'lavender': (tr('Oải hương'), const [Color(0xFF8E2DE2), Color(0xFFC471F5)]),
      'peach': (tr('Đào'), const [Color(0xFFFFB199), Color(0xFFFF0844)]),
      'sky': (tr('Bầu trời'), const [Color(0xFF56CCF2), Color(0xFF2F80ED)]),
      'gold': (tr('Vàng'), const [Color(0xFFF7971E), Color(0xFFFFD200)]),
      'rose': (tr('Hoa hồng'), const [Color(0xFFEE9CA7), Color(0xFFFFDDE1)]),
      'forest': (tr('Rừng xanh'), const [Color(0xFF5A3F37), Color(0xFF2C7744)]),
      'aurora': (tr('Cực quang'), const [Color(0xFF00C9FF), Color(0xFF92FE9D)]),
    };

/// Nền gradient của bong bóng tin theo mã (null nếu không có): gradient phủ mờ trên [base].
Gradient? fxBubbleGradient(String? id, Color base) {
  final g = fxBackgrounds[id];
  if (g == null) return null;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [for (final c in g.$2) Color.alphaBlend(c.withValues(alpha: .45), base)],
  );
}

/// Cấu hình hiệu ứng đang chọn cho tin sắp gửi.
class MsgFx {
  String? visual, alert, bg; // alert: 'important' | 'urgent'; bg: mã nền (fxBackgrounds)
  bool silent = false; // gửi im lặng: props.flygo_silent (trạm đẩy và app máy tính không báo)
  DateTime? sendAt; // hẹn giờ gửi (nút "Hẹn giờ" riêng)
  bool burn = false;
  /// Chưa chọn hiệu ứng nào (không tính hẹn giờ).
  bool get isEmpty => visual == null && alert == null && bg == null && !burn;
  Map<String, dynamic>? get props => visual == null && bg == null ? null : {'flygo_fx': {'visual': ?visual, 'bg': ?bg}};
  void clear() {
    visual = alert = bg = null;
    sendAt = null;
    silent = false;
    burn = false;
  }

  /// Các biểu tượng đại diện cho cấu hình (hiện trên nút "Hiệu ứng").
  List<IconData> get icons => [
        if (visual != null) Icons.auto_awesome_rounded,
        if (alert == 'important') Icons.priority_high_rounded,
        if (alert == 'urgent') Icons.campaign_rounded,
        if (burn) Icons.local_fire_department_rounded,
        if (bg != null) Icons.palette_outlined,
      ];
}

/// Bảng chọn hiệu ứng. Sửa trực tiếp [fx]; trả về true nếu người dùng bấm Xong.
Future<bool> showEffectsSheet(BuildContext context, MsgFx fx, {bool allowBurn = true}) async {
  final draft = MsgFx()
    ..visual = fx.visual
    ..alert = fx.alert
    ..bg = fx.bg
    ..silent = fx.silent
    ..burn = fx.burn;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final pal = Pal.of(ctx);
      Widget head(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: .5, fontWeight: FontWeight.w700, color: pal.sub)),
          );
      Widget chip(String label, bool on, VoidCallback tap, {Color? color}) => Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: on,
              showCheckmark: false,
              onSelected: (_) => set(tap),
              selectedColor: (color ?? pal.accent).withValues(alpha: .2),
              labelStyle: TextStyle(color: on ? (color ?? pal.accentText) : pal.text, fontWeight: on ? FontWeight.w600 : FontWeight.normal),
            ),
          );
      Widget wrap(List<Widget> c) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Wrap(children: c));
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .85),
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(tr('Hiệu ứng'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
          ),
          // Một mục "Hiệu ứng": cảnh báo (quan trọng / khẩn cấp) và hình ảnh; bấm lại để bỏ chọn.
          head('✨ ${tr('Hiệu ứng')}'),
          wrap([
            chip(tr('❗ Quan trọng'), draft.alert == 'important', () => draft.alert = draft.alert == 'important' ? null : 'important',
                color: const Color(0xFFF5A623)),
            chip(tr('🚨 Khẩn cấp'), draft.alert == 'urgent', () => draft.alert = draft.alert == 'urgent' ? null : 'urgent',
                color: Colors.redAccent),
            for (final e in fxVisuals.entries)
              chip('${e.value.$2.first} ${e.value.$1}', draft.visual == e.key, () {
                draft.visual = draft.visual == e.key ? null : e.key;
                if (draft.visual != null) playVisual(ctx, e.key);
              }),
          ]),
          if (draft.alert != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(draft.alert == 'urgent' ? tr('Hiện toàn màn hình ở máy người nhận, kêu chuông tới khi bấm "Đã nhận".') : tr('Người nhận phải bấm xác nhận đã đọc.'), style: TextStyle(fontSize: 13, color: pal.sub)),
            ),
          head('🔕 ${tr('Gửi im lặng')}'),
          SwitchListTile(
            value: draft.silent,
            onChanged: (v) => set(() => draft.silent = v),
            title: Text(tr('Gửi im lặng'), style: TextStyle(color: pal.text)),
            subtitle: Text(tr('Người nhận vẫn thấy tin nhưng không có thông báo, không đổ chuông.'), style: TextStyle(color: pal.sub, fontSize: 13)),
          ),
          if (allowBurn) ...[
            head('🔥 ${tr('Tự hủy')}'),
            SwitchListTile(
              value: draft.burn,
              onChanged: (v) => set(() => draft.burn = v),
              title: Text(tr('Tự hủy sau khi đọc'), style: TextStyle(color: pal.text)),
              subtitle: Text(tr('Người nhận phải bấm để xem, tin tự xóa sau 10 phút'), style: TextStyle(color: pal.sub, fontSize: 13)),
            ),
          ],
          head('🎨 ${tr('Màu nền tin nhắn')}'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              _BgSwatch(pal: pal, colors: null, label: tr('Không'), on: draft.bg == null, onTap: () => set(() => draft.bg = null)),
              for (final e in fxBackgrounds.entries)
                _BgSwatch(pal: pal, colors: e.value.$2, label: e.value.$1, on: draft.bg == e.key, onTap: () => set(() => draft.bg = e.key)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(children: [
              TextButton(onPressed: () => set(draft.clear), child: Text(tr('Bỏ hết'))),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Xong'))),
            ]),
          ),
        ]),
      );
    }),
  );
  if (ok == true) {
    fx
      ..visual = draft.visual
      ..alert = draft.alert
      ..bg = draft.bg
      ..silent = draft.silent
      ..burn = draft.burn;
    return true;
  }
  return false;
}

/// Ô mẫu màu nền (gradient) trong bảng hiệu ứng.
class _BgSwatch extends StatelessWidget {
  final Pal pal;
  final List<Color>? colors;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _BgSwatch({required this.pal, required this.colors, required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors == null ? pal.surface2 : null,
              gradient: colors == null ? null : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors!),
              border: Border.all(color: on ? pal.accent : pal.divider, width: on ? 3 : 1),
            ),
            child: colors == null ? Icon(Icons.block, size: 18, color: pal.sub) : null,
          ),
        ),
      );
}

/// Nút "Hẹn giờ": chọn lúc gửi tin. Trả về true nếu đã chọn (hoặc bỏ hẹn giờ).
Future<bool> showScheduleSheet(BuildContext context, MsgFx fx) async {
  final now = DateTime.now();
  DateTime? at = fx.sendAt;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final pal = Pal.of(ctx);
      Widget chip(String label, bool on, VoidCallback tap) => ChoiceChip(
            label: Text(label),
            selected: on,
            showCheckmark: false,
            onSelected: (_) => set(tap),
            selectedColor: pal.accent.withValues(alpha: .2),
            labelStyle: TextStyle(color: on ? pal.accentText : pal.text, fontWeight: on ? FontWeight.w600 : FontWeight.normal),
          );
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Hẹn giờ gửi'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: pal.text)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            chip(tr('Gửi ngay'), at == null, () => at = null),
            for (final m in const [5, 30, 60])
              chip(m < 60 ? tr('Sau {0} phút', [m]) : tr('Sau 1 giờ'), at != null && _sameMinute(at!, now.add(Duration(minutes: m))),
                  () => at = now.add(Duration(minutes: m))),
            ActionChip(
              avatar: const Icon(Icons.event, size: 16),
              label: Text(at == null ? tr('Chọn giờ…') : _fmt(at!)),
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
                if (d == null || !ctx.mounted) return;
                final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
                if (t == null) return;
                final v = DateTime(d.year, d.month, d.day, t.hour, t.minute);
                if (v.isAfter(DateTime.now())) set(() => at = v);
              },
            ),
          ]),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Xong')))),
        ]),
      );
    }),
  );
  if (ok == true) fx.sendAt = at;
  return ok == true;
}

bool _sameMinute(DateTime a, DateTime b) => (a.difference(b).inSeconds).abs() < 90;
String _fmt(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${d.day}/${d.month}';

// ---------------------------------------------------------------- phát hiệu ứng
AudioPlayer? _fxPlayer;
Timer? _fxStop;

/// Phát âm thanh hiệu ứng khoảng 4 giây.
Future<void> previewSound(String id) async {
  final a = fxSounds[id];
  if (a == null) return;
  try {
    _fxStop?.cancel();
    await _fxPlayer?.stop();
    final p = _fxPlayer ??= AudioPlayer();
    await p.play(AssetSource(a.$2));
    _fxStop = Timer(const Duration(seconds: 4), () => p.stop());
  } catch (_) {}
}

/// Các biểu tượng rơi từ trên xuống phủ màn hình trong ~3 giây.
void playVisual(BuildContext context, String id) {
  final v = fxVisuals[id];
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (v == null || overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => IgnorePointer(child: _Rain(emojis: v.$2, onDone: () => entry.remove())));
  overlay.insert(entry);
}

/// Đã phát hiệu ứng của tin nào (mỗi tin chỉ phát một lần mỗi lần chạy app).
final playedFx = <String>{};

/// Chỉ phát cho tin mới (gửi sau lúc mở app trừ 1 phút): mở lại chat cũ không phát lại.
final int fxSince = DateTime.now().millisecondsSinceEpoch - 60000;

/// Phát hiệu ứng của một tin (props.flygo_fx) nếu chưa phát.
void playPostFx(BuildContext context, String postId, Map<String, dynamic>? fx) {
  if (fx == null || !playedFx.add(postId)) return;
  final s = fx['sound'] as String?, v = fx['visual'] as String?;
  if (s != null) previewSound(s);
  if (v != null) playVisual(context, v);
}

class _Rain extends StatefulWidget {
  final List<String> emojis;
  final VoidCallback onDone;
  const _Rain({required this.emojis, required this.onDone});
  @override
  State<_Rain> createState() => _RainState();
}

class _RainState extends State<_Rain> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
    ..forward().whenComplete(widget.onDone);
  final _rnd = Random();
  late final List<(double x, double delay, double size, double drift, String e)> _p = [
    for (var i = 0; i < 36; i++)
      (_rnd.nextDouble(), _rnd.nextDouble() * .45, 22 + _rnd.nextDouble() * 20, (_rnd.nextDouble() - .5) * .2,
          widget.emojis[_rnd.nextInt(widget.emojis.length)]),
  ];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final size = MediaQuery.sizeOf(context);
          return Stack(children: [
            for (final (x, delay, s, drift, e) in _p)
              if (_c.value > delay)
                Positioned(
                  left: (x + drift * (_c.value - delay)) * size.width,
                  top: -40 + ((_c.value - delay) / (1 - delay)) * (size.height + 80),
                  child: Opacity(
                    opacity: (1 - _c.value).clamp(0, 1) * .9 + .1,
                    child: Text(e, style: TextStyle(fontSize: s, decoration: TextDecoration.none)),
                  ),
                ),
          ]);
        },
      );
}
