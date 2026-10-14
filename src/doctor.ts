// Kiểm tra máy có Codex / Claude Code và đã đăng nhập chưa.
import { resolveBin } from "./config";
export interface EngineCheck { installed: boolean; version?: string; loggedIn: boolean; account?: string; path?: string; error?: string }
export interface DoctorReport { codex: EngineCheck; claude: EngineCheck; platform: string; hostname: string }

async function run(cmd: string[], timeoutMs = 15000): Promise<{ code: number; out: string }> {
  try {
    const p = Bun.spawn(cmd, { env: { ...process.env }, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
    const t = setTimeout(() => p.kill(), timeoutMs);
    const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
    const code = await p.exited;
    clearTimeout(t);
    return { code, out: (out + err).trim() };
  } catch (e) {
    return { code: -1, out: String(e) };
  }
}

async function checkCodex(): Promise<EngineCheck> {
  const path = resolveBin("codex");
  if (path === "codex") return { installed: false, loggedIn: false };
  const v = await run([path, "--version"]);
  const s = await run([path, "login", "status"]);
  return { installed: true, path, version: v.out.split("\n").pop(), loggedIn: s.code === 0, account: s.code === 0 ? s.out.split("\n").pop() : undefined, error: s.code === 0 ? undefined : s.out.slice(0, 200) };
}

async function checkClaude(): Promise<EngineCheck> {
  const path = resolveBin("claude");
  if (path === "claude") return { installed: false, loggedIn: false };
  const v = await run([path, "--version"]);
  const s = await run([path, "auth", "status"]);
  let loggedIn = false, account: string | undefined;
  try { const j = JSON.parse(s.out); loggedIn = !!j.loggedIn; account = j.email ?? j.authMethod; } catch { loggedIn = s.code === 0; }
  return { installed: true, path, version: v.out.split("\n")[0], loggedIn, account, error: loggedIn ? undefined : s.out.slice(0, 200) };
}

export async function doctor(): Promise<DoctorReport> {
  const [codex, claude] = await Promise.all([checkCodex(), checkClaude()]);
  return { codex, claude, platform: `${process.platform}-${process.arch}`, hostname: (await import("node:os")).hostname() };
}
