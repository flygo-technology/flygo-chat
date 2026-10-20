import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/ui/qr_login.dart';

void main() {
  test('QR payload round-trips', () {
    final p = QrLoginPayload(
        server: 'https://chat.dnd-global.com',
        host: '192.168.1.25',
        port: 51234,
        nonce: 'abcDEF_-123',
        key: List.generate(32, (i) => i * 7 % 256),
        device: 'MacBook Pro của Ba');
    final q = QrLoginPayload.parse(p.encode())!;
    expect(q.server, p.server);
    expect(q.host, p.host);
    expect(q.port, p.port);
    expect(q.nonce, p.nonce);
    expect(q.key, p.key);
    expect(q.device, p.device);
  });

  test('foreign QR codes are ignored', () {
    expect(QrLoginPayload.parse('https://example.com'), isNull);
    expect(QrLoginPayload.parse('flygochat-qr:login?v=2&s=x'), isNull);
  });
}
