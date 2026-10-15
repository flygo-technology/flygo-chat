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
  /// Ảnh nhóm (Flygo Chat): mô tả kênh có mốc "[flygo-icon <file id>]".
  static final _iconRe = RegExp(r'\[flygo-icon (\w+)\]');
  String? get iconFileId => _iconRe.firstMatch(purpose)?.group(1);
  /// Luồng riêng tư đã đóng: mô tả kênh có mốc "[flygo-closed]".
  static final _closedRe = RegExp(r'\[flygo-closed\]');
  bool get isClosed => _closedRe.hasMatch(purpose);
  /// Mô tả hiển thị (bỏ mốc kỹ thuật).
  String get purposeText => purpose.replaceAll(_subRe, '').replaceAll(_iconRe, '').replaceAll(_closedRe, '').trim();
  /// Các mốc kỹ thuật trong mô tả (giữ lại khi sửa mô tả).
  String get purposeMarkers => [
        ..._subRe.allMatches(purpose).map((m) => m.group(0)!),
        ..._iconRe.allMatches(purpose).map((m) => m.group(0)!),
        if (isClosed) '[flygo-closed]',
      ].join(' ');
  String get header => raw['header'] as String? ?? '';
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
