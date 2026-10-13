import '../i18n/i18n.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'theme.dart';

enum AttachAction { file, task, video, photo, gallery, voice }

/// Bảng "+" ở ô soạn tin: lưới các thao tác đính kèm.
Future<AttachAction?> showAttachPanel(BuildContext context) {
  final items = <(AttachAction, IconData, String, Color)>[
    (AttachAction.file, Icons.insert_drive_file, tr('Chọn file'), const Color(0xFF7F66FF)),
    (AttachAction.task, Icons.task_alt, tr('Tạo việc'), const Color(0xFF02A698)),
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

/// Ghi âm: chạm nút để bắt đầu, chạm lần nữa để dừng, rồi Gửi hoặc Hủy.
/// Trả về đường dẫn file .m4a.
Future<String?> showVoiceRecorder(BuildContext context) => showModalBottomSheet<String>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => const _VoiceRecorder(),
    );

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

  @override
  void dispose() {
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
          const SizedBox(height: 18),
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
                style: FilledButton.styleFrom(backgroundColor: pal.accent, foregroundColor: Colors.white),
                onPressed: _path == null ? null : () => Navigator.pop(context, _path),
                icon: const Icon(Icons.send_rounded),
                label: Text(tr('Gửi')),
              ),
            ),
          ]),
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
      messenger.showSnackBar(SnackBar(content: Text(tr('Đã tạo việc'))));
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
                  title: Text(u.id == app.me?.id ? tr('{0} (tôi)', [u.displayName]) : u.displayName, style: TextStyle(color: pal.text)),
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
  const TasksPage({super.key, this.channelId});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  late bool _onlyChannel = widget.channelId != null;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadTodos();
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
        floatingActionButton: widget.channelId == null
            ? null
            : FloatingActionButton(
                backgroundColor: pal.accent,
                foregroundColor: Colors.white,
                tooltip: tr('Tạo việc'),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => CreateTaskPage(channelId: widget.channelId!))),
                child: const Icon(Icons.add_task),
              ),
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                GlassCircle(icon: Icons.arrow_back_ios_new, onTap: () => Navigator.pop(context)),
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
              labelColor: pal.accentText,
              unselectedLabelColor: pal.sub,
              indicatorColor: pal.accent,
              dividerColor: pal.divider,
              tabs: [for (final (l, name) in tabs) Tab(text: '$name (${pick(l).length})')],
            ),
            Expanded(
              child: !app.todoAvailable
                  ? Center(child: Text(tr('Máy chủ chưa bật plugin Công việc (Todo).'), style: TextStyle(color: pal.sub)))
                  : TabBarView(children: [
                      for (final (l, _) in tabs)
                        pick(l).isEmpty
                            ? Center(child: Text(tr('Không có việc nào'), style: TextStyle(color: pal.sub)))
                            : ListView(children: [for (final t in pick(l)) _TaskRow(task: t, list: l)]),
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
