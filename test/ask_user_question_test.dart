import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/data/models.dart';
import 'package:flygo_chat/ui/agent_view.dart';

void main() {
  test('parses a truncated AskUserQuestion title', () {
    const title = 'AskUserQuestion {"questions":[{"question":"Bạn thường làm gì để thư giãn cuối tuần? (chọn được nhiều)",'
        '"header":"Cuối tuần","options":[{"label":"Đọc sách","description":"Yên tĩnh, nạp kiến thức"},'
        '{"label":"Thể thao","description":"Chạy bộ, gym, đá bóng..."},{"label":"Xem phim","description":"Giải trí tại nhà hoặc r';
    final q = askUserQuestionOf(MmPost({'id': 'p1'}), {'kind': 'tool', 'title': title, 'status': 'pending'})!;
    expect(q['question'], startsWith('Bạn thường làm gì'));
    expect((q['options'] as List).map((o) => o['label']), ['Đọc sách', 'Thể thao', 'Xem phim']);
    expect(q['multi'], true);
  });
  test('parses a complete AskUserQuestion title', () {
    const title = 'AskUserQuestion {"questions":[{"question":"Uống gì?","options":[{"label":"Cà phê"},{"label":"Trà"}],"multiSelect":false}]}';
    final q = askUserQuestionOf(MmPost({'id': 'p1'}), {'title': title})!;
    expect((q['options'] as List).length, 2);
    expect(q['multi'], false);
  });
}
