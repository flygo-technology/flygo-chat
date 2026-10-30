// Engine Antigravity CLI (agy): mỗi lượt chạy `agy -p <prompt> --output-format stream-json`, nói tiếp bằng --conversation <id>.
// agy không có --mcp-config / --append-system-prompt / --permission-prompt-tool: runner dựng cho mỗi lượt một thư mục riêng
// (CONFIG_DIR/agy/run-<khoá lượt>) rồi thêm vào workspace bằng --add-dir. agy nạp cấu hình .agents/ của mọi thư mục workspace:
//   .agents/mcp_config.json   MCP server flygo_chat của lượt (env riêng của lượt)
//   .agents/hooks.json        hook PreToolUse -> `flygo-agent agy-hook` -> runner hỏi duyệt trên chat (như Claude)
//   AGENTS.md                 persona + vai trò của bot
// Không ghi gì vào thư mục làm việc (thư mục chat dùng chung / thư mục code của người dùng); xoá thư mục lượt khi xong.
// -p không hỏi được người dùng: công cụ cần duyệt mà không ai duyệt thì agy "từ chối mềm". Vì vậy hook tự hỏi runner rồi trả
// auto_approve / deny; hook không chạy được thì công cụ bị từ chối (an toàn).
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { CONFIG_DIR, AGY_DEFAULT_MODEL, resolveBin, type Config } from "../config";
import { base, clip, commandLabel, hostOf, mcpLabel } from "../labels";
import type { StepKind, StepStatus } from "../card";
import type { Engine, EngineInventory, PermMode, TurnHooks, TurnInput, TurnResult } from "./types";
import { hidden, killTree } from "./claude";

export const AGY_EFFORTS = ["low", "medium", "high", "xhigh", "max"];
const LINGER_MS = 15_000;
/** Biến môi trường cho mọi lần gọi agy của runner: không tự cập nhật giữa chừng (chủ máy cập nhật bằng `agy update`). */
export const AGY_ENV = { AGY_CLI_DISABLE_AUTO_UPDATE: "true" };

// ---------------------------------------------------------------- tên công cụ của agy
/** Lấy tham số theo nhiều cách viết (CommandLine / command_line / command…), không phân biệt hoa thường. */
export function arg(o: any, ...keys: string[]): string {
  if (!o || typeof o !== "object") return "";
  const norm = (k: string) => k.toLowerCase().replace(/[_-]/g, "");
  const want = keys.map(norm);
  for (const [k, v] of Object.entries(o)) if (want.includes(norm(k)) && v != null && v !== "") return typeof v === "string" ? v : JSON.stringify(v);
  return "";
}
const fileOf = (a: any) => arg(a, "TargetFile", "AbsolutePath", "FilePath", "File", "Path", "file_path");

/** Tên MCP của agy -> dạng Claude "mcp__server__tool" (để dùng chung nhãn / danh sách ẩn). null nếu không phải MCP. */
export function mcpName(name: string): string | null {
  const n = String(name ?? "");
  if (n.startsWith("mcp__")) return n;
  const m = /^(?:mcp[_:/.]+)?(flygo_chat)[/.:_]+(.+)$/.exec(n) ?? /^mcp[_:/.]+([^/.:]+)[/.:]+(.+)$/.exec(n) ?? /^([^/]+)\/(.+)$/.exec(n);
  return m ? `mcp__${m[1]}__${m[2]}` : null;
}

export type ToolClass = "read" | "edit" | "command" | "flygo" | "other";
const READ_TOOLS = new Set(["view_file", "view_file_outline", "view_code_item", "read_file", "list_dir", "grep_search", "find_by_name", "codebase_search",
  "search_web", "read_url_content", "command_status", "task_boundary", "notify_user", "list_resources", "read_resource", "invoke_subagent",
  "manage_subagents", "send_message", "read_terminal", "view_content_chunk", "search_in_file", "get_task_status", "todo_write", "update_plan"]);
const EDIT_TOOLS = new Set(["write_to_file", "replace_file_content", "multi_replace_file_content", "edit_file", "create_file", "delete_file", "write_file", "edit_notebook"]);
const COMMAND_TOOLS = new Set(["run_command", "send_command_input", "execute_command", "shell"]);
/** Nhóm công cụ để quyết định có cần hỏi duyệt không. */
export function toolClass(name: string): ToolClass {
  const n = String(name ?? "");
  const mcp = mcpName(n);
  if (mcp?.startsWith("mcp__flygo_chat__")) return "flygo";
  if (COMMAND_TOOLS.has(n)) return "command";
  if (EDIT_TOOLS.has(n)) return "edit";
  if (READ_TOOLS.has(n) || /^(view|list|read|find|search|grep|get)_/.test(n)) return "read";
  return "other";
}

