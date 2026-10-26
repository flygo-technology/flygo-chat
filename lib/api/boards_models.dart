import 'dart:convert';
import 'dart:math';

/// Mô hình dữ liệu của plugin Boards (id `focalboard`): bảng, thuộc tính, thẻ, khối (view / nội dung / bình luận),
/// thành viên, nhóm bảng ở thanh bên. Đọc theo JSON của API v2 của plugin.

List<String> _strs(Object? v) => [for (final x in (v as List? ?? const [])) if (x is String) x];
int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// Phương án của thuộc tính select (id, tên, màu kiểu `propColorBlue`).
class PropOption {
  final String id, value, color;
  const PropOption(this.id, this.value, this.color);
  factory PropOption.fromJson(Map m) => PropOption('${m['id'] ?? ''}', '${m['value'] ?? ''}', '${m['color'] ?? ''}');
  Map<String, dynamic> toJson() => {'id': id, 'value': value, 'color': color};
  PropOption copyWith({String? value, String? color}) => PropOption(id, value ?? this.value, color ?? this.color);
}

/// Các loại thuộc tính thẻ mà Boards hỗ trợ.
const boardPropTypes = [
  'text', 'number', 'select', 'multiSelect', 'date', 'person', 'multiPerson', 'checkbox', 'url', 'email', 'phone',
  'createdTime', 'createdBy', 'updatedTime', 'updatedBy',
];

/// Thuộc tính thẻ của bảng: select / multiSelect / person / multiPerson / date / text...
class PropTemplate {
  final String id, name, type;
  final List<PropOption> options;
  const PropTemplate(this.id, this.name, this.type, [this.options = const []]);
  factory PropTemplate.fromJson(Map m) => PropTemplate('${m['id'] ?? ''}', '${m['name'] ?? ''}', '${m['type'] ?? ''}',
      [for (final o in (m['options'] as List? ?? const [])) PropOption.fromJson(o as Map)]);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type, 'options': [for (final o in options) o.toJson()]};
  PropTemplate copyWith({String? name, String? type, List<PropOption>? options}) =>
      PropTemplate(id, name ?? this.name, type ?? this.type, options ?? this.options);
  String optionName(Object? id) => options.where((o) => o.id == id).firstOrNull?.value ?? '';
  PropOption? option(Object? id) => options.where((o) => o.id == id).firstOrNull;

  /// Thuộc tính máy chủ tự điền (ngày tạo / người sửa...), không sửa được.
  bool get readOnly => type == 'createdTime' || type == 'createdBy' || type == 'updatedTime' || type == 'updatedBy';
  bool get isSelect => type == 'select' || type == 'multiSelect';
  bool get isPerson => type == 'person' || type == 'multiPerson' || type == 'createdBy' || type == 'updatedBy';
  bool get isDate => type == 'date' || type == 'createdTime' || type == 'updatedTime';
}

/// Bảng (board) của plugin Boards.
class TaskBoard {
  final String id, teamId, channelId, type, title, description, icon, minimumRole, createdBy;
  final bool showDescription, isTemplate;
  final List<PropTemplate> props;
  final Map<String, dynamic> properties;
  final int createAt, updateAt, deleteAt;
  const TaskBoard(this.id, this.teamId, this.type, this.title, this.icon, this.minimumRole, this.props,
      {this.channelId = '',
      this.description = '',
      this.createdBy = '',
      this.showDescription = false,
      this.isTemplate = false,
      this.properties = const {},
      this.createAt = 0,
      this.updateAt = 0,
      this.deleteAt = 0});
  factory TaskBoard.fromJson(Map m) => TaskBoard('${m['id']}', '${m['teamId'] ?? ''}', '${m['type'] ?? 'P'}', '${m['title'] ?? ''}',
      '${m['icon'] ?? ''}', '${m['minimumRole'] ?? ''}', [for (final p in (m['cardProperties'] as List? ?? const [])) PropTemplate.fromJson(p as Map)],
      channelId: '${m['channelId'] ?? ''}',
      description: '${m['description'] ?? ''}',
      createdBy: '${m['createdBy'] ?? ''}',
      showDescription: m['showDescription'] == true,
      isTemplate: m['isTemplate'] == true,
      properties: ((m['properties'] as Map?) ?? const {}).cast<String, dynamic>(),
      createAt: _int(m['createAt']),
      updateAt: _int(m['updateAt']),
      deleteAt: _int(m['deleteAt']));

