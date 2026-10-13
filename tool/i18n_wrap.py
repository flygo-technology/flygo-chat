#!/usr/bin/env python3
"""Bọc các chuỗi tiếng Việt trong lib/ bằng tr('...', [args]) và xuất danh sách câu.

Chạy: python3 tool/i18n_wrap.py [--extract-only]
- Chuỗi có ký tự tiếng Việt (hoặc nằm trong ASCII_WORDS) được bọc.
- Phần nội suy $x / ${expr} thành {0}, {1}... và chuyển thành tham số.
- Ghi tool/i18n_keys.json: danh sách câu gốc kèm file:dòng để làm ngữ cảnh dịch.
"""
import json, os, re, sys

VI = re.compile(r'[À-ỹĐđ]')
ASCII_WORDS = {'Chat', 'Video', 'Email', 'GIF', 'Sticker', 'Xong', 'Xoay', 'Thoai'}
SKIP_FILES = {'lib/i18n/', 'lib/config.dart'}


def scan_string(src, i):
    """src[i] là dấu nháy. Trả về (end, parts) với parts = [('text', s) | ('expr', s)]."""
    q = src[i]
    triple = src[i:i + 3] == q * 3
    if triple:
        return None
    j = i + 1
    parts, buf = [], []
    while j < len(src):
        c = src[j]
        if c == '\\':
            buf.append(src[j:j + 2]); j += 2; continue
        if c == q:
            if buf: parts.append(('text', ''.join(buf)))
            return j + 1, parts
        if c == '\n':
            return None
        if c == '$':
            if src[j + 1] == '{':
                depth, k = 1, j + 2
                while k < len(src) and depth:
                    ch = src[k]
                    if ch in '\'"':
                        r = scan_string(src, k)
                        if r is None: return None
                        k = r[0]; continue
                    if ch == '{': depth += 1
                    elif ch == '}': depth -= 1
                    k += 1
                if buf: parts.append(('text', ''.join(buf))); buf = []
                parts.append(('expr', src[j + 2:k - 1]))
                j = k; continue
            m = re.match(r'\$([A-Za-z_]\w*)', src[j:])
            if m:
                if buf: parts.append(('text', ''.join(buf))); buf = []
                parts.append(('expr', m.group(1)))
                j += len(m.group(0)); continue
        buf.append(c); j += 1
    return None


def process(path, keys, write):
    src = open(path, encoding='utf-8').read()
    out, i, changed = [], 0, False
    line = 1
    while i < len(src):
        c = src[i]
        if src.startswith('//', i):
            e = src.find('\n', i)
            e = len(src) if e < 0 else e
            out.append(src[i:e]); i = e; continue
        if src.startswith('import ', i) or src.startswith('export ', i):
            e = src.find('\n', i)
            out.append(src[i:e]); i = e; continue
        if c in '\'"' and not (i > 0 and src[i - 1] == 'r'):
            r = scan_string(src, i)
            if r is None:
                out.append(c); i += 1; continue
            end, parts = r
            text = ''.join(p[1] for p in parts if p[0] == 'text')
            prev = src[max(0, i - 3):i]
            already = src[max(0, i - 3):i] == 'tr(' or src[max(0, i - 3):i].endswith('tr(')
            if (VI.search(text) or (parts == [('text', text)] and text in ASCII_WORDS)) and not already:
                tmpl, args = [], []
                for kind, v in parts:
                    if kind == 'text':
                        tmpl.append(v if c == "'" else v.replace("'", "\\'").replace('\\"', '"'))
                    else:
                        tmpl.append('{%d}' % len(args)); args.append(v)
                t = ''.join(tmpl)
                lineno = src.count('\n', 0, i) + 1
                keys.setdefault(t, f'{os.path.relpath(path)}:{lineno}')
                rep = f"tr('{t}'" + (', [' + ', '.join(args) + ']' if args else '') + ')'
                out.append(rep); i = end; changed = True; continue
            out.append(src[i:end]); i = end; continue
        out.append(c); i += 1
    if changed and write:
        res = ''.join(out)
        if "i18n/i18n.dart" not in res:
            rel = os.path.relpath('lib/i18n/i18n.dart', os.path.dirname(path))
            res = re.sub(r"(^import [^\n]+\n)", "import '" + rel.replace(os.sep, '/') + "';\n\\1", res, count=1, flags=re.M)
        open(path, 'w', encoding='utf-8').write(res)
    return changed


def main():
    write = '--extract-only' not in sys.argv
    keys = {}
    for root, _, files in os.walk('lib'):
        for f in files:
            p = os.path.join(root, f)
            if not f.endswith('.dart') or any(p.startswith(s) for s in SKIP_FILES):
                continue
            process(p, keys, write)
    # Câu đã bọc từ trước (chạy lại script): lấy từ tr('...')
    for root, _, files in os.walk('lib'):
        for f in files:
            p = os.path.join(root, f)
            if not f.endswith('.dart') or p.startswith('lib/i18n/'):
                continue
            src = open(p, encoding='utf-8').read()
            for m in re.finditer(r"\btr\('((?:[^'\\]|\\.)*)'", src):
                keys.setdefault(m.group(1), f'{p}:{src.count(chr(10), 0, m.start()) + 1}')
    json.dump([{'vi': k, 'where': v} for k, v in sorted(keys.items())], open('tool/i18n_keys.json', 'w'), ensure_ascii=False, indent=1)
    print(len(keys), 'keys')


main()
