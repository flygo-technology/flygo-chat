import '../i18n/i18n.dart';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Nhạc chuông cuộc gọi đến theo từng nhóm. Tệp nhạc nằm trong app:
/// `assets/ringtones/{id}.mp3` (máy tính, trong app), `res/raw/{id}.mp3` (Android), `Runner/{id}.caf` (iPhone).
/// Lựa chọn lưu trên máy chủ (preferences flygo_chat/ringtones) và chép ra máy (ringtones.json, iPhone thêm UserDefaults)
/// để màn hình cuộc gọi đến của hệ điều hành đọc được cả khi app đang tắt.
class Ringtones {
  static const ids = [
    'ring_classic', 'ring_digital', 'ring_soft', 'ring_bell', 'ring_pulse', 'ring_chime',
    // Giai điệu cổ điển / dân gian đã hết bản quyền, tự tổng hợp lại.
    'ring_fur_elise',
    'ring_ode_to_joy',
    'ring_canon',
    'ring_turkish_march',
    'ring_nachtmusik',
    'ring_swan_lake',
    'ring_habanera',
    'ring_morning',
    'ring_mountain_king',
    'ring_blue_danube',
    'ring_william_tell',
    'ring_jingle_bells',
    'ring_happy_birthday',
    'ring_twinkle',
    'ring_buom_vang',
    'ring_lullaby',
    'ring_greensleeves',
    'ring_minuet',
    'ring_cancan',
    'ring_spring',
  ];

  static String label(String? id) => switch (id) {
        'ring_classic' => tr('Cổ điển'),
        'ring_digital' => tr('Điện tử'),
        'ring_soft' => tr('Nhẹ nhàng'),
        'ring_bell' => tr('Chuông ngân'),
        'ring_pulse' => tr('Nhịp đập'),
        'ring_chime' => tr('Ding dong'),
        'ring_fur_elise' => tr('Für Elise'),
        'ring_ode_to_joy' => tr('Khúc hoan ca'),
        'ring_canon' => tr('Canon'),
        'ring_turkish_march' => tr('Hành khúc Thổ Nhĩ Kỳ'),
        'ring_nachtmusik' => tr('Tiểu dạ khúc'),
        'ring_swan_lake' => tr('Hồ thiên nga'),
        'ring_habanera' => tr('Habanera'),
        'ring_morning' => tr('Bình minh'),
        'ring_mountain_king' => tr('Cung điện vua núi'),
        'ring_blue_danube' => tr('Dòng Danube xanh'),
        'ring_william_tell' => tr('William Tell'),
        'ring_jingle_bells' => tr('Jingle Bells'),
        'ring_happy_birthday' => tr('Chúc mừng sinh nhật'),
        'ring_twinkle' => tr('Ngôi sao nhỏ'),
        'ring_buom_vang' => tr('Kìa con bướm vàng'),
        'ring_lullaby' => tr('Hát ru (Brahms)'),
        'ring_greensleeves' => tr('Greensleeves'),
        'ring_minuet' => tr('Minuet in G'),
        'ring_cancan' => tr('Can-can'),
        'ring_spring' => tr('Mùa xuân (Vivaldi)'),

        _ => tr('Mặc định'),
      };

  /// id kênh → id nhạc chuông (mọi máy chủ đã đăng nhập trên máy này).
  static final Map<String, String> map = {};
  static bool _loaded = false;

  static String? of(String channelId) => map[channelId];

  static Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/ringtones.json');

  static Future<void> loadLocal() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (await f.exists()) map.addAll((jsonDecode(await f.readAsString()) as Map).cast<String, String>());
    } catch (_) {}
    _loaded = true;
  }

  /// Gộp lựa chọn của một máy chủ ([channelIds] là các kênh của máy chủ đó) rồi lưu ra máy.
  static Future<void> merge(Map<String, String> server, Iterable<String> channelIds) async {
    await loadLocal();
    for (final id in channelIds) {
      map.remove(id);
    }
    map.addAll(server);
    await _save();
  }

  static Future<void> set(String channelId, String? id) async {
    await loadLocal();
    id == null ? map.remove(channelId) : map[channelId] = id;
    await _save();
  }

  static Future<void> _save() async {
    try {
      await (await _file()).writeAsString(jsonEncode(map));
      if (!kIsWeb && Platform.isIOS) await const MethodChannel('flygo/push').invokeMethod('setRingtones', map);
    } catch (e) {
      debugPrint('[ringtones] save: $e');
    }
  }

  // ---------------------------------------------------------------- phát nhạc trong app
  static AudioPlayer? _player;

  /// Đổ chuông trong app (lặp lại tới khi [stop]).
  static Future<void> ring(String channelId) async {
    await stop();
    final p = _player = AudioPlayer();
    try {
      await p.setReleaseMode(ReleaseMode.loop);
      await p.play(AssetSource('ringtones/${of(channelId) ?? 'ring_classic'}.mp3'));
    } catch (e) {
      debugPrint('[ringtones] ring: $e');
    }
  }

  /// Nghe thử một nhạc chuông.
  static Future<void> preview(String id) async {
    await stop();
    final p = _player = AudioPlayer();
    try {
      await p.play(AssetSource('ringtones/$id.mp3'));
    } catch (_) {}
  }

  static Future<void> stop() async {
    final p = _player;
    _player = null;
    if (p == null) return;
    try {
      await p.stop();
      await p.dispose();
    } catch (_) {}
  }
}
