// flygo-agent runner: chạy trên máy cá nhân, nối bot Mattermost với Codex/Claude.
// - Chủ bot @tag bot (hoặc nhắn DM, hoặc trả lời trong chủ đề đã có phiên) -> agent làm việc trong chủ đề đó.
// - Tin ở chat chính -> trả lời ngay ở chat chính, MỘT post stream (thẻ + chữ), không tự tạo luồng; phiên theo kênh.
// - Tin trong luồng -> trả lời trong luồng: thẻ tiến trình (props.flygo_agent) + tin stream (props.flygo_agent_message).
// - Duyệt quyền: post "Cần Sếp duyệt" trong chủ đề, chủ bot bấm Xác nhận / Từ chối (reaction +1 / -1).
// - Chế độ --json: in sự kiện JSON từng dòng ra stdout cho app Flygo Chat (log ra stderr).
import { Database } from "bun:sqlite";
import { copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";
import defaultPersona from "../profiles/default/persona.md" with { type: "text" };
import { RunCard } from "./card";
import { agentOptions, CONFIG_DIR, type Config, type EngineName } from "./config";
import { doctor } from "./doctor";
import { ClaudeEngine } from "./engines/claude";
import { CodexEngine } from "./engines/codex";
import type { ApprovalDecision, ApprovalRequest, Engine } from "./engines/types";
import { InlineReply, MessageStream } from "./messages";
import { MM, type Post } from "./mm";

export interface RunnerIO {
  emit(ev: Record<string, any>): void; // sự kiện cho app
  log(s: string): void;
  selfCommand: string[]; // lệnh gọi lại chính chương trình này (để chạy subcommand mcp-chat)
  takeover?: boolean; // runner khác đang giữ bot thì dừng nó (kể cả dịch vụ nền) để chạy thay
}

export async function startRunner(cfg: Config, io: RunnerIO) {
const { emit } = io;
const log = io.log;
const mm = new MM(cfg.serverUrl, cfg.botToken);
const me = await mm.me().catch((e) => { emit({ event: "error", code: "auth", message: String(e.message ?? e) }); throw e; });
const BOT_ID: string = me.id;
const BOT_NAME: string = me.username;
log(`bot @${BOT_NAME} (${BOT_ID}), chủ: ${cfg.ownerUserIds.join(", ")}`);

// ---- phân quyền gọi bot: chủ (config) ∪ allow trong mô tả bot "[flygo-agent … allow=id1,id2]" ----
let allowIds: string[] = [];
let botDesc: string = me.bot_description ?? ""; // mốc "[flygo-agent engine=… allow=… models=… efforts=… default=…]"
const parseAllow = (desc: string) => /\[flygo-agent[^\]]*\ballow=([a-z0-9,]+)/i.exec(desc ?? "")?.[1].split(",").filter(Boolean) ?? [];
async function refreshAllow() {
  const u = await mm.me().catch(() => null);
  if (!u) return;
  botDesc = u.bot_description ?? "";
  const next = parseAllow(u.bot_description);
  if (next.join(",") !== allowIds.join(",")) log(`người được gọi bot: ${[...cfg.ownerUserIds, ...next].join(", ")}`);
  allowIds = next;
}
const isOwner = (id: string) => cfg.ownerUserIds.includes(id);
const isAllowed = (id: string) => isOwner(id) || allowIds.includes(id);
allowIds = parseAllow(me.bot_description);
setInterval(refreshAllow, 60_000);

// ---- mỗi bot chỉ một runner ----
mkdirSync(CONFIG_DIR, { recursive: true });
const lockPath = join(CONFIG_DIR, `runner-${BOT_ID}.lock`);
if (existsSync(lockPath)) {
  const pid = Number(readFileSync(lockPath, "utf8"));
  let alive = false;
  try { if (pid && pid !== process.pid) { process.kill(pid, 0); alive = true; } } catch {}
  if (alive && io.takeover) {
    const { stopServiceForTakeover } = await import("./service");
    if (stopServiceForTakeover(pid)) log("đã dừng dịch vụ nền để tiếp quản");
    try { process.kill(pid, "SIGTERM"); } catch {}
    for (let i = 0; i < 50; i++) { try { process.kill(pid, 0); await Bun.sleep(200); } catch { alive = false; break; } }
    if (alive) try { process.kill(pid, "SIGKILL"); alive = false; } catch {}
    emit({ event: "took_over", pid });
  }
  if (alive) { emit({ event: "error", code: "already_running", pid, message: `Bot @${BOT_NAME} đang được runner khác chạy (pid ${pid}).` }); process.exit(3); }
}
writeFileSync(lockPath, String(process.pid));

// ---- engine có sẵn trên máy ----
const report = await doctor({ codex: cfg.codex.bin, claude: cfg.claude.bin, codexSkipLogin: cfg.codex.skipLoginCheck });
const available = (["codex", "claude"] as EngineName[]).filter((e) => report[e].installed && report[e].loggedIn);
if (!available.includes(cfg.engine)) {
  emit({ event: "error", code: "no_engine", engine: cfg.engine, message: `Bot @${BOT_NAME} dùng ${cfg.engine} nhưng máy chưa cài hoặc chưa đăng nhập ${cfg.engine}.`, doctor: report });
  process.exit(4);
}
const ENGINE: EngineName = cfg.engine; // bot gắn cố định một engine, không đổi theo tin nhắn

// ---- trạng thái phiên ----
const dbPath = join(CONFIG_DIR, `state-${BOT_ID}.db`);
if (!existsSync(dbPath) && existsSync(join(CONFIG_DIR, "state.db")) && BOT_NAME === "sep-ai") copyFileSync(join(CONFIG_DIR, "state.db"), dbPath);
const db = new Database(dbPath);
db.run(`CREATE TABLE IF NOT EXISTS sessions (
  root_id TEXT PRIMARY KEY, channel_id TEXT, engine TEXT, session_id TEXT, status TEXT,
  title TEXT, card_post_id TEXT, last_seen_at INTEGER, updated_at INTEGER)`);
interface Session { root_id: string; channel_id: string; engine: EngineName; session_id: string; status: string; title: string; card_post_id: string; last_seen_at: number; updated_at: number }
const getSession = (root: string) => db.query("SELECT * FROM sessions WHERE root_id = ?").get(root) as Session | null;
const saveSession = (s: Session) =>
  db.query(`INSERT OR REPLACE INTO sessions VALUES ($root_id,$channel_id,$engine,$session_id,$status,$title,$card_post_id,$last_seen_at,$updated_at)`)
    .run(Object.fromEntries(Object.entries(s).map(([k, v]) => [`$${k}`, v])) as any);

// ---- engine ----
const mcpCommand = { command: io.selfCommand[0], args: [...io.selfCommand.slice(1), "mcp-chat"] };
const engines: Record<EngineName, Engine> = {
  codex: new CodexEngine(cfg, mcpCommand, log),
  claude: new ClaudeEngine(cfg, mcpCommand, log),
};

// ---- duyệt quyền ----
const pendingApprovals = new Map<string, { resolve: (d: ApprovalDecision) => void; assigner: string }>(); // post_id -> chờ duyệt
const runsByKey = new Map<string, (req: ApprovalRequest) => Promise<ApprovalDecision>>();

/** Chờ người giao việc (hoặc chủ bot) thả 👍/👎 lên post `postId`. */
async function waitDecision(postId: string, ownerId: string, signal?: AbortSignal): Promise<ApprovalDecision | "expired"> {
  await mm.react(postId, BOT_ID, "+1").catch(() => {});
  await mm.react(postId, BOT_ID, "-1").catch(() => {});
  const decision = await new Promise<ApprovalDecision | "expired">((resolve) => {
    pendingApprovals.set(postId, { resolve, assigner: ownerId });
    setTimeout(() => resolve("expired"), cfg.approvalTimeoutSec * 1000);
    signal?.addEventListener("abort", () => resolve("decline")); // lượt bị dừng thì thôi chờ
  });
  pendingApprovals.delete(postId);
  return decision;
}
const approvalStatus = (d: ApprovalDecision | "expired") => (d === "accept" ? "accepted" : d === "decline" ? "declined" : "expired");

/** Chat chính: lời xin duyệt nằm ngay trong post trả lời (props.flygo_agent_approval), 👍/👎 thả lên chính post đó. */
async function askApprovalInline(reply: InlineReply, req: ApprovalRequest, ownerId: string, signal?: AbortSignal): Promise<ApprovalDecision> {
  const base = { kind: req.kind, title: req.title, detail: req.detail };
  const postId = await reply.ensurePost();
  await reply.setApproval({ ...base, status: "pending" });
  const decision = postId ? await waitDecision(postId, ownerId, signal) : "expired";
  await reply.setApproval({ ...base, status: approvalStatus(decision) });
  for (const e of ["+1", "-1"]) await mm.api("DELETE", `/users/${BOT_ID}/posts/${postId}/reactions/${e}`).catch(() => {});
  await reply.setApproval(null); // đã ghi vào bước của thẻ
  return decision === "accept" ? "accept" : "decline";
}

async function askApproval(where: { channel_id: string; root_id: string }, engine: string, req: ApprovalRequest, ownerId: string, signal?: AbortSignal): Promise<ApprovalDecision> {
  const body = (status: string) =>
    `✋ **Cần Sếp duyệt** · ${engine}\n\`\`\`\n${req.title}\n\`\`\`${req.detail ? `\n${req.detail}` : ""}\n${status}`;
  const props = (status: string) => ({ ...(where.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: ownerId, flygo_agent_approval: { kind: req.kind, title: req.title, detail: req.detail, status } });
  const post = await mm.createPost({ ...where, message: body("Thả 👍/👎 để Xác nhận / Từ chối."), props: props("pending") });
  const decision = await waitDecision(post.id, ownerId, signal);
  // Đã quyết thì xoá post duyệt (kết quả đã ghi vào bước của thẻ) cho luồng gọn.
  await mm.patchPost(post.id, { props: props(approvalStatus(decision)) }).catch(() => {});
  await mm.deletePost(post.id).catch(() => {});
  return decision === "accept" ? "accept" : "decline";
}

// HTTP nội bộ: MCP server của Claude gọi /approve
const http = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/approve" && req.method === "POST") {
      const { key, tool_name, input } = await req.json();
      const ask = runsByKey.get(key);
      if (!ask) return Response.json({ allow: false, message: "phiên không còn chạy" });
      const title = tool_name === "Bash" ? `$ ${input?.command ?? ""}` : `${tool_name} ${JSON.stringify(input).slice(0, 300)}`;
      const kind = tool_name === "Bash" ? "command" : /Edit|Write/.test(tool_name) ? "file" : "tool";
      const d = await ask({ kind, title, detail: input?.description });
      return Response.json({ allow: d === "accept", message: d === "accept" ? "" : "Sếp không cho phép thao tác này." });
    }
    if (url.pathname === "/health") return new Response("ok");
    return new Response("not found", { status: 404 });
  },
});

