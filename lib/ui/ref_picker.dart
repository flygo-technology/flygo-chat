import '../i18n/i18n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'ai_panel.dart';
import 'common.dart';
import 'theme.dart';

// Nút @ ở ô nhắn tin: tag chat khác, luồng khác, AI agent khác cho trợ lý, hoặc người trong danh bạ.
// - Danh bạ: chèn @tên vào ô nhắn tin (người được tag nhận thông báo).
// - Chat / luồng: lúc gửi hỏi cấp quyền tạm (đọc, có thể cả gửi tin) trong bao lâu → trạm đẩy cấp "vé" cho trợ lý
//   (POST <trạm đẩy>/ref/grants); trợ lý tự đọc phần cần (tìm, phân trang) bằng vé, không phải thành viên nhóm.
// - Agent: trao đổi A2A (props.flygo_a2a_peers như nút "+ Agent").

/// Một chat / luồng được tag.
class RefItem {
  final String kind; // 'chat' | 'thread'
  final String channelId;
  final String? rootId;
  final String name;
  const RefItem(this.kind, this.channelId, this.rootId, this.name);
  String get key => '$channelId/${rootId ?? ''}';
  Map<String, dynamic> toJson() => {'channel_id': channelId, 'root_id': ?rootId};
}

class RefSelection {
  final List<RefItem> refs;
  final List<Map<String, dynamic>> agents;
  final List<MmUser> people; // tab Danh bạ: chèn @tên
  const RefSelection(this.refs, this.agents, this.people);
}