  TaskBoard copyWith({String? title, String? icon, String? description, bool? showDescription, String? type, String? minimumRole, List<PropTemplate>? props}) =>
      TaskBoard(id, teamId, type ?? this.type, title ?? this.title, icon ?? this.icon, minimumRole ?? this.minimumRole, props ?? this.props,
          channelId: channelId,
          description: description ?? this.description,
          createdBy: createdBy,
          showDescription: showDescription ?? this.showDescription,
          isTemplate: isTemplate,
          properties: properties,
          createAt: createAt,
          updateAt: updateAt,
          deleteAt: deleteAt);

  bool get isOpen => type == 'O';
  PropTemplate? prop(String? id) => props.where((p) => p.id == id).firstOrNull;

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

/// Giá trị thuộc tính ngày: một ngày hoặc khoảng ngày, có / không kèm giờ.
class DateProp {
  final int? from, to;
  final bool includeTime;
  const DateProp(this.from, [this.to, this.includeTime = false]);

  /// Đọc giá trị lưu trên thẻ: JSON `{"from":ms,"to":ms,"includeTime":bool}` hoặc số ms (dữ liệu cũ).
  static DateProp? parse(Object? v) {
    if (v is! String || v.isEmpty) return null;
    final n = int.tryParse(v);
    if (n != null) return DateProp(n);
    try {
      final j = jsonDecode(v) as Map;
      final f = (j['from'] as num?)?.toInt(), t = (j['to'] as num?)?.toInt();
      if (f == null && t == null) return null;
      return DateProp(f ?? t, f == null ? null : t, j['includeTime'] == true);
    } catch (_) {
      return null;
    }
  }

  /// Ngày không kèm giờ lưu ở 00:00 UTC: đổi về ngày địa phương cùng số.
  static DateTime toLocal(int ms, bool includeTime) {
    final u = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return includeTime ? u.toLocal() : DateTime(u.year, u.month, u.day);
  }

  DateTime? get start => from == null ? null : toLocal(from!, includeTime);
  DateTime? get end => to == null ? null : toLocal(to!, includeTime);

  /// Tạo giá trị từ ngày địa phương (không giờ: 00:00 UTC của ngày đó như bản web).
  static String encode(DateTime start, {DateTime? end, bool includeTime = false}) {
    int ms(DateTime d) => includeTime ? d.toUtc().millisecondsSinceEpoch : DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch;
    return jsonEncode({'from': ms(start), if (end != null) 'to': ms(end), if (includeTime) 'includeTime': true});
  }
}

/// Thẻ (card) = một việc. Đọc được cả dạng thẻ của API `/cards` lẫn dạng khối (`fields`) của API `/blocks` và websocket.
class TaskCard {
  final String id, boardId, title, icon, createdBy, modifiedBy;
  final Map<String, dynamic> properties;
  final List<String> contentOrder;
  final int createAt, updateAt, deleteAt;
  final bool isTemplate;
  const TaskCard(this.id, this.boardId, this.title, this.icon, this.createdBy, this.properties, this.contentOrder, this.updateAt,
      {this.modifiedBy = '', this.createAt = 0, this.deleteAt = 0, this.isTemplate = false});
  factory TaskCard.fromJson(Map m) {
    final f = m['fields'] is Map ? m['fields'] as Map : m;
    return TaskCard('${m['id']}', '${m['boardId'] ?? ''}', '${m['title'] ?? ''}', '${f['icon'] ?? ''}', '${m['createdBy'] ?? ''}',
        Map<String, dynamic>.from((f['properties'] as Map?) ?? const {}), _flatOrder(f['contentOrder']), _int(m['updateAt']),
        modifiedBy: '${m['modifiedBy'] ?? ''}', createAt: _int(m['createAt']), deleteAt: _int(m['deleteAt']), isTemplate: f['isTemplate'] == true);
  }

