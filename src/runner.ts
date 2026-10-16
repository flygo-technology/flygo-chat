// flygo-agent runner: chạy trên máy cá nhân, nối bot Mattermost với Codex/Claude.
// - Chủ bot @tag bot (hoặc nhắn DM, hoặc trả lời trong chủ đề đã có phiên) -> agent làm việc trong chủ đề đó.
// - Tin ở chat chính -> trả lời ngay ở chat chính, MỘT post stream (thẻ + chữ), không tự tạo luồng; phiên theo kênh.
// - Tin trong luồng -> trả lời trong luồng: thẻ tiến trình (props.flygo_agent) + tin stream (props.flygo_agent_message).
// - Duyệt quyền: post "Cần Sếp duyệt" trong chủ đề, chủ bot bấm Xác nhận / Từ chối (reaction +1 / -1).
// - Chế độ --json: in sự kiện JSON từng dòng ra stdout cho app Flygo Chat (log ra stderr).
import { Database } from "bun:sqlite";
import { copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { normHost } from "./config";
import { join, resolve, sep } from "node:path";
import defaultPersona from "../profiles/default/persona.md" with { type: "text" };
import { RunCard } from "./card";
import { agentOptions, CONFIG_DIR, type Config, type EngineName } from "./config";
import { doctor } from "./doctor";
import { ClaudeEngine } from "./engines/claude";
import { CodexEngine } from "./engines/codex";
import { answerText, type ApprovalDecision, type ApprovalRequest, type AskResult, type Engine, type UserAnswer, type UserQuestion } from "./engines/types";
import { A2AClient, type A2APeer } from "./a2a";
import { INLINE_MAX, insideDir, saveFilePart, splitParts, toFilePart, uploadLarge } from "./a2a-files";
import { InlineReply } from "./messages";
import { aiOf, ancestorChain, linkOf, type Level } from "./chain";
import { botHome, claudeSkillsDir, deleteSkill, listSkills, memoryPath, readRole, readSkill, roleLine, roleSlug, saveSkill, setRole, type SkillFile } from "./skills";
import pkg from "../package.json";
import { createHash } from "node:crypto";
import { basename } from "node:path";
import { MM, type Post } from "./mm";

export interface RunnerIO {
  emit(ev: Record<string, any>): void; // sự kiện cho app
  log(s: string): void;
  selfCommand: string[]; // lệnh gọi lại chính chương trình này (để chạy subcommand mcp-chat)
}

export async function startRunner(cfg: Config, io: RunnerIO) {
const { emit } = io;
const log = io.log;
const mm = new MM(cfg.serverUrl, cfg.botToken);
// Token bị thu hồi (bot bị xoá/tắt: POST /bots/{id}/disable) -> 401: báo và thoát mã 0 để dịch vụ nền không chạy lại liên tục.
// Lỗi khác (mạng…) thì thoát lỗi để dịch vụ nền thử lại.
const isAuthError = (e: any) => /-> 401\b/.test(String(e?.message ?? e));
const me = await mm.me().catch((e) => {
  if (isAuthError(e)) {
    emit({ event: "error", code: "auth_revoked", message: `Token của bot không còn dùng được (bot đã bị tắt hoặc xoá): ${String(e.message ?? e).slice(0, 200)}` });
    io.log("token bot bị từ chối (401): dừng runner");
    process.exit(0);
  }
  emit({ event: "error", code: "auth", message: String(e.message ?? e) });
  throw e;
});
const BOT_ID: string = me.id;
let BOT_NAME: string = me.username; // đổi được trên app (PUT /bots): cập nhật ở refreshAllow
log(`bot @${BOT_NAME} (${BOT_ID}), chủ: ${cfg.ownerUserIds.join(", ")}`);

// ---- phân quyền gọi bot: chủ (config) ∪ allow trong mô tả bot "[flygo-agent … allow=id1,id2]" ----
let allowIds: string[] = [];
let botDesc: string = me.bot_description ?? ""; // mốc "[flygo-agent engine=… allow=… models=… efforts=… default=…]"
const parseAllow = (desc: string) => /\[flygo-agent[^\]]*\ballow=([a-z0-9,]+)/i.exec(desc ?? "")?.[1].split(",").filter(Boolean) ?? [];
async function refreshAllow() {
  let revoked = false;
  const u = await mm.me().catch((e) => { revoked = isAuthError(e); return null; });
  if (revoked) { emit({ event: "error", code: "auth_revoked", message: "Token của bot không còn dùng được (bot đã bị tắt hoặc xoá)." }); return shutdown("auth_revoked"); }
  if (!u) return;
  botDesc = u.bot_description ?? "";
  if (boundElsewhere(botDesc)) return shutdown("bound_elsewhere"); // bị chuyển sang máy khác lúc đang chạy
  if (u.username && u.username !== BOT_NAME) {
    log(`bot đổi tên @${BOT_NAME} -> @${u.username}`);
    BOT_NAME = u.username;
    mentionRe = mentionReFor(BOT_NAME);
    emit({ event: "bot_renamed", bot: { id: BOT_ID, username: BOT_NAME } });
  }
  a2a?.setCard(a2aCard());
  const next = parseAllow(u.bot_description);
  if (next.join(",") !== allowIds.join(",")) log(`người được gọi bot: ${[...cfg.ownerUserIds, ...next].join(", ")}`);
  allowIds = next;
}
// ---- bot gắn cứng một máy: mốc "[flygo-agent … host=<máy>]" (app đặt khi bật "Chạy trên máy này") ----
const MY_HOST = normHost(hostname());
const markerHost = (desc: string) => normHost(/\[flygo-agent[^\]]*\bhost=([^\s\]]+)/i.exec(desc ?? "")?.[1] ?? "");
/** Bot đã gắn máy khác: báo lỗi và thoát mã 0 (dịch vụ nền chỉ chạy lại khi thoát lỗi -> không lặp). */
function boundElsewhere(desc: string) {
  const h = markerHost(desc);
  if (!h || h === MY_HOST) return false;
  emit({ event: "error", code: "bound_elsewhere", host: h, message: `Bot @${BOT_NAME} đã gắn với máy ${h}, không chạy trên ${MY_HOST}.` });
  log(`bot gắn với máy ${h}, máy này là ${MY_HOST}: dừng runner`);
  return true;
}
if (boundElsewhere(botDesc)) process.exit(0);
if (!markerHost(botDesc)) {
  // Bot không tự sửa được mô tả của mình (Mattermost cấm) -> thử, không được thì chỉ báo; app/chủ bot đặt host.
  const desc = /\[flygo-agent[^\]]*\]/i.test(botDesc) ? botDesc.replace(/\[flygo-agent([^\]]*)\]/i, `[flygo-agent$1 host=${MY_HOST}]`) : `${botDesc} [flygo-agent engine=${cfg.engine} host=${MY_HOST}]`.trim();
  const ok = await mm.api("PUT", `/bots/${BOT_ID}`, { description: desc }).then(() => true, () => false);
  log(ok ? `đã gắn bot với máy ${MY_HOST}` : `bot chưa gắn máy (mốc thiếu host=), máy này: ${MY_HOST}`);
  if (!ok) emit({ event: "unbound", host: MY_HOST });
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
// Chat gắn thư mục code bằng lệnh "@bot dự án <path>" của chủ bot (mốc [flygo-project path=…] trong mô tả kênh được ưu tiên).
db.run(`CREATE TABLE IF NOT EXISTS projects (channel_id TEXT PRIMARY KEY, path TEXT)`);
// "Luôn cho phép" (🔓 của chủ bot trên lời xin duyệt): phạm vi = khoá phiên (chat chính của kênh / luồng / a2a:<caller>:<context>).
db.run(`CREATE TABLE IF NOT EXISTS bypass (scope TEXT PRIMARY KEY, by_user TEXT, at INTEGER)`);
// Khối "Vị trí & ID / Công cụ" đã đưa cho phiên: chỉ nhắc lại khi đổi.
db.run(`CREATE TABLE IF NOT EXISTS ctx_seen (root_id TEXT PRIMARY KEY, hash TEXT)`);
// Chat AI riêng: tin chat chính của nhóm gắn đã đưa cho phiên tới mốc thời gian nào.
db.run(`CREATE TABLE IF NOT EXISTS group_seen (root_id TEXT PRIMARY KEY, ts INTEGER)`);
// 📤 "Gửi ra ngoài bằng bot" trong chat AI riêng: mỗi tin chỉ gửi một lần.
db.run(`CREATE TABLE IF NOT EXISTS ai_shared (post_id TEXT PRIMARY KEY, group_post_id TEXT, at INTEGER)`);
const isBypass = (scope: string) => !!scope && !!db.query("SELECT 1 FROM bypass WHERE scope = ?").get(scope);
function setBypass(scope: string, on: boolean, by = "") {
  if (on) db.query("INSERT OR REPLACE INTO bypass VALUES (?, ?, ?)").run(scope, by, Date.now());
  else db.query("DELETE FROM bypass WHERE scope = ?").run(scope);
  log(`${on ? "bật" : "tắt"} luôn cho phép: ${scope}`);
}
const BYPASS_NOTE = "🔓 Đang chạy không cần duyệt (chủ bot cho phép)";
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
type Decision = ApprovalDecision | "expired" | "always";
let stopping = false; // runner đang tắt (SIGTERM: cập nhật / khởi động lại)
const STOP_NOTE = "⏹ Bị dừng do cập nhật trợ lý. Bấm \"Tiếp tục\" để em làm tiếp (hoặc gửi lại yêu cầu).";
const STALE_NOTE = "Lượt này đã dừng (trợ lý vừa khởi động lại). Bấm \"Tiếp tục\" hoặc gửi lại yêu cầu để em làm tiếp nhé.";
const pendingApprovals = new Map<string, { resolve: (d: Decision) => void; assigner: string; scope: string }>(); // post_id -> chờ duyệt
const runsByKey = new Map<string, (req: ApprovalRequest) => Promise<ApprovalDecision>>();

/** Chờ người giao việc (hoặc chủ bot) thả 👍/👎 lên post `postId`. `scope` khác rỗng: chủ bot thả 🔓 = duyệt + luôn cho phép phạm vi đó. */
async function waitDecision(postId: string, ownerId: string, signal?: AbortSignal, timeoutMs = cfg.approvalTimeoutSec * 1000, scope = ""): Promise<Decision> {
  const decision = await new Promise<Decision>((resolve) => {
    pendingApprovals.set(postId, { resolve, assigner: ownerId, scope }); // đăng ký trước khi thả 👍/👎 mẫu: không lỡ người bấm nhanh
    setTimeout(() => resolve("expired"), timeoutMs);
    signal?.addEventListener("abort", () => resolve(stopping ? "expired" : "decline")); // lượt bị dừng thì thôi chờ
    (async () => {
      await mm.react(postId, BOT_ID, "+1").catch(() => {});
      await mm.react(postId, BOT_ID, "-1").catch(() => {});
      // Reaction có trước khi đăng ký (post vừa hiện đã bấm): xét luôn.
      const rs = await mm.api<any[]>("GET", `/posts/${postId}/reactions`).catch(() => []);
      for (const x of rs ?? []) onApprovalReaction(x);
    })();
  });
  pendingApprovals.delete(postId);
  return decision;
}
const approvalStatus = (d: Decision) => (d === "accept" ? "accepted" : d === "always" ? "always" : d === "decline" ? "declined" : "expired");

/** Chat chính: lời xin duyệt nằm ngay trong post trả lời (props.flygo_agent_approval), 👍/👎 thả lên chính post đó. */
async function askApprovalInline(reply: InlineReply, req: ApprovalRequest, ownerId: string, signal?: AbortSignal, timeoutMs?: number, scope = ""): Promise<Decision> {
  const base = { kind: req.kind, title: req.title, detail: req.detail };
  const postId = await reply.ensurePost();
  await reply.setApproval({ ...base, status: "pending" });
  const decision = postId ? await waitDecision(postId, ownerId, signal, timeoutMs, scope) : "expired";
  await reply.setApproval({ ...base, status: approvalStatus(decision) });
  for (const e of ["+1", "-1", "unlock"]) await mm.api("DELETE", `/users/${BOT_ID}/posts/${postId}/reactions/${e}`).catch(() => {});
  await reply.setApproval(null); // đã ghi vào bước của thẻ
  return decision;
}

// ---- câu hỏi cho người dùng (AskUserQuestion / request_user_input / ask_user) ----
// Mỗi câu hỏi một post: props.flygo_agent_question = { id, question, header, options, multi, allow_other, status, answer? }.
// Trả lời KHÔNG tạo tin: thả 1️⃣–4️⃣ lên chính post (chọn nhiều: thả các số rồi ✅). "Ý khác": gõ một tin trong chỗ đó
// (tin này là câu trả lời, không mở lượt mới). Tương thích: post có props.flygo_agent_answer { post_id, choices, other?, cancelled? }.
const NUM_EMOJI = ["one", "two", "three", "four", "five", "six"];
interface PendingQuestion { resolve: (a: UserAnswer | null) => void; assigner: string; q: UserQuestion; picks: Set<number>; where: { channel_id: string; root_id: string } }
const pendingQuestions = new Map<string, PendingQuestion>(); // post_id câu hỏi -> chờ trả lời
const askByKey = new Map<string, (qs: UserQuestion[]) => Promise<AskResult>>(); // RUN_KEY -> hỏi trong lượt đó