// ---- dựng ngữ cảnh & thư mục làm việc ----
const persona = cfg.persona?.trim() ? cfg.persona : defaultPersona;

async function workspaceFor(channelId: string) {
  const ch = await mm.channel(channelId);
  const name = (ch.type === "D" ? `dm-${channelId}` : ch.name || channelId).replace(/[^a-zA-Z0-9._-]/g, "_");
  const dir = join(cfg.workspaceRoot, name);
  mkdirSync(dir, { recursive: true });
  const skills = cfg.skillsDir;
  if (skills && existsSync(skills) && readdirSync(skills).length) {
    for (const target of [join(dir, ".claude", "skills"), join(dir, ".agents", "skills")]) cpSync(skills, target, { recursive: true });
  }
  for (const f of ["AGENTS.md", "CLAUDE.md"]) await Bun.write(join(dir, f), persona);
  return { dir, ch };
}

function filesNote(p: Post) {
  const fl = (p as any).metadata?.files as any[] | undefined;
  return fl?.length ? ` [tệp đính kèm: ${fl.map((f) => `${f.name} (file_id=${f.id})`).join("; ")}]` : "";
}

async function fmtPosts(posts: Post[]) {
  const out: string[] = [];
  for (const p of posts) {
    if (p.type?.startsWith("system_") || !p.message?.trim()) continue;
    if (isTrue(p.props?.flygo_private_thread)) continue; // việc đã chuyển sang kênh luồng riêng, không thuộc cuộc trò chuyện này
    if (p.user_id === BOT_ID && p.props?.flygo_agent && !p.props?.flygo_agent_message) continue; // bỏ thẻ tiến trình (giữ câu trả lời ở chat chính)
    const t = new Date(p.create_at).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false });
    out.push(`[${t}] ${await mm.displayName(p.user_id)}: ${p.message}${filesNote(p)}`);
  }
  return out.join("\n");
}