  /// Thứ tự nội dung có thể lồng mảng (khối đặt cạnh nhau trên web): làm phẳng.
  static List<String> _flatOrder(Object? v) => [
        for (final x in (v as List? ?? const []))
          if (x is String) x else if (x is List) ...x.whereType<String>(),
      ];

  TaskCard copyWith({String? title, String? icon, Map<String, dynamic>? properties, List<String>? contentOrder}) =>
      TaskCard(id, boardId, title ?? this.title, icon ?? this.icon, createdBy, properties ?? this.properties, contentOrder ?? this.contentOrder,
          DateTime.now().millisecondsSinceEpoch,
          modifiedBy: modifiedBy, createAt: createAt, deleteAt: deleteAt, isTemplate: isTemplate);

  List<String> list(String propId) {
    final v = properties[propId];
    return v is List ? [for (final x in v) '$x'] : v is String && v.isNotEmpty ? [v] : const [];
  }

  String? str(String propId) => properties[propId] is String ? properties[propId] as String : null;

  /// Ngày của thuộc tính date theo lịch địa phương (ngày bắt đầu nếu là khoảng).
  DateTime? date(String? propId) => propId == null ? null : DateProp.parse(properties[propId])?.start;
}

/// Khối chung của Boards: view, nội dung thẻ (text / checkbox / divider / image / attachment / h1..h3), bình luận.
class BoardBlock {
  final String id, boardId, parentId, type, title, createdBy, modifiedBy;
  final Map<String, dynamic> fields;
  final int createAt, updateAt, deleteAt;
  const BoardBlock(this.id, this.boardId, this.parentId, this.type, this.title, this.fields,
      {this.createdBy = '', this.modifiedBy = '', this.createAt = 0, this.updateAt = 0, this.deleteAt = 0});
  factory BoardBlock.fromJson(Map m) => BoardBlock('${m['id']}', '${m['boardId'] ?? ''}', '${m['parentId'] ?? ''}', '${m['type'] ?? ''}',
      '${m['title'] ?? ''}', Map<String, dynamic>.from((m['fields'] as Map?) ?? const {}),
      createdBy: '${m['createdBy'] ?? ''}', modifiedBy: '${m['modifiedBy'] ?? ''}',
      createAt: _int(m['createAt']), updateAt: _int(m['updateAt']), deleteAt: _int(m['deleteAt']));

  /// Khối mới để gửi lên (`POST /boards/{id}/blocks`).
  static Map<String, dynamic> make(String boardId, String parentId, String type, {String title = '', Map<String, dynamic>? fields, String? id}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': id ?? newBoardsId(type == 'view' ? 'v' : type == 'card' ? 'c' : 'a'),
      'boardId': boardId, 'parentId': parentId, 'schema': 1, 'type': type, 'title': title,
      'fields': fields ?? {}, 'createAt': now, 'updateAt': now, 'deleteAt': 0,
    };
  }

  BoardBlock copyWith({String? title, Map<String, dynamic>? fields}) => BoardBlock(id, boardId, parentId, type, title ?? this.title, fields ?? this.fields,
      createdBy: createdBy, modifiedBy: modifiedBy, createAt: createAt, updateAt: DateTime.now().millisecondsSinceEpoch, deleteAt: deleteAt);

  String get fileId => '${fields['fileId'] ?? ''}';
}

