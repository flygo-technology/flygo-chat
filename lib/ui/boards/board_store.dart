import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/boards_api.dart';
import '../../api/mm_api.dart';

/// Dữ liệu của một bảng đang mở: bảng, các view, thẻ, nội dung + bình luận của thẻ, thành viên. Sửa thì cập nhật ngay trên máy
/// (lạc quan) rồi gọi API; lỗi thì tải lại và báo lỗi cho màn hình. Nghe sự kiện realtime của plugin để cập nhật khi người khác sửa.
class BoardStore extends ChangeNotifier {
  final BoardsApi api;
  final String boardId, myId;
  BoardStore(MmApi mm, this.boardId, this.myId) : api = BoardsApi(mm) {
    _sub = BoardsApi.events.stream.listen(_onEvent);
  }

  TaskBoard? board;
  List<BoardView> views = [];
  final Map<String, TaskCard> cards = {};
  /// Khối nội dung, đính kèm và bình luận (theo id).
  final Map<String, BoardBlock> blocks = {};
  List<BoardMember> members = [];
  bool loading = false, loaded = false, deleted = false;
  Object? error;
  StreamSubscription<BoardsEvent>? _sub;
  bool _disposed = false;

  String get teamId => board?.teamId ?? '';

  /// Vai trò của mình: thành viên thật, hoặc quyền tối thiểu của bảng mở cho team.
  String get myRole {
    final m = members.where((m) => m.userId == myId).firstOrNull;
    if (m != null) return m.role;
    final b = board;
    if (b != null && b.isOpen && b.minimumRole.isNotEmpty) return b.minimumRole;
    return b?.isOpen == true ? 'editor' : 'viewer';
  }

