import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/boards_api.dart';
import '../../config.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../markdown_view.dart';
import '../open_file.dart';
import '../theme.dart';
import 'board_store.dart';
import 'boards_common.dart';
import 'prop_editors.dart';
import 'props_page.dart';

/// Màn hình riêng của một thẻ (điện thoại, hoặc mở từ "Việc của tôi" / link trong chat). [store] null: tự tải bảng [boardId].
class CardPage extends StatefulWidget {
  final BoardStore? store;
  final String boardId, cardId;
  /// Mở thẳng chế độ sửa (thẻ vừa tạo); mặc định chỉ xem chi tiết.
  final bool editing;
  const CardPage({super.key, this.store, required this.boardId, required this.cardId, this.editing = false});
  @override
  State<CardPage> createState() => _CardPageState();
}

class _CardPageState extends State<CardPage> {
  late final BoardStore _store;
  late final bool _own = widget.store == null;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _store = widget.store ?? (BoardStore(app.api, widget.boardId, app.me?.id ?? '')..load());
    if (_own) app.boardsSubscribe();
  }

  @override
  void dispose() {
    if (_own) _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ChangeNotifierProvider.value(
      value: _store,
      child: Consumer<BoardStore>(builder: (context, s, _) {
        final card = s.cards[widget.cardId];
        final b = s.board;
        return Scaffold(
          backgroundColor: pal.bg,
          appBar: AppBar(
            titleSpacing: 0,
            title: Text(b == null ? '' : '${b.icon.isEmpty ? '' : '${b.icon} '}${b.title}', style: const TextStyle(fontSize: 16)),
            actions: [if (card != null) CardMenu(store: s, card: card, onDeleted: () => Navigator.of(context).maybePop())],
          ),
          body: card != null
              ? CardDetail(store: s, cardId: widget.cardId, editing: widget.editing)
              : s.loading || !s.loaded && s.error == null
                  ? const Center(child: CircularProgressIndicator())
                  : BoardsNotice(icon: Icons.search_off_rounded, title: tr('Không tìm thấy thẻ'), body: s.error == null ? tr('Thẻ đã bị xoá hoặc bạn không có quyền xem.') : '${s.error}'),
        );
      }),
    );
  }
}

/// Menu của thẻ: chép link, nhân bản, xoá.
class CardMenu extends StatelessWidget {
  final BoardStore store;
  final TaskCard card;
  final VoidCallback? onDeleted;
  final ValueChanged<TaskCard>? onDuplicated;
  const CardMenu({super.key, required this.store, required this.card, this.onDeleted, this.onDuplicated});

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: tr('Thêm'),
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) async {
          final messenger = ScaffoldMessenger.of(context);
          switch (v) {
            case 'link':
              final view = store.views.firstOrNull?.id;
              await Clipboard.setData(ClipboardData(text: BoardsApi.webUrl(teamId: store.teamId, boardId: store.boardId, viewId: view, cardId: card.id)));
              messenger.showSnackBar(toast(Text(tr('Đã chép link thẻ'))));
            case 'dup':
              try {
                final c = await store.duplicateCard(card);
                messenger.showSnackBar(toast(Text(tr('Đã nhân bản thẻ'))));
                if (c != null) onDuplicated?.call(c);
              } catch (e) {
                if (context.mounted) boardsError(context, tr('Không nhân bản được'), e);
              }
            case 'del':
              if (!await confirmBoards(context, tr('Xoá thẻ?'), tr('Thẻ "{0}" và nội dung của nó sẽ bị xoá.', [card.title.isEmpty ? tr('(Không có tiêu đề)') : card.title]))) {
                return;
              }
              try {
                await store.deleteCard(card);
                onDeleted?.call();
              } catch (e) {
                if (context.mounted) boardsError(context, tr('Không xoá được'), e);
              }
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'link', child: ListTile(leading: const Icon(Icons.link_rounded), title: Text(tr('Chép link')), dense: true)),
          if (store.canEdit) ...[
            PopupMenuItem(value: 'dup', child: ListTile(leading: const Icon(Icons.copy_rounded), title: Text(tr('Nhân bản')), dense: true)),
            PopupMenuItem(
                value: 'del',
                child: ListTile(
                    leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE53935)),
                    title: Text(tr('Xoá thẻ'), style: const TextStyle(color: Color(0xFFE53935))),
                    dense: true)),
          ],
        ],
      );
}

