import 'dart:convert';
import 'dart:math';

import '../config.dart';
import 'mm_api.dart';

/// Phương án của thuộc tính select (id, tên, màu kiểu `propColorBlue`).
class PropOption {
  final String id, value, color;
  const PropOption(this.id, this.value, this.color);
  factory PropOption.fromJson(Map m) => PropOption('${m['id'] ?? ''}', '${m['value'] ?? ''}', '${m['color'] ?? ''}');
  Map<String, dynamic> toJson() => {'id': id, 'value': value, 'color': color};
}

/// Thuộc tính thẻ của bảng: select / multiSelect / person / multiPerson / date / text...
class PropTemplate {
  final String id, name, type;
  final List<PropOption> options;
  const PropTemplate(this.id, this.name, this.type, [this.options = const []]);
  factory PropTemplate.fromJson(Map m) => PropTemplate('${m['id'] ?? ''}', '${m['name'] ?? ''}', '${m['type'] ?? ''}',
      [for (final o in (m['options'] as List? ?? const [])) PropOption.fromJson(o as Map)]);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type, 'options': [for (final o in options) o.toJson()]};
  String optionName(Object? id) => options.where((o) => o.id == id).firstOrNull?.value ?? '';
}

/// Bảng (board) của plugin Boards.
class TaskBoard {
  final String id, teamId, type, title, icon, minimumRole;
  final List<PropTemplate> props;
  const TaskBoard(this.id, this.teamId, this.type, this.title, this.icon, this.minimumRole, this.props);
  factory TaskBoard.fromJson(Map m) => TaskBoard('${m['id']}', '${m['teamId'] ?? ''}', '${m['type'] ?? 'P'}', '${m['title'] ?? ''}',
      '${m['icon'] ?? ''}', '${m['minimumRole'] ?? ''}', [for (final p in (m['cardProperties'] as List? ?? const [])) PropTemplate.fromJson(p as Map)]);

  bool get isOpen => type == 'O';

  /// Trạng thái: select tên "status / trạng thái", không có thì select đầu tiên không phải ưu tiên.
  PropTemplate? get status {
    final sel = props.where((p) => p.type == 'select').toList();
    return sel.where((p) => RegExp(r'status|trang thai|tinh trang').hasMatch(normText(p.name))).firstOrNull ??
        sel.where((p) => !RegExp(r'priority|uu tien').hasMatch(normText(p.name))).firstOrNull;
  }

  PropTemplate? get priority =>
      props.where((p) => p.type == 'select' && RegExp(r'priority|uu tien|muc do').hasMatch(normText(p.name))).firstOrNull;

  /// Người làm: multiPerson trước rồi person, bỏ qua thuộc tính "người giao".
  PropTemplate? get assignee {
    final ppl = props.where((p) => p.type == 'multiPerson' || p.type == 'person').toList();
    final work = ppl.where((p) => !RegExp(r'giao|reporter|requester|owner').hasMatch(normText(p.name))).toList();
    return work.where((p) => p.type == 'multiPerson').firstOrNull ?? work.firstOrNull ?? ppl.firstOrNull;
  }

  PropTemplate? get due {
    final ds = props.where((p) => p.type == 'date').toList();
    return ds.where((p) => RegExp(r'due|han|deadline|ngay').hasMatch(normText(p.name))).firstOrNull ?? ds.firstOrNull;
  }

  /// Mọi người có trong các thuộc tính person / multiPerson của thẻ.
  Set<String> people(TaskCard c) => {
        for (final p in props)
          if (p.type == 'person' || p.type == 'multiPerson') ...c.list(p.id),
      };
}

/// Thẻ (card) = một việc.
class TaskCard {
  final String id, boardId, title, icon, createdBy;
  final Map<String, dynamic> properties;
  final List<String> contentOrder;
  final int updateAt;
  const TaskCard(this.id, this.boardId, this.title, this.icon, this.createdBy, this.properties, this.contentOrder, this.updateAt);
  factory TaskCard.fromJson(Map m) => TaskCard('${m['id']}', '${m['boardId'] ?? ''}', '${m['title'] ?? ''}', '${m['icon'] ?? ''}',
      '${m['createdBy'] ?? ''}', ((m['properties'] as Map?) ?? const {}).cast<String, dynamic>(),
      [for (final x in (m['contentOrder'] as List? ?? const [])) if (x is String) x], (m['updateAt'] as num?)?.toInt() ?? 0);

  List<String> list(String propId) {
    final v = properties[propId];
    return v is List ? [for (final x in v) '$x'] : v is String && v.isNotEmpty ? [v] : const [];
  }

  String? str(String propId) => properties[propId] is String ? properties[propId] as String : null;

  /// Ngày của thuộc tính date ({"from": ms}, ngày không kèm giờ lưu ở 00:00 UTC) theo lịch địa phương.
  DateTime? date(String? propId) {
    final v = propId == null ? null : properties[propId];
    if (v is! String || v.isEmpty) return null;
    try {
      final j = jsonDecode(v) as Map;
      final ms = (j['from'] ?? j['to']) as num?;
      if (ms == null) return null;
      final u = DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
      return j['includeTime'] == true ? u.toLocal() : DateTime(u.year, u.month, u.day);
    } catch (_) {
      return null;
    }
  }
}

