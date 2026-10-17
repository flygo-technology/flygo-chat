import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api/stt.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

enum AttachAction { file, task, video, photo, gallery, voice }

/// Bảng "+" ở ô soạn tin: lưới các thao tác đính kèm.
Future<AttachAction?> showAttachPanel(BuildContext context) {
  final items = <(AttachAction, IconData, String, Color)>[
    (AttachAction.file, Icons.insert_drive_file, tr('Chọn file'), const Color(0xFF7F66FF)),
    (AttachAction.video, Icons.videocam, 'Quay video', const Color(0xFFD3396D)),
    (AttachAction.photo, Icons.photo_camera, tr('Chụp ảnh'), const Color(0xFFFA6533)),
    (AttachAction.gallery, Icons.photo_library, tr('Thư viện'), const Color(0xFF1F7AEC)),
    (AttachAction.voice, Icons.mic, tr('Ghi âm'), const Color(0xFF06A35A)),
  ];
  return showModalBottomSheet<AttachAction>(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 14,
            childAspectRatio: 1.25,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final (a, icon, label, color) in items)
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.pop(ctx, a),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      child: Icon(icon, color: Colors.white, size: 25),
                    ),
                    const SizedBox(height: 8),
                    Text(label, style: TextStyle(color: pal.text, fontSize: 14)),
                  ]),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Ghi âm: mở ra là ghi ngay; chạm nút để dừng / ghi lại, bấm Gửi (đang ghi thì dừng rồi gửi luôn) hoặc Hủy.
/// Trả về file .m4a (gửi tin thoại) hoặc chữ đã nhận diện (điền vào ô nhắn tin, không tự gửi).
class VoiceResult {
  final String? path;
  final String? text;
  const VoiceResult({this.path, this.text});
}

/// Bấm mic: điện thoại / Mac có bộ nhận diện giọng nói của máy thì nghe và hiện chữ ngay khi đang nói
/// (ưu tiên nhận diện ngay trên máy, không gửi máy chủ); không có thì ghi âm như cũ (gửi tin thoại / máy chủ STT).
/// [recorder] = true: mở thẳng bảng ghi âm gửi tin thoại.
Future<VoiceResult?> showVoiceRecorder(BuildContext context, {bool recorder = false}) async {
  final live = !recorder && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) && await LiveDictation.available();
  if (!context.mounted) return null;
  final r = await showModalBottomSheet<Object>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => live ? const LiveDictation() : const _VoiceRecorder(),
  );
  if (r == LiveDictation.switchToRecorder && context.mounted) return showVoiceRecorder(context, recorder: true);
  return r is VoiceResult ? r : null;
}

/// Bộ nhận diện giọng nói của máy (Google trên Android, Apple trên iPhone / Mac), dùng chung.
class DeviceSpeech {
  static final stt = SpeechToText();
  static bool? _ok;
  static String? locale;

  /// Máy có bộ nhận diện giọng nói tiếng Việt dùng được (khởi tạo một lần).
  static Future<bool> available() async {
    if (_ok != null) return _ok!;
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return _ok = false;
    try {
      _ok = await stt.initialize(debugLogging: false);
      if (_ok!) {
        final locales = await stt.locales();
        locale = locales.where((l) => l.localeId.toLowerCase().startsWith('vi')).map((l) => l.localeId).firstOrNull;
        // Không có tiếng Việt thì dùng cách cũ (máy chủ Whisper hiểu tiếng Việt tốt hơn).
        if (locale == null) _ok = false;
      }
    } catch (_) {
      _ok = false;
    }
    return _ok!;
  }
}

/// Đọc chính tả trực tiếp: mở ra là nghe ngay, chữ chạy liền trong lúc nói (nhận diện của máy, tiếng Việt).
/// Ngừng nói lâu thì máy tự nghe tiếp; bấm "Xong" để đưa chữ vào ô nhắn tin.
class LiveDictation extends StatefulWidget {
  const LiveDictation({super.key});
  static const switchToRecorder = 'recorder';
  static SpeechToText get _stt => DeviceSpeech.stt;
  static String? get _locale => DeviceSpeech.locale;
  static Future<bool> available() => DeviceSpeech.available();

  @override
  State<LiveDictation> createState() => _LiveDictationState();
}

