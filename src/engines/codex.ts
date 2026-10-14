// Engine Codex: nối vào `codex app-server` dùng chung qua WebSocket trên unix socket.
// Codex app (ChatGPT.app mở với CODEX_APP_SERVER_WS_URL trỏ cùng socket) thấy cùng các thread, realtime.
import { existsSync } from "node:fs";
import type { Config } from "../config";
import type { Engine, TurnHooks, TurnInput, TurnResult } from "./types";

type Pending = (msg: any) => void;

/** Điền form elicitation khi đồng ý: boolean -> true, enum -> lựa chọn kiểu "accept/allow" nếu có. */
function fillForm(schema: any): Record<string, any> {
  const out: Record<string, any> = {};
  for (const [k, v] of Object.entries<any>(schema?.properties ?? {})) {
    if (v.type === "boolean") out[k] = true;
    else if (Array.isArray(v.enum)) out[k] = v.enum.find((x: any) => /accept|allow|approve|yes/i.test(String(x))) ?? v.enum[0];
    else if (v.default !== undefined) out[k] = v.default;
  }
  return out;
}

const shortCmd =(c: string) => c.replace(/^\/bin\/(ba|z)?sh -l?c /, "").replace(/^'(.*)'$/s, "$1");

export class CodexEngine implements Engine {
  name = "codex" as const;
  private ws: WebSocket | null = null;
  private ready: Promise<void> | null = null;
  private id = 1;
  private pending = new Map<number, Pending>();
  private byThread = new Map<string, (method: string, params: any, reqId?: number) => void>();

  constructor(private cfg: Config, private mcpCommand: { command: string; args: string[] }, private log: (s: string) => void) {}

  private async ensureServer() {
    const sock = this.cfg.codex.socket;
    if (existsSync(sock) && (await this.tryConnect(sock))) return;
    this.log(`codex: không thấy app-server ở ${sock}, tự khởi động`);
    Bun.spawn(["codex", "app-server", "--listen", `unix://${sock}`, ...this.cfg.codex.spawnArgs], {
      stdout: "ignore", stderr: "ignore", stdin: "ignore",
    }).unref();
    for (let i = 0; i < 50; i++) {
      await Bun.sleep(200);
      if (existsSync(sock) && (await this.tryConnect(sock))) return;
    }
    throw new Error(`không khởi động được codex app-server ở ${sock}`);
  }

  private tryConnect(sock: string) {
    return new Promise<boolean>((resolve) => {
      const ws = new WebSocket(`ws+unix://${sock}:/rpc`);
      const t = setTimeout(() => { ws.close(); resolve(false); }, 3000);
      ws.onopen = () => { clearTimeout(t); this.attach(ws); resolve(true); };
      ws.onerror = () => { clearTimeout(t); resolve(false); };
    });
  }

  private attach(ws: WebSocket) {
    this.ws = ws;
    ws.onmessage = (e) => {
      const m = JSON.parse(String(e.data));
      if (m.id != null && !m.method) { const p = this.pending.get(m.id); this.pending.delete(m.id); p?.(m); return; }
      const threadId = m.params?.threadId ?? m.params?.thread?.id;
      const h = threadId && this.byThread.get(threadId);
      // Thread không do runner điều khiển (vd. Sếp đang dùng trong Codex app): bỏ qua, kể cả yêu cầu duyệt.
      if (h) h(m.method, m.params, m.id);
    };
    ws.onclose = () => { this.log("codex: mất kết nối app-server"); this.ws = null; this.ready = null; for (const p of this.pending.values()) p({ error: { message: "disconnected" } }); this.pending.clear(); };
  }

