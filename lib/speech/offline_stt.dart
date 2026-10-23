import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

// Nhận dạng giọng nói tiếng Việt ngay trên máy (không cần mạng): mô hình Zipformer tiếng Việt của sherpa-onnx (~78 MB,
// tải một lần từ máy chủ đang dùng) + Silero VAD cắt câu. Chạy trong một isolate riêng để giao diện không giật.
// Bộ nhận dạng của điện thoại (Google / Samsung) nhiều máy không có gói tiếng Việt ngoại tuyến nên không dùng được offline.

String get _base => '${staticBase('flygo-update')}/stt/vi-60m';
const sttRate = 16000;

class OfflineStt {
  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// Tiến độ tải mô hình (0..1); null = không tải.
  static final downloading = ValueNotifier<double?>(null);
  static final ready = ValueNotifier<bool>(false);
  static bool _checked = false;

  static Future<Directory> _dir() async => Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}stt-vi-60m');

  /// Đã có mô hình trên máy chưa (kiểm tra một lần, sau đó theo [ready]).
  static Future<bool> isReady() async {
    if (!supported) return false;
    if (_checked) return ready.value;
    _checked = true;
    final d = await _dir();
    ready.value = await File('${d.path}${Platform.pathSeparator}.ok').exists();
    return ready.value;
  }

  /// Tải mô hình (kiểm tra sha256 từng tệp). Trả lỗi dạng chữ, hoặc null khi xong.
  static Future<String?> download() async {
    if (downloading.value != null) return null;
    downloading.value = 0;
    final d = await _dir();
    await d.create(recursive: true);
    final client = http.Client();
    try {
      final man = jsonDecode((await client.get(Uri.parse('$_base/manifest.json'))).body) as Map;
      final files = [for (final f in man['files'] as List) (f as Map).cast<String, dynamic>()];
      final total = files.fold<int>(0, (a, f) => a + (f['size'] as int));
      var got = 0;
      for (final f in files) {
        final out = File('${d.path}${Platform.pathSeparator}${f['name']}');
        if (await out.exists() && await out.length() == f['size']) {
          got += f['size'] as int;
          continue;
        }
        final res = await client.send(http.Request('GET', Uri.parse('$_base/${f['name']}')));
        if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
        final tmp = File('${out.path}.part');
        final sink = tmp.openWrite();
        final hash = AccumulatorSink<Digest>();
        final h = sha256.startChunkedConversion(hash);
        await for (final c in res.stream) {
          sink.add(c);
          h.add(c);
          got += c.length;
          downloading.value = total == 0 ? null : got / total;
        }
        await sink.close();
        h.close();
        if (hash.events.single.toString() != f['sha256']) {
          await tmp.delete();
          throw 'sai mã kiểm tra ${f['name']}';
        }
        await tmp.rename(out.path);
      }
      await File('${d.path}${Platform.pathSeparator}.ok').writeAsString(man['id'] as String? ?? 'ok');
      ready.value = true;
      return null;
    } catch (e) {
      return '$e';
    } finally {
      client.close();
      downloading.value = null;
    }
  }

  static Isolate? _iso;
  static SendPort? _to;
  static final _events = StreamController<Map>.broadcast();
  static Completer<void>? _starting;

  /// Khởi động isolate nhận dạng (nạp mô hình một lần, giữ lại cho các lần sau).
  static Future<void> _ensure() async {
    if (_to != null) return;
    if (_starting != null) return _starting!.future;
    final c = _starting = Completer<void>();
    try {
      final from = ReceivePort();
      final d = await _dir();
      _iso = await Isolate.spawn(_worker, [from.sendPort, d.path]);
      from.listen((m) {
        if (m is SendPort) {
          _to = m;
        } else if (m is Map) {
          if (m['ready'] == true && !c.isCompleted) c.complete();
          if (m['error'] != null && !c.isCompleted) c.completeError(m['error']);
          _events.add(m);
        }
      });
      await c.future;
    } catch (e) {
      _iso?.kill();
      _iso = null;
      _to = null;
      rethrow;
    } finally {
      _starting = null;
    }
  }

  /// Bắt đầu một phiên: [feed] PCM16 mono 16 kHz, nhận [onPartial] (câu đang nói) và [onFinal] (câu đã chốt).
  static Future<OfflineSession> open({required void Function(String) onPartial, required void Function(String) onFinal}) async {
    await _ensure();
    _to!.send({'reset': true});
    return OfflineSession._(onPartial, onFinal);
  }
}

class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T e) => events.add(e);
  @override
  void close() {}
}

class OfflineSession {
  final void Function(String) onPartial, onFinal;
  late final StreamSubscription _sub;
  Completer<void>? _flushed;

  OfflineSession._(this.onPartial, this.onFinal) {
    _sub = OfflineStt._events.stream.listen((m) {
      if (m['partial'] is String) onPartial(m['partial'] as String);
      if (m['final'] is String) onFinal(m['final'] as String);
      if (m['flushed'] == true) _flushed?.complete();
    });
  }

  /// Thêm âm thanh PCM16 little-endian (mono 16 kHz).
  void feed(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return;
    final d = ByteData.sublistView(pcm);
    final f = Float32List(n);
    for (var i = 0; i < n; i++) {
      f[i] = d.getInt16(i * 2, Endian.little) / 32768;
    }
    OfflineStt._to?.send({'pcm': TransferableTypedData.fromList([f])});
  }