class _LiveDictationState extends State<LiveDictation> {
  SpeechToText get _stt => LiveDictation._stt;
  final _ctl = TextEditingController();
  String _committed = ''; // các đoạn đã nghe xong
  String _partial = ''; // đoạn đang nghe
  bool _active = true; // người dùng chưa bấm Xong / Huỷ
  bool _onDevice = true; // thử nhận diện ngay trên máy trước
  bool _started = false;
  double _level = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _stt.statusListener = _onStatus;
    _stt.errorListener = _onError;
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  @override
  void dispose() {
    _active = false;
    _stt.statusListener = null;
    _stt.errorListener = null;
    _stt.cancel();
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    if (!_active || !mounted) return;
    if (!_started) HapticFeedback.selectionClick();
    _started = true;
    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          localeId: LiveDictation._locale,
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 6),
          partialResults: true,
          onDevice: _onDevice,
          listenMode: ListenMode.dictation,
          cancelOnError: false,
          autoPunctuation: true,
        ),
        onSoundLevelChange: (l) => setState(() => _level = ((l + 2) / 12).clamp(0.0, 1.0)),
        onResult: (r) {
          if (!mounted) return;
          setState(() {
            if (r.finalResult) {
              _committed = [_committed, r.recognizedWords].where((x) => x.trim().isNotEmpty).join(' ');
              _partial = '';
            } else {
              _partial = r.recognizedWords;
            }
            _ctl.text = [_committed, _partial].where((x) => x.trim().isNotEmpty).join(' ');
            _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
          });
        },
      );
    } catch (_) {
      if (_onDevice) {
        _onDevice = false; // máy không có gói nhận diện ngoại tuyến: dùng nhận diện thường của máy
        return _listen();
      }
      if (mounted) setState(() => _error = tr('Không bật được nhận diện giọng nói.'));
    }
  }

  /// Máy tự dừng sau một quãng im lặng: còn đang đọc thì nghe tiếp.
  void _onStatus(String s) {
    if (!mounted) return;
    setState(() {});
    if ((s == 'done' || s == 'notListening') && _active) {
      if (_partial.trim().isNotEmpty) {
        _committed = [_committed, _partial].where((x) => x.trim().isNotEmpty).join(' ');
        _partial = '';
      }
      Future.delayed(const Duration(milliseconds: 250), _listen);
    }
  }

  void _onError(SpeechRecognitionError e) {
    if (!mounted) return;
    // Gói ngoại tuyến không có: chuyển sang nhận diện thường của máy.
    if (_onDevice && (e.errorMsg.contains('language') || e.errorMsg.contains('not_supported') || e.errorMsg.contains('server'))) {
      _onDevice = false;
    }
    if (e.permanent && !e.errorMsg.contains('no_match') && !e.errorMsg.contains('speech_timeout')) {
      setState(() => _error = tr('Lỗi nhận diện giọng nói: {0}', [e.errorMsg]));
    }
  }

  Future<void> _finish(bool keep) async {
    _active = false;
    await _stt.stop();
    final t = _ctl.text.trim();
    if (!mounted) return;
    Navigator.pop(context, keep && t.isNotEmpty ? VoiceResult(text: t) : null);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final listening = _stt.isListening;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 14 + 14 * _level,
                height: 14 + 14 * _level,
                decoration: BoxDecoration(
                    color: listening ? Colors.redAccent : pal.sub.withValues(alpha: .5), shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(listening ? tr('Đang nghe… cứ nói, chữ hiện ngay') : tr('Đang chuẩn bị…'),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pal.text)),
              ),
              Text(_onDevice ? tr('Trên máy') : tr('Nhận diện của máy'), style: TextStyle(fontSize: 12, color: pal.sub)),
            ]),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 90, maxHeight: 220),
              child: TextField(
                controller: _ctl,
                maxLines: null,
                style: TextStyle(fontSize: 18, color: pal.text, height: 1.35),
                decoration: InputDecoration(
                  hintText: tr('Chữ sẽ hiện ở đây khi bạn nói…'),
                  filled: true,
                  fillColor: pal.bg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
                // Sửa tay: giữ nguyên chữ đã sửa làm phần đã nghe.
                onChanged: (v) {
                  _committed = v;
                  _partial = '';
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            const SizedBox(height: 12),
            Row(children: [
              TextButton.icon(
                onPressed: () async {
                  _active = false;
                  await _stt.cancel();
                  if (context.mounted) Navigator.pop(context, LiveDictation.switchToRecorder);
                },
                icon: const Icon(Icons.graphic_eq_rounded, size: 18),
                label: Text(tr('Gửi tin thoại')),
              ),
              const Spacer(),
              TextButton(onPressed: () => _finish(false), child: Text(tr('Hủy'))),
              const SizedBox(width: 6),
              FilledButton.icon(
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: () => _finish(true),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(tr('Xong')),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _VoiceRecorder extends StatefulWidget {
  const _VoiceRecorder();
  @override
  State<_VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<_VoiceRecorder> {
  final _rec = AudioRecorder();
  String? _path;
  bool _recording = false;
  DateTime? _start;
  Duration _len = Duration.zero;
  Timer? _tick;
  double _level = 0;
  StreamSubscription<Amplitude>? _amp;
  String? _error;
  bool _transcribing = false;

  /// Chữ nhận diện từ đoạn vừa ghi (tự chạy khi dừng ghi), sửa được trước khi gửi.
  final _textCtl = TextEditingController();
  Future<void>? _textJob;

  void _startTranscribe(String path) {
    _textCtl.clear();
    // Máy chủ chỉ kịp nhận diện đoạn khoảng 3 phút; dài hơn thì chỉ gửi ghi âm.
    if (_len > const Duration(minutes: 3)) {
      setState(() => _error = tr('Đoạn ghi âm dài hơn 3 phút, không chuyển được thành chữ.'));
      return;
    }
    final api = context.read<AppState>().api;
    setState(() {
      _transcribing = true;
      _error = null;
    });
    _textJob = transcribeAudio(api, path).then((text) {
      if (!mounted || _path != path) return;
      setState(() {
        _transcribing = false;
        _textCtl.text = text;
        if (text.isEmpty) _error = tr('Không nghe rõ, thử nói lại.');
      });
    }, onError: (_) {
      if (!mounted || _path != path) return;
      setState(() {
        _transcribing = false;
        _error = tr('Không chuyển được thành chữ. Kiểm tra kết nối mạng.');
      });
    });
  }

  /// Chuyển thành văn bản: đang ghi thì dừng, chờ nhận diện xong rồi điền vào ô nhắn tin (không tự gửi).
  Future<void> _sendText() async {
    if (_recording) await _toggle();
    await _textJob;
    final t = _textCtl.text.trim();
    if (mounted && t.isNotEmpty) Navigator.pop(context, VoiceResult(text: t));
  }

  @override
  void initState() {
    super.initState();
    // Bấm ghi âm là bắt đầu ghi ngay, không phải chạm thêm lần nữa.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_recording) _toggle();
    });
  }

  /// Gửi: đang ghi thì dừng rồi gửi luôn.
  Future<void> _sendNow() async {
    if (_recording) await _toggle();
    if (mounted && _path != null) Navigator.pop(context, VoiceResult(path: _path));
  }

  @override
  void dispose() {
    _textCtl.dispose();
    _tick?.cancel();
    _amp?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_recording) {
      final p = await _rec.stop();
      _tick?.cancel();
      _amp?.cancel();
      setState(() {
        _recording = false;
        _path = p;
      });
      if (p != null) _startTranscribe(p);
      return;
    }
    if (!await _rec.hasPermission()) {
      setState(() => _error = tr('Cần cho phép dùng micro để ghi âm.'));
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/ghi-am-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100), path: path);
    HapticFeedback.mediumImpact();
    _start = DateTime.now();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      setState(() => _len = DateTime.now().difference(_start!));
    });
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      setState(() => _level = ((a.current + 50) / 50).clamp(0.0, 1.0));
    });
    setState(() {
      _recording = true;
      _path = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final mm = _len.inMinutes.toString().padLeft(2, '0');
    final ss = (_len.inSeconds % 60).toString().padLeft(2, '0');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_recording ? tr('Đang ghi âm...') : (_path != null ? tr('Đã ghi xong') : tr('Ghi âm')),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
          const SizedBox(height: 10),
          Text('$mm:$ss', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w300, color: pal.text)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: _toggle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 84 + _level * 24,
              height: 84 + _level * 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _recording ? Colors.redAccent : pal.accent,
                boxShadow: [BoxShadow(color: (_recording ? Colors.redAccent : pal.accent).withValues(alpha: .4), blurRadius: 18)],
              ),
              child: Icon(_recording ? Icons.stop : Icons.mic, color: Colors.white, size: 40),
            ),
          ),
          const SizedBox(height: 10),
          Text(_recording ? tr('Chạm để dừng') : tr('Chạm để bắt đầu ghi'), style: TextStyle(color: pal.sub)),
          if (_path != null && !_recording) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _textCtl,
              enabled: !_transcribing,
              onChanged: (_) => setState(() {}),
              minLines: 1,
              maxLines: 5,
              style: TextStyle(color: pal.text, fontSize: 15.5),
              decoration: InputDecoration(
                hintText: _transcribing ? tr('Đang chuyển thành chữ...') : tr('Chữ nhận diện được'),
                prefixIcon: _transcribing
                    ? Padding(padding: const EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent)))
                    : Icon(Icons.text_fields_rounded, color: pal.sub),
                filled: true,
                fillColor: pal.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Chuyển thành văn bản: nút rộng riêng một dòng (điện thoại hẹp không đủ chỗ cho 3 nút).
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
              onPressed: (_path == null && !_recording) || (!_transcribing && !_recording && _textCtl.text.trim().isEmpty) ? null : _sendText,
              icon: const Icon(Icons.text_fields_rounded, size: 20),
              label: Text(tr('Chuyển thành văn bản')),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  if (_recording) await _rec.cancel();
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(tr('Hủy')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: pal.accent.withValues(alpha: .18), foregroundColor: pal.accentText),
                onPressed: _path == null && !_recording ? null : _sendNow,
                icon: const Icon(Icons.mic_rounded, size: 18),
                label: Text(tr('Gửi ghi âm')),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Bảng chọn một cuộc trò chuyện (có ô tìm kiếm); trả về id kênh hoặc null nếu bỏ qua.
