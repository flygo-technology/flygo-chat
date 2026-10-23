import 'dart:convert';
typedef Json = Map<String, dynamic>;

class MmUser {
  final Json raw;
  MmUser(this.raw);
  String get id => raw['id'] as String;
  String get username => raw['username'] as String? ?? '';
  String get firstName => raw['first_name'] as String? ?? '';
  String get lastName => raw['last_name'] as String? ?? '';
  String get nickname => raw['nickname'] as String? ?? '';
  String get email => raw['email'] as String? ?? '';
  bool get isBot => raw['is_bot'] == true;
  int get deleteAt => (raw['delete_at'] as num?)?.toInt() ?? 0;
  int get lastPictureUpdate => (raw['last_picture_update'] as num?)?.toInt() ?? 0;

  String get displayName {
    final full = '$firstName $lastName'.trim();
    if (full.isNotEmpty) return full;
    if (nickname.isNotEmpty) return nickname;
    return username;
  }
}

class MmChannel {
  final Json raw;
  MmChannel(this.raw);
  String get id => raw['id'] as String;
  String get name => raw['name'] as String? ?? '';
  String get displayName => raw['display_name'] as String? ?? '';
  String get type => raw['type'] as String? ?? 'O';
  int get lastPostAt => (raw['last_post_at'] as num?)?.toInt() ?? 0;
  int get totalMsgCount => (raw['total_msg_count'] as num?)?.toInt() ?? 0;
  /// Chỉ tính tin gốc (không tính trả lời trong luồng); null nếu máy chủ không gửi.
  int? get totalMsgCountRoot => (raw['total_msg_count_root'] as num?)?.toInt();
  int get deleteAt => (raw['delete_at'] as num?)?.toInt() ?? 0;
  int get createAt => (raw['create_at'] as num?)?.toInt() ?? 0;
  String get purpose => raw['purpose'] as String? ?? '';

  /// Luồng riêng tách từ một nhóm: mô tả kênh có mốc "[flygo-sub parent=<id kênh> root=<id tin>]".
  static final _subRe = RegExp(r'\[flygo-sub parent=(\w+) root=(\w+)\]');
  String? get subParent => _subRe.firstMatch(purpose)?.group(1);
  String? get subRoot => _subRe.firstMatch(purpose)?.group(2);
  bool get isSub => subParent != null;

