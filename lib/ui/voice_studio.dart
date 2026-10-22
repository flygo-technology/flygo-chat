import '../i18n/i18n.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api/stt.dart';
import '../speech/offline_stt.dart';
import '../state/app_state.dart';
import 'attach_panel.dart';
import 'theme.dart';

// Phiên âm ưu tiên bộ nhận dạng giọng nói của máy (offline, chữ hiện ngay khi nói — Google trên Android, Apple trên
// iPhone / Mac, như app Nhà Minh); máy không có tiếng Việt thì gửi máy chủ Whisper như dưới đây.
// Bấm nút ghi âm: màn hình toàn màn hình — hiệu ứng sóng âm ở trên, phiên âm (máy chủ Whisper) chạy dần ở dưới,
// cuối màn hình 4 nút: Gửi ghi âm, Gửi phiên âm, Sửa phiên âm, Hủy.
// Ghi dạng PCM 16 kHz (luồng): cứ vài giây gửi đoạn đang nói (tối đa ~25 giây) để nhận diện, đoạn đủ dài thì chốt
// rồi sang đoạn mới — chữ hiện gần như trực tiếp. Gửi ghi âm = file WAV của cả bài.

const _rate = 16000;
const _bytesPerSec = _rate * 2;

/// Mở màn hình ghi âm. Trả về VoiceResult: path (gửi ghi âm) hoặc text + send (gửi phiên âm).
Future<VoiceResult?> showVoiceStudio(BuildContext context, AppState app) =>
    Navigator.of(context).push<VoiceResult>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _VoiceStudio(app: app)));

class _VoiceStudio extends StatefulWidget {
  final AppState app;
  const _VoiceStudio({required this.app});
  @override
  State<_VoiceStudio> createState() => _VoiceStudioState();
}

class _VoiceStudioState extends State<_VoiceStudio> {
  final _rec = AudioRecorder();
  final _audio = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  Timer? _tick;
  bool _recording = false, _editing = false;
  DateTime? _start;
  Duration _len = Duration.zero;
  final _levels = List<double>.filled(48, 0, growable: true);
  String? _error;

  // Phiên âm: các đoạn đã chốt + đoạn đang nghe.
  String _committed = '', _partial = '';
  int _segStart = 0; // byte bắt đầu đoạn đang nghe
  int _lastSent = 0; // số byte lúc gửi nhận diện gần nhất
  Future<void>? _job;
  final _textCtl = TextEditingController();

  /// Đang phiên âm bằng bộ nhận dạng của máy (không gửi máy chủ).
  bool _device = false;
  /// Bộ nhận dạng của máy giữ micro: không ghi được file song song (nút "Gửi ghi âm" tắt).
  bool _audioOff = false;
  SpeechToText get _stt => DeviceSpeech.stt;
  /// Nhận dạng tiếng Việt trên máy (mô hình của Flygo, đã tải): nghe chính luồng ghi âm, không cần mạng.
  OfflineSession? _off;

