import '../i18n/i18n.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../state/app_state.dart';
import 'theme.dart';

// Chọn thư mục làm việc cho dự án trợ lý: duyệt thư mục trên máy chạy bot (trạm Flygo GET /a2a/dirs → runner, chỉ chủ bot,
// chỉ trong projectRoots). Bấm thư mục cha để vào thư mục con, nút quay lại ở trên để lên một cấp.

/// Trả về đường dẫn đã chọn (dạng ~/...), null = huỷ.
Future<String?> pickAgentFolder(BuildContext context, AppState app, String botId) =>
    Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _FolderPicker(app: app, botId: botId)));

class _FolderPicker extends StatefulWidget {
  final AppState app;
  final String botId;
  const _FolderPicker({required this.app, required this.botId});
  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  String _path = '';
  String? _parent;
  String _machine = '';
  List<({String name, String path})> _dirs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await http.get(
        Uri.parse('$kFlygoPush/a2a/dirs').replace(queryParameters: {'bot': widget.botId, 'path': path}),
        headers: {'Authorization': 'Bearer ${widget.app.token}', 'X-MM-Server': kServerUrl, 'User-Agent': kUserAgent},
      ).timeout(const Duration(seconds: 15));
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      if (r.statusCode != 200 || j['ok'] != true) throw Exception(j['error'] ?? 'HTTP ${r.statusCode}');
      setState(() {
        _path = j['path'] as String? ?? '';
        _parent = j['parent'] as String?;
        _machine = j['machine'] as String? ?? '';
        _dirs = [for (final d in (j['dirs'] as List? ?? const [])) (name: '${(d as Map)['name']}', path: '${d['path']}')];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final atTop = _path.isEmpty;
    return PopScope(
      canPop: atTop,
      onPopInvokedWithResult: (did, _) {
        if (!did) _load(_parent ?? '');
      },
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          // Nút quay lại: lên thư mục cha (ở danh sách gốc thì đóng).
          leading: IconButton(
            icon: Icon(atTop ? Icons.close : Icons.arrow_back),
            onPressed: atTop ? () => Navigator.pop(context) : () => _load(_parent ?? ''),
          ),
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(atTop ? tr('Chọn thư mục') : _path.split('/').where((x) => x.isNotEmpty).lastOrNull ?? _path,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(atTop ? (_machine.isEmpty ? '' : tr('Trên máy {0}', [_machine])) : _path,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: pal.sub)),
          ]),
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: pal.accent))
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.folder_off_outlined, size: 40, color: pal.sub),
                        const SizedBox(height: 10),
                        Text(tr('Không tải được danh sách thư mục: {0}', [_error!]), textAlign: TextAlign.center, style: TextStyle(color: pal.text)),
                        const SizedBox(height: 12),
                        OutlinedButton(onPressed: () => _load(_path), child: Text(tr('Thử lại'))),
                      ]),
                    ),
                  )
                : _dirs.isEmpty
                    ? Center(child: Text(tr('Không có thư mục con.'), style: TextStyle(color: pal.sub)))
                    : ListView.separated(
                        itemCount: _dirs.length,
                        separatorBuilder: (_, _) => Divider(height: 1, indent: 56, color: pal.divider),
                        itemBuilder: (_, i) => ListTile(
                          leading: Icon(Icons.folder_rounded, color: pal.accent),
                          title: Text(_dirs[i].name, style: TextStyle(color: pal.text)),
                          subtitle: atTop ? Text(_dirs[i].path, style: TextStyle(color: pal.sub, fontSize: 12.5)) : null,
                          trailing: Icon(Icons.chevron_right, color: pal.sub),
                          onTap: () => _load(_dirs[i].path),
                        ),
                      ),
        bottomNavigationBar: atTop || _error != null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, _path),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(tr('Chọn thư mục này'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