  /// Chat AI cột phải: kênh riêng tư chỉ có chủ nhân + các bot của họ, gắn với một nhóm
  /// (mốc "[flygo-ai group=<id nhóm> owner=<id người dùng>]" trong mô tả kênh).
  static final _aiRe = RegExp(r'\[flygo-ai group=(\w+) owner=(\w+)\]');
  String? get aiGroup => _aiRe.firstMatch(purpose)?.group(1);
  String? get aiOwner => _aiRe.firstMatch(purpose)?.group(2);
  bool get isAi => aiGroup != null;
  /// Phiên AI tách (fork) từ một phiên AI khác: mốc `[flygo-ai-fork <id kênh nguồn>]` trong header kênh.
  static final _aiForkRe = RegExp(r'\[flygo-ai-fork (\w+)\]');
  String? get aiForkOf => _aiForkRe.firstMatch(header)?.group(1);
  /// Phiên AI gắn với một luồng công việc riêng (tin gốc [aiThread]) trong nhóm: mốc `[flygo-ai-thread <id tin gốc>]`.
  static final _aiThreadRe = RegExp(r'\[flygo-ai-thread (\w+)\]');
  String? get aiThread => _aiThreadRe.firstMatch(header)?.group(1);
  /// Phiên AI đã đánh dấu xong: mốc `[flygo-ai-done]` trong header (vẫn mở lại được).
  bool get aiDone => header.contains('[flygo-ai-done]');
  /// Phiên AI đã lưu trữ (ẩn khỏi danh sách, khôi phục được): mốc `[flygo-ai-archived]` trong header.
  bool get aiArchived => header.contains('[flygo-ai-archived]');
  /// Dự án trợ lý (tab Agents): kênh riêng tư có mốc `[flygo-agent-project owner=<id>]` trong mô tả; các phiên AI
  /// của dự án là kênh AI có group = kênh này. Không hiện ở danh sách chat.
  static final _projectRe = RegExp(r'\[flygo-agent-project owner=(\w+)\]');
  String? get agentProjectOwner => _projectRe.firstMatch(purpose)?.group(1);
  bool get isAgentProject => agentProjectOwner != null;
  /// Thư mục làm việc của dự án trợ lý trên máy chạy bot: mốc `[flygo-project path=…]` trong mô tả (runner đọc).
  static final _projectPathRe = RegExp(r'\[flygo-project path=(?:"([^"\]]+)"|([^\]\s]+))\]');
  String? get projectPath {
    final m = _projectPathRe.firstMatch(purpose);
    return m == null ? null : (m.group(1) ?? m.group(2));
  }
  /// Tên phiên AI: tên kênh bỏ tiền tố `AI · <nhóm> · ` (kênh cũ chỉ có `AI · <nhóm>` → rỗng).
  String get aiTitle {
    final parts = displayName.split(' · ');
    return parts.length >= 3 ? parts.sublist(2).join(' · ') : '';
  }
  /// Ảnh nhóm (Flygo Chat): mô tả kênh có mốc "[flygo-icon <file id>]".
  static final _iconRe = RegExp(r'\[flygo-icon (\w+)\]');
  String? get iconFileId => _iconRe.firstMatch(purpose)?.group(1);
  /// Luồng riêng tư đã đóng: mô tả kênh có mốc "[flygo-closed]".
  static final _closedRe = RegExp(r'\[flygo-closed\]');
  bool get isClosed => _closedRe.hasMatch(purpose);
  /// Tự xoá tin cũ hơn N ngày (0 = tắt): mốc "[flygo-retention days=N]" (10–365) trong mô tả, chủ nhóm đặt;
  /// trạm của máy chủ xoá mỗi đêm (chỉ khi người đặt mốc là quản trị nhóm).
  static final _retentionRe = RegExp(r'\[flygo-retention days=(\d+)\]');
  int get retentionDays => int.tryParse(_retentionRe.firstMatch(purpose)?.group(1) ?? '') ?? 0;
  /// Mô tả hiển thị (bỏ mốc kỹ thuật).
  String get purposeText =>
      purpose.replaceAll(_subRe, '').replaceAll(_iconRe, '').replaceAll(_closedRe, '').replaceAll(_retentionRe, '').trim();
  /// Các mốc kỹ thuật trong mô tả (giữ lại khi sửa mô tả).
  String get purposeMarkers => [
        ..._subRe.allMatches(purpose).map((m) => m.group(0)!),
        ..._iconRe.allMatches(purpose).map((m) => m.group(0)!),
        if (isClosed) '[flygo-closed]',
        if (retentionDays > 0) '[flygo-retention days=$retentionDays]',
      ].join(' ');
  String get header => raw['header'] as String? ?? '';
  /// Mốc kỹ thuật trong header (ẩn khi hiển thị): `[flygo-…]`.
  static final _headerMarkRe = RegExp(r'\[flygo-[^\]]*\]');
  /// Header hiển thị (bỏ mốc kỹ thuật).
  String get headerText => header.replaceAll(_headerMarkRe, '').trim();
  /// Giao diện chat dùng chung cho mọi thành viên: mốc `[flygo-theme <id>]` trong header.
  static final _themeRe = RegExp(r'\[flygo-theme ([\w-]+)\]');
  String? get themeId => _themeRe.firstMatch(header)?.group(1);
  /// Banner của Flygo Chat (mọi loại chat, kể cả 1-1): mốc `[flygo-banner <màu hex> <chữ base64url>]` trong header.
  static final _bannerRe = RegExp(r'\[flygo-banner ([0-9a-fA-F]{6}) ([A-Za-z0-9_=-]+)\]');
  ({String color, String text})? get flygoBanner {
    final m = _bannerRe.firstMatch(header);
    if (m == null) return null;
    try {
      return (color: m.group(1)!, text: utf8.decode(base64Url.decode(m.group(2)!)));
    } catch (_) {
      return null;
    }
  }

