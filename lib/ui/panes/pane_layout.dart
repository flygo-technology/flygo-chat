/// Mô hình chia ô của màn hình máy tính (tối đa 4 ô): cây chia đôi ngang / dọc, mỗi lá là một ô hiện một cuộc trò
/// chuyện hoặc một mục của thanh tab. Không phụ thuộc giao diện để kiểm thử được (test/pane_layout_test.dart).
library;

/// Các mục của thanh tab có thể kéo vào một ô (tên dùng trong bố cục lưu trên máy và tham số `--section=`).
class PaneSections {
  static const chats = 'chats', threads = 'threads', agents = 'agents', apps = 'apps', tasks = 'tasks';
  static const all = [chats, agents, tasks, threads, apps];

  /// Chỉ số tab tương ứng trên thanh tab (0 Chat, 1 Luồng, 2 Các trợ lý, 3 Bạn, 4 Việc).
  static int tabOf(String s) => switch (s) { threads => 1, agents => 2, apps => 3, tasks => 4, _ => 0 };
  static String ofTab(int tab) => switch (tab) { 1 => threads, 2 => agents, 3 => apps, 4 => tasks, _ => chats };
}

/// Nội dung một ô: một cuộc trò chuyện (id kênh) hoặc một mục của thanh tab.
class PaneContent {
  final String kind;
  final String id;
  const PaneContent.chat(this.id) : kind = 'chat';
  const PaneContent.section(this.id) : kind = 'section';

  bool get isChat => kind == 'chat';
  bool get isSection => kind == 'section';

  /// Dạng chữ để lưu: `chat:<id>` / `section:<tên>`.
  String get key => '$kind:$id';

  static PaneContent? parse(Object? v) {
    if (v is! String) return null;
    final i = v.indexOf(':');
    if (i <= 0 || i == v.length - 1) return null;
    final kind = v.substring(0, i), id = v.substring(i + 1);
    if (kind == 'chat') return PaneContent.chat(id);
    if (kind == 'section' && PaneSections.all.contains(id)) return PaneContent.section(id);
    return null;
  }

  @override
  bool operator ==(Object other) => other is PaneContent && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
  @override
  String toString() => key;
}

/// Chỗ thả khi kéo vào một ô: chia sang trái / phải / trên / dưới, hoặc thay nội dung ô (giữa).
enum PaneEdge { left, right, top, bottom, center }

sealed class PaneNode {}

/// Một ô. [id] giữ nguyên khi ô được kéo sang chỗ khác (giao diện gắn khoá theo id để giữ trạng thái chat).
class PaneLeaf extends PaneNode {
  final String id;
  PaneContent? content;
  PaneLeaf(this.id, [this.content]);
}

/// Chia đôi: [horizontal] = hai ô cạnh nhau (trái | phải), ngược lại xếp chồng (trên / dưới).
/// [ratio]: phần của ô thứ nhất (0..1).
class PaneSplit extends PaneNode {
  final String id;
  bool horizontal;
  double ratio;
  PaneNode first, second;
  PaneSplit(this.id, this.horizontal, this.first, this.second, [this.ratio = .5]);
}

class PaneLayout {
  static const maxPanes = 4;
  static const minRatio = .15, maxRatio = .85;

  PaneNode root;
  String focusedId;
  /// Ô đang phóng to (các ô khác tạm ẩn, vẫn giữ trạng thái).
  String? maximizedId;
  /// Các ô theo thứ tự chọn gần nhất (đầu danh sách = ô đang chọn).
  final List<String> _recent = [];
  int _seq = 1;

  PaneLayout() : root = PaneLeaf('p1'), focusedId = 'p1' {
    _recent.add('p1');
    _seq = 2;
  }

  String _newId(String prefix) => '$prefix${_seq++}';

  /// Các ô theo thứ tự đọc (trái → phải, trên → dưới).
  List<PaneLeaf> get leaves {
    final out = <PaneLeaf>[];
    void walk(PaneNode n) {
      switch (n) {
        case PaneLeaf l:
          out.add(l);
        case PaneSplit s:
          walk(s.first);
          walk(s.second);
      }
    }

    walk(root);
    return out;
  }

  int get count => leaves.length;
  bool get isFull => count >= maxPanes;
  bool get isMulti => count > 1;

  PaneLeaf? leaf(String id) => leaves.where((l) => l.id == id).firstOrNull;
  PaneLeaf get focused => leaf(focusedId) ?? leaves.first;
  PaneLeaf? find(PaneContent c) => leaves.where((l) => l.content == c).firstOrNull;

  void focus(String id) {
    if (leaf(id) == null) return;
    focusedId = id;
    _recent
      ..remove(id)
      ..insert(0, id);
  }

