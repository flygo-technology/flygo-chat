// Bộ công cụ chat cho agent (0.6.61): đọc / gửi / thao tác tin / quản lý cuộc trò chuyện ở MỌI chat trong phạm vi của bot.
// MCP flygo_chat (mcp-chat.ts) khai báo tool, runner xử lý ở POST /chat_op/<tool> trong lượt đang chạy (cần RUN_KEY).
//
// Phạm vi (token của BOT, không bao giờ đọc chat bot không thấy):
//   - chat bot là thành viên (nhóm, kênh, luồng bí mật, nhóm nhắn tin, DM giữa bot và một người);
//   - chat / luồng được tag cho phiên (ref grant, đi qua relay /ref như ref_read / ref_post);
//   - phiên AI riêng (kênh a-…) chỉ của chính người giao việc;
//   - người giao việc KHÔNG phải chủ bot: chỉ chat người đó cũng là thành viên, nhắn riêng chỉ cho chính người đó.
// Duyệt: gửi / ghim / quản lý chat cần người giao việc duyệt (thẻ duyệt của lượt, tự duyệt khi "Luôn cho phép"),
// trừ khi đích là chat hiện tại. Thao tác phá (bớt thành viên) chỉ chủ bot.
import { realpathSync, statSync } from "node:fs";
import { basename, resolve, sep } from "node:path";
import type { Database } from "bun:sqlite";
import { aiOf, projectOwnerOf, subOf } from "./chain";
import type { RunCard } from "./card";
import type { ApprovalDecision, ApprovalRequest } from "./engines/types";
import { clip } from "./labels";
import type { MM, Post } from "./mm";

/** Ngữ cảnh lượt đang chạy (runner dựng từ RUN_KEY). */
export interface ChatCtx {
  card: RunCard;
  dir: string;
  key: string; // khoá phiên (ch:<kênh> | root id | …)
  channelId: string;
  threadRoot: string;
  assigner: string;
  runKey: string; // RUN_KEY của lượt (gọi refTool của runner)
  ask: (req: ApprovalRequest) => Promise<ApprovalDecision>;
}
export interface RefLite { ref_id: string; name: string; write: boolean; kind: "chat" | "thread"; channel_id: string; root_id?: string }
/** Nơi một lượt mới được mở lại (thẻ có nút / nhắc hẹn): chỗ agent đang làm việc lúc gọi tool. */
export interface Origin { channel_id: string; root_id: string; assigner: string }
export interface ChatDeps {
  mm: MM;
  serverUrl: string;
  botToken: string;
  botId: string;
  botName: () => string;
  ownerIds: string[];
  isOwner: (id: string) => boolean;
  isAllowed: (id: string) => boolean;
  db: Database;
  log: (s: string) => void;
  chatName: (ch: any) => Promise<string>;
  /** Chat được tag của phiên (còn hạn). */
  refs: (key: string) => RefLite[];
  /** Gọi refTool của runner: read / thread / post. */
  refCall: (op: "read" | "thread" | "post", a: any, runKey: string) => Promise<string>;
  /** Bot đăng tin mốc đóng / mở luồng: runner cập nhật cache (không tự dừng lượt đang chạy của chính bot). */
  onCloseMark: (channelId: string, rootId: string, closed: boolean) => void;
  /** Mở một lượt mới ở `origin` (người giao việc = origin.assigner) sau khi đăng tin báo `notice`. */
  kickTurn: (origin: Origin, notice: string, text: string) => Promise<void>;
}

const ID = /^[a-z0-9]{26}$/;
const TZ = "Asia/Ho_Chi_Minh";
const fmtTime = (ms: number) => new Date(ms).toLocaleString("vi-VN", { timeZone: TZ, hour12: false });
const oneLine = (t: any, n: number) => clip(String(t ?? ""), n);
/** Bỏ dấu tiếng Việt, chữ thường: so khớp tên người không dấu. */
export const fold = (s: any) => String(s ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[đĐ]/g, "d").toLowerCase();
const rand32 = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => "abcdefghijklmnopqrstuvwxyz234567"[b & 31]).join("");
const rid = (n = 8) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => "abcdefghijklmnopqrstuvwxyz0123456789"[b % 36]).join("");
const TYPE_NAME: Record<string, string> = { O: "kênh công khai", P: "nhóm riêng", D: "chat 1-1", G: "nhóm nhắn tin" };
const NUM_EMOJI = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];

/** Thời điểm từ chuỗi: ISO (giờ Việt Nam nếu không ghi múi), "30m" / "2h" / "1d" (trước đây hoặc sau này theo `dir`), số ms. */
export function parseWhen(v: any, dir: 1 | -1): number | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v === "number" && Number.isFinite(v)) return v > 1e12 ? v : v * 1000;
  const s = String(v).trim();
  const rel = /^(\d+(?:\.\d+)?)\s*(m|min|phút|p|h|giờ|g|d|ngày)$/i.exec(s);
  if (rel) {
    const n = Number(rel[1]), u = rel[2].toLowerCase();
    const ms = /^(m|min|phút|p)$/.test(u) ? 60_000 : /^(h|giờ|g)$/.test(u) ? 3600_000 : 86400_000;
    return Date.now() + dir * n * ms;
  }
  if (/^\d{10,13}$/.test(s)) return Number(s) * (s.length === 10 ? 1000 : 1);
  // Không ghi múi giờ: hiểu là giờ Việt Nam (+07:00).
  const iso = /[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : /^\d{4}-\d\d-\d\d$/.test(s) ? `${s}T00:00:00+07:00` : `${s.replace(" ", "T")}+07:00`;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
}

interface Target { kind: "chat"; ch: any; id: string; name: string; current: boolean }
interface RefTarget { kind: "ref"; ref: RefLite; name: string }