/// Bảng chọn 4 tab: Chat / Luồng / Agent / Danh bạ (chọn nhiều).
Future<RefSelection?> showRefPicker(BuildContext context, AppState app, String currentId,
    {List<RefItem> refs = const [], List<Map<String, dynamic>> agents = const []}) {
  final selRefs = {for (final r in refs) r.key: r};
  final selAgents = {for (final a in agents) a['session_id'] as String: a};
  final selPeople = <String, MmUser>{};
  final people = [
    for (final id in app.teamMemberIds)
      if (app.users[id] case final u? when !u.isBot && u.deleteAt == 0 && u.id != app.me?.id) u,
  ]..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  int at(MmChannel c) => app.latest[c.id]?.createAt ?? (c.lastPostAt > 0 ? c.lastPostAt : c.createAt);
  final chats = app.chats.where((s) => s.channel.id != currentId && !s.channel.isSelfDm).toList();
  final secret = app.privateThreads.where((c) => c.id != currentId && !c.isClosed).toList();
  final work = app.workThreads.where((t) => !app.isThreadClosed(t.root.channelId, t.root.id)).toList();
  final sessions = app.channels.values
      .where((c) => c.isAi && c.aiOwner == app.me?.id && c.deleteAt == 0 && !c.aiDone && c.id != currentId)
      .toList()
    ..sort((a, b) => at(b).compareTo(at(a)));
  String query = '';
  final searchCtl = TextEditingController();

  return showModalBottomSheet<RefSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final pal = Pal.of(ctx);
      bool match(String s) => query.isEmpty || s.toLowerCase().contains(query.toLowerCase());
      Widget tile({required bool on, required VoidCallback toggle, required Widget leading, required String title, String? sub}) =>
          CheckboxListTile(
            value: on,
            onChanged: (_) => set(toggle),
            secondary: leading,
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text)),
            subtitle: sub == null ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.sub, fontSize: 13)),
            controlAffinity: ListTileControlAffinity.trailing,
            dense: true,
          );
      void flip(RefItem r) => selRefs.containsKey(r.key) ? selRefs.remove(r.key) : selRefs[r.key] = r;
      final n = selRefs.length + selAgents.length + selPeople.length;
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * .8 - MediaQuery.viewInsetsOf(ctx).bottom * .5,
        child: DefaultTabController(
          length: 4,
          child: Column(children: [
            TabBar(
              labelColor: pal.accentText,
              unselectedLabelColor: pal.sub,
              indicatorColor: pal.accent,
              isScrollable: false,
              tabs: [Tab(text: tr('Chat')), Tab(text: tr('Luồng')), Tab(text: tr('Agent')), Tab(text: tr('Danh bạ'))],
            ),
            Expanded(
              child: TabBarView(children: [
                ListView(children: [
                  for (final s in chats)
                    if (match(s.title))
                      tile(
                        on: selRefs.containsKey('${s.channel.id}/'),
                        toggle: () => flip(RefItem('chat', s.channel.id, null, s.title)),
                        leading: Avatar(userId: s.avatarUserId, name: s.title, size: 36, icon: s.avatarUserId == null ? chatIcon(s.channel) : null, channel: s.channel),
                        title: s.title,
                      ),
                ]),
                ListView(children: [
                  for (final c in secret)
                    if (match(c.displayName))
                      tile(
                        on: selRefs.containsKey('${c.id}/'),
                        toggle: () => flip(RefItem('thread', c.id, null, c.displayName)),
                        leading: Icon(Icons.lock_outline, color: pal.sub),
                        title: c.displayName,
                        sub: [tr('Luồng bí mật'), if (app.channels[c.subParent] case final p?) app.channelTitle(p)].join(' · '),
                      ),
                  for (final t in work)
                    if (app.channels[t.root.channelId] case final ch?)
                      if (match(app.threadName(ch.id, t.root.id) ?? plainPreview(t.root.message)))
                        tile(
                          on: selRefs.containsKey('${ch.id}/${t.root.id}'),
                          toggle: () => flip(RefItem('thread', ch.id, t.root.id,
                              app.threadName(ch.id, t.root.id) ?? plainPreview(t.root.message).replaceAll('\n', ' '))),
                          leading: Icon(Icons.forum_outlined, color: pal.sub),
                          title: app.threadName(ch.id, t.root.id) ?? plainPreview(t.root.message).replaceAll('\n', ' '),
                          sub: [tr('Luồng riêng'), app.channelTitle(ch)].join(' · '),
                        ),
                ]),
                ListView(children: [
                  for (final c in sessions)
                    if (match(aiSessionLabel(c)))
                      tile(
                        on: selAgents.containsKey(c.id),
                        toggle: () => selAgents.containsKey(c.id)
                            ? selAgents.remove(c.id)
                            : selAgents[c.id] = {
                                'session_id': c.id,
                                'title': aiSessionLabel(c),
                                'group': c.aiGroup,
                                'kind': 'ai_session',
                              },
                        leading: AiStatusIcon(aiSessionState(app, c)),
                        title: aiSessionLabel(c),
                        sub: app.channels[c.aiGroup] == null ? null : app.channelTitle(app.channels[c.aiGroup]!),
                      ),
                ]),
                ListView(children: [
                  for (final u in people)
                    if (match('${u.displayName} ${u.username}'))
                      tile(
                        on: selPeople.containsKey(u.id),
                        toggle: () => selPeople.containsKey(u.id) ? selPeople.remove(u.id) : selPeople[u.id] = u,
                        leading: Avatar(userId: u.id, name: u.displayName, size: 36),
                        title: u.displayName,
                        sub: '@${u.username}',
                      ),
                ]),
              ]),
            ),
            // Ô tìm kiếm cố định dưới danh sách; gõ chữ thì có nút ✕ để xoá.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: TextField(
                controller: searchCtl,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: tr('Xoá'),
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () => set(() {
                            searchCtl.clear();
                            query = '';
                          }),
                        ),
                  hintText: tr('Tìm'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onChanged: (v) => set(() => query = v.trim()),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(children: [
                  Text(tr('Đã chọn {0}', [n]), style: TextStyle(color: pal.sub)),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      // Agent: tìm bot của phiên (để A2A biết gọi ai).
                      final agents = <Map<String, dynamic>>[];
                      for (final a in selAgents.values) {
                        if (a['bot_id'] != null) {
                          agents.add(a);
                          continue;
                        }
                        final bot = (await app.channelUsers(a['session_id'] as String))
                            .where((u) => u.isBot && app.isAssistant(u.id))
                            .firstOrNull;
                        if (bot != null) agents.add({...a, 'bot_id': bot.id, 'username': bot.username});
                      }
                      if (ctx.mounted) Navigator.pop(ctx, RefSelection(selRefs.values.toList(), agents, selPeople.values.toList()));
                    },
                    child: Text(tr('Xong')),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
      );
    }),
  );
}