async function askOne(where: { channel_id: string; root_id: string }, q: UserQuestion, assigner: string, signal: AbortSignal): Promise<UserAnswer | "cancelled" | "expired" | "stopped"> {
  const options = q.options.slice(0, NUM_EMOJI.length).map((o) => ({ label: String(o.label ?? ""), description: String(o.description ?? "") }));
  const meta = { id: crypto.randomUUID(), question: q.question, header: q.header ?? "", options, multi: !!q.multi, allow_other: true };
  const list = options.map((o, i) => `${i + 1}. **${o.label}**${o.description ? ` — ${o.description}` : ""}`).join("\n");
  const hint = `_Thả ${options.length > 1 ? `1️⃣–${["1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣"][options.length - 1]}` : "1️⃣"} để chọn${q.multi ? " (chọn nhiều rồi thả ✅)" : ""}, hoặc gõ ý khác._`;
  const base = { ...(where.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: assigner };
  const post = await mm.createPost({ ...where, message: `❓ ${q.question}\n${list}\n${hint}`, props: { ...base, flygo_agent_question: { ...meta, status: "pending" } } });
  const a = await new Promise<UserAnswer | null | "expired">((resolve) => {
    pendingQuestions.set(post.id, { resolve, assigner, q: { ...q, options }, picks: new Set(), where });
    const timer = setTimeout(() => resolve("expired"), cfg.approvalTimeoutSec * 1000);
    signal.addEventListener("abort", () => { clearTimeout(timer); resolve(null); });
  });
  pendingQuestions.delete(post.id);
  const status = a === "expired" ? "expired" : a ? "answered" : "cancelled";
  const answer = a && a !== "expired" ? answerText(a) : "";
  const done = a && a !== "expired" ? `→ ${answer}` : a === "expired" ? "_(hết giờ, không có trả lời)_" : "_(đã huỷ)_";
  await mm.patchPost(post.id, { message: `❓ ${q.question}\n${done}`, props: { ...base, flygo_agent_question: { ...meta, status, ...(answer ? { answer, choices: (a as UserAnswer).choices, ...((a as UserAnswer).other ? { other: (a as UserAnswer).other } : {}) } : {}) } } }).catch(() => {});
  return a === "expired" ? "expired" : a ? a : signal.aborted ? "stopped" : "cancelled";
}

/** Hỏi lần lượt từng câu; một câu bị huỷ / hết giờ thì thôi các câu sau. */
async function askUser(where: { channel_id: string; root_id: string }, qs: UserQuestion[], assigner: string, signal: AbortSignal): Promise<AskResult> {
  const answers: UserAnswer[] = [];
  for (const q of qs) {
    const a = await askOne(where, q, assigner, signal);
    if (a === "cancelled") return { cancelled: true, reason: "Người dùng huỷ câu hỏi. Đừng hỏi lại; tự quyết theo hướng hợp lý nhất hoặc dừng và nói rõ." };
    if (a === "expired") return { cancelled: true, reason: "Hết giờ chờ người dùng trả lời. Tự quyết theo hướng hợp lý nhất và nói rõ đã chọn gì." };
    if (a === "stopped") return { cancelled: true, reason: "Lượt đã bị dừng." };
    answers.push(a);
  }
  return { answers };
}

const canAnswer = (pq: PendingQuestion, uid: string) => uid === pq.assigner || isOwner(uid);
function onQuestionReaction(r: any, removed = false) {
  const pq = pendingQuestions.get(r.post_id);
  if (!pq || r.user_id === BOT_ID || !canAnswer(pq, r.user_id)) return;
  const i = NUM_EMOJI.indexOf(r.emoji_name);
  const labels = () => [...pq.picks].sort().map((k) => pq.q.options[k].label);
  if (i >= 0 && i < pq.q.options.length) {
    if (removed) { pq.picks.delete(i); return; }
    if (!pq.q.multi) return pq.resolve({ choices: [pq.q.options[i].label] });
    pq.picks.add(i);
    return;
  }
  if (removed) return;
  if (["-1", "x"].includes(r.emoji_name)) return pq.resolve(null);
  if (r.emoji_name === "white_check_mark" && pq.picks.size) return pq.resolve({ choices: labels() });
  // 👍: app thả kèm khi gửi trả lời (dự phòng). Có trả lời (post / số) thì bỏ qua; chọn nhiều đã có số thì coi như xong.
  if (r.emoji_name === "+1") setTimeout(() => { if (pendingQuestions.get(r.post_id) === pq && pq.picks.size) pq.resolve({ choices: labels() }); }, 3000);
}
/** Tin trả lời câu hỏi: props.flygo_agent_answer, hoặc tin gõ "ý khác" ở đúng chỗ đang hỏi. true = đã dùng làm câu trả lời. */
function onQuestionPost(post: Post): boolean {
  let ans: any = post.props?.flygo_agent_answer;
  if (typeof ans === "string") try { ans = JSON.parse(ans); } catch { ans = null; }
  if (ans?.post_id) {
    const pq = pendingQuestions.get(ans.post_id);
    if (!pq || !canAnswer(pq, post.user_id)) return true; // không phải câu của bot này / đã xong: không mở lượt mới
    if (ans.cancelled) pq.resolve(null);
    else pq.resolve({ choices: (Array.isArray(ans.choices) ? ans.choices : []).map(String), ...(ans.other || post.message?.trim() && !ans.choices?.length ? { other: String(ans.other || post.message).trim() } : {}) });
    return true;
  }
  for (const [qid, pq] of pendingQuestions) {
    if (!canAnswer(pq, post.user_id) || post.channel_id !== pq.where.channel_id) continue;
    if (!(post.root_id === pq.where.root_id || post.root_id === qid)) continue;
    const other = post.message.replace(mentionRe, "").trim();
    mentionRe.lastIndex = 0;
    if (!other) continue;
    pq.resolve({ choices: pq.q.multi ? [...pq.picks].sort().map((k) => pq.q.options[k].label) : [], other });
    return true;
  }
  return false;
}

// HTTP nội bộ: MCP server của Claude gọi /approve
const http = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0, // /approve, /a2a/ask_agent chờ người duyệt / agent khác làm lâu: không cắt kết nối (mặc định Bun 10 giây)
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
    if (url.pathname === "/ask" && req.method === "POST") { // câu hỏi cho người dùng: ask-hook (Claude) / ask_user (MCP)
      const { key, questions } = await req.json();
      const ask = askByKey.get(key);
      if (!ask) return Response.json({ cancelled: true, reason: "Không hỏi được người dùng ở đây (lượt đã xong hoặc đang làm việc được nhờ qua A2A). Tự quyết theo hướng hợp lý nhất và nói rõ đã chọn gì." });
      const qs = (Array.isArray(questions) ? questions : []).filter((q: any) => q?.question && Array.isArray(q.options)).slice(0, 4);
      if (!qs.length) return Response.json({ cancelled: true, reason: "Câu hỏi không hợp lệ (cần question + options)." });
      return Response.json(await ask(qs));
    }
    if (url.pathname.startsWith("/a2a/") && req.method === "POST") {
      const body = await req.json();
      const r = await a2aTool(url.pathname.slice(5), body).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname.startsWith("/skill/") && req.method === "POST") {
      const r = await skillTool(url.pathname.slice(7), await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname === "/report_out" && req.method === "POST") {
      const r = await reportOut(await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname === "/ctx") { // mcp-chat hỏi ngữ cảnh lượt hiện tại của phiên (SCOPE)
      const c = mcpCtx.get(url.searchParams.get("scope") ?? "");
      return c ? Response.json(c) : new Response("no run", { status: 404 });
    }
    if (url.pathname === "/health") return new Response("ok");
    return new Response("not found", { status: 404 });
  },
});

// Cổng HTTP của runner ghi ra tệp: MCP sống lâu (Codex app-server giữ thread) vẫn tìm được runner sau khi runner khởi động lại.
const portFile = join(CONFIG_DIR, `runner-${BOT_ID}.port`);
writeFileSync(portFile, String(http.port));
const mcpCtx = new Map<string, Record<string, string>>(); // khoá phiên -> env MCP của lượt đang chạy
/** Env MCP của lượt: đăng ký theo khoá phiên để MCP cũ hỏi lại được (/ctx). */
function mcpEnvFor(scope: string, e: Record<string, string>) {
  const full = { ...e, RUNNER_URL: `http://127.0.0.1:${http.port}`, SCOPE: scope, PORT_FILE: portFile };
  mcpCtx.set(scope, full);
  return full;
}

// ---- dựng ngữ cảnh & thư mục làm việc ----
const persona = cfg.persona?.trim() ? cfg.persona : defaultPersona; // chung cho mọi bot (ghi vào AGENTS.md/CLAUDE.md của thư mục chat)
/** Persona của bot này: persona chung + vai trò riêng (ROLE.md). Chỉ truyền qua engine, không ghi vào thư mục chat dùng chung. */
const botPersona = () => { const r = readRole(BOT_ID); return r ? `${persona}\n\n## Vai trò của bạn (@${BOT_NAME})\n${r}` : persona; };

// ---- thư mục làm việc: mỗi chat một thư mục (hoặc thư mục code đã gắn); kênh bí mật [flygo-sub parent=…] dùng của chat cha ----
const slug = (t: string) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[đĐ]/g, "d").toLowerCase()
  .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "chat";
const subParentOf = (ch: any) => /\[flygo-sub parent=(\w+)/.exec(ch.purpose ?? "")?.[1];
/** Chat gốc trên cùng của kênh bí mật / chat AI riêng (lồng nhau: lần theo parent, tối đa 10 tầng). Kênh thường trả về chính nó. */
async function topChat(ch: any): Promise<any> {
  let cur = ch;
  for (let i = 0; i < 10; i++) {
    const pid = linkOf(cur)?.parent; // luồng bí mật -> kênh cha; chat AI riêng -> nhóm gắn
    if (!pid) break;
    const parent = await mm.channel(pid).catch(() => null);
    if (!parent) break;
    cur = parent;
  }
  return cur;
}
async function chatName(ch: any): Promise<string> {
  if (ch.type === "D") {
    const other = String(ch.name).split("__").find((id) => id !== BOT_ID) ?? BOT_ID;
    return `Chat với ${await mm.displayName(other)}`;
  }
  return ch.display_name || ch.name;
}

/** Path thư mục code hợp lệ: có thật, là thư mục, nằm dưới cfg.projectRoots. Trả về realpath hoặc null. */
function allowedProject(raw: string): string | null {
  try {
    const real = realpathSync(resolve(raw.replace(/^~(?=\/|$)/, homedir())));
    if (!statSync(real).isDirectory()) return null;
    for (const r of cfg.projectRoots) {
      let root: string;
      try { root = realpathSync(r); } catch { continue; }
      if (real === root || real.startsWith(root + sep)) return real;
    }
  } catch {}
  return null;
}
const projectRe = /\[flygo-project path=([^\]\s]+)\]/;
const purposeOwner = new Map<string, string | null>(); // channel_id -> path từ mốc trong mô tả (đã kiểm chủ bot đặt), xoá khi channel_updated
/** Mốc [flygo-project path=…] chỉ có hiệu lực khi lần đổi mô tả gần nhất (tin hệ thống system_purpose_change) do chủ bot làm. */
async function purposeProject(ch: any): Promise<string | null> {
  const m = projectRe.exec(ch.purpose ?? "");
  if (!m) return null;
  if (!purposeOwner.has(ch.id)) {
    let ok = false, before: string | undefined;
    for (let page = 0; page < 5; page++) {
      const posts = await mm.channelPosts(ch.id, 200, before).catch(() => [] as Post[]);
      const hit = [...posts].reverse().find((p) => p.type === "system_purpose_change");
      if (hit) { ok = isOwner(hit.user_id) && String(hit.props?.new_purpose ?? "").includes(m[0]); break; }
      if (posts.length < 200) break;
      before = posts[0].id;
    }
    purposeOwner.set(ch.id, ok ? allowedProject(m[1]) : null);
    if (!ok) log(`kênh ${ch.id}: bỏ qua ${m[0]} (không phải chủ bot đặt)`);
  }
  return purposeOwner.get(ch.id)!;
}
async function boundProject(ch: any): Promise<string | null> {
  const fromPurpose = await purposeProject(ch);
  if (fromPurpose) return fromPurpose;
  const row = db.query("SELECT path FROM projects WHERE channel_id = ?").get(ch.id) as { path: string } | null;
  return row ? allowedProject(row.path) : null;
}

/** Thư mục riêng của chat: "<tên chat>-<6 ký tự id>". Đổi tên chat thì đổi tên thư mục; thư mục kiểu cũ (dm-<id>, <tên kênh>) được đổi tên sang. */
function chatDir(base: any, name: string) {
  const tag = base.id.slice(0, 6);
  const dir = join(cfg.workspaceRoot, `${slug(name)}-${tag}`);
  if (!existsSync(dir)) {
    mkdirSync(cfg.workspaceRoot, { recursive: true });
    const legacy = (base.type === "D" ? `dm-${base.id}` : base.name || base.id).replace(/[^a-zA-Z0-9._-]/g, "_");
    const old = readdirSync(cfg.workspaceRoot).find((d) => d.endsWith(`-${tag}`)) ?? (existsSync(join(cfg.workspaceRoot, legacy)) ? legacy : undefined);
    if (old) { try { renameSync(join(cfg.workspaceRoot, old), dir); log(`thư mục ${old} -> ${dir}`); } catch {} }
  }
  mkdirSync(dir, { recursive: true });
  return dir;
}

async function workspaceFor(channelId: string) {
  const ch = await mm.channel(channelId);
  const base = await topChat(ch); // kênh bí mật (kể cả lồng nhau): thư mục của chat gốc trên cùng
  const chat = await chatName(base);
  const bound = await boundProject(base);
  if (bound) return { dir: bound, ch, chat, bound: true }; // thư mục code: không chép persona/skill vào (persona truyền qua engine)
  const dir = chatDir(base, chat); // kỹ năng KHÔNG chép vào đây (nhiều bot dùng chung thư mục chat): xem src/skills.ts
  for (const f of ["AGENTS.md", "CLAUDE.md"]) await Bun.write(join(dir, f), persona);
  return { dir, ch, chat, bound: false };
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
    const shared = p.props?.flygo_ai_share ? (p.user_id === BOT_ID ? " (bạn đăng tin này theo lệnh 📤 \"Gửi ra ngoài bằng bot\" của chủ trong chat AI riêng)" : " (gửi ra từ chat AI riêng theo lệnh 📤 của chủ)") : "";
    out.push(`[${t}] ${await mm.displayName(p.user_id)}: ${p.message}${filesNote(p)}${shared}`);
  }
  return out.join("\n");
}

