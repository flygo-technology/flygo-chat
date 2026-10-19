// Engine Codex: nối vào `codex app-server` dùng chung qua WebSocket trên unix socket.
// Codex app (ChatGPT.app mở với CODEX_APP_SERVER_WS_URL trỏ cùng socket) thấy cùng các thread, realtime.
import { appendFileSync, existsSync, mkdirSync, renameSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { resolveBin, type Config } from "../config";
import { logDir } from "../service";
import { tailTokens } from "./claude";
import type { Engine, EngineInventory, TurnHooks, TurnInput, TurnResult } from "./types";

type Pending = (msg: any) => void;

/** Lỗi khi app-server Codex thoát / mất kết nối giữa lượt (runTurn tự chạy lại một lần). */
class CodexDisconnected extends Error {}
const LOST = "mất kết nối Codex (app-server đã thoát)";
const STDERR_MAX = 2 * 1024 * 1024;
/** Model bị upstream từ chối ("The 'x' model is not supported…"), hoặc null. */
const unsupportedModel = (msg: string) => /'([^']+)' model is not supported/i.exec(msg)?.[1] ?? (/model[^.]{0,40}not supported/i.test(msg) ? "?" : null);
/** Câu báo lỗi dễ hiểu cho người dùng (giữ nguyên văn lỗi gốc ở cuối, rút gọn). */
function friendly(msg: string, model?: string): string {
  const raw = msg.length > 300 ? msg.slice(0, 300) + "…" : msg;
  const m = unsupportedModel(msg);
  if (m) return `Mô hình ${m !== "?" ? m : model ?? ""} không dùng được với tài khoản Codex trên máy chạy bot (tài khoản hoặc proxy không hỗ trợ mô hình này). Chọn mô hình khác trên app rồi gửi lại. (${raw})`;
  if (/usage limit|hit your limit|rate.?limit|quota|insufficient_quota|\b429\b/i.test(msg)) return `Tài khoản Codex trên máy chạy bot đã hết hạn mức sử dụng (usage limit). Thử lại sau, hoặc chọn mô hình khác. (${raw})`;
  return msg;
}
const IDLE_WARN_MS = 20 * 60_000;
const REJECTED_TTL_MS = 30 * 60_000; // nhớ model bị từ chối trong 30 phút
const stderrFile = () => {
  const f = process.env.FLYGO_AGENT_LOG_FILE;
  return f ? f.replace(/(\.log)?$/, "-codex-stderr.log") : join(logDir, "codex-stderr.log");
};
/** Ghi stderr của app-server vào file riêng, quá STDERR_MAX thì xoay sang .1. */
function appendStderr(text: string) {
  const f = stderrFile();
  try {
    mkdirSync(dirname(f), { recursive: true });
    if (existsSync(f) && statSync(f).size > STDERR_MAX) renameSync(f, f + ".1");
    appendFileSync(f, text);
  } catch {}
}

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
  private rejected = new Map<string, number>(); // model -> lúc bị upstream từ chối
  private turnFail = new Map<string, (e: Error) => void>(); // threadId -> kết thúc lượt đang chờ khi mất kết nối

  constructor(private cfg: Config, private mcpCommand: { command: string; args: string[] }, private log: (s: string) => void) {}

  /** stdio: chạy `codex app-server` riêng, nói JSON-RPC theo dòng qua stdin/stdout (Windows, hoặc khi không cần dùng chung). */
  private startStdio() {
    const proc = Bun.spawn([resolveBin(this.cfg.codex.bin ?? "codex"), "app-server", ...this.cfg.codex.spawnArgs], { env: { ...process.env }, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    let closed = false;
    const conn: any = {
      readyState: 1,
      send: (s: string) => { try { proc.stdin.write(s + "\n"); proc.stdin.flush(); } catch { finish(); } },
      close: () => proc.kill(),
      onmessage: null, onclose: null,
    };
    const finish = () => { if (closed) return; closed = true; conn.readyState = 3; try { proc.kill(); } catch {} conn.onclose?.(); };
    appendStderr(`--- ${new Date().toISOString()} app-server pid ${proc.pid} (runner pid ${process.pid})\n`);
    (async () => {
      const rd = proc.stderr.getReader(); const dec = new TextDecoder();
      try { for (;;) { const { value, done } = await rd.read(); if (done) break; appendStderr(dec.decode(value, { stream: true })); } } catch {}
    })();
    (async () => {
      const rd = proc.stdout.getReader(); const dec = new TextDecoder(); let buf = "";
      try {
        for (;;) {
          const { value, done } = await rd.read(); if (done) break;
          buf += dec.decode(value, { stream: true }); let i;
          while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (line) conn.onmessage?.({ data: line }); }
        }
      } catch {}
      finish();
    })();
    // Tiến trình thoát mà stdout chưa đóng (tiến trình con giữ pipe): vẫn coi là mất kết nối.
    proc.exited.then((code) => {
      const msg = `codex: app-server pid ${proc.pid} thoát, mã ${code}${proc.signalCode ? ` (${proc.signalCode})` : ""}`;
      this.log(msg); appendStderr(`--- ${new Date().toISOString()} ${msg}\n`);
      setTimeout(finish, 2000);
    });
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
    ws.onclose = () => {
      if (this.ws !== ws) return; // kết nối cũ, đã thay
      this.log(`codex: mất kết nối app-server${this.turnFail.size ? ` (${this.turnFail.size} lượt đang chạy)` : ""}`);
      this.ws = null; this.ready = null;
      for (const p of this.pending.values()) p({ error: { message: "disconnected", lost: true } });
      this.pending.clear();
      // Lượt đang chờ turn/completed sẽ không bao giờ nhận được: kết thúc ngay để báo lỗi / chạy lại.
      for (const f of this.turnFail.values()) f(new CodexDisconnected(LOST));
      this.turnFail.clear();
    };
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
      if (!this.ws) return reject(new CodexDisconnected(`${method}: codex chưa kết nối`));
      const id = this.id++;
      this.pending.set(id, (m) => (m.error ? reject(new (m.error.lost ? CodexDisconnected : Error)(`${method}: ${m.error.message ?? JSON.stringify(m.error)}`)) : resolve(m.result)));
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
    let threadId = "";
    let progressed = false;
    const open = new Map<string, Parameters<TurnHooks["step"]>[0]>(); // bước đang chạy: chốt "lỗi" khi app-server chết
    const h: TurnHooks = { ...hooks, step: (st) => { if (st.status === "running") open.set(st.id, st); else open.delete(st.id); hooks.step(st); } };
    const closeOpen = () => { for (const st of open.values()) hooks.step({ ...st, status: "error", detail: LOST }); open.clear(); };
    let want = input.model ?? this.cfg.codex.model;
    const fb = input.fallbackModel;
    // Model đã chọn vừa bị upstream từ chối (vd. app còn lưu lựa chọn cũ): đi thẳng sang model mặc định, khỏi tốn một lần hỏng.
    const rejectedAt = want ? this.rejected.get(want) : undefined;
    if (want && fb && fb !== want && rejectedAt && Date.now() - rejectedAt < REJECTED_TTL_MS) {
      hooks.step({ id: "codex-model-fallback", kind: "tool", title: `Mô hình ${want} không dùng được, chuyển sang ${fb}`, status: "done" });
      input = { ...input, model: fb };
      want = fb;
    }
    try {
      return await this.runOnce(input, h, signal, (id) => { threadId = id; }, () => { progressed = true; }, false);
    } catch (e: any) {
      if (e instanceof CodexDisconnected) closeOpen();
      let bad = !(e instanceof CodexDisconnected) && !signal.aborted ? unsupportedModel(String(e?.message ?? "")) : null;
      let err = e;
      // Model đã chọn bị từ chối -> chạy lại bằng model mặc định của bot (cùng thread; thread vướng model cũ thì bước dưới mở thread mới).
      if (bad && (bad === want || (bad === "?" && !input.sessionId && !input.forkFrom)) && fb && fb !== want) {
        this.log(`codex: model ${want} không được hỗ trợ, chạy lại bằng model mặc định ${fb}`);
        if (want) this.rejected.set(want, Date.now());
        closeOpen();
        hooks.step({ id: "codex-model-fallback", kind: "tool", title: `Mô hình ${want} không dùng được, chuyển sang ${fb}`, status: "done" });
        input = { ...input, model: fb };
        want = fb;
        try { return await this.runOnce(input, h, signal, (id) => { threadId = id; }, () => {}, false); }
        catch (e2: any) {
          if (e2 instanceof CodexDisconnected) { closeOpen(); throw new Error(LOST); }
          if (signal.aborted) throw e2;
          err = e2;
          bad = unsupportedModel(String(e2?.message ?? ""));
        }
      }
      // Đổi model: Codex nén lịch sử của thread (resume / fork) bằng model CŨ của thread. Model cũ bị từ chối thì lượt hỏng
      // dù model mới dùng được -> mở thread mới hẳn bằng model mới (agent đọc lại chat bằng chat_history nếu cần).
      if (bad && bad !== "?" && bad !== want && (input.sessionId || input.forkFrom)) {
        this.log(`codex: thread ${threadId || input.sessionId || input.forkFrom} vướng model cũ ${bad} (không được hỗ trợ), mở thread mới với ${want ?? "mặc định"}`);
        closeOpen();
        hooks.step({ id: "codex-new-thread", kind: "tool", title: `Mở phiên Codex mới (model cũ ${bad} không dùng được)`, status: "done" });
        const note = `[Phiên Codex trước không tiếp tục được vì mô hình cũ ${bad} không còn dùng được, đây là phiên mới. Cần ngữ cảnh thì đọc lại bằng chat_history.]\n\n`;
        return await this.runOnce({ ...input, sessionId: undefined, forkFrom: undefined, prompt: note + input.prompt }, h, signal, () => {}, () => {}, false)
          .catch((e2: any) => { throw e2 instanceof CodexDisconnected ? e2 : new Error(friendly(String(e2?.message ?? e2), want)); });
      }
      if (err !== e) throw new Error(friendly(String(err?.message ?? err), want));
      if (!(e instanceof CodexDisconnected)) throw signal.aborted ? e : new Error(friendly(String(e?.message ?? e), want));
      if (signal.aborted) throw e;
      // App-server chết giữa lượt: dựng lại và chạy lại lượt này đúng một lần, trên cùng thread nếu đã có.
      this.log(`codex: ${e.message}; chạy lại lượt${threadId ? ` trên thread ${threadId}` : ""}`);
      hooks.step({ id: "codex-restart", kind: "tool", title: "Codex khởi động lại, chạy lại lượt", status: "done" });
      const note = progressed ? "[Lượt trước bị gián đoạn vì Codex khởi động lại giữa chừng. Kiểm tra những gì đã làm rồi làm tiếp, đừng lặp lại thao tác đã xong.]\n\n" : "";
      try {
        return await this.runOnce({ ...input, ...(threadId ? { sessionId: threadId, forkFrom: undefined } : {}), prompt: note + input.prompt }, h, signal, () => {}, () => {}, true);
      } catch (e2) {
        if (e2 instanceof CodexDisconnected) closeOpen();
        if (e2 instanceof CodexDisconnected) throw new Error(`${LOST} hai lần liền, lượt dừng. Xem log stderr Codex cạnh log runner.`);
        throw signal.aborted ? e2 : new Error(friendly(String((e2 as any)?.message ?? e2), want));
      }
    }
  }

  private async runOnce(input: TurnInput, hooks: TurnHooks, signal: AbortSignal, onThread: (id: string) => void, onProgress: () => void, retry: boolean): Promise<TurnResult> {
    await this.connect();
    const config = {
      // tool_timeout_sec: approve / ask_agent (A2A) chờ người duyệt hoặc agent khác làm việc lâu.
      mcp_servers: { flygo_chat: { command: this.mcpCommand.command, args: this.mcpCommand.args, env: input.mcpEnv, tool_timeout_sec: 2400 } },
    };
    let threadId = input.sessionId;
    if (threadId) {
      const resumed = this.call("thread/resume", { threadId, cwd: input.cwd, config, ...(input.model ?? this.cfg.codex.model ? { model: input.model ?? this.cfg.codex.model } : {}) });
      // Chạy lại sau sự cố: thread mới tạo có thể chưa kịp ghi xuống đĩa -> mở thread mới.
      if (retry) await resumed.catch((e) => { this.log(`codex: không resume được ${threadId} khi chạy lại: ${e.message ?? e}, mở phiên mới`); threadId = undefined; });
      else await resumed;
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
    onThread(threadId);
    await this.organize(threadId!, input).catch((e) => this.log(`codex: đặt tên/section: ${e.message ?? e}`));

    let lastMessage = "";
    let usage: any;
    let turnId = "";
    let lastEvent = Date.now();
    let waiting = 0; // đang chờ người duyệt / trả lời: im lặng là bình thường
    const done = new Promise<void>((resolve, reject) => {
      this.turnFail.set(threadId!, reject);
      this.byThread.set(threadId!, async (method, p, reqId) => {
        lastEvent = Date.now();
        if (method.startsWith("item/")) onProgress();
        try {
          if (reqId != null && method.endsWith("requestApproval")) {
            const isFile = method.includes("fileChange");
            const title = isFile ? `Sửa file${p.reason ? ` (${p.reason})` : ""}` : `$ ${shortCmd(p.command ?? "")}`;
            waiting++;
            const decision = await hooks.approval({ kind: isFile ? "file" : "command", title, detail: p.reason ?? p.cwd ?? undefined }).finally(() => { waiting--; lastEvent = Date.now(); });
            this.respond(reqId, { decision });
            return;
          }
          if (reqId != null && method === "mcpServer/elicitation/request") {
            // Codex hỏi trước khi gọi tool MCP. flygo_chat chỉ đọc kênh hiện tại -> tự cho phép; server khác -> hỏi Sếp.
            waiting++;
            const ok = await (async () => p.serverName === "flygo_chat" ||
              (await hooks.approval({ kind: "tool", title: `MCP ${p.serverName}`, detail: String(p.message ?? "").slice(0, 300) })) === "accept")().finally(() => { waiting--; lastEvent = Date.now(); });
            this.respond(reqId, ok ? { action: "accept", content: fillForm(p.requestedSchema), _meta: null } : { action: "decline", content: null, _meta: null });
            return;
          }
          if (reqId != null && method === "item/tool/requestUserInput") { // request_user_input: hỏi trên Flygo, trả lời trong lượt
            const qs = (p.questions ?? []) as any[];
            waiting++;
            const r = await hooks.ask(qs.map((q) => ({ id: q.id, question: q.question, header: q.header, options: q.options ?? [] }))).finally(() => { waiting--; lastEvent = Date.now(); });
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
    done.catch(() => {}); // turn/start có thể lỗi trước khi chờ done

    const onAbort = () => { if (turnId) this.call("turn/interrupt", { threadId, turnId }).catch(() => {}); };
    signal.addEventListener("abort", onAbort);
    // Canh lượt: im lặng quá IDLE_WARN_MS (không phải đang chờ người) thì ghi log để biết lượt treo ở đâu.
    let warnedFor = 0, warns = 0;
    const watchdog = setInterval(() => {
      if (warnedFor !== lastEvent) { warnedFor = lastEvent; warns = 0; }
      const idle = Date.now() - lastEvent;
      if (waiting || idle < IDLE_WARN_MS * (warns + 1)) return;
      warns++;
      this.log(`codex: lượt ${turnId || "?"} trên thread ${threadId} không có sự kiện ${Math.round(idle / 60_000)} phút${this.ws ? "" : " (mất kết nối app-server)"}`);
    }, 60_000);
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
      clearInterval(watchdog);
      signal.removeEventListener("abort", onAbort);
      this.byThread.delete(threadId!);
      this.turnFail.delete(threadId!);
      // Thả thread khi xong lượt: app-server dỡ thread (nếu Codex app không mở nó) -> lượt sau resume chạy MCP flygo_chat MỚI
      // với env của lượt đó (RUN_KEY, danh sách tool mới). Không thả thì MCP cũ sống mãi: tool cũ, RUN_KEY hết hạn.
      const st = await this.call("thread/unsubscribe", { threadId }).catch((e) => ({ status: `lỗi ${e.message ?? e}` }));
      if (st?.status !== "unsubscribed") this.log(`codex: thread/unsubscribe ${threadId}: ${st?.status}`);
    }
    return { sessionId: threadId!, text: lastMessage, usage };
  }
}