  bool get canEdit => roleAtLeast(myRole, 'editor');
  bool get canComment => roleAtLeast(myRole, 'commenter');
  bool get isAdmin => myRole == 'admin';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    error = null;
    _notify();
    try {
      final results = await Future.wait([api.board(boardId), api.allBlocks(boardId)]);
      board = results[0] as TaskBoard;
      _setBlocks(results[1] as List<BoardBlock>);
      try {
        members = await api.members(boardId);
      } on ApiException catch (_) {}
      loaded = true;
    } catch (e) {
      error = e;
      if (e is ApiException && e.status == 404) deleted = true;
    } finally {
      loading = false;
      _notify();
    }
  }

  void _setBlocks(List<BoardBlock> all) {
    final vs = <BoardView>[];
    cards.clear();
    blocks.clear();
    for (final b in all) {
      if (b.deleteAt != 0) continue;
      _put(b, vs);
    }
    views = _sortViews(vs);
  }

  void _put(BoardBlock b, [List<BoardView>? vs]) {
    switch (b.type) {
      case 'view':
        (vs ?? views).removeWhere((v) => v.id == b.id);
        (vs ?? views).add(BoardView(b));
      case 'card':
        final c = TaskCard.fromJson(_blockJson(b));
        if (!c.isTemplate) cards[c.id] = c;
      case 'board':
        break;
      default:
        blocks[b.id] = b;
    }
  }

  static Map<String, dynamic> _blockJson(BoardBlock b) => {
        'id': b.id, 'boardId': b.boardId, 'title': b.title, 'fields': b.fields, 'createdBy': b.createdBy,
        'modifiedBy': b.modifiedBy, 'createAt': b.createAt, 'updateAt': b.updateAt, 'deleteAt': b.deleteAt,
      };

  /// View theo tên (bỏ emoji đầu), như thanh view của bản web.
  static List<BoardView> _sortViews(List<BoardView> vs) {
    String key(BoardView v) => v.title.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '').toLowerCase();
    return vs..sort((a, b) => key(a).compareTo(key(b)));
  }

  // ---------------------------------------------------------------- realtime

  void _onEvent(BoardsEvent e) {
    switch (e.action) {
      case 'UPDATE_BLOCK':
        final m = e.block;
        if (m == null || m['boardId'] != boardId) return;
        final b = BoardBlock.fromJson(m);
        if (b.deleteAt != 0) {
          views.removeWhere((v) => v.id == b.id);
          cards.remove(b.id);
          blocks.remove(b.id);
        } else {
          _put(b);
          if (b.type == 'view') views = _sortViews(views);
        }
        _notify();
      case 'UPDATE_BOARD':
        final m = e.board;
        if (m == null || m['id'] != boardId) return;
        final b = TaskBoard.fromJson(m);
        if (b.deleteAt != 0) {
          deleted = true;
        } else {
          board = b;
        }
        _notify();
      case 'UPDATE_MEMBER':
      case 'DELETE_MEMBER':
        final m = e.member;
        if (m == null || m['boardId'] != boardId) return;
        final mem = BoardMember.fromJson(m);
        members = [
          for (final x in members)
            if (x.userId != mem.userId) x,
          if (e.action == 'UPDATE_MEMBER') mem,
        ];
        if (e.action == 'DELETE_MEMBER' && mem.userId == myId && board?.isOpen != true) deleted = true;
        _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }

  /// Chạy lệnh ghi; lỗi thì tải lại từ máy chủ (bỏ thay đổi lạc quan) rồi ném lỗi cho màn hình báo.
  Future<T> _write<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      unawaited(load());
      rethrow;
    }
  }

  // ---------------------------------------------------------------- tra cứu

  BoardView? view(String? id) => views.where((v) => v.id == id).firstOrNull;

  /// Thẻ của view: lọc theo bộ lọc của view + chữ tìm, rồi sắp xếp.
  List<TaskCard> cardsFor(BoardView v, {String search = '', String Function(String id)? userName}) {
    final b = board;
    if (b == null) return const [];
    final q = normText(search);
    final list = cards.values.where((c) => filterMet(v.filter, b.props, c) && (q.isEmpty || normText(c.title).contains(q))).toList();
    return sortCards(list, b, v, userName);
  }

  /// Nội dung thẻ theo thứ tự (không gồm đính kèm và bình luận).
  List<BoardBlock> contentOf(TaskCard c) => [
        for (final id in c.contentOrder)
          if (blocks[id] != null && blocks[id]!.type != 'comment' && blocks[id]!.type != 'attachment') blocks[id]!,
      ];

  List<BoardBlock> attachmentsOf(TaskCard c) =>
      blocks.values.where((b) => b.parentId == c.id && b.type == 'attachment').toList()..sort((a, b) => a.createAt.compareTo(b.createAt));

  List<BoardBlock> commentsOf(TaskCard c) =>
      blocks.values.where((b) => b.parentId == c.id && b.type == 'comment').toList()..sort((a, b) => a.createAt.compareTo(b.createAt));

  /// Ảnh bìa (ảnh đầu tiên trong nội dung) cho view Thư viện.
  String? coverFileId(TaskCard c) => contentOf(c).where((b) => b.type == 'image' && b.fileId.isNotEmpty).firstOrNull?.fileId;

  // ---------------------------------------------------------------- thẻ

  Future<void> setCardProp(TaskCard c, String propId, Object? value) => _write(() async {
        final cur = cards[c.id] ?? c;
        final all = {...cur.properties, propId: value};
        cards[c.id] = cur.copyWith(properties: all);
        _notify();
        // Plugin trên máy chủ thay CẢ bộ thuộc tính khi sửa: luôn gửi bộ đầy đủ.
        cards[c.id] = await api.patchCard(c.id, properties: all);
        _notify();
      });

  Future<void> setCardTitle(TaskCard c, String title) => _write(() async {
        cards[c.id] = (cards[c.id] ?? c).copyWith(title: title);
        _notify();
        await api.patchCard(c.id, title: title);
      });

  Future<void> setCardIcon(TaskCard c, String icon) => _write(() async {
        cards[c.id] = (cards[c.id] ?? c).copyWith(icon: icon);
        _notify();
        await api.patchCard(c.id, icon: icon);
      });

  /// Tạo thẻ (thuộc tính thỏa bộ lọc của view đang xem được thêm vào), trả về thẻ mới.
  Future<TaskCard> createCard({String title = '', Map<String, dynamic> props = const {}, BoardView? inView}) => _write(() async {
        final b = board!;
        final p = {if (inView != null) ...propsMeetingFilter(inView.filter, b.props), ...props};
        final c = await api.createCard(boardId, title, p);
        cards[c.id] = c;
        _notify();
        return c;
      });

  Future<void> deleteCard(TaskCard c) => _write(() async {
        cards.remove(c.id);
        _notify();
        await api.deleteBlock(boardId, c.id);
      });

  Future<TaskCard?> duplicateCard(TaskCard c) => _write(() async {
        final made = await api.duplicateBlock(boardId, c.id);
        for (final b in made) {
          _put(b);
        }
        _notify();
        final first = made.where((b) => b.type == 'card').firstOrNull;
        return first == null ? null : cards[first.id];
      });

  /// Kéo thẻ trong Kanban: đổi giá trị cột (nếu sang cột khác) và thứ tự thủ công của view.
  /// [beforeId]: thẻ đứng sau vị trí thả (null = cuối cột). [columnCards]: thẻ của cột đích theo thứ tự đang hiện.
  Future<void> moveCard(BoardView v, TaskCard c, {PropTemplate? group, String? toOption, String? beforeId, List<TaskCard> columnCards = const []}) =>
      _write(() async {
        final b = board!;
        final all = sortCards(cards.values.toList(), b, v).map((x) => x.id).toList()..remove(c.id);
        var at = beforeId == null ? -1 : all.indexOf(beforeId);
        if (at < 0) {
          final last = columnCards.where((x) => x.id != c.id).lastOrNull;
          at = last == null ? all.length : all.indexOf(last.id) + 1;
        }
        all.insert(at.clamp(0, all.length), c.id);
        final cur = cards[c.id] ?? c;
        final changeGroup = group != null && cur.str(group.id) != toOption && !(cur.str(group.id) == null && (toOption ?? '').isEmpty);
        final props = {...cur.properties, if (group != null) group.id: toOption ?? ''};
        if (changeGroup) cards[c.id] = cur.copyWith(properties: props);
        _setViewFields(v, {'cardOrder': all, 'sortOptions': []});
        _notify();
        await Future.wait([
          if (changeGroup) api.patchCard(c.id, properties: props),
          api.patchBlock(boardId, v.id, updatedFields: {'cardOrder': all, 'sortOptions': []}),
        ]);
      });

  // ---------------------------------------------------------------- view

  void _setViewFields(BoardView v, Map<String, dynamic> f) {
    final i = views.indexWhere((x) => x.id == v.id);
    if (i >= 0) views[i] = BoardView(views[i].block.copyWith(fields: {...views[i].f, ...f}));
  }

  Future<void> patchView(BoardView v, Map<String, dynamic> fields) => _write(() async {
        _setViewFields(v, fields);
        _notify();
        await api.patchBlock(boardId, v.id, updatedFields: fields);
      });

  Future<void> renameView(BoardView v, String title) => _write(() async {
        final i = views.indexWhere((x) => x.id == v.id);
        if (i >= 0) views[i] = BoardView(v.block.copyWith(title: title));
        views = _sortViews(views);
        _notify();
        await api.patchBlock(boardId, v.id, title: title);
      });

  Future<BoardView> addView(String type, String title) => _write(() async {
        final b = board!;
        final select = b.props.where((p) => p.type == 'select').firstOrNull;
        final date = b.props.where((p) => p.type == 'date').firstOrNull;
        final visible = switch (type) {
          'table' => [for (final p in b.props) p.id],
          'board' || 'gallery' => [for (final p in b.props.where((p) => p.id != select?.id).take(3)) p.id],
          _ => <String>[],
        };
        final made = await api.insertBlocks(boardId, [
          BoardBlock.make(boardId, boardId, 'view',
              title: title, fields: BoardView.defaultFields(type, groupById: type == 'board' ? select?.id : null, dateId: date?.id, visible: visible)),
        ]);
        final v = BoardView(made.first);
        views = _sortViews([...views.where((x) => x.id != v.id), v]);
        _notify();
        return v;
      });

  Future<BoardView?> duplicateView(BoardView v) => _write(() async {
        final made = await api.duplicateBlock(boardId, v.id);
        for (final b in made) {
          _put(b);
        }
        views = _sortViews(views);
        _notify();
        final first = made.where((b) => b.type == 'view').firstOrNull;
        return first == null ? null : BoardView(first);
      });

  Future<void> deleteView(BoardView v) => _write(() async {
        views.removeWhere((x) => x.id == v.id);
        _notify();
        await api.deleteBlock(boardId, v.id);
      });

  // ---------------------------------------------------------------- bảng & thuộc tính

  Future<void> patchBoard({String? title, String? icon, String? description, bool? showDescription, String? type, String? minimumRole}) =>
      _write(() async {
        board = board!.copyWith(
            title: title, icon: icon, description: description, showDescription: showDescription, type: type, minimumRole: minimumRole);
        _notify();
        board = await api.patchBoard(boardId,
            title: title, icon: icon, description: description, showDescription: showDescription, type: type, minimumRole: minimumRole);
        _notify();
      });

  /// Thêm hoặc sửa một thuộc tính (tên, loại, phương án).
  Future<void> saveProp(PropTemplate t) => _write(() async {
        final b = board!;
        final has = b.props.any((p) => p.id == t.id);
        board = b.copyWith(props: has ? [for (final p in b.props) p.id == t.id ? t : p] : [...b.props, t]);
        _notify();
        board = await api.patchBoard(boardId, updatedProps: [t]);
        _notify();
      });

  /// Bỏ thuộc tính; bỏ luôn khỏi các view đang hiện / nhóm theo nó.
  Future<void> deleteProp(PropTemplate t) => _write(() async {
        final b = board!;
        board = b.copyWith(props: b.props.where((p) => p.id != t.id).toList());
        _notify();
        board = await api.patchBoard(boardId, deletedProps: [t.id]);
        for (final v in [...views]) {
          final f = <String, dynamic>{};
          if (v.visiblePropertyIds.contains(t.id)) f['visiblePropertyIds'] = v.visiblePropertyIds.where((x) => x != t.id).toList();
          if (v.groupById == t.id) f['groupById'] = '';
          if (v.dateDisplayPropertyId == t.id) f['dateDisplayPropertyId'] = '';
          if (v.sortOptions.any((s) => s.propertyId == t.id)) {
            f['sortOptions'] = [for (final s in v.sortOptions) if (s.propertyId != t.id) s.toJson()];
          }
          if (f.isNotEmpty) await patchView(v, f);
        }
        _notify();
      });

  Future<void> reorderProps(List<PropTemplate> ordered) => _write(() async {
        board = board!.copyWith(props: ordered);
        _notify();
        board = await api.reorderProps(boardId, ordered);
        _notify();
      });

  // ---------------------------------------------------------------- nội dung & bình luận

  /// Thêm khối nội dung vào cuối thẻ (hoặc trước [beforeId]). Đính kèm không nằm trong thứ tự nội dung (như bản web).
  Future<BoardBlock> addContent(TaskCard c, String type, {String title = '', Map<String, dynamic>? fields}) => _write(() async {
        final made = await api.insertBlocks(boardId, [BoardBlock.make(boardId, c.id, type, title: title, fields: fields)]);
        final b = made.first;
        blocks[b.id] = b;
        if (type != 'attachment') {
          final cur = cards[c.id] ?? c;
          final order = [...cur.contentOrder, b.id];
          cards[c.id] = cur.copyWith(contentOrder: order);
          _notify();
          await api.patchCard(c.id, contentOrder: order);
        }
        _notify();
        return b;
      });

  Future<void> updateBlock(BoardBlock b, {String? title, Map<String, dynamic>? fields}) => _write(() async {
        blocks[b.id] = b.copyWith(title: title, fields: fields == null ? null : {...b.fields, ...fields});
        _notify();
        await api.patchBlock(boardId, b.id, title: title, updatedFields: fields);
      });

  Future<void> deleteContent(TaskCard c, BoardBlock b) => _write(() async {
        blocks.remove(b.id);
        final cur = cards[c.id] ?? c;
        final order = cur.contentOrder.where((x) => x != b.id).toList();
        final reorder = order.length != cur.contentOrder.length;
        if (reorder) cards[c.id] = cur.copyWith(contentOrder: order);
        _notify();
        await api.deleteBlock(boardId, b.id);
        if (reorder) await api.patchCard(c.id, contentOrder: order);
      });

  Future<void> reorderContent(TaskCard c, List<String> order) => _write(() async {
        cards[c.id] = (cards[c.id] ?? c).copyWith(contentOrder: order);
        _notify();
        await api.patchCard(c.id, contentOrder: order);
      });

  Future<void> addComment(TaskCard c, String text) => _write(() async {
        final made = await api.insertBlocks(boardId, [BoardBlock.make(boardId, c.id, 'comment', title: text)]);
        for (final b in made) {
          blocks[b.id] = b;
        }
        _notify();
      });

  Future<void> deleteBlock(BoardBlock b) => _write(() async {
        blocks.remove(b.id);
        _notify();
        await api.deleteBlock(boardId, b.id);
      });

  // ---------------------------------------------------------------- thành viên

  Future<void> reloadMembers() async {
    members = await api.members(boardId);
    _notify();
  }

  Future<void> addMember(String userId, String role) => _write(() async {
        await api.addMember(boardId, userId, role);
        await reloadMembers();
      });

  Future<void> setMemberRole(String userId, String role) => _write(() async {
        await api.setMemberRole(boardId, userId, role);
        await reloadMembers();
      });

  Future<void> removeMember(String userId) => _write(() async {
        members = members.where((m) => m.userId != userId).toList();
        _notify();
        await api.removeMember(boardId, userId);
      });
}
