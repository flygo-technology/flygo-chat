// Engine Codex: nối vào `codex app-server` dùng chung qua WebSocket trên unix socket.
// Codex app (ChatGPT.app mở với CODEX_APP_SERVER_WS_URL trỏ cùng socket) thấy cùng các thread, realtime.
import { existsSync } from "node:fs";
import { resolveBin, type Config } from "../config";
import { tailTokens } from "./claude";
import type { Engine, EngineInventory, TurnHooks, TurnInput, TurnResult } from "./types";

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

const SANDBOX = { "read-only": { type: "readOnly" }, "workspace-write": { type: "workspaceWrite" }, "danger-full-access": { type: "dangerFullAccess" } } as const;

export class CodexEngine implements Engine {
  name = "codex" as const;
  private ws: WebSocket | null = null;
  private ready: Promise<void> | null = null;
  private id = 1;
  private pending = new Map<number, Pending>();
  private byThread = new Map<string, (method: string, params: any, reqId?: number) => void>();

  constructor(private cfg: Config, private mcpCommand: { command: string; args: string[] }, private log: (s: string) => void) {}

  /** stdio: chạy `codex app-server` riêng, nói JSON-RPC theo dòng qua stdin/stdout (Windows, hoặc khi không cần dùng chung). */
  private startStdio() {
    const proc = Bun.spawn([resolveBin(this.cfg.codex.bin ?? "codex"), "app-server", ...this.cfg.codex.spawnArgs], { env: { ...process.env }, stdin: "pipe", stdout: "pipe", stderr: "ignore" });
    const conn: any = {
      readyState: 1,
      send: (s: string) => { proc.stdin.write(s + "\n"); proc.stdin.flush(); },
      close: () => proc.kill(),
      onmessage: null, onclose: null,
    };
    (async () => {
      const rd = proc.stdout.getReader(); const dec = new TextDecoder(); let buf = "";
      for (;;) {
        const { value, done } = await rd.read(); if (done) break;
        buf += dec.decode(value, { stream: true }); let i;
        while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (line) conn.onmessage?.({ data: line }); }
      }
      conn.onclose?.();
    })();
    this.attach(conn as WebSocket);
  }

  private async ensureServer() {
    if (this.cfg.codex.transport === "stdio") return this.startStdio();
    const sock = this.cfg.codex.socket;
    if (existsSync(sock) && (await this.tryConnect(sock))) return;
    this.log(`codex: không thấy app-server ở ${sock}, tự khởi động`);
    Bun.spawn([resolveBin(this.cfg.codex.bin ?? "codex"), "app-server", "--listen", `unix://${sock}`, ...this.cfg.codex.spawnArgs], {
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
  private sections = new Map<string, string>(); // tên section -> id

  /** Codex app: tên thread "<chat> · <luồng>", xếp vào section "Flygo · <chat>" (thay vì tên = dòng đầu prompt, lẫn lộn). */
  private async organize(threadId: string, input: TurnInput) {
    await this.call("thread/name/set", { threadId, name: input.title });
    if (this.cfg.codex.sections === false) return;
    const name = `Flygo · ${input.group}`;
    let id = this.sections.get(name);
    if (!id) {
      let cursor: string | null = null;
      do {
        const r: any = await this.call("threadSection/list", { cursor, limit: 100 });
        for (const s of r.data ?? []) this.sections.set(s.name, s.id);
        cursor = r.nextCursor ?? null;
      } while (cursor && !this.sections.has(name));
      id = this.sections.get(name) ?? (await this.call("threadSection/create", { name })).section.id as string;
      this.sections.set(name, id);
    }
    await this.call("thread/section/move", { threadId, sectionId: id });
  }

  async inventory(): Promise<EngineInventory> {
    await this.connect();
    const models: EngineInventory["models"] = [];
    let cursor: string | null = null;
    do {
      const r: any = await this.call("model/list", { cursor, limit: 100, includeHidden: false });
      for (const m of r?.data ?? []) models.push({
        id: m.model || m.id, name: m.displayName, isDefault: !!m.isDefault, defaultEffort: m.defaultReasoningEffort,
        efforts: (m.supportedReasoningEfforts ?? []).map((e: any) => e.reasoningEffort).filter(Boolean),
      });
      cursor = r?.nextCursor ?? null;
    } while (cursor);
    const sk: any = await this.call("skills/list", { cwds: [this.cfg.workspaceRoot] }).catch(() => null);
    const skills = (sk?.data ?? []).flatMap((e: any) => e.skills ?? []).filter((x: any) => x.enabled !== false)
      .map((x: any) => ({ name: x.name, description: x.shortDescription || x.description || "" }));
    return { skills, models };
  }

  async contextTokens(threadId: string) {
    await this.connect();
    const r = await this.call("thread/read", { threadId, includeTurns: false }).catch(() => null);
    const path = r?.thread?.path;
    if (!path || !existsSync(path)) return null;
    return tailTokens(path, (ev) => ev?.payload?.type === "token_count" ? ev.payload.info?.last_token_usage?.input_tokens ?? null : null);
  }

  private respond(id: number, result: any) { this.ws?.send(JSON.stringify({ id, result })); }

  async runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult> {
    await this.connect();
    const config = {
      // tool_timeout_sec: approve / ask_agent (A2A) chờ người duyệt hoặc agent khác làm việc lâu.
      mcp_servers: { flygo_chat: { command: this.mcpCommand.command, args: this.mcpCommand.args, env: input.mcpEnv, tool_timeout_sec: 2400 } },
    };
    let threadId = input.sessionId;
    if (threadId) {
      await this.call("thread/resume", { threadId, cwd: input.cwd, config, ...(input.model ?? this.cfg.codex.model ? { model: input.model ?? this.cfg.codex.model } : {}) });
    } else if (input.forkFrom) {
      // Phiên mới tách từ phiên cha: mang lịch sử + hướng dẫn của phiên cha, cấu hình MCP / thư mục của phiên mới.
      const r = await this.call("thread/fork", {
        threadId: input.forkFrom, cwd: input.cwd, config, excludeTurns: true,
        approvalPolicy: "on-request", sandbox: this.cfg.codex.sandbox, model: input.model ?? this.cfg.codex.model ?? null,
      }).catch((e) => { this.log(`codex: không fork được ${input.forkFrom}: ${e.message ?? e}, mở phiên mới`); return null; });
      threadId = r?.thread?.id as string | undefined;
    }
    if (!threadId) {
      const r = await this.call("thread/start", {
        cwd: input.cwd, approvalPolicy: "on-request", sandbox: this.cfg.codex.sandbox, model: input.model ?? this.cfg.codex.model ?? null,
        developerInstructions: input.persona, config,
      });
      threadId = r.thread.id as string;
    }
    hooks.session(threadId);
    await this.organize(threadId!, input).catch((e) => this.log(`codex: đặt tên/section: ${e.message ?? e}`));

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
          if (reqId != null && method === "item/tool/requestUserInput") { // request_user_input: hỏi trên Flygo, trả lời trong lượt
            const qs = (p.questions ?? []) as any[];
            const r = await hooks.ask(qs.map((q) => ({ id: q.id, question: q.question, header: q.header, options: q.options ?? [] })));
            const answers: Record<string, { answers: string[] }> = {};
            if ("answers" in r) qs.forEach((q, i) => { const a = r.answers[i]; if (a) answers[q.id] = { answers: [...a.choices, ...(a.other ? [a.other] : [])] }; });
            this.respond(reqId, { answers });
            return;
          }
          if (reqId != null) { this.log(`codex: từ chối yêu cầu chưa hỗ trợ ${method}`); this.respond(reqId, { decision: "decline" }); return; }
          if (method === "item/agentMessage/delta") { hooks.text({ id: p.itemId, delta: p.delta ?? "" }); return; }
          if (method === "turn/started") turnId = p.turn?.id ?? turnId;
          if (method === "thread/tokenUsage/updated") {
            const tu = p.tokenUsage;
            usage = { ...tu?.total, ...(tu?.last ? { contextTokens: tu.last.inputTokens } : {}), ...(tu?.modelContextWindow ? { contextWindow: tu.modelContextWindow } : {}) };
          }
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
                if (it.tool === "chat_report_out") break; // runner tự ghi bước "Báo cáo ra ngoài"
                hooks.step({ id: it.id, kind: "tool", title: `${it.server}.${it.tool}`, status: !fin ? "running" : it.error ? "error" : "done", detail: it.error?.message });
                break;
              case "webSearch":
                hooks.step({ id: it.id, kind: "search", title: `Tìm web: ${it.query ?? ""}`, status: fin ? "done" : "running" });
                break;
              case "agentMessage":
                if (fin) {
                  if (it.text) lastMessage = it.text;
                  hooks.text({ id: it.id, full: it.text ?? "", done: true });
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
      // model/effort ghi đè cho lượt này và các lượt sau của thread -> luôn truyền rõ (mặc định khi người dùng không chọn).
      const tr = await this.call("turn/start", {
        threadId, input: [{ type: "text", text: input.prompt, text_elements: [] }],
        ...(input.model ? { model: input.model } : {}), ...(input.effort ? { effort: input.effort } : {}),
        // Ghi đè quyền mỗi lượt (có hiệu lực cho cả lượt sau nên luôn gửi): "luôn cho phép" -> never + toàn quyền.
        approvalPolicy: input.bypass ? "never" : "on-request",
        sandboxPolicy: input.bypass ? { type: "dangerFullAccess" } : SANDBOX[this.cfg.codex.sandbox],
      });
      turnId = tr.turn?.id ?? turnId;
      await done;
    } finally {
      signal.removeEventListener("abort", onAbort);
      this.byThread.delete(threadId!);
      // Thả thread khi xong lượt: app-server dỡ thread (nếu Codex app không mở nó) -> lượt sau resume chạy MCP flygo_chat MỚI
      // với env của lượt đó (RUN_KEY, danh sách tool mới). Không thả thì MCP cũ sống mãi: tool cũ, RUN_KEY hết hạn.
      const st = await this.call("thread/unsubscribe", { threadId }).catch((e) => ({ status: `lỗi ${e.message ?? e}` }));
      if (st?.status !== "unsubscribed") this.log(`codex: thread/unsubscribe ${threadId}: ${st?.status}`);
    }
    return { sessionId: threadId!, text: lastMessage, usage };
  }
}