  String get _transcript => [_committed, _partial].where((s) => s.trim().isNotEmpty).join(' ').trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startRec());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _again?.cancel();
    if (_device) {
      _stt.statusListener = null;
      _stt.errorListener = null;
      _stt.cancel();
    }
    _sub?.cancel();
    _off?.cancel();
    _rec.dispose();
    _textCtl.dispose();
    super.dispose();
  }

  Future<void> _startRec() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = tr('Cần cho phép dùng micro để ghi âm.'));
        return;
      }
      if (await OfflineStt.isReady()) {
        try {
          _off = await OfflineStt.open(
            onPartial: (t) {
              if (mounted) setState(() => _partial = t);
            },
            onFinal: (t) {
              if (!mounted) return;
              setState(() {
                _committed = [_committed, t].where((x) => x.trim().isNotEmpty).join(' ');
                _partial = '';
              });
            },
          );
        } catch (e) {
          debugPrint('[stt] offline: $e');
        }
      }
      _device = _off == null && await DeviceSpeech.available();
      HapticFeedback.mediumImpact();
      _start = DateTime.now();
      _tick = Timer.periodic(const Duration(milliseconds: 250), (t) {
        if (!mounted) return;
        setState(() => _len = DateTime.now().difference(_start!));
        // Không có bộ nhận dạng trên máy: mỗi ~3 giây gửi máy chủ nhận diện lại đoạn đang nói.
        if (!_device && _off == null && t.tick % 12 == 0) _transcribe();
      });
      setState(() => _recording = true);
      if (_device) await _deviceListen();
      // Ghi file song song (để "Gửi ghi âm"); máy không cho dùng micro cùng lúc thì bỏ qua.
      try {
        final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
        _sub = stream.listen(_onChunk);
      } catch (e) {
        if (!_device) rethrow;
        _audioOff = true;
      }
    } catch (e) {
      setState(() => _error = tr('Không ghi âm được: {0}', ['$e']));
    }
  }

  /// Nghe bằng bộ nhận dạng của máy; hết một lượt (ngừng nói) thì nghe tiếp, chữ cộng dồn.
  Future<void> _deviceListen() async {
    if (!_recording || _stt.isListening) return;
    _stt.statusListener = (st) {
      if (_recording && (st == 'done' || st == 'notListening')) _deviceAgain();
    };
    _stt.errorListener = (e) {
      if (!_recording) return;
      // Ghi file song song giành mất micro: bỏ ghi file, giữ phiên âm.
      if (e.errorMsg.contains('audio') && !_audioOff) {
        _audioOff = true;
        _sub?.cancel();
        _rec.stop().catchError((_) => null);
      }
      _deviceAgain();
    };
    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          localeId: DeviceSpeech.locale,
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 6),
          partialResults: true,
          onDevice: true,
          listenMode: ListenMode.dictation,
          cancelOnError: false,
          autoPunctuation: true,
        ),
        onSoundLevelChange: (l) {
          if (!mounted || !_audioOff) return;
          // Không có luồng âm thanh riêng: sóng âm theo mức âm của bộ nhận dạng.
          setState(() {
            _levels
              ..removeAt(0)
              ..add(((l + 2) / 12).clamp(0.0, 1.0));
          });
        },
        onResult: (r) {
          if (!mounted) return;
          setState(() {
            _partial = r.recognizedWords;
            if (r.finalResult) {
              _committed = [_committed, _partial].where((x) => x.trim().isNotEmpty).join(' ');
              _partial = '';
            }
          });
        },
      );
    } catch (_) {
      // Không nghe được trên máy: chuyển sang máy chủ Whisper.
      _device = false;
    }
  }

  Timer? _again;
  void _deviceAgain() {
    if (!_recording) return;
    if (_partial.trim().isNotEmpty) {
      _committed = [_committed, _partial].where((x) => x.trim().isNotEmpty).join(' ');
      _partial = '';
    }
    _again?.cancel();
    _again = Timer(const Duration(milliseconds: 250), () => _deviceListen().catchError((_) {}));
  }

  void _onChunk(Uint8List b) {
    _audio.add(b);
    _off?.feed(b);
    // Mức âm lượng (RMS) cho hiệu ứng sóng.
    final d = ByteData.sublistView(b);
    var sum = 0.0;
    final n = b.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final v = d.getInt16(i * 2, Endian.little) / 32768;
      sum += v * v;
    }
    final rms = n == 0 ? 0.0 : sqrt(sum / n);
    final level = (rms * 6).clamp(0.0, 1.0);
    if (mounted) {
      setState(() {
        _levels
          ..removeAt(0)
          ..add(level);
      });
    }
  }

  /// Nhận diện đoạn đang nói (chạy một yêu cầu một lúc). [last] = lần cuối sau khi dừng ghi.
  void _transcribe({bool last = false}) {
    if (_job != null) return;
    final end = _audio.length;
    if (end - _segStart < _bytesPerSec ~/ 2 || (!last && end - _lastSent < _bytesPerSec)) return;
    _lastSent = end;
    final seg = Uint8List.sublistView(_audio.toBytes(), _segStart, end);
    final commit = last || end - _segStart >= _bytesPerSec * 25;
    _job = () async {
      try {
        final f = await _wav(seg, 'stt');
        final text = await transcribeAudio(widget.app.api, f.path);
        f.delete().catchError((_) => f);
        if (!mounted) return;
        setState(() {
          if (commit) {
            _committed = [_committed, text].where((s) => s.trim().isNotEmpty).join(' ');
            _partial = '';
            _segStart = end;
          } else {
            _partial = text;
          }
          _error = null;
        });
      } catch (_) {
        if (mounted) setState(() => _error = tr('Không chuyển được thành chữ. Kiểm tra kết nối mạng.'));
      } finally {
        _job = null;
      }
    }();
  }

  Future<File> _wav(Uint8List pcm, String name) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name-${DateTime.now().millisecondsSinceEpoch}.wav');
    final h = ByteData(44);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        h.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, _rate, Endian.little);
    h.setUint32(28, _bytesPerSec, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    str(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    await f.writeAsBytes([...h.buffer.asUint8List(), ...pcm], flush: true);
    return f;
  }

  Future<void> _stop() async {
    if (!_recording) return;
    _tick?.cancel();
    _again?.cancel();
    if (mounted) setState(() => _recording = false);
    if (_device) {
      _stt.statusListener = null;
      _stt.errorListener = null;
      try {
        await _stt.stop();
      } catch (_) {}
      // Chờ kết quả cuối của lượt đang nghe.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_partial.trim().isNotEmpty) {
        _committed = [_committed, _partial].where((x) => x.trim().isNotEmpty).join(' ');
        _partial = '';
      }
    }
    try {
      await _rec.stop();
    } catch (_) {}
    await _sub?.cancel();
    // Nhận dạng trên máy: chốt câu đang nói.
    final off = _off;
    _off = null;
    if (off != null) {
      await off.finish();
      _offDone = true;
    }
    if (mounted) setState(() {});
  }

  /// Phiên âm đã do bộ nhận dạng trên máy làm xong (không gửi máy chủ nữa).
  bool _offDone = false;

  /// Dừng ghi và chờ nhận diện xong phần còn lại.
  Future<void> _finishTranscript() async {
    await _stop();
    if (_device || _offDone) return;
    await _job;
    _transcribe(last: true);
    if (_job != null) setState(() {});
    await _job;
  }

  Future<void> _sendAudio() async {
    await _stop();
    if (_audio.isEmpty) return;
    final f = await _wav(_audio.toBytes(), 'ghi-am');
    if (mounted) Navigator.pop(context, VoiceResult(path: f.path));
  }

  Future<void> _sendText() async {
    if (!_editing) await _finishTranscript();
    final t = (_editing ? _textCtl.text : _transcript).trim();
    if (!mounted) return;
    if (t.isEmpty) {
      setState(() => _error = tr('Chưa có phiên âm để gửi.'));
      return;
    }
    Navigator.pop(context, VoiceResult(text: t, send: true));
  }

  Future<void> _edit() async {
    await _finishTranscript();
    if (!mounted) return;
    _textCtl.text = _transcript;
    setState(() => _editing = true);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final mm = _len.inMinutes.toString().padLeft(2, '0');
    final ss = (_len.inSeconds % 60).toString().padLeft(2, '0');
    final busy = _job != null;
    Widget btn(IconData icon, String label, VoidCallback? onTap, {Color? color, bool filled = false}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Opacity(
                opacity: onTap == null ? .4 : 1,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? (color ?? pal.accent) : (color ?? pal.accent).withValues(alpha: .14),
                    ),
                    child: Icon(icon, color: filled ? Colors.white : (color ?? pal.accentText)),
                  ),
                  const SizedBox(height: 6),
                  Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: pal.text)),
                ]),
              ),
            ),
          ),
        );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) async {
        if (did) return;
        await _stop();
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: pal.bg,
        body: SafeArea(
          child: Column(children: [
            const SizedBox(height: 20),
            Text(_recording ? tr('Đang ghi âm') : (_editing ? tr('Sửa phiên âm') : tr('Đã dừng ghi')),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _recording ? Colors.redAccent : pal.sub)),
            const SizedBox(height: 6),
            Text('$mm:$ss', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w300, color: pal.text, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 16),
            // Sóng âm.
            SizedBox(
              height: 90,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final l in _levels)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    width: 4,
                    height: 6 + l * 84,
                    decoration: BoxDecoration(
                      color: (_recording ? Colors.redAccent : pal.sub).withValues(alpha: .35 + l * .65),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            if (_recording)
              TextButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
                label: Text(tr('Dừng ghi'), style: const TextStyle(color: Colors.redAccent)),
              ),
            // Phiên âm.
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
                child: _editing
                    ? TextField(
                        controller: _textCtl,
                        autofocus: true,
                        maxLines: null,
                        expands: true,
                        style: TextStyle(fontSize: 17, height: 1.45, color: pal.text),
                        decoration: const InputDecoration(border: InputBorder.none),
                      )
                    : SingleChildScrollView(
                        reverse: true,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Icon(Icons.subtitles_outlined, size: 18, color: pal.sub),
                            const SizedBox(width: 6),
                            Text(tr('Phiên âm'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.sub)),
                            const Spacer(),
                            if (_off != null || _offDone)
                              Text(tr('Trên máy · không cần mạng'), style: TextStyle(fontSize: 12, color: pal.sub)),
                            if (busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent)),
                          ]),
                          // Chưa có mô hình tiếng Việt trên máy: mời tải (một lần, ~78 MB) để lần sau phiên âm không cần mạng.
                          if (OfflineStt.supported && !OfflineStt.ready.value) _OfflineOffer(pal: pal),
                          const SizedBox(height: 10),
                          Text.rich(
                            TextSpan(children: [
                              TextSpan(text: _committed, style: TextStyle(color: pal.text)),
                              if (_partial.isNotEmpty) TextSpan(text: '${_committed.isEmpty ? '' : ' '}$_partial', style: TextStyle(color: pal.text.withValues(alpha: .7))),
                              if (_transcript.isEmpty)
                                TextSpan(text: _recording ? tr('Hãy nói, chữ sẽ hiện ở đây…') : tr('Chưa có phiên âm.'), style: TextStyle(color: pal.sub)),
                            ]),
                            style: const TextStyle(fontSize: 17, height: 1.45),
                          ),
                        ]),
                      ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                btn(Icons.close_rounded, tr('Hủy'), () async {
                  await _stop();
                  if (context.mounted) Navigator.pop(context);
                }, color: pal.sub),
                btn(Icons.edit_note_rounded, tr('Sửa phiên âm'), _editing || (_audio.isEmpty && _transcript.isEmpty && !_recording) ? null : _edit),
                btn(Icons.text_fields_rounded, tr('Gửi phiên âm'), _audio.isEmpty && _transcript.isEmpty && !_editing && !_recording ? null : _sendText),
                btn(Icons.send_rounded, tr('Gửi ghi âm'), _audio.isEmpty || _editing ? null : _sendAudio, filled: true),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}


