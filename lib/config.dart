import 'package:flutter/material.dart';

const kServerUrl = 'https://chat.flygo.vn';
const kTeamName = 'team';
const kUserAgent = 'DNDChat/1.0 (Flutter)';
const kMobileScheme = 'dndchat';

/// Bảng màu theo phong cách WhatsApp.
class WaColors {
  static const teal = Color(0xFF008069);
  static const tealDark = Color(0xFF005C4B);
  static const green = Color(0xFF25D366);
  static const chatBg = Color(0xFFEFEAE2);
  static const outBubble = Color(0xFFD9FDD3);
  static const inBubble = Colors.white;
  static const tickBlue = Color(0xFF53BDEB);
  static const subtle = Color(0xFF667781);
  static const divider = Color(0xFFE9EDEF);
  static const panelBg = Color(0xFFF0F2F5);

  // Màu tên người gửi trong nhóm, giống WhatsApp.
  static const senderColors = [
    Color(0xFF1F7AEC), Color(0xFFE542A3), Color(0xFF02A698), Color(0xFFD3396D),
    Color(0xFF7F66FF), Color(0xFFFA6533), Color(0xFF06CF9C), Color(0xFFC4532D),
  ];
  static Color sender(String userId) =>
      senderColors[userId.codeUnits.fold<int>(0, (a, b) => a + b) % senderColors.length];
}