/** Bước trên thẻ cho một lần gọi công cụ của agy. */
export function describeAgy(name: string, a: any): { kind: StepKind; title: string; label: string } {
  const f = base(fileOf(a));
  switch (name) {
    case "run_command": case "send_command_input": {
      const cmd = arg(a, "CommandLine", "command", "Input");
      return { kind: "command", title: `$ ${cmd.split("\n")[0].slice(0, 160)}`, label: commandLabel(cmd) };
    }
    case "write_to_file": case "create_file": case "write_file": return { kind: "file", title: `Sửa ${f}`, label: clip(`Tạo ${f}`) };
    case "replace_file_content": case "multi_replace_file_content": case "edit_file": case "edit_notebook": return { kind: "file", title: `Sửa ${f}`, label: clip(`Sửa ${f}`) };
    case "delete_file": return { kind: "file", title: `Xoá ${f}`, label: clip(`Xoá ${f}`) };
    case "view_file": case "view_file_outline": case "view_code_item": case "read_file": return { kind: "tool", title: `Đọc ${f}`, label: clip(`Đọc ${f}`) };
    case "list_dir": { const d = base(arg(a, "DirectoryPath", "Path")); return { kind: "tool", title: `Liệt kê ${d}`, label: clip(`Liệt kê ${d || "thư mục"}`) }; }
    case "grep_search": case "codebase_search": { const q = arg(a, "Query", "Pattern"); return { kind: "search", title: `${name} ${q}`, label: clip(`Tìm ${q}`) }; }
    case "find_by_name": { const q = arg(a, "Pattern", "Query"); return { kind: "search", title: `${name} ${q}`, label: clip(`Tìm ${q}`) }; }
    case "search_web": { const q = arg(a, "query", "Query"); return { kind: "search", title: `Tìm web: ${q}`, label: clip(`Tìm web ${q}`) }; }
    case "read_url_content": { const u = arg(a, "Url", "url"); return { kind: "search", title: `Mở ${u}`, label: clip(`Mở ${hostOf(u)}`) }; }
    case "invoke_subagent": return { kind: "tool", title: name, label: clip(arg(a, "description", "Task", "prompt") || "Giao việc cho agent phụ") };
  }
  const mcp = mcpName(name);
  if (mcp) { const m = /^mcp__(.+?)__(.+)$/.exec(mcp)!; return { kind: "tool", title: `${m[1]}.${m[2]}`, label: mcpLabel(m[1], m[2]) }; }
  if (name.startsWith("browser_")) return { kind: "tool", title: name, label: clip(`Trình duyệt · ${name.slice(8)}`) };
  return { kind: "tool", title: name, label: clip(name) };
}

/** Công cụ agy -> dạng Claude cho lời xin duyệt của runner (approvalOf: lệnh, tệp + nội dung / thay đổi, tool). */
export function approvalInput(name: string, a: any): { tool_name: string; input: any } {
  const file = fileOf(a);
  switch (name) {
    case "run_command": case "send_command_input": return { tool_name: "Bash", input: { command: arg(a, "CommandLine", "command", "Input"), description: arg(a, "Cwd") ? `trong ${arg(a, "Cwd")}` : undefined } };
    case "write_to_file": case "create_file": case "write_file": return { tool_name: "Write", input: { file_path: file, content: arg(a, "CodeContent", "content") } };
    case "replace_file_content": case "edit_file": return { tool_name: "Edit", input: { file_path: file, old_string: arg(a, "TargetContent", "old_string"), new_string: arg(a, "ReplacementContent", "new_string", "CodeEdit") } };
    case "multi_replace_file_content": {
      const chunks = (a?.ReplacementChunks ?? a?.replacementChunks ?? a?.chunks ?? []) as any[];
      return { tool_name: "MultiEdit", input: { file_path: file, edits: (Array.isArray(chunks) ? chunks : []).map((c) => ({ old_string: arg(c, "TargetContent"), new_string: arg(c, "ReplacementContent") })) } };
    }
    case "read_url_content": return { tool_name: "WebFetch", input: { url: arg(a, "Url", "url") } };
  }
  return { tool_name: mcpName(name) ?? name, input: a ?? {} };
}