  /// Mở [c] ở ô đang chọn (thay nội dung). Đã có ở ô khác thì chỉ chuyển sang ô đó (không mở trùng hai ô).
  PaneLeaf open(PaneContent c) {
    final existing = find(c);
    if (existing != null) {
      focus(existing.id);
      return existing;
    }
    final f = focused;
    f.content = c;
    focus(f.id);
    return f;
  }

  /// Mở [c] từ một ô [fromId] (vd. bấm chat trong ô "Chat" hay "Các trợ lý"): ô nguồn là danh sách thì không thay
  /// chính nó mà mở ở ô chat gần nhất; chưa có ô chat thì chia đôi ô nguồn (còn chỗ) hoặc thay ô gần nhất khác.
  PaneLeaf openFrom(String? fromId, PaneContent c) {
    final existing = find(c);
    if (existing != null) {
      focus(existing.id);
      return existing;
    }
    final from = fromId == null ? null : leaf(fromId);
    if (from == null || from.content == null || from.content!.isChat) {
      if (from != null) focus(from.id);
      return open(c);
    }
    final others = [for (final id in _recent) ?leaf(id)]
        .where((l) => l.id != from.id)
        .toList();
    final target = others.where((l) => l.content == null || l.content!.isChat).firstOrNull;
    if (target != null) {
      target.content = c;
      focus(target.id);
      return target;
    }
    if (!isFull) return split(from.id, PaneEdge.right, c)!;
    final t = others.isNotEmpty ? others.first : from;
    t.content = c;
    focus(t.id);
    return t;
  }

  /// Chia ô [targetId] theo [edge], ô mới hiện [c]. Hết chỗ (4 ô) hoặc [edge] là giữa thì trả về null.
  PaneLeaf? split(String targetId, PaneEdge edge, PaneContent c) {
    if (isFull || edge == PaneEdge.center) return null;
    final t = leaf(targetId);
    if (t == null) return null;
    final n = PaneLeaf(_newId('p'), c);
    _insertBeside(t, n, edge);
    focus(n.id);
    return n;
  }

  void _insertBeside(PaneLeaf target, PaneLeaf n, PaneEdge edge) {
    final horizontal = edge == PaneEdge.left || edge == PaneEdge.right;
    final before = edge == PaneEdge.left || edge == PaneEdge.top;
    final s = PaneSplit(_newId('s'), horizontal, before ? n : target, before ? target : n);
    _replace(target, s);
  }

  /// Cha của [n] (null nếu [n] là gốc hoặc không có trong cây).
  PaneSplit? _parentOf(PaneNode n) {
    PaneSplit? found;
    void walk(PaneNode x) {
      if (found != null || x is! PaneSplit) return;
      if (identical(x.first, n) || identical(x.second, n)) {
        found = x;
        return;
      }
      walk(x.first);
      walk(x.second);
    }

    walk(root);
    return found;
  }

  void _replace(PaneNode old, PaneNode n) {
    if (identical(root, old)) {
      root = n;
      return;
    }
    final p = _parentOf(old);
    if (p == null) return;
    if (identical(p.first, old)) {
      p.first = n;
    } else {
      p.second = n;
    }
  }

  /// Gỡ ô [l] khỏi cây (ô anh em chiếm chỗ của khung chia). Không gỡ được ô duy nhất.
  bool _detach(PaneLeaf l) {
    if (identical(root, l)) return false;
    final p = _parentOf(l);
    if (p == null) return false;
    _replace(p, identical(p.first, l) ? p.second : p.first);
    return true;
  }

  /// Đóng ô [id]. Ô duy nhất thì chỉ xoá nội dung (màn chào). Ô đang chọn thì chọn ô gần nhất còn lại.
  void close(String id) {
    final l = leaf(id);
    if (l == null) return;
    if (maximizedId == id) maximizedId = null;
    if (!_detach(l)) {
      l.content = null;
      return;
    }
    _recent.remove(id);
    if (focusedId == id) focus(_recent.where((x) => leaf(x) != null).firstOrNull ?? leaves.first.id);
  }

  /// Kéo ô [srcId] thả vào ô [targetId]: giữa = đổi chỗ hai ô; cạnh = chuyển ô sang cạnh đó.
  bool move(String srcId, String targetId, PaneEdge edge) {
    if (srcId == targetId) return false;
    final src = leaf(srcId), target = leaf(targetId);
    if (src == null || target == null) return false;
    if (edge == PaneEdge.center) {
      final a = _parentOf(src), b = _parentOf(target);
      // Đổi chỗ hai lá trong cây (giữ nguyên đối tượng ô để giao diện giữ trạng thái).
      void put(PaneSplit? p, PaneLeaf old, PaneLeaf n) {
        if (p == null) {
          root = n;
        } else if (identical(p.first, old)) {
          p.first = n;
        } else {
          p.second = n;
        }
      }

      if (identical(a, b) && a != null) {
        final t = a.first;
        a.first = a.second;
        a.second = t;
      } else {
        put(a, src, target);
        put(b, target, src);
      }
      focus(src.id);
      return true;
    }
    if (!_detach(src)) return false;
    _insertBeside(target, src, edge);
    focus(src.id);
    return true;
  }

