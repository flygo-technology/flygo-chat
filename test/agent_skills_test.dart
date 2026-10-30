import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flygo_chat/agent/agent_skills.dart';

void main() {
  test('skillSlug giống runner: bỏ dấu, chữ thường, gạch ngang', () {
    expect(skillSlug('Xử lý hoá đơn VAT'), 'xu-ly-hoa-don-vat');
    expect(skillSlug('  Đối chiếu công nợ!! '), 'doi-chieu-cong-no');
    expect(skillSlug('---'), '');
  });

  test('lưu / đọc / đổi tên / xoá kỹ năng', () async {
    final home = await Directory.systemTemp.createTemp('skills');
    addTearDown(() => home.delete(recursive: true));
    final n = await saveSkillFile(home.path, 'Hoá đơn', 'Xử lý "hoá đơn"\nVAT', '---\nname: x\n---\n# Các bước\n1. Đọc');
    expect(n, 'hoa-don');
    final f = File('${home.path}/skills/hoa-don/SKILL.md');
    final d = await readSkillFile(f.path);
    expect(d!.name, 'hoa-don');
    expect(d.description, 'Xử lý "hoá đơn" VAT');
    expect(d.body, '# Các bước\n1. Đọc');
    File('${home.path}/skills/hoa-don/mau.txt').writeAsStringSync('kèm');
    await saveSkillFile(home.path, 'hoa-don-vat', 'mới', 'thân', oldName: 'hoa-don');
    expect(File('${home.path}/skills/hoa-don-vat/mau.txt').existsSync(), isTrue);
    expect(Directory('${home.path}/skills/hoa-don').existsSync(), isFalse);
    expect(await deleteSkillFile(home.path, 'hoa-don-vat'), isTrue);
    expect(await deleteSkillFile(home.path, 'hoa-don-vat'), isFalse);
  });
}
