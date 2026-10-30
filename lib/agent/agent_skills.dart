import 'dart:convert';
import 'dart:io';

/// Kỹ năng riêng của một trợ lý trên máy chạy runner: `<home bot>/skills/<tên>/SKILL.md` (+ tệp kèm), cùng định dạng
/// runner ghi (agent/src/skills.ts): frontmatter `name`, `description` (chuỗi JSON) rồi nội dung markdown.
/// App máy tính chạy cùng máy với trợ lý thì đọc / ghi thẳng các tệp này; runner đọc lại mỗi lượt (có hiệu lực từ lượt sau).

/// Chữ có dấu tiếng Việt -> chữ không dấu (để đặt tên skill).
const _accents = {
  'a': 'àáạảãâầấậẩẫăằắặẳẵ',
  'e': 'èéẹẻẽêềếệểễ',
  'i': 'ìíịỉĩ',
  'o': 'òóọỏõôồốộổỗơờớợởỡ',
  'u': 'ùúụủũưừứựửữ',
  'y': 'ỳýỵỷỹ',
  'd': 'đ',
};

/// Tên skill như runner: chữ thường không dấu, số, gạch ngang (tối đa 63 ký tự); rỗng nếu không hợp lệ.
String skillSlug(String raw) {
  final b = StringBuffer();
  for (final ch in raw.toLowerCase().split('')) {
    var c = ch;
    for (final e in _accents.entries) {
      if (e.value.contains(ch)) c = e.key;
    }
    b.write(c);
  }
  var s = b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 63) s = s.substring(0, 63);
  return RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(s) ? s : '';
}

/// Nội dung một SKILL.md: frontmatter + phần thân.
class SkillDoc {
  final String name;
  final String description;
  final String body;
  const SkillDoc(this.name, this.description, this.body);
}

final _front = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?');

SkillDoc parseSkill(String md, {String fallbackName = ''}) {
  final m = _front.firstMatch(md);
  final fm = <String, String>{};
  for (final line in (m?.group(1) ?? '').split(RegExp(r'\r?\n'))) {
    final kv = RegExp(r'^([A-Za-z_-]+):\s*(.*)$').firstMatch(line);
    if (kv == null) continue;
    var v = kv.group(2)!.trim();
    if (v.startsWith('"')) {
      try {
        v = jsonDecode(v) as String;
      } catch (_) {}
    } else if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) {
      v = v.substring(1, v.length - 1).replaceAll("''", "'");
    }
    fm[kv.group(1)!] = v;
  }
  return SkillDoc(fm['name'] ?? fallbackName, fm['description'] ?? '', (m == null ? md : md.substring(m.end)).trim());
}

String _sep() => Platform.pathSeparator;

/// Đọc SKILL.md (đường dẫn runner trả về); null nếu không đọc được.
Future<SkillDoc?> readSkillFile(String path) async {
  try {
    final f = File(path);
    final dir = f.parent.path.split(_sep()).last;
    return parseSkill(await f.readAsString(), fallbackName: dir);
  } catch (_) {
    return null;
  }
}

/// Ghi kỹ năng riêng của bot vào `<home>/skills/<tên>`. [oldName] khác tên mới: đổi tên thư mục (giữ tệp kèm).
/// Ghi ra tệp tạm rồi đổi tên: runner không đọc phải tệp dở dang. Trả về tên đã chuẩn hoá.
Future<String> saveSkillFile(String home, String rawName, String description, String content, {String? oldName}) async {
  final name = skillSlug(rawName);
  if (name.isEmpty) throw const FormatException('invalid skill name');
  final root = Directory('$home${_sep()}skills');
  final dir = Directory('${root.path}${_sep()}$name');
  if (oldName != null && oldName != name) {
    final old = Directory('${root.path}${_sep()}$oldName');
    if (await dir.exists()) throw const FileSystemException('skill exists');
    if (await old.exists()) await old.rename(dir.path);
  }
  await dir.create(recursive: true);
  final body = content.replaceFirst(_front, '').trim();
  var desc = description.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (desc.length > 1000) desc = desc.substring(0, 1000);
  final tmp = File('${dir.path}${_sep()}.SKILL.md.tmp');
  await tmp.writeAsString('---\nname: $name\ndescription: ${jsonEncode(desc)}\n---\n\n$body\n', flush: true);
  await tmp.rename('${dir.path}${_sep()}SKILL.md');
  return name;
}

/// Xoá kỹ năng riêng của bot (cả tệp kèm). false nếu không có.
Future<bool> deleteSkillFile(String home, String name) async {
  final dir = Directory('$home${_sep()}skills${_sep()}${skillSlug(name)}');
  if (skillSlug(name).isEmpty || !await dir.exists()) return false;
  await dir.delete(recursive: true);
  return true;
}