/// Điều kiện lọc: thuộc tính + phép so + giá trị (id phương án, chữ, ngày ms...).
class FilterClause {
  final String propertyId, condition;
  final List<String> values;
  const FilterClause(this.propertyId, this.condition, [this.values = const []]);
  factory FilterClause.fromJson(Map m) => FilterClause('${m['propertyId'] ?? ''}', '${m['condition'] ?? 'includes'}', _strs(m['values']));
  Map<String, dynamic> toJson() => {'propertyId': propertyId, 'condition': condition, 'values': values};
}

/// Nhóm điều kiện lọc (và / hoặc); có thể lồng nhóm (giữ nguyên khi sửa).
class FilterGroup {
  final String operation;
  final List<Object> filters; // FilterClause | FilterGroup
  const FilterGroup([this.operation = 'and', this.filters = const []]);
  factory FilterGroup.fromJson(Object? v) {
    if (v is! Map) return const FilterGroup();
    return FilterGroup(v['operation'] == 'or' ? 'or' : 'and', [
      for (final f in (v['filters'] as List? ?? const []))
        if (f is Map) f.containsKey('operation') && f.containsKey('filters') ? FilterGroup.fromJson(f) : FilterClause.fromJson(f),
    ]);
  }
  Map<String, dynamic> toJson() => {
        'operation': operation,
        'filters': [for (final f in filters) f is FilterGroup ? f.toJson() : (f as FilterClause).toJson()],
      };
  List<FilterClause> get clauses => filters.whereType<FilterClause>().toList();
  bool get isEmpty => filters.isEmpty;
}

/// Một tiêu chí sắp xếp của view (`__title` = tên thẻ).
class SortOption {
  final String propertyId;
  final bool reversed;
  const SortOption(this.propertyId, [this.reversed = false]);
  factory SortOption.fromJson(Map m) => SortOption('${m['propertyId'] ?? ''}', m['reversed'] == true);
  Map<String, dynamic> toJson() => {'propertyId': propertyId, 'reversed': reversed};
}

/// Id cột tên thẻ trong sắp xếp / cột bảng.
const kTitleColumn = '__title';

/// View của bảng (khối type `view`): Kanban (`board`), Bảng (`table`), Lịch (`calendar`), Thư viện (`gallery`).
class BoardView {
  final BoardBlock block;
  const BoardView(this.block);
  String get id => block.id;
  String get title => block.title;
  Map<String, dynamic> get f => block.fields;
  String get viewType => '${f['viewType'] ?? 'board'}';
  String? get groupById => (f['groupById'] as String?)?.isEmpty == true ? null : f['groupById'] as String?;
  String? get dateDisplayPropertyId => (f['dateDisplayPropertyId'] as String?)?.isEmpty == true ? null : f['dateDisplayPropertyId'] as String?;
  List<SortOption> get sortOptions => [for (final s in (f['sortOptions'] as List? ?? const [])) if (s is Map) SortOption.fromJson(s)];
  List<String> get visiblePropertyIds => _strs(f['visiblePropertyIds']);
  List<String> get visibleOptionIds => _strs(f['visibleOptionIds']);
  List<String> get hiddenOptionIds => _strs(f['hiddenOptionIds']);
  List<String> get collapsedOptionIds => _strs(f['collapsedOptionIds']);
  List<String> get cardOrder => _strs(f['cardOrder']);
  FilterGroup get filter => FilterGroup.fromJson(f['filter']);
  Map<String, num> get columnWidths =>
      {for (final e in ((f['columnWidths'] as Map?) ?? const {}).entries) if (e.value is num) '${e.key}': e.value as num};

  /// Trường mặc định của view mới (như bản web).
  static Map<String, dynamic> defaultFields(String viewType, {String? groupById, String? dateId, List<String> visible = const []}) => {
        'viewType': viewType, 'groupById': groupById ?? '', 'dateDisplayPropertyId': dateId ?? '', 'sortOptions': [],
        'visiblePropertyIds': visible, 'visibleOptionIds': [], 'hiddenOptionIds': [], 'collapsedOptionIds': [],
        'filter': {'operation': 'and', 'filters': []}, 'cardOrder': [], 'columnWidths': {}, 'columnCalculations': {},
        'kanbanCalculations': {}, 'defaultTemplateId': '',
      };
}