/// Bỏ dấu, chữ thường: so tên thuộc tính / phương án không phụ thuộc cách gõ.
String normText(String s) {
  const from = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
  const to = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().trim().split('')) {
    final i = from.indexOf(ch);
    b.write(i < 0 ? ch : to[i]);
  }
  return b.toString();
}

/// Phương án "xong" (để không tính quá hạn, xếp cuối).
bool isDoneStatus(String name) =>
    RegExp(r'^(xong|hoan thanh|da xong|done|completed?|closed|finished|完了|完成|已完成|완료|เสร็จ|เสร็จแล้ว)$').hasMatch(normText(name));

/// Giá trị thuộc tính date cho một ngày (00:00 UTC của ngày đó, như giao diện web).
String dateValue(DateTime d) => jsonEncode({'from': DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch});

const _b32 = 'ybndrfg8ejkmcpqxot1uwisza345h769';
final _rnd = Random.secure();

/// Id kiểu Boards: tiền tố loại (a = block, v = view) + 26 ký tự base32.
String newBoardsId([String prefix = 'a']) => prefix + List.generate(26, (_) => _b32[_rnd.nextInt(32)]).join();

/// Client plugin Boards (id `focalboard`) của máy chủ chat, dùng phiên đăng nhập của app.
/// Lưu ý: PATCH thẻ với updatedProperties THAY CẢ bộ thuộc tính -> luôn gửi bộ đầy đủ.
class BoardsApi {
  static const base = '/plugins/focalboard/api/v2';
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

  /// Bảng của team mà mình thấy: bảng mở của team + bảng mình là thành viên.
  Future<List<TaskBoard>> teamBoards(String teamId) async {
    final r = await api.get('$base/teams/$teamId/boards') as List? ?? const [];
    return [
      for (final m in r)
        if ((m as Map)['isTemplate'] != true && ((m['deleteAt'] as num?) ?? 0) == 0) TaskBoard.fromJson(m),
    ];
  }

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

  /// Id view đầu tiên của bảng (đường dẫn mở thẻ trên web cần id view).
  Future<String> firstViewId(String boardId) async {
    final r = await api.get('$base/boards/$boardId/blocks', {'type': 'view'}) as List? ?? const [];
    return r.isEmpty ? '' : '${(r.first as Map)['id']}';
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
    final views = await api.post('$base/boards/${b.id}/blocks', [
      {
        'id': newBoardsId('v'), 'boardId': b.id, 'parentId': b.id, 'schema': 1, 'type': 'view', 'title': viewName,
        'createAt': now, 'updateAt': now, 'deleteAt': 0,
        'fields': {
          'viewType': 'board', 'groupById': status.id, 'sortOptions': [], 'visiblePropertyIds': [for (final p in props.skip(1)) p.id],
          'visibleOptionIds': [], 'hiddenOptionIds': [], 'collapsedOptionIds': [], 'filter': {'operation': 'and', 'filters': []},
          'cardOrder': [], 'columnWidths': {}, 'columnCalculations': {}, 'kanbanCalculations': {}, 'defaultTemplateId': '',
        },
      }
    ]) as List? ?? const [];
    return (b, views.isEmpty ? '' : '${(views.first as Map)['id']}');
  }

  /// Thêm thành viên (quyền sửa thẻ) để người được giao thấy bảng riêng tư.
  Future<void> addMember(String boardId, String userId) => api.post('$base/boards/$boardId/members',
      {'boardId': boardId, 'userId': userId, 'schemeEditor': true, 'schemeAdmin': false, 'schemeCommenter': false, 'schemeViewer': false});

  Future<TaskCard> createCard(String boardId, String title, Map<String, dynamic> properties) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return TaskCard.fromJson(await api.post('$base/boards/$boardId/cards', {
      'boardId': boardId, 'title': title, 'icon': '', 'properties': properties, 'contentOrder': [],
      'isTemplate': false, 'createAt': now, 'updateAt': now, 'deleteAt': 0,
    }) as Map);
  }

  /// Sửa thẻ: [properties] là BỘ ĐẦY ĐỦ sau khi sửa.
  Future<TaskCard> patchCard(String cardId, {String? title, Map<String, dynamic>? properties, List<String>? contentOrder}) async =>
      TaskCard.fromJson(await api.patch('$base/cards/$cardId', {
        'title': ?title,
        'updatedProperties': ?properties,
        'contentOrder': ?contentOrder,
      }) as Map);

  /// Mô tả của thẻ: khối chữ (markdown) gắn vào thẻ.
  Future<void> addDescription(TaskCard card, String text) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = await api.post('$base/boards/${card.boardId}/blocks', [
      {
        'id': newBoardsId(), 'boardId': card.boardId, 'parentId': card.id, 'schema': 1, 'type': 'text', 'title': text,
        'fields': {}, 'createAt': now, 'updateAt': now, 'deleteAt': 0,
      }
    ]) as List? ?? const [];
    if (r.isNotEmpty) await patchCard(card.id, contentOrder: [...card.contentOrder, '${(r.first as Map)['id']}']);
  }

  /// Trang web của Boards: cả ứng dụng, một bảng, hoặc một thẻ (cần id view).
  static String webUrl({String? teamId, String? boardId, String? viewId, String? cardId}) {
    if (teamId == null || boardId == null) return '$kServerUrl/boards';
    final v = viewId == null || viewId.isEmpty ? '' : '/$viewId${cardId == null ? '' : '/$cardId'}';
    return '$kServerUrl/boards/team/$teamId/$boardId$v';
  }
}
