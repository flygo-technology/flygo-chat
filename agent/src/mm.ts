// Client Mattermost tối giản: REST + WebSocket (tự kết nối lại).

const WS_PING_MS = 30_000;
const WS_STALE_MS = 75_000;

export interface Post {
  id: string;
  channel_id: string;
  root_id: string;
  user_id: string;
  message: string;
  create_at: number;
  type: string;
  props?: Record<string, any>;
  file_ids?: string[];
}

/** Vô hiệu @nhắc trong tin của bot (@user, @all, @channel, @here) để không làm phiền ai: chèn U+2060 sau "@".
 *  Bỏ qua phần code (`…` và ```…```) và email. */
export function defuseMentions(text: string, allow: string[] = []): string {
  return text.split(/(```[\s\S]*?(?:```|$)|`[^`\n]*`)/).map((part, i) =>
    i % 2 ? part : part.replace(/(^|[^\w@\u2060])@([a-zA-Z0-9_][a-zA-Z0-9_.-]*)/g, (_, pre, name) =>
      allow.includes(name.replace(/[.]+$/, "")) ? `${pre}@${name}` : `${pre}@\u2060${name}`)).join("");
}
const quiet = <T extends { message?: string; props?: Record<string, any> }>(p: T, allow: string[] = []): T =>
  ({ ...p, ...(p.message !== undefined ? { message: defuseMentions(p.message, allow) } : {}), props: { ...(p.props ?? {}), disable_group_highlight: true } });

export class MM {
  private users = new Map<string, any>();
  private channels = new Map<string, any>();
  constructor(public url: string, private token: string) {}

  async api<T = any>(method: string, path: string, body?: any): Promise<T> {
    const r = await fetch(`${this.url}/api/v4${path}`, {
      method,
      headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!r.ok) throw new Error(`${method} ${path} -> ${r.status} ${(await r.text()).slice(0, 300)}`);
    return (r.status === 204 ? undefined : await r.json()) as T;
  }

  me() { return this.api("GET", "/users/me"); }

  async user(id: string) {
    if (!this.users.has(id)) this.users.set(id, await this.api("GET", `/users/${id}`).catch(() => ({ id, username: id })));
    return this.users.get(id);
  }
  async displayName(id: string) {
    const u = await this.user(id);
    return u.nickname || [u.first_name, u.last_name].filter(Boolean).join(" ") || u.username;
  }
  async channel(id: string) {
    if (!this.channels.has(id)) this.channels.set(id, await this.api("GET", `/channels/${id}`));
    return this.channels.get(id);
  }

  forgetChannel(id: string) { this.channels.delete(id); }
  forgetUser(id: string) { this.users.delete(id); }

  /** allowMention: username được @nhắc thật (chỉ dùng cho tin cuối gửi người giao việc). */
  createPost(p: Partial<Post>, allowMention: string[] = []) { return this.api<Post>("POST", "/posts", quiet(p, allowMention)); }
  deletePost(id: string) { return this.api("DELETE", `/posts/${id}`); }
  patchPost(id: string, patch: { message?: string; props?: Record<string, any> }) { return this.api<Post>("PUT", `/posts/${id}/patch`, quiet(patch)); }
  react(postId: string, userId: string, emoji: string) {
    return this.api("POST", "/reactions", { user_id: userId, post_id: postId, emoji_name: emoji });
  }

  /** Bài trong thread (gốc + trả lời), sắp theo thời gian. */
  async thread(rootId: string): Promise<Post[]> {
    const r = await this.api<any>("GET", `/posts/${rootId}/thread?perPage=200`);
    return (r.order as string[]).map((id) => r.posts[id] as Post).sort((a, b) => a.create_at - b.create_at);
  }
  /** Bài gần nhất của kênh (trước `before` nếu có), sắp theo thời gian. */
  async channelPosts(channelId: string, perPage = 30, before?: string): Promise<Post[]> {
    const q = new URLSearchParams({ per_page: String(perPage) });
    if (before) q.set("before", before);
    const r = await this.api<any>("GET", `/channels/${channelId}/posts?${q}`);
    return (r.order as string[]).map((id) => r.posts[id] as Post).sort((a, b) => a.create_at - b.create_at);
  }

  /** WebSocket với tự kết nối lại; trả về hàm gửi action (vd. user_typing).
   *  Nhịp tim: 30 giây gửi "ping"; quá WS_STALE_MS không nhận gì (kể cả pong) thì coi là kết nối nửa mở, bỏ và nối lại. */
  connect(onEvent: (ev: any) => void, log: (s: string) => void) {
    let ws: WebSocket | null = null;
    let seq = 1;
    let backoff = 1000;
    let lastRx = Date.now();
    let retry: ReturnType<typeof setTimeout> | null = null;
    const reopen = () => { if (retry) return; retry = setTimeout(() => { retry = null; open(); }, backoff); backoff = Math.min(backoff * 2, 30000); };
    const open = () => {
      const sock = new WebSocket(`${this.url.replace(/^http/, "ws")}/api/v4/websocket`, { headers: { Authorization: `Bearer ${this.token}` } } as any);
      ws = sock;
      lastRx = Date.now();
      sock.onopen = () => { if (ws !== sock) return; backoff = 1000; lastRx = Date.now(); log("mm websocket connected"); };
      sock.onmessage = (e) => {
        if (ws !== sock) return;
        lastRx = Date.now();
        let ev: any;
        try { ev = JSON.parse(String(e.data)); } catch (err) { log(`ws event error: ${err}`); return; }
        if (!ev.event) return; // phản hồi action (pong, typing…)
        try { onEvent(ev); } catch (err) { log(`ws event error: ${err}`); }
      };
      sock.onclose = () => { if (ws !== sock) return; ws = null; log(`mm websocket closed, retry in ${backoff}ms`); reopen(); };
      sock.onerror = () => {};
    };
    setInterval(() => {
      if (!ws) return;
      if (Date.now() - lastRx > WS_STALE_MS) {
        const dead = ws;
        ws = null;
        log(`mm websocket im lặng ${Math.round((Date.now() - lastRx) / 1000)}s, nối lại`);
        try { (dead as any).terminate?.() ?? dead.close(); } catch {}
        reopen();
        return;
      }
      if (ws.readyState === WebSocket.OPEN) try { ws.send(JSON.stringify({ seq: seq++, action: "ping" })); } catch {}
    }, WS_PING_MS).unref?.();
    open();
    return (action: string, data: any) => { if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ seq: seq++, action, data })); };
  }
}
