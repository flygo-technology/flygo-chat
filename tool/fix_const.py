#!/usr/bin/env python3
"""Gỡ `const` ở những chỗ không còn là hằng (sau khi bọc chuỗi bằng tr())."""
import os, re, subprocess
FLUTTER = os.path.expanduser('~/tools/flutter/bin/flutter')
for it in range(80):
    out = subprocess.run([FLUTTER, 'analyze', '--no-pub'], capture_output=True, text=True).stdout
    errs = []
    for m in re.finditer(r'error • (.+?) • (lib/\S+?):(\d+):(\d+) • (\S+)', out):
        if m.group(5).startswith(('const_', 'non_constant', 'invalid_constant', 'const_initialized_with_non_constant_value')):
            errs.append((m.group(2), int(m.group(3)), int(m.group(4))))
    if not errs:
        print('done after', it, 'rounds'); break
    done = set()
    for f, line, col in errs:
        if f in done: continue  # mỗi vòng sửa 1 chỗ/file để vị trí dòng còn đúng
        src = open(f).read().split('\n')
        off = sum(len(l) + 1 for l in src[:line - 1]) + col - 1
        text = '\n'.join(src)
        k = text.rfind('const ', 0, off)
        while k > 0 and re.match(r'\w', text[k - 1]):
            k = text.rfind('const ', 0, k)
        if k < 0: continue
        ls = text.rfind('\n', 0, k) + 1
        prefix = text[ls:k].strip()
        if (prefix == '' and k == ls) or prefix == 'static':
            text = text[:k] + 'final ' + text[k + 6:]
        else:
            text = text[:k] + text[k + 6:]
        open(f, 'w').write(text); done.add(f)
    print('round', it, 'fixed', len(done))
