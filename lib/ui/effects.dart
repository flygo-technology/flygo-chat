import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

// Hiệu ứng tin nhắn (nút "Hiệu ứng" cạnh "Luồng riêng" / "Bí mật"):
// - Âm thanh, hình ảnh: gửi kèm props.flygo_fx = {sound, visual}; người nhận mở chat thấy tin thì phát một lần.
// - Cảnh báo: tin quan trọng / khẩn cấp (bắt xác nhận đã đọc) — dùng metadata priority sẵn có của Mattermost.
// - Đếm ngược: hẹn giờ gửi (tin gửi đi khi hết giờ).
// - Tự hủy: người nhận bấm để xem, tin tự xoá sau 10 phút.

/// Âm thanh: mã → (tên, tệp trong assets/ringtones).
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

/// Cấu hình hiệu ứng đang chọn cho tin sắp gửi.
class MsgFx {
  String? sound, visual, alert; // alert: 'important' | 'urgent'
  DateTime? sendAt;
  bool burn = false;
  bool get isEmpty => sound == null && visual == null && alert == null && sendAt == null && !burn;
  Map<String, dynamic>? get props => sound == null && visual == null ? null : {'flygo_fx': {'sound': ?sound, 'visual': ?visual}};
  void clear() {
    sound = visual = alert = null;
    sendAt = null;
    burn = false;
  }

  /// Các biểu tượng đại diện cho cấu hình (hiện trên nút "Hiệu ứng").
  List<IconData> get icons => [
        if (sound != null) Icons.music_note_rounded,
        if (visual != null) Icons.auto_awesome_rounded,
        if (alert == 'important') Icons.priority_high_rounded,
        if (alert == 'urgent') Icons.campaign_rounded,
        if (sendAt != null) Icons.timer_outlined,
        if (burn) Icons.local_fire_department_rounded,
      ];
}

/// Bảng chọn hiệu ứng. Sửa trực tiếp [fx]; trả về true nếu người dùng bấm Xong.
Future<bool> showEffectsSheet(BuildContext context, MsgFx fx, {bool allowBurn = true}) async {
  final draft = MsgFx()
    ..sound = fx.sound
    ..visual = fx.visual
    ..alert = fx.alert
    ..sendAt = fx.sendAt
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
          head('🎵 ${tr('Âm thanh')}'),
          wrap([
            chip(tr('Không'), draft.sound == null, () => draft.sound = null),
            for (final e in fxSounds.entries)
              chip(e.value.$1, draft.sound == e.key, () {
                draft.sound = e.key;
                previewSound(e.key);
              }),
          ]),
          head('✨ ${tr('Hình ảnh')}'),
          wrap([
            chip(tr('Không'), draft.visual == null, () => draft.visual = null),
            for (final e in fxVisuals.entries)
              chip('${e.value.$2.first} ${e.value.$1}', draft.visual == e.key, () {
                draft.visual = e.key;
                playVisual(ctx, e.key);
              }),
          ]),
          head('⚠️ ${tr('Cảnh báo')}'),
          wrap([
            chip(tr('Không'), draft.alert == null, () => draft.alert = null),
            chip(tr('❗ Quan trọng'), draft.alert == 'important', () => draft.alert = 'important', color: const Color(0xFFF5A623)),
            chip(tr('🚨 Khẩn cấp'), draft.alert == 'urgent', () => draft.alert = 'urgent', color: Colors.redAccent),
          ]),
          if (draft.alert != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(tr('Người nhận phải bấm xác nhận đã đọc.'), style: TextStyle(fontSize: 13, color: pal.sub)),
            ),
          head('⏱ ${tr('Đếm ngược (hẹn giờ gửi)')}'),
          wrap([
            chip(tr('Gửi ngay'), draft.sendAt == null, () => draft.sendAt = null),
            for (final m in const [5, 30, 60])
              chip(m < 60 ? tr('Sau {0} phút', [m]) : tr('Sau 1 giờ'),
                  draft.sendAt != null && _sameMinute(draft.sendAt!, DateTime.now().add(Duration(minutes: m))),
                  () => draft.sendAt = DateTime.now().add(Duration(minutes: m))),
            ActionChip(
              avatar: const Icon(Icons.event, size: 16),
              label: Text(draft.sendAt == null ? tr('Chọn giờ…') : _fmt(draft.sendAt!)),
              onPressed: () async {
                final now = DateTime.now();
                final d = await showDatePicker(context: ctx, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
                if (d == null || !ctx.mounted) return;
                final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
                if (t == null) return;
                final at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
                if (at.isAfter(DateTime.now())) set(() => draft.sendAt = at);
              },
            ),
          ]),
          if (allowBurn) ...[
            head('🔥 ${tr('Tự hủy')}'),
            SwitchListTile(
              value: draft.burn,
              onChanged: (v) => set(() => draft.burn = v),
              title: Text(tr('Tự hủy sau khi đọc'), style: TextStyle(color: pal.text)),
              subtitle: Text(tr('Người nhận phải bấm để xem, tin tự xóa sau 10 phút'), style: TextStyle(color: pal.sub, fontSize: 13)),
            ),
          ],
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
      ..sound = draft.sound
      ..visual = draft.visual
      ..alert = draft.alert
      ..sendAt = draft.sendAt
      ..burn = draft.burn;
    return true;
  }
  return false;
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