  /// Header mới: thay mốc theme / banner (null = bỏ), giữ nguyên phần còn lại.
  String headerWith({String? theme, ({String color, String text})? banner, bool setTheme = false, bool setBanner = false}) {
    var h = header;
    if (setTheme) {
      h = h.replaceAll(_themeRe, '').trim();
      if (theme != null) h = '$h [flygo-theme $theme]'.trim();
    }
    if (setBanner) {
      h = h.replaceAll(_bannerRe, '').trim();
      if (banner != null && banner.text.trim().isNotEmpty) {
        h = '$h [flygo-banner ${banner.color} ${base64Url.encode(utf8.encode(banner.text.trim()))}]'.trim();
      }
    }
    return h;
  }
  /// Banner màu của kênh (Mattermost: banner_info {enabled, text, background_color}).
  Map<String, dynamic>? get banner {
    final b = (raw['banner_info'] as Map?)?.cast<String, dynamic>();
    return b != null && b['enabled'] == true && (b['text'] as String? ?? '').isNotEmpty ? b : null;
  }
  bool get isSelfDm => type == 'D' && name.split('__').toSet().length == 1;
  bool get isDirect => type == 'D';
  bool get isPublic => type == 'O';
  bool get isGroupDm => type == 'G';

  /// Id người còn lại trong tin nhắn riêng (tên kênh dạng "uid1__uid2").
  String? otherUserId(String myId) {
    if (!isDirect) return null;
    final parts = name.split('__');
    if (parts.length != 2) return null;
    return parts[0] == myId ? parts[1] : parts[0];
  }
}

class MmMember {
  final Json raw;
  MmMember(this.raw);
  String get channelId => raw['channel_id'] as String;
  int get msgCount => (raw['msg_count'] as num?)?.toInt() ?? 0;
  int? get msgCountRoot => (raw['msg_count_root'] as num?)?.toInt();
  int get mentionCount => (raw['mention_count'] as num?)?.toInt() ?? 0;
  int get lastViewedAt => (raw['last_viewed_at'] as num?)?.toInt() ?? 0;
  bool get muted => (raw['notify_props'] as Map?)?['mark_unread'] == 'mention';
}

class MmFile {
  final Json raw;
  MmFile(this.raw);
  String get id => raw['id'] as String;
  String get name => raw['name'] as String? ?? 'file';
  int get size => (raw['size'] as num?)?.toInt() ?? 0;
  String get mime => raw['mime_type'] as String? ?? '';
  bool get isImage => mime.startsWith('image/') && raw['has_preview_image'] != false;
  bool get isVideo => mime.startsWith('video/');
  int get width => (raw['width'] as num?)?.toInt() ?? 0;
  int get height => (raw['height'] as num?)?.toInt() ?? 0;
}

enum SendState { sent, sending, failed }

class MmPost {
  final Json raw;
  MmPost(this.raw);
  String get id => raw['id'] as String;
  String get channelId => raw['channel_id'] as String;
  String get userId => raw['user_id'] as String? ?? '';
  String get message => raw['message'] as String? ?? '';
  String get rootId => raw['root_id'] as String? ?? '';
  String get type => raw['type'] as String? ?? '';
  int get createAt => (raw['create_at'] as num?)?.toInt() ?? 0;
  int get updateAt => (raw['update_at'] as num?)?.toInt() ?? 0;
  int get editAt => (raw['edit_at'] as num?)?.toInt() ?? 0;
  int get deleteAt => (raw['delete_at'] as num?)?.toInt() ?? 0;
  String get pendingId => raw['pending_post_id'] as String? ?? '';
  bool get isSystem => type.startsWith('system_');
  bool get isBurnOnRead => type == 'burn_on_read';
  bool get isPinned => raw['is_pinned'] == true;

