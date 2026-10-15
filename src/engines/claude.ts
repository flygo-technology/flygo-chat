// Engine Claude: mỗi lượt chạy `claude -p --output-format stream-json`, nói tiếp bằng --resume.
// Quyền: công cụ ngoài allowedTools được hỏi qua tool MCP flygo_chat.approve (--permission-prompt-tool)
// -> runner hiện yêu cầu duyệt trên Flygo.
import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { resolveBin, type Config } from "../config";
import type { Engine, TurnHooks, TurnInput, TurnResult } from "./types";

function describe(name: string, input: any): { kind: "command" | "file" | "tool" | "search"; title: string } {
  switch (name) {
    case "Bash": return { kind: "command", title: `$ ${String(input?.command ?? "").split("\n")[0].slice(0, 160)}` };
    case "Edit": case "MultiEdit": case "Write": case "NotebookEdit":
      return { kind: "file", title: `Sửa ${String(input?.file_path ?? input?.notebook_path ?? "").split("/").pop()}` };
    case "Read": return { kind: "tool", title: `Đọc ${String(input?.file_path ?? "").split("/").pop()}` };
    case "Grep": case "Glob": return { kind: "search", title: `${name} ${input?.pattern ?? ""}` };
    case "WebSearch": return { kind: "search", title: `Tìm web: ${input?.query ?? ""}` };
    case "WebFetch": return { kind: "search", title: `Mở ${input?.url ?? ""}` };
    default: return { kind: "tool", title: name.replace(/^mcp__([^_]+(?:_[^_]+)*)__/, "$1.") };
  }
}

/** claude --resume tìm phiên trong ~/.claude/projects/<cwd>: thư mục làm việc đổi (đổi tên chat, gắn dự án, kênh bí mật về chat cha)
 *  thì chép file phiên sang thư mục mới để vẫn nói tiếp được. */
function adoptSession(id: string, cwd: string) {
  const root = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"), "projects");
  const want = join(root, cwd.replace(/[^a-zA-Z0-9]/g, "-"), `${id}.jsonl`);
  if (existsSync(want) || !existsSync(root)) return;
  for (const d of readdirSync(root)) {
    const f = join(root, d, `${id}.jsonl`);
    if (existsSync(f)) { mkdirSync(dirname(want), { recursive: true }); copyFileSync(f, want); return; }
  }
}

/** File phiên trên máy (thư mục dự án bất kỳ). */
function sessionFile(id: string): string | null {
  const root = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"), "projects");
  if (!existsSync(root)) return null;
  for (const d of readdirSync(root)) { const f = join(root, d, `${id}.jsonl`); if (existsSync(f)) return f; }
  return null;
}

/** Token ngữ cảnh của lần gọi model gần nhất trong file phiên (đọc phần đuôi). */
export async function tailTokens(path: string, pick: (ev: any) => number | null): Promise<number | null> {
  const size = statSync(path).size;
  const tail = await Bun.file(path).slice(Math.max(0, size - 1024 * 1024)).text();
  const lines = tail.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes("tokens")) continue;
    try { const n = pick(JSON.parse(lines[i])); if (n != null) return n; } catch {}
  }
  return Math.round(size / 4); // không thấy: ước theo cỡ file
}

// Tool A2A của flygo_chat: luôn cho phép (nhờ agent khác / gửi tệp kết quả; agent kia tự xin duyệt quyền của nó).
const A2A_TOOLS = ["mcp__flygo_chat__list_agents", "mcp__flygo_chat__ask_agent", "mcp__flygo_chat__return_files", "mcp__flygo_chat__chat_report_out"]; // chat_report_out tự xin duyệt khi cần

const resultText = (c: any) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((x) => x.text ?? "").join("\n") : "");

export class ClaudeEngine implements Engine {
  name = "claude" as const;
  constructor(private cfg: Config, private mcpCommand: { command: string; args: string[] }, private log: (s: string) => void) {}

  async contextTokens(id: string) {
    const f = sessionFile(id);
    if (!f) return null;
    return tailTokens(f, (ev) => {
      const u = ev?.type === "assistant" ? ev.message?.usage : null;
      return u ? (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) : null;
    });
  }

