// Engine Claude: mỗi lượt chạy `claude -p --output-format stream-json`, nói tiếp bằng --resume.
// Quyền: công cụ ngoài allowedTools được hỏi qua tool MCP flygo_chat.approve (--permission-prompt-tool)
// -> runner hiện yêu cầu duyệt trên Flygo.
import type { Config } from "../config";
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

const resultText = (c: any) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((x) => x.text ?? "").join("\n") : "");

export class ClaudeEngine implements Engine {
  name = "claude" as const;
  constructor(private cfg: Config, private mcpCommand: { command: string; args: string[] }, private log: (s: string) => void) {}

  async runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult> {
    const mcpConfig = JSON.stringify({
      mcpServers: { flygo_chat: { command: this.mcpCommand.command, args: this.mcpCommand.args, env: input.mcpEnv } },
    });
    // Không nạp settings cá nhân (~/.claude/settings.json có thể allow Bash/Write hoặc bypass);
    // quyền của phiên chỉ gồm allowedTools + deny của runner, còn lại hỏi Sếp qua Flygo.
    const settings = JSON.stringify({ permissions: { defaultMode: "default", deny: this.cfg.claude.deny } });
    const args = [
      this.cfg.claude.bin, "-p", input.prompt,
      "--output-format", "stream-json", "--verbose", "--include-partial-messages",
      "--setting-sources", "project,local",
      "--settings", settings,
      "--permission-mode", "default",
      "--mcp-config", mcpConfig,
      "--permission-prompt-tool", "mcp__flygo_chat__approve",
      "--allowedTools", this.cfg.claude.allowedTools.join(","),
      "--append-system-prompt", input.persona,
    ];
    if (this.cfg.claude.model) args.push("--model", this.cfg.claude.model);
    if (input.sessionId) args.push("--resume", input.sessionId);

    const proc = Bun.spawn(args, { cwd: input.cwd, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
    const kill = () => proc.kill();
    signal.addEventListener("abort", kill);

    let sessionId = input.sessionId ?? "";
    let final = "";
    let usage: any;
    let isError = false;
    let curMsg = "";
    const tools = new Map<string, { name: string; input: any }>();
    const stderr = new Response(proc.stderr).text();

    const reader = proc.stdout.getReader();
    const dec = new TextDecoder();
    let buf = "";
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i).trim();
          buf = buf.slice(i + 1);
          if (!line) continue;
          let ev: any;
          try { ev = JSON.parse(line); } catch { continue; }
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
                if (c.name === "mcp__flygo_chat__approve" || c.name === "ToolSearch") continue;
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
              if (!t || t.name === "mcp__flygo_chat__approve" || t.name === "ToolSearch") continue;
              const d = describe(t.name, t.input);
              hooks.step({ id: c.tool_use_id, kind: d.kind, title: d.title, status: c.is_error ? "error" : "done", detail: resultText(c.content).slice(-600) });
            }
          } else if (ev.type === "result") {
            final = ev.result ?? "";
            isError = !!ev.is_error;
            usage = { cost_usd: ev.total_cost_usd, duration_ms: ev.duration_ms, ...ev.usage };
            if (ev.session_id) sessionId = ev.session_id;
          }
        }
      }
      const code = await proc.exited;
      if (signal.aborted) throw new Error("đã dừng");
      if (code !== 0 && !final) throw new Error(`claude thoát mã ${code}: ${(await stderr).slice(-400)}`);
      if (isError) throw new Error(final || "claude báo lỗi");
    } finally {
      signal.removeEventListener("abort", kill);
    }
    return { sessionId, text: final, usage };
  }
}