/// Chi tiết thẻ: biểu tượng + tên, mọi thuộc tính, nội dung (chữ, việc con, đường kẻ, ảnh), đính kèm, bình luận.
class CardDetail extends StatefulWidget {
  final BoardStore store;
  final String cardId;
  /// Thanh trên cùng (bảng bên trên máy tính: nút đóng + menu).
  final Widget? header;
  /// Bắt đầu ở chế độ sửa; mặc định chỉ xem (bấm "Sửa" để sửa).
  final bool editing;
  const CardDetail({super.key, required this.store, required this.cardId, this.header, this.editing = false});
  @override
  State<CardDetail> createState() => _CardDetailState();
}

class _CardDetailState extends State<CardDetail> {
  late final _title = TextEditingController(text: widget.store.cards[widget.cardId]?.title ?? '');
  final _titleFocus = FocusNode();
  final _comment = TextEditingController();
  bool _busy = false;
  late bool _editing = widget.editing;

  BoardStore get s => widget.store;

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _saveTitle();
    });
  }

  @override
  void didUpdateWidget(CardDetail old) {
    super.didUpdateWidget(old);
    if (old.cardId != widget.cardId) {
      _title.text = s.cards[widget.cardId]?.title ?? '';
      _editing = widget.editing;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _titleFocus.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _saveTitle() {
    final c = s.cards[widget.cardId];
    if (c == null || _title.text.trim() == c.title) return;
    s.setCardTitle(c, _title.text.trim()).catchError((e) {
      if (mounted) boardsError(context, tr('Không lưu được'), e);
    });
  }

  Future<void> _run(String what, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) boardsError(context, what, e);
    }
  }

  Future<void> _upload(TaskCard c, {required bool image}) async {
    final files = await FilePicker.pickFiles(type: image ? FileType.image : FileType.any);
    final f = files.firstOrNull;
    if (f == null || f.path == null) return;
    final bytes = await File(f.path!).readAsBytes();
    setState(() => _busy = true);
    await _run(tr('Không tải tệp lên được'), () async {
      final id = await s.api.uploadFile(s.teamId, s.boardId, f.name, bytes);
      await s.addContent(c, image ? 'image' : 'attachment', title: image ? '' : f.name, fields: {'fileId': id});
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openAttachment(BoardBlock b) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(toast(Text(tr('Đang tải tệp...')), icon: Icons.download_rounded));
    await _run(tr('Không mở được tệp'), () async {
      var name = b.title;
      if (name.isEmpty) name = (await s.api.fileInfo(s.teamId, s.boardId, b.fileId)).name;
      if (name.isEmpty) name = b.fileId;
      final bytes = await s.api.fileBytes(s.teamId, s.boardId, b.fileId);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
      await f.writeAsBytes(bytes);
      if (Platform.isAndroid || Platform.isIOS) {
        await openLocalFile(f.path, title: name);
      } else {
        await launchUrl(Uri.file(f.path));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final c = s.cards[widget.cardId];
        final b = s.board;
        if (c == null || b == null) return BoardsNotice(icon: Icons.search_off_rounded, title: tr('Thẻ đã bị xoá'));
        if (!_titleFocus.hasFocus && _title.text != c.title) _title.text = c.title;
        final pal = Pal.of(context);
        final edit = s.canEdit && _editing;
        // Xem chi tiết: ẩn thuộc tính chưa có giá trị cho gọn.
        final props = edit ? b.props : [for (final t in b.props) if (propText(context, t, c).trim().isNotEmpty) t];
        final content = s.contentOf(c);
        final comments = s.commentsOf(c);
        final atts = s.attachmentsOf(c);
        return Column(children: [
          ?widget.header,
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
              // Biểu tượng + tên thẻ
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: !edit
                      ? null
                      : () async {
                          final e = await pickBoardsIcon(context);
                          if (e != null) await _run(tr('Không lưu được'), () => s.setCardIcon(c, e));
                        },
                  onLongPress: !edit || c.icon.isEmpty ? null : () => _run(tr('Không lưu được'), () => s.setCardIcon(c, '')),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: c.icon.isEmpty
                        ? (edit ? Icon(Icons.add_reaction_outlined, color: pal.sub, size: 28) : Icon(Icons.task_alt_rounded, color: pal.accentText, size: 28))
                        : Text(c.icon, style: const TextStyle(fontSize: 30)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: edit
                      ? TextField(
                          controller: _title,
                          focusNode: _titleFocus,
                          maxLines: null,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _saveTitle(),
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: pal.text),
                          decoration: InputDecoration(border: InputBorder.none, hintText: tr('Không có tiêu đề'), isDense: true),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: SelectableText(c.title.isEmpty ? tr('(Không có tiêu đề)') : c.title,
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.title.isEmpty ? pal.sub : pal.text)),
                        ),
                ),
                if (s.canEdit)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: _editing
                        ? FilledButton.tonalIcon(
                            onPressed: () {
                              _saveTitle();
                              _titleFocus.unfocus();
                              setState(() => _editing = false);
                            },
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: Text(tr('Xong')),
                          )
                        : OutlinedButton.icon(
                            onPressed: () => setState(() => _editing = true),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: Text(tr('Sửa')),
                          ),
                  ),
              ]),
              const SizedBox(height: 8),
              // Thuộc tính
              if (!edit && props.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(tr('Chưa có thông tin'), style: TextStyle(color: pal.sub))),
              for (final t in props) _propRow(context, c, t, edit),
              if (edit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => editPropertySheet(context, s),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(tr('Thêm thuộc tính')),
                  ),
                ),
              Divider(height: 28, color: pal.divider),
              // Nội dung
              if (edit || content.isNotEmpty) _section(tr('Mô tả'), 0),
              for (final (i, blk) in content.indexed) _ContentBlock(key: ValueKey(blk.id), store: s, card: c, block: blk, index: i, editing: edit),
              if (edit) _addContentBar(c),
              // Đính kèm
              if (atts.isNotEmpty) ...[
                const SizedBox(height: 18),
                _section(tr('Tệp đính kèm'), atts.length),
                for (final a in atts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.attach_file_rounded, color: pal.sub),
                    title: Text(a.title.isEmpty ? a.fileId : a.title, style: TextStyle(color: pal.text), overflow: TextOverflow.ellipsis),
                    dense: true,
                    onTap: () => _openAttachment(a),
                    trailing: edit
                        ? IconButton(
                            tooltip: tr('Xoá'),
                            icon: Icon(Icons.close_rounded, color: pal.sub, size: 20),
                            onPressed: () async {
                              if (await confirmBoards(context, tr('Xoá tệp đính kèm?'), a.title)) {
                                await _run(tr('Không xoá được'), () => s.deleteBlock(a));
                              }
                            },
                          )
                        : null,
                  ),
              ],
              // Bình luận
              const SizedBox(height: 18),
              _section(tr('Bình luận'), comments.length),
              for (final cm in comments) _comment1(context, cm),
              if (comments.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(tr('Chưa có bình luận'), style: TextStyle(color: pal.sub))),
            ]),
          ),
          if (s.canComment) _composer(c),
        ]);
      },
    );
  }

  Widget _section(String title, int n) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('${title.toUpperCase()}${n > 0 ? ' · $n' : ''}',
            style: TextStyle(fontSize: 12.5, letterSpacing: .5, fontWeight: FontWeight.w700, color: Pal.of(context).sub)),
      );

  Widget _propRow(BuildContext context, TaskCard c, PropTemplate t, bool edit) {
    final pal = Pal.of(context);
    final link = (t.type == 'url' || t.type == 'email' || t.type == 'phone') ? (c.str(t.id) ?? '') : '';
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: t.readOnly || !edit ? null : () => editProp(context, s, c, t),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 140,
            child: InkWell(
              onTap: edit ? () => editPropertySheet(context, s, prop: t) : null,
              child: Row(children: [
                Icon(propTypeIcon(t.type), size: 17, color: pal.sub),
                const SizedBox(width: 6),
                Expanded(child: Text(t.name, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 14))),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: PropValue(t, c, showEmpty: edit))),
          if (link.isNotEmpty)
            InkWell(onTap: () => openPropLink(t, link), child: Icon(Icons.open_in_new_rounded, size: 18, color: pal.accentText)),
        ]),
      ),
    );
  }

  Widget _addContentBar(TaskCard c) {
    final pal = Pal.of(context);
    Widget btn(IconData icon, String label, VoidCallback f) => ActionChip(
          avatar: Icon(icon, size: 17, color: pal.sub),
          label: Text(label),
          onPressed: f,
          visualDensity: VisualDensity.compact,
        );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        btn(Icons.notes_rounded, tr('Chữ'), () => _run(tr('Không thêm được'), () async {
              final t = await askMarkdown(context, '');
              if (t != null && t.trim().isNotEmpty) await s.addContent(c, 'text', title: t.trim());
            })),
        btn(Icons.check_box_outlined, tr('Việc con'), () => _run(tr('Không thêm được'), () async {
              final t = await askText(context, tr('Việc con'), '');
              if (t != null && t.trim().isNotEmpty) await s.addContent(c, 'checkbox', title: t.trim(), fields: {'value': false});
            })),
        btn(Icons.horizontal_rule_rounded, tr('Đường kẻ'), () => _run(tr('Không thêm được'), () => s.addContent(c, 'divider'))),
        btn(Icons.image_outlined, tr('Ảnh'), () => _upload(c, image: true)),
        btn(Icons.attach_file_rounded, tr('Đính kèm'), () => _upload(c, image: false)),
      ]),
    );
  }

  Widget _comment1(BuildContext context, BoardBlock cm) {
    final pal = Pal.of(context);
    final app = context.read<AppState>();
    final mine = cm.createdBy == app.me?.id;
    final t = DateTime.fromMillisecondsSinceEpoch(cm.createAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(userId: cm.createdBy, name: app.users[cm.createdBy]?.displayName ?? '?', size: 30, status: false),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(userName(context, cm.createdBy), style: TextStyle(fontWeight: FontWeight.w600, color: pal.text), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Text(shortDate(t, time: true), style: TextStyle(fontSize: 12, color: pal.sub)),
              const Spacer(),
              if (mine || s.isAdmin)
                InkWell(
                  onTap: () async {
                    if (await confirmBoards(context, tr('Xoá bình luận?'), cm.title)) await _run(tr('Không xoá được'), () => s.deleteBlock(cm));
                  },
                  child: Icon(Icons.delete_outline_rounded, size: 17, color: pal.sub),
                ),
            ]),
            const SizedBox(height: 2),
            MarkdownView(text: cm.title, style: TextStyle(color: pal.text, fontSize: 14.5)),
          ]),
        ),
      ]),
    );
  }

  Widget _composer(TaskCard c) {
    final pal = Pal.of(context);
    Future<void> send() async {
      final t = _comment.text.trim();
      if (t.isEmpty) return;
      _comment.clear();
      await _run(tr('Không gửi được bình luận'), () => s.addComment(c, t));
    }

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(color: pal.surface, border: Border(top: BorderSide(color: pal.divider))),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _comment,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => send(),
              decoration: InputDecoration(hintText: tr('Viết bình luận...'), border: InputBorder.none, isDense: true),
            ),
          ),
          IconButton(icon: Icon(Icons.send_rounded, color: pal.accentText), tooltip: tr('Gửi'), onPressed: send),
        ]),
      ),
    );
  }
}