const mentionReFor = (name: string) => new RegExp(`@${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "gi");
let mentionRe = mentionReFor(BOT_NAME);

// ---- A2A: bot nhờ nhau qua relay (xem src/a2a.ts, relay/a2a.mjs) ----
// Chủ trì: tool ask_agent / list_agents (mcp-chat, A2A_ROLE=orchestrator) -> runner gọi agent khác (message/stream), ghi bước lên thẻ.
// Được nhờ: relay chuyển JSON-RPC tới -> chạy engine trong phiên riêng "a2a:<bên gọi>:<contextId>", quyền và duyệt của chính bot này
// (duyệt hiện trong DM với chủ bot), không đọc/gửi chat, không nhờ tiếp agent khác (độ sâu 1).
const a2a = cfg.a2a.enabled ? new A2AClient(cfg.a2a.relay, cfg.serverUrl, cfg.botToken, log, (cid, from, depth, req) => onA2ARequest(cid, from, depth, req), (cid) => onA2ACancel(cid)) : null;
const relayBase = cfg.a2a.relay.replace(/^ws/, "http").replace(/\/connect$/, "");
const relayAuth = { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl };
const iso = () => new Date().toISOString();
const oneLine = (t: string, n: number) => { const s = String(t ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "…" : s; };

function a2aCard() {
  const o = agentOptions(cfg, botDesc);
  const modes = ["text/plain", "application/json", "*/*"];
  return {
    protocolVersion: "1.0",
    version: pkg.version,
    description: [roleLine(readRole(BOT_ID)), botDesc.replace(/\[flygo-agent[^\]]*\]/i, "").trim()].filter(Boolean).join(" — ") || `Trợ lý AI @${BOT_NAME}`,
    capabilities: {
      streaming: true,
      extensions: [{ uri: "https://flygo.vn/a2a/ext/agent-options/v1", description: "Engine, model và mức suy nghĩ của agent", params: { engine: ENGINE, models: o.models, efforts: o.efforts, default: o.default, host: MY_HOST } }],
    },
    defaultInputModes: modes,
    defaultOutputModes: modes,
    skills: [{
      id: "assistant", name: `Trợ lý ${ENGINE}`, tags: [ENGINE, "coding", "files", "research"], inputModes: modes, outputModes: modes,
      description: `${roleLine(readRole(BOT_ID)) ? `${roleLine(readRole(BOT_ID))}. ` : ""}Làm việc trên máy ${MY_HOST} bằng ${ENGINE === "codex" ? "Codex" : "Claude Code"}: đọc/sửa code, chạy lệnh, tra cứu web, xử lý tệp.`,
    }, ...listSkills(BOT_ID, cfg.skillsDir).slice(0, 30).map((k) => ({ id: `skill:${k.name}`, name: k.name, description: k.description || k.name, tags: ["skill", ENGINE], inputModes: modes, outputModes: modes }))],
  };
}

/** Các bot flygo-agent được @tag trong tin, theo thứ tự xuất hiện. */
async function taggedAgents(message: string): Promise<{ id: string; username: string }[]> {
  const out: { id: string; username: string }[] = [];
  for (const m of message.matchAll(/(?:^|[^\w@])@([a-zA-Z0-9_][a-zA-Z0-9_.-]*[a-zA-Z0-9_])/g)) {
    const u = m[1] === BOT_NAME ? { id: BOT_ID, username: BOT_NAME, is_bot: true, bot_description: "[flygo-agent]" } : await userByName(m[1]);
    if (u?.is_bot && /\[flygo-agent/i.test(u.bot_description ?? "") && !out.some((x) => x.id === u.id)) out.push({ id: u.id, username: u.username });
  }
  return out;
}

// -- phía chủ trì --
interface OrchRun { card: RunCard; dir: string; root: string; channelId: string; signal: AbortSignal; calls: number; chat: string }
const orchRuns = new Map<string, OrchRun>(); // run key -> lượt chat đang chạy

async function a2aTool(name: string, a: any): Promise<string> {
  if (name === "return_files") return a2aReturnFiles(a);
  const ctx = orchRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  if (!a2a?.online) return "Chưa nối được relay A2A nên chưa nhờ được agent khác.";
  const peers = await a2a.list();
  if (name === "list_agents") {
    if (!peers.length) return "Không có agent nào khác đang trực tuyến mà bạn được phép nhờ.";
    return peers.map((p) => {
      const ext = p.card?.capabilities?.extensions?.find((e: any) => String(e.uri).includes("agent-options"))?.params;
      return `- @${p.username} (${p.name})${ext ? ` — ${ext.engine}, ${ext.default?.model ?? ""}` : ""}, chủ: ${p.owner_name}${p.card?.description ? `. ${oneLine(p.card.description, 160)}` : ""}`;
    }).join("\n");
  }
  if (name !== "ask_agent") return `Không có tool ${name}.`;
  const bot = String(a.bot ?? "").replace(/^@/, "").trim();
  const peer = peers.find((p) => p.username === bot || p.id === bot);
  if (!peer) return `Không thấy @${bot} trực tuyến, hoặc bạn không được phép nhờ agent đó. Dùng list_agents để xem các agent nhờ được.`;
  if (ctx.calls >= cfg.a2a.maxCalls) return `Đã nhờ agent ${ctx.calls} lần trong lượt này (tối đa ${cfg.a2a.maxCalls}). Hãy tự làm tiếp hoặc trả lời với những gì đã có.`;
  const n = ++ctx.calls;
  const message = String(a.message ?? "");
  const parts: any[] = [{ kind: "text", text: message }];
  if (a.data && typeof a.data === "object") parts.push({ kind: "data", data: a.data });
  const sendErrors: string[] = [];
  for (const f of Array.isArray(a.files) ? a.files : []) {
    try { parts.push(await toFilePart(a2a, mm, cfg.botToken, async () => ctx.channelId, insideDir(ctx.dir, String(f)), peer.id)); }
    catch (e: any) { sendErrors.push(`${f}: ${e?.message ?? e}`); }
  }
  if (sendErrors.length) { ctx.calls--; return `Chưa nhờ @${peer.username} vì không gửi được tệp:\n- ${sendErrors.join("\n- ")}`; }
  const sid = `a2a-${n}-${crypto.randomUUID().slice(0, 6)}`;
  const askTitle = `Hỏi @${peer.username}: ${oneLine(message, 80)}`;
  const fileNote = parts.filter((p) => p.kind === "file").map((p) => p.file.name);
  ctx.card.step({ id: `${sid}-q`, kind: "tool", title: askTitle, status: "running", detail: message + (fileNote.length ? `\n📎 ${fileNote.join(", ")}` : "") });
  // Cùng một luồng chat + cùng agent -> cùng contextId: agent kia nhớ các lần nhờ trước trong luồng này.
  const contextId = createHash("sha256").update(`${BOT_ID}:${ctx.root}:${peer.id}`).digest("hex").slice(0, 32);
  const artifacts: any[] = [];
  let status: any = null;
  try {
    await a2a.call(peer.id, "message/stream", {
      message: { kind: "message", role: "user", messageId: crypto.randomUUID(), contextId, parts, metadata: { "x-flygo": { chat: ctx.chat } } },
      configuration: { blocking: true, acceptedOutputModes: ["text/plain", "application/json", "*/*"] },
    }, {
      timeoutMs: cfg.a2a.timeoutSec * 1000, signal: ctx.signal,
      onEvent: (e) => {
        if (e?.kind === "status-update") {
          status = e.status;
          const t = splitParts(e.status?.message?.parts ?? []).texts.join(" ");
          if (t && !e.final) ctx.card.step({ id: `${sid}-q`, kind: "tool", title: askTitle, status: "running", detail: `${message}\n\n⏳ ${oneLine(t, 200)}` });
        } else if (e?.kind === "artifact-update") artifacts.push(e.artifact);
        else if (e?.kind === "task") status = e.status;
      },
    });
  } catch (e: any) {
    ctx.card.step({ id: `${sid}-q`, kind: "tool", title: askTitle, status: "error", detail: `${message}\n\n❌ ${e?.message ?? e}` });
    return `Nhờ @${peer.username} không thành: ${e?.message ?? e}`;
  }
  const state = status?.state ?? "unknown";
  const all = splitParts(artifacts.flatMap((x) => x.parts ?? []));
  let answer = all.texts.join("\n\n").trim();
  if (!answer) answer = splitParts(status?.message?.parts ?? []).texts.join("\n").trim() || `(không có câu trả lời, trạng thái ${state})`;
  const saved: string[] = [];
  for (const f of all.files) {
    try { saved.push(await saveFilePart(f, join(ctx.dir, "a2a-nhan", peer.username), relayBase, relayAuth)); }
    catch (e: any) { sendErrors.push(`nhận ${f?.name}: ${e?.message ?? e}`); }
  }
  ctx.card.step({ id: `${sid}-q`, kind: "tool", title: askTitle, status: "done", detail: message + (fileNote.length ? `\n📎 ${fileNote.join(", ")}` : "") });
  ctx.card.step({
    id: `${sid}-a`, kind: "message", title: `@${peer.username} trả lời: ${oneLine(answer, 80)}`, status: state === "completed" ? "done" : "error",
    detail: answer + (saved.length ? `\n📎 ${saved.map((p) => basename(p)).join(", ")}` : ""),
  });
  return [
    `@${peer.username} (${state}) trả lời:`, answer,
    all.datas.length ? `\nDữ liệu kèm theo:\n${JSON.stringify(all.datas, null, 2).slice(0, 20000)}` : "",
    saved.length ? `\nTệp nhận được (đã lưu trong thư mục làm việc, gửi cho Sếp bằng chat_send_files nếu cần):\n${saved.map((p) => `- ${p}`).join("\n")}` : "",
    sendErrors.length ? `\nLỗi tệp:\n- ${sendErrors.join("\n- ")}` : "",
  ].filter(Boolean).join("\n");
}

// -- phía được nhờ --
interface A2ATask { task: any; ac: AbortController; callerId: string; files: string[]; dir: string }
const a2aTasks = new Map<string, A2ATask>(); // task id
const a2aByCid = new Map<string, string>(); // cid (cuộc gọi qua relay) -> task id
const a2aRuns = new Map<string, A2ATask>(); // run key -> task (tool return_files)
const ownerDM = async () => (await mm.api<any>("POST", "/channels/direct", [BOT_ID, cfg.ownerUserIds[0]])).id as string;

function onA2ACancel(cid: string) {
  const t = a2aTasks.get(a2aByCid.get(cid) ?? "");
  t?.ac.abort();
}

function onA2ARequest(cid: string, from: A2APeer, _depth: number, req: { method: string; params: any }) {
  const P = req.params ?? {};
  const fail = (code: number, message: string) => a2a!.done(cid, undefined, { code, message });
  const mine = (id: string) => { const t = a2aTasks.get(String(id ?? "")); return t && t.callerId === from.id ? t : null; };
  switch (req.method) {
    case "tasks/get": { const t = mine(P.id); return t ? a2a!.done(cid, t.task) : fail(-32001, "task không tồn tại"); }
    case "tasks/cancel": { const t = mine(P.id); if (!t) return fail(-32001, "task không tồn tại"); t.ac.abort(); return a2a!.done(cid, t.task); }
    case "message/send": case "message/stream": {
      const msg = P.message;
      if (!Array.isArray(msg?.parts) || !msg.parts.length) return fail(-32602, "thiếu message.parts");
      const task = { kind: "task", id: crypto.randomUUID(), contextId: String(msg.contextId || crypto.randomUUID()), status: { state: "submitted", timestamp: iso() }, history: [msg], artifacts: [] as any[] };
      const dir = join(cfg.workspaceRoot, `a2a-${slug(from.username)}-${from.id.slice(0, 6)}`);
      const t: A2ATask = { task, ac: new AbortController(), callerId: from.id, files: [], dir };
      a2aTasks.set(task.id, t);
      a2aByCid.set(cid, task.id);
      const stream = req.method === "message/stream";
      if (stream) a2a!.event(cid, task);
      log(`a2a: @${from.username} nhờ (${req.method}) ${oneLine(splitParts(msg.parts).texts.join(" "), 80)}`);
      enqueue(`a2a:${from.id}:${task.contextId}`, () => runA2A(cid, from, msg, t, stream));
      return;
    }
    default: return fail(-32601, `method ${req.method} không hỗ trợ`);
  }
}

async function a2aReturnFiles(a: any): Promise<string> {
  const t = a2aRuns.get(a.key);
  if (!t) return "Chỉ dùng được khi đang làm việc được agent khác nhờ.";
  const ok: string[] = [], bad: string[] = [];
  for (const p of Array.isArray(a.paths) ? a.paths : []) {
    try { const real = insideDir(t.dir, String(p)); if (!t.files.includes(real)) t.files.push(real); ok.push(basename(real)); }
    catch (e: any) { bad.push(`${p}: ${e?.message ?? e}`); }
  }
  return [ok.length ? `Sẽ gửi kèm kết quả: ${ok.join(", ")}.` : "", bad.length ? `Không gửi được:\n- ${bad.join("\n- ")}` : ""].filter(Boolean).join("\n") || "Chưa có tệp nào.";
}

/** Duyệt quyền khi làm việc được nhờ: hiện trong DM giữa bot và chủ bot, xoá khi đã quyết. */
async function askApprovalDM(req: ApprovalRequest, from: A2APeer, signal: AbortSignal, scope: string): Promise<ApprovalDecision> {
  if (isBypass(scope)) return "accept"; // chủ bot đã "luôn cho phép" việc này
  const owner = cfg.ownerUserIds[0];
  const props = (status: string) => ({ flygo_agent_owner: owner, flygo_agent_approval: { kind: req.kind, title: req.title, detail: req.detail, status } });
  const post = await mm.createPost({
    channel_id: await ownerDM(), root_id: "", props: props("pending"),
    message: `✋ **Cần Sếp duyệt** · việc @${from.username} nhờ qua A2A\n\`\`\`\n${req.title}\n\`\`\`${req.detail ? `\n${req.detail}` : ""}\nThả 👍/👎 để Xác nhận / Từ chối.`,
  });
  const d = await waitDecision(post.id, owner, signal, undefined, scope);
  await mm.patchPost(post.id, { props: props(approvalStatus(d)) }).catch(() => {});
  await mm.deletePost(post.id).catch(() => {});
  return d === "accept" || d === "always" ? "accept" : "decline";
}

