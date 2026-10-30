// Kỹ năng và vai trò riêng của từng bot: ~/flygo-agent/bots/<bot_id>/
//   skills/<tên>/SKILL.md (+ tệp kèm)   kỹ năng của bot (chồng lên lớp chung cfg.skillsDir, trùng tên thì bản của bot thắng)
//   ROLE.md                             vai trò / chuyên môn, nối sau persona mặc định
//   memory.md                           (tuỳ chọn) ghi nhớ lâu dài của bot
// Không chép vào thư mục chat (nhiều bot dùng chung): Claude đọc qua --add-dir <home>/.runtime/claude (.claude/skills),
// Codex nhận danh sách kỹ năng (tên, mô tả, đường dẫn SKILL.md) trong ngữ cảnh lượt.
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";

export const BOTS_ROOT = join(homedir(), "flygo-agent", "bots");
export const botHome = (botId: string) => join(BOTS_ROOT, botId);

export interface SkillInfo { name: string; description: string; path: string; source: "bot" | "base" }

const NAME_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
/** Tên skill: chữ thường không dấu, số, gạch ngang. */
export function skillName(raw: string): string {
  const s = String(raw ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[đĐ]/g, "d").toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 63);
  if (!NAME_RE.test(s)) throw new Error(`tên skill không hợp lệ: ${raw}`);
  return s;
}

function frontmatter(md: string): Record<string, string> {
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(md);
  const out: Record<string, string> = {};
  for (const line of m?.[1].split(/\r?\n/) ?? []) {
    const kv = /^([A-Za-z_-]+):\s*(.*)$/.exec(line);
    if (!kv) continue;
    let v = kv[2].trim();
    if (v.startsWith('"')) try { v = JSON.parse(v); } catch {}
    else if (v.startsWith("'") && v.endsWith("'")) v = v.slice(1, -1).replace(/''/g, "'");
    out[kv[1]] = v;
  }
  return out;
}

function scan(dir: string | undefined, source: "bot" | "base"): SkillInfo[] {
  if (!dir || !existsSync(dir)) return [];
  const out: SkillInfo[] = [];
  for (const d of readdirSync(dir)) {
    const f = join(dir, d, "SKILL.md");
    if (!existsSync(f)) continue;
    const fm = frontmatter(readFileSync(f, "utf8"));
    out.push({ name: fm.name || d, description: fm.description || "", path: f, source });
  }
  return out;
}

/** Kỹ năng bot dùng được: lớp chung + của bot (bot ghi đè trùng tên), sắp theo tên. */
export function listSkills(botId: string, baseDir?: string): SkillInfo[] {
  const map = new Map<string, SkillInfo>();
  for (const s of [...scan(baseDir, "base"), ...scan(join(botHome(botId), "skills"), "bot")]) map.set(s.name, s);
  return [...map.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function readSkill(botId: string, name: string, baseDir?: string): string {
  const s = listSkills(botId, baseDir).find((x) => x.name === name || x.name === skillName(name));
  if (!s) throw new Error(`không có skill ${name}`);
  const dir = dirname(s.path);
  const extra = readdirSync(dir, { recursive: true }).map(String).filter((f) => f !== "SKILL.md" && statSync(join(dir, f)).isFile());
  return `${readFileSync(s.path, "utf8")}${extra.length ? `\n\n(tệp kèm trong ${dir}: ${extra.join(", ")})` : ""}`;
}

/** Một kỹ năng để sửa (app sửa từ xa qua relay): tên, mô tả, nội dung (không frontmatter), tệp kèm (đường dẫn tương đối). */
export function skillDoc(botId: string, name: string, baseDir?: string): { name: string; description: string; body: string; source: "bot" | "base"; files: string[] } {
  const s = listSkills(botId, baseDir).find((x) => x.name === name);
  if (!s) throw new Error(`không có skill ${name}`);
  const md = readFileSync(s.path, "utf8");
  const dir = dirname(s.path);
  const files = readdirSync(dir, { recursive: true }).map(String).filter((f) => f !== "SKILL.md" && statSync(join(dir, f)).isFile());
  return { name: s.name, description: s.description, body: md.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, "").trim(), source: s.source, files };
}
/** Tệp kèm của kỹ năng riêng của bot (để giữ lại khi đổi tên). */
export function skillFilesOf(botId: string, rawName: string): SkillFile[] {
  const dir = join(botHome(botId), "skills", skillName(rawName));
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { recursive: true }).map(String).filter((f) => f !== "SKILL.md" && statSync(join(dir, f)).isFile()).map((f) => ({ path: f, from: join(dir, f) }));
}