  private connect() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.ensureServer();
        await this.call("initialize", { clientInfo: { name: "flygo-agent", title: "Flygo Agent", version: "0.1.0" }, capabilities: null });
        this.ws!.send(JSON.stringify({ method: "initialized" }));
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  private call(method: string, params: any): Promise<any> {
    return new Promise((resolve, reject) => {
      if (!this.ws) return reject(new Error("codex chưa kết nối"));
      const id = this.id++;
      this.pending.set(id, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message ?? JSON.stringify(m.error)}`)) : resolve(m.result)));
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  private respond(id: number, result: any) { this.ws?.send(JSON.stringify({ id, result })); }

  async runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult> {
    await this.connect();
    const config = {
      mcp_servers: { flygo_chat: { command: this.mcpCommand.command, args: this.mcpCommand.args, env: input.mcpEnv } },
    };
    let threadId = input.sessionId;
    if (threadId) {
      await this.call("thread/resume", { threadId, cwd: input.cwd, config });
    } else {
      const r = await this.call("thread/start", {
        cwd: input.cwd, approvalPolicy: "on-request", sandbox: this.cfg.codex.sandbox, model: this.cfg.codex.model ?? null,
        developerInstructions: input.persona, config,
      });
      threadId = r.thread.id as string;
    }
    hooks.session(threadId);

    let lastMessage = "";
    let usage: any;
    let turnId = "";
    const done = new Promise<void>((resolve, reject) => {
      this.byThread.set(threadId!, async (method, p, reqId) => {
        try {
          if (reqId != null && method.endsWith("requestApproval")) {
            const isFile = method.includes("fileChange");
            const title = isFile ? `Sửa file${p.reason ? ` (${p.reason})` : ""}` : `$ ${shortCmd(p.command ?? "")}`;
            const decision = await hooks.approval({ kind: isFile ? "file" : "command", title, detail: p.reason ?? p.cwd ?? undefined });
            this.respond(reqId, { decision });
            return;
          }
          if (reqId != null && method === "mcpServer/elicitation/request") {
            // Codex hỏi trước khi gọi tool MCP. flygo_chat chỉ đọc kênh hiện tại -> tự cho phép; server khác -> hỏi Sếp.
            const ok = p.serverName === "flygo_chat" ||
              (await hooks.approval({ kind: "tool", title: `MCP ${p.serverName}`, detail: String(p.message ?? "").slice(0, 300) })) === "accept";
            this.respond(reqId, ok ? { action: "accept", content: fillForm(p.requestedSchema), _meta: null } : { action: "decline", content: null, _meta: null });
            return;
          }
          if (reqId != null && method === "item/tool/requestUserInput") { this.respond(reqId, { answers: {} }); return; }
          if (reqId != null) { this.log(`codex: từ chối yêu cầu chưa hỗ trợ ${method}`); this.respond(reqId, { decision: "decline" }); return; }
          if (method === "turn/started") turnId = p.turn?.id ?? turnId;
          if (method === "thread/tokenUsage/updated") usage = p.tokenUsage?.total;
          if (method === "item/started" || method === "item/completed") {
            const it = p.item;
            const fin = method === "item/completed";
            switch (it.type) {
              case "commandExecution": {
                const failed = fin && it.exitCode != null && it.exitCode !== 0;
                hooks.step({ id: it.id, kind: "command", title: `$ ${shortCmd(it.command)}`, status: !fin ? "running" : failed ? "error" : "done", detail: fin ? (it.aggregatedOutput ?? "").slice(-600) : undefined });
                break;
              }
              case "fileChange":
                hooks.step({ id: it.id, kind: "file", title: `Sửa ${(it.changes ?? []).map((c: any) => c.path.split("/").pop()).join(", ")}`, status: !fin ? "running" : it.status === "failed" ? "error" : "done" });
                break;
              case "mcpToolCall":
                hooks.step({ id: it.id, kind: "tool", title: `${it.server}.${it.tool}`, status: !fin ? "running" : it.error ? "error" : "done", detail: it.error?.message });
                break;
              case "webSearch":
                hooks.step({ id: it.id, kind: "search", title: `Tìm web: ${it.query ?? ""}`, status: fin ? "done" : "running" });
                break;
              case "agentMessage":
                if (fin && it.text) {
                  lastMessage = it.text;
                  hooks.step({ id: it.id, kind: "message", title: it.text.split("\n")[0].slice(0, 120), status: "done" });
                }
                break;
            }
          }
          if (method === "turn/completed") {
            const t = p.turn;
            if (t.status === "failed") reject(new Error(t.error?.message ?? "turn failed"));
            else if (t.status === "interrupted") reject(new Error("đã dừng"));
            else resolve();
          }
        } catch (e) { reject(e); }
      });
    });

    const onAbort = () => { if (turnId) this.call("turn/interrupt", { threadId, turnId }).catch(() => {}); };
    signal.addEventListener("abort", onAbort);
    try {
      const tr = await this.call("turn/start", { threadId, input: [{ type: "text", text: input.prompt, text_elements: [] }] });
      turnId = tr.turn?.id ?? turnId;
      await done;
    } finally {
      signal.removeEventListener("abort", onAbort);
      this.byThread.delete(threadId!);
    }
    return { sessionId: threadId!, text: lastMessage, usage };
  }
}