// ---------------------------------------------------------------- hook PreToolUse (lệnh `flygo-agent agy-hook`)
export type HookDecision = { decision: "allow" | "auto_approve" | "deny"; reason?: string };
/** Hook quyết theo chế độ quyền: "ask" = phải hỏi người dùng qua runner. */
export function hookPlan(name: string, mode: PermMode | string): HookDecision | "ask" {
  const c = toolClass(name);
  if (c === "flygo") return { decision: "auto_approve" }; // tool của runner: runner tự xin duyệt khi cần
  if (mode === "bypassPermissions") return { decision: "auto_approve" };
  if (c === "read") return { decision: "allow" };
  if (mode === "plan") return { decision: "deny", reason: "Đang ở chế độ Lập kế hoạch: chỉ đọc và tìm hiểu, không sửa tệp hay chạy lệnh. Trả lời bằng kế hoạch rồi chờ người dùng đổi chế độ." };
  if (mode === "auto") return { decision: "allow" }; // agy tự xét (--mode auto)
  if (mode === "acceptEdits" && c === "edit") return { decision: "auto_approve" };
  return "ask";
}

/** Chạy hook: đọc sự kiện PreToolUse (JSON stdin), hỏi runner khi cần, in quyết định (JSON stdout). */
export async function runAgyHook(args: string[], stdin: string): Promise<HookDecision> {
  const opt = (k: string) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] ?? "" : ""; };
  const url = opt("--url") || process.env.FLYGO_RUNNER_URL || "", key = opt("--key") || process.env.FLYGO_RUN_KEY || "";
  const mode = opt("--mode") || "manual";
  let ev: any = {};
  try { ev = JSON.parse(stdin || "{}"); } catch {}
  const call = ev.toolCall ?? ev.tool_call ?? ev.tool ?? {};
  const name = String(call.name ?? call.toolName ?? ev.toolName ?? ev.tool_name ?? "");
  const a = call.args ?? call.arguments ?? call.input ?? call.parameters ?? ev.toolInput ?? ev.tool_input ?? {};
  const plan = hookPlan(name, mode);
  if (plan !== "ask") return plan;
  if (!url || !key) return { decision: "deny", reason: "Không xin duyệt được lúc này (runner không chạy)." };
  const { tool_name, input } = approvalInput(name, typeof a === "string" ? (() => { try { return JSON.parse(a); } catch { return { value: a }; } })() : a);
  const r: any = await fetch(`${url}/approve`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ key, tool_name, input }) })
    .then((x) => x.json()).catch((e) => ({ allow: false, message: `Không xin duyệt được: ${e?.message ?? e}` }));
  return r.allow ? { decision: "auto_approve" } : { decision: "deny", reason: r.message || "Người dùng không cho phép thao tác này." };
}

// ---------------------------------------------------------------- đọc stream-json
export interface AgyParseHooks extends Pick<TurnHooks, "step" | "text" | "session"> {}
/** Trạng thái bước của agy (DONE, RUNNING, CORTEX_STEP_STATUS_ERROR…) -> trạng thái bước trên thẻ. */
export function stepStatus(state: any): StepStatus {
  const s = String(state ?? "").toUpperCase().replace(/^(CORTEX_STEP_STATUS_|STEP_STATE_|STATE_)/, "");
  if (s === "DONE" || s === "SUCCESS" || s === "COMPLETED") return "done";
  if (["ERROR", "CANCELED", "CANCELLED", "INTERRUPTED", "HALTED", "INVALID", "FAILED"].includes(s)) return "error";
  if (s === "WAITING") return "waiting";
  return "running";
}

/** Bộ đọc từng dòng NDJSON của `agy -p --output-format stream-json` (tách riêng để kiểm thử bằng dòng mẫu). */
export class AgyStream {
  sessionId = "";
  final = "";
  result: any = null; // sự kiện result (status, response, usage, error…)
  ctxTokens = 0; // token ngữ cảnh của lần gọi model gần nhất (input + cache_read)
  private stepState = new Map<string, string>(); // id bước -> trạng thái đã báo (khỏi báo trùng)
  private texts = new Map<string, string>(); // id đoạn chữ -> chữ đã nhận
  constructor(private h: AgyParseHooks) {}