async function runA2A(cid: string, from: A2APeer, msg: any, t: A2ATask, stream: boolean) {
  const { task, ac, dir } = t;
  const setState = (state: string, text?: string, final = false) => {
    task.status = { state, timestamp: iso(), ...(text ? { message: { kind: "message", role: "agent", messageId: crypto.randomUUID(), taskId: task.id, contextId: task.contextId, parts: [{ kind: "text", text }] } } : {}) };
    if (stream) a2a!.event(cid, { kind: "status-update", taskId: task.id, contextId: task.contextId, status: task.status, final });
  };
  const addArtifact = (artifact: any) => {
    task.artifacts.push(artifact);
    if (stream) a2a!.event(cid, { kind: "artifact-update", taskId: task.id, contextId: task.contextId, artifact, lastChunk: true });
  };
  const key = `a2a:${from.id}:${task.contextId}`;
  let session = getSession(key);
  if (session && session.engine !== ENGINE) session = null;
  const runId = crypto.randomUUID();
  try {
    if (ac.signal.aborted) throw new Error("đã huỷ");
    mkdirSync(dir, { recursive: true });
    for (const f of ["AGENTS.md", "CLAUDE.md"]) await Bun.write(join(dir, f), persona);
    const { texts, datas, files } = splitParts(msg.parts);
    const saved: string[] = [];
    for (const f of files) {
      try { saved.push(await saveFilePart(f, join(dir, "a2a-nhan", task.id.slice(0, 8)), relayBase, relayAuth)); }
      catch (e: any) { texts.push(`(không nhận được tệp ${f?.name ?? ""}: ${e?.message ?? e})`); }
    }
    const prompt = [
      session ? "" : `Agent @${from.username}${from.owner_name ? ` (trợ lý AI của ${from.owner_name})` : ""} nhờ bạn qua A2A (Agent2Agent). Bạn là agent được nhờ: không có nhóm chat, câu trả lời của bạn được chuyển lại cho agent đó. Làm đúng việc được nhờ, trả lời gọn và đủ ý. Cần gửi tệp kết quả thì dùng tool return_files.`,
      `## @${from.username} nhờ\n${texts.join("\n\n")}`,
      datas.length ? `\n## Dữ liệu kèm theo (JSON)\n${JSON.stringify(datas, null, 2).slice(0, 50_000)}` : "",
      saved.length ? `\n## Tệp kèm theo (đã lưu)\n${saved.map((p) => `- ${p}`).join("\n")}` : "",
    ].filter(Boolean).join("\n");
    const opts = agentOptions(cfg, botDesc);
    const ask = (req: ApprovalRequest) => askApprovalDM(req, from, ac.signal, key);
    runsByKey.set(runId, ask);
    a2aRuns.set(runId, t);
    setState("working");
    emit({ event: "a2a_task", task_id: task.id, from: from.username, status: "working" });
    const res = await engines[ENGINE].runTurn({
      sessionId: session?.session_id || undefined, cwd: dir, prompt, persona: botPersona(), ...skillDirs(),
      title: `A2A · @${from.username} · ${oneLine(texts[0] ?? "", 50)}`, group: `A2A · @${from.username}`,
      model: opts.default.model, effort: opts.default.effort, bypass: isBypass(key), // chỉ theo phạm vi của chính bot này, không kế thừa từ bên nhờ
      mcpEnv: mcpEnvFor(key, {
        MM_URL: cfg.serverUrl, MM_TOKEN: cfg.botToken, CHANNEL_ID: "", ROOT_ID: "",
        RUN_KEY: runId, WORKDIR: dir, OWNER_ID: cfg.ownerUserIds[0], A2A_ROLE: "callee",
      }),
    }, {
      step: (s) => { if (s.status === "running") setState("working", s.title); },
      text: () => {},
      approval: ask,
      ask: async () => ({ cancelled: true, reason: "Đang làm việc được nhờ qua A2A: không hỏi được người dùng. Tự quyết theo hướng hợp lý nhất và nói rõ trong câu trả lời." }),
      session: (id) => {
        session = session ?? { root_id: key, channel_id: "", engine: ENGINE, session_id: id, status: "running", title: `A2A @${from.username}`, card_post_id: "", last_seen_at: 0, updated_at: Date.now() };
        session.session_id = id; saveSession(session);
      },
    }, ac.signal);
    addArtifact({ artifactId: crypto.randomUUID(), name: "answer", parts: [{ kind: "text", text: res.text || "(không có câu trả lời)" }] });
    for (const f of t.files) {
      try { addArtifact({ artifactId: crypto.randomUUID(), name: basename(f), parts: [await toFilePart(a2a!, mm, cfg.botToken, ownerDM, f, from.id)] }); }
      catch (e: any) { addArtifact({ artifactId: crypto.randomUUID(), name: "file-error", parts: [{ kind: "text", text: `Không gửi được tệp ${basename(f)}: ${e?.message ?? e}` }] }); }
    }
    setState("completed", undefined, true);
  } catch (e: any) {
    const cancelled = ac.signal.aborted;
    setState(cancelled ? "canceled" : "failed", cancelled ? "đã huỷ" : String(e?.message ?? e).slice(0, 500), true);
    log(`a2a: việc @${from.username} nhờ ${cancelled ? "bị huỷ" : `lỗi: ${e?.message ?? e}`}`);
  } finally {
    runsByKey.delete(runId);
    a2aRuns.delete(runId);
    if (mcpCtx.get(key)?.RUN_KEY === runId) mcpCtx.delete(key);
    if (session) { session.status = task.status.state; session.updated_at = Date.now(); saveSession(session); }
    emit({ event: "a2a_task", task_id: task.id, from: from.username, status: task.status.state });
    a2a!.done(cid, stream ? null : task);
    a2aByCid.delete(cid);
    setTimeout(() => a2aTasks.delete(task.id), 3600_000).unref?.();
  }
}

// ---- kỹ năng & vai trò riêng của bot (src/skills.ts) ----
/** Claude: kỹ năng qua --add-dir (dựng lại mỗi lượt: lưu skill có hiệu lực từ lượt sau). Codex: danh sách trong khối ngữ cảnh. */
const skillDirs = () => { if (ENGINE !== "claude") return {}; const d = claudeSkillsDir(BOT_ID, cfg.skillsDir); return d ? { addDirs: [d] } : {}; };
interface SkillRun { assigner: string; ask: (req: ApprovalRequest) => Promise<ApprovalDecision>; dir: string }
const skillRuns = new Map<string, SkillRun>(); // run key -> lượt chat (A2A: không có)
async function skillTool(op: string, a: any): Promise<string> {
  const ctx = skillRuns.get(a.key);
  if (!ctx) return "Kỹ năng chỉ xem/sửa được trong lượt chat với người dùng.";
  if (op === "list") {
    const ks = listSkills(BOT_ID, cfg.skillsDir);
    const role = readRole(BOT_ID);
    return [`Vai trò: ${role ? roleLine(role) : "(chưa đặt)"}`, ks.length ? `Kỹ năng (${ks.length}):` : "Chưa có kỹ năng nào.", ...ks.map((k) => `- ${k.name}${k.source === "base" ? " (chung)" : ""}: ${k.description}`)].join("\n");
  }
  if (op === "read") return readSkill(BOT_ID, String(a.name ?? ""), cfg.skillsDir);
  if (!isOwner(ctx.assigner)) return "Chỉ chủ bot mới được sửa kỹ năng / vai trò của bot. Người được cho phép chỉ dùng được kỹ năng.";
  const approve = async (title: string, detail: string) => (await ctx.ask({ kind: "file", title, detail: detail.slice(0, 1500) })) === "accept";
  if (op === "save") {
    const name = String(a.name ?? "");
    const files: SkillFile[] = [];
    for (const f of Array.isArray(a.files) ? a.files.slice(0, 20) : []) {
      if (typeof f === "string") files.push({ path: basename(f), from: insideDir(ctx.dir, f) }); // tệp trong thư mục làm việc
      else if (f && typeof f.path === "string") files.push({ path: f.path, content: String(f.content ?? "") });
    }
    if (!(await approve(`Lưu kỹ năng "${name}"`, `${a.description ?? ""}\n\n${a.content ?? ""}${files.length ? `\n📎 ${files.map((f) => f.path).join(", ")}` : ""}`))) return "Chủ bot không duyệt, chưa lưu kỹ năng.";
    const k = saveSkill(BOT_ID, name, String(a.description ?? ""), String(a.content ?? ""), files);
    a2a?.setCard(a2aCard());
    log(`lưu kỹ năng ${k.name}`);
    return `Đã lưu kỹ năng "${k.name}" (${k.path}). Có hiệu lực từ lượt sau.`;
  }
  if (op === "delete") {
    const name = String(a.name ?? "");
    if (!listSkills(BOT_ID).some((k) => k.name === name)) return `Bot không có kỹ năng riêng tên "${name}" (kỹ năng chung không xoá được ở đây).`;
    if (!(await approve(`Xoá kỹ năng "${name}"`, readSkill(BOT_ID, name)))) return "Chủ bot không duyệt, chưa xoá.";
    deleteSkill(BOT_ID, name);
    a2a?.setCard(a2aCard());
    log(`xoá kỹ năng ${name}`);
    return `Đã xoá kỹ năng "${name}".`;
  }
  if (op === "role") {
    const text = String(a.text ?? "").trim();
    if (!(await approve(text ? "Đặt vai trò của bot" : "Xoá vai trò của bot", text || "(bỏ vai trò)"))) return "Chủ bot không duyệt, chưa đổi vai trò.";
    setRole(BOT_ID, text);
    a2a?.setCard(a2aCard());
    const marked = await markRole(text);
    log(`đặt vai trò: ${roleLine(text)}`);
    return `Đã ${text ? "đặt" : "xoá"} vai trò. Có hiệu lực từ lượt sau.${marked ? "" : " (Chưa ghi được mốc role= vào mô tả bot: bot không tự sửa mô tả được, đặt vai trò trên app để hiện.)"}`;
  }
  return `Không có thao tác ${op}.`;
}
/** Mốc role=<slug> trong mô tả bot (giữ các thuộc tính khác). Trả về true nếu mô tả đã đúng hoặc sửa được. */
async function markRole(role: string) {
  const slug = roleSlug(role);
  const cur = /\[flygo-agent([^\]]*)\]/i.exec(botDesc);
  const attrs = (cur?.[1] ?? ` engine=${ENGINE}`).replace(/\s+role=\S+/i, "") + (slug ? ` role=${slug}` : "");
  const desc = cur ? botDesc.replace(cur[0], `[flygo-agent${attrs}]`) : `${botDesc} [flygo-agent${attrs}]`.trim();
  if (desc === botDesc) return true;
  const ok = await mm.api("PUT", `/bots/${BOT_ID}`, { description: desc }).then(() => true, () => false);
  if (ok) botDesc = desc;
  return ok;
}

// ---- xử lý tin ----
const queues = new Map<string, Promise<void>>();
const mainKey = (channelId: string) => `ch:${channelId}`; // phiên chat chính của kênh
const openThread = (post: Post) => !post.root_id && isTrue(post.props?.flygo_open_thread);
/** Luồng bot trả lời vào: luồng của tin, hoặc luồng mới dưới tin "Mở luồng riêng"; rỗng = chat chính. */
/** Trả lời trích dẫn ở chat chính: props.flygo_reply="quote" (app từ build 84). App cũ không gửi flygo_reply:
 *  coi là trích dẫn nếu tin gốc là câu trả lời ở chat chính của chính bot (có flygo_agent) và chưa có luồng (chỉ có tin này). */
async function isMainQuote(post: Post) {
  const fr = post.props?.flygo_reply;
  if (fr === "quote") return true;
  if (fr !== undefined && fr !== "") return false;
  const thread = await mm.thread(post.root_id).catch(() => [] as Post[]);
  const root = thread.find((p) => p.id === post.root_id);
  return !!root && root.user_id === BOT_ID && !!root.props?.flygo_agent && thread.every((p) => p.id === root.id || p.id === post.id);
}
const isMainPost = (p: Post) => !p.root_id || p.props?.flygo_reply === "quote"; // tin thuộc chat chính (kể cả trả lời trích dẫn)
const threadRootOf = (post: Post) => post.root_id || (openThread(post) ? post.id : "");
const MAIN_IDLE_MS = cfg.mainIdleHours > 0 ? cfg.mainIdleHours * 3600_000 : Infinity; // mặc định: không tự mở phiên mới
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

/** Chat AI riêng: bot nhận tin không tag. Cùng một kết quả ở mọi runner (chỉ dựa vào dữ liệu trên server). */
async function aiResponder(post: Post): Promise<string | null> {
  const m = await channelMembers(post.channel_id);
  const bots: any[] = [];
  for (const id of m.bots) { const u = await mm.user(id); if (/\[flygo-agent/i.test(u.bot_description ?? "")) bots.push(u); }
  if (!bots.length) return null;
  const lastAnswer = (ps: Post[]) => [...ps].reverse().find((p) => p.id !== post.id && p.props?.flygo_agent_message && bots.some((b) => b.id === p.user_id))?.user_id;
  if (post.root_id) { const t = lastAnswer(await mm.thread(post.root_id).catch(() => [] as Post[])); if (t) return t; }
  const main = lastAnswer((await mm.channelPosts(post.channel_id, 100).catch(() => [] as Post[])).filter(isMainPost));
  if (main) return main;
  return bots.sort((a, b) => (a.create_at ?? 0) - (b.create_at ?? 0) || String(a.id).localeCompare(b.id))[0].id;
}

/** Tin này có giao cho bot mà không cần @tag không? */
async function implicitTrigger(post: Post, channelType: string): Promise<boolean> {
  if (channelType === "D") return true; // DM với bot: 1 người + bot
  const m = await channelMembers(post.channel_id);
  if (onlyMeAnd(m.humans, m.bots, post.user_id)) return true; // kênh/nhóm/luồng riêng chỉ có người này + bot
  if (!post.root_id) return false; // chat chính của kênh nhiều người/nhiều bot: phải @tag
  const p = await threadParticipants(post.root_id);
  return onlyMeAnd(p.humans, p.bots, post.user_id);
}

// ---- bảo mật: bot chạy trên máy của chủ -> chỉ chủ được nhắn riêng; ở nhóm phải có chủ trong nhóm ----
const refusedAt = new Map<string, number>(); // khoá -> lần trả lời từ chối gần nhất (chống spam / vòng lặp giữa bot)
const once = (key: string, ms: number) => { const t = refusedAt.get(key) ?? 0; if (Date.now() - t < ms) return false; refusedAt.set(key, Date.now()); return true; };
const DM_REFUSE = "Em chỉ nhận việc từ chủ của em trong tin nhắn riêng. Hãy nhắn trong nhóm có chủ em.";
const NO_OWNER_REFUSE = "Chủ của em không ở trong nhóm này nên em không nhận việc ở đây.";
const ownerIn = async (channelId: string) => (await channelMembers(channelId)).humans.some(isOwner);
async function refuse(post: Post, why: string, reply: string, notifyOwner: boolean) {
  const who = await mm.user(post.user_id).catch(() => ({ username: post.user_id }));
  const ch = await mm.channel(post.channel_id).catch(() => ({ display_name: post.channel_id, type: "?" }));
  log(`từ chối (${why}): @${who.username} (${post.user_id}) ở kênh ${ch.display_name || ch.name || post.channel_id} (${post.channel_id}, loại ${ch.type}), tin ${post.id}`);
  if (!who.is_bot && once(`r:${post.channel_id}`, 6 * 3600_000)) // không trả lời bot khác (tránh vòng lặp); vẫn báo chủ
    await mm.createPost({ channel_id: post.channel_id, root_id: post.root_id, message: reply, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } }).catch(() => {});
  if (notifyOwner && once(`n:${post.channel_id}:${post.user_id}`, 30 * 60_000)) {
    const where = ch.type === "D" ? "tin nhắn riêng với em" : ch.type === "G" ? `nhóm nhắn tin "${ch.display_name || ch.name}"` : `nhóm "${ch.display_name || ch.name}"`;
    await mm.createPost({ channel_id: await ownerDM(), root_id: "", message: `⚠️ @${who.username} vừa gọi em trong ${where} (kênh ${post.channel_id}) nhưng ${why === "dm" ? "chỉ Sếp được nhắn riêng với em" : "Sếp không ở trong nhóm đó"}, nên em không nhận việc.\n> ${oneLine(post.message, 200)}`, props: { flygo_agent_owner: cfg.ownerUserIds[0] } }).catch(() => {});
  }
}