export interface SkillFile { path: string; content?: string; from?: string }
/** Ghi skill của bot (ghi qua thư mục tạm rồi đổi tên: không để skill dở dang). */
export function saveSkill(botId: string, rawName: string, description: string, content: string, files: SkillFile[] = []): SkillInfo {
  const name = skillName(rawName);
  const root = join(botHome(botId), "skills");
  const dir = join(root, name), tmp = join(root, `.${name}.tmp`);
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(tmp, { recursive: true });
  if (existsSync(dir)) cpSync(dir, tmp, { recursive: true }); // giữ tệp kèm cũ
  const body = String(content ?? "").replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, "").trim(); // bỏ frontmatter agent tự viết
  const desc = String(description ?? "").replace(/\s+/g, " ").trim().slice(0, 1000);
  writeFileSync(join(tmp, "SKILL.md"), `---\nname: ${name}\ndescription: ${JSON.stringify(desc)}\n---\n\n${body}\n`);
  for (const f of files) {
    const target = resolve(tmp, String(f.path ?? ""));
    if (!target.startsWith(tmp + sep) || target.endsWith(`${sep}SKILL.md`)) throw new Error(`đường dẫn tệp kèm không hợp lệ: ${f.path}`);
    mkdirSync(dirname(target), { recursive: true });
    if (f.from) cpSync(f.from, target);
    else writeFileSync(target, String(f.content ?? ""));
  }
  rmSync(dir, { recursive: true, force: true });
  renameSync(tmp, dir);
  return { name, description: desc, path: join(dir, "SKILL.md"), source: "bot" };
}

export function deleteSkill(botId: string, rawName: string): boolean {
  const dir = join(botHome(botId), "skills", skillName(rawName));
  if (!existsSync(dir)) return false;
  rmSync(dir, { recursive: true, force: true });
  return true;
}

export function readRole(botId: string): string {
  try { return readFileSync(join(botHome(botId), "ROLE.md"), "utf8").trim(); } catch { return ""; }
}
export function setRole(botId: string, text: string) {
  mkdirSync(botHome(botId), { recursive: true });
  const t = String(text ?? "").trim();
  if (t) writeFileSync(join(botHome(botId), "ROLE.md"), t + "\n");
  else rmSync(join(botHome(botId), "ROLE.md"), { force: true });
}
/** Một dòng tóm tắt vai trò (dòng đầu, bỏ dấu #). */
export const roleLine = (role: string) => role.split("\n").map((l) => l.replace(/^#+\s*/, "").trim()).find(Boolean)?.slice(0, 160) ?? "";
/** Mốc role=<slug> trong mô tả bot: ngắn, không dấu. */
export const roleSlug = (role: string) => {
  try {
    const s = skillName(roleLine(role).split(/\s+[—–-]\s+|[:,(]/)[0]); // phần trước "—", ":", "," -> vd. "android-dev"
    return s.length <= 24 ? s : s.slice(0, 25).replace(/-[^-]*$/, "") || s.slice(0, 24);
  } catch { return ""; }
};

/** Claude: dựng <home>/.runtime/claude/.claude/skills từ lớp chung + skill của bot; trả về thư mục cho --add-dir. */
export function claudeSkillsDir(botId: string, baseDir?: string): string | null {
  const skills = listSkills(botId, baseDir);
  const rt = join(botHome(botId), ".runtime", "claude");
  const target = join(rt, ".claude", "skills");
  rmSync(target, { recursive: true, force: true });
  if (!skills.length) return null;
  mkdirSync(target, { recursive: true });
  for (const s of skills) cpSync(dirname(s.path), join(target, s.name), { recursive: true });
  return rt;
}

export const memoryPath = (botId: string) => join(botHome(botId), "memory.md");