const mentionRe = new RegExp(`@${BOT_NAME.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "gi");

// ---- xử lý tin ----
const queues = new Map<string, Promise<void>>();
const mainKey = (channelId: string) => `ch:${channelId}`; // phiên chat chính của kênh
const MAIN_IDLE_MS = 12 * 3600_000;
// root_id -> lượt đang chạy; posts(): các post của lượt (thẻ, tin stream) để nhận 🛑 dừng
const running = new Map<string, { ac: AbortController; assigner: string; channel_id: string; posts: () => string[] }>();

// ---- luồng đã đóng (app: tab "Luồng riêng", nút Đóng luồng) ----
// Luồng công việc: tin mới nhất trong thread mang props.flygo_thread_closed quyết định trạng thái.
// Kênh luồng riêng "[flygo-sub …]": đóng khi purpose có "[flygo-closed]". Luồng đã đóng thì bot không nhận việc mới.
const isTrue = (v: any) => v === true || v === "true";
const threadClosed = new Map<string, boolean>(); // root_id -> đã đóng
async function isThreadClosed(root: string) {
  if (!threadClosed.has(root)) {
    let closed = false;
    for (const p of await mm.thread(root)) if (p.props?.flygo_thread_closed !== undefined) closed = isTrue(p.props.flygo_thread_closed);
    threadClosed.set(root, closed);
  }
  return threadClosed.get(root)!;
}
const isChannelClosed = async (channelId: string) => /\[flygo-closed\]/.test((await mm.channel(channelId)).purpose ?? "");
async function isClosed(post: Post) {
  if (await isChannelClosed(post.channel_id)) return true;
  return !!post.root_id && (await isThreadClosed(post.root_id));
}
/** Tin mốc đóng/mở luồng do app đăng: cập nhật trạng thái, đóng thì dừng lượt đang chạy. Không bao giờ là tin giao việc. */
function onCloseMarker(post: Post) {
  const closed = isTrue(post.props!.flygo_thread_closed);
  if (post.root_id) {
    threadClosed.set(post.root_id, closed);
    if (closed) running.get(post.root_id)?.ac.abort();
  } else {
    mm.forgetChannel(post.channel_id); // purpose vừa đổi
    if (closed) for (const x of running.values()) if (x.channel_id === post.channel_id) x.ac.abort();
  }
  log(`${closed ? "đóng" : "mở lại"} ${post.root_id ? `luồng ${post.root_id}` : `kênh ${post.channel_id}`}`);
}

function enqueue(root: string, job: () => Promise<void>) {
  const next = (queues.get(root) ?? Promise.resolve()).then(job, job).catch((e) => log(`job error ${e}`));
  queues.set(root, next);
}

// ---- khi nào bot tự xử lý (không cần @tag) ----
// Quy tắc chung: ở đâu chỉ có đúng 1 người (người gửi) + đúng bot này thì mọi tin của người đó giao cho bot, không cần @tag;
// còn lại (từ 2 người hoặc từ 2 bot) phải @tag. Xét theo thành viên kênh (DM, nhóm, kênh luồng riêng "[flygo-sub …]"),
// rồi với tin trong thread thì xét người tham gia thread.
interface Participants { humans: Set<string>; bots: Set<string> }
const threadParts = new Map<string, Participants>(); // root_id -> người/bot tham gia (cập nhật dần theo WebSocket)
const memberCache = new Map<string, { at: number; humans: string[]; bots: string[] }>(); // channel_id -> thành viên (60s)
const usernameCache = new Map<string, any | null>();

async function userByName(name: string) {
  if (!usernameCache.has(name)) usernameCache.set(name, await mm.api("GET", `/users/username/${encodeURIComponent(name)}`).catch(() => null));
  return usernameCache.get(name);
}
async function addParticipant(p: Participants, post: Post) {
  const u = await mm.user(post.user_id);
  (u.is_bot ? p.bots : p.humans).add(post.user_id);
  for (const m of post.message.matchAll(/(?:^|[^\w@])@([a-zA-Z0-9_][a-zA-Z0-9_.-]*[a-zA-Z0-9_])/g)) {
    const t = await userByName(m[1]);
    if (t?.is_bot) p.bots.add(t.id); // bot được tag trong luồng cũng tính là tham gia
  }
}
/** Cập nhật cache người tham gia luồng từ mọi tin nhận qua WebSocket (kể cả tin của bot). */
async function trackPost(post: Post) {
  const p = threadParts.get(post.root_id || post.id);
  if (p) await addParticipant(p, post);
}
async function threadParticipants(root: string): Promise<Participants> {
  let p = threadParts.get(root);
  if (!p) {
    p = { humans: new Set(), bots: new Set() };
    for (const x of await mm.thread(root)) await addParticipant(p, x);
    threadParts.set(root, p);
  }
  return p;
}
async function channelMembers(channelId: string) {
  const c = memberCache.get(channelId);
  if (c && Date.now() - c.at < 60_000) return c;
  const ms = await mm.api<any[]>("GET", `/channels/${channelId}/members?per_page=200`);
  const humans: string[] = [], bots: string[] = [];
  for (const m of ms) ((await mm.user(m.user_id)).is_bot ? bots : humans).push(m.user_id);
  const v = { at: Date.now(), humans, bots };
  memberCache.set(channelId, v);
  return v;
}
const onlyMeAnd = (humans: Iterable<string>, bots: Iterable<string>, userId: string) => {
  const h = [...humans], b = [...bots];
  return h.length === 1 && h[0] === userId && b.length === 1 && b[0] === BOT_ID;
};

/** Tin này có giao cho bot mà không cần @tag không? */
async function implicitTrigger(post: Post, channelType: string): Promise<boolean> {
  if (channelType === "D") return true; // DM với bot: 1 người + bot
  const m = await channelMembers(post.channel_id);
  if (onlyMeAnd(m.humans, m.bots, post.user_id)) return true; // kênh/nhóm/luồng riêng chỉ có người này + bot
  if (!post.root_id) return false; // chat chính của kênh nhiều người/nhiều bot: phải @tag
  const p = await threadParticipants(post.root_id);
  return onlyMeAnd(p.humans, p.bots, post.user_id);
}

async function onPosted(post: Post, channelType: string) {
  if (post.type && post.type !== "") return;
  await trackPost(post).catch(() => {});
  if (post.user_id === BOT_ID) return;
  if (post.props?.flygo_thread_closed !== undefined) return onCloseMarker(post);
  // Tin "Bắt đầu công việc trong luồng riêng tư" ở chat chính: app tạo kênh luồng riêng và chép tin sang đó;
  // bot chỉ trả lời trong kênh luồng riêng, KHÔNG BAO GIỜ trả lời tin gốc này (kể cả có @tag hay quy tắc 1 người + 1 bot).
  if (post.props?.flygo_private_thread === true || post.props?.flygo_private_thread === "true") return;
  // Khoá phiên/hàng đợi: tin trong luồng -> root_id; tin ở chat chính -> cả kênh (bot trả lời ngay ở chat chính, không tạo luồng).
  const root = post.root_id || mainKey(post.channel_id);
  const allowed = isAllowed(post.user_id);
  const mentioned = mentionRe.test(post.message);
  mentionRe.lastIndex = 0;
  const text = post.message.replace(mentionRe, "").trim();

  // Chủ bot nhắn "dừng" trong luồng bot đang chạy thì dừng, không cần tag.
  const cur = running.get(root);
  if (cur && (post.user_id === cur.assigner || isOwner(post.user_id)) && /^(dừng|dung|stop|\/stop)$/i.test(text)) {
    cur.ac.abort();
    return;
  }
  if (!mentioned && !(allowed && (await implicitTrigger(post, channelType)))) return;
  if (await isClosed(post)) return; // luồng đã đóng: không nhận việc mới (mở lại thì nhận bình thường)

  if (!allowed) {
    const owners = await Promise.all(cfg.ownerUserIds.map((id) => mm.user(id).then((u) => `@${u.username}`)));
    await mm.createPost({ channel_id: post.channel_id, root_id: post.root_id, message: `Em là trợ lý riêng của ${owners.join(", ")}, em chỉ nhận việc từ những người được chủ của em cho phép ạ.`, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } });
    return; // tin của người khác chỉ là ngữ cảnh
  }
  enqueue(root, () => runTurn(post, root, text));
}

async function runTurn(post: Post, root: string, rawText: string) {
  if (await isClosed(post)) return; // đóng trong lúc đang xếp hàng
  const inline = !post.root_id; // trả lời ở chat chính
  let session = getSession(root);
  // Chat chính: nghỉ quá lâu thì mở phiên mới (tránh ngữ cảnh phình mãi).
  if (session && inline && Date.now() - session.updated_at > MAIN_IDLE_MS) session = null;
  const engineName: EngineName = ENGINE;
  let text = rawText;
  if (session && session.engine !== ENGINE) session = null; // phiên cũ của engine khác (trước khi gắn cố định): mở phiên mới
  if (!text) text = "(Sếp gọi em nhưng chưa nói việc gì — hãy hỏi lại Sếp cần gì.)";

  const { dir, ch } = await workspaceFor(post.channel_id);
  const owner = await mm.displayName(post.user_id);
  let prompt: string;
  if (!session) {
    const thread = post.root_id ? (await mm.thread(post.root_id)).filter((p) => p.id !== post.id) : [];
    const rootPost = thread[0];
    const before = (await mm.channelPosts(post.channel_id, 20, rootPost?.id ?? post.id)).filter((p) => !p.root_id && !p.props?.flygo_agent_message?.streaming);
    const chName = ch.type === "D" ? "tin nhắn riêng" : `nhóm "${ch.display_name}"`;
    prompt = [
      `Bạn đang được giao việc trong ${chName} trên Flygo Chat.`,
      before.length ? `\n## Tin nhắn gần đây trong nhóm (ngữ cảnh)\n${await fmtPosts(before)}` : "",
      thread.length ? `\n## Chủ đề đang trao đổi\n${await fmtPosts(thread)}` : "",
      `\n## Việc ${owner} giao\n${text}${filesNote(post)}`,
      `\n(Tool flygo_chat: chat_history / chat_thread / chat_search để đọc tin cũ; chat_info để xem nhóm và thành viên; chat_files / chat_read_file để đọc tệp đính kèm.)`,
    ].join("\n");
  } else {
    const recent = inline ? (await mm.channelPosts(post.channel_id, 50)).filter((p) => !p.root_id) : await mm.thread(root);
    // Chỉ các tin sau lượt trả lời gần nhất của bot (việc cũ đã qua thì không nhắc lại).
    const lastBot = Math.max(session.last_seen_at, ...recent.filter((p) => p.user_id === BOT_ID).map((p) => p.create_at));
    const since = recent.filter((p) => p.create_at > lastBot && p.create_at < post.create_at && p.id !== post.id && p.user_id !== BOT_ID);
    const sinceText = since.length ? await fmtPosts(since) : "";
    prompt = [sinceText ? `## Tin khác ${inline ? "trong nhóm" : "trong chủ đề"} từ lần trả lời trước (chỉ để tham khảo, không cần trả lời)\n${sinceText}\n` : "", `## ${owner} nhắn\n${text}${filesNote(post)}`].join("\n");
  }

  // Model / mức suy nghĩ người dùng chọn trên app: props.flygo_agent_config = { "<bot>": { model, effort } }. Thiếu = mặc định.
  const opts = agentOptions(cfg, botDesc);
  let want: any = post.props?.flygo_agent_config;
  if (typeof want === "string") try { want = JSON.parse(want); } catch { want = null; }
  want = want?.[BOT_NAME] ?? {};
  const bad: string[] = [];
  const model = want.model && !opts.models.includes(want.model) ? (bad.push(`model ${want.model}`), opts.default.model) : want.model || opts.default.model;
  const effort = want.effort && !opts.efforts.includes(want.effort) ? (bad.push(`mức ${want.effort}`), opts.default.effort) : want.effort || opts.default.effort;
  const runConfig = { model, effort, ...(bad.length ? { note: `Không hỗ trợ ${bad.join(", ")}, dùng mặc định.` } : {}) };

  const runId = crypto.randomUUID();
  const title = text.split("\n")[0].slice(0, 80);
  emit({ event: "run_started", run_id: runId, channel_id: post.channel_id, root_id: root, engine: engineName, title, config: runConfig });
  const ownerUser = await mm.user(post.user_id);
  const ownerRef = { id: post.user_id, username: ownerUser.username };
  const where = { channel_id: post.channel_id, root_id: post.root_id };
  // Chat chính: một post duy nhất (thẻ + chữ stream); trong luồng: thẻ riêng + tin stream như trước.
  const reply = inline ? new InlineReply(mm, post.channel_id, runId, engineName, ownerRef, ch.type !== "D") : null;
  const card = new RunCard(mm, where, runId, engineName, title, post.user_id, reply ? () => reply.touch() : undefined);
  if (reply) reply.card = card;
  card.config = runConfig;
  await card.create();
  const stream = reply ? null : new MessageStream(mm, where, runId, engineName, ownerRef);
  session = session ?? { root_id: root, channel_id: post.channel_id, engine: engineName, session_id: "", status: "running", title, card_post_id: card.postId, last_seen_at: 0, updated_at: 0 };
  session.status = "running"; session.card_post_id = card.postId; session.last_seen_at = post.create_at; session.updated_at = Date.now();
  saveSession(session);

  const ac = new AbortController();
  running.set(root, { ac, assigner: post.user_id, channel_id: post.channel_id, posts: () => [card.postId, reply?.id ?? "", ...(stream?.ids ?? [])].filter(Boolean) });
  const sendTyping = () => typing("user_typing", { channel_id: post.channel_id, parent_id: post.root_id });
  sendTyping();
  const typingTimer = setInterval(sendTyping, 4000);

  const ask = async (req: ApprovalRequest) => {
    const sid = `approval-${crypto.randomUUID()}`;
    card.step({ id: sid, kind: "approval", title: `Chờ duyệt: ${req.title.slice(0, 100)}`, status: "waiting" });
    card.setStatus("awaiting_approval");
    await card.flush();
    const d = reply ? await askApprovalInline(reply, req, post.user_id, ac.signal) : await askApproval(where, engineName, req, post.user_id, ac.signal);
    card.step({ id: sid, kind: "approval", title: `${d === "accept" ? "Đã duyệt" : "Bị từ chối"}: ${req.title.slice(0, 100)}`, status: d === "accept" ? "done" : "error" });
    card.setStatus("running");
    return d;
  };
  runsByKey.set(runId, ask);

  try {
    const res = await engines[engineName].runTurn(
      {
        sessionId: session.session_id || undefined,
        cwd: dir,
        prompt,
        persona,
        model,
        effort,
        mcpEnv: {
          MM_URL: cfg.serverUrl, MM_TOKEN: cfg.botToken, CHANNEL_ID: post.channel_id, ROOT_ID: post.root_id,
          RUNNER_URL: `http://127.0.0.1:${http.port}`, RUN_KEY: runId, WORKDIR: dir, OWNER_ID: post.user_id,
        },
      },
      {
        step: (s) => card.step(s),
        text: (t) => (reply ? reply.update(t) : stream!.update(t)),
        approval: ask,
        session: (id) => { card.sessionId = id; session!.session_id = id; saveSession(session!); },
      },
      ac.signal,
    );
    card.usage = res.usage;
    card.sessionId = res.sessionId;
    card.setStatus("done");
    await card.finish();
    // Hỏi trong luồng không tích "Gửi cả vào chat chính" (flygo_reply="thread") -> trả lời im lặng trong luồng.
    // Tin gốc, reply có tích (thread_broadcast) hoặc reply từ client khác (không có flygo_reply) -> tin cuối ra cả chat chính.
    const broadcast = !(post.root_id && post.props?.flygo_reply === "thread");
    if (reply) await reply.finish(res.text); else await stream!.finish(res.text, broadcast);
    session.status = "done";
  } catch (e: any) {
    const cancelled = ac.signal.aborted;
    card.error = cancelled ? "" : String(e?.message ?? e).slice(0, 400);
    card.setStatus(cancelled ? "cancelled" : "error");
    await card.finish();
    if (reply) await reply.finish(""); else await stream!.finish("", false);
    if (!cancelled) await mm.createPost({ ...where, message: `❌ Em gặp lỗi: ${card.error}`, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } });
    session.status = cancelled ? "cancelled" : "error";
    log(`run ${runId} ${session.status}: ${e?.message ?? e}`);
  } finally {
    emit({ event: "run_finished", run_id: runId, root_id: root, status: session.status });
    clearInterval(typingTimer);
    running.delete(root);
    runsByKey.delete(runId);
    session.updated_at = Date.now();
    saveSession(session);
  }
}