async function onPosted(post: Post, channelType: string) {
  if (post.type && post.type !== "") return;
  await trackPost(post).catch(() => {});
  if (post.user_id === BOT_ID) return;
  if (post.props?.flygo_thread_closed !== undefined) return onCloseMarker(post);
  if (onQuestionPost(post)) return; // trả lời câu bot đang hỏi (ý khác / props trả lời): không mở lượt mới
  // Tin "Bắt đầu công việc trong luồng riêng tư" ở chat chính: app tạo kênh luồng riêng và chép tin sang đó;
  // bot chỉ trả lời trong kênh luồng riêng, KHÔNG BAO GIỜ trả lời tin gốc này (kể cả có @tag hay quy tắc 1 người + 1 bot).
  if (post.props?.flygo_private_thread === true || post.props?.flygo_private_thread === "true") return;
  // Tin nhắn riêng: chỉ chủ bot (danh sách allow không còn được nhắn riêng). Nhóm nhắn tin (G) không có chủ: như vậy.
  if (channelType === "D" && !isOwner(post.user_id)) return refuse(post, "dm", DM_REFUSE, true);
  if (channelType === "G" && !isOwner(post.user_id) && !(await ownerIn(post.channel_id))) {
    if (mentionRe.test(post.message)) { mentionRe.lastIndex = 0; return refuse(post, "dm", DM_REFUSE, true); }
    mentionRe.lastIndex = 0;
    return;
  }
  // Trả lời trích dẫn ở chat chính (app gửi root_id = tin được trích): coi là tin chat chính, không mở luồng.
  if (post.root_id && (await isMainQuote(post))) { (post as any).quote_of = post.root_id; post.root_id = ""; }
  // Khoá phiên/hàng đợi: tin trong luồng -> root_id; tin ở chat chính -> cả kênh (bot trả lời ngay ở chat chính, không tạo luồng).
  // Tin ở chat chính có props.flygo_open_thread ("Mở luồng riêng" trên app): bot trả lời trong luồng dưới chính tin đó.
  const root = threadRootOf(post) || mainKey(post.channel_id);
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
  // Tin tag từ 2 agent trở lên: agent tag ĐẦU TIÊN chủ trì (trả lời trong chat, nhờ các agent kia qua A2A); agent khác im lặng.
  const tagged = mentioned ? await taggedAgents(post.message) : [];
  if (tagged.length >= 2 && tagged[0].id !== BOT_ID) return;
  (post as any).a2a_peers = tagged.filter((t) => t.id !== BOT_ID).map((t) => t.username);
  // Chat AI riêng (cột phải) nhiều bot: tin không tag bot nào -> bot trả lời gần nhất (trong luồng / chat đó) nhận; chưa ai thì bot tạo sớm nhất.
  let aiPick = false;
  if (!mentioned && allowed && aiOf(await mm.channel(post.channel_id))) {
    if ((await taggedAgents(post.message)).length) return; // tag bot khác: bot đó trả lời
    aiPick = (await aiResponder(post)) === BOT_ID;
    if (!aiPick) return;
  }
  if (!mentioned && !aiPick && !(allowed && (await implicitTrigger(post, channelType)))) return;
  // Nhóm / kênh: chủ bot phải ở trong nhóm (thấy được bot đang làm gì). A2A đi qua relay, không qua đây.
  if (!isOwner(post.user_id) && !(await ownerIn(post.channel_id))) return refuse(post, "owner_absent", NO_OWNER_REFUSE, true);
  const proj = /^(?:dự án|du an|project)(?:\s+(.+))?$/i.exec(text);
  if (proj && isOwner(post.user_id)) return projectCommand(post, proj[1]?.trim() ?? "");
  if (/^(tắt luôn cho phép|tat luon cho phep|bật lại duyệt|bat lai duyet)[.!]?$/i.test(text) && isOwner(post.user_id)) {
    const was = isBypass(root);
    if (was) setBypass(root, false);
    const where = post.root_id ? "luồng này" : "chat này";
    await mm.createPost({ channel_id: post.channel_id, root_id: post.root_id, message: was ? `🔒 Đã bật lại duyệt cho ${where}: từ lượt sau em sẽ xin Sếp duyệt như bình thường.` : `${where[0].toUpperCase()}${where.slice(1)} đang duyệt bình thường, không bật "Luôn cho phép".`, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } });
    return;
  }
  if (await isClosed(post)) return; // luồng đã đóng: không nhận việc mới (mở lại thì nhận bình thường)

  if (!allowed) {
    const owners = await Promise.all(cfg.ownerUserIds.map((id) => mm.user(id).then((u) => `@${u.username}`)));
    await mm.createPost({ channel_id: post.channel_id, root_id: post.root_id, message: `Em là trợ lý riêng của ${owners.join(", ")}, em chỉ nhận việc từ những người được chủ của em cho phép ạ.`, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } });
    return; // tin của người khác chỉ là ngữ cảnh
  }
  enqueue(root, () => runTurn(post, root, text));
}

/** "@bot dự án <path>" (gắn), "dự án bỏ" (gỡ), "dự án" (xem) — chỉ chủ bot. Kênh bí mật thì áp cho chat cha. */
async function projectCommand(post: Post, arg: string) {
  const ch = await mm.channel(post.channel_id);
  const base = await topChat(ch);
  let msg: string;
  if (/^(bỏ|bo|gỡ|go|off|none)$/i.test(arg)) {
    db.query("DELETE FROM projects WHERE channel_id = ?").run(base.id);
    msg = "Đã gỡ thư mục code, chat này dùng lại thư mục làm việc riêng.";
  } else if (arg) {
    const real = allowedProject(arg);
    if (real) { db.query("INSERT OR REPLACE INTO projects VALUES (?, ?)").run(base.id, real); msg = `Đã gắn chat này với thư mục \`${real}\`. Các phiên sau làm việc trong thư mục đó.`; }
    else msg = `Không gắn được \`${arg}\`: thư mục không tồn tại hoặc không nằm trong ${cfg.projectRoots.length ? cfg.projectRoots.map((r) => `\`${r}\``).join(", ") : "danh sách cho phép (projectRoots trong cấu hình runner đang trống)"}.`;
  } else {
    const cur = await boundProject(base);
    msg = cur ? `Chat này đang gắn thư mục \`${cur}\`.` : "Chat này chưa gắn thư mục code. Gắn bằng: dự án ~/dev/<thư mục>";
  }
  await mm.createPost({ channel_id: post.channel_id, root_id: post.root_id, message: msg, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } });
}

// ---- báo cáo ra ngoài: lượt trong luồng / kênh bí mật gửi báo cáo ra chat chính của nhóm ngoài ----
interface Outer { secret: boolean; ai?: boolean; channelId: string; name: string; rootId: string; rootText: string; label: string; top?: string }
/** Nhóm ngoài của lượt: luồng mở -> chính kênh đó; kênh bí mật [flygo-sub parent=… root=…] -> kênh cha. */
async function outerOf(ch: any, threadRoot: string, threadTitle: string): Promise<Outer | null> {
  const ai = aiOf(ch);
  if (ai) { // chat AI riêng: "ra ngoài" = chat chính của nhóm gắn, luôn phải duyệt (nhóm không thấy chat này)
    const g = await mm.channel(ai.group).catch(() => null);
    if (!g) return null;
    const top = linkOf(g) ? await topChat(g) : null;
    return { secret: true, ai: true, channelId: g.id, name: await chatName(g), rootId: threadRoot, rootText: "", label: threadRoot ? `${threadTitle} · chat AI riêng` : "Chat AI riêng", top: top ? await chatName(top) : undefined };
  }
  const m = /\[flygo-sub parent=(\w+) root=(\w+)\]/.exec(ch.purpose ?? "");
  if (m) {
    const parent = await mm.channel(m[1]).catch(() => null);
    if (!parent) return null;
    const rp = await mm.api<Post>("GET", `/posts/${m[2]}`).catch(() => null);
    const top = subParentOf(parent) ? await topChat(parent) : null; // nhóm cha cũng là luồng bí mật: nêu cả nhóm gốc
    return { secret: true, channelId: parent.id, name: await chatName(parent), rootId: m[2], rootText: rp?.message ?? "", label: ch.display_name || "Luồng riêng", top: top ? await chatName(top) : undefined };
  }
  if (!threadRoot) return null;
  const rp = await mm.api<Post>("GET", `/posts/${threadRoot}`).catch(() => null);
  return { secret: false, channelId: ch.id, name: await chatName(ch), rootId: threadRoot, rootText: rp?.message ?? "", label: threadTitle };
}
interface ReportRun { outer: Outer; card: RunCard; reply: InlineReply; assigner: string; channelId: string; postId: string; dir: string; signal: AbortSignal; sent: number }
const reportRuns = new Map<string, ReportRun>(); // run key
const REPORT_TIMEOUT_MS = 30 * 60_000;

