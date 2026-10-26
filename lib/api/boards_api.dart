import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'boards_models.dart';
import 'mm_api.dart';

export 'boards_models.dart';

/// Sự kiện websocket của plugin Boards (`custom_focalboard_*`), AppState chuyển vào đây cho các màn hình đang mở.
/// [data] = payload của plugin: `action` (UPDATE_BLOCK / UPDATE_BOARD / UPDATE_MEMBER / DELETE_MEMBER / UPDATE_CATEGORY...),
/// `teamId`, và `block` / `board` / `member` / `category`...
class BoardsEvent {
  final String event;
  final Map<String, dynamic> data;
  const BoardsEvent(this.event, this.data);
  String get action => '${data['action'] ?? ''}';
  Map<String, dynamic>? get block => (data['block'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get board => (data['board'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get member => (data['member'] as Map?)?.cast<String, dynamic>();
}

/// Kết quả nhân bản / tạo từ mẫu: các bảng và khối mới.
class BoardsAndBlocks {
  final List<TaskBoard> boards;
  final List<BoardBlock> blocks;
  const BoardsAndBlocks(this.boards, this.blocks);
  factory BoardsAndBlocks.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    return BoardsAndBlocks([for (final b in (m['boards'] as List? ?? const [])) TaskBoard.fromJson(b as Map)],
        [for (final b in (m['blocks'] as List? ?? const [])) BoardBlock.fromJson(b as Map)]);
  }
}

/// Thông tin tệp đính kèm của Boards.
class BoardsFileInfo {
  final String name, extension;
  final int size;
  const BoardsFileInfo(this.name, this.extension, this.size);
  factory BoardsFileInfo.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    return BoardsFileInfo('${m['name'] ?? ''}', '${m['extension'] ?? ''}', (m['size'] as num?)?.toInt() ?? 0);
  }
}

/// Client plugin Boards (id `focalboard`) của máy chủ chat, dùng phiên đăng nhập của app.
/// Lưu ý: PATCH thẻ với updatedProperties THAY CẢ bộ thuộc tính (plugin 9.x) -> luôn gửi bộ đầy đủ.
class BoardsApi {
  static const base = '/plugins/focalboard/api/v2';

  /// Tiền tố tên sự kiện websocket của plugin.
  static const wsPrefix = 'custom_focalboard_';

  /// Luồng sự kiện realtime (AppState đẩy vào).
  static final events = StreamController<BoardsEvent>.broadcast();

  final MmApi api;
  BoardsApi(this.api);

  /// Máy chủ có plugin Boards đang chạy không (404 = không có / chưa bật).
  Future<bool> available() async {
    try {
      await api.get('$base/teams');
      return true;
    } on ApiException catch (e) {
      if (e.status == 404) return false;
      rethrow;
    }
  }

  // ---------------------------------------------------------------- bảng

  /// Bảng của team mà mình thấy: bảng mở của team + bảng mình là thành viên.
  Future<List<TaskBoard>> teamBoards(String teamId) async {
    final r = await api.get('$base/teams/$teamId/boards') as List? ?? const [];
    return [
      for (final m in r)
        if ((m as Map)['isTemplate'] != true && ((m['deleteAt'] as num?) ?? 0) == 0) TaskBoard.fromJson(m),
    ];
  }

  Future<TaskBoard> board(String boardId) async => TaskBoard.fromJson(await api.get('$base/boards/$boardId') as Map);

  /// Mẫu bảng: mẫu riêng của team + mẫu có sẵn của plugin (team "0").
  Future<List<TaskBoard>> templates(String teamId) async {
    final out = <TaskBoard>[];
    for (final t in [teamId, '0']) {
      try {
        final r = await api.get('$base/teams/$t/templates') as List? ?? const [];
        out.addAll([for (final m in r) TaskBoard.fromJson(m as Map)]);
      } on ApiException catch (_) {}
    }
    return out;
  }

  /// Tạo bảng trống có một view (mặc định Kanban nhóm theo thuộc tính select đầu tiên).
  Future<(TaskBoard, String)> createBlankBoard(String teamId, String title,
      {String icon = '', bool open = true, List<PropTemplate> props = const [], String viewName = 'Board view', String viewType = 'board'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = TaskBoard.fromJson(await api.post('$base/boards', {
      'teamId': teamId, 'channelId': '', 'type': open ? 'O' : 'P', 'minimumRole': open ? 'editor' : '', 'title': title,
      'description': '', 'icon': icon, 'showDescription': false, 'isTemplate': false, 'templateVersion': 0, 'properties': {},
      'cardProperties': [for (final p in props) p.toJson()], 'createAt': now, 'updateAt': now, 'deleteAt': 0,
    }) as Map);
    final group = props.where((p) => p.type == 'select').firstOrNull;
    final views = await insertBlocks(b.id, [
      BoardBlock.make(b.id, b.id, 'view', title: viewName, fields: BoardView.defaultFields(viewType, groupById: group?.id)),
    ]);
    return (b, views.isEmpty ? '' : views.first.id);
  }

  /// Tạo bảng việc mở cho cả team (ai trong team cũng vào và sửa được), có sẵn Trạng thái / Người làm / Hạn / Ưu tiên và
  /// một view Kanban nhóm theo trạng thái. [names]: tên thuộc tính theo ngôn ngữ của người tạo.
  Future<(TaskBoard, String)> createBoard(String teamId, String title,
      {required String statusName,
      required String assigneeName,
      required String dueName,
      required String priorityName,
      required List<(String, String)> statuses,
      required List<(String, String)> priorities,
      String viewName = 'Kanban'}) async {
    List<PropOption> opts(List<(String, String)> l) => [for (final (v, c) in l) PropOption(newBoardsId(), v, c)];
    final status = PropTemplate(newBoardsId(), statusName, 'select', opts(statuses));
    final props = [
      status,
      PropTemplate(newBoardsId(), assigneeName, 'multiPerson'),
      PropTemplate(newBoardsId(), dueName, 'date'),
      PropTemplate(newBoardsId(), priorityName, 'select', opts(priorities)),
    ];
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = TaskBoard.fromJson(await api.post('$base/boards', {
      'teamId': teamId, 'channelId': '', 'type': 'O', 'minimumRole': 'editor', 'title': title, 'description': '', 'icon': '📋',
      'showDescription': false, 'isTemplate': false, 'templateVersion': 0, 'properties': {},
      'cardProperties': [for (final p in props) p.toJson()], 'createAt': now, 'updateAt': now, 'deleteAt': 0,
    }) as Map);
    final views = await insertBlocks(b.id, [
      BoardBlock.make(b.id, b.id, 'view',
          title: viewName, fields: BoardView.defaultFields('board', groupById: status.id, visible: [for (final p in props.skip(1)) p.id])),
    ]);
    return (b, views.isEmpty ? '' : views.first.id);
  }

  /// Sửa bảng. [updatedProps]: thuộc tính thêm / sửa (giữ thứ tự cũ, mới thêm ở cuối); [deletedProps]: id thuộc tính bỏ.
  Future<TaskBoard> patchBoard(String boardId,
      {String? title,
      String? icon,
      String? description,
      bool? showDescription,
      String? type,
      String? minimumRole,
      List<PropTemplate>? updatedProps,
      List<String>? deletedProps}) async =>
      TaskBoard.fromJson(await api.patch('$base/boards/$boardId', {
        'title': ?title,
        'icon': ?icon,
        'description': ?description,
        'showDescription': ?showDescription,
        'type': ?type,
        'minimumRole': ?minimumRole,
        if (updatedProps != null) 'updatedCardProperties': [for (final p in updatedProps) p.toJson()],
        'deletedCardProperties': ?deletedProps,
      }) as Map);

  /// Đổi thứ tự thuộc tính: máy chủ giữ thứ tự cũ khi sửa, nên bỏ hết rồi thêm lại theo thứ tự mới (giá trị trên thẻ giữ nguyên
  /// vì gắn theo id). Lần hai lỗi thì thử lại một lần để không mất thuộc tính.
  Future<TaskBoard> reorderProps(String boardId, List<PropTemplate> ordered) async {
    await patchBoard(boardId, deletedProps: [for (final p in ordered) p.id]);
    try {
      return await patchBoard(boardId, updatedProps: ordered);
    } catch (_) {
      return patchBoard(boardId, updatedProps: ordered);
    }
  }

  Future<void> deleteBoard(String boardId) => api.delete('$base/boards/$boardId');

  /// Nhân bản bảng (cả view, thẻ, nội dung); với mẫu (`asTemplate` = false) là tạo bảng mới từ mẫu vào [toTeam].
  Future<BoardsAndBlocks> duplicateBoard(String boardId, {bool asTemplate = false, String? toTeam}) async =>
      BoardsAndBlocks.fromJson(
          await api.post('$base/boards/$boardId/duplicate?asTemplate=$asTemplate${toTeam == null ? '' : '&toTeam=$toTeam'}', null));

  // ---------------------------------------------------------------- nhóm bảng (thanh bên)

  Future<List<BoardCategory>> categories(String teamId) async {
    final r = await api.get('$base/teams/$teamId/categories') as List? ?? const [];
    return [for (final m in r) if ((m as Map)['deleteAt'] == null || m['deleteAt'] == 0) BoardCategory.fromJson(m)]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  Future<void> createCategory(String teamId, String userId, String name) => api.post('$base/teams/$teamId/categories', {
        'name': name, 'userID': userId, 'teamID': teamId, 'type': 'custom', 'collapsed': false,
        'createAt': DateTime.now().millisecondsSinceEpoch, 'updateAt': DateTime.now().millisecondsSinceEpoch, 'deleteAt': 0,
      });

  Future<void> updateCategory(String teamId, String userId, BoardCategory c, {String? name, bool? collapsed}) =>
      api.put('$base/teams/$teamId/categories/${c.id}', {
        'id': c.id, 'name': name ?? c.name, 'userID': userId, 'teamID': teamId, 'type': c.type, 'collapsed': collapsed ?? c.collapsed,
        'sortOrder': c.sortOrder, 'updateAt': DateTime.now().millisecondsSinceEpoch, 'deleteAt': 0,
      });

  Future<void> deleteCategory(String teamId, String categoryId) => api.delete('$base/teams/$teamId/categories/$categoryId');

  Future<void> moveBoardToCategory(String teamId, String boardId, String toCategoryId, String fromCategoryId) =>
      api.post('$base/teams/$teamId/categories/$toCategoryId/boards/$boardId', {'fromCategoryID': fromCategoryId});

  // ---------------------------------------------------------------- khối (view, thẻ, nội dung, bình luận)

  /// Mọi khối của bảng (view, thẻ, nội dung, bình luận) trong một lần gọi.
  Future<List<BoardBlock>> allBlocks(String boardId) async {
    final r = await api.get('$base/boards/$boardId/blocks', {'all': 'true'}) as List? ?? const [];
    return [for (final m in r) BoardBlock.fromJson(m as Map)];
  }

  Future<List<BoardBlock>> blocks(String boardId, {String? type, String? parentId}) async {
    final r = await api.get('$base/boards/$boardId/blocks', {'type': ?type, 'parent_id': ?parentId}) as List? ?? const [];
    return [for (final m in r) BoardBlock.fromJson(m as Map)];
  }

  Future<List<BoardBlock>> insertBlocks(String boardId, List<Map<String, dynamic>> blocks) async {
    final r = await api.post('$base/boards/$boardId/blocks', blocks) as List? ?? const [];
    return [for (final m in r) BoardBlock.fromJson(m as Map)];
  }

  Future<void> patchBlock(String boardId, String blockId, {String? title, Map<String, dynamic>? updatedFields, List<String>? deletedFields}) =>
      api.patch('$base/boards/$boardId/blocks/$blockId', {
        'title': ?title,
        'updatedFields': ?updatedFields,
        'deletedFields': ?deletedFields,
      });

  Future<void> deleteBlock(String boardId, String blockId) => api.delete('$base/boards/$boardId/blocks/$blockId');

  /// Nhân bản một khối và các khối con (thẻ kèm nội dung, view...). Trả về các khối mới (khối gốc đứng đầu).
  Future<List<BoardBlock>> duplicateBlock(String boardId, String blockId) async {
    final r = await api.post('$base/boards/$boardId/blocks/$blockId/duplicate', null) as List? ?? const [];
    return [for (final m in r) BoardBlock.fromJson(m as Map)];
  }

  /// Id view đầu tiên của bảng (đường dẫn mở thẻ trên web cần id view).
  Future<String> firstViewId(String boardId) async {
    final r = await blocks(boardId, type: 'view');
    return r.isEmpty ? '' : r.first.id;
  }

  // ---------------------------------------------------------------- thẻ

  Future<List<TaskCard>> cards(String boardId) async {
    final out = <TaskCard>[];
    for (var page = 0; page < 30; page++) {
      final r = await api.get('$base/boards/$boardId/cards', {'page': '$page', 'per_page': '100'}) as List? ?? const [];
      for (final m in r) {
        if ((m as Map)['isTemplate'] != true && ((m['deleteAt'] as num?) ?? 0) == 0) out.add(TaskCard.fromJson(m));
      }
      if (r.length < 100) break;
    }
    return out;
  }

  Future<TaskCard> card(String cardId) async => TaskCard.fromJson(await api.get('$base/cards/$cardId') as Map);

  Future<TaskCard> createCard(String boardId, String title, Map<String, dynamic> properties, {String icon = ''}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return TaskCard.fromJson(await api.post('$base/boards/$boardId/cards', {
      'boardId': boardId, 'title': title, 'icon': icon, 'properties': properties, 'contentOrder': [],
      'isTemplate': false, 'createAt': now, 'updateAt': now, 'deleteAt': 0,
    }) as Map);
  }

  /// Sửa thẻ: [properties] là BỘ ĐẦY ĐỦ sau khi sửa.
  Future<TaskCard> patchCard(String cardId, {String? title, String? icon, Map<String, dynamic>? properties, List<String>? contentOrder}) async =>
      TaskCard.fromJson(await api.patch('$base/cards/$cardId', {
        'title': ?title,
        'icon': ?icon,
        'updatedProperties': ?properties,
        'contentOrder': ?contentOrder,
      }) as Map);

  /// Mô tả của thẻ: khối chữ (markdown) gắn vào thẻ.
  Future<void> addDescription(TaskCard card, String text) async {
    final r = await insertBlocks(card.boardId, [BoardBlock.make(card.boardId, card.id, 'text', title: text)]);
    if (r.isNotEmpty) await patchCard(card.id, contentOrder: [...card.contentOrder, r.first.id]);
  }

  // ---------------------------------------------------------------- thành viên

  Future<List<BoardMember>> members(String boardId) async {
    final r = await api.get('$base/boards/$boardId/members') as List? ?? const [];
    return [for (final m in r) BoardMember.fromJson(m as Map)];
  }

  /// Quyền của mình trên mọi bảng (để biết được sửa / quản trị hay chỉ xem).
  Future<List<BoardMember>> myMemberships() async {
    final r = await api.get('$base/users/me/memberships') as List? ?? const [];
    return [for (final m in r) BoardMember.fromJson(m as Map)];
  }

  /// Thêm thành viên (mặc định quyền sửa thẻ) để người được giao thấy bảng riêng tư.
  Future<void> addMember(String boardId, String userId, [String role = 'editor']) =>
      api.post('$base/boards/$boardId/members', BoardMember.roleJson(boardId, userId, role));

  Future<void> setMemberRole(String boardId, String userId, String role) =>
      api.put('$base/boards/$boardId/members/$userId', BoardMember.roleJson(boardId, userId, role));

  Future<void> removeMember(String boardId, String userId) => api.delete('$base/boards/$boardId/members/$userId');

  /// Vào một bảng mở của team (thành viên thật thay cho thành viên ngầm).
  Future<void> join(String boardId) => api.post('$base/boards/$boardId/join', null);
  Future<void> leave(String boardId) => api.post('$base/boards/$boardId/leave', null);

  // ---------------------------------------------------------------- tệp

  String fileUrl(String teamId, String boardId, String fileId) => '$kServerUrl$base/files/teams/$teamId/$boardId/$fileId';

  /// Tải tệp lên bảng (ảnh / đính kèm), trả về id tệp để gắn vào khối `image` / `attachment`.
  Future<String> uploadFile(String teamId, String boardId, String name, Uint8List bytes) async {
    final req = http.MultipartRequest('POST', Uri.parse('$kServerUrl$base/teams/$teamId/$boardId/files'))
      ..headers.addAll(api.headers)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return '${(jsonDecode(res.body) as Map)['fileId'] ?? ''}';
  }

  Future<BoardsFileInfo> fileInfo(String teamId, String boardId, String fileId) async =>
      BoardsFileInfo.fromJson(await api.get('$base/files/teams/$teamId/$boardId/$fileId/info'));

  Future<Uint8List> fileBytes(String teamId, String boardId, String fileId) async {
    final res = await http.get(Uri.parse(fileUrl(teamId, boardId, fileId)), headers: api.headers);
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res.bodyBytes;
  }

  // ---------------------------------------------------------------- liên kết

  /// Trang web của Boards: cả ứng dụng, một bảng, hoặc một thẻ (cần id view). Dùng làm link chia sẻ; trong app link này mở màn
  /// hình gốc của app.
  static String webUrl({String? teamId, String? boardId, String? viewId, String? cardId}) {
    if (teamId == null || boardId == null) return '$kServerUrl/boards';
    final v = viewId == null || viewId.isEmpty ? '' : '/$viewId${cardId == null ? '' : '/$cardId'}';
    return '$kServerUrl/boards/team/$teamId/$boardId$v';
  }
}

/// Link thuộc giao diện Boards của máy chủ đang dùng (`<máy chủ>/boards...`).
bool isBoardsUrl(Uri u) {
  final s = Uri.tryParse(kServerUrl);
  return s != null && u.host == s.host && (u.path == '/boards' || u.path.startsWith('/boards/'));
}

/// Tách link Boards: `/boards/team/<team>/<bảng>[/<view>[/<thẻ>]]` (cả dạng `/boards/team/<team>/shared/<bảng>...`).
/// Trả về (bảng, view, thẻ); null nếu là trang chính của Boards.
(String, String?, String?)? parseBoardsPath(Uri u) {
  final seg = u.pathSegments.where((s) => s.isNotEmpty).toList();
  final i = seg.indexOf('team');
  if (i < 0 || seg.length < i + 3) return null;
  var rest = seg.sublist(i + 2);
  if (rest.first == 'shared') rest = rest.sublist(1);
  if (rest.isEmpty) return null;
  return (rest[0], rest.length > 1 ? rest[1] : null, rest.length > 2 ? rest[2] : null);
}