// ---- WebSocket Mattermost ----
const typing = mm.connect((ev) => {
  if (ev.event === "hello") emit({ event: "connected" });
  if (ev.event === "posted") {
    const post = JSON.parse(ev.data.post) as Post;
    onPosted(post, ev.data.channel_type).catch((e) => log(`onPosted error ${e}`));
  } else if (ev.event === "user_updated" && ev.data?.user?.id === BOT_ID) {
    refreshAllow(); // sự kiện có thể không mang bot_description: đọc lại từ /users/me
  } else if (ev.event === "channel_updated") {
    mm.forgetChannel(ev.broadcast?.channel_id ?? ev.data?.channel_id ?? "");
  } else if (ev.event === "user_added" || ev.event === "user_removed") {
    memberCache.delete(ev.broadcast?.channel_id ?? ev.data?.channel_id);
  } else if (ev.event === "reaction_added") {
    const r = JSON.parse(ev.data.reaction);
    // 🛑 lên post của lượt đang chạy (thẻ / tin trả lời) = dừng lượt, như nhắn "dừng". Chỉ người giao việc hoặc chủ bot.
    if (r.emoji_name === "octagonal_sign") {
      for (const x of running.values()) {
        if (!x.posts().includes(r.post_id) || !(r.user_id === x.assigner || isOwner(r.user_id))) continue;
        log(`dừng lượt theo 🛑 trên ${r.post_id}`);
        x.ac.abort();
      }
      return;
    }
    const pa = pendingApprovals.get(r.post_id);
    if (!pa || !(r.user_id === pa.assigner || isOwner(r.user_id))) return; // người giao việc hoặc chủ bot
    const resolve = pa.resolve;
    if (r.emoji_name === "+1" || r.emoji_name === "white_check_mark") resolve("accept");
    else if (r.emoji_name === "-1" || r.emoji_name === "x") resolve("decline");
  }
}, log);