async function uploadTo(channelId: string, path: string): Promise<string> {
  if (Bun.file(path).size > INLINE_MAX) return uploadLarge(mm, cfg.botToken, channelId, path); // tệp lớn: từng khúc (Cloudflare cắt request dài)
  const form = new FormData();
  form.append("channel_id", channelId);
  form.append("files", Bun.file(path), basename(path));
  const r = await fetch(`${mm.url}/api/v4/files`, { method: "POST", headers: { Authorization: `Bearer ${cfg.botToken}` }, body: form });
  if (!r.ok) throw new Error(`tải lên lỗi ${r.status} ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).file_infos[0].id;
}

async function reportOut(a: any): Promise<string> {
  const ctx = reportRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  const { outer, card } = ctx;
  const message = String(a.message ?? "").trim();
  if (!message) return "Thiếu nội dung báo cáo.";
  if (ctx.sent >= 3) return "Đã gửi báo cáo ra ngoài 3 lần trong lượt này.";
  const paths: string[] = [], bad: string[] = [];
  for (const f of Array.isArray(a.files) ? a.files.slice(0, 10) : []) {
    try { paths.push(insideDir(ctx.dir, String(f))); } catch (e: any) { bad.push(`${f}: ${e?.message ?? e}`); }
  }
  if (bad.length) return `Chưa gửi báo cáo vì tệp lỗi:\n- ${bad.join("\n- ")}`;
  const names = paths.map((p) => basename(p));
  const sid = `report-${crypto.randomUUID().slice(0, 8)}`;
  const title = `Báo cáo ra ngoài → ${outer.name}`;
  const detail = message + (names.length ? `\n📎 ${names.join(", ")}` : "");
  if (outer.secret) {
    // Luồng bí mật: nội dung sắp lộ ra nhóm ngoài -> người giao việc hoặc chủ bot duyệt đúng văn bản này.
    card.step({ id: sid, kind: "approval", title: `${title} (chờ duyệt)`, status: "waiting", detail });
    card.setStatus("awaiting_approval");
    await card.flush();
    const d = await askApprovalInline(ctx.reply, { kind: "report", title, detail }, ctx.assigner, ctx.signal, REPORT_TIMEOUT_MS);
    card.setStatus("running");
    if (d !== "accept") {
      card.step({ id: sid, kind: "approval", title: `${title} (${d === "expired" ? "hết hạn" : "bị từ chối"})`, status: "error", detail });
      return d === "expired" ? "Không ai duyệt trong 30 phút nên báo cáo hết hạn, chưa gửi ra ngoài." : "Báo cáo ra ngoài bị từ chối, không gửi. Đừng gửi lại trừ khi được yêu cầu.";
    }
  } else card.step({ id: sid, kind: "tool", title, status: "running", detail });
  try {
    const fileIds: string[] = [];
    for (const p of paths) fileIds.push(await uploadTo(outer.channelId, p));
    const share = outer.ai ? { flygo_ai_report: { channel_id: ctx.channelId, post_id: ctx.postId } }
      : outer.secret ? { flygo_sub_report: { channel_id: ctx.channelId, post_id: ctx.postId } } : { flygo_thread_share: { root_id: outer.rootId, post_id: ctx.postId } };
    await mm.createPost({
      channel_id: outer.channelId, root_id: "", file_ids: fileIds,
      message: outer.ai ? `📋 Báo cáo từ trợ lý @${BOT_NAME}\n\n${message}` : `📋 Báo cáo từ luồng "${outer.label}"\n\n${message}`,
      props: { ...share, flygo_agent_owner: ctx.assigner, flygo_agent_report: true },
    });
  } catch (e: any) {
    card.step({ id: sid, kind: outer.secret ? "approval" : "tool", title: `${title} (lỗi)`, status: "error", detail: `${detail}\n\n❌ ${e?.message ?? e}` });
    return `Gửi báo cáo ra ngoài lỗi: ${e?.message ?? e}`;
  }
  ctx.sent++;
  card.step({ id: sid, kind: outer.secret ? "approval" : "tool", title: `${title} (đã gửi)`, status: "done", detail });
  return `Đã gửi báo cáo ra chat chính của ${outer.name}${names.length ? ` kèm ${names.join(", ")}` : ""}.`;
}

// ---- khối ngữ cảnh: vị trí trong cây nhóm, các ID, công cụ ----
const clip = (t: string, n: number) => oneLine(t, n);
const teamChans = new Map<string, { at: number; list: any[] }>(); // team -> kênh bot là thành viên (60s)
async function botChannels(teamId: string, fresh = false) {
  const c = teamChans.get(teamId);
  if (!fresh && c && Date.now() - c.at < 60_000) return c.list;
  const list = await mm.api<any[]>("GET", `/users/${BOT_ID}/teams/${teamId}/channels`).catch(() => []);
  teamChans.set(teamId, { at: Date.now(), list });
  return list;
}
/** Luồng bí mật con trực tiếp (bot là thành viên) và luồng mở gần đây của kênh: chỉ để biết, không đọc được. */
async function childrenOf(ch: any) {
  const secret = ch.team_id ? (await botChannels(ch.team_id)).filter((c) => subParentOf(c) === ch.id && !/\[flygo-closed\]/.test(c.purpose ?? "")).slice(0, 8) : [];
  const posts = await mm.channelPosts(ch.id, 100).catch(() => [] as Post[]);
  const open = posts.filter((p) => !p.root_id && !isTrue(p.props?.flygo_private_thread) && ((p as any).reply_count > 0 || isTrue(p.props?.flygo_open_thread)))
    .slice(-6).reverse();
  return { secret, open };
}
async function contextBlock(o: { ch: any; chain: Level[]; threadRoot: string; assigner: any; report: boolean }) {
  const { ch, chain, threadRoot } = o;
  const n = chain.length - 1;
  const kids = await childrenOf(ch);
  const tree: string[] = [];
  chain.forEach((l, i) => {
    const pad = i ? "  ".repeat(i - 1) + "└ " : "";
    tree.push(`  ${pad}Tầng ${l.tier} · ${l.kind === "ai" ? "chat AI riêng " : ""}"${l.name}" (id ${l.id})${i === 0 && n ? " — nhóm gốc" : ""}${l.rootId ? ` — tách từ tin ${l.rootId}: "${clip(l.rootText, 120)}"` : ""}${i === n ? " ← đang ở đây" : ""}`);
  });
  const kpad = "  " + "  ".repeat(n);
  const kidLines = [
    ...kids.secret.map((c) => `luồng bí mật con: "${c.display_name}" (id ${c.id})`),
    ...kids.open.map((p) => `luồng mở: "${clip(p.message.replace(mentionRe, ""), 60)}" (root_id ${p.id})${p.id === threadRoot ? " ← đang ở đây" : ""}`),
  ];
  mentionRe.lastIndex = 0;
  kidLines.forEach((t, i) => tree.push(`${kpad}${i === kidLines.length - 1 ? "└" : "├"} ${t}`));
  const isAi = chain[n].kind === "ai";
  const ai = aiOf(ch);
  const chanHelp = n
    ? `channel = ${isAi ? `"group" (= "parent", nhóm "${chain[n - 1].name}" id ${chain[n - 1].id}), ` : `"parent" (id ${chain[n - 1].id}), `}"top" (id ${chain[0].id}), "top" (id ${chain[0].id}), số tầng 0…${n}, hoặc id một tầng trong cây; bỏ trống = kênh hiện tại. Chỉ ĐỌC được kênh hiện tại và các tầng trên (bot phải là thành viên); luồng con chỉ để biết, không đọc.`
    : isAi ? `Chưa đọc được nhóm gắn với chat AI này (bot chưa là thành viên nhóm): bỏ trống channel.`
    : `Nhóm này không phải luồng bí mật: không có tầng trên, bỏ trống channel. Luồng con trong cây chỉ để biết.`;
  const aiOwner = ai?.owner ? await mm.displayName(ai.owner).catch(() => "chủ") : o.assigner.username;
  const role = readRole(BOT_ID);
  const ks = listSkills(BOT_ID, cfg.skillsDir);
  const owner = isOwner(o.assigner.id);
  return [
    role ? `Bạn là trợ lý ${roleLine(role)} (@${BOT_NAME}).` : "",
    `## Vị trí & ID`,
    `- Bot (bạn): @${BOT_NAME} (user id ${BOT_ID}) · Người giao việc: @${o.assigner.username} (user id ${o.assigner.id})`,
    ch.team_id ? `- Team id ${ch.team_id}` : "",
    ai ? `- Đây là chat riêng của ${aiOwner} với trợ lý, gắn với nhóm "${n ? chain[n - 1].name : ai.group}" (id ${ai.group}); chỉ ${aiOwner} (và các bot của họ) thấy. Đọc nhóm bằng channel="group". KHÔNG gửi gì vào nhóm trừ khi ${aiOwner} yêu cầu rõ (chat_report_out, cần duyệt). Tin mở đầu bằng trích dẫn "> **Tên:** …" là đang hỏi về tin đó của nhóm: tìm bằng chat_search(terms, channel="group") nếu cần thêm ngữ cảnh.` : "",
    `- Cây nhóm${n && !isAi ? ` (bạn ở luồng bí mật tầng ${n}: ${chain.map((l) => l.name).join(" › ")})` : ""}:`,
    ...tree,
    `- Kênh hiện tại: id ${ch.id}; ${threadRoot ? `chủ đề hiện tại: root_id ${threadRoot}` : "đang ở chat chính (không trong chủ đề)"}`,
    n && !isAi ? `- Thông tin chỉ đi vào trong: các tầng trên không thấy luồng này; không gửi gì lên trên trừ chat_report_out.` : "",
    `## Công cụ flygo_chat`,
    `- chat_history(limit?, before_post_id?, channel?) · chat_thread(root_id?, channel?) · chat_search(terms, channel?)`,
    `- chat_files(scope?: thread|channel, root_id?, channel?) · chat_read_file(file_id, channel?) · chat_info() · chat_ancestors()`,
    `- chat_send_files(paths, message?): gửi tệp vào chủ đề hiện tại`,
    o.report ? `- chat_report_out(message, files?): báo cáo ra ${n ? `${isAi ? "chat chính của nhóm" : `tầng ${n - 1}`} "${chain[n - 1].name}" (cần duyệt)` : "chat chính của nhóm"}, chỉ khi được yêu cầu` : "",
    a2a ? `- list_agents() · ask_agent(bot, message, files?, data?): nhờ agent khác qua A2A` : "",
    `- skill_list() · skill_read(name)${owner ? ` · skill_save(name, description, content, files?) · skill_delete(name) · role_set(text): sửa kỹ năng / vai trò của bot (người giao việc là chủ bot; lưu/xoá cần duyệt, có hiệu lực từ lượt sau)` : " (chỉ chủ bot sửa được kỹ năng / vai trò)"}`,
    `- ${chanHelp}`,
    ks.length ? `## Kỹ năng của bạn${ENGINE === "claude" ? " (dùng qua tool Skill)" : " (cần thì đọc SKILL.md theo đường dẫn rồi làm theo)"}` : "",
    ...ks.slice(0, 15).map((k) => `- ${k.name}: ${clip(k.description, 140)}${ENGINE === "claude" ? "" : ` — ${k.path}`}`),
    ks.length > 15 ? `- … còn ${ks.length - 15} kỹ năng, xem bằng skill_list()` : "",
    existsSync(memoryPath(BOT_ID)) ? `Ghi nhớ lâu dài của bot: ${memoryPath(BOT_ID)} (đọc khi cần).` : "",
  ].filter(Boolean).join("\n");
}
/** Khối ngữ cảnh: lượt đầu của phiên luôn đưa; lượt sau chỉ đưa khi đổi. */
function blockIfChanged(root: string, block: string, first: boolean) {
  const h = createHash("sha256").update(block).digest("hex").slice(0, 16);
  const seen = (db.query("SELECT hash FROM ctx_seen WHERE root_id = ?").get(root) as { hash: string } | null)?.hash;
  if (!first && seen === h) return "";
  db.query("INSERT OR REPLACE INTO ctx_seen VALUES (?, ?)").run(root, h);
  return first ? block : `${block}\n(Vị trí/ID ở trên vừa thay đổi so với lần trước.)`;
}

// ---- fork phiên chính của chat CHA TRỰC TIẾP cho lượt đầu của luồng / luồng bí mật / chat AI riêng ----
// Tách từ phiên CHÍNH (tiền tố ổn định -> trúng prompt cache); phiên cha gần đầy thì để engine tự nén sau khi tách.
// Không có phiên cha (cùng bot) thì mở phiên mới, không lần lên cao hơn. Không bao giờ tách từ chat AI riêng ra chỗ dùng chung.
/** Phiên để fork. Hai cây không bao giờ chéo nhau:
 *  - cột chính: luồng mở -> chat chính của kênh; luồng bí mật tầng N -> chat chính của tầng N-1;
 *  - cột AI: chat AI riêng gắn kênh X -> chat AI riêng (cùng chủ, bot là thành viên) gắn kênh CHA của X; X là nhóm gốc -> mở mới.
 *  Luồng trong kênh bất kỳ -> chat chính của chính kênh đó. */
async function parentKeyOf(ch: any, threadRoot: string) {
  if (threadRoot) return mainKey(ch.id);
  const l = linkOf(ch);
  if (!l) return "";
  if (l.kind === "ai") {
    const ai = aiOf(ch)!;
    const x = await mm.channel(ai.group).catch(() => null);
    const xl = linkOf(x);
    if (!xl || xl.kind !== "secret") return ""; // chat AI của nhóm gốc: không có chat AI cha
    // Thường chỉ có một chat AI cho mỗi (nhóm, chủ); lỡ có nhiều thì lấy chat có phiên của bot này dùng gần nhất.
    const cands = (await botChannels(ch.team_id, true)).filter((c) => { const a = aiOf(c); return !!a && c.id !== ch.id && a.group === xl.parent && a.owner === ai.owner; });
    const best = cands.map((c) => getSession(mainKey(c.id))).filter((x): x is Session => !!x?.session_id).sort((a, b) => b.updated_at - a.updated_at)[0];
    return best ? best.root_id : "";
  }
  if (l.kind === "secret" && aiOf(await mm.channel(l.parent).catch(() => null))) return ""; // cha là chat AI riêng: không tách ra
  return mainKey(l.parent);
}

/** Chat AI riêng: tin chat chính của nhóm gắn từ lần trước (lượt đầu: các tin gần nhất), để nắm tình hình nhóm. */
async function groupNews(outer: Outer, root: string, first: boolean): Promise<string> {
  const gid = outer.channelId;
  const member = (await channelMembers(gid).catch(() => null))?.bots.includes(BOT_ID);
  if (!member) return `\n## Nhóm "${outer.name}"\n(Bạn chưa là thành viên nhóm này nên chưa đọc được tin của nhóm. Nhờ chủ thêm bạn vào nhóm.)`;
  const since = first ? 0 : (db.query("SELECT ts FROM group_seen WHERE root_id = ?").get(root) as { ts: number } | null)?.ts ?? 0;
  const posts = (await mm.channelPosts(gid, 100).catch(() => [] as Post[]))
    .filter((p) => isMainPost(p) && !p.props?.flygo_agent_message?.streaming && p.create_at > since);
  if (posts.length) db.query("INSERT OR REPLACE INTO group_seen VALUES (?, ?)").run(root, posts[posts.length - 1].create_at);
  const N = 30, shown = posts.slice(-N);
  const text = await fmtPosts(shown);
  if (!text) return first ? `\n## Chat chính nhóm "${outer.name}"\n(chưa có tin)` : "";
  return `\n## ${first ? "Tin gần đây" : "Tin mới"} ở chat chính nhóm "${outer.name}" (id ${gid}) — chỉ để nắm tình hình${posts.length > N ? `; còn ${posts.length - N} tin cũ hơn, đọc bằng chat_history(channel="group")` : ""}\n${text}`;
}