export function createChatOps(d: ChatDeps) {
  const { mm, db } = d;
  db.run(`CREATE TABLE IF NOT EXISTS chat_cards (post_id TEXT PRIMARY KEY, data TEXT, at INTEGER)`);
  db.run(`CREATE TABLE IF NOT EXISTS chat_reminders (id TEXT PRIMARY KEY, at INTEGER, data TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)`);
  db.run(`DELETE FROM chat_cards WHERE at < ${Date.now() - 30 * 86400_000}`);

  // ---- thành viên (cache 60 giây) ----
  const memberCache = new Map<string, { at: number; ok: boolean }>();
  async function isMember(channelId: string, userId: string) {
    const k = `${channelId}:${userId}`, c = memberCache.get(k);
    if (c && Date.now() - c.at < 60_000) return c.ok;
    const ok = await mm.api("GET", `/channels/${channelId}/members/${userId}`).then(() => true, () => false);
    memberCache.set(k, { at: Date.now(), ok });
    return ok;
  }
  const forgetMembers = (channelId: string) => { for (const k of memberCache.keys()) if (k.startsWith(`${channelId}:`)) memberCache.delete(k); };

  // ---- kênh của bot trên mọi team ----
  let teamsC: { at: number; list: any[] } | null = null;
  async function teams(): Promise<any[]> {
    if (teamsC && Date.now() - teamsC.at < 600_000) return teamsC.list;
    const list = await mm.api<any[]>("GET", `/users/${d.botId}/teams`).catch(() => [] as any[]);
    teamsC = { at: Date.now(), list };
    return list;
  }
  let chansC: { at: number; list: any[]; members: Map<string, any> } | null = null;
  async function allChannels(fresh = false) {
    if (!fresh && chansC && Date.now() - chansC.at < 30_000) return chansC;
    const seen = new Map<string, any>(), members = new Map<string, any>();
    for (const t of await teams()) {
      for (const c of await mm.api<any[]>("GET", `/users/${d.botId}/teams/${t.id}/channels`).catch(() => [] as any[])) if (!c.delete_at) seen.set(c.id, c);
      for (const m of await mm.api<any[]>("GET", `/users/${d.botId}/teams/${t.id}/channels/members`).catch(() => [] as any[])) members.set(m.channel_id, m);
    }
    chansC = { at: Date.now(), list: [...seen.values()], members };
    return chansC;
  }
  const kindOf = (c: any) => c.type === "D" ? "dm" : c.type === "G" ? "group" : aiOf(c) ? "ai" : projectOwnerOf(c) !== null ? "project" : subOf(c) ? "private_thread" : "channel";
  const KIND_NAME: Record<string, string> = { dm: "chat 1-1", group: "nhóm nhắn tin", ai: "phiên AI", project: "dự án", private_thread: "luồng bí mật", channel: "kênh" };

  /** Chat có nằm trong phạm vi của lượt không: null = được, chuỗi = lý do không được. */
  async function outOfScope(ctx: ChatCtx, ch: any): Promise<string | null> {
    if (!ch || ch.delete_at) return "chat đã xoá hoặc bot không thấy";
    if (ch.id === ctx.channelId) return null;
    if (!(await isMember(ch.id, d.botId))) return `bot không là thành viên "${await d.chatName(ch).catch(() => ch.id)}"`;
    const ai = aiOf(ch);
    if (ai && ai.owner !== ctx.assigner) return "đây là phiên AI riêng của người khác";
    if (!d.isOwner(ctx.assigner) && !(await isMember(ch.id, ctx.assigner))) return "người giao việc không là thành viên chat này (người không phải chủ bot chỉ dùng được chat mình cũng ở trong)";
    return null;
  }

  async function userOf(spec: string): Promise<any> {
    const s = String(spec ?? "").trim().replace(/^@/, "");
    if (!s) throw new Error("Thiếu người dùng.");
    if (ID.test(s)) { const u = await mm.api<any>("GET", `/users/${s}`).catch(() => null); if (u) return u; }
    const u = await mm.api<any>("GET", `/users/username/${encodeURIComponent(s.toLowerCase())}`).catch(() => null);
    if (u) return u;
    const hits = await findUsers(s, 5);
    if (hits.length === 1) return hits[0];
    if (!hits.length) throw new Error(`Không thấy người dùng "${spec}" (dùng chat_find_user).`);
    throw new Error(`"${spec}" khớp nhiều người: ${hits.map((x) => `@${x.username} (${nameOf(x)})`).join(", ")}. Ghi rõ @username.`);
  }
  const nameOf = (u: any) => u?.nickname || [u?.first_name, u?.last_name].filter(Boolean).join(" ") || u?.username || "?";

  /** DM giữa bot và một người (tạo nếu chưa có). Người không phải chủ bot: chỉ DM với chính mình. */
  async function dmWith(ctx: ChatCtx, spec: string): Promise<Target> {
    const u = await userOf(spec);
    if (u.id === d.botId) throw new Error("Không nhắn riêng cho chính bot được.");
    if (u.delete_at) throw new Error(`@${u.username} đã bị khoá.`);
    if (!d.isOwner(ctx.assigner) && u.id !== ctx.assigner) throw new Error("Người giao việc không phải chủ bot: chỉ nhắn riêng được cho chính người giao việc.");
    const ch = await mm.api<any>("POST", "/channels/direct", [d.botId, u.id]);
    return { kind: "chat", ch, id: ch.id, name: `Chat với ${nameOf(u)}`, current: ch.id === ctx.channelId };
  }

  /** Chat từ chuỗi: bỏ trống / "here" = chat hiện tại; id kênh; @username = DM bot↔người đó; ref_id chat được tag; ~tên / tên. */
  async function resolveChat(ctx: ChatCtx, spec: any): Promise<Target | RefTarget> {
    const s = String(spec ?? "").trim();
    const low = s.toLowerCase();
    if (!s || ["here", "current", "đây", "hiện tại"].includes(low)) {
      const ch = await mm.channel(ctx.channelId);
      return { kind: "chat", ch, id: ch.id, name: await d.chatName(ch), current: true };
    }
    const ref = d.refs(ctx.key).find((r) => r.ref_id === s || r.ref_id === s.replace(/^ref:/, ""));
    if (ref) return { kind: "ref", ref, name: ref.name };
    if (s.startsWith("@")) return dmWith(ctx, s);
    let ch: any = null;
    if (ID.test(s)) {
      ch = await mm.channel(s).catch(() => null);
      if (!ch) {
        // Có thể là id người dùng: DM với người đó.
        const u = await mm.api<any>("GET", `/users/${s}`).catch(() => null);
        if (u) return dmWith(ctx, u.id);
        throw new Error(`Không thấy chat ${s} (bot không là thành viên hoặc id sai).`);
      }
    } else {
      const q = fold(s.replace(/^~/, ""));
      const { list } = await allChannels();
      const named = await Promise.all(list.map(async (c) => ({ c, n: fold(await d.chatName(c)), slug: String(c.name) })));
      const exact = named.filter((x) => x.slug === s.replace(/^~/, "") || x.n === q);
      const part = exact.length ? exact : named.filter((x) => x.n.includes(q));
      if (!part.length) throw new Error(`Không thấy chat "${s}" trong các chat bot ở (dùng chat_list).`);
      if (part.length > 1) throw new Error(`"${s}" khớp nhiều chat: ${part.slice(0, 8).map((x) => `"${x.c.display_name || x.slug}" (id ${x.c.id})`).join(", ")}. Dùng id kênh.`);
      ch = part[0].c;
    }
    const why = await outOfScope(ctx, ch);
    if (why) throw new Error(`Không dùng được chat này: ${why}.`);
    return { kind: "chat", ch, id: ch.id, name: await d.chatName(ch), current: ch.id === ctx.channelId };
  }
  async function chatOnly(ctx: ChatCtx, spec: any): Promise<Target> {
    const t = await resolveChat(ctx, spec);
    if (t.kind === "ref") throw new Error(`"${t.name}" là chat được tag (bot không là thành viên): chỉ dùng được ref_read / ref_thread / ref_post hoặc chat_history / chat_send với chat=${t.ref.ref_id}.`);
    return t;
  }
  /** Tin theo id, kèm kiểm tra phạm vi của kênh chứa tin. */
  async function postOf(ctx: ChatCtx, id: any): Promise<{ p: Post & Record<string, any>; t: Target }> {
    const pid = String(id ?? "").trim().replace(/^#/, "");
    if (!ID.test(pid)) throw new Error("post_id không hợp lệ (26 ký tự, lấy từ #id trong chat_history / chat_thread / chat_search).");
    const p = await mm.api<any>("GET", `/posts/${pid}`).catch(() => null);
    if (!p || p.delete_at) throw new Error(`Không thấy tin ${pid} (đã xoá hoặc bot không đọc được).`);
    const ch = await mm.channel(p.channel_id).catch(() => null);
    const why = await outOfScope(ctx, ch);
    if (why) throw new Error(`Không dùng được tin này: ${why}.`);
    return { p, t: { kind: "chat", ch, id: ch.id, name: await d.chatName(ch), current: ch.id === ctx.channelId } };
  }
  const link = (postId: string) => `${d.serverUrl}/_redirect/pl/${postId}`;
  const sid = (p: string) => `${p}-${crypto.randomUUID().slice(0, 8)}`;
  const step = (ctx: ChatCtx, prefix: string, title: string, label: string, ok = true, detail?: string) =>
    ctx.card.step({ id: sid(prefix), kind: "tool", title, label: clip(label, 60), status: ok ? "done" : "error", detail: detail?.slice(0, 600) });
  /** Duyệt: đích là chat hiện tại thì không cần (trừ khi always). */
  async function approve(ctx: ChatCtx, t: { current?: boolean } | null, title: string, detail: string, always = false) {
    if (!always && t?.current) return true;
    return (await ctx.ask({ kind: "tool", title, detail: detail.slice(0, 1500) })) === "accept";
  }

  // ---- định dạng tin ----
  async function fmt(posts: any[], opts: { mark?: (p: any) => string } = {}) {
    const out: string[] = [];
    for (const p of posts) {
      if (p.type && String(p.type).startsWith("system_")) continue;
      const am = p.props?.flygo_agent_message;
      if (am ? am.streaming : p.props?.flygo_agent || p.props?.flygo_agent_approval) continue;
      if (p.props?.flygo_thread_closed !== undefined) { out.push(`[${fmtTime(p.create_at)}] (${p.props.flygo_thread_closed === true || p.props.flygo_thread_closed === "true" ? "luồng đã đóng" : "luồng mở lại"})`); continue; }
      if (!String(p.message ?? "").trim() && !p.file_ids?.length && !p.props?.flygo_poll) continue;
      const files = (p.metadata?.files ?? []) as any[];
      const fl = files.length ? ` [tệp: ${files.map((f) => `${f.name} (id=${f.id})`).join("; ")}]` : p.file_ids?.length ? ` [tệp id: ${p.file_ids.join(", ")}]` : "";
      const pr = p.metadata?.priority?.priority ? ` [${p.metadata.priority.priority === "urgent" ? "KHẨN" : "QUAN TRỌNG"}${p.metadata.priority.requested_ack ? ", cần xác nhận" : ""}]` : "";
      const poll = p.props?.flygo_poll ? ` [bình chọn: ${(p.props.flygo_poll.options ?? []).map((o: any) => o.text).join(" / ")}]` : "";
      const where = p.root_id ? ` (trả lời trong luồng ${p.root_id})` : p.reply_count ? ` (luồng ${p.reply_count} trả lời)` : "";
      out.push(`${opts.mark?.(p) ?? ""}[${fmtTime(p.create_at)}] ${await mm.displayName(p.user_id)}${where} #${p.id}: ${oneLine(p.message, 2000)}${fl}${pr}${poll}`);
    }
    return out.join("\n") || "(không có tin nào)";
  }
  const listOf = (r: any): any[] => ((r?.order ?? []) as string[]).map((id) => r.posts[id]).filter(Boolean).sort((a: any, b: any) => a.create_at - b.create_at);
  async function postsSince(channelId: string, since: number) {
    const r = await mm.api<any>("GET", `/channels/${channelId}/posts?since=${since}`).catch(() => null);
    return listOf(r).filter((p: any) => !p.delete_at && p.create_at > since);
  }
  const isNoise = (p: any) => (p.type && String(p.type).startsWith("system_")) || p.props?.flygo_agent_message?.streaming || (p.props?.flygo_agent && !p.props?.flygo_agent_message) || p.props?.flygo_agent_approval || p.props?.flygo_thread_closed !== undefined;

  // ---- tệp gửi kèm: chỉ trong thư mục làm việc ----
  async function upload(ctx: ChatCtx, channelId: string, paths: any): Promise<{ ids: string[]; names: string[]; errors: string[] }> {
    const list: string[] = Array.isArray(paths) ? paths.map(String).slice(0, 10) : [];
    const ids: string[] = [], names: string[] = [], errors: string[] = [];
    if (!list.length) return { ids, names, errors };
    const root = realpathSync(ctx.dir);
    const cfgc = await mm.api<any>("GET", "/config/client?format=old").catch(() => ({}));
    const maxSize = Number(cfgc.MaxFileSize) || 100 * 1024 * 1024;
    for (const p of list) {
      let real: string;
      try { real = realpathSync(resolve(ctx.dir, p)); } catch { errors.push(`${p}: không tồn tại`); continue; }
      if (real !== root && !real.startsWith(root + sep)) { errors.push(`${p}: nằm ngoài thư mục làm việc`); continue; }
      const st = statSync(real);
      if (!st.isFile()) { errors.push(`${p}: không phải tệp`); continue; }
      if (st.size > maxSize) { errors.push(`${p}: vượt giới hạn ${maxSize}B`); continue; }
      const form = new FormData();
      form.append("channel_id", channelId);
      form.append("files", Bun.file(real), basename(real));
      const r = await fetch(`${d.serverUrl}/api/v4/files`, { method: "POST", headers: { Authorization: `Bearer ${d.botToken}` }, body: form });
      if (!r.ok) { errors.push(`${p}: tải lên lỗi ${r.status}`); continue; }
      const info = (await r.json()).file_infos?.[0];
      if (info?.id) { ids.push(info.id); names.push(info.name); }
    }
    return { ids, names, errors };
  }
  /** Tệp của một tin -> tải lại vào kênh khác (chuyển tiếp). */
  async function copyFiles(files: any[], channelId: string) {
    const ids: string[] = [];
    for (const f of files.slice(0, 10)) {
      const r = await fetch(`${d.serverUrl}/api/v4/files/${f.id}`, { headers: { Authorization: `Bearer ${d.botToken}` } });
      if (!r.ok) continue;
      const form = new FormData();
      form.append("channel_id", channelId);
      form.append("files", new Blob([await r.arrayBuffer()], { type: f.mime_type || "application/octet-stream" }), f.name || "file");
      const u = await fetch(`${d.serverUrl}/api/v4/files`, { method: "POST", headers: { Authorization: `Bearer ${d.botToken}` }, body: form });
      if (u.ok) { const id = (await u.json()).file_infos?.[0]?.id; if (id) ids.push(id); }
    }
    return ids;
  }
  /** Gửi tin vào chat đích. Trong luồng hiện tại: flygo_reply="thread" như tin của lượt. */
  async function postTo(ctx: ChatCtx, t: Target, body: { message: string; root_id?: string; file_ids?: string[]; props?: Record<string, any>; priority?: string; ack?: boolean; mention?: string[] }) {
    const props: Record<string, any> = { flygo_agent_owner: ctx.assigner, ...(body.root_id ? { flygo_reply: "thread" } : {}), ...(body.props ?? {}) };
    const meta = body.priority || body.ack ? { priority: { priority: body.priority ?? "", requested_ack: !!body.ack } } : undefined;
    return mm.createPost({ channel_id: t.id, root_id: body.root_id ?? "", message: body.message, file_ids: body.file_ids, props, ...(meta ? { metadata: meta } : {}) } as any, body.mention ?? []);
  }

  // ---- thẻ có nút (flygo_agent_question, lượt mới khi có người bấm) ----
  interface CardRec { post_id: string; channel_id: string; text: string; options: { label: string; description?: string }[]; multi: boolean; origin: Origin; meta: any }
  const cardOf = (postId: string): CardRec | null => { const r = db.query("SELECT data FROM chat_cards WHERE post_id = ?").get(postId) as { data: string } | null; return r ? JSON.parse(r.data) : null; };
  const dropCard = (postId: string) => db.query("DELETE FROM chat_cards WHERE post_id = ?").run(postId);
  const picks = new Map<string, Set<number>>();
  async function answerCard(c: CardRec, userId: string, choices: string[]) {
    if (!cardOf(c.post_id)) return; // đã có người bấm
    if (userId === d.botId || !(await isMember(c.channel_id, userId))) return;
    dropCard(c.post_id); picks.delete(c.post_id);
    const who = await mm.displayName(userId).catch(() => userId);
    const answer = choices.join(", ");
    await mm.patchPost(c.post_id, { message: `${c.text}\n→ ${answer} (${who})`, props: { ...((await mm.api<any>("GET", `/posts/${c.post_id}`).catch(() => null))?.props ?? {}), flygo_agent_question: { ...c.meta, status: "answered", answer: `${answer} (${who})`, choices, answered_by: userId } } }).catch(() => {});
    if (!d.isAllowed(c.origin.assigner)) return d.log(`thẻ ${c.post_id}: người giao việc không còn được gọi bot, không mở lượt`);
    const ch = await mm.channel(c.channel_id).catch(() => null);
    const where = c.channel_id === c.origin.channel_id ? "" : ` ở "${ch ? await d.chatName(ch) : c.channel_id}"`;
    d.log(`thẻ ${c.post_id}: ${who} chọn ${answer}`);
    await d.kickTurn(c.origin, `🔘 ${who} chọn «${answer}» trên thẻ${where}: ${oneLine(c.text, 80)}`,
      `(Thẻ có nút bạn gửi trước đó${where} (tin #${c.post_id}, ${link(c.post_id)}) vừa có người bấm: ${who} (user id ${userId}) chọn «${answer}». Nội dung thẻ: "${oneLine(c.text, 500)}". Làm tiếp việc tương ứng với lựa chọn này rồi báo kết quả.)`);
  }
  /** Reaction lên thẻ: true = đã xử lý. */
  function onCardReaction(r: any, removed = false): boolean {
    const c = cardOf(r.post_id);
    if (!c || r.user_id === d.botId) return !!c;
    const i = NUM_EMOJI.indexOf(r.emoji_name);
    const set = picks.get(c.post_id) ?? new Set<number>();
    picks.set(c.post_id, set);
    if (i >= 0 && i < c.options.length) {
      if (removed) { set.delete(i); return true; }
      if (!c.multi) { answerCard(c, r.user_id, [c.options[i].label]).catch((e) => d.log(`thẻ: ${e?.message ?? e}`)); return true; }
      set.add(i);
      return true;
    }
    if (!removed && r.emoji_name === "white_check_mark" && set.size) answerCard(c, r.user_id, [...set].sort().map((k) => c.options[k].label)).catch((e) => d.log(`thẻ: ${e?.message ?? e}`));
    return true;
  }
  /** Tin trả lời thẻ (props.flygo_agent_answer.post_id = thẻ): true = đã xử lý. */
  function onCardAnswer(post: Post, ans: any): boolean {
    const c = cardOf(String(ans?.post_id ?? ""));
    if (!c) return false;
    const choices = (Array.isArray(ans.choices) ? ans.choices : []).map(String).filter((x: string) => c.options.some((o) => o.label === x));
    if (choices.length) answerCard(c, post.user_id, choices).catch((e) => d.log(`thẻ: ${e?.message ?? e}`));
    return true;
  }

  // ---- nhắc hẹn của bot: tới giờ thì mở lượt ở chỗ đã đặt ----
  async function remindTick() {
    const due = db.query("SELECT id, data FROM chat_reminders WHERE at <= ?").all(Date.now()) as { id: string; data: string }[];
    for (const r of due) {
      db.query("DELETE FROM chat_reminders WHERE id = ?").run(r.id);
      const x = JSON.parse(r.data);
      if (!d.isAllowed(x.origin.assigner)) continue;
      await d.kickTurn(x.origin, `⏰ Nhắc hẹn: ${oneLine(x.preview, 80)}`, `(Nhắc hẹn bạn tự đặt lúc trước cho tin #${x.post_id} (${link(x.post_id)}) ở "${x.where}": "${oneLine(x.preview, 500)}".${x.note ? ` Ghi chú: ${x.note}.` : ""} Đọc lại tin đó (chat_get_message) rồi làm việc cần làm.)`).catch((e) => d.log(`nhắc hẹn: ${e?.message ?? e}`));
    }
  }
  setInterval(() => remindTick().catch(() => {}), 30_000);

  // ---- trạng thái riêng của bot (user_set_status): runner giữ và làm mới cùng trạng thái "đang chạy" ----
  function statusOverride(): { text: string; emoji: string; until: number } | null {
    const r = db.query("SELECT v FROM kv WHERE k = 'bot_status'").get() as { v: string } | null;
    if (!r) return null;
    const s = JSON.parse(r.v);
    if (s.until && s.until < Date.now()) { db.query("DELETE FROM kv WHERE k = 'bot_status'").run(); return null; }
    return s;
  }

  // ---- tìm người ----
  let dirC: { at: number; users: any[] } | null = null;
  async function directory() {
    if (dirC && Date.now() - dirC.at < 600_000) return dirC.users;
    const map = new Map<string, any>();
    for (const t of await teams()) {
      for (let page = 0; page < 10; page++) {
        const us = await mm.api<any[]>("GET", `/users?in_team=${t.id}&active=true&per_page=200&page=${page}`).catch(() => [] as any[]);
        for (const u of us) map.set(u.id, u);
        if (us.length < 200) break;
      }
    }
    dirC = { at: Date.now(), users: [...map.values()] };
    return dirC.users;
  }
  async function findUsers(q: string, limit = 20): Promise<any[]> {
    const words = fold(q).replace(/^@/, "").split(/\s+/).filter(Boolean);
    if (!words.length) return [];
    const hay = (u: any) => fold([u.username, u.first_name, u.last_name, u.nickname, u.position].filter(Boolean).join(" "));
    const found = new Map<string, any>();
    for (const u of await mm.api<any[]>("POST", "/users/search", { term: q.replace(/^@/, ""), allow_inactive: false, limit: 50 }).catch(() => [] as any[])) found.set(u.id, u);
    for (const u of await directory()) if (words.every((w) => hay(u).includes(w))) found.set(u.id, u);
    const score = (u: any) => (fold(u.username) === words.join("") ? 0 : hay(u).startsWith(words[0]) ? 1 : 2);
    return [...found.values()].filter((u) => !u.delete_at && words.every((w) => hay(u).includes(w))).sort((a, b) => score(a) - score(b)).slice(0, limit);
  }

  // ---- các tool ----
  async function tool(op: string, a: any, ctx: ChatCtx): Promise<string> {
    switch (op) {
      // ======== đọc ========
      case "chat_list": {
        const { list, members } = await allChannels(true);
        const type = String(a.type ?? "all");
        const q = a.query ? fold(a.query) : "";
        const since = parseWhen(a.active_since, -1) ?? 0;
        const limit = Math.min(Math.max(Number(a.limit) || 30, 1), 100);
        const rows: string[] = [];
        const sorted = list.filter((c) => (type === "all" || kindOf(c) === type) && (c.last_post_at ?? 0) >= since).sort((x, y) => (y.last_post_at ?? 0) - (x.last_post_at ?? 0));
        for (const c of sorted) {
          if (rows.length >= limit) break;
          if (await outOfScope(ctx, c)) continue;
          const name = await d.chatName(c);
          if (q && !fold(name).includes(q) && !String(c.name).includes(q)) continue;
          const m = members.get(c.id);
          const unread = Math.max(0, (c.total_msg_count ?? 0) - (m?.msg_count ?? 0));
          if (a.unread_only && !unread && !m?.mention_count) continue;
          const last = listOf(await mm.api<any>("GET", `/channels/${c.id}/posts?per_page=1`).catch(() => null)).pop();
          const prev = last ? ` · ${fmtTime(last.create_at)} ${await mm.displayName(last.user_id)}: ${oneLine(last.message || (last.file_ids?.length ? "(tệp)" : ""), 80)}` : "";
          rows.push(`- "${name}" · ${KIND_NAME[kindOf(c)]}${c.type === "P" || c.type === "O" ? ` (${TYPE_NAME[c.type]})` : ""} · id ${c.id}${unread ? ` · ${unread} tin bot chưa đọc` : ""}${m?.mention_count ? ` · ${m.mention_count} lần nhắc bot` : ""}${c.id === ctx.channelId ? " · ← đang ở đây" : ""}${prev}`);
        }
        const refs = d.refs(ctx.key);
        return [rows.length ? `Chat bot thấy (${rows.length}, mới nhất trước):` : "Không có chat nào khớp.", ...rows,
          refs.length ? `Chat được tag cho phiên này (bot không là thành viên): ${refs.map((r) => `"${r.name}" (chat=${r.ref_id}, ${r.write ? "đọc + gửi" : "chỉ đọc"})`).join("; ")}` : ""].filter(Boolean).join("\n");
      }
      case "chat_unread": {
        const since = parseWhen(a.since, -1) ?? Date.now() - 24 * 3600_000;
        const onlyMentions = a.only === "mentions";
        const limit = Math.min(Math.max(Number(a.limit) || 80, 1), 300);
        const owners = await Promise.all(d.ownerIds.map((id) => mm.user(id).then((u: any) => u.username as string).catch(() => "")));
        const names = [d.botName(), ...owners].filter(Boolean).map((n) => n.toLowerCase());
        const mentionRe = new RegExp(`@(${[...names, "all", "channel", "here"].map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})\\b`, "i");
        const { list } = await allChannels(true);
        const out: string[] = [];
        let total = 0;
        for (const c of list.filter((c) => (c.last_post_at ?? 0) > since).sort((x, y) => (y.last_post_at ?? 0) - (x.last_post_at ?? 0))) {
          if (total >= limit) break;
          if (await outOfScope(ctx, c)) continue;
          const ps = (await postsSince(c.id, since)).filter((p: any) => p.user_id !== d.botId && !isNoise(p));
          const hit = (p: any) => c.type === "D" || mentionRe.test(String(p.message ?? ""));
          const show = (onlyMentions ? ps.filter(hit) : ps).slice(-Math.min(30, limit - total));
          if (!show.length) continue;
          total += show.length;
          out.push(`## "${await d.chatName(c)}" (id ${c.id}, ${KIND_NAME[kindOf(c)]}) — ${ps.length} tin mới${ps.length > show.length ? `, hiện ${show.length} tin cuối` : ""}`);
          out.push(await fmt(show, { mark: (p) => (hit(p) ? "⚑ " : "") }));
        }
        return out.length ? `Tin từ ${fmtTime(since)} (⚑ = nhắc bot / chủ bot / cả nhóm, hoặc tin nhắn riêng):\n${out.join("\n")}` : `Không có tin mới${onlyMentions ? " nhắc tới bot / chủ bot" : ""} từ ${fmtTime(since)}.`;
      }
      case "chat_history": {
        const t = await resolveChat(ctx, a.chat);
        if (t.kind === "ref") return d.refCall("read", { ref_id: t.ref.ref_id, before: a.before_post_id, limit: a.limit, q: a.q }, ctx.runKey);
        const limit = Math.min(Math.max(Number(a.limit) || 30, 1), 100);
        const ps = await mm.channelPosts(t.id, limit, a.before_post_id || undefined);
        return `"${t.name}" (id ${t.id}):\n${await fmt(ps)}`;
      }
      case "chat_thread": {
        const t = await resolveChat(ctx, a.chat);
        if (t.kind === "ref") return d.refCall("thread", { ref_id: t.ref.ref_id, root: a.root_id }, ctx.runKey);
        const root = String(a.root_id ?? "") || (t.current ? ctx.threadRoot : "");
        if (!root) return "Cần root_id (id tin gốc của luồng).";
        const ps = await mm.thread(root).catch(() => [] as Post[]);
        if (!ps.length || ps[0].channel_id !== t.id) return `Luồng ${root} không thuộc "${t.name}".`;
        return `Luồng ${root} ở "${t.name}":\n${await fmt(ps)}`;
      }
      case "chat_search": {
        const t = await resolveChat(ctx, a.chat);
        if (t.kind === "ref") return d.refCall("read", { ref_id: t.ref.ref_id, q: a.terms, limit: 30 }, ctx.runKey);
        const team = t.ch.team_id || (await teams())[0]?.id;
        const r = await mm.api<any>("POST", `/teams/${team}/posts/search`, { terms: String(a.terms ?? ""), is_or_search: false, per_page: 60, include_deleted_channels: false });
        const ps = listOf(r).filter((p: any) => p.channel_id === t.id);
        return `Tìm "${a.terms}" ở "${t.name}":\n${await fmt(ps)}`;
      }
      case "chat_get_message": {
        const { p, t } = await postOf(ctx, a.post_id);
        const md = p.metadata ?? {};
        const reacts = new Map<string, string[]>();
        for (const r of md.reactions ?? []) reacts.set(r.emoji_name, [...(reacts.get(r.emoji_name) ?? []), await mm.displayName(r.user_id)]);
        const acks = await Promise.all((md.acknowledgements ?? []).filter((x: any) => x.acknowledged_at).map((x: any) => mm.displayName(x.user_id)));
        const thread = p.root_id ? `trả lời trong luồng ${p.root_id}` : p.reply_count ? `tin gốc của luồng ${p.reply_count} trả lời` : "tin ở chat chính, chưa có trả lời";
        const poll = p.props?.flygo_poll;
        const votes = poll ? (poll.options ?? []).map((o: any) => `${o.text}: ${Object.values<any>(poll.votes ?? {}).filter((v) => Array.isArray(v) && v.includes(o.id)).length}`).join(", ") : "";
        return [
          `Tin #${p.id} ở "${t.name}" (kênh ${t.id}) · ${link(p.id)}`,
          `Người gửi: ${await mm.displayName(p.user_id)} (user id ${p.user_id}) · lúc ${fmtTime(p.create_at)}${p.edit_at ? ` · sửa lúc ${fmtTime(p.edit_at)}` : ""}${p.is_pinned ? " · 📌 đã ghim" : ""}`,
          `Vị trí: ${thread}`,
          md.priority?.priority || md.priority?.requested_ack ? `Ưu tiên: ${md.priority.priority === "urgent" ? "khẩn" : md.priority.priority === "important" ? "quan trọng" : "thường"}${md.priority.requested_ack ? ` · cần xác nhận đã đọc (${acks.length} người đã xác nhận${acks.length ? `: ${acks.join(", ")}` : ""})` : ""}` : "",
          reacts.size ? `Cảm xúc: ${[...reacts].map(([e, us]) => `:${e}: ${us.join(", ")}`).join(" · ")}` : "",
          (md.files ?? []).length ? `Tệp: ${(md.files as any[]).map((f) => `${f.name} (file_id=${f.id}, ${f.mime_type}, ${f.size}B)`).join("; ")}` : "",
          poll ? `Bình chọn "${poll.question}"${poll.closed ? " (đã khoá)" : ""}: ${votes}` : "",
          p.props?.flygo_bilingual ? `Song ngữ: ${(p.props.flygo_bilingual.langs ?? []).join("/")}` : "",
          `Nội dung:\n${p.message || "(trống)"}`,
        ].filter(Boolean).join("\n");
      }
      case "chat_members": {
        const t = await chatOnly(ctx, a.chat);
        const ms = await mm.api<any[]>("GET", `/channels/${t.id}/members?per_page=200`);
        const us = await mm.api<any[]>("POST", "/users/ids", ms.map((m) => m.user_id));
        const by = new Map(us.map((u) => [u.id, u]));
        const lines = ms.map((m) => { const u = by.get(m.user_id) ?? { username: m.user_id }; const tags = [u.position, m.scheme_admin ? "quản trị" : "", u.is_bot ? "bot" : ""].filter(Boolean).join(", "); return `- ${nameOf(u)} (@${u.username}, id ${m.user_id})${tags ? ` — ${tags}` : ""}`; });
        return [`"${t.name}" (${TYPE_NAME[t.ch.type] ?? t.ch.type}, id ${t.id}) — ${ms.length} thành viên:`, ...lines].join("\n");
      }
      case "chat_find_user": {
        const hits = await findUsers(String(a.query ?? ""), Math.min(Number(a.limit) || 15, 50));
        if (!hits.length) return `Không thấy ai khớp "${a.query}".`;
        return hits.map((u) => `- ${nameOf(u)} (@${u.username}, id ${u.id})${u.position ? ` — ${u.position}` : ""}${u.is_bot ? " · bot" : ""}`).join("\n");
      }
      case "user_info": {
        const u = await userOf(String(a.user ?? ""));
        const st = await mm.api<any>("GET", `/users/${u.id}/status`).catch(() => null);
        let cs: any = u.props?.customStatus;
        if (typeof cs === "string") try { cs = JSON.parse(cs); } catch { cs = null; }
        const csOk = cs && (cs.text || cs.emoji) && (!cs.expires_at || Date.parse(cs.expires_at) > Date.now());
        const tz = u.timezone?.useAutomaticTimezone === "true" || u.timezone?.useAutomaticTimezone === true ? u.timezone?.automaticTimezone : u.timezone?.manualTimezone;
        let local = "";
        try { if (tz) local = new Date().toLocaleString("vi-VN", { timeZone: tz, hour12: false }); } catch {}
        const ST: Record<string, string> = { online: "trực tuyến", away: "vắng", dnd: "không làm phiền", offline: "ngoại tuyến" };
        return [
          `${nameOf(u)} (@${u.username}, user id ${u.id})${u.is_bot ? " · bot" : ""}`,
          u.position ? `Chức danh: ${u.position}` : "",
          st ? `Trạng thái: ${ST[st.status] ?? st.status}${st.last_activity_at ? ` · hoạt động gần nhất ${fmtTime(st.last_activity_at)}` : ""}` : "",
          csOk ? `Trạng thái tuỳ chỉnh: ${cs.emoji ? `:${cs.emoji}: ` : ""}${cs.text ?? ""}${cs.expires_at ? ` (tới ${fmtTime(Date.parse(cs.expires_at))})` : ""}` : "",
          tz ? `Múi giờ: ${tz}${local ? ` · giờ ở đó: ${local}` : ""}` : "",
          u.delete_at ? "Tài khoản đã bị khoá." : "",
        ].filter(Boolean).join("\n");
      }
      case "chat_pinned": {
        const t = await chatOnly(ctx, a.chat);
        const r = await mm.api<any>("GET", `/channels/${t.id}/pinned`);
        return `Tin ghim ở "${t.name}":\n${await fmt(listOf(r))}`;
      }
      case "chat_digest": {
        const since = parseWhen(a.since, -1) ?? Date.now() - 24 * 3600_000;
        const per = Math.min(Math.max(Number(a.limit_per_chat) || 40, 5), 150);
        const targets: Target[] = [];
        if (Array.isArray(a.chats) && a.chats.length) for (const c of a.chats.slice(0, 15)) targets.push(await chatOnly(ctx, c));
        else {
          const { list } = await allChannels(true);
          for (const c of list.filter((c) => (c.last_post_at ?? 0) > since).sort((x, y) => (y.last_post_at ?? 0) - (x.last_post_at ?? 0))) {
            if (targets.length >= 15) break;
            if (!(await outOfScope(ctx, c))) targets.push({ kind: "chat", ch: c, id: c.id, name: await d.chatName(c), current: c.id === ctx.channelId });
          }
        }
        const out: string[] = [];
        for (const t of targets) {
          const ps = (await postsSince(t.id, since)).filter((p: any) => !isNoise(p));
          if (!ps.length) { if (a.chats) out.push(`## "${t.name}" (id ${t.id}): không có tin mới`); continue; }
          const who = new Map<string, number>();
          for (const p of ps) who.set(p.user_id, (who.get(p.user_id) ?? 0) + 1);
          const people = await Promise.all([...who].sort((x, y) => y[1] - x[1]).slice(0, 8).map(async ([id, n]) => `${await mm.displayName(id)} (${n})`));
          const roots = new Map<string, number>();
          for (const p of ps) if (p.root_id) roots.set(p.root_id, (roots.get(p.root_id) ?? 0) + 1);
          const hot = await Promise.all([...roots].sort((x, y) => y[1] - x[1]).slice(0, 5).map(async ([id, n]) => {
            const r = ps.find((p: any) => p.id === id) ?? await mm.api<any>("GET", `/posts/${id}`).catch(() => null);
            return `  - luồng #${id} (${n} tin mới): "${oneLine(r?.message ?? "", 100)}"`;
          }));
          const urgent = ps.filter((p: any) => p.metadata?.priority?.priority);
          const files = ps.flatMap((p: any) => (p.metadata?.files ?? []).map((f: any) => f.name));
          const polls = ps.filter((p: any) => p.props?.flygo_poll);
          out.push([
            `## "${t.name}" (id ${t.id}, ${KIND_NAME[kindOf(t.ch)]}) — ${ps.length} tin, ${who.size} người: ${people.join(", ")}`,
            hot.length ? `Luồng sôi nổi:\n${hot.join("\n")}` : "",
            urgent.length ? `Tin quan trọng / khẩn: ${urgent.map((p: any) => `#${p.id}`).join(", ")}` : "",
            polls.length ? `Bình chọn: ${polls.map((p: any) => `"${p.props.flygo_poll.question}" #${p.id}`).join(", ")}` : "",
            files.length ? `Tệp: ${files.slice(0, 15).join(", ")}${files.length > 15 ? ` (+${files.length - 15})` : ""}` : "",
            `Tin (cũ → mới${ps.length > per ? `, ${per} tin cuối` : ""}):`,
            await fmt(ps.slice(-per)),
          ].filter(Boolean).join("\n"));
        }
        return out.length ? `Dữ liệu tóm tắt từ ${fmtTime(since)} (tự tóm tắt cho người dùng, nêu việc cần làm / quyết định / câu hỏi chưa trả lời):\n\n${out.join("\n\n")}` : `Không có tin mới từ ${fmtTime(since)}.`;
      }

      // ======== gửi ========
      case "chat_send": {
        const t = await resolveChat(ctx, a.to);
        const message = String(a.message ?? "");
        if (!message.trim() && !(Array.isArray(a.files) && a.files.length)) return "Thiếu nội dung (message) hoặc tệp.";
        if (t.kind === "ref") {
          if (a.files?.length || a.priority) return `"${t.name}" là chat được tag: chỉ gửi được chữ (không tệp, không ưu tiên).`;
          return d.refCall("post", { ref_id: t.ref.ref_id, message, root_id: a.thread_root }, ctx.runKey);
        }
        let root = "";
        if (a.thread_root) {
          const { p } = await postOf(ctx, a.thread_root);
          if (p.channel_id !== t.id) return `Tin ${a.thread_root} không thuộc "${t.name}".`;
          root = p.root_id || p.id;
        }
        const priority = a.priority === "urgent" || a.priority === "important" ? a.priority : "";
        if (root && (priority || a.ack)) return "Tin trả lời trong luồng không gắn ưu tiên / xác nhận đã đọc được (máy chủ chỉ cho tin gốc). Bỏ thread_root hoặc bỏ priority / ack.";
        const flags = [priority === "urgent" ? "KHẨN" : priority === "important" ? "QUAN TRỌNG" : "", a.ack ? "cần xác nhận đã đọc" : "", a.silent ? "im lặng" : "", root ? `trong luồng #${root}` : ""].filter(Boolean).join(", ");
        const files = Array.isArray(a.files) ? a.files.map(String) : [];
        if (!(await approve(ctx, t, `Gửi tin vào ${t.name}${flags ? ` (${flags})` : ""}`, `${message}${files.length ? `\n📎 ${files.map((f: string) => basename(f)).join(", ")}` : ""}`))) return "Người giao việc không duyệt, chưa gửi.";
        const up = await upload(ctx, t.id, files);
        if (files.length && !up.ids.length) return `Không gửi được tệp:\n- ${up.errors.join("\n- ")}`;
        const mention = (Array.isArray(a.mention) ? a.mention : []).map((x: any) => String(x).replace(/^@/, ""));
        const p = await postTo(ctx, t, { message, root_id: root, file_ids: up.ids, priority, ack: !!a.ack, mention, props: { ...(a.silent ? { flygo_silent: true } : {}), flygo_agent_sent: true } });
        step(ctx, "send", `Đã gửi vào ${t.name}${flags ? ` (${flags})` : ""}`, `Gửi tin vào ${t.name}`, true, message);
        return `Đã gửi vào "${t.name}" (tin #${p.id}): ${link(p.id)}${up.errors.length ? `\nTệp không gửi được:\n- ${up.errors.join("\n- ")}` : ""}`;
      }
      case "chat_reply": {
        const { p, t } = await postOf(ctx, a.post_id);
        const message = String(a.message ?? "");
        const files = Array.isArray(a.files) ? a.files.map(String) : [];
        if (!message.trim() && !files.length) return "Thiếu nội dung trả lời.";
        if (!(await approve(ctx, t, `Trả lời tin của ${await mm.displayName(p.user_id)} ở ${t.name}`, `> ${oneLine(p.message, 200)}\n\n${message}`))) return "Người giao việc không duyệt, chưa gửi.";
        const up = await upload(ctx, t.id, files);
        const r = await postTo(ctx, t, { message, root_id: p.root_id || p.id, file_ids: up.ids, props: { flygo_agent_sent: true } });
        step(ctx, "reply", `Đã trả lời trong luồng ở ${t.name}`, `Trả lời tin ở ${t.name}`, true, message);
        return `Đã trả lời trong luồng (tin #${r.id}): ${link(r.id)}${up.errors.length ? `\nTệp không gửi được:\n- ${up.errors.join("\n- ")}` : ""}`;
      }
      case "chat_forward": {
        const { p, t: from } = await postOf(ctx, a.post_id);
        const t = await chatOnly(ctx, a.to);
        if (!(await approve(ctx, t, `Chuyển tiếp tin từ ${from.name} sang ${t.name}`, `${oneLine(p.message, 600)}${a.comment ? `\n\nKèm lời nhắn: ${a.comment}` : ""}`))) return "Người giao việc không duyệt, chưa chuyển tiếp.";
        const ids = await copyFiles(p.metadata?.files ?? [], t.id);
        const who = await mm.displayName(p.user_id);
        const msg = [a.comment ? String(a.comment) : "", `↪️ Chuyển tiếp từ ${who} · ${from.name}:\n${p.message ?? ""}`].filter(Boolean).join("\n\n");
        const r = await postTo(ctx, t, { message: msg, file_ids: ids, props: { flygo_forwarded: true } });
        step(ctx, "fwd", `Đã chuyển tiếp tin sang ${t.name}`, `Chuyển tiếp sang ${t.name}`, true, p.message);
        return `Đã chuyển tiếp sang "${t.name}" (tin #${r.id}): ${link(r.id)}`;
      }
      case "chat_schedule_message": {
        const t = await chatOnly(ctx, a.to);
        const at = parseWhen(a.at, 1);
        if (!at || at < Date.now() + 30_000) return "Thời điểm gửi không hợp lệ hoặc đã qua (vd. 2026-11-02T08:00 theo giờ Việt Nam, hoặc \"2h\").";
        const message = String(a.message ?? "");
        if (!message.trim()) return "Thiếu nội dung.";
        let root = "";
        if (a.thread_root) { const { p } = await postOf(ctx, a.thread_root); if (p.channel_id !== t.id) return `Tin ${a.thread_root} không thuộc "${t.name}".`; root = p.root_id || p.id; }
        if (!(await approve(ctx, t, `Hẹn gửi tin vào ${t.name} lúc ${fmtTime(at)}`, message))) return "Người giao việc không duyệt, chưa hẹn.";
        const sp = await mm.api<any>("POST", "/posts/schedule", { channel_id: t.id, root_id: root, message, scheduled_at: at, props: { flygo_agent_owner: ctx.assigner, ...(root ? { flygo_reply: "thread" } : {}) } });
        step(ctx, "sched", `Đã hẹn gửi vào ${t.name} lúc ${fmtTime(at)}`, `Hẹn giờ gửi tin`, true, message);
        return `Đã hẹn gửi vào "${t.name}" lúc ${fmtTime(at)} (lịch ${sp?.id ?? "?"}; máy chủ tự gửi, xem / huỷ trong mục tin hẹn giờ của app).`;
      }
      case "chat_poll": {
        const t = await chatOnly(ctx, a.to);
        const question = String(a.question ?? "").replace(/\s+/g, " ").trim();
        const seen = new Set<string>();
        const options = (Array.isArray(a.options) ? a.options : []).map((x: any) => String(x ?? "").replace(/\s+/g, " ").trim()).filter((x: string) => x && !seen.has(x.toLowerCase()) && seen.add(x.toLowerCase())).slice(0, 20);
        if (!question || options.length < 2) return "Cần câu hỏi và ít nhất 2 phương án khác nhau.";
        const ends = a.ends_at ? parseWhen(a.ends_at, 1) ?? 0 : a.duration_min ? Date.now() + Number(a.duration_min) * 60_000 : 0;
        let root = "";
        if (a.thread_root) { const { p } = await postOf(ctx, a.thread_root); if (p.channel_id !== t.id) return `Tin ${a.thread_root} không thuộc "${t.name}".`; root = p.root_id || p.id; }
        if (!(await approve(ctx, t, `Tạo bình chọn ở ${t.name}`, `${question}\n${options.map((o: string) => `- ${o}`).join("\n")}${ends ? `\nHết hạn: ${fmtTime(ends)}` : ""}`))) return "Người giao việc không duyệt, chưa tạo bình chọn.";
        // Định dạng như app (lib/ui/poll.dart): người tạo = người giao việc (khoá được bình chọn trên app).
        const poll = { v: 1, question, options: options.map((text: string) => ({ id: rid(), text })), multi: !!a.multi, revote: a.revote !== false, allow_add: !!a.allow_add, ends_at: ends, closed: false, votes: {}, created_by: ctx.assigner };
        const p = await postTo(ctx, t, { message: `📊 Bình chọn: ${question}`, root_id: root, props: { flygo_poll: poll } });
        if (a.pin) await mm.api("POST", `/posts/${p.id}/pin`).catch(() => {});
        step(ctx, "poll", `Đã tạo bình chọn ở ${t.name}: ${question}`, "Tạo bình chọn", true, options.join(" / "));
        return `Đã tạo bình chọn ở "${t.name}" (tin #${p.id}): ${link(p.id)}. Xem kết quả bằng chat_get_message(post_id).`;
      }
      case "chat_send_card": {
        const t = await chatOnly(ctx, a.to);
        const text = String(a.text ?? "").trim();
        const buttons = (Array.isArray(a.buttons) ? a.buttons : []).map((b: any) => typeof b === "string" ? { label: b } : { label: String(b?.label ?? ""), ...(b?.description ? { description: String(b.description) } : {}) }).filter((b: any) => b.label.trim()).slice(0, NUM_EMOJI.length);
        if (!text || buttons.length < 1) return "Cần text và ít nhất 1 nút (tối đa 9).";
        let root = "";
        if (a.thread_root) { const { p } = await postOf(ctx, a.thread_root); if (p.channel_id !== t.id) return `Tin ${a.thread_root} không thuộc "${t.name}".`; root = p.root_id || p.id; }
        if (!(await approve(ctx, t, `Gửi thẻ có nút vào ${t.name}`, `${text}\n${buttons.map((b: any, i: number) => `${i + 1}. ${b.label}`).join("\n")}`))) return "Người giao việc không duyệt, chưa gửi thẻ.";
        const meta = { id: crypto.randomUUID(), question: text, header: String(a.header ?? "").slice(0, 12), options: buttons, multi: !!a.multi, allow_other: false, kind: "card" };
        const list = buttons.map((b: any, i: number) => `${i + 1}. **${b.label}**${b.description ? ` — ${b.description}` : ""}`).join("\n");
        const p = await postTo(ctx, t, { message: `${text}\n${list}`, root_id: root, props: { flygo_agent_question: { ...meta, status: "pending" }, flygo_agent_card: true } });
        const rec: CardRec = { post_id: p.id, channel_id: t.id, text, options: buttons, multi: !!a.multi, origin: { channel_id: ctx.channelId, root_id: ctx.threadRoot, assigner: ctx.assigner }, meta };
        db.query("INSERT OR REPLACE INTO chat_cards VALUES (?, ?, ?)").run(p.id, JSON.stringify(rec), Date.now());
        step(ctx, "card", `Đã gửi thẻ có nút vào ${t.name}`, `Gửi thẻ có nút`, true, text);
        return `Đã gửi thẻ vào "${t.name}" (tin #${p.id}): ${link(p.id)}. Khi có người bấm, bạn được gọi lại ở đây trong một lượt mới kèm lựa chọn; lượt này không cần chờ.`;
      }

      // ======== thao tác trên tin ========
      case "chat_react": case "chat_unreact": {
        const { p, t } = await postOf(ctx, a.post_id);
        const emoji = String(a.emoji ?? "").trim().replace(/^:|:$/g, "");
        if (!/^[a-z0-9_+-]{1,64}$/i.test(emoji)) return "emoji là tên cảm xúc như +1, white_check_mark, heart, eyes (không phải ký tự emoji).";
        if (op === "chat_react") await mm.react(p.id, d.botId, emoji);
        else await mm.api("DELETE", `/users/${d.botId}/posts/${p.id}/reactions/${encodeURIComponent(emoji)}`);
        step(ctx, "react", `${op === "chat_react" ? "Thả" : "Gỡ"} :${emoji}: trên tin ở ${t.name}`, op === "chat_react" ? "Thả cảm xúc" : "Gỡ cảm xúc");
        return `Đã ${op === "chat_react" ? "thả" : "gỡ"} :${emoji}: trên tin #${p.id}.`;
      }
      case "chat_pin": case "chat_unpin": {
        const { p, t } = await postOf(ctx, a.post_id);
        const pin = op === "chat_pin";
        if (!(await approve(ctx, null, `${pin ? "Ghim" : "Bỏ ghim"} tin ở ${t.name}`, oneLine(p.message, 600), true))) return "Người giao việc không duyệt.";
        await mm.api("POST", `/posts/${p.id}/${pin ? "pin" : "unpin"}`);
        step(ctx, "pin", `Đã ${pin ? "ghim" : "bỏ ghim"} tin ở ${t.name}`, pin ? "Ghim tin" : "Bỏ ghim tin", true, p.message);
        return `Đã ${pin ? "ghim" : "bỏ ghim"} tin #${p.id} ở "${t.name}".`;
      }
      case "chat_ack": {
        const { p, t } = await postOf(ctx, a.post_id);
        if (!p.metadata?.priority?.requested_ack) return "Tin này không yêu cầu xác nhận đã đọc.";
        await mm.api("POST", `/users/${d.botId}/posts/${p.id}/ack`);
        step(ctx, "ack", `Đã xác nhận đã đọc tin ở ${t.name}`, "Xác nhận đã đọc");
        return `Đã xác nhận đã đọc tin #${p.id}.`;
      }
      case "chat_mark_read": {
        const t = await chatOnly(ctx, a.chat);
        await mm.api("POST", `/channels/members/${d.botId}/view`, { channel_id: t.id });
        chansC = null;
        return `Đã đánh dấu đã đọc "${t.name}" (với bot).`;
      }
      case "chat_remind_me": {
        const { p, t } = await postOf(ctx, a.post_id);
        const at = parseWhen(a.at, 1);
        if (!at || at < Date.now() + 30_000) return "Thời điểm nhắc không hợp lệ hoặc đã qua (vd. \"2h\", \"1d\", 2026-11-02T08:00).";
        const forOwner = a.for === "owner";
        if (forOwner) {
          if (!d.isOwner(ctx.assigner)) return "Chỉ chủ bot mới đặt nhắc cho chủ bot được.";
          // Nhắc gốc của máy chủ chỉ đặt được cho chính tài khoản đang gọi: thử, không được thì hẹn một tin riêng (tin hẹn giờ của máy chủ).
          const native = await mm.api("POST", `/users/${ctx.assigner}/posts/${p.id}/reminder`, { target_time: Math.floor(at / 1000) }).then(() => true, () => false);
          if (!native) {
            const dm = await mm.api<any>("POST", "/channels/direct", [d.botId, ctx.assigner]);
            await mm.api("POST", "/posts/schedule", { channel_id: dm.id, root_id: "", message: `⏰ Nhắc Sếp: tin của ${await mm.displayName(p.user_id)} ở "${t.name}"${a.note ? ` — ${a.note}` : ""}\n${link(p.id)}`, scheduled_at: at, props: { flygo_agent_owner: ctx.assigner, flygo_reminder_of: p.id } });
          }
          step(ctx, "remind", `Đã đặt nhắc chủ bot lúc ${fmtTime(at)}`, "Đặt nhắc hẹn", true, p.message);
          return `Đã đặt nhắc ${native ? "(nhắc của máy chủ)" : "(tin nhắn riêng hẹn giờ từ bot)"} cho chủ bot lúc ${fmtTime(at)} về tin #${p.id}.`;
        }
        // Không đặt nhắc gốc của máy chủ cho tài khoản bot (tin nhắc của bot hệ thống sẽ rơi vào DM của bot): runner tự nhắc.
        const id = crypto.randomUUID();
        db.query("INSERT OR REPLACE INTO chat_reminders VALUES (?, ?, ?)").run(id, at, JSON.stringify({ post_id: p.id, where: t.name, preview: p.message ?? "", note: String(a.note ?? ""), origin: { channel_id: ctx.channelId, root_id: ctx.threadRoot, assigner: ctx.assigner } }));
        step(ctx, "remind", `Đã đặt nhắc bot lúc ${fmtTime(at)}`, "Đặt nhắc hẹn", true, p.message);
        return `Đã đặt nhắc lúc ${fmtTime(at)}: tới giờ bạn được gọi lại ở đây (lượt mới) để xử lý tin #${p.id}.`;
      }

      // ======== quản lý cuộc trò chuyện ========
      case "chat_create": {
        const name = String(a.name ?? "").replace(/\s+/g, " ").trim().slice(0, 64);
        if ([...name].length < 2) return "Tên chat trống hoặc quá ngắn.";
        const here = await mm.channel(ctx.channelId).catch(() => null);
        const team = (a.team_id && (await teams()).some((x) => x.id === a.team_id) ? a.team_id : here?.team_id) || (await teams())[0]?.id;
        if (!team) return "Không xác định được team.";
        const users = [] as any[];
        for (const m of Array.isArray(a.members) ? a.members.slice(0, 50) : []) users.push(await userOf(String(m)));
        const priv = a.private !== false;
        if (!(await approve(ctx, null, `Tạo ${priv ? "nhóm riêng" : "kênh công khai"} "${name}"`, `Thành viên: ${[await mm.displayName(ctx.assigner), ...users.map(nameOf)].join(", ")}${a.purpose ? `\nMô tả: ${a.purpose}` : ""}`, true))) return "Người giao việc không duyệt, chưa tạo.";
        const slug = (fold(name).replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 50) || "chat") + `-${rand32(4)}`;
        const c = await mm.api<any>("POST", "/channels", { team_id: team, name: slug, display_name: name, type: priv ? "P" : "O", ...(a.purpose ? { purpose: String(a.purpose).slice(0, 250) } : {}) });
        const failed: string[] = [];
        for (const id of [...new Set([ctx.assigner, ...users.map((u) => u.id)])]) {
          if (id === d.botId) continue;
          await mm.api("POST", `/channels/${c.id}/members`, { user_id: id }).catch(() => failed.push(id));
        }
        await mm.api("PUT", `/channels/${c.id}/members/${ctx.assigner}/schemeRoles`, { scheme_admin: true, scheme_user: true }).catch(() => {});
        chansC = null;
        step(ctx, "create", `Đã tạo ${priv ? "nhóm riêng" : "kênh"} "${name}"`, "Tạo cuộc trò chuyện", true, `${users.length + 1} thành viên`);
        return `Đã tạo "${name}" (id ${c.id})${failed.length ? `; chưa thêm được: ${(await Promise.all(failed.map((x) => mm.displayName(x)))).join(", ")}` : ""}. Người giao việc là quản trị chat.`;
      }
      case "chat_add_members": case "chat_remove_member": {
        const t = await chatOnly(ctx, a.chat);
        const add = op === "chat_add_members";
        if (t.ch.type === "D" || t.ch.type === "G") return "Chat 1-1 / nhóm nhắn tin không đổi thành viên được.";
        if (aiOf(t.ch) || projectOwnerOf(t.ch) !== null) return "Phiên AI / dự án không thêm bớt người bằng tool này.";
        if (!add && !d.isOwner(ctx.assigner)) return "Chỉ chủ bot mới bớt người khỏi chat được.";
        const users = [] as any[];
        for (const m of add ? (Array.isArray(a.users) ? a.users.slice(0, 50) : []) : [a.user]) users.push(await userOf(String(m ?? "")));
        if (!users.length) return "Thiếu người.";
        if (!add && users[0].id === d.botId) return "Không tự rời chat bằng tool này.";
        if (!(await approve(ctx, null, `${add ? "Thêm" : "Bớt"} ${users.map(nameOf).join(", ")} ${add ? "vào" : "khỏi"} ${t.name}`, "", true))) return "Người giao việc không duyệt.";
        const done: string[] = [], failed: string[] = [];
        for (const u of users) {
          const ok = add ? await mm.api("POST", `/channels/${t.id}/members`, { user_id: u.id }).then(() => true, () => false)
            : await mm.api("DELETE", `/channels/${t.id}/members/${u.id}`).then(() => true, () => false);
          (ok ? done : failed).push(nameOf(u));
        }
        forgetMembers(t.id);
        step(ctx, "members", `${add ? "Thêm" : "Bớt"} ${done.join(", ") || "(không ai)"} ${add ? "vào" : "khỏi"} ${t.name}`, add ? "Thêm thành viên" : "Bớt thành viên", !failed.length);
        return `${done.length ? `Đã ${add ? "thêm" : "bớt"}: ${done.join(", ")}.` : ""}${failed.length ? ` Không ${add ? "thêm" : "bớt"} được: ${failed.join(", ")} (thiếu quyền hoặc không ở team).` : ""}`.trim();
      }
      case "chat_rename": case "chat_set_purpose": {
        const t = await chatOnly(ctx, a.chat);
        if (t.ch.type === "D") return "Chat 1-1 không đổi tên / mô tả được.";
        if (op === "chat_rename") {
          if (aiOf(t.ch)) return "Đây là phiên AI: dùng session_rename.";
          const name = String(a.name ?? "").replace(/\s+/g, " ").trim().slice(0, 64);
          if ([...name].length < 2) return "Tên trống hoặc quá ngắn.";
          if (!(await approve(ctx, null, `Đổi tên "${t.name}" → "${name}"`, "", true))) return "Người giao việc không duyệt.";
          await mm.api("PUT", `/channels/${t.id}/patch`, { display_name: name });
          mm.forgetChannel(t.id); chansC = null;
          step(ctx, "rename", `Đổi tên chat: "${t.name}" → "${name}"`, "Đổi tên chat");
          return `Đã đổi tên thành "${name}".`;
        }
        // Giữ các mốc kỹ thuật [flygo-…] của app trong mô tả.
        const marks = (String(t.ch.purpose ?? "").match(/\[flygo-[^\]]*\]/g) ?? []).join(" ");
        const text = String(a.purpose ?? "").replace(/\[flygo-[^\]]*\]/g, "").trim();
        const purpose = [text, marks].filter(Boolean).join(" ").slice(0, 250);
        if (!(await approve(ctx, null, `Đổi mô tả của "${t.name}"`, text || "(xoá mô tả)", true))) return "Người giao việc không duyệt.";
        await mm.api("PUT", `/channels/${t.id}/patch`, { purpose });
        mm.forgetChannel(t.id);
        step(ctx, "purpose", `Đổi mô tả của "${t.name}"`, "Đổi mô tả chat", true, text);
        return `Đã đổi mô tả của "${t.name}".`;
      }
      case "thread_create_private": {
        const { p, t } = await postOf(ctx, a.post_id);
        if (aiOf(t.ch) || projectOwnerOf(t.ch) !== null) return "Không tách luồng bí mật từ phiên AI / dự án.";
        const users = [] as any[];
        for (const m of Array.isArray(a.members) ? a.members.slice(0, 30) : []) users.push(await userOf(String(m)));
        const outside: string[] = [];
        for (const u of users) if (!(await isMember(t.id, u.id))) outside.push(nameOf(u));
        if (outside.length) return `Luồng bí mật chỉ gồm người trong "${t.name}"; không ở đó: ${outside.join(", ")}.`;
        const plain = String(p.message ?? "").replace(/\s+/g, " ").trim();
        const name = String(a.name ?? "").trim() || (plain ? (plain.length > 40 ? `${plain.slice(0, 40)}…` : plain) : "Luồng riêng");
        if (!(await approve(ctx, null, `Tạo luồng bí mật "${name}" từ tin ở ${t.name}`, `Thành viên: ${[await mm.displayName(ctx.assigner), ...users.map(nameOf)].join(", ")}\n> ${oneLine(p.message, 300)}`, true))) return "Người giao việc không duyệt, chưa tạo luồng.";
        // Như app (createSubChannel): kênh P tên s-<kênh cha>-<tin gốc>-<4 ký tự>, mô tả trống, tin gốc chép vào làm tin đầu.
        const team = t.ch.team_id || (await mm.channel(ctx.channelId).catch(() => null))?.team_id || (await teams())[0]?.id;
        const c = await mm.api<any>("POST", "/channels", { team_id: team, name: `s-${t.id}-${p.id}-${rand32(4)}`, display_name: [...name].slice(0, 64).join(""), type: "P" });
        for (const id of [...new Set([ctx.assigner, ...users.map((u) => u.id)])]) if (id !== d.botId) await mm.api("POST", `/channels/${c.id}/members`, { user_id: id }).catch(() => {});
        await mm.api("PUT", `/channels/${c.id}/members/${ctx.assigner}/schemeRoles`, { scheme_admin: true, scheme_user: true }).catch(() => {});
        // Danh mục "Luồng riêng" trên thanh bên (bản web): chỉ chính người dùng sửa được -> thử, không được thì thôi.
        await fileIntoCategory(ctx.assigner, team, c.id, "Luồng riêng").catch(() => {});
        const ids = await copyFiles(p.metadata?.files ?? [], c.id);
        const first = await mm.createPost({ channel_id: c.id, message: `📌 Từ ${t.name} · ${await mm.displayName(p.user_id)}:\n${p.message ?? ""}`, file_ids: ids, props: { flygo_sub_origin: { channel_id: t.id, post_id: p.id }, flygo_agent_owner: ctx.assigner } });
        chansC = null;
        step(ctx, "sub", `Đã tạo luồng bí mật "${name}"`, "Tạo luồng bí mật", true, `${users.length + 1} người`);
        return `Đã tạo luồng bí mật "${name}" (kênh ${c.id}) từ tin #${p.id}: ${link(first.id)}. Nhắn trong luồng đó bằng chat_send(to="${c.id}").`;
      }
      case "thread_close": case "thread_reopen": {
        const closed = op === "thread_close";
        const label = closed ? "🔒 Đã đóng luồng" : "🔓 Đã mở lại luồng";
        const props = { flygo_thread_closed: closed, flygo_silent: true, flygo_agent_owner: ctx.assigner };
        if (a.post_id) {
          const { p, t } = await postOf(ctx, a.post_id);
          const root = p.root_id || p.id;
          if (!(await approve(ctx, null, `${closed ? "Đóng" : "Mở lại"} luồng ở ${t.name}`, oneLine(p.message, 300), true))) return "Người giao việc không duyệt.";
          await mm.createPost({ channel_id: t.id, root_id: root, message: label, props: { ...props, flygo_reply: "thread" } });
          d.onCloseMark(t.id, root, closed);
          step(ctx, "close", `${closed ? "Đã đóng" : "Đã mở lại"} luồng #${root} ở ${t.name}`, closed ? "Đóng luồng" : "Mở lại luồng");
          return `${closed ? "Đã đóng" : "Đã mở lại"} luồng #${root}.${closed && root === ctx.threadRoot ? " Đây là luồng đang làm: lượt này vẫn làm xong, từ sau bot không nhận việc mới ở đây tới khi mở lại." : ""}`;
        }
        const t = await chatOnly(ctx, a.chat);
        if (!subOf(t.ch)) return "Cần post_id (luồng trong chat) hoặc chat là một luồng bí mật.";
        if (!(await approve(ctx, null, `${closed ? "Đóng" : "Mở lại"} luồng bí mật "${t.name}"`, "", true))) return "Người giao việc không duyệt.";
        const base = String(t.ch.purpose ?? "").replace("[flygo-closed]", "").trim();
        await mm.api("PUT", `/channels/${t.id}/patch`, { purpose: closed ? `${base} [flygo-closed]`.trim() : base });
        mm.forgetChannel(t.id);
        await mm.createPost({ channel_id: t.id, message: label, props });
        d.onCloseMark(t.id, "", closed);
        step(ctx, "close", `${closed ? "Đã đóng" : "Đã mở lại"} luồng bí mật "${t.name}"`, closed ? "Đóng luồng" : "Mở lại luồng");
        return `${closed ? "Đã đóng" : "Đã mở lại"} luồng bí mật "${t.name}".`;
      }
      case "user_set_status": {
        if (!d.isOwner(ctx.assigner)) return "Chỉ chủ bot mới đổi trạng thái của bot được.";
        const text = String(a.text ?? "").trim().slice(0, 100);
        if (!text) {
          db.query("DELETE FROM kv WHERE k = 'bot_status'").run();
          step(ctx, "status", "Bỏ trạng thái riêng của bot", "Đổi trạng thái bot");
          return "Đã bỏ trạng thái riêng; bot hiện lại trạng thái \"Đang chạy trên …\".";
        }
        const until = a.expires ? parseWhen(a.expires, 1) ?? 0 : 0;
        const emoji = String(a.emoji ?? "speech_balloon").replace(/^:|:$/g, "");
        db.query("INSERT OR REPLACE INTO kv VALUES ('bot_status', ?)").run(JSON.stringify({ text, emoji, until }));
        await refreshStatus();
        step(ctx, "status", `Trạng thái bot: ${text}`, "Đổi trạng thái bot");
        return `Đã đặt trạng thái của bot: :${emoji}: ${text}${until ? ` (tới ${fmtTime(until)})` : ""}.`;
      }
    }
    return `Không có tool ${op}.`;
  }
  async function fileIntoCategory(userId: string, team: string, channelId: string, name: string) {
    const base = `/users/${userId}/teams/${team}/channels/categories`;
    const r = await mm.api<any>("GET", base);
    const cat = (r.categories ?? []).find((c: any) => c.type === "custom" && c.display_name === name);
    if (!cat) await mm.api("POST", base, { user_id: userId, team_id: team, type: "custom", display_name: name, collapsed: true, channel_ids: [channelId] });
    else if (!(cat.channel_ids ?? []).includes(channelId)) await mm.api("PUT", `${base}/${cat.id}`, { ...cat, channel_ids: [channelId, ...(cat.channel_ids ?? [])] });
  }
  let refreshStatus: () => Promise<void> = async () => {};
  return {
    tool,
    onCardReaction,
    onCardAnswer,
    statusOverride,
    /** Runner gắn hàm làm mới trạng thái của bot (presence). */
    setStatusRefresher(f: () => Promise<void>) { refreshStatus = f; },
  };
}