  /// File trên máy của tin đang gửi: [{path, name, mime, aspect}].
  List<Map<String, dynamic>> get localFiles =>
      [for (final f in (raw['_local_files'] as List? ?? const [])) (f as Map).cast<String, dynamic>()];
  /// Tin chuyển tiếp (flygo_forwarded; dnd_forwarded là tên cũ).
  bool get isForwarded => props['flygo_forwarded'] == true || props['dnd_forwarded'] == true;
  /// Kiểu trả lời của Flygo Chat (props.flygo_reply): '' = trả lời trong chat,
  /// 'thread' = chỉ trong chủ đề, 'thread_broadcast' = trong chủ đề và cả chat chính.
  String get replyKind => rootId.isEmpty ? '' : (props['flygo_reply'] as String? ?? '');
  bool get inThread => replyKind == 'thread' || replyKind == 'thread_broadcast';
  /// Chỉ nằm trong luồng công việc riêng (không hiện ở chat chính). Kể cả trả lời "gửi cả vào chat chính" (thread_broadcast):
  /// chat chính chỉ hiện thẻ luồng dưới tin gốc cho gọn.
  bool get threadOnly => replyKind == 'thread' || (rootId.isNotEmpty && replyKind == 'thread_broadcast');
  bool get isCall => type == 'custom_calls';
  /// Tin báo đổ chuông gọi nhóm của Flygo Chat (props.flygo_call_ring = {video: bool}).
  bool get isCallRing => props['flygo_call_ring'] is Map;
  bool get callRingVideo => (props['flygo_call_ring'] as Map?)?['video'] == true;
  /// Nội dung tin đổ chuông, bỏ "@channel" (chỉ để Mattermost gửi thông báo đẩy cho cả nhóm).
  String get callRingText => message.replaceAll(RegExp(r'\s*@channel\b'), '').trim();
  /// Bản cũ máy chủ lưu lại mỗi khi tin bị sửa (có original_id); không phải tin thật.
  bool get isEditHistory => (raw['original_id'] as String? ?? '').isNotEmpty;
  int get callStart => (props['start_at'] as num?)?.toInt() ?? createAt;
  int? get callEnd => (props['end_at'] as num?)?.toInt();
  /// Tin đã bị thu hồi (xóa): vẫn giữ chỗ trong khung chat.
  bool get isRecalled => deleteAt > 0 || raw['_deleted'] == true;

  /// Mức ưu tiên: '' | 'important' | 'urgent'.
  String get priority => ((raw['metadata'] as Map?)?['priority'] as Map?)?['priority'] as String? ?? '';
  bool get requestedAck => ((raw['metadata'] as Map?)?['priority'] as Map?)?['requested_ack'] == true;
  List<String> get ackUserIds => [
        for (final a in ((raw['metadata'] as Map?)?['acknowledgements'] as List? ?? const []))
          if ((a as Map)['acknowledged_at'] != 0) a['user_id'] as String,
      ];
  Json get props => (raw['props'] as Map?)?.cast<String, dynamic>() ?? {};

  /// Tin đánh dấu đóng / mở lại luồng (props.flygo_thread_closed): app và bot đọc để biết trạng thái; trong chat hiện thành
  /// dòng hệ thống nhỏ "🔒 Luồng đã đóng" / "🔓 Luồng đã mở lại", không đổ chuông, không vào dòng xem trước.
  bool get isThreadCloseMark => props.containsKey('flygo_thread_closed');

  /// "Dịch AI": tin đang chờ dịch trước khi gửi (ngôn ngữ đích), app tự gắn.
  String? get translatingTo => raw['_translate'] as String?;

  /// Trạng thái gửi do app tự gắn (không có trên server).
  SendState get sendState => switch (raw['_send']) {
        'sending' => SendState.sending,
        'failed' => SendState.failed,
        _ => SendState.sent,
      };

  List<MmFile> get files {
    final m = raw['metadata'] as Map?;
    final f = m?['files'] as List?;
    return f == null ? const [] : f.map((e) => MmFile((e as Map).cast<String, dynamic>())).toList();
  }

  /// Gom cảm xúc: emoji_name -> danh sách user_id.
  Map<String, List<String>> get reactions {
    final m = raw['metadata'] as Map?;
    final r = m?['reactions'] as List?;
    final out = <String, List<String>>{};
    for (final e in r ?? const []) {
      final name = e['emoji_name'] as String;
      (out[name] ??= []).add(e['user_id'] as String);
    }
    return out;
  }
}