// ---- trạng thái hiện trên bot (custom status tự hết hạn nếu runner chết đột ngột) ----
const host = hostname().replace(/\.local$/, "");
async function presence(online: boolean) {
  if (online) {
    await mm.api("PUT", `/users/${BOT_ID}/status`, { user_id: BOT_ID, status: "online" }).catch(() => {});
    await mm.api("PUT", `/users/${BOT_ID}/status/custom`, {
      emoji: "large_green_circle", text: `Đang chạy trên ${host} · ${ENGINE}`,
      duration: "date_and_time", expires_at: new Date(Date.now() + 10 * 60_000).toISOString(),
    }).catch((e) => log(`custom status: ${e}`));
  } else {
    await mm.api("DELETE", `/users/${BOT_ID}/status/custom`).catch(() => {});
    await mm.api("PUT", `/users/${BOT_ID}/status`, { user_id: BOT_ID, status: "offline" }).catch(() => {});
  }
}
await presence(true);
const presenceTimer = setInterval(() => presence(true), 5 * 60_000);

async function shutdown(sig: string) {
  log(`nhận ${sig}, dừng runner`);
  clearInterval(presenceTimer);
  for (const x of running.values()) x.ac.abort();
  await presence(false);
  try { if (readFileSync(lockPath, "utf8") === String(process.pid)) unlinkSync(lockPath); } catch {}
  emit({ event: "stopped" });
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

emit({ event: "ready", bot: { id: BOT_ID, username: BOT_NAME }, owners: cfg.ownerUserIds, allow: allowIds, engine: ENGINE, options: agentOptions(cfg, botDesc), doctor: report, workspace_root: cfg.workspaceRoot });
log(`runner sẵn sàng · engine ${ENGINE} · thư mục làm việc ${cfg.workspaceRoot}`);
}

