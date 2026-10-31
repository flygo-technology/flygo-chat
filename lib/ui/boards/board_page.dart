import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/boards_api.dart';
import '../../i18n/i18n.dart';
import '../../state/app_state.dart';
import '../common.dart';
import '../theme.dart';
import 'board_settings.dart';
import 'board_store.dart';
import 'boards_common.dart';
import 'calendar_view.dart';
import 'card_detail.dart';
import 'gallery_view.dart';
import 'kanban_view.dart';
import 'props_page.dart';
import 'table_view.dart';
import 'view_options.dart';

/// Mở một bảng (tùy chọn view / thẻ cần mở sẵn).
Future<void> openBoard(BuildContext context, String boardId, {String? viewId, String? cardId}) => Navigator.of(context, rootNavigator: true)
    .push(MaterialPageRoute(builder: (_) => BoardPage(boardId: boardId, viewId: viewId, cardId: cardId)));

/// Màn hình một bảng: các view (Kanban / Bảng / Lịch / Thư viện) dạng tab, thanh công cụ lọc / sắp xếp / nhóm / thuộc tính,
/// chi tiết thẻ ở cột bên phải (màn hình rộng) hoặc trang riêng (điện thoại).
class BoardPage extends StatefulWidget {
  final String boardId;
  final String? viewId, cardId;
  const BoardPage({super.key, required this.boardId, this.viewId, this.cardId});
  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  late final BoardStore _s;
  String? _viewId;
  String? _selected;
  bool _searching = false;
  final _search = TextEditingController();
  bool _openedInitial = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _viewId = widget.viewId;
    _s = BoardStore(app.api, widget.boardId, app.me?.id ?? '')..addListener(_onStore);
    _s.load();
    app.boardsSubscribe();
  }

  void _onStore() {
    if (!mounted) return;
    if (_s.loaded && !_openedInitial) {
      _openedInitial = true;
      final c = widget.cardId;
      if (c != null && _s.cards.containsKey(c)) WidgetsBinding.instance.addPostFrameCallback((_) => _open(_s.cards[c]!));
    }
    if (_selected != null && !_s.cards.containsKey(_selected)) setState(() => _selected = null);
  }

  @override
  void dispose() {
    _s.removeListener(_onStore);
    _s.dispose();
    _search.dispose();
    super.dispose();
  }

  BoardView? get _view => _s.view(_viewId) ?? _s.views.firstOrNull;

  /// Thẻ vừa tạo mở thẳng chế độ sửa; còn lại mở xem chi tiết.
  String? _newCard;

  void _open(TaskCard c, {bool edit = false}) {
    if (boardsWide(context)) {
      setState(() {
        _selected = c.id;
        _newCard = edit ? c.id : null;
      });
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => CardPage(store: _s, boardId: _s.boardId, cardId: c.id, editing: edit)));
    }
  }

  Future<void> _add([Map<String, dynamic> props = const {}]) async {
    try {
      final c = await _s.createCard(props: props, inView: _view);
      if (mounted) _open(c, edit: true);
    } catch (e) {
      if (mounted) boardsError(context, tr('Không tạo được thẻ'), e);
    }
  }

  Future<void> _addView() async {
    final type = await boardsSheet<String>(
      context,
      (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final t in ['board', 'table', 'calendar', 'gallery'])
            ListTile(leading: Icon(viewTypeIcon(t)), title: Text(viewTypeLabel(t)), onTap: () => Navigator.pop(ctx, t)),
        ]),
      ),
      scroll: false,
    );
    if (type == null || !mounted) return;
    final name = await askText(context, tr('Tên view'), viewTypeLabel(type));
    if (name == null || !mounted) return;
    try {
      final v = await _s.addView(type, name.trim().isEmpty ? viewTypeLabel(type) : name.trim());
      setState(() => _viewId = v.id);
    } catch (e) {
      if (mounted) boardsError(context, tr('Không tạo được view'), e);
    }
  }

  Future<void> _viewMenu(BoardView v, Offset pos) async {
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        PopupMenuItem(value: 'rename', child: Text(tr('Đổi tên'))),
        PopupMenuItem(value: 'dup', child: Text(tr('Nhân bản'))),
        if (_s.views.length > 1) PopupMenuItem(value: 'del', child: Text(tr('Xoá view'), style: const TextStyle(color: Color(0xFFE53935)))),
      ],
    );
    if (r == null || !mounted) return;
    try {
      switch (r) {
        case 'rename':
          final name = await askText(context, tr('Đổi tên view'), v.title);
          if (name != null && name.trim().isNotEmpty) await _s.renameView(v, name.trim());
        case 'dup':
          final nv = await _s.duplicateView(v);
          if (nv != null) setState(() => _viewId = nv.id);
        case 'del':
          if (!await confirmBoards(context, tr('Xoá view?'), tr('View "{0}" sẽ bị xoá; thẻ vẫn giữ nguyên.', [v.title]))) return;
          await _s.deleteView(v);
          setState(() => _viewId = null);
      }
    } catch (e) {
      if (mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  Future<void> _boardMenu(String v) async {
    final b = _s.board;
    if (b == null) return;
    switch (v) {
      case 'settings':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BoardSettingsPage(store: _s)));
      case 'props':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PropertiesPage(store: _s)));
      case 'members':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BoardMembersPage(store: _s)));
      case 'link':
        await Clipboard.setData(ClipboardData(text: BoardsApi.webUrl(teamId: b.teamId, boardId: b.id, viewId: _view?.id)));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(toast(Text(tr('Đã chép link bảng'))));
      case 'refresh':
        await _s.load();
    }
  }

  Widget _toolbar(BoardView v) {
    final pal = Pal.of(context);
    final b = _s.board!;
    final edit = _s.canEdit;
    final nFilter = v.filter.filters.length, nSort = v.sortOptions.length;
    Widget btn(IconData icon, String label, VoidCallback? f, {bool active = false}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: TextButton.icon(
            onPressed: f,
            style: TextButton.styleFrom(
              foregroundColor: active ? pal.accentText : pal.sub,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );
    final group = KanbanView.groupOf(b, v);
    final date = CalendarView.dateProp(b, v);
    // Các tuỳ chọn của view (nhóm / ngày / thuộc tính / lọc / sắp xếp): màn rộng là hàng nút, màn hẹp gom vào một bảng dưới.
    final opts = <(IconData, String, VoidCallback?, bool)>[
      if (v.viewType == 'board')
        (Icons.view_column_outlined, tr('Nhóm: {0}', [group?.name ?? '—']), !edit ? null : () => _pickProp(v, 'groupById', (p) => p.type == 'select'), false),
      if (v.viewType == 'calendar')
        (Icons.event_rounded, tr('Ngày: {0}', [date?.name ?? tr('Ngày tạo')]), !edit ? null : () => _pickProp(v, 'dateDisplayPropertyId', (p) => p.isDate), false),
      if (v.viewType != 'calendar')
        (Icons.tune_rounded, tr('Thuộc tính'), !edit ? null : () => boardsSheet<void>(context, (_) => VisiblePropsSheet(store: _s, viewId: v.id)), false),
      (Icons.filter_list_rounded, nFilter > 0 ? tr('Lọc ({0})', [nFilter]) : tr('Lọc'),
          !edit ? null : () => boardsSheet<void>(context, (_) => FilterSheet(store: _s, view: v)), nFilter > 0),
      if (v.viewType != 'calendar')
        (Icons.sort_rounded, nSort > 0 ? tr('Sắp xếp ({0})', [nSort]) : tr('Sắp xếp'),
            !edit ? null : () => boardsSheet<void>(context, (_) => SortSheet(store: _s, view: v), scroll: false), nSort > 0),
    ];
    final narrow = MediaQuery.sizeOf(context).width < kBoardsNarrow;
    Future<void> optionsSheet() async {
      final f = await boardsSheet<VoidCallback>(
        context,
        scroll: false,
        (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (icon, label, f, active) in opts)
              ListTile(
                enabled: f != null,
                leading: Icon(icon, color: active ? pal.accentText : null),
                title: Text(label, style: TextStyle(color: active ? pal.accentText : null, fontWeight: active ? FontWeight.w600 : null)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(ctx, f),
              ),
          ]),
        ),
      );
      f?.call();
    }

    return SizedBox(
      height: 44,
      child: Row(children: [
        Expanded(
          child: _searching
              ? Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: tr('Tìm thẻ'),
                      isDense: true,
                      border: InputBorder.none,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () => setState(() {
                                _search.clear();
                                _searching = false;
                              })),
                    ),
                  ),
                )
              : narrow
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: btn(
                          Icons.tune_rounded,
                          nFilter + nSort > 0 ? tr('Tuỳ chọn ({0})', [nFilter + nSort]) : tr('Tuỳ chọn'),
                          edit ? optionsSheet : null,
                          active: nFilter + nSort > 0,
                        ),
                      ),
                    )
                  : ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                      for (final (icon, label, f, active) in opts) btn(icon, label, f, active: active),
                    ]),
        ),
        if (!_searching) IconButton(tooltip: tr('Tìm thẻ'), icon: Icon(Icons.search, color: pal.sub), onPressed: () => setState(() => _searching = true)),
        if (edit)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.icon(
              onPressed: () => _add(),
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Mới')),
            ),
          ),
      ]),
    );
  }

  Future<void> _pickProp(BoardView v, String field, bool Function(PropTemplate) ok) async {
    final props = _s.board!.props.where(ok).toList();
    final cur = v.f[field];
    final r = await boardsSheet<String>(
      context,
      (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (field == 'dateDisplayPropertyId')
            ListTile(title: Text(tr('Ngày tạo')), trailing: cur == '' || cur == null ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(ctx, '')),
          for (final p in props)
            ListTile(
              leading: Icon(propTypeIcon(p.type)),
              title: Text(p.name),
              trailing: cur == p.id ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(ctx, p.id),
            ),
          if (props.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(tr('Bảng chưa có thuộc tính phù hợp'))),
        ]),
      ),
      scroll: false,
    );
    if (r == null) return;
    try {
      await _s.patchView(v, {field: r});
    } catch (e) {
      if (mounted) boardsError(context, tr('Không lưu được'), e);
    }
  }

  /// Màn hẹp: chọn view trong bảng dưới (nhấn giữ một view để đổi tên / nhân bản / xoá).
  Future<void> _viewsSheet() async {
    final pal = Pal.of(context);
    final cur = _view;
    final r = await boardsSheet<String>(
      context,
      scroll: false,
      (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7),
          child: ListView(shrinkWrap: true, children: [
            for (final v in _s.views)
              ListTile(
                leading: Icon(viewTypeIcon(v.viewType), color: v.id == cur?.id ? pal.accentText : pal.sub),
                title: Text(v.title.isEmpty ? viewTypeLabel(v.viewType) : v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(viewTypeLabel(v.viewType), style: TextStyle(color: pal.sub)),
                trailing: v.id == cur?.id ? Icon(Icons.check_rounded, color: pal.accentText) : null,
                onTap: () => Navigator.pop(ctx, v.id),
                onLongPress: !_s.canEdit
                    ? null
                    : () {
                        final box = ctx.findRenderObject() as RenderBox?;
                        final pos = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
                        Navigator.pop(ctx);
                        _viewMenu(v, pos);
                      },
              ),
            if (_s.canEdit) ...[
              const Divider(height: 8),
              ListTile(
                leading: Icon(Icons.add_rounded, color: pal.accentText),
                title: Text(tr('Thêm view'), style: TextStyle(color: pal.accentText, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx, '+'),
              ),
            ],
          ]),
        ),
      ),
    );
    if (r == null || !mounted) return;
    if (r == '+') {
      await _addView();
    } else {
      setState(() => _viewId = r);
    }
  }

  Widget _viewTabs() {
    final pal = Pal.of(context);
    final cur = _view;
    if (MediaQuery.sizeOf(context).width < kBoardsNarrow) {
      // Điện thoại: một nút chọn view thay cho hàng tab cuộn ngang.
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ActionChip(
            key: const ValueKey('view-switcher'),
            avatar: Icon(viewTypeIcon(cur?.viewType ?? 'board'), size: 17, color: pal.chipSelFg),
            label: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(cur == null ? '' : (cur.title.isEmpty ? viewTypeLabel(cur.viewType) : cur.title),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.chipSelFg, fontWeight: FontWeight.w600)),
              ),
              if (_s.views.length > 1) Text('  ·  ${_s.views.length}', style: TextStyle(color: pal.chipSelFg.withValues(alpha: .7))),
              Icon(Icons.expand_more_rounded, size: 18, color: pal.chipSelFg),
            ]),
            backgroundColor: pal.chipSelBg,
            side: BorderSide.none,
            onPressed: _viewsSheet,
            tooltip: tr('Chọn view'),
          ),
        ),
      );
    }
    return SizedBox(
      height: 46,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(10, 6, 10, 4), children: [
        for (final v in _s.views)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onLongPressStart: _s.canEdit ? (d) => _viewMenu(v, d.globalPosition) : null,
              onSecondaryTapDown: _s.canEdit ? (d) => _viewMenu(v, d.globalPosition) : null,
              child: ChoiceChip(
                avatar: Icon(viewTypeIcon(v.viewType), size: 17, color: v.id == cur?.id ? pal.chipSelFg : pal.sub),
                label: Text(v.title.isEmpty ? viewTypeLabel(v.viewType) : v.title),
                selected: v.id == cur?.id,
                showCheckmark: false,
                onSelected: (_) => setState(() => _viewId = v.id),
              ),
            ),
          ),
        if (_s.canEdit)
          ActionChip(avatar: const Icon(Icons.add_rounded, size: 17), label: Text(tr('View')), onPressed: _addView, tooltip: tr('Thêm view')),
      ]),
    );
  }

  Widget _body(BoardView v) {
    String names(String id) => userName(context, id);
    final cards = _s.cardsFor(v, search: _search.text, userName: names);
    switch (v.viewType) {
      case 'table':
        return TableView(store: _s, view: v, cards: cards, selectedId: _selected, onOpen: _open, onAdd: () => _add());
      case 'calendar':
        return CalendarView(store: _s, view: v, cards: cards, selectedId: _selected, onOpen: _open, onAdd: _add);
      case 'gallery':
        return GalleryView(store: _s, view: v, cards: cards, selectedId: _selected, onOpen: _open, onAdd: () => _add());
      default:
        return KanbanView(store: _s, view: v, cards: cards, selectedId: _selected, onOpen: _open, onAdd: _add);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ChangeNotifierProvider.value(
      value: _s,
      child: Consumer<BoardStore>(builder: (context, s, _) {
        final b = s.board;
        final v = _view;
        Widget body;
        if (s.deleted) {
          body = BoardsNotice(icon: Icons.delete_outline_rounded, title: tr('Bảng không còn nữa'), body: tr('Bảng đã bị xoá hoặc bạn không còn quyền xem.'));
        } else if (b == null) {
          body = s.error != null
              ? BoardsNotice(
                  icon: Icons.cloud_off_rounded,
                  title: tr('Không tải được bảng'),
                  body: '${s.error}',
                  action: FilledButton(onPressed: s.load, child: Text(tr('Thử lại'))))
              : const Center(child: CircularProgressIndicator());
        } else if (v == null) {
          body = BoardsNotice(
            icon: Icons.view_kanban_outlined,
            title: tr('Bảng chưa có view'),
            action: s.canEdit ? FilledButton.icon(onPressed: _addView, icon: const Icon(Icons.add_rounded), label: Text(tr('Thêm view'))) : null,
          );
        } else {
          final sel = _selected == null ? null : s.cards[_selected];
          final main = Column(children: [
            if (b.showDescription && b.description.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(alignment: Alignment.centerLeft, child: Text(b.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub))),
              ),
            _viewTabs(),
            _toolbar(v),
            Divider(height: 1, color: pal.divider),
            Expanded(
              child: RefreshIndicator(
                notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
                onRefresh: s.load,
                child: _body(v),
              ),
            ),
          ]);
          body = sel == null || !boardsWide(context)
              ? main
              : Row(children: [
                  Expanded(child: main),
                  VerticalDivider(width: 1, color: pal.divider),
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width >= 1300 ? 520 : 440,
                    child: CardDetail(
                      key: ValueKey(sel.id),
                      store: s,
                      cardId: sel.id,
                      editing: _newCard == sel.id,
                      header: Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                        child: Row(children: [
                          IconButton(tooltip: tr('Đóng'), icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _selected = null)),
                          const Spacer(),
                          IconButton(
                            tooltip: tr('Mở toàn màn hình'),
                            icon: const Icon(Icons.open_in_full_rounded, size: 20),
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CardPage(store: s, boardId: s.boardId, cardId: sel.id))),
                          ),
                          CardMenu(store: s, card: sel, onDeleted: () => setState(() => _selected = null), onDuplicated: (c) => _open(c, edit: true)),
                        ]),
                      ),
                    ),
                  ),
                ]);
        }
        return Scaffold(
          backgroundColor: pal.bg,
          appBar: AppBar(
            titleSpacing: 0,
            title: b == null
                ? null
                : InkWell(
                    onTap: () => _boardMenu('settings'),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (b.icon.isNotEmpty) Text('${b.icon} ', style: const TextStyle(fontSize: 20)),
                      Flexible(child: Text(b.title.isEmpty ? tr('(Không có tên)') : b.title, overflow: TextOverflow.ellipsis)),
                      if (!b.isOpen) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.lock_outline_rounded, size: 16, color: pal.sub)),
                    ]),
                  ),
            actions: [
              if (s.loading && s.loaded) const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              if (b != null) ...[
                IconButton(tooltip: tr('Thành viên'), icon: const Icon(Icons.group_outlined), onPressed: () => _boardMenu('members')),
                PopupMenuButton<String>(
                  tooltip: tr('Thêm'),
                  onSelected: _boardMenu,
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'settings', child: ListTile(dense: true, leading: const Icon(Icons.settings_outlined), title: Text(tr('Cài đặt bảng')))),
                    PopupMenuItem(value: 'props', child: ListTile(dense: true, leading: const Icon(Icons.tune_rounded), title: Text(tr('Thuộc tính của thẻ')))),
                    PopupMenuItem(value: 'members', child: ListTile(dense: true, leading: const Icon(Icons.group_outlined), title: Text(tr('Thành viên')))),
                    PopupMenuItem(value: 'link', child: ListTile(dense: true, leading: const Icon(Icons.link_rounded), title: Text(tr('Chép link')))),
                    PopupMenuItem(value: 'refresh', child: ListTile(dense: true, leading: const Icon(Icons.refresh_rounded), title: Text(tr('Tải lại')))),
                  ],
                ),
              ],
            ],
          ),
          body: body,
        );
      }),
    );
  }
}