/** Tool chat do runner xử lý (POST /chat_op/<tool>). */
export const CHAT_OP_TOOLS = new Set([
  "chat_list", "chat_unread", "chat_get_message", "chat_members", "chat_find_user", "user_info", "chat_pinned", "chat_digest",
  "chat_send", "chat_reply", "chat_forward", "chat_schedule_message", "chat_poll", "chat_send_card",
  "chat_react", "chat_unreact", "chat_pin", "chat_unpin", "chat_ack", "chat_mark_read", "chat_remind_me",
  "chat_create", "chat_add_members", "chat_remove_member", "chat_rename", "chat_set_purpose",
  "thread_create_private", "thread_close", "thread_reopen", "user_set_status",
]);
/** Tool runner tự ghi bước lên thẻ (ẩn bước MCP của engine để không trùng). */
export const CHAT_OP_SELF_STEP = new Set([
  "chat_send", "chat_reply", "chat_forward", "chat_schedule_message", "chat_poll", "chat_send_card",
  "chat_react", "chat_unreact", "chat_pin", "chat_unpin", "chat_ack", "chat_remind_me",
  "chat_create", "chat_add_members", "chat_remove_member", "chat_rename", "chat_set_purpose",
  "thread_create_private", "thread_close", "thread_reopen", "user_set_status",
]);