async function runTurn(post: Post, root: string, rawText: string) {
  if (await isClosed(post)) return; // đóng trong lúc đang xếp hàng
  const threadRoot = threadRootOf(post);
  const inline = !threadRoot; // trả lời ở chat chính
  let session = getSession(root);
  const brandNew = !session; // chưa từng có phiên cho khoá này (lượt đầu của luồng / kênh)
  // Chat chính: nghỉ quá lâu thì mở phiên mới (tránh ngữ cảnh phình mãi).
  if (session && inline && Date.now() - session.updated_at > MAIN_IDLE_MS) session = null;
  const engineName: EngineName = ENGINE;
  let text = rawText;
  if (session && session.engine !== ENGINE) session = null; // phiên cũ của engine khác (trước khi gắn cố định): mở phiên mới
  if (!text) text = "(Sếp gọi em nhưng chưa nói việc gì — hãy hỏi lại Sếp cần gì.)";
  if ((post as any).resume) text = `(Lượt trước cho việc này bị dừng giữa chừng vì trợ lý khởi động lại. Làm tiếp: kiểm tra những gì đã làm xong rồi làm nốt, đừng làm lại từ đầu những bước đã xong.)\n${text}`;

  const { dir, ch, chat } = await workspaceFor(post.channel_id);
  // Tên phiên: "<chat> · <luồng>" — luồng = dòng đầu tin gốc; kênh bí mật = tên kênh; chat chính = "Luồng chính".
  const owner = await mm.displayName(post.user_id);
  // Trả lời trích dẫn: kèm nội dung tin được trích.
  let quoteNote = "";
  if ((post as any).quote_of) {
    const q = await mm.api<Post>("GET", `/posts/${(post as any).quote_of}`).catch(() => null);
    if (q?.message) quoteNote = `\n(${owner} đang trả lời tin của ${q.user_id === BOT_ID ? "bạn" : await mm.displayName(q.user_id)}: "${q.message.slice(0, 1500)}")`;
  }
  const firstLine = (t: string) => t.replace(mentionRe, "").replace(/\s+/g, " ").trim().slice(0, 60).trim();
  mentionRe.lastIndex = 0;
  const threadTitle = threadRoot
    ? firstLine(threadRoot === post.id ? post.message : (await mm.api<Post>("GET", `/posts/${threadRoot}`).catch(() => post)).message) || "Luồng"
    : subParentOf(ch) ? `Bí mật · ${ch.display_name}` : aiOf(ch) ? "Chat AI riêng" : "Luồng chính";
  const sessTitle = `${chat} · ${threadTitle}`;
  const peers: string[] = (post as any).a2a_peers ?? [];
  const peerNote = peers.length && a2a
    ? `\n(Tin này tag thêm ${peers.map((u) => `@${u}`).join(", ")}. Bạn là agent chủ trì: nhờ các agent đó bằng tool ask_agent (A2A, tối đa ${cfg.a2a.maxCalls} lần), tổng hợp kết quả rồi trả lời trong chat. Các agent kia không tự trả lời trong chat.)`
    : "";
  const outer = await outerOf(ch, threadRoot, threadTitle);
  const reportNote = outer?.ai
    ? `\n(Đây là chat AI riêng: nhóm "${outer.name}" không thấy. Chỉ khi người giao việc yêu cầu rõ mới gửi vào nhóm, bằng chat_report_out (cần duyệt).)`
    : outer
    ? `\n(Có tool chat_report_out để gửi báo cáo ra chat chính của ${outer.secret ? "nhóm cha" : "nhóm"} "${outer.name}". Chỉ dùng khi người giao việc yêu cầu báo cáo ra ngoài (vd. "xong thì báo cáo ra ngoài", "gửi báo cáo ra nhóm") hoặc đã dặn trước là xong thì báo.${outer.secret ? " Đây là luồng bí mật: báo cáo cần người giao việc duyệt trước khi gửi, chỉ đưa vào nội dung được phép công khai cho nhóm ngoài." : ""})`
    : "";
  const outerCtx = outer?.ai ? await groupNews(outer, root, !session) : outer
    ? `\n## Nhóm ngoài\n${outer.secret ? `Bạn đang ở luồng bí mật "${outer.label}" (kênh riêng, nhóm ngoài không thấy), tách từ ${outer.top ? `luồng bí mật "${outer.name}" (id ${outer.channelId}) thuộc nhóm gốc "${outer.top}"` : `nhóm "${outer.name}" (id ${outer.channelId})`}. Báo cáo ra ngoài chỉ lên một tầng: tới "${outer.name}".` : `Bạn đang ở trong luồng "${outer.label}" của nhóm "${outer.name}" (id ${outer.channelId}); chat chính của nhóm nằm ngoài luồng.`}\nTin gốc (id ${outer.rootId}): ${outer.rootText.slice(0, 1500) || "(không đọc được)"}`
    : "";
  // Lượt đầu của luồng / luồng bí mật: tách phiên cha (cùng bot, cùng engine) để mang theo hiểu biết. Chỉ chảy vào trong.
  let forkFrom = "", forkNote = "";
  const pkey = brandNew ? await parentKeyOf(ch, threadRoot) : "";
  const parent = pkey ? getSession(pkey) : null;
  if (parent?.session_id && parent.engine === ENGINE) {
    const pch = pkey.slice(3);
    const pname = pch === ch.id ? "chat chính của nhóm này" : `chat chính của chat cha "${await chatName(await mm.channel(pch).catch(() => ({ id: pch, name: pch })))}"`;
    forkFrom = parent.session_id;
    forkNote = `(Phiên này vừa tách từ phiên ${pname}: những gì ở trên là ngữ cảnh trước đó. Từ đây bạn làm việc ở ${threadRoot ? "một luồng riêng" : aiOf(ch) ? "chat AI riêng của chủ (nhóm không thấy)" : "một luồng bí mật"}; vị trí và công cụ theo hướng dẫn dưới đây.)`;
    const tokens = await engines[ENGINE].contextTokens(parent.session_id).catch(() => null);
    log(`phiên ${root}: fork từ ${pkey} (${tokens ?? "?"} token)`);
  }
  const chain = await ancestorChain(mm, ch.id, chatName).catch(() => [{ tier: 0, id: ch.id, name: chat, rootId: "", rootText: "" }] as Level[]);
  const ownerU = await mm.user(post.user_id);
  const block = blockIfChanged(root, await contextBlock({ ch, chain, threadRoot, assigner: { id: post.user_id, username: ownerU.username }, report: !!outer }), !session);
  const trigger = `(tin giao việc id ${post.id})`;
  let prompt: string;
  if (!session) {
    const thread = threadRoot ? (await mm.thread(threadRoot)).filter((p) => p.id !== post.id) : [];
    const rootPost = thread[0];
    const before = (await mm.channelPosts(post.channel_id, 20, rootPost?.id ?? post.id)).filter((p) => isMainPost(p) && !p.props?.flygo_agent_message?.streaming);
    const chName = ch.type === "D" ? "tin nhắn riêng" : aiOf(ch) ? `chat AI riêng (cột phải) gắn với nhóm "${outer?.name ?? chat}"` : `nhóm "${ch.display_name}"`;
    prompt = [
      forkNote,
      `Bạn đang được giao việc trong ${chName} trên Flygo Chat.`,
      ...(await Promise.all([["Tin nhắn gần đây trong nhóm (ngữ cảnh)", before], ["Chủ đề đang trao đổi", thread]].map(async ([h, ps]) => {
        const t = await fmtPosts(ps as Post[]);
        return t ? `\n## ${h}\n${t}` : "";
      }))),
      outerCtx,
      `\n${block}`,
      `\n## Việc ${owner} giao ${trigger}\n${text}${filesNote(post)}${quoteNote}${peerNote}${reportNote}`,
    ].filter(Boolean).join("\n");
  } else {
    const recent = inline ? (await mm.channelPosts(post.channel_id, 50)).filter(isMainPost) : await mm.thread(root);
    // Chỉ các tin sau lượt trả lời gần nhất của bot (việc cũ đã qua thì không nhắc lại).
    const lastBot = Math.max(session.last_seen_at, ...recent.filter((p) => p.user_id === BOT_ID).map((p) => p.create_at));
    const since = recent.filter((p) => p.create_at > lastBot && p.create_at < post.create_at && p.id !== post.id && p.user_id !== BOT_ID);
    const sinceText = since.length ? await fmtPosts(since) : "";
    prompt = [block ? `${block}\n` : "", outer?.ai && outerCtx ? `${outerCtx.trim()}\n` : "", sinceText ? `## Tin khác ${inline ? "trong nhóm" : "trong chủ đề"} từ lần trả lời trước (chỉ để tham khảo, không cần trả lời)\n${sinceText}\n` : "", `## ${owner} nhắn ${trigger}\n${text}${filesNote(post)}${quoteNote}${peerNote}${reportNote}`].filter(Boolean).join("\n");
  }

  // Model / mức suy nghĩ người dùng chọn trên app: props.flygo_agent_config = { "<bot>": { model, effort } }. Thiếu = mặc định.
  const opts = agentOptions(cfg, botDesc);
  let want: any = post.props?.flygo_agent_config;
  if (typeof want === "string") try { want = JSON.parse(want); } catch { want = null; }
  want = want?.[BOT_NAME] ?? want?.[BOT_ID] ?? {}; // khoá theo username hiện tại (hoặc id bot)
  const bad: string[] = [];
  const model = want.model && !opts.models.includes(want.model) ? (bad.push(`model ${want.model}`), opts.default.model) : want.model || opts.default.model;
  const effort = want.effort && !opts.efforts.includes(want.effort) ? (bad.push(`mức ${want.effort}`), opts.default.effort) : want.effort || opts.default.effort;
  const runConfig = { model, effort, ...(bad.length ? { note: `Không hỗ trợ ${bad.join(", ")}, dùng mặc định.` } : {}) };

  const runId = crypto.randomUUID();
  const title = text.split("\n")[0].slice(0, 80);
  emit({ event: "run_started", run_id: runId, channel_id: post.channel_id, root_id: root, engine: engineName, title, config: runConfig });
  const ownerUser = await mm.user(post.user_id);
  const ownerRef = { id: post.user_id, username: ownerUser.username };
  const where = { channel_id: post.channel_id, root_id: threadRoot };
  // Mỗi lượt MỘT post (thẻ + chữ stream + lời xin duyệt), ở chat chính lẫn trong luồng.
  const reply = new InlineReply(mm, where, runId, engineName, ownerRef, ch.type !== "D");
  const card = new RunCard(mm, where, runId, engineName, title, post.user_id, () => reply.touch());
  reply.card = card;
  card.config = runConfig;
  card.triggerId = post.id;
  session = session ?? { root_id: root, channel_id: post.channel_id, engine: engineName, session_id: "", status: "running", title, card_post_id: card.postId, last_seen_at: 0, updated_at: 0 };
  session.status = "running"; session.card_post_id = card.postId; session.last_seen_at = post.create_at; session.updated_at = Date.now();
  saveSession(session);

  const ac = new AbortController();
  running.set(root, { ac, assigner: post.user_id, channel_id: post.channel_id, posts: () => [reply.id].filter(Boolean) });
  let waitingHuman = 0; // đang chờ người duyệt / trả lời: không hiện "đang gõ"
  const sendTyping = () => { if (!waitingHuman) typing("user_typing", { channel_id: post.channel_id, parent_id: threadRoot }); };
  sendTyping();
  const typingTimer = setInterval(sendTyping, 4000);

  const ask = async (req: ApprovalRequest): Promise<ApprovalDecision> => {
    const sid = `approval-${crypto.randomUUID()}`;
    if (isBypass(root)) { // đã "luôn cho phép" (kể cả bật giữa lượt): tự duyệt
      card.step({ id: sid, kind: "approval", title: `🔓 Tự duyệt: ${req.title.slice(0, 100)}`, status: "done" });
      return "accept";
    }
    card.step({ id: sid, kind: "approval", title: `Chờ duyệt: ${req.title.slice(0, 100)}`, status: "waiting" });
    card.setStatus("awaiting_approval");
    await card.flush();
    waitingHuman++;
    const raw = await askApprovalInline(reply, req, post.user_id, ac.signal, undefined, root).finally(() => waitingHuman--);
    const d = raw === "accept" || raw === "always" ? "accept" : "decline";
    card.step({ id: sid, kind: "approval", title: `${raw === "always" ? "🔓 Luôn cho phép" : d === "accept" ? "Đã duyệt" : "Bị từ chối"}: ${req.title.slice(0, 100)}`, status: d === "accept" ? "done" : "error" });
    if (raw === "always") card.step({ id: "bypass", kind: "approval", title: BYPASS_NOTE, status: "done" });
    card.setStatus("running");
    return d;
  };
  const askQ = async (qs: UserQuestion[]): Promise<AskResult> => {
    const sid = `ask-${crypto.randomUUID()}`;
    const title = qs.map((q) => q.question).join(" · ").slice(0, 100);
    card.step({ id: sid, kind: "approval", title: `Chờ trả lời: ${title}`, status: "waiting" });
    card.setStatus("awaiting_approval");
    await card.flush();
    waitingHuman++;
    const r = await askUser(where, qs, post.user_id, ac.signal).finally(() => waitingHuman--);
    card.step({ id: sid, kind: "approval", title: "answers" in r ? `Đã trả lời: ${r.answers.map(answerText).join(" · ").slice(0, 100)}` : `Không trả lời: ${title}`, status: "answers" in r ? "done" : "error" });
    card.setStatus("running");
    return r;
  };
  runsByKey.set(runId, ask);
  askByKey.set(runId, askQ);
  skillRuns.set(runId, { assigner: post.user_id, ask, dir });
  orchRuns.set(runId, { card, dir, root, channelId: post.channel_id, signal: ac.signal, calls: 0, chat });
  const bypass = isBypass(root);
  if (bypass) card.step({ id: "bypass", kind: "approval", title: BYPASS_NOTE, status: "done" });
  if (outer) reportRuns.set(runId, { outer, card, reply, assigner: post.user_id, channelId: post.channel_id, postId: post.id, dir, signal: ac.signal, sent: 0 });

  try {
    const res = await engines[engineName].runTurn(
      {
        sessionId: session.session_id || undefined,
        forkFrom: session.session_id ? undefined : forkFrom || undefined,
        cwd: dir,
        prompt,
        persona: botPersona(),
        ...skillDirs(),
        title: sessTitle,
        group: chat,
        model,
        effort,
        bypass,
        mcpEnv: mcpEnvFor(root, {
          MM_URL: cfg.serverUrl, MM_TOKEN: cfg.botToken, CHANNEL_ID: post.channel_id, ROOT_ID: threadRoot,
          RUN_KEY: runId, WORKDIR: dir, OWNER_ID: post.user_id,
          ...(a2a ? { A2A_ROLE: "orchestrator" } : {}),
          ...(outer ? { REPORT_OUT: "1" } : {}),
        }),
      },
      {
        step: (s) => card.step(s),
        text: (t) => reply.update(t),
        approval: ask,
        ask: askQ,
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
    // Tin "Mở luồng riêng": trả lời chỉ trong luồng.
    reply.broadcast = !!post.root_id && post.props?.flygo_reply !== "thread";
    await reply.finish(res.text);
    session.status = "done";
  } catch (e: any) {
    const cancelled = ac.signal.aborted;
    card.error = cancelled ? (stopping ? STOP_NOTE : "") : String(e?.message ?? e).slice(0, 400);
    card.interrupted = cancelled && stopping;
    card.setStatus(cancelled ? (stopping ? "stopped" : "cancelled") : "error");
    await card.finish();
    // Runner tắt giữa lượt: đăng lại thành tin có lời nhắn (có thông báo), giữ phần chữ đã viết.
    await reply.finish(cancelled && stopping ? [reply.current.trim(), STOP_NOTE].filter(Boolean).join("\n\n") : "");
    if (!cancelled) await mm.createPost({ ...where, message: `❌ Em gặp lỗi: ${card.error}`, props: { ...(post.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id } });
    session.status = cancelled ? "cancelled" : "error";
    log(`run ${runId} ${session.status}: ${e?.message ?? e}`);
  } finally {
    emit({ event: "run_finished", run_id: runId, root_id: root, status: session.status });
    clearInterval(typingTimer);
    running.delete(root);
    runsByKey.delete(runId); askByKey.delete(runId);
    orchRuns.delete(runId);
    skillRuns.delete(runId);
    if (mcpCtx.get(root)?.RUN_KEY === runId) mcpCtx.delete(root);
    reportRuns.delete(runId);
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
  } else if (ev.event === "user_updated") {
    const uid = ev.data?.user?.id;
    if (uid) { mm.forgetUser(uid); usernameCache.clear(); } // đổi tên / tên hiển thị
    if (uid === BOT_ID) refreshAllow(); // sự kiện có thể không mang bot_description: đọc lại từ /users/me
  } else if (ev.event === "channel_updated") {
    const id = ev.broadcast?.channel_id ?? ev.data?.channel_id ?? "";
    mm.forgetChannel(id);
    purposeOwner.delete(id);
  } else if (ev.event === "user_added" || ev.event === "user_removed") {
    memberCache.delete(ev.broadcast?.channel_id ?? ev.data?.channel_id);
  } else if (ev.event === "reaction_removed") {
    const r = JSON.parse(ev.data.reaction);
    if (pendingQuestions.has(r.post_id)) onQuestionReaction(r, true);
  } else if (ev.event === "reaction_added") {
    const r = JSON.parse(ev.data.reaction);
    // 🛑 lên post của lượt đang chạy (thẻ / tin trả lời) = dừng lượt, như nhắn "dừng". Chỉ người giao việc hoặc chủ bot.
    if (r.emoji_name === "arrow_forward") { onResume(r).catch((e) => log(`tiếp tục: ${e}`)); return; }
    if (r.emoji_name === "outbox_tray") { onShareOut(r).catch((e) => log(`gửi ra ngoài: ${e}`)); return; }
    if (pendingQuestions.has(r.post_id)) { onQuestionReaction(r); return; }
    if (r.emoji_name === "octagonal_sign") {
      for (const x of running.values()) {
        if (!x.posts().includes(r.post_id) || !(r.user_id === x.assigner || isOwner(r.user_id))) continue;
        log(`dừng lượt theo 🛑 trên ${r.post_id}`);
        x.ac.abort();
      }
      return;
    }
    if (!pendingApprovals.has(r.post_id) && ["+1", "-1", "unlock", "white_check_mark", "x"].includes(r.emoji_name) && r.user_id !== BOT_ID) { onStaleApproval(r).catch((e) => log(`duyệt cũ: ${e}`)); return; }
    onApprovalReaction(r);
  }
}, log);

function onApprovalReaction(r: any) {
  {
    const pa = pendingApprovals.get(r.post_id);
    if (!pa || !(r.user_id === pa.assigner || isOwner(r.user_id))) return; // người giao việc hoặc chủ bot
    const resolve = pa.resolve;
    if (r.emoji_name === "unlock") { // chỉ chủ bot; lời xin duyệt báo cáo ra ngoài (không có scope) vẫn phải 👍
      if (pa.scope && isOwner(r.user_id)) { setBypass(pa.scope, true, r.user_id); resolve("always"); }
      return;
    }
    if (r.emoji_name === "+1" || r.emoji_name === "white_check_mark") resolve("accept");
    else if (r.emoji_name === "-1" || r.emoji_name === "x") resolve("decline");
  }
}

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

// ---- lượt bị bỏ dở (runner chết / khởi động lại) ----
/** Chốt post stream của lượt không còn chạy: thẻ "đã dừng", lời xin duyệt "hết hạn". Trả về true nếu có sửa. */
async function finalizeStale(p: Post): Promise<boolean> {
  const fa = p.props?.flygo_agent, msg = p.props?.flygo_agent_message, ap = p.props?.flygo_agent_approval, qu = p.props?.flygo_agent_question;
  const live = fa && ["thinking", "running", "awaiting_approval"].includes(fa.status);
  if (p.user_id !== BOT_ID || !(live || msg?.streaming || ap?.status === "pending" || qu?.status === "pending")) return false;
  const props: any = { ...p.props };
  if (fa) props.flygo_agent = { ...fa, status: live ? "stopped" : fa.status, error: live ? STOP_NOTE : fa.error, ...(live && fa.post_id ? { interrupted: true, resume_post_id: fa.post_id } : {}), ended_at: fa.ended_at ?? Date.now(), steps: (fa.steps ?? []).map((st: any) => st.status === "running" || st.status === "waiting" ? { ...st, status: "error" } : st) };
  if (msg) props.flygo_agent_message = { ...msg, streaming: false, final: true };
  if (ap) props.flygo_agent_approval = { ...ap, status: ap.status === "pending" ? "expired" : ap.status };
  if (qu?.status === "pending") props.flygo_agent_question = { ...qu, status: "expired" };
  await mm.patchPost(p.id, { props }).catch(() => {});
  return true;
}

/** Khởi động: phiên còn ghi "running" (lần trước tắt không kịp chốt) -> chốt thẻ và báo một câu. */
async function recoverInterrupted() {
  const rows = db.query("SELECT * FROM sessions WHERE status = 'running' AND updated_at > ?").all(Date.now() - 7 * 86400_000) as Session[];
  for (const s of rows) {
    try {
      if (s.root_id.startsWith("a2a:")) { s.status = "cancelled"; saveSession(s); continue; }
      const main = s.root_id.startsWith("ch:");
      const posts = main ? await mm.channelPosts(s.channel_id, 40) : await mm.thread(s.root_id);
      let fixed = 0;
      for (const p of posts) if (p.create_at >= s.updated_at - 3600_000 && (await finalizeStale(p))) fixed++;
      if (fixed) await mm.createPost({ channel_id: s.channel_id, root_id: main ? "" : s.root_id, message: STOP_NOTE, props: { ...(main ? {} : { flygo_reply: "thread" }), flygo_agent_owner: cfg.ownerUserIds[0] } });
      s.status = "cancelled"; saveSession(s);
      log(`phiên ${s.root_id}: lượt bị bỏ dở, đã chốt ${fixed} post`);
    } catch (e: any) { log(`chốt phiên ${s.root_id} lỗi: ${e?.message ?? e}`); }
  }
}

/** ▶️ (app: nút "Tiếp tục") lên post của lượt bị dừng giữa chừng: chạy lại đúng tin giao việc, cùng phiên/phạm vi. */
async function onResume(r: any) {
  const p = await mm.api<Post>("GET", `/posts/${r.post_id}`).catch(() => null);
  const fa = p?.props?.flygo_agent;
  if (!p || p.user_id !== BOT_ID || fa?.status !== "stopped" || !fa.interrupted || !fa.resume_post_id) return;
  if (!(isOwner(r.user_id) || r.user_id === p.props?.flygo_agent_owner)) return;
  await mm.patchPost(p.id, { props: { ...p.props, flygo_agent: { ...fa, interrupted: false } } }); // chỉ tiếp tục một lần
  const trigger = await mm.api<Post>("GET", `/posts/${fa.resume_post_id}`).catch(() => null);
  if (!trigger || (trigger as any).delete_at) return;
  const ch = await mm.channel(trigger.channel_id);
  log(`tiếp tục lượt bị dừng: tin ${trigger.id}`);
  (trigger as any).resume = true;
  await onPosted(trigger, ch.type);
}

/** 📤 của chủ lên một tin trong chat AI riêng: bot (tác giả nếu là bot, không thì bot trả lời gần nhất / bot đầu tiên)
 *  đăng nội dung tin (chữ + tệp) vào chat chính của nhóm gắn. Chủ bấm nên không cần duyệt thêm; mỗi tin một lần. */
const sharing = new Set<string>();
async function onShareOut(r: any) {
  if (sharing.has(r.post_id) || db.query("SELECT 1 FROM ai_shared WHERE post_id = ?").get(r.post_id)) return;
  const p = await mm.api<Post>("GET", `/posts/${r.post_id}`).catch(() => null);
  if (!p || (p as any).delete_at) return;
  const ch = await mm.channel(p.channel_id).catch(() => null);
  const ai = aiOf(ch);
  if (!ai || !isOwner(r.user_id) || (ai.owner && ai.owner !== r.user_id)) return;
  const author = await mm.user(p.user_id);
  const isFlygoBot = author.is_bot && /\[flygo-agent/i.test(author.bot_description ?? "") && (await channelMembers(p.channel_id)).bots.includes(p.user_id);
  const who = isFlygoBot ? p.user_id : await aiResponder({ ...p, id: "", root_id: p.root_id } as Post);
  if (who !== BOT_ID) return;
  sharing.add(r.post_id);
  try {
    const reply = (message: string) => mm.createPost({ channel_id: p.channel_id, root_id: p.root_id, message, props: { ...(p.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: r.user_id } });
    if (!(await channelMembers(ai.group).catch(() => null))?.bots.includes(BOT_ID)) { await reply("Em chưa là thành viên nhóm nên chưa gửi ra ngoài được. Sếp thêm em vào nhóm rồi thử lại nhé."); return; }
    const fileIds: string[] = [];
    const tmp = join(CONFIG_DIR, "tmp", `share-${p.id}`);
    for (const f of ((p as any).metadata?.files ?? []) as any[]) {
      const res = await fetch(`${mm.url}/api/v4/files/${f.id}`, { headers: { Authorization: `Bearer ${cfg.botToken}` } });
      if (!res.ok) throw new Error(`tải tệp ${f.name} lỗi ${res.status}`);
      const path = join(tmp, String(f.name ?? f.id).replace(/[^\p{L}\p{N}._ -]/gu, "_"));
      await Bun.write(path, res);
      fileIds.push(await uploadTo(ai.group, path));
    }
    try { (await import("node:fs")).rmSync(tmp, { recursive: true, force: true }); } catch {}
    let text = String(p.message ?? "").replace(mentionRe, "").trim();
    if (isFlygoBot) text = text.replace(/^@[\w.-]+\s+/, ""); // câu trả lời của bot mở đầu bằng @người giao việc
    mentionRe.lastIndex = 0;
    const gp = await mm.createPost({
      channel_id: ai.group, root_id: "", message: text, file_ids: fileIds.slice(0, 10),
      props: { flygo_agent_message: { run_id: crypto.randomUUID(), engine: ENGINE, seq: 1, streaming: false, final: true }, flygo_agent_owner: r.user_id, flygo_ai_share: { channel_id: p.channel_id, post_id: p.id } },
    });
    db.query("INSERT OR REPLACE INTO ai_shared VALUES (?, ?, ?)").run(p.id, gp.id, Date.now());
    await mm.react(p.id, BOT_ID, "white_check_mark").catch(() => {});
    log(`gửi ra ngoài: tin ${p.id} -> nhóm ${ai.group} (${gp.id})`);
  } catch (e: any) {
    log(`gửi ra ngoài lỗi: ${e?.message ?? e}`);
    await mm.createPost({ channel_id: p.channel_id, root_id: p.root_id, message: `❌ Chưa gửi ra ngoài được: ${e?.message ?? e}`, props: { ...(p.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: r.user_id } }).catch(() => {});
  } finally { sharing.delete(r.post_id); }
}

const staleReplied = new Set<string>();
/** 👍/👎/🔓 lên lời xin duyệt mà lượt đã không còn (runner vừa khởi động lại). */
async function onStaleApproval(r: any) {
  await Bun.sleep(3000); // lời xin duyệt vừa hiện có thể chưa kịp đăng ký chờ: đợi rồi xét lại
  if (pendingApprovals.has(r.post_id)) return onApprovalReaction(r);
  for (const x of running.values()) if (x.posts().includes(r.post_id)) return;
  const p = await mm.api<Post>("GET", `/posts/${r.post_id}`).catch(() => null);
  const ap = p?.props?.flygo_agent_approval;
  // "expired" ở đây = lời xin duyệt đã được chốt lúc khởi động (recoverInterrupted); mỗi post chỉ trả lời một lần.
  if (!p || p.user_id !== BOT_ID || !["pending", "expired"].includes(ap?.status) || pendingApprovals.has(p.id) || staleReplied.has(p.id)) return;
  if (!(isOwner(r.user_id) || r.user_id === p.props?.flygo_agent_owner)) return;
  staleReplied.add(p.id);
  await finalizeStale(p);
  const inChat = !!p.props?.flygo_agent_message; // lời xin duyệt trong chat (không phải DM duyệt việc A2A)
  let note = STALE_NOTE;
  if (r.emoji_name === "unlock" && isOwner(r.user_id) && inChat && ap.kind !== "report") {
    setBypass(p.root_id || mainKey(p.channel_id), true, r.user_id);
    note += " Em đã bật \"Luôn cho phép\" cho " + (p.root_id ? "luồng này." : "chat này.");
  }
  await mm.createPost({ channel_id: p.channel_id, root_id: p.root_id, message: note, props: { ...(p.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: r.user_id } });
}

async function shutdown(sig: string) {
  log(`nhận ${sig}, dừng runner`);
  stopping = true;
  clearInterval(presenceTimer);
  for (const x of running.values()) x.ac.abort();
  for (const t of a2aTasks.values()) t.ac.abort();
  a2a?.stop();
  // Chờ các lượt đang chạy chốt thẻ (đã dừng) rồi mới thoát, tối đa 8 giây.
  for (let i = 0; i < 40 && running.size; i++) await Bun.sleep(200);
  await presence(false);
  try { if (readFileSync(lockPath, "utf8") === String(process.pid)) unlinkSync(lockPath); } catch {}
  emit({ event: "stopped" });
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ---- A2A ----
a2a?.start(a2aCard());
emit({ event: "ready", a2a: a2a ? cfg.a2a.relay : null, bot: { id: BOT_ID, username: BOT_NAME }, owners: cfg.ownerUserIds, allow: allowIds, engine: ENGINE, options: agentOptions(cfg, botDesc), doctor: report, workspace_root: cfg.workspaceRoot });
recoverInterrupted().catch((e) => log(`recoverInterrupted: ${e}`));
log(`runner sẵn sàng · engine ${ENGINE} · thư mục làm việc ${cfg.workspaceRoot}`);
}

