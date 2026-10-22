import '../i18n/i18n.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'reaction_usage.dart';
import 'theme.dart';

class MenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const MenuAction(this.icon, this.label, this.onTap, {this.danger = false});
}

/// Menu nổi khi nhấn giữ tin nhắn, kiểu WhatsApp: nền mờ, thanh cảm xúc ở
/// trên, bản xem trước tin ở giữa, các thao tác ở dưới.
Future<void> showMessageMenu({
  required BuildContext context,
  required AppState app,
  required MmPost post,
  required bool mine,
  required List<MenuAction> actions,
  Rect? anchor,
}) {
  HapticFeedback.mediumImpact();
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('Đóng'),
    barrierColor: Colors.black.withValues(alpha: .25),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, _, _) => Material(
      type: MaterialType.transparency,
      child: _MessageMenu(app: app, post: post, mine: mine, actions: actions, anchor: anchor),
    ),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(scale: Tween(begin: .96, end: 1.0).animate(anim), child: child),
    ),
  );
}

class _MessageMenu extends StatelessWidget {
  final AppState app;
  final MmPost post;
  final bool mine;
  final List<MenuAction> actions;
  final Rect? anchor;
  const _MessageMenu({required this.app, required this.post, required this.mine, required this.actions, this.anchor});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final myReaction = post.reactions.entries.where((e) => e.value.contains(app.me?.id)).map((e) => e.key).firstOrNull;
    final align = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final (previewMax, actionsMax) = _heights(context);

    void react(String name) {
      Navigator.pop(context);
      if (myReaction != name) ReactionUsage.used(name);
      app.toggleReaction(post, name);
    }

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(context),
        onSecondaryTap: () => Navigator.pop(context),
        child: _placed(context, Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: align, children: [
                  if (post.sendState == SendState.sent)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: pal.surface,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 4))],
                      ),
                      // Tối đa 8 cảm xúc theo thói quen + nút thêm: màn hình hẹp thì thu nhỏ cả thanh cho vừa.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final e in ReactionUsage.quick)
                          _ReactButton(emoji: emojiOf(e), selected: myReaction == e, onTap: () => react(e)),
                        _ReactButton(
                          icon: Icons.add,
                          onTap: () async {
                            final name = await showEmojiPicker(context);
                            if (name != null && context.mounted) react(name);
                          },
                        ),
                      ]),
                      ),
                    ),
                  const SizedBox(height: 10),
                  _Preview(app: app, post: post, mine: mine, maxHeight: previewMax),
                  const SizedBox(height: 10),
                  Container(
                    width: 250,
                    // Nhiều thao tác mà màn hình thấp: danh sách cuộn được thay vì tràn ra ngoài màn hình.
                    constraints: BoxConstraints(maxHeight: actionsMax),
                    decoration: BoxDecoration(
                      color: pal.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 4))],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SingleChildScrollView(
                      child: Column(children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) Divider(height: 1, thickness: .6, color: pal.divider),
                        InkWell(
                          onTap: () {
                            Navigator.pop(context);
                            actions[i].onTap();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                            child: Row(children: [
                              Expanded(
                                child: Text(actions[i].label,
                                    style: TextStyle(
                                        fontSize: 16.5, color: actions[i].danger ? Colors.redAccent : pal.text)),
                              ),
                              Icon(actions[i].icon, size: 21, color: actions[i].danger ? Colors.redAccent : pal.text),
                            ]),
                          ),
                        ),
                      ],
                    ]),
                    ),
                  ),
                ])),
      ),
    );
  }

  /// Chiều cao tối đa của bản xem trước tin và của danh sách thao tác để cả cụm menu (thanh cảm xúc 54 + khoảng
  /// cách) luôn nằm gọn trong màn hình: thiếu chỗ thì thu bản xem trước trước, rồi cho danh sách thao tác cuộn.
  (double, double) _heights(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final avail = size.height - pad.top - pad.bottom - 16 - 54 - 20;
    final actionsH = actions.length * 49.0;
    final preview = (avail - actionsH).clamp(60.0, 280.0);
    return (preview, (avail - preview).clamp(120.0, actionsH));
  }

  /// Đặt cụm menu: có [anchor] thì bám theo vị trí tin nhắn (thanh cảm xúc ngay trên,
  /// thao tác ngay dưới, tự đẩy lên nếu sát đáy); không có thì đặt giữa màn hình.
  Widget _placed(BuildContext context, Widget menu) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final a = anchor;
    if (a == null) {
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: size.width > 700 ? 520 : size.width),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: menu),
          ),
        ),
      );
    }
    final (previewMax, actionsMax) = _heights(context);
    final previewH = a.height.clamp(40.0, previewMax);
    final total = 54 + 10 + previewH + 10 + actionsMax;
    var top = a.top - 64;
    final minTop = pad.top + 8;
    final maxTop = size.height - pad.bottom - 8 - total;
    if (top > maxTop) top = maxTop;
    if (top < minTop) top = minTop;
    return Stack(children: [
      Positioned(
        top: top,
        left: mine ? null : a.left.clamp(8.0, size.width - 260),
        right: mine ? (size.width - a.right).clamp(8.0, size.width - 260) : null,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: (size.width - 16).clamp(0, 520)), child: menu),
      ),
    ]);
  }
}