/// Vai trò trên bảng, từ cao xuống thấp.
const boardRoles = ['admin', 'editor', 'commenter', 'viewer'];

/// Thành viên của bảng và quyền (admin / editor / commenter / viewer). `synthetic`: thành viên ngầm của bảng mở cho team.
class BoardMember {
  final String boardId, userId, minimumRole;
  final bool admin, editor, commenter, viewer, synthetic;
  const BoardMember(this.boardId, this.userId,
      {this.minimumRole = '', this.admin = false, this.editor = false, this.commenter = false, this.viewer = false, this.synthetic = false});
  factory BoardMember.fromJson(Map m) => BoardMember('${m['boardId'] ?? ''}', '${m['userId'] ?? ''}',
      minimumRole: '${m['minimumRole'] ?? ''}',
      admin: m['schemeAdmin'] == true,
      editor: m['schemeEditor'] == true,
      commenter: m['schemeCommenter'] == true,
      viewer: m['schemeViewer'] == true,
      synthetic: m['synthetic'] == true);

  /// Vai trò cao nhất (tính cả quyền tối thiểu của bảng).
  String get role {
    if (admin) return 'admin';
    if (editor || minimumRole == 'editor') return 'editor';
    if (commenter || minimumRole == 'commenter') return 'commenter';
    return 'viewer';
  }

  static Map<String, dynamic> roleJson(String boardId, String userId, String role) => {
        'boardId': boardId, 'userId': userId,
        'schemeAdmin': role == 'admin',
        'schemeEditor': role == 'admin' || role == 'editor',
        'schemeCommenter': role != 'viewer',
        'schemeViewer': true,
      };
}

/// Quyền làm gì trên bảng theo vai trò.
bool roleAtLeast(String role, String need) {
  final a = boardRoles.indexOf(role), b = boardRoles.indexOf(need);
  return a >= 0 && b >= 0 && a <= b;
}