/// Mời tải bộ nhận dạng tiếng Việt ngoại tuyến (hiện tiến độ khi đang tải).
class _OfflineOffer extends StatefulWidget {
  final Pal pal;
  const _OfflineOffer({required this.pal});
  @override
  State<_OfflineOffer> createState() => _OfflineOfferState();
}

class _OfflineOfferState extends State<_OfflineOffer> {
  String? _err;
  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return ValueListenableBuilder<double?>(
      valueListenable: OfflineStt.downloading,
      builder: (_, p, _) => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(color: pal.accent.withValues(alpha: .08), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(Icons.offline_bolt_outlined, size: 18, color: pal.accentText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                p != null
                    ? tr('Đang tải bộ nhận dạng tiếng Việt… {0}%', [(p * 100).round()])
                    : _err ?? tr('Phiên âm tiếng Việt không cần mạng: tải bộ nhận dạng (78 MB, một lần).'),
                style: TextStyle(fontSize: 12.5, color: _err != null ? Colors.redAccent : pal.text)),
          ),
          if (p == null)
            TextButton(
              onPressed: () async {
                setState(() => _err = null);
                final e = await OfflineStt.download();
                if (mounted) setState(() => _err = e == null ? null : tr('Tải không được: {0}', [e]));
              },
              child: Text(tr('Tải')),
            )
          else
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, value: p, color: pal.accent)),
        ]),
      ),
    );
  }
}