  /// Chốt đoạn đang nói (khi bấm dừng), chờ câu cuối về.
  Future<void> finish() async {
    _flushed = Completer<void>();
    OfflineStt._to?.send({'flush': true});
    await _flushed!.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    await _sub.cancel();
  }

  Future<void> cancel() async {
    OfflineStt._to?.send({'reset': true});
    await _sub.cancel();
  }
}

/// Đọc chính tả bằng micro + nhận dạng trên máy (dùng cho đọc chính tả ở ô nhắn tin và khung đọc chính tả).
class OfflineDictation {
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _mic;
  OfflineSession? _s;

  Future<void> start({required void Function(String) onPartial, required void Function(String) onFinal, void Function(double)? onLevel}) async {
    if (!await _rec.hasPermission()) throw 'mic';
    _s = await OfflineStt.open(onPartial: onPartial, onFinal: onFinal);
    final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: sttRate, numChannels: 1));
    _mic = stream.listen((b) {
      _s?.feed(b);
      if (onLevel != null) onLevel(_rms(b));
    });
  }

  Future<void> stop() async {
    await _mic?.cancel();
    await _rec.stop().catchError((_) => null);
    await _s?.finish();
    _s = null;
    await _rec.dispose();
  }

  Future<void> cancel() async {
    await _mic?.cancel();
    await _rec.stop().catchError((_) => null);
    await _s?.cancel();
    _s = null;
    await _rec.dispose();
  }

  static double _rms(Uint8List b) {
    final d = ByteData.sublistView(b);
    final n = b.length ~/ 2;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = d.getInt16(i * 2, Endian.little) / 32768;
      sum += v * v;
    }
    return n == 0 ? 0 : (sqrt(sum / n) * 6).clamp(0.0, 1.0);
  }
}

/// Chữ của mô hình viết hoa toàn bộ, không dấu câu: đưa về chữ thường, viết hoa đầu câu.
String _tidy(String t) {
  final s = t.trim().toLowerCase();
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

// ---------------------------------------------------------------- isolate nhận dạng
Future<void> _worker(List args) async {
  final back = args[0] as SendPort;
  final dir = args[1] as String;
  final inbox = ReceivePort();
  back.send(inbox.sendPort);
  late so.OfflineRecognizer rec;
  late so.VoiceActivityDetector vad;
  String p(String f) => '$dir${Platform.pathSeparator}$f';
  try {
    await so.initBindingsAsync();
    rec = so.OfflineRecognizer(so.OfflineRecognizerConfig(
      model: so.OfflineModelConfig(
        transducer: so.OfflineTransducerModelConfig(encoder: p('encoder.onnx'), decoder: p('decoder.onnx'), joiner: p('joiner.onnx')),
        tokens: p('tokens.txt'),
        numThreads: 2,
        debug: false,
      ),
    ));
    vad = so.VoiceActivityDetector(
      config: so.VadModelConfig(
        sileroVad: so.SileroVadModelConfig(model: p('vad.onnx'), minSilenceDuration: 0.6, minSpeechDuration: 0.2, maxSpeechDuration: 20),
        sampleRate: sttRate,
        debug: false,
      ),
      bufferSizeInSeconds: 60,
    );
    back.send({'ready': true});
  } catch (e) {
    back.send({'error': '$e'});
    return;
  }

  String decode(Float32List samples) {
    final s = rec.createStream();
    s.acceptWaveform(samples: samples, sampleRate: sttRate);
    rec.decode(s);
    final t = rec.getResult(s).text;
    s.free();
    return _tidy(t);
  }

  // Đoạn đang nói (để hiện chữ tạm) và phần âm thanh dư chưa đủ một cửa sổ VAD.
  var speech = <double>[];
  var pending = Float32List(0);
  var sinceDecode = 0;
  void drain() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      final t = decode(seg.samples);
      if (t.isNotEmpty) back.send({'final': t});
      speech = [];
      sinceDecode = 0;
      back.send({'partial': ''});
    }
  }

  inbox.listen((m) {
    if (m is! Map) return;
    if (m['reset'] == true) {
      vad.reset();
      speech = [];
      pending = Float32List(0);
      sinceDecode = 0;
      return;
    }
    if (m['pcm'] is TransferableTypedData) {
      final f = (m['pcm'] as TransferableTypedData).materialize().asFloat32List();
      final all = Float32List(pending.length + f.length)
        ..setAll(0, pending)
        ..setAll(pending.length, f);
      var i = 0;
      for (; i + 512 <= all.length; i += 512) {
        final w = Float32List.sublistView(all, i, i + 512);
        vad.acceptWaveform(w);
        if (vad.isDetected()) {
          speech.addAll(w);
          sinceDecode += 512;
        }
        drain();
      }
      pending = Float32List.fromList(Float32List.sublistView(all, i));
      // Chữ tạm của câu đang nói: nhận dạng lại mỗi ~0,8 giây âm thanh mới.
      if (speech.length > sttRate ~/ 2 && sinceDecode >= sttRate * 0.8) {
        sinceDecode = 0;
        final t = decode(Float32List.fromList(speech.length > sttRate * 20 ? speech.sublist(speech.length - sttRate * 20) : speech));
        back.send({'partial': t});
      }
      return;
    }
    if (m['flush'] == true) {
      vad.flush();
      drain();
      if (speech.length > sttRate ~/ 4) {
        final t = decode(Float32List.fromList(speech));
        if (t.isNotEmpty) back.send({'final': t});
      }
      speech = [];
      vad.reset();
      back.send({'partial': ''});
      back.send({'flushed': true});
    }
  });
}