/// Lúc gửi: hỏi cấp quyền cho trợ lý trong bao lâu (và có cho gửi tin vào chat được tag không). null = huỷ.
Future<({int ttl, bool write})?> askGrant(BuildContext context, List<RefItem> refs, List<MmUser> bots) {
  int ttl = 600;
  bool write = false;
  return showDialog<({int ttl, bool write})>(
    context: context,
    builder: (d) => StatefulBuilder(builder: (d, set) {
      final pal = Pal.of(d);
      final opts = [(600, tr('10 phút')), (3600, tr('1 giờ')), (_untilTonight(), tr('Hết hôm nay'))];
      return AlertDialog(
        title: Text(tr('Cấp quyền cho trợ lý')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('{0} được đọc:', [bots.map((b) => b.displayName).join(', ')]), style: TextStyle(color: pal.text)),
            const SizedBox(height: 6),
            for (final r in refs)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Icon(r.kind == 'chat' ? Icons.chat_bubble_outline : Icons.forum_outlined, size: 16, color: pal.sub),
                  const SizedBox(width: 8),
                  Expanded(child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text))),
                ]),
              ),
            const SizedBox(height: 12),
            Text(tr('Trong bao lâu?'), style: TextStyle(color: pal.sub, fontSize: 13)),
            Wrap(spacing: 8, children: [
              for (final (s, l) in opts) ChoiceChip(label: Text(l), selected: ttl == s, onSelected: (_) => set(() => ttl = s)),
            ]),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: write,
              onChanged: (v) => set(() => write = v ?? false),
              title: Text(tr('Cho phép gửi tin vào chat được tag'), style: TextStyle(color: pal.text, fontSize: 14)),
              subtitle: Text(tr('Tin hiện tên trợ lý kèm nhãn BOT.'), style: TextStyle(color: pal.sub, fontSize: 12.5)),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Hủy'))),
          FilledButton(onPressed: () => Navigator.pop(d, (ttl: ttl, write: write)), child: Text(tr('Cấp quyền và gửi'))),
        ],
      );
    }),
  );
}

int _untilTonight() {
  final now = DateTime.now();
  final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
  return end.difference(now).inSeconds.clamp(600, 86400);
}

/// Xin trạm đẩy cấp vé cho một trợ lý. Trả về props.flygo_refs để gửi kèm tin.
Future<Map<String, dynamic>> requestGrant(AppState app, MmUser bot, List<RefItem> refs, int ttl, bool write) async {
  final r = await http
      .post(Uri.parse('${pushUrlFor(kServerUrl)}/ref/grants'),
          headers: {
            'Authorization': 'Bearer ${app.token}',
            'X-MM-Server': kServerUrl,
            'Content-Type': 'application/json',
            'User-Agent': kUserAgent,
          },
          body: jsonEncode({'bot_id': bot.id, 'ttl_sec': ttl, 'write': write, 'refs': [for (final x in refs) x.toJson()]}))
      .timeout(const Duration(seconds: 15));
  final body = jsonDecode(r.body) as Map;
  if (r.statusCode != 200) throw Exception(body['error'] ?? 'ref/grants ${r.statusCode}');
  final items = [
    for (final it in (body['refs'] as List? ?? const []))
      {
        'ref_id': it['ref_id'],
        'kind': it['kind'] ?? ((it['root_id'] as String?)?.isNotEmpty == true ? 'thread' : 'chat'),
        'channel_id': it['channel_id'],
        if ((it['root_id'] as String?)?.isNotEmpty == true) 'root_id': it['root_id'],
        'name': it['name'],
      },
  ];
  return {'grant_id': body['grant_id'], 'expires_at': body['expires_at'], 'write': write, 'server': kServerUrl, 'bot_id': bot.id, 'items': items};
}
