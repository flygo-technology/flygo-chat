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

/** Codex có thể xác thực không qua `codex login`: provider trong config.toml có experimental_bearer_token,
 *  hoặc env_key mà biến đó đã đặt, hoặc OPENAI_API_KEY. */
async function codexProviderAuth(): Promise<string | undefined> {
  if (process.env.OPENAI_API_KEY) return "OPENAI_API_KEY";
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  const home = process.env.CODEX_HOME || join(homedir(), ".codex");
  try {
    const cfg: any = Bun.TOML.parse(await Bun.file(join(home, "config.toml")).text());
    const name = cfg.profile && cfg.profiles?.[cfg.profile]?.model_provider || cfg.model_provider;
    const p = name && cfg.model_providers?.[name];
    if (!p) return undefined;
    if (p.experimental_bearer_token) return `provider ${name} (bearer token)`;
    if (p.env_key && process.env[p.env_key]) return `provider ${name} (${p.env_key})`;
  } catch {}
  return undefined;
}

async function checkCodex(bin = "codex", skipLogin = false): Promise<EngineCheck> {
  const path = resolveBin(bin);
  if (path === bin && !(await Bun.file(bin).exists())) return { installed: false, loggedIn: false };
  const v = await run([path, "--version"]);
  const s = await run([path, "login", "status"]);
  if (s.code !== 0) {
    const alt = skipLogin ? "skipLoginCheck" : await codexProviderAuth();
    if (alt) return { installed: true, path, version: v.out.split("\n").pop(), loggedIn: true, account: alt };
  }
  return { installed: true, path, version: v.out.split("\n").pop(), loggedIn: s.code === 0, account: s.code === 0 ? s.out.split("\n").pop() : undefined, error: s.code === 0 ? undefined : s.out.slice(0, 200) };
}

async function checkClaude(bin = "claude"): Promise<EngineCheck> {
  const path = resolveBin(bin);
  if (path === bin && !(await Bun.file(bin).exists())) return { installed: false, loggedIn: false };
  const v = await run([path, "--version"]);
  const s = await run([path, "auth", "status"]);
  let loggedIn = false, account: string | undefined;
  try { const j = JSON.parse(s.out); loggedIn = !!j.loggedIn; account = j.email ?? j.authMethod; } catch { loggedIn = s.code === 0; }
  return { installed: true, path, version: v.out.split("\n")[0], loggedIn, account, error: loggedIn ? undefined : s.out.slice(0, 200) };
}

export async function doctor(bins: { codex?: string; claude?: string; codexSkipLogin?: boolean } = {}): Promise<DoctorReport> {
  const [codex, claude] = await Promise.all([checkCodex(bins.codex, bins.codexSkipLogin), checkClaude(bins.claude)]);
  return { codex, claude, platform: `${process.platform}-${process.arch}`, hostname: (await import("node:os")).hostname() };
}