/// Nhóm bảng ở thanh bên của người dùng (mỗi người tự xếp), kèm id bảng theo thứ tự và bảng bị ẩn.
class BoardCategory {
  final String id, name, type;
  final bool collapsed;
  final int sortOrder;
  final List<String> boardIds;
  final Set<String> hidden;
  const BoardCategory(this.id, this.name, this.type, this.collapsed, this.sortOrder, this.boardIds, this.hidden);
  factory BoardCategory.fromJson(Map m) {
    final meta = [for (final x in (m['boardMetadata'] as List? ?? const [])) if (x is Map) x];
    return BoardCategory('${m['id'] ?? ''}', '${m['name'] ?? ''}', '${m['type'] ?? ''}', m['collapsed'] == true, _int(m['sortOrder']),
        [for (final x in meta) '${x['boardID']}'], {for (final x in meta) if (x['hidden'] == true) '${x['boardID']}'});
  }
  bool get isSystem => type == 'system';
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
String dateValue(DateTime d) => DateProp.encode(d);

const _b32 = 'ybndrfg8ejkmcpqxot1uwisza345h769';
final _rnd = Random.secure();

/// Id kiểu Boards: tiền tố loại (a = block, v = view, c = card, b = board) + 26 ký tự base32.
String newBoardsId([String prefix = 'a']) => prefix + List.generate(26, (_) => _b32[_rnd.nextInt(32)]).join();

// ---------------------------------------------------------------- lọc & sắp xếp thẻ theo view (như bản web)

/// Giá trị dùng để lọc / sắp xếp: thuộc tính tự điền lấy từ thẻ.
Object? cardValue(TaskCard c, PropTemplate? t, String propId) {
  if (propId == 'title' || propId == kTitleColumn) return c.title;
  switch (t?.type) {
    case 'createdBy':
      return c.createdBy;
    case 'updatedBy':
      return c.modifiedBy.isEmpty ? c.createdBy : c.modifiedBy;
    case 'createdTime':
      return '${c.createAt}';
    case 'updatedTime':
      return '${c.updateAt}';
  }
  return c.properties[propId];
}

const _halfDay = 12 * 60 * 60 * 1000;

bool _clauseMet(FilterClause f, List<PropTemplate> props, TaskCard c) {
  final t = props.where((p) => p.id == f.propertyId).firstOrNull;
  var value = cardValue(c, t, f.propertyId);
  if (f.propertyId == 'title') value = c.title.toLowerCase();
  final isDate = t?.isDate == true;
  final dv = isDate ? DateProp.parse(value) : null;
  final s = value is String ? value : '';
  final first = f.values.firstOrNull ?? '';
  bool has(String x) => value is List ? value.contains(x) : value == x;
  switch (f.condition) {
    case 'includes':
      return f.values.isEmpty || f.values.any(has);
    case 'notIncludes':
      return f.values.isEmpty || !f.values.any(has);
    case 'isEmpty':
      return value == null || (value is List ? value.isEmpty : '$value'.isEmpty);
    case 'isNotEmpty':
      return !(value == null || (value is List ? value.isEmpty : '$value'.isEmpty));
    case 'isSet':
      return value != null && value != '' && value != 'false' && !(value is List && value.isEmpty);
    case 'isNotSet':
      return value == null || value == '' || value == 'false' || (value is List && value.isEmpty);
    case 'is':
      if (f.values.isEmpty) return true;
      if (isDate) {
        final n = int.tryParse(first) ?? 0;
        if (dv?.from == null) return false;
        if (t!.type != 'date') return dv!.from! > n - _halfDay && dv.from! < n + _halfDay;
        if (dv!.to != null) return dv.from! <= n && dv.to! >= n;
        return dv.from == n;
      }
      return first.toLowerCase() == s.toLowerCase();
    case 'contains':
      return f.values.isEmpty || s.toLowerCase().contains(first.toLowerCase());
    case 'notContains':
      return f.values.isEmpty || !s.toLowerCase().contains(first.toLowerCase());
    case 'startsWith':
      return f.values.isEmpty || s.toLowerCase().startsWith(first.toLowerCase());
    case 'notStartsWith':
      return f.values.isEmpty || !s.toLowerCase().startsWith(first.toLowerCase());
    case 'endsWith':
      return f.values.isEmpty || s.toLowerCase().endsWith(first.toLowerCase());
    case 'notEndsWith':
      return f.values.isEmpty || !s.toLowerCase().endsWith(first.toLowerCase());
    case 'isBefore':
      if (f.values.isEmpty) return true;
      if (dv?.from == null) return false;
      final n = int.tryParse(first) ?? 0;
      return t?.type == 'date' ? dv!.from! < n : dv!.from! < n - _halfDay;
    case 'isAfter':
      if (f.values.isEmpty) return true;
      if (dv?.from == null) return false;
      final n = int.tryParse(first) ?? 0;
      if (t?.type != 'date') return dv!.from! > n + _halfDay;
      return (dv!.to ?? dv.from!) > n;
  }
  return true;
}

/// Thẻ có thỏa nhóm điều kiện lọc không.
bool filterMet(FilterGroup g, List<PropTemplate> props, TaskCard c) {
  if (g.filters.isEmpty) return true;
  bool one(Object f) => f is FilterGroup ? filterMet(f, props, c) : _clauseMet(f as FilterClause, props, c);
  return g.operation == 'or' ? g.filters.any(one) : g.filters.every(one);
}

int _titleOrCreated(TaskCard a, TaskCard b) {
  if (a.title.isNotEmpty && b.title.isEmpty) return -1;
  if (b.title.isNotEmpty && a.title.isEmpty) return 1;
  if (a.title.isNotEmpty && b.title.isNotEmpty) {
    final r = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (r != 0) return r;
  }
  return a.createAt.compareTo(b.createAt);
}

/// Sắp xếp thẻ theo view: không có tiêu chí thì theo thứ tự kéo thả (`cardOrder`), thẻ chưa xếp ở cuối.
/// [userName]: tên người dùng (sắp theo người tạo / sửa).
List<TaskCard> sortCards(List<TaskCard> cards, TaskBoard board, BoardView view, [String Function(String id)? userName]) {
  final out = [...cards];
  final sorts = view.sortOptions;
  if (sorts.isEmpty) {
    final order = {for (final (i, id) in view.cardOrder.indexed) id: i};
    out.sort((a, b) {
      final ia = order[a.id], ib = order[b.id];
      if (ia == null && ib == null) return _titleOrCreated(a, b);
      if (ia == null) return 1;
      if (ib == null) return -1;
      return ia.compareTo(ib);
    });
    return out;
  }
  int cmp(TaskCard a, TaskCard b) {
    for (final s in sorts) {
      int r;
      if (s.propertyId == kTitleColumn) {
        r = _titleOrCreated(a, b);
      } else {
        final t = board.prop(s.propertyId);
        if (t == null) continue;
        r = _cmpProp(a, b, t, userName);
      }
      if (r != 0) return s.reversed ? -r : r;
    }
    return _titleOrCreated(a, b);
  }

  out.sort(cmp);
  return out;
}

int _cmpProp(TaskCard a, TaskCard b, PropTemplate t, String Function(String id)? userName) {
  switch (t.type) {
    case 'createdTime':
      return a.createAt.compareTo(b.createAt);
    case 'updatedTime':
      return a.updateAt.compareTo(b.updateAt);
    case 'number':
    case 'date':
      num? n(TaskCard c) => t.type == 'date' ? DateProp.parse(c.properties[t.id])?.from : num.tryParse('${c.properties[t.id] ?? ''}');
      final x = n(a), y = n(b);
      if (x != null && y == null) return -1;
      if (y != null && x == null) return 1;
      if (x == null && y == null) return 0;
      return x!.compareTo(y!);
    case 'select':
    case 'multiSelect':
      // Theo thứ tự phương án trong bảng; trống ở cuối.
      int idx(TaskCard c) {
        final v = c.list(t.id).firstOrNull;
        final i = t.options.indexWhere((o) => o.id == v);
        return i < 0 ? 1 << 30 : i;
      }
      return idx(a).compareTo(idx(b));
  }
  String sv(TaskCard c) {
    final v = cardValue(c, t, t.id);
    final s = v is List ? v.join(',') : '${v ?? ''}';
    return t.isPerson && userName != null && s.isNotEmpty ? userName(s.split(',').first) : s;
  }

  final x = sv(a).toLowerCase(), y = sv(b).toLowerCase();
  if (x.isNotEmpty && y.isEmpty) return -1;
  if (y.isNotEmpty && x.isEmpty) return 1;
  return x.compareTo(y);
}

/// Thuộc tính để thẻ mới tạo trong view vẫn thỏa bộ lọc (phép "includes" lấy giá trị đầu, như bản web).
Map<String, dynamic> propsMeetingFilter(FilterGroup g, List<PropTemplate> props) {
  final out = <String, dynamic>{};
  final clauses = g.clauses;
  for (final f in g.operation == 'or' ? clauses.take(1) : clauses) {
    final t = props.where((p) => p.id == f.propertyId).firstOrNull;
    if (t == null || t.readOnly || f.values.isEmpty) continue;
    if (f.condition == 'includes' || f.condition == 'is') {
      out[t.id] = t.type == 'multiSelect' || t.type == 'multiPerson' ? [f.values.first] : f.values.first;
    }
  }
  return out;
}
