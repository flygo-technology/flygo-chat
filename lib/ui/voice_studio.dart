import '../i18n/i18n.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../api/stt.dart';
import '../state/app_state.dart';
import 'attach_panel.dart';
import 'theme.dart';

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

  String get _transcript => [_committed, _partial].where((s) => s.trim().isNotEmpty).join(' ').trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startRec());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
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
      final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
      HapticFeedback.mediumImpact();
      _start = DateTime.now();
      _sub = stream.listen(_onChunk);
      _tick = Timer.periodic(const Duration(milliseconds: 250), (t) {
        if (!mounted) return;
        setState(() => _len = DateTime.now().difference(_start!));
        // Mỗi ~3 giây nhận diện lại đoạn đang nói.
        if (t.tick % 12 == 0) _transcribe();
      });
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = tr('Không ghi âm được: {0}', ['$e']));
    }
  }

  void _onChunk(Uint8List b) {
    _audio.add(b);
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
    await _rec.stop();
    await _sub?.cancel();
    if (mounted) setState(() => _recording = false);
  }

  /// Dừng ghi và chờ nhận diện xong phần còn lại.
  Future<void> _finishTranscript() async {
    await _stop();
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
                            if (busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent)),
                          ]),
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
                btn(Icons.edit_note_rounded, tr('Sửa phiên âm'), _editing || _audio.isEmpty ? null : _edit),
                btn(Icons.text_fields_rounded, tr('Gửi phiên âm'), _audio.isEmpty && !_editing ? null : _sendText),
                btn(Icons.send_rounded, tr('Gửi ghi âm'), _audio.isEmpty || _editing ? null : _sendAudio, filled: true),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
