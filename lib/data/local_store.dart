import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

import '../config.dart';

import 'models.dart';

/// Kho lưu trên máy để dùng offline: kênh, người dùng, tin nhắn gần đây,
/// tin chờ gửi.
class LocalStore {
  final Database db;
  LocalStore._(this.db);

  static final _channels = stringMapStoreFactory.store('channels');
  static final _members = stringMapStoreFactory.store('members');
  static final _users = stringMapStoreFactory.store('users');
  static final _posts = stringMapStoreFactory.store('posts');
  static final _outbox = stringMapStoreFactory.store('outbox');
  static final _meta = StoreRef<String, Object?>('meta');

  static const keepPerChannel = 300;

  /// Bỏ các bản lịch sử sửa tin (có original_id) mà máy chủ trả kèm.
  static final _notHistory = Filter.custom((r) => ((r.value as Map)['original_id'] as String? ?? '').isEmpty);

  static Future<LocalStore> open(String userId) async {
    // Cửa sổ phụ dùng kho trong bộ nhớ, không ghi chung file với cửa sổ chính.
    if (kWindowChannel != null) return LocalStore._(await databaseFactoryMemory.openDatabase('window_$userId'));
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final db = await databaseFactoryIo.openDatabase('${dir.path}${Platform.pathSeparator}cache_$userId.db');
    return LocalStore._(db);
  }

  Future<void> close() => db.close();

  // --- meta
  Future<T?> meta<T>(String key) async => await _meta.record(key).get(db) as T?;
  Future<void> setMeta(String key, Object? v) => _meta.record(key).put(db, v);

  // --- kênh, thành viên, người dùng
  Future<List<MmChannel>> channels() async =>
      (await _channels.find(db)).map((r) => MmChannel(Map<String, dynamic>.from(r.value))).toList();
  Future<void> putChannels(List<MmChannel> list, {bool replace = false}) => db.transaction((tx) async {
        if (replace) await _channels.delete(tx);
        for (final c in list) {
          await _channels.record(c.id).put(tx, c.raw);
        }
      });

  Future<List<MmMember>> members() async =>
      (await _members.find(db)).map((r) => MmMember(Map<String, dynamic>.from(r.value))).toList();
  Future<void> putMembers(List<MmMember> list) => db.transaction((tx) async {
        for (final m in list) {
          await _members.record(m.channelId).put(tx, m.raw);
        }
      });

  Future<List<MmUser>> users() async =>
      (await _users.find(db)).map((r) => MmUser(Map<String, dynamic>.from(r.value))).toList();
  Future<void> putUsers(List<MmUser> list) => db.transaction((tx) async {
        for (final u in list) {
          await _users.record(u.id).put(tx, u.raw);
        }
      });

  /// Xóa người dùng đã bị xóa trên máy chủ khỏi bộ nhớ máy.
  Future<void> deleteUsers(Iterable<String> ids) => db.transaction((tx) async {
        for (final id in ids) {
          await _users.record(id).delete(tx);
        }
      });

  // --- tin nhắn
  Future<List<MmPost>> posts(String channelId, {int limit = 120}) async {
    final rs = await _posts.find(db,
        finder: Finder(
          filter: Filter.equals('channel_id', channelId),
          sortOrders: [SortOrder('create_at', false)],
          limit: limit,
        ));
    return rs.map((r) => MmPost(Map<String, dynamic>.from(r.value))).where((p) => !p.isEditHistory).toList();
  }

  /// Tin cuộc gọi (`custom_calls`) và tin đổ chuông gọi nhóm của Flygo Chat, mới nhất trước (lịch sử cuộc gọi).
  Future<List<MmPost>> callPosts({int limit = 400}) async {
    final rs = await _posts.find(db,
        finder: Finder(
          filter: Filter.or([
            Filter.equals('type', 'custom_calls'),
            Filter.notNull('props.flygo_call_ring'),
          ]),
          sortOrders: [SortOrder('create_at', false)],
          limit: limit,
        ));
    return rs.map((r) => MmPost(Map<String, dynamic>.from(r.value))).where((p) => !p.isEditHistory && !p.isRecalled).toList();
  }

  Future<MmPost?> post(String id) async {
    final v = await _posts.record(id).get(db);
    return v == null ? null : MmPost(Map<String, dynamic>.from(v));
  }

  Future<void> putPosts(List<MmPost> list) => db.transaction((tx) async {
        for (final p in list) {
          if (p.isEditHistory) {
            await _posts.record(p.id).delete(tx);
            continue;
          }
          if (p.deleteAt > 0) {
            // Tin bị thu hồi: lưu chỗ trống (không giữ nội dung) để vẫn hiện "đã thu hồi".
            await _posts.record(p.id).put(tx, {...p.raw, 'message': '', 'metadata': {}, 'file_ids': const [], '_deleted': true});
          } else {
            await _posts.record(p.id).put(tx, p.raw);
          }
        }
      });

  Future<void> deletePost(String id) => _posts.record(id).delete(db);

  /// Giữ tối đa [keepPerChannel] tin gần nhất mỗi kênh để file không phình to.
  Future<void> trim(String channelId) async {
    final keys = await _posts.findKeys(db,
        finder: Finder(
          filter: Filter.equals('channel_id', channelId),
          sortOrders: [SortOrder('create_at', false)],
          offset: keepPerChannel,
        ));
    if (keys.isNotEmpty) await _posts.records(keys).delete(db);
  }

  /// Tin mới nhất mỗi kênh, dùng cho dòng xem trước trong danh sách chat.
  Future<MmPost?> latest(String channelId) async {
    final r = await _posts.findFirst(db,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('channel_id', channelId),
            Filter.equals('root_id', ''),
            _notHistory,
          ]),
          sortOrders: [SortOrder('create_at', false)],
        ));
    if (r != null) return MmPost(Map<String, dynamic>.from(r.value));
    final any = await _posts.findFirst(db,
        finder: Finder(filter: Filter.and([Filter.equals('channel_id', channelId), _notHistory]), sortOrders: [SortOrder('create_at', false)]));
    return any == null ? null : MmPost(Map<String, dynamic>.from(any.value));
  }

  // --- hàng chờ gửi
  Future<List<Json>> outbox() async =>
      (await _outbox.find(db, finder: Finder(sortOrders: [SortOrder('create_at')])))
          .map((r) => Map<String, dynamic>.from(r.value))
          .toList();
  Future<void> putOutbox(Json p) => _outbox.record(p['pending_post_id'] as String).put(db, p);
  Future<void> removeOutbox(String pendingId) => _outbox.record(pendingId).delete(db);
}