  async runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult> {
    const mcpConfig = JSON.stringify({
      mcpServers: { flygo_chat: { command: this.mcpCommand.command, args: this.mcpCommand.args, env: input.mcpEnv } },
    });
    // Không nạp settings cá nhân (~/.claude/settings.json có thể allow Bash/Write hoặc bypass);
    // quyền của phiên chỉ gồm allowedTools + deny của runner, còn lại hỏi Sếp qua Flygo.
    // claude.fullAccess: toàn quyền, không hỏi, không deny.
    const full = !!this.cfg.claude.fullAccess || !!input.bypass;
    const settings = JSON.stringify({ permissions: full ? { defaultMode: "bypassPermissions" } : { defaultMode: "default", deny: this.cfg.claude.deny } });
    const args = [
      resolveBin(this.cfg.claude.bin), "-p", input.prompt,
      "--output-format", "stream-json", "--verbose", "--include-partial-messages",
      "--setting-sources", "project,local",
      "--settings", settings,
      "--permission-mode", full ? "bypassPermissions" : "default",
      "--mcp-config", mcpConfig,
      ...(full ? [] : ["--permission-prompt-tool", "mcp__flygo_chat__approve", "--allowedTools", [...this.cfg.claude.allowedTools, ...A2A_TOOLS].join(",")]),
      "--append-system-prompt", input.persona,
    ];
    const model = input.model ?? this.cfg.claude.model;
    if (model) args.push("--model", model);
    if (input.effort) args.push("--effort", input.effort);
    if (input.sessionId) { adoptSession(input.sessionId, input.cwd); args.push("--resume", input.sessionId); }
    else if (input.forkFrom && sessionFile(input.forkFrom)) { adoptSession(input.forkFrom, input.cwd); args.push("--resume", input.forkFrom, "--fork-session"); } // phiên mới mang ngữ cảnh phiên cha
    args.push("--name", input.title);

    const proc = Bun.spawn(args, { env: { ...process.env, MCP_TOOL_TIMEOUT: "1800000" }, cwd: input.cwd, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
    const kill = () => proc.kill();
    signal.addEventListener("abort", kill);

    let sessionId = input.sessionId ?? "";
    let final = "";
    let usage: any;
    let isError = false;
    let curMsg = "";
    let gotResult = false;
    let lingering = false;
    const tools = new Map<string, { name: string; input: any }>();
    const stderr = new Response(proc.stderr).text();

    const reader = proc.stdout.getReader();
    const dec = new TextDecoder();
    let buf = "";
    try {
      for (;;) {
        // Sau "result": claude -p có thể (a) chạy tiếp lượt khác (thông báo lệnh nền còn tồn khi resume được xử lý thành lượt riêng),
        // hoặc (b) đứng chờ lệnh nền (vd. find chạy lâu). Im lặng quá LINGER_MS sau result -> coi là (b), dừng hẳn.
        const rd = reader.read();
        const r = gotResult ? await Promise.race([rd, Bun.sleep(LINGER_MS).then(() => null)]) : await rd;
        if (r === null) { lingering = true; break; }
        const { value, done } = r;
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i).trim();
          buf = buf.slice(i + 1);
          if (!line) continue;
          let ev: any;
          try { ev = JSON.parse(line); } catch { continue; }
          if (ev.type !== "result") gotResult = false; // còn lượt tiếp theo
          if (ev.type === "system" && ev.subtype === "init" && ev.session_id) { sessionId = ev.session_id; hooks.session(sessionId); }
          else if (ev.type === "stream_event") {
            const e = ev.event;
            if (e?.type === "message_start") curMsg = e.message?.id ?? curMsg;
            else if (e?.type === "content_block_delta" && e.delta?.type === "text_delta" && curMsg) hooks.text({ id: curMsg, delta: e.delta.text });
          }
          else if (ev.type === "assistant") {
            for (const c of ev.message?.content ?? []) {
              if (c.type === "tool_use") {
                tools.set(c.id, { name: c.name, input: c.input });
                if (c.name === "mcp__flygo_chat__approve" || c.name === "mcp__flygo_chat__chat_report_out" || c.name === "ToolSearch") continue; // report_out: runner tự ghi bước
                const d = describe(c.name, c.input);
                hooks.step({ id: c.id, kind: d.kind, title: d.title, status: "running" });
              } else if (c.type === "text" && c.text?.trim()) {
                hooks.text({ id: ev.message?.id ?? String(ev.uuid), full: c.text, done: true });
              }
            }
          } else if (ev.type === "user") {
            for (const c of ev.message?.content ?? []) {
              if (c.type !== "tool_result") continue;
              const t = tools.get(c.tool_use_id);
              if (!t || t.name === "mcp__flygo_chat__approve" || t.name === "mcp__flygo_chat__chat_report_out" || t.name === "ToolSearch") continue;
              const d = describe(t.name, t.input);
              hooks.step({ id: c.tool_use_id, kind: d.kind, title: d.title, status: c.is_error ? "error" : "done", detail: resultText(c.content).slice(-600) });
            }
          } else if (ev.type === "result") {
            final = ev.result ?? "";
            isError = !!ev.is_error;
            usage = { cost_usd: ev.total_cost_usd, duration_ms: ev.duration_ms, ...ev.usage };
            if (ev.session_id) sessionId = ev.session_id;
            gotResult = true;
          }
        }
      }
      if (lingering) { reader.cancel().catch(() => {}); killTree(proc.pid); }
      const code = lingering ? 0 : await proc.exited;
      if (signal.aborted) throw new Error("đã dừng");
      if (code !== 0 && !final) throw new Error(`claude thoát mã ${code}: ${(await stderr).slice(-400)}`);
      if (isError) throw new Error(final || "claude báo lỗi");
    } finally {
      signal.removeEventListener("abort", kill);
    }
    return { sessionId, text: final, usage };
  }
}

const LINGER_MS = 15_000;

/** Dừng tiến trình và mọi tiến trình con (lệnh nền của agent). */
function killTree(pid: number) {
  if (process.platform === "win32") { Bun.spawnSync(["taskkill", "/T", "/F", "/PID", String(pid)], { stdout: "ignore", stderr: "ignore" }); return; }
  const all: number[] = [];
  const walk = (p: number) => {
    all.push(p);
    const out = Bun.spawnSync(["pgrep", "-P", String(p)], { stdout: "pipe", stderr: "ignore" }).stdout.toString();
    for (const c of out.split("\n").map(Number).filter(Boolean)) walk(c);
  };
  walk(pid);
  for (const p of all.reverse()) try { process.kill(p, "SIGTERM"); } catch {}
}