/// Hộp soạn chữ nhiều dòng (markdown) cho khối nội dung.
Future<String?> askMarkdown(BuildContext context, String initial) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Nội dung')),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 4,
          maxLines: 14,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(hintText: tr('Viết nội dung (hỗ trợ markdown)'), border: const OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text(tr('Lưu'))),
      ],
    ),
  );
}

/// Một khối nội dung của thẻ: chữ (markdown), việc con, đường kẻ, ảnh, tiêu đề. Bấm để sửa, menu để chuyển lên / xuống / xoá.
class _ContentBlock extends StatelessWidget {
  final BoardStore store;
  final TaskCard card;
  final BoardBlock block;
  final int index;
  /// Chế độ sửa: bấm để sửa, có menu chuyển / xoá. Chế độ xem chỉ còn đánh dấu việc con.
  final bool editing;
  const _ContentBlock({super.key, required this.store, required this.card, required this.block, required this.index, required this.editing});

  Future<void> _move(BuildContext context, int d) async {
    final order = [...card.contentOrder];
    final i = order.indexOf(block.id), j = i + d;
    if (i < 0 || j < 0 || j >= order.length) return;
    order[i] = order[j];
    order[j] = block.id;
    try {
      await store.reorderContent(card, order);
    } catch (e) {
      if (context.mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  Future<void> _edit(BuildContext context) async {
    try {
      switch (block.type) {
        case 'text':
        case 'h1':
        case 'h2':
        case 'h3':
          final t = await askMarkdown(context, block.title);
          if (t != null) await store.updateBlock(block, title: t);
        case 'checkbox':
          final t = await askText(context, tr('Việc con'), block.title);
          if (t != null) await store.updateBlock(block, title: t);
      }
    } catch (e) {
      if (context.mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = context.read<AppState>();
    final edit = editing;
    Widget body;
    switch (block.type) {
      case 'divider':
        body = Divider(color: pal.divider, thickness: 1.2);
      case 'checkbox':
        final on = block.fields['value'] == true;
        body = Row(children: [
          Checkbox(
            value: on,
            onChanged: !store.canEdit
                ? null
                : (v) => store.updateBlock(block, fields: {'value': v == true}).catchError((e) {
                      if (context.mounted) boardsError(context, tr('Không lưu được'), e);
                    }),
          ),
          Expanded(
            child: Text(block.title,
                style: TextStyle(color: on ? pal.sub : pal.text, decoration: on ? TextDecoration.lineThrough : null, fontSize: 15)),
          ),
        ]);
      case 'image':
        final url = store.api.fileUrl(store.teamId, store.boardId, block.fileId);
        body = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(url,
              headers: app.api.headers,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Container(
                    height: 80,
                    color: pal.surface2,
                    alignment: Alignment.center,
                    child: Icon(Icons.broken_image_outlined, color: pal.sub),
                  )),
        );
      case 'h1':
      case 'h2':
      case 'h3':
        body = Text(block.title,
            style: TextStyle(fontSize: block.type == 'h1' ? 22 : (block.type == 'h2' ? 19 : 17), fontWeight: FontWeight.w700, color: pal.text));
      default:
        body = block.title.isEmpty
            ? Text(tr('Trống'), style: TextStyle(color: pal.sub))
            : MarkdownView(text: block.title, style: TextStyle(color: pal.text, fontSize: 15, height: 1.4));
    }
    final editable = block.type == 'text' || block.type == 'checkbox' || block.type.startsWith('h');
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: edit && editable ? () => _edit(context) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: body),
          if (edit)
            PopupMenuButton<String>(
              tooltip: tr('Thêm'),
              iconSize: 18,
              padding: EdgeInsets.zero,
              icon: Icon(Icons.more_horiz_rounded, color: pal.sub, size: 18),
              onSelected: (v) async {
                switch (v) {
                  case 'edit':
                    await _edit(context);
                  case 'up':
                    await _move(context, -1);
                  case 'down':
                    await _move(context, 1);
                  case 'del':
                    try {
                      await store.deleteContent(card, block);
                    } catch (e) {
                      if (context.mounted) boardsError(context, tr('Không xoá được'), e);
                    }
                }
              },
              itemBuilder: (_) => [
                if (editable) PopupMenuItem(value: 'edit', child: Text(tr('Sửa'))),
                if (index > 0) PopupMenuItem(value: 'up', child: Text(tr('Chuyển lên'))),
                if (index < card.contentOrder.length - 1) PopupMenuItem(value: 'down', child: Text(tr('Chuyển xuống'))),
                PopupMenuItem(value: 'del', child: Text(tr('Xoá'), style: const TextStyle(color: Color(0xFFE53935)))),
              ],
            ),
        ]),
      ),
    );
  }
}

/// Mở thẻ (từ link trong chat / "Việc của tôi"): màn hình thẻ riêng, tự tải bảng.
Future<void> openBoardCard(BuildContext context, String boardId, String cardId) => Navigator.of(context, rootNavigator: true)
    .push(MaterialPageRoute(builder: (_) => CardPage(boardId: boardId, cardId: cardId)));

/// Có đang chạy trên màn hình rộng (máy tính / máy tính bảng ngang) để chia bảng + chi tiết thẻ.
bool boardsWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900 || (isDesktop && MediaQuery.sizeOf(context).width >= 760);