Future<String?> pickChat(BuildContext context, {required String title}) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _ChatPicker(title: title),
    );

class _ChatPicker extends StatefulWidget {
  final String title;
  const _ChatPicker({required this.title});
  @override
  State<_ChatPicker> createState() => _ChatPickerState();
}

class _ChatPickerState extends State<_ChatPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.watch<AppState>();
    final q = _q.trim().toLowerCase();
    final chats = app.chats.where((c) => q.isEmpty || c.title.toLowerCase().contains(q)).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
            child: Row(children: [
              Expanded(child: Text(widget.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text))),
              IconButton(icon: Icon(Icons.close, color: pal.sub), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: TextStyle(color: pal.text),
              decoration: InputDecoration(
                hintText: tr('Tìm kiếm'),
                hintStyle: TextStyle(color: pal.sub),
                prefixIcon: Icon(Icons.search, color: pal.sub),
                isDense: true,
                filled: true,
                fillColor: pal.surface2,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: chats.isEmpty
                ? Center(child: Text(tr('Không tìm thấy cuộc trò chuyện'), style: TextStyle(color: pal.sub)))
                : ListView.builder(
                    itemCount: chats.length,
                    itemBuilder: (_, i) {
                      final c = chats[i];
                      return ListTile(
                        leading: Avatar(userId: c.avatarUserId, name: c.title, size: 40, channel: c.channel),
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text)),
                        onTap: () => Navigator.pop(context, c.channel.id),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

/// Tạo việc trong một cuộc trò chuyện, giao cho một thành viên.
class CreateTaskPage extends StatefulWidget {
  final String channelId;
  final String initialTitle;
  const CreateTaskPage({super.key, required this.channelId, this.initialTitle = ''});
  @override
  State<CreateTaskPage> createState() => _CreateTaskPageState();
}

class _CreateTaskPageState extends State<CreateTaskPage> {
  late final _title = TextEditingController(text: widget.initialTitle);
  final _desc = TextEditingController();
  MmUser? _assignee;
  List<MmUser> _members = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _assignee = app.me;
    app.channelUsers(widget.channelId).then((m) {
      if (mounted) setState(() => _members = m.where((u) => !u.isBot).toList());
    });
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) return;
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await app.createTodo(widget.channelId, _title.text.trim(), description: _desc.text.trim(), assignee: _assignee);
      nav.pop(true);
      messenger.showSnackBar(toast(Text(tr('Đã tạo việc'))));
    } catch (e) {
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
          content: Text(app.todoAvailable ? tr('Không tạo được việc. Kiểm tra kết nối mạng.') : tr('Máy chủ chưa bật plugin Công việc (Todo).'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.read<AppState>();
    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: pal.sub),
          filled: true,
          fillColor: pal.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        );
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Row(children: [
            GlassCircle(icon: Icons.close, onTap: () => Navigator.pop(context)),
            Expanded(
              child: Text(tr('Tạo việc'),
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
            ),
            _saving
                ? SizedBox(width: 44, height: 44, child: Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent)))
                : GlassCircle(icon: Icons.check, color: pal.accent, iconColor: Colors.white, onTap: _save),
          ]),
          const SizedBox(height: 20),
          TextField(controller: _title, autofocus: true, style: TextStyle(color: pal.text, fontSize: 17), decoration: deco(tr('Tên việc cần làm'))),
          const SizedBox(height: 12),
          TextField(controller: _desc, minLines: 3, maxLines: 8, style: TextStyle(color: pal.text), decoration: deco(tr('Mô tả (không bắt buộc)'))),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 8),
            child: Text('GIAO CHO', style: TextStyle(fontSize: 13, color: pal.sub, letterSpacing: .3)),
          ),
          Container(
            decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              for (final u in _members.isEmpty && app.me != null ? [app.me!] : _members)
                ListTile(
                  leading: Avatar(userId: u.id, name: u.displayName, size: 38),
                  title: nameText(u.id == app.me?.id ? tr('{0} (tôi)', [u.displayName]) : u.displayName, bot: u.isBot, engine: engineOf(u), style: TextStyle(color: pal.text)),
                  trailing: Icon(_assignee?.id == u.id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: _assignee?.id == u.id ? pal.accent : pal.sub),
                  onTap: () => setState(() => _assignee = u),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Trang công việc: việc của tôi, việc người khác giao (chờ nhận), việc tôi đã giao.
/// Có [channelId] thì mặc định chỉ hiện việc của cuộc trò chuyện đó.
class TasksPage extends StatefulWidget {
  final String? channelId;
  /// Đặt trong tab (không có nút quay lại): thay nút quay lại bằng [leading] (vd. ảnh đại diện).
  final Widget? leading;
  final double bottomPadding;
  const TasksPage({super.key, this.channelId, this.leading, this.bottomPadding = 0});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> with SingleTickerProviderStateMixin {
  late bool _onlyChannel = widget.channelId != null;
  /// Tab đang chọn được nhớ lại kể cả khi trang dựng lại (vd. danh sách đang tải xong) — không nhảy về "Của tôi".
  static int _lastTab = 0;
  late final TabController _tabCtl = TabController(length: 3, vsync: this, initialIndex: _lastTab)
    ..addListener(() => _lastTab = _tabCtl.index);

  @override
  void dispose() {
    _tabCtl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadTodos();
  }

  /// Khoảng nâng nút tạo việc lên trên thanh tab nổi (0 khi trang mở riêng, không có thanh tab).
  double _fabLift(BuildContext context) {
    if (widget.bottomPadding <= 0) return 0;
    // Nút nổi đã tự tránh vùng an toàn; thanh tab cao ~64 và đè 14 lên vùng an toàn (máy có thanh vuốt).
    return MediaQuery.paddingOf(context).bottom > 0 ? 44 : 68;
  }

  /// Tạo việc: trong một cuộc trò chuyện thì mở luôn, ở tab Công việc thì chọn cuộc trò chuyện trước.
  Future<void> _create() async {
    final nav = Navigator.of(context);
    final channelId = widget.channelId ?? await pickChat(context, title: tr('Tạo việc trong cuộc trò chuyện'));
    if (channelId == null || !mounted) return;
    nav.push(MaterialPageRoute(builder: (_) => CreateTaskPage(channelId: channelId)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    List<Map<String, dynamic>> pick(String l) =>
        app.todos[l]!.where((t) => !_onlyChannel || app.todoChannel(t) == widget.channelId).toList();
    final tabs = [('my', tr('Của tôi')), ('in', tr('Được giao')), ('out', tr('Đã giao'))];
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: pal.bg,
        // (TabBar/TabBarView dùng _tabCtl riêng để giữ tab đang chọn.)
        // Nút tạo việc nổi góc phải, đặt cao hơn thanh tab nổi (khi trang nằm trong tab) để không bị che.
        floatingActionButton: Padding(
          padding: EdgeInsets.only(bottom: _fabLift(context)),
          child: FloatingActionButton(
            shape: const CircleBorder(),
            backgroundColor: pal.accent,
            foregroundColor: Colors.white,
            tooltip: tr('Tạo việc'),
            onPressed: _create,
            child: Icon(widget.channelId == null ? Icons.add : Icons.add_task),
          ),
        ),
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                widget.leading ?? GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
                Expanded(
                  child: Text(tr('Công việc'),
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text)),
                ),
                GlassCircle(icon: Icons.refresh, onTap: app.loadTodos),
              ]),
            ),
            if (widget.channelId != null)
              SwitchListTile.adaptive(
                value: _onlyChannel,
                activeTrackColor: pal.accent,
                onChanged: (v) => setState(() => _onlyChannel = v),
                title: Text(tr('Chỉ việc của cuộc trò chuyện này'), style: TextStyle(color: pal.text, fontSize: 15)),
              ),
            TabBar(
              controller: _tabCtl,
              labelColor: pal.accentText,
              unselectedLabelColor: pal.sub,
              indicatorColor: pal.accent,
              dividerColor: pal.divider,
              tabs: [for (final (l, name) in tabs) CountTab(label: name, count: pick(l).length)],
            ),
            Expanded(
              child: !app.todoAvailable
                  ? Center(child: Text(tr('Máy chủ chưa bật plugin Công việc (Todo).'), style: TextStyle(color: pal.sub)))
                  : TabBarView(controller: _tabCtl, children: [
                      for (final (l, _) in tabs)
                        pick(l).isEmpty
                            ? Center(child: Text(tr('Không có việc nào'), style: TextStyle(color: pal.sub)))
                            : ListView(
                                padding: EdgeInsets.only(bottom: widget.bottomPadding),
                                children: [for (final t in pick(l)) _TaskRow(task: t, list: l)],
                              ),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  final Map<String, dynamic> task;
  final String list;
  const _TaskRow({required this.task, required this.list});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    final other = task['user'] as String?;
    final otherName = other == null || other.isEmpty ? null : (app.users[other]?.displayName ?? other);
    final ch = app.channels[app.todoChannel(task) ?? ''];
    final sub = [
      if (list == 'in' && otherName != null) tr('Từ {0}', [otherName]),
      if (list == 'out' && otherName != null) 'Giao cho $otherName',
      if (ch != null) app.channelTitle(ch),
      listTime((task['create_at'] as num?)?.toInt() ?? 0),
    ].join(' · ');
    return ListTile(
      leading: list == 'my'
          ? IconButton(
              icon: Icon(Icons.radio_button_unchecked, color: pal.accentText),
              tooltip: tr('Xong'),
              onPressed: () => app.todoAction('complete', task['id'] as String),
            )
          : Icon(list == 'in' ? Icons.move_to_inbox_outlined : Icons.outbox_outlined, color: pal.sub),
      title: Text(task['message'] as String? ?? '', style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
      subtitle: Text(
        [if ((task['description'] as String? ?? '').isNotEmpty) task['description'], sub].join('\n'),
        style: TextStyle(color: pal.sub, fontSize: 13),
      ),
      isThreeLine: (task['description'] as String? ?? '').isNotEmpty,
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert, color: pal.sub),
        onSelected: (a) => app.todoAction(a, task['id'] as String),
        itemBuilder: (_) => [
          if (list == 'in') PopupMenuItem(value: 'accept', child: Text(tr('Nhận việc'))),
          if (list != 'in') PopupMenuItem(value: 'complete', child: Text(tr('Đánh dấu xong'))),
          PopupMenuItem(value: 'remove', child: Text(tr('Xóa'))),
        ],
      ),
    );
  }
}