  /** Một dòng stdout; trả true khi gặp result (hết lượt). */
  line(raw: string): boolean {
    const t = raw.trim();
    if (!t || t[0] !== "{") return false;
    let ev: any;
    try { ev = JSON.parse(t); } catch { return false; }
    const kind = ev.event ?? ev.type;
    if (kind === "init") { this.setSession(ev.conversation_id ?? ev.init?.conversation_id); return false; }
    if (kind === "step_update") { this.step(ev.step_update ?? {}); return false; }
    if (kind === "result") {
      const r = ev.result ?? {};
      this.result = r;
      this.setSession(r.conversation_id);
      this.final = String(r.response ?? "");
      const u = r.usage;
      if (u && !this.ctxTokens) this.ctxTokens = (Number(u.input_tokens) || 0) + (Number(u.cache_read_tokens) || 0);
      return true;
    }
    return false;
  }

  private setSession(id: any) {
    if (id && id !== this.sessionId) { this.sessionId = String(id); this.h.session(this.sessionId); }
  }

  private step(su: any) {
    this.setSession(su.conversation_id);
    const idx = su.step_index ?? su.stepIndex ?? 0;
    const type = String(su.step_type ?? su.stepType ?? "").toLowerCase();
    const st = stepStatus(su.state);
    const u = su.usage;
    if (u && (u.input_tokens || u.cache_read_tokens)) this.ctxTokens = (Number(u.input_tokens) || 0) + (Number(u.cache_read_tokens) || 0);
    const ti = su.tool_info ?? su.toolInfo;
    const tool = String(ti?.name ?? ti?.tool_name ?? ti?.canonical_name ?? su.tool_name ?? "");
    const id = `agy-${idx}`;
    if (tool) {
      const a = ti?.parameters ?? ti?.params ?? ti?.args ?? ti?.arguments ?? ti?.input ?? {};
      const mcp = mcpName(tool);
      if (mcp && hidden(mcp, a)) return; // tool runner tự ghi bước (report_out, ask_user…)
      if (this.stepState.get(id) === st && st === "running") return;
      this.stepState.set(id, st);
      const d = describeAgy(tool, a);
      const out = ti?.output ?? ti?.result ?? su.error;
      const detail = st === "running" ? undefined : (typeof out === "string" ? out : out == null ? "" : JSON.stringify(out)).slice(-600) || undefined;
      this.h.step({ id, kind: d.kind, title: d.title, label: d.label, status: st, detail });
      return;
    }
    if (type === "user_input" || /thinking|thought|planner/.test(type)) return;
    const delta = su.text_delta ?? su.textDelta;
    if (typeof delta === "string" && delta) {
      this.texts.set(id, (this.texts.get(id) ?? "") + delta);
      this.h.text({ id, delta });
    }
    if (st === "done" && this.texts.has(id)) this.h.text({ id, full: this.texts.get(id)!, done: true });
  }
}

/** Danh sách model từ `agy models` (agy 1.4.11 chỉ in chữ; bản sau có --output-format json): nhận mảng JSON, {models:[…]}, hoặc chữ. */
export function parseModels(out: string): EngineInventory["models"] {
  const t = out.trim();
  let list: any[] = [];
  try {
    const j = JSON.parse(t.slice(Math.max(0, Math.min(...["[", "{"].map((c) => { const i = t.indexOf(c); return i < 0 ? Infinity : i; })))));
    list = Array.isArray(j) ? j : (j.models ?? j.data ?? j.items ?? []);
  } catch {
    // Chữ: mỗi dòng một model, slug đứng đầu (có thể có dấu đầu dòng "*", "-", "•", ">"; "*" / "(default)" / "(current)" = mặc định).
    list = t.split("\n").map((l) => l.trim()).map((l) => ({ l, id: l.replace(/^[*•>\-\s]+/, "").split(/\s+/)[0] ?? "" }))
      .filter(({ l, id }) => /^[a-z0-9][\w.:-]*$/i.test(id) && /[-\d]/.test(id) && !/^(fetching|error|available|usage)/i.test(l))
      .map(({ l, id }) => ({ id, isDefault: /\((default|current)\)|^\*|^>/i.test(l) }));
  }
  return list.map((m: any) => {
    if (typeof m === "string") return { id: m, efforts: AGY_EFFORTS };
    const id = String(m.slug ?? m.id ?? m.model ?? m.name ?? "");
    const ef = (m.efforts ?? m.supported_efforts ?? m.supportedEfforts ?? m.thinking_levels ?? m.thinkingLevels) as any[] | undefined;
    return {
      id, name: m.display_name ?? m.displayName ?? m.label ?? (m.name !== id ? m.name : undefined),
      efforts: Array.isArray(ef) && ef.length ? ef.map((e) => String(e?.effort ?? e?.name ?? e).toLowerCase()) : AGY_EFFORTS,
      defaultEffort: m.default_effort ?? m.defaultEffort, isDefault: !!(m.is_default ?? m.isDefault ?? m.default ?? m.current),
    };
  }).filter((m) => m.id);
}