class _ReactButton extends StatelessWidget {
  final String? emoji;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  const _ReactButton({this.emoji, this.icon, this.selected = false, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? pal.surface2 : null),
        child: emoji != null
            ? Text(emoji!, style: const TextStyle(fontSize: 28))
            : Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(shape: BoxShape.circle, color: pal.surface2),
                child: Icon(icon, color: pal.sub, size: 22),
              ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final AppState app;
  final MmPost post;
  final bool mine;
  final double maxHeight;
  const _Preview({required this.app, required this.post, required this.mine, this.maxHeight = 280});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return Container(
      constraints: BoxConstraints(maxWidth: width > 700 ? 420 : width * .8, maxHeight: maxHeight),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: mine ? pal.outBubble : pal.inBubble, borderRadius: BorderRadius.circular(18)),
      child: SingleChildScrollView(
        child: Text(
          post.message.isNotEmpty ? plainPreview(post.message) : app.previewText(post),
          style: TextStyle(fontSize: 17, color: pal.text, height: 1.3),
        ),
      ),
    );
  }
}

/// Bảng chọn emoji đầy đủ; trả về tên emoji theo Mattermost.
Future<String?> showEmojiPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .45,
          child: Column(children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              width: 36,
              height: 5,
              decoration: BoxDecoration(color: pal.surface2, borderRadius: BorderRadius.circular(3)),
            ),
            Expanded(
              child: GridView.extent(
                maxCrossAxisExtent: 52,
                padding: const EdgeInsets.all(10),
                children: [
                  for (final (name, char) in emojiList)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(ctx, name),
                      child: Center(child: Text(char, style: const TextStyle(fontSize: 30))),
                    ),
                ],
              ),
            ),
          ]),
        ),
      );
    },
  );
}

/// Ai đã thả cảm xúc gì; bấm vào cảm xúc của mình để gỡ.
Future<void> showReactionDetails(BuildContext context, AppState app, MmPost post) {
  return showModalBottomSheet(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      final pal = Pal.of(ctx);
      final rows = <(String, String)>[
        for (final e in post.reactions.entries)
          for (final u in e.value) (u, e.key),
      ];
      rows.sort((a, b) => a.$1 == app.me?.id ? -1 : (b.$1 == app.me?.id ? 1 : 0));
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Row(children: [
              Text(tr('{0} cảm xúc', [rows.length]),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: pal.text)),
              const Spacer(),
              Text(post.reactions.keys.map(emojiOf).join(' '), style: const TextStyle(fontSize: 20)),
            ]),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .5),
            child: ListView(shrinkWrap: true, children: [
              for (final (uid, emoji) in rows)
                ListTile(
                  leading: Avatar(userId: uid, name: app.users[uid]?.displayName ?? '?', size: 40),
                  title: nameText(uid == app.me?.id ? tr('Bạn') : (app.users[uid]?.displayName ?? tr('Người dùng')),
                      bot: app.users[uid]?.isBot == true, engine: engineOf(app.users[uid]),
                      style: TextStyle(color: pal.text, fontWeight: FontWeight.w500)),
                  subtitle: uid == app.me?.id ? Text(tr('Nhấn để gỡ'), style: TextStyle(color: pal.sub)) : null,
                  trailing: Text(emojiOf(emoji), style: const TextStyle(fontSize: 26)),
                  onTap: uid == app.me?.id
                      ? () {
                          Navigator.pop(ctx);
                          app.toggleReaction(post, emoji);
                        }
                      : null,
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
}
