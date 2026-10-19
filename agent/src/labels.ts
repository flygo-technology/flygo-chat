// Nhãn ngắn của bước (props.flygo_agent.steps[].label): mô tả việc của bước cho người đọc, kiểu "Đọc runner.ts", "Tìm WS_PING", "npm test".

const MAX = 60;
export const clip = (s: string, n = MAX) => { const t = String(s ?? "").replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n - 1).trimEnd() + "…" : t; };
export const base = (p: string) => String(p ?? "").replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "";
const unquote = (s: string) => s.replace(/^(['"])(.*)\1$/s, "$2");

/** Bỏ vỏ shell: `/bin/zsh -lc '…'`, `bash -c "…"`, `powershell.exe -NoProfile -Command "…"`, `cmd /c …`. */
function unwrap(cmd: string): string {
  let c = cmd.trim();
  for (let i = 0; i < 3; i++) {
    const m = /^(?:"[^"]*[\\/])?(?:\S*[\\/])?(?:ba|z|da)?sh(?:\.exe)?"?\s+-l?c\s+([\s\S]+)$/i.exec(c)
      ?? /^(?:"[^"]*[\\/])?(?:\S*[\\/])?(?:powershell|pwsh)(?:\.exe)?"?\s+(?:-\w+\s+(?:Bypass\s+)?)*?-(?:Command|c)\s+([\s\S]+)$/i.exec(c)
      ?? /^(?:\S*[\\/])?cmd(?:\.exe)?\s+\/[cC]\s+([\s\S]+)$/i.exec(c);
    if (!m) break;
    c = unquote(m[1].trim());
  }
  return c;
}

const READ = /^(cat|head|tail|less|more|bat|type|Get-Content|gc)$/i;
const FIND = /^(rg|grep|egrep|ag|ack|Select-String|sls|findstr)$/i;
const LIST = /^(ls|dir|tree|Get-ChildItem|gci|find|fd)$/i;

/** Câu lệnh -> nhãn dễ đọc: bỏ vỏ shell, bỏ `cd … &&`, lấy lệnh chính (chương trình + tham số chính), tối đa ~60 ký tự. */
export function commandLabel(cmd: string): string {
  let c = unwrap(String(cmd ?? "")).split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"))[0] ?? "";
  // bỏ các bước dọn đường: cd / set -e / export / Set-Location
  const parts = c.split(/\s*(?:&&|;|\|\|)\s*/).filter(Boolean);
  const main = parts.find((p) => !/^(cd|pushd|set|export|Set-Location|sl|source|\.)\b/i.test(p)) ?? parts[0] ?? c;
  const first = main.split(/\s+\|\s+/)[0]; // lệnh đầu của pipe
  const toks = first.match(/"[^"]*"|'[^']*'|\S+/g) ?? [];
  if (!toks.length) return clip(c);
  const prog = base(unquote(toks[0]!)).replace(/\.exe$/i, "");
  const args = toks.slice(1).map(unquote);
  const pos = args.filter((a) => !a.startsWith("-"));
  const paths = pos.filter((a) => /[./\\]/.test(a) && !/^\d+(\.\d+)?$/.test(a)); // tham số trông như đường dẫn (bỏ số của -TotalCount 20…)
  if (READ.test(prog) && pos.length) return clip(`Đọc ${(paths.length ? paths : pos).map(base).join(", ")}`);
  if (/^sed$/i.test(prog) && args.includes("-n") && pos.length >= 2) return clip(`Đọc ${base(pos[pos.length - 1])}`);
  if (FIND.test(prog) && pos.length) return clip(`Tìm ${pos[0]}${pos[1] ? ` trong ${base(pos[1])}` : ""}`);
  if (LIST.test(prog)) return clip(`Liệt kê ${pos[0] ? base(pos[0]) : "thư mục"}`);
  return clip([prog, ...args].join(" "));
}

/** "mcp__flygo_chat__chat_history" -> "flygo_chat · chat_history". */
export function mcpLabel(server: string, tool: string) { return clip(`${server} · ${tool}`); }
export function mcpFromName(name: string): string | null {
  const m = /^mcp__(.+?)__(.+)$/.exec(name);
  return m ? mcpLabel(m[1], m[2]) : null;
}
export function hostOf(url: string) { try { return new URL(url).host; } catch { return clip(url, 40); } }
