// A2A (Agent2Agent): client nối relay (wss://push.flygo.vn/a2a/connect) — runner sau NAT giữ một WebSocket ra relay.
// Gọi agent khác: call() (message/stream, nhận sự kiện), list(), grant() (cấp URL tải tệp lớn cho một agent).
// Được gọi: onRequest(cid, from, depth, req) -> trả bằng event() / done().
// Giao thức khung: xem relay/a2a.mjs.

const PART = 200_000;

export interface A2APeer { id: string; username: string; name: string; server: string; is_bot: boolean; owner_id: string; owner_name: string; card?: any }
export type A2AHandler = (cid: string, from: A2APeer, depth: number, req: { jsonrpc: string; id: any; method: string; params: any }) => void;

export class A2AClient {
  private ws: WebSocket | null = null;
  private pending = new Map<string, { resolve: (m: any) => void; onEvent?: (e: any) => void }>();
  private parts = new Map<string, string[]>();
  private backoff = 2000;
  private stopped = false;
  private card: any = {};
  me: A2APeer | null = null;
  onSched: ((m: { cid: string; user: { id: string; username?: string }; body: any }) => void) | null = null; // app thao tác lịch hẹn qua relay

  constructor(private url: string, private server: string, private token: string, private log: (s: string) => void,
    private onRequest: A2AHandler, private onCancel: (cid: string) => void) {}

  get online() { return !!this.me && this.ws?.readyState === WebSocket.OPEN; }

  start(card: any) {
    this.card = card;
    this.open();
    setInterval(() => this.send({ t: "ping" }), 30_000);
  }
  setCard(card: any) {
    if (JSON.stringify(card) === JSON.stringify(this.card)) return;
    this.card = card;
    this.send({ t: "hello", card });
  }
  stop() { this.stopped = true; this.ws?.close(); }

  private open() {
    if (this.stopped) return;
    const ws = new WebSocket(this.url, { headers: { Authorization: `Bearer ${this.token}`, "X-MM-Server": this.server } } as any);
    this.ws = ws;
    ws.onopen = () => { this.backoff = 2000; this.send({ t: "hello", card: this.card }); };
    ws.onmessage = (e) => {
      let m: any;
      try { m = JSON.parse(String(e.data)); } catch { return; }
      if (m.t === "part") {
        const arr = this.parts.get(m.k) ?? [];
        arr[m.i] = m.d;
        this.parts.set(m.k, arr);
        if (arr.filter((x) => x !== undefined).length < m.n) return;
        this.parts.delete(m.k);
        try { m = JSON.parse(arr.join("")); } catch { return; }
      }
      this.dispatch(m);
    };
    ws.onclose = (e) => {
      const wasOnline = !!this.me;
      this.me = null;
      for (const p of [...this.pending.values()]) p.resolve({ error: { code: -32002, message: "mất kết nối relay A2A" } });
      if (this.stopped) return;
      // 4401/4403: relay từ chối (token, server chưa bật A2A, bị chặn) -> thử lại thưa (6 giờ).
      const denied = e.code === 4401 || e.code === 4403;
      const wait = denied ? 6 * 3600_000 : this.backoff;
      if (wasOnline || denied) this.log(`a2a: ngắt kết nối relay (${e.code}${e.reason ? ` ${e.reason}` : ""}), nối lại sau ${Math.round(wait / 1000)}s`);
      this.backoff = Math.min(this.backoff * 2, 60_000);
      setTimeout(() => this.open(), wait);
    };
    ws.onerror = () => {};
  }

  private dispatch(m: any) {
    switch (m.t) {
      case "welcome": this.me = m.agent; this.log(`a2a: đã nối relay (@${m.agent.username})`); return;
      case "error": this.log(`a2a: relay báo lỗi ${m.code}: ${m.message}`); return;
      case "req": this.onRequest(m.cid, m.from, m.depth, m.req); return;
      case "cancel": this.onCancel(m.cid); return;
      case "sched": this.onSched?.(m); return;
      case "ev": this.pending.get(m.id)?.onEvent?.(m.data); return;
      case "res": case "done": this.pending.get(m.id)?.resolve(m); return;
    }
  }

  send(obj: any) {
    if (this.ws?.readyState !== WebSocket.OPEN) return false;
    const s = JSON.stringify(obj);
    if (s.length <= PART) { this.ws.send(s); return true; }
    const k = crypto.randomUUID(), n = Math.ceil(s.length / PART);
    for (let i = 0; i < n; i++) this.ws.send(JSON.stringify({ t: "part", k, i, n, d: s.slice(i * PART, (i + 1) * PART) }));
    return true;
  }

  private request(msg: any, onEvent?: (e: any) => void, timeoutMs = 30_000, signal?: AbortSignal): Promise<any> {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      if (!this.online) return reject(new Error("chưa nối relay A2A"));
      const end = (m: any) => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
        this.pending.delete(id);
        m.error ? reject(Object.assign(new Error(m.error.message ?? "lỗi A2A"), { code: m.error.code })) : resolve(m.result);
      };
      const cancel = (message: string) => { this.send({ t: "cancel", id }); end({ error: { code: -32007, message } }); };
      const onAbort = () => cancel("đã huỷ");
      const timer = setTimeout(() => cancel("quá thời gian chờ agent"), timeoutMs);
      signal?.addEventListener("abort", onAbort, { once: true });
      this.pending.set(id, { onEvent, resolve: end });
      this.send({ ...msg, id });
    });
  }

  list(): Promise<A2APeer[]> { return this.request({ t: "list" }); }
  grant(fileId: string, to: string): Promise<{ uri: string; name: string; mimeType: string; size: number }> { return this.request({ t: "grant", file_id: fileId, to }); }

  /** Gọi JSON-RPC A2A tới agent `to` (id bot hoặc username). signal: huỷ cuộc gọi. */
  call(to: string, method: string, params: any, opts: { onEvent?: (e: any) => void; timeoutMs: number; signal?: AbortSignal }): Promise<any> {
    return this.request({ t: "call", to, depth: 0, req: { jsonrpc: "2.0", id: crypto.randomUUID(), method, params } }, opts.onEvent, opts.timeoutMs, opts.signal);
  }

  event(cid: string, data: any) { this.send({ t: "ev", cid, data }); }
  done(cid: string, result?: any, error?: { code: number; message: string }) { this.send({ t: "done", cid, ...(error ? { error } : { result: result ?? null }) }); }
}