// ---------------------------------------------------------------- engine
const CTX_FILE = join(CONFIG_DIR, "agy-context.json");
const q = (s: string) => `"${s.replace(/"/g, '\\"')}"`;

export class AntigravityEngine implements Engine {
  name = "agy" as const;
  private models: { at: number; list: EngineInventory["models"] } = { at: 0, list: [] };
  constructor(private cfg: Config, private mcpCommand: { command: string; args: string[] }, private log: (s: string) => void) {
    // Thư mục lượt còn sót (runner bị tắt giữa lượt): xoá các thư mục quá một ngày.
    const root = join(CONFIG_DIR, "agy");
    try { for (const d of readdirSync(root)) { const f = join(root, d); if (d.startsWith("run-") && Date.now() - statSync(f).mtimeMs > 86400_000) rmSync(f, { recursive: true, force: true }); } } catch {}
  }

  private bin() { return resolveBin(this.cfg.agy.bin); }

  async inventory(): Promise<EngineInventory> {
    if (Date.now() - this.models.at > 600_000 || !this.models.list.length) {
      const p = Bun.spawn([this.bin(), "models"], { env: { ...process.env, ...AGY_ENV }, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
      const timer = setTimeout(() => p.kill(), 30_000);
      const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
      const code = await p.exited;
      clearTimeout(timer);
      if (code !== 0) throw new Error(`agy models: ${err.trim().split("\n").pop() ?? code}`);
      const list = parseModels(out);
      if (list.length && !list.some((m) => m.isDefault)) list[0].isDefault = true;
      this.models = { at: Date.now(), list };
    }
    return { skills: [], models: this.models.list }; // kỹ năng riêng của bot: runner liệt kê trong ngữ cảnh lượt (như Codex)
  }

  async contextTokens(id: string) {
    try { const n = JSON.parse(readFileSync(CTX_FILE, "utf8"))[id]; return typeof n === "number" ? n : null; } catch { return null; }
  }
  private saveCtx(id: string, n: number) {
    if (!id || !n) return;
    let all: Record<string, number> = {};
    try { all = JSON.parse(readFileSync(CTX_FILE, "utf8")); } catch {}
    all[id] = n;
    const keys = Object.keys(all);
    for (const k of keys.slice(0, Math.max(0, keys.length - 500))) delete all[k]; // giữ 500 phiên gần nhất
    try { writeFileSync(CTX_FILE, JSON.stringify(all)); } catch {}
  }

  /** Luật quyền của lượt (--settings): đọc được mọi nơi trừ luật cấm, tool flygo_chat luôn được phép. */
  settings(full: boolean) {
    const home = homedir();
    const deny = (this.cfg.agy.deny ?? []).map((r) => r.replace(/\(~(?=[/\\)])/, `(${home}`));
    return full ? { permissions: { allow: ["mcp(flygo_chat/*)"] } }
      : { toolPermission: "request-review", permissions: { allow: ["mcp(flygo_chat/*)", "read_file(*)", "read_url(*)"], deny } };
  }

  /** Thư mục cấu hình riêng của lượt (thêm vào workspace bằng --add-dir). */
  prepareRunDir(input: TurnInput, runKey: string, mode: string): string {
    const dir = join(CONFIG_DIR, "agy", `run-${runKey.replace(/[^\w-]/g, "").slice(0, 36) || crypto.randomUUID()}`);
    mkdirSync(join(dir, ".agents"), { recursive: true, mode: 0o700 });
    const mcp = { mcpServers: { flygo_chat: { command: this.mcpCommand.command, args: this.mcpCommand.args, env: input.mcpEnv, timeoutSeconds: 1800 } } };
    writeFileSync(join(dir, ".agents", "mcp_config.json"), JSON.stringify(mcp, null, 1), { mode: 0o600 });
    const hookCmd = [this.mcpCommand.command, ...this.mcpCommand.args.slice(0, -1), "agy-hook", "--url", input.mcpEnv.RUNNER_URL ?? "", "--key", input.mcpEnv.RUN_KEY ?? "", "--mode", mode].map(q).join(" ");
    const hooks = { flygo_agent: { enabled: true, PreToolUse: [{ matcher: ".*", hooks: [{ type: "command", command: hookCmd, timeout: this.cfg.approvalTimeoutSec + 120 }] }] } };
    writeFileSync(join(dir, ".agents", "hooks.json"), JSON.stringify(hooks, null, 1), { mode: 0o600 });
    writeFileSync(join(dir, "AGENTS.md"), `${input.persona}\n\nHỏi người giao việc trong lượt: dùng tool ask_user của flygo_chat (không có cách hỏi khác).\n`, { mode: 0o600 });
    return dir;
  }

  async runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult> {
    const full = !!this.cfg.agy.fullAccess || !!input.bypass || input.mode === "bypassPermissions";
    const mode: PermMode = full ? "bypassPermissions" : input.mode ?? "manual";
    const runKey = input.mcpEnv.RUN_KEY || crypto.randomUUID();
    const dir = this.prepareRunDir(input, runKey, mode);
    // Phiên mới: kèm persona vào tin đầu (dự phòng nếu AGENTS.md của thư mục lượt không được nạp).
    const prompt = input.sessionId ? input.prompt : `<system_instructions>\n${input.persona}\n</system_instructions>\n\n${input.prompt}`;
    const args = [this.bin(), "-p", prompt, "--output-format", "stream-json", "--add-dir", dir, ...(input.addDirs ?? []).flatMap((d) => ["--add-dir", d]),
      "--settings", JSON.stringify(this.settings(full))];
    if (full) args.push("--dangerously-skip-permissions");
    else if (mode === "acceptEdits") args.push("--mode", "accept-edits");
    else if (mode === "auto") args.push("--mode", "auto");
    // Lập kế hoạch: không dùng --mode plan (kế hoạch chờ duyệt trong giao diện agy, -p không duyệt được); hook chặn sửa / chạy lệnh.
    const model = input.model ?? this.cfg.agy.model;
    if (model && model !== AGY_DEFAULT_MODEL) args.push("--model", model);
    if (input.effort) args.push("--effort", input.effort);
    if (input.sessionId) args.push("--conversation", input.sessionId);
    // forkFrom: agy -p chưa có tách phiên -> phiên mới (ngữ cảnh do runner đưa trong prompt).

    const proc = Bun.spawn(args, {
      env: { ...process.env, ...AGY_ENV, FLYGO_RUNNER_URL: input.mcpEnv.RUNNER_URL ?? "", FLYGO_RUN_KEY: input.mcpEnv.RUN_KEY ?? "" },
      cwd: input.cwd, stdout: "pipe", stderr: "pipe", stdin: "pipe",
    });
    proc.stdin.end(); // stdin là ống rỗng: agy không chờ đăng nhập tương tác, báo lỗi ngay nếu chưa đăng nhập
    const kill = () => killTree(proc.pid);
    signal.addEventListener("abort", kill);
    const stderr = new Response(proc.stderr).text();
    const parser = new AgyStream({ step: hooks.step, text: hooks.text, session: hooks.session });
    if (input.sessionId) parser.sessionId = input.sessionId;
    let gotResult = false, lingering = false;
    const reader = proc.stdout.getReader();
    const dec = new TextDecoder();
    let buf = "";
    try {
      for (;;) {
        // Sau result: agy -p chờ việc nền (tối đa --print-timeout). Im lặng quá LINGER_MS thì dừng cả cây tiến trình.
        const rd = reader.read();
        const r = gotResult ? await Promise.race([rd, Bun.sleep(LINGER_MS).then(() => null)]) : await rd;
        if (r === null) { lingering = true; break; }
        if (r.done) break;
        buf += dec.decode(r.value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          if (parser.line(line)) gotResult = true;
        }
      }
      if (buf.trim() && parser.line(buf)) gotResult = true;
      if (lingering) { reader.cancel().catch(() => {}); killTree(proc.pid); }
      const code = lingering ? 0 : await proc.exited;
      if (signal.aborted) throw new Error("đã dừng");
      const res = parser.result;
      const err = await stderr;
      const failed = (res?.status && res.status !== "SUCCESS") || (code !== 0 && !parser.final);
      if (failed || code !== 0) {
        const agyErr = /AGY_ERROR:\s*(\{.*\})/.exec(err)?.[1];
        let msg = res?.error || (agyErr ? (() => { try { const j = JSON.parse(agyErr); return j.short_error ?? j.message ?? agyErr; } catch { return agyErr; } })() : "") || err.trim().split("\n").slice(-3).join(" ");
        if (/authentication|sign in|log in/i.test(msg)) msg = `agy chưa đăng nhập trên máy này (mở app → Trợ lý & bot → Antigravity → Đăng nhập). ${msg}`;
        if (failed) throw new Error(`agy lỗi${code ? ` (mã ${code})` : ""}: ${String(msg).slice(0, 400)}`);
        this.log(`agy kết thúc mã ${code}: ${String(msg).slice(0, 300)}`);
      }
      const u = res?.usage ?? {};
      this.saveCtx(parser.sessionId, parser.ctxTokens);
      const usage = { ...u, duration_ms: res?.duration_seconds != null ? Math.round(res.duration_seconds * 1000) : undefined, ...(parser.ctxTokens ? { contextTokens: parser.ctxTokens } : {}) };
      return { sessionId: parser.sessionId, text: parser.final, usage };
    } finally {
      signal.removeEventListener("abort", kill);
      try { rmSync(dir, { recursive: true, force: true }); } catch {}
    }
  }
}

/** Cài agy bằng bộ cài chính thức (macOS/Linux: install.sh vào ~/.local/bin; Windows: install.ps1 vào %LOCALAPPDATA%\agy\bin). */
export async function installAgy(): Promise<{ ok: boolean; path?: string; version?: string; error?: string }> {
  const cmd = process.platform === "win32"
    ? ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm https://antigravity.google/cli/install.ps1 | iex"]
    : ["/bin/bash", "-c", "curl -fsSL https://antigravity.google/cli/install.sh | bash"];
  const p = Bun.spawn(cmd, { env: { ...process.env }, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const timer = setTimeout(() => p.kill(), 600_000);
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  const code = await p.exited;
  clearTimeout(timer);
  const guess = process.platform === "win32" ? join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), "agy", "bin", "agy.exe") : join(homedir(), ".local", "bin", "agy");
  const path = existsSync(guess) ? guess : resolveBin("agy");
  if (!existsSync(path)) return { ok: false, error: (err || out).trim().split("\n").slice(-3).join(" ").slice(0, 400) || `bộ cài thoát mã ${code}` };
  const v = Bun.spawnSync([path, "--version"], { env: { ...process.env, ...AGY_ENV }, stdout: "pipe", stderr: "pipe" });
  return { ok: true, path, version: v.stdout.toString().trim().split("\n").pop() };
}

/** Mở cửa sổ dòng lệnh chạy `agy` để đăng nhập (agy chỉ đăng nhập được trong giao diện tương tác: chọn Google OAuth,
 *  mở đường dẫn, dán mã từ trình duyệt). */
export function openAgyLogin(bin = "agy"): { ok: boolean; error?: string } {
  const path = resolveBin(bin);
  try {
    if (process.platform === "darwin") {
      const script = `tell application "Terminal" to do script "${path.replace(/(["\\])/g, "\\$1")}"\ntell application "Terminal" to activate`;
      const r = Bun.spawnSync(["/usr/bin/osascript", "-e", script], { stdout: "pipe", stderr: "pipe" });
      return r.exitCode === 0 ? { ok: true } : { ok: false, error: r.stderr.toString().trim() };
    }
    if (process.platform === "win32") {
      Bun.spawn(["cmd", "/c", "start", "Antigravity", path], { stdout: "ignore", stderr: "ignore", stdin: "ignore" }).unref();
      return { ok: true };
    }
    for (const t of [["x-terminal-emulator", "-e"], ["gnome-terminal", "--"], ["konsole", "-e"], ["xfce4-terminal", "-x"], ["xterm", "-e"]]) {
      if (Bun.which(t[0])) { Bun.spawn([...t, path], { stdout: "ignore", stderr: "ignore", stdin: "ignore" }).unref(); return { ok: true }; }
    }
    return { ok: false, error: "không tìm thấy cửa sổ dòng lệnh; mở terminal và chạy: agy" };
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  }
}