  /// Thả nội dung kéo từ danh sách (chat, mục thanh tab) hoặc từ một ô khác ([fromPane]) vào ô [targetId].
  bool drop(String targetId, PaneEdge edge, PaneContent c, {String? fromPane}) {
    final target = leaf(targetId);
    if (target == null) return false;
    final src = fromPane != null ? leaf(fromPane) : find(c);
    if (src != null) {
      if (src.id == targetId) {
        focus(targetId);
        return false;
      }
      return move(src.id, targetId, edge);
    }
    if (edge == PaneEdge.center || target.content == null) {
      target.content = c;
      focus(target.id);
      return true;
    }
    return split(targetId, edge, c) != null;
  }

  /// Được chia thêm khi kéo [c] (từ ô [fromPane]) không: kéo ô có sẵn thì luôn được (số ô không đổi).
  bool canSplitWith(PaneContent c, {String? fromPane}) => fromPane != null || find(c) != null || !isFull;

  void toggleMaximize(String id) {
    if (leaf(id) == null) return;
    maximizedId = maximizedId == id ? null : id;
    focus(id);
  }

  PaneSplit? splitById(String id) {
    PaneSplit? found;
    void walk(PaneNode n) {
      if (found != null || n is! PaneSplit) return;
      if (n.id == id) {
        found = n;
        return;
      }
      walk(n.first);
      walk(n.second);
    }

    walk(root);
    return found;
  }

  void setRatio(String splitId, double r) {
    final s = splitById(splitId);
    if (s != null) s.ratio = r.clamp(minRatio, maxRatio);
  }

  /// Bỏ các ô có nội dung không còn dùng được (cuộc trò chuyện đã rời / đã xoá).
  void prune(bool Function(PaneContent c) keep) {
    for (final l in leaves) {
      final c = l.content;
      if (c != null && !keep(c)) close(l.id);
    }
  }

  // ---------------------------------------------------------------- lưu / đọc
  Map<String, Object?> toJson() {
    Object? node(PaneNode n) => switch (n) {
          PaneLeaf l => {'id': l.id, 'c': l.content?.key},
          PaneSplit s => {'id': s.id, 'h': s.horizontal, 'r': s.ratio, 'a': node(s.first), 'b': node(s.second)},
        };
    return {'v': 1, 'root': node(root), 'focus': focusedId, 'max': ?maximizedId, 'recent': [..._recent]};
  }

  /// Đọc bố cục đã lưu. Dữ liệu hỏng thì trả về bố cục một ô; thừa ô (quá 4) thì bỏ bớt; id trùng thì đặt lại.
  static PaneLayout fromJson(Object? json) {
    final out = PaneLayout();
    if (json is! Map) return out;
    final seen = <String>{};
    var nums = 1;
    String fresh(String prefix, Object? id) {
      var s = id is String && id.isNotEmpty ? id : '';
      if (s.isEmpty || !seen.add(s)) {
        do {
          s = '$prefix${100 + nums++}';
        } while (!seen.add(s));
      }
      return s;
    }

    var leavesLeft = maxPanes;
    PaneNode? node(Object? j, int depth) {
      if (j is! Map || depth > 8 || leavesLeft <= 0) return null;
      if (j.containsKey('a') || j.containsKey('b')) {
        final a = node(j['a'], depth + 1), b = node(j['b'], depth + 1);
        if (a == null || b == null) return a ?? b;
        final r = j['r'];
        return PaneSplit(fresh('s', j['id']), j['h'] != false, a, b,
            (r is num && r.isFinite ? r.toDouble() : .5).clamp(minRatio, maxRatio));
      }
      leavesLeft--;
      return PaneLeaf(fresh('p', j['id']), PaneContent.parse(j['c']));
    }

    final root = node(json['root'], 0);
    if (root == null) return out;
    out.root = root;
    out._recent.clear();
    final ids = [for (final l in out.leaves) l.id];
    final recent = json['recent'];
    if (recent is List) {
      for (final id in recent) {
        if (id is String && ids.contains(id) && !out._recent.contains(id)) out._recent.add(id);
      }
    }
    for (final id in ids) {
      if (!out._recent.contains(id)) out._recent.add(id);
    }
    final f = json['focus'];
    out.focusedId = f is String && ids.contains(f) ? f : out._recent.first;
    out.focus(out.focusedId);
    final m = json['max'];
    out.maximizedId = m is String && ids.contains(m) && ids.length > 1 ? m : null;
    // Số đếm cho id mới: lớn hơn mọi số đã dùng.
    var maxNum = 1;
    for (final id in seen) {
      final n = int.tryParse(id.substring(1));
      if (n != null && n > maxNum) maxNum = n;
    }
    out._seq = maxNum + 1;
    return out;
  }
}
