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
import { answerText, type EngineInventory, type ApprovalDecision, type ApprovalRequest, type AskResult, type Engine, type UserAnswer, type UserQuestion, type PermMode, PERM_MODES } from "./engines/types";
import { A2AClient, type A2APeer } from "./a2a";
import { INLINE_MAX, insideDir, saveFilePart, splitParts, toFilePart, uploadLarge } from "./a2a-files";
import { InlineReply } from "./messages";
import { aiOf, ancestorChain, linkOf, type Level } from "./chain";
import { botHome, claudeSkillsDir, deleteSkill, listSkills, memoryPath, readRole, readSkill, roleLine, roleSlug, saveSkill, setRole, type SkillFile } from "./skills";
import pkg from "../package.json";
import { createHash } from "node:crypto";
import { basename } from "node:path";
import { MM, defuseMentions, type Post } from "./mm";
import { describe as schedDescribe, HISTORY_MAX, nextRun, normalize as schedNormalize, type RunRecord, type Schedule } from "./schedule";

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
let botDesc: string = me.bot_description ?? ""; // mốc "[flygo-agent engine=… allow=… models=… efforts=… default=… paused=…]"
let wasPaused = false;
/** Mốc paused=1 (app: "Tạm tắt bot"): không nhận lượt mới, trả lời ngắn "đang tạm tắt". */
const isPaused = () => /\[flygo-agent[^\]]*\bpaused=(1|true)\b/i.test(botDesc);
const pausedNoted = new Map<string, number>(); // chỗ (kênh/luồng) -> lần báo "tạm tắt" gần nhất
const parseAllow = (desc: string) => /\[flygo-agent[^\]]*\ballow=([a-z0-9,]+)/i.exec(desc ?? "")?.[1].split(",").filter(Boolean) ?? [];
async function refreshAllow() {
  let revoked = false;
  const u = await mm.me().catch((e) => { revoked = isAuthError(e); return null; });
  if (revoked) { emit({ event: "error", code: "auth_revoked", message: "Token của bot không còn dùng được (bot đã bị tắt hoặc xoá)." }); return shutdown("auth_revoked"); }
  if (!u) return;
  botDesc = u.bot_description ?? "";
  if (boundElsewhere(botDesc)) return shutdown("bound_elsewhere"); // bị chuyển sang máy khác lúc đang chạy
  if (isPaused() !== wasPaused) { wasPaused = isPaused(); log(wasPaused ? "bot tạm tắt (paused=1)" : "bot bật lại"); presence(true).catch(() => {}); }
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
// Độ sâu tách phiên: phiên tách từ phiên tách… tối đa FORK_MAX_DEPTH tầng (phiên gốc = 0).
db.run(`CREATE TABLE IF NOT EXISTS fork_depth (root_id TEXT PRIMARY KEY, depth INTEGER)`);
const FORK_MAX_DEPTH = 3;
const forkDepth = (root: string) => (db.query("SELECT depth FROM fork_depth WHERE root_id = ?").get(root) as { depth: number } | null)?.depth ?? 0;
// Tin đã xử lý (bắt bù sau khởi động lại / mất kết nối không làm lại): tin có lượt chạy ghi khi lượt bắt đầu,
// tin không cần chạy ghi khi xét xong. Tin đã nhận mà lượt chưa kịp chạy (runner tắt) -> bắt bù chạy lại.
db.run(`CREATE TABLE IF NOT EXISTS seen_posts (post_id TEXT PRIMARY KEY, at INTEGER)`);
// Lượt đang chạy: tin giao việc của mỗi phiên (xoá khi lượt kết thúc). Còn lại lúc khởi động = lượt bị bỏ dở -> chạy lại.
db.run(`CREATE TABLE IF NOT EXISTS turn_triggers (root_id TEXT PRIMARY KEY, post_id TEXT, channel_id TEXT, at INTEGER)`);
db.run(`CREATE TABLE IF NOT EXISTS turn_retried (post_id TEXT PRIMARY KEY, at INTEGER)`);
// Chat / luồng được tag kèm quyền tạm (props.flygo_refs, relay /ref): theo khoá phiên, dùng tới khi hết hạn.
db.run(`CREATE TABLE IF NOT EXISTS meet_suggestions (key TEXT PRIMARY KEY, post_id TEXT, at INTEGER)`); // "<kênh phiên> <question_id>" -> post gợi ý
db.run(`CREATE TABLE IF NOT EXISTS ref_grants (grant_id TEXT PRIMARY KEY, root_id TEXT, data TEXT, expires_at INTEGER)`);
db.run(`DELETE FROM turn_retried WHERE at < ${Date.now() - 2 * 86400_000}`);
db.run(`DELETE FROM seen_posts WHERE at < ${Date.now() - 2 * 86400_000}`);
const isSeen = (id: string) => !!db.query("SELECT 1 FROM seen_posts WHERE post_id = ?").get(id);
const markSeen = (id: string) => { db.query("INSERT OR IGNORE INTO seen_posts VALUES (?, ?)").run(id, Date.now()); };
const enqueuedPosts = new Set<string>();
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
  reply.hold(true);
  const decision = postId ? await waitDecision(postId, ownerId, signal, timeoutMs, scope).finally(() => reply.hold(false)) : "expired";
  await reply.setApproval({ ...base, status: approvalStatus(decision) }); // giữ trạng thái đã quyết trên post (tới lời xin duyệt sau / tin cuối)
  for (const e of ["+1", "-1", "unlock"]) await mm.api("DELETE", `/users/${BOT_ID}/posts/${postId}/reactions/${e}`).catch(() => {});
  return decision;
}

// ---- câu hỏi cho người dùng (AskUserQuestion / request_user_input / ask_user) ----
// Mỗi câu hỏi một post: props.flygo_agent_question = { id, question, header, options, multi, allow_other, status, answer? }.
// Trả lời KHÔNG tạo tin: thả 1️⃣–9️⃣ lên chính post (chọn nhiều: thả các số rồi ✅). "Ý khác": gõ một tin trong chỗ đó
// (tin này là câu trả lời, không mở lượt mới). Tương thích: post có props.flygo_agent_answer { post_id, choices, other?, cancelled? }.
const NUM_EMOJI = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
const KEYCAP = ["1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣"];
interface PendingQuestion { resolve: (a: UserAnswer | null) => void; assigner: string; q: UserQuestion; picks: Set<number>; where: { channel_id: string; root_id: string } }
const pendingQuestions = new Map<string, PendingQuestion>(); // post_id câu hỏi -> chờ trả lời
const askByKey = new Map<string, (qs: UserQuestion[]) => Promise<AskResult>>(); // RUN_KEY -> hỏi trong lượt đó

async function askOne(where: { channel_id: string; root_id: string }, q: UserQuestion, assigner: string, signal: AbortSignal): Promise<UserAnswer | "cancelled" | "expired" | "stopped"> {
  const options = q.options.slice(0, NUM_EMOJI.length).map((o) => ({ label: String(o.label ?? ""), description: String(o.description ?? "") }));
  const meta = { id: crypto.randomUUID(), question: q.question, header: q.header ?? "", options, multi: !!q.multi, allow_other: true };
  const list = options.map((o, i) => `${i + 1}. **${o.label}**${o.description ? ` — ${o.description}` : ""}`).join("\n");
  const hint = `_Thả ${options.length > 1 ? `1️⃣–${KEYCAP[options.length - 1]}` : "1️⃣"} để chọn${q.multi ? " (chọn nhiều rồi thả ✅)" : ""}, hoặc gõ ý khác._`;
  const base = { ...(where.root_id ? { flygo_reply: "thread" } : {}), flygo_agent_owner: assigner, flygo_agent_requester: assigner };
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
    const raw = post.message.replace(mentionRe, "").trim();
    mentionRe.lastIndex = 0;
    if (!raw) continue;
    // App ghép các lựa chọn đã chọn vào đầu tin ("Phở, Bún, ý khác"): tách ra thành lựa chọn, phần còn lại là ý khác.
    const labels = pq.q.options.map((o) => o.label);
    const choices = pq.q.multi ? [...pq.picks].sort().map((k) => labels[k]) : [];
    let rest = raw;
    for (;;) {
      const l = labels.find((x) => rest === x || rest.startsWith(`${x}, `));
      if (!l) break;
      if (!choices.includes(l)) choices.push(l);
      rest = rest.slice(l.length).replace(/^,\s*/, "");
    }
    pq.resolve({ choices, ...(rest.trim() ? { other: rest.trim() } : {}) });
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
      const plan = tool_name === "ExitPlanMode"; // chế độ Lập kế hoạch: Claude xin duyệt kế hoạch trước khi làm
      const { kind, title, detail } = approvalOf(tool_name, input);
      log(`xin duyệt ${tool_name}: ${oneLine(title, 160)}`);
      const d = await ask({ kind, title, detail });
      log(`duyệt ${tool_name}: ${d === "accept" ? "cho phép" : "từ chối"}`);
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
    if (url.pathname.startsWith("/schedule/") && req.method === "POST") {
      const r = await scheduleTool(url.pathname.slice(10), await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname.startsWith("/skill/") && req.method === "POST") {
      const r = await skillTool(url.pathname.slice(7), await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname.startsWith("/ref/") && req.method === "POST") { // ref_read / ref_thread / ref_post (chat được tag, quyền tạm)
      const r = await refTool(url.pathname.slice(5), await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname === "/meet_suggest" && req.method === "POST") { // meeting_suggest: gợi ý trả lời cho chủ trì duyệt
      const r = await meetSuggest(await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname === "/meet_watch" && req.method === "POST") { // meeting_watch: bật / tắt theo dõi cuộc họp
      const r = await meetWatchTool(await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname === "/session_title" && req.method === "POST") { // chat_session_title: đặt tên phiên AI mới
      const r = await sessionTitleTool(await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
      return Response.json({ text: r });
    }
    if (url.pathname === "/post_op" && req.method === "POST") { // chat_edit_message / chat_recall_message
      const r = await postOp(await req.json()).catch((e: any) => `Lỗi: ${e?.message ?? e}`);
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
/** Kênh dự án (app 156): kênh P có mốc [flygo-agent-project owner=…] trong purpose, làm gốc cho các phiên AI của dự án. */
const isProject = (ch: any) => /\[flygo-agent-project\b/.test(ch?.purpose ?? "");
/** Phiên AI đã lưu trữ (app 156): mốc [flygo-ai-archived] trong header. Khôi phục = bỏ mốc. */
const isArchived = (ch: any) => /\[flygo-ai-archived\]/.test(ch?.header ?? "");
/** Phiên AI gắn với gì: chat 1-1 chủ↔bot, dự án, hay nhóm chat. */
async function aiKindOf(ch: any): Promise<"dm" | "project" | "group" | null> {
  const ai = aiOf(ch);
  if (!ai) return null;
  const g = await mm.channel(ai.group).catch(() => null);
  return g?.type === "D" ? "dm" : isProject(g) ? "project" : "group";
}
/** Kênh D là chat 1-1 giữa `owner` và bot này (tên kênh D = "<id>__<id>"). */
const isDmOf = (ch: any, owner: string) => { const ids = String(ch?.name ?? "").split("__"); return ids.includes(BOT_ID) && (!owner || ids.includes(owner)); };

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
/** Thư mục con trực tiếp (bỏ .* và node_modules) của path trong projectRoots; path trống = danh sách projectRoots. */
function listDirs(userId: string, raw: string) {
  if (!isOwner(userId)) return { ok: false, status: 403, error: "chỉ chủ bot" };
  const home = homedir();
  const tilde = (p: string) => (p === home ? "~" : p.startsWith(home + sep) ? `~${p.slice(home.length).replaceAll(sep, "/")}` : p);
  const roots = cfg.projectRoots.map((r) => { try { return realpathSync(r); } catch { return null; } }).filter((r): r is string => !!r && statSync(r).isDirectory());
  const machine = hostname().replace(/\.local$/, "");
  if (!raw.trim()) return { ok: true, path: "", parent: null, root: true, machine, dirs: roots.map((r) => ({ name: tilde(r), path: tilde(r) })) };
  const real = allowedProject(raw.trim());
  if (!real) return { ok: false, status: 400, error: roots.length ? "thư mục không có hoặc nằm ngoài các thư mục được phép" : "bot chưa cấu hình projectRoots" };
  const atRoot = roots.includes(real);
  const parent = atRoot ? null : tilde(resolve(real, ".."));
  const dirs = readdirSync(real, { withFileTypes: true })
    .filter((d) => !d.name.startsWith(".") && d.name !== "node_modules" && (d.isDirectory() || (d.isSymbolicLink() && (() => { try { return statSync(join(real, d.name)).isDirectory(); } catch { return false; } })())))
    .map((d) => d.name).sort((a, b) => a.localeCompare(b, "vi", { sensitivity: "base" })).slice(0, 300)
    .map((name) => ({ name, path: tilde(join(real, name)) }));
  return { ok: true, path: tilde(real), parent, root: atRoot, machine, dirs };
}
const projectRe = /\[flygo-project path=(?:"([^"\]]+)"|([^\]\s]+))\]/; // path có dấu cách: path="…"
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
      if (posts.length < 200) { ok = isOwner(ch.creator_id ?? ""); break; } // mô tả đặt lúc tạo kênh (không có tin đổi mô tả): người tạo phải là chủ bot
      before = posts[0].id;
    }
    purposeOwner.set(ch.id, ok ? allowedProject(m[1] ?? m[2]) : null);
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
    if (p.props?.flygo_thread_name !== undefined) { out.push(`(luồng được đổi tên thành "${oneLine(String(p.props.flygo_thread_name), 80)}")`); continue; }
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

// ---- kiểm kê (kỹ năng / model) -> relay ghi props.flygo_skills, props.flygo_models và mốc models= efforts= default= của bot ----
let inventory: EngineInventory | null = null;
/** Model / mức suy nghĩ dùng được: cấu hình + mốc + model engine báo có. Codex: model mặc định không còn dùng được -> model mặc định của engine. */
function botOptions() {
  const o = agentOptions(cfg, botDesc);
  if (!inventory?.models.length) return o;
  const ids = inventory.models.map((m) => m.id);
  const models = [...new Set([...o.models, ...ids])];
  const efforts = [...new Set([...o.efforts, ...inventory.models.flatMap((m) => m.efforts)])];
  let def = o.default;
  if (ENGINE === "codex" && !ids.includes(def.model)) {
    const d = inventory.models.find((m) => m.isDefault) ?? inventory.models[0];
    def = { model: d.id, effort: d.efforts.includes(def.effort) ? def.effort : d.defaultEffort ?? def.effort };
  }
  return { models, efforts, default: def };
}
// Chế độ quyền cho app (Quyền → Chọn chế độ). Mặc định giữ như trước: Claude hỏi trước mọi thay đổi, Codex tự sửa trong thư mục làm việc.
const defaultMode = (): PermMode => (ENGINE === "codex" ? "acceptEdits" : "manual");
const permModes = () => [
  { id: "manual", label: "Thủ công", description: "Luôn hỏi trước khi thực hiện thay đổi" },
  { id: "acceptEdits", label: "Chấp nhận chỉnh sửa", description: "Tự động chấp nhận chỉnh sửa tệp" },
  { id: "plan", label: "Lập kế hoạch", description: "Tạo kế hoạch trước khi thực hiện thay đổi" },
  { id: "auto", label: "Tự động", description: `${ENGINE === "codex" ? "Codex" : "Claude"} xử lý các quyết định về quyền` },
  ...(ENGINE === "claude" ? [{ id: "bypassPermissions", label: "Bỏ qua kiểm tra", description: "Claude tự làm mọi việc, không hỏi quyền" }] : []),
];
/** Lời xin duyệt của Claude (--permission-prompt-tool) dễ đọc: lệnh, tệp + nội dung / thay đổi, kế hoạch, tool. */
function approvalOf(tool: string, input: any): ApprovalRequest {
  const clipD = (s: string, n = 1500) => (s.length > n ? s.slice(0, n) + "\n…" : s);
  const file = String(input?.file_path ?? input?.notebook_path ?? "");
  const name = file.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || file;
  const diff = (o: string, n: string) => [...String(o ?? "").split("\n").map((l) => `- ${l}`), ...String(n ?? "").split("\n").map((l) => `+ ${l}`)].join("\n");
  switch (tool) {
    case "ExitPlanMode": return { kind: "plan", title: "Thực hiện kế hoạch này", detail: String(input?.plan ?? "").slice(0, 3500) };
    case "Bash": return { kind: "command", title: `$ ${input?.command ?? ""}`, detail: input?.description };
    case "Write": return { kind: "file", title: `Ghi tệp ${name}`, detail: clipD(`${file}\n\n${String(input?.content ?? "")}`) };
    case "Edit": return { kind: "file", title: `Sửa tệp ${name}`, detail: clipD(`${file}\n\n${diff(input?.old_string, input?.new_string)}`) };
    case "MultiEdit": return { kind: "file", title: `Sửa tệp ${name}`, detail: clipD(`${file}\n\n${(input?.edits ?? []).map((e: any) => diff(e.old_string, e.new_string)).join("\n…\n")}`) };
    case "NotebookEdit": return { kind: "file", title: `Sửa notebook ${name}`, detail: clipD(`${file}\n\n${String(input?.new_source ?? "")}`) };
    case "WebFetch": return { kind: "tool", title: `Mở ${input?.url ?? ""}`, detail: input?.prompt };
    case "WebSearch": return { kind: "tool", title: `Tìm web: ${input?.query ?? ""}` };
    default: {
      const m = /^mcp__(.+?)__(.+)$/.exec(tool);
      return { kind: "tool", title: m ? `${m[1]} · ${m[2]}` : tool, detail: clipD(JSON.stringify(input ?? {}, null, 1), 800) };
    }
  }
}
let metaSent = "";
async function publishMeta() {
  inventory = await engines[ENGINE].inventory().catch((e) => { log(`kiểm kê ${ENGINE}: ${e?.message ?? e}`); return inventory; });
  const own = listSkills(BOT_ID, cfg.skillsDir);
  const skills = [
    ...own.map((k) => ({ name: k.name, description: clip(k.description, 200), source: k.source })),
    ...(inventory?.skills ?? []).filter((k) => !own.some((x) => x.name === k.name)).map((k) => ({ name: k.name, description: clip(k.description, 200), source: "engine" })),
  ];
  const o = botOptions();
  const alias: Record<string, string> = { opus: "claude-opus-5-5", sonnet: "claude-sonnet-5-5", haiku: "claude-haiku-5-5", fable: "claude-fable-5-1" };
  const defModel = ENGINE === "claude" ? alias[o.default.model] ?? o.default.model : o.default.model;
  // Thứ tự hiện trên app: model mặc định, rồi các model trong cấu hình (codex.models / claude.models), rồi phần còn lại theo engine.
  const pref = [defModel, ...((ENGINE === "codex" ? cfg.codex.models : cfg.claude.models) ?? [])];
  const rank = (id: string) => { const i = pref.indexOf(id); return i < 0 ? pref.length : i; };
  const invModels = [...(inventory?.models ?? [])].sort((a, b) => rank(a.id) - rank(b.id));
  const models = { engine: ENGINE, models: invModels, efforts: o.efforts, default: { model: defModel, effort: o.default.effort }, modes: permModes(), default_mode: defaultMode() };
  const marker = invModels.length ? { models: invModels.map((m) => m.id).join(","), efforts: o.efforts.join(","), default: `${defModel}:${o.default.effort}` } : undefined;
  const body = JSON.stringify({ skills: { v: 1, at: Date.now(), skills }, models, marker });
  const key = JSON.stringify({ skills, models, marker });
  if (key === metaSent || !a2a) return;
  const r = await fetch(`${relayBase}/meta`, { method: "POST", headers: { ...relayAuth, "content-type": "application/json" }, body, signal: AbortSignal.timeout(15_000) })
    .then((x) => x.json()).catch((e) => ({ error: String(e) }));
  if (r?.ok) { metaSent = key; log(`kiểm kê: ${skills.length} kỹ năng, ${models.models.length} model${r.marker ? " (đã cập nhật mốc)" : ""}`); }
  else log(`kiểm kê: relay không nhận (${r?.error ?? "?"})`);
}
const iso = () => new Date().toISOString();
const oneLine = (t: string, n: number) => { const s = String(t ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "…" : s; };

function a2aCard() {
  const o = botOptions();
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
interface OrchRun { card: RunCard; dir: string; root: string; channelId: string; signal: AbortSignal; calls: number; chat: string; waiting: Map<string, number>; assigner?: string; runId?: string }
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
  const n = ++ctx.calls; // không giới hạn số lần; chống vòng lặp ở phía được nhờ (phiên đang chờ chính bên nhờ)
  const session = String(a.session ?? "").trim();
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
  const askTitle = `Hỏi @${peer.username}${session ? " (phiên của nó)" : ""}: ${oneLine(message, 80)}`;
  const fileNote = parts.filter((p) => p.kind === "file").map((p) => p.file.name);
  ctx.card.step({ id: `${sid}-q`, kind: "tool", title: askTitle, status: "running", detail: message + (fileNote.length ? `\n📎 ${fileNote.join(", ")}` : "") });
  // Cùng một luồng chat + cùng agent -> cùng contextId: agent kia nhớ các lần nhờ trước trong luồng này.
  const contextId = createHash("sha256").update(`${BOT_ID}:${ctx.root}:${peer.id}`).digest("hex").slice(0, 32);
  const artifacts: any[] = [];
  let status: any = null;
  ctx.waiting.set(peer.id, (ctx.waiting.get(peer.id) ?? 0) + 1);
  try {
    await a2a.call(peer.id, "message/stream", {
      message: { kind: "message", role: "user", messageId: crypto.randomUUID(), contextId, parts, metadata: { "x-flygo": { chat: ctx.chat, ...(session ? { session } : {}), from_root: ctx.root } } },
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
  } finally {
    const w = (ctx.waiting.get(peer.id) ?? 1) - 1;
    if (w > 0) ctx.waiting.set(peer.id, w); else ctx.waiting.delete(peer.id);
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
      if (isPaused()) return fail(-32003, `@${BOT_NAME} đang tạm tắt, chưa nhận việc.`);
      const task = { kind: "task", id: crypto.randomUUID(), contextId: String(msg.contextId || crypto.randomUUID()), status: { state: "submitted", timestamp: iso() }, history: [msg], artifacts: [] as any[] };
      const dir = join(cfg.workspaceRoot, `a2a-${slug(from.username)}-${from.id.slice(0, 6)}`);
      const t: A2ATask = { task, ac: new AbortController(), callerId: from.id, files: [], dir };
      a2aTasks.set(task.id, t);
      a2aByCid.set(cid, task.id);
      const stream = req.method === "message/stream";
      if (stream) a2a!.event(cid, task);
      log(`a2a: @${from.username} nhờ (${req.method}) ${oneLine(splitParts(msg.parts).texts.join(" "), 80)}`);
      const sess = String(msg.metadata?.["x-flygo"]?.session ?? P.metadata?.["x-flygo"]?.session ?? "").trim();
      if (sess) { // nói tiếp một phiên có sẵn của bot này (chat / chat AI riêng), hiện ngay trong kênh của phiên
        a2aSession(cid, from, msg, t, stream, sess).catch((e) => { log(`a2a phiên ${sess}: ${e?.message ?? e}`); });
        return;
      }
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

/** props.flygo_a2a_peers: phiên của các bot khác (cùng chủ) người dùng gắn vào tin -> nói tiếp bằng ask_agent(bot, message, session). */
function a2aPeersNote(post: Post): string {
  let ps: any = post.props?.flygo_a2a_peers;
  if (typeof ps === "string") try { ps = JSON.parse(ps); } catch { ps = null; }
  if (!Array.isArray(ps) || !a2a) return "";
  const rows = ps.filter((p: any) => p?.session_id && (p.username || p.bot_id) && p.bot_id !== BOT_ID)
    .map((p: any) => `- @${p.username ?? p.bot_id}: ${p.kind === "ai_session" ? "chat AI" : "chat"} "${oneLine(String(p.title ?? ""), 80)}"${p.group ? ` (nhóm ${p.group})` : ""} — session="${p.session_id}"`);
  return rows.length ? `\n\n## Phiên của agent khác được gắn vào tin này\nNói tiếp đúng phiên đó (agent kia nhớ ngữ cảnh của phiên) bằng ask_agent(bot, message, session=<session>):\n${rows.join("\n")}` : "";
}

/** Bên nhờ (cùng chủ) muốn nói tiếp phiên `sess` của bot này: chạy như một lượt trong kênh của phiên (hiện ở cả hai nơi). */
async function a2aSession(cid: string, from: A2APeer, msg: any, t: A2ATask, stream: boolean, sess: string) {
  const { task } = t;
  const finish = (state: string, text: string) => {
    task.status = { state, timestamp: iso(), message: { kind: "message", role: "agent", messageId: crypto.randomUUID(), taskId: task.id, contextId: task.contextId, parts: [{ kind: "text", text }] } };
    if (state === "completed") task.artifacts.push({ artifactId: crypto.randomUUID(), name: "answer", parts: [{ kind: "text", text }] });
    if (stream) {
      if (state === "completed") a2a!.event(cid, { kind: "artifact-update", taskId: task.id, contextId: task.contextId, artifact: task.artifacts[task.artifacts.length - 1], lastChunk: true });
      a2a!.event(cid, { kind: "status-update", taskId: task.id, contextId: task.contextId, status: task.status, final: true });
    }
    a2aTasks.delete(task.id);
    a2aByCid.delete(cid);
    a2a!.done(cid, stream ? null : task);
  };
  if (!cfg.ownerUserIds.includes(from.owner_id)) return finish("rejected", "Chỉ bot cùng chủ mới được nói tiếp phiên của bot này.");
  // session: khoá phiên (ch:<kênh> / id tin gốc luồng) hoặc id kênh (= phiên chat chính của kênh đó)
  const key = getSession(sess) ? sess : /^\w{26}$/.test(sess) ? mainKey(sess) : "";
  const s = key ? getSession(key) : null;
  const channelId = s?.channel_id || (key.startsWith("ch:") ? key.slice(3) : "");
  if (!channelId) return finish("rejected", `Không thấy phiên ${sess} của @${BOT_NAME}.`);
  if (!(await channelMembers(channelId).catch(() => null))?.bots.includes(BOT_ID)) return finish("rejected", `@${BOT_NAME} không còn ở kênh của phiên ${sess}.`);
  // Chống vòng lặp: phiên đích đang chạy và đang chờ chính bên nhờ trả lời -> nói tiếp sẽ kẹt.
  const cur = [...orchRuns.values()].find((o) => o.root === key && o.waiting.has(from.id));
  if (cur) return finish("rejected", `Vòng lặp: phiên này của @${BOT_NAME} đang chờ @${from.username} trả lời. Trả lời nó trước, đừng nhờ ngược lại.`);
  const text = splitParts(msg.parts).texts.join("\n").trim();
  const threadRoot = key.startsWith("ch:") ? "" : key;
  const shown = await mm.createPost({
    channel_id: channelId, root_id: threadRoot, message: `🤝 **@${from.username} nhờ qua A2A:**\n${text}`,
    props: { ...(threadRoot ? { flygo_reply: "thread" } : {}), flygo_agent_owner: from.owner_id, flygo_a2a_from: { bot_id: from.id, username: from.username } },
  }).catch(() => null);
  const post = {
    id: shown?.id ?? crypto.randomUUID(), channel_id: channelId, root_id: threadRoot, user_id: from.owner_id, create_at: Date.now(),
    message: `(Agent @${from.username} của cùng chủ nhờ qua A2A. Câu trả lời cuối của bạn được gửi lại cho @${from.username}; trả lời đầy đủ, đúng việc được nhờ.)\n${text}`,
    props: {},
  } as any as Post;
  if (stream) { task.status = { state: "working", timestamp: iso() }; a2a!.event(cid, { kind: "status-update", taskId: task.id, contextId: task.contextId, status: task.status, final: false }); }
  const out: { text?: string; error?: string; onStart?: (ac: AbortController) => void } = {
    onStart: (ac) => t.ac.signal.addEventListener("abort", () => ac.abort(), { once: true }),
  };
  enqueue(key, () => runTurn(post, key, post.message, out).catch((e) => { out.error = String(e?.message ?? e); }).then(() => {
    if (out.text !== undefined) finish("completed", out.text || "(không có câu trả lời)");
    else finish(t.ac.signal.aborted ? "canceled" : "failed", out.error || "lượt không chạy (phiên đóng / bot tạm tắt)");
  }));
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
  let release = () => {};
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
    const opts = botOptions();
    const ask = (req: ApprovalRequest) => askApprovalDM(req, from, ac.signal, key);
    runsByKey.set(runId, ask);
    a2aRuns.set(runId, t);
    release = await acquireSlot(ac.signal);
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
    release();
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
// Mỗi bot chạy tối đa MAX_PARALLEL lượt cùng lúc (mọi chat + A2A); lượt sau chờ chỗ trống (thẻ "queued").
const MAX_PARALLEL = 3;
let activeRuns = 0;
const slotWaiters: (() => void)[] = [];
/** Chờ chỗ chạy. onQueued: gọi khi phải chờ. Bị huỷ khi signal abort. */
async function acquireSlot(signal: AbortSignal, onQueued?: () => void): Promise<() => void> {
  if (activeRuns >= MAX_PARALLEL) {
    onQueued?.();
    await new Promise<void>((resolve, reject) => {
      const go = () => { signal.removeEventListener("abort", stop); resolve(); };
      const stop = () => { const i = slotWaiters.indexOf(go); if (i >= 0) slotWaiters.splice(i, 1); reject(new Error("đã dừng")); };
      slotWaiters.push(go);
      signal.addEventListener("abort", stop, { once: true });
    });
  } else activeRuns++;
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const next = slotWaiters.shift();
    if (next) next(); // chuyển chỗ cho lượt chờ (activeRuns giữ nguyên)
    else activeRuns--;
  };
}
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
  if (post.props?.flygo_meet_comment || post.props?.flygo_meet_thread) return; // bình luận cuộc họp (luồng công khai): runner nhận qua phòng họp, không phải việc
  if (post.props?.flygo_thread_name !== undefined) return; // app đổi tên luồng (✏️ Đổi tên luồng thành "…"): không phải việc, không phải câu trả lời
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
    if (isArchived(await mm.channel(post.channel_id))) return; // phiên đã lưu trữ: chỉ trả lời khi được @tag (khôi phục phiên để nói tiếp như thường)
    if ((await taggedAgents(post.message)).length) return; // tag bot khác: bot đó trả lời
    aiPick = (await aiResponder(post)) === BOT_ID;
    if (!aiPick) return;
  }
  // Trích dẫn tin của chính bot này (không tag bot khác) = nói với bot này, như có @tag.
  const quotedMe = !mentioned && !!(post as any).quote_of && (await mm.api<Post>("GET", `/posts/${(post as any).quote_of}`).catch(() => null))?.user_id === BOT_ID
    && !(await taggedAgents(post.message)).length;
  if (!mentioned && !aiPick && !quotedMe && !(allowed && (await implicitTrigger(post, channelType)))) return;
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
  if (isPaused()) {
    if (Date.now() - (pausedNoted.get(root) ?? 0) < 10 * 60_000) return; // mỗi chỗ báo một lần / 10 phút
    pausedNoted.set(root, Date.now());
    await mm.createPost({ channel_id: post.channel_id, root_id: threadRootOf(post), message: `⏸ @${BOT_NAME} đang tạm tắt, chưa nhận việc mới. Bật lại trên app để em làm tiếp.`, props: { ...(threadRootOf(post) ? { flygo_reply: "thread" } : {}), flygo_agent_owner: post.user_id, flygo_agent_paused: true } }).catch(() => {});
    return;
  }
  enqueuedPosts.add(post.id);
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
interface Outer { secret: boolean; ai?: boolean; dm?: boolean; noAccess?: boolean; channelId: string; name: string; rootId: string; rootText: string; label: string; top?: string }
/** Nhóm ngoài của lượt: luồng mở -> chính kênh đó; kênh bí mật [flygo-sub parent=… root=…] -> kênh cha. */
async function outerOf(ch: any, threadRoot: string, threadTitle: string): Promise<Outer | null> {
  const ai = aiOf(ch);
  if (ai) { // chat AI riêng: "ra ngoài" = chat chính của nhóm gắn, luôn phải duyệt (nhóm không thấy chat này)
    const g = await mm.channel(ai.group).catch(() => null);
    if (g && isProject(g)) return null; // phiên của dự án: kênh dự án không hiện như một chat, không có chỗ để báo cáo ra
    // Bot không đọc được nhóm gắn (nhóm riêng tư, bot không là thành viên — mỗi chat một trợ lý): vẫn có "ra ngoài" để chat_report_out báo đúng lý do.
    if (!g) return { secret: true, ai: true, noAccess: true, channelId: ai.group, name: "nhóm gắn (bot không đọc được)", rootId: threadRoot, rootText: "", label: threadRoot ? `${threadTitle} · chat AI riêng` : "Chat AI riêng" };
    const top = linkOf(g) ? await topChat(g) : null;
    return { secret: true, ai: true, dm: g.type === "D", channelId: g.id, name: await chatName(g), rootId: threadRoot, rootText: "", label: threadRoot ? `${threadTitle} · chat AI riêng` : "Chat AI riêng", top: top ? await chatName(top) : undefined };
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

async function uploadTo(channelId: string, path: string): Promise<string> {
  if (Bun.file(path).size > INLINE_MAX) return uploadLarge(mm, cfg.botToken, channelId, path); // tệp lớn: từng khúc (Cloudflare cắt request dài)
  const form = new FormData();
  form.append("channel_id", channelId);
  form.append("files", Bun.file(path), basename(path));
  const r = await fetch(`${mm.url}/api/v4/files`, { method: "POST", headers: { Authorization: `Bearer ${cfg.botToken}` }, body: form });
  if (!r.ok) throw new Error(`tải lên lỗi ${r.status} ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).file_infos[0].id;
}

/** chat_edit_message / chat_recall_message: sửa hoặc thu hồi (xoá) tin do CHÍNH bot này gửi. Không cần duyệt; mỗi lần ghi một bước trên thẻ.
 *  Không đụng thẻ tiến trình, lời xin duyệt, tin đang stream của lượt. Người giao việc không phải chủ bot: chỉ tin trong kênh hiện tại. */
// ---- phòng họp: cuộc gọi đang diễn ra ở nhóm của phiên -> tool meeting_*; theo dõi bình luận / giơ tay đưa vào phiên AI ----
const meetBase = relayBase.replace(/\/a2a$/, "") + "/meet";
/** Kênh họp của một kênh: phiên AI -> nhóm gắn với nó; kênh thường -> chính nó. */
const meetChannelOf = (ch: any) => aiOf(ch)?.group || ch?.id || "";
async function callActive(channelId: string): Promise<boolean> {
  if (!channelId) return false;
  try {
    const r = await fetch(`${cfg.serverUrl}/plugins/com.mattermost.calls/${channelId}`, { headers: { Authorization: `Bearer ${cfg.botToken}` }, signal: AbortSignal.timeout(5000) });
    if (!r.ok) return false;
    const j: any = await r.json();
    if (j?.call && (j.call.id || j.call.start_at) && !(Number(j.call.end_at) > 0)) return true;
  } catch {}
  // Dự phòng: app vào phòng họp của relay khi đang trong cuộc gọi -> có người (không phải bot) trong phòng = đang họp.
  try {
    const r = await fetch(`${meetBase}/${channelId}/state`, { headers: { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl }, signal: AbortSignal.timeout(5000) });
    const j: any = r.ok ? await r.json() : null;
    return !!j?.online?.some((x: any) => !x.bot);
  } catch { return false; }
}
interface MeetWatch { group: string; session: string; owner: string; ws: WebSocket | null; buf: any[]; timer: any; poll: any; stopped: boolean; names: Map<string, string>; thread: string | null }
const meetWatches = new Map<string, MeetWatch>(); // nhóm (kênh họp) -> theo dõi
const MEET_BATCH_MS = 15_000, MEET_BATCH_MAX = 5;
/** Phiên AI gần nhất của chủ bot gắn với nhóm G (theo lần chạy gần nhất). */
async function latestAiSession(group: string): Promise<string | null> {
  const rows = db.query("SELECT channel_id, MAX(updated_at) AS t FROM sessions WHERE channel_id != '' GROUP BY channel_id ORDER BY t DESC LIMIT 200").all() as { channel_id: string }[];
  for (const r of rows) {
    const c = await mm.channel(r.channel_id).catch(() => null);
    if (c && !c.delete_at && aiOf(c)?.group === group && !isArchived(c)) return c.id;
  }
  return null;
}
/** Cuộc gọi bắt đầu ở nhóm chủ bot đang dùng bot này: giành quyền trợ lý (một bot mỗi cuộc gọi, bot dùng gần nhất thắng),
 *  thắng thì mở một phiên AI MỚI cho cuộc họp này, tách (fork) từ phiên chủ đang chat ở cột AI của nhóm — giữ ngữ cảnh,
 *  không lẫn tin cũ — rồi theo dõi bình luận vào đó. */
async function meetStart(group: string) {
  const sid = await latestAiSession(group);
  if (!sid || meetWatches.get(group)?.stopped === false) return;
  const score = (db.query("SELECT MAX(updated_at) AS t FROM sessions WHERE channel_id = ?").get(sid) as any)?.t ?? 0;
  const r = await fetch(`${meetBase}/${group}/claim`, { method: "POST", headers: { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl, "content-type": "application/json" }, body: JSON.stringify({ score }), signal: AbortSignal.timeout(20_000) });
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok || !j.winner) { log(`họp: nhóm ${group} đã có trợ lý khác cho cuộc họp này`); return; }
  const owner = aiOf(await mm.channel(sid))?.owner || cfg.ownerUserIds[0];
  const old = await mm.channel(sid);
  const g = await mm.channel(group);
  const now = new Date();
  const at = now.toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour: "2-digit", minute: "2-digit", day: "2-digit", month: "2-digit", hour12: false }).replace(",", "");
  const name = `AI · ${await chatName(g)} · Cuộc họp ${at}`;
  const c: any = await mm.api("POST", "/channels", { team_id: old.team_id, name: `ai-${now.getTime().toString(36)}`, display_name: name.length > 64 ? name.slice(0, 64) : name, purpose: `[flygo-ai group=${group} owner=${owner}]`, header: `[flygo-ai-fork ${sid}]`, type: "P" });
  await mm.api("POST", `/channels/${c.id}/members`, { user_id: owner });
  await mm.createPost({ channel_id: c.id, message: `🎙️ Cuộc họp bắt đầu lúc ${at}. Phiên này tách từ phiên "${old.display_name}" nên em nhớ những gì anh đã trao đổi trước đó. Em theo dõi bình luận, giơ tay và soạn gợi ý trả lời ở đây; anh nhắn ở đây để giao việc cho em trong cuộc họp (trình chiếu, trả lời câu hỏi, bình chọn…).` });
  startMeetWatch(group, c.id, owner, "cuộc gọi bắt đầu · phiên mới");
  meetLobby(group, g).catch((e) => log(`họp: phòng chờ ${e?.message ?? e}`));
}
/** Phòng chờ: chưa có gì trên sân khấu thì chiếu cảnh mở đầu (tên + giờ bắt đầu lấy từ thẻ cuộc họp gần nhất của nhóm,
 *  có đếm ngược nếu chưa tới giờ) và bật nhạc phòng chờ, để ai vào sớm cũng thấy màn hình chờ và nghe nhạc. */
async function meetLobby(group: string, g: any) {
  const H = { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl, "content-type": "application/json" };
  const st: any = await (await fetch(`${meetBase}/${group}/state`, { headers: H, signal: AbortSignal.timeout(10_000) })).json();
  if (st.stage) return; // đã có người chiếu
  const ps: any = await mm.api("GET", `/channels/${group}/posts?per_page=60`).catch(() => null);
  const card = Object.values<any>(ps?.posts ?? {}).filter((p) => p.props?.flygo_meeting && !p.delete_at).sort((a, b) => b.create_at - a.create_at)[0]?.props?.flygo_meeting;
  const start = Number(card?.start) || 0;
  const hhmm = (ms: number) => new Date(ms).toLocaleTimeString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour: "2-digit", minute: "2-digit", hour12: false });
  const cmd = (b: any) => fetch(`${meetBase}/${group}/cmd`, { method: "POST", headers: H, body: JSON.stringify(b), signal: AbortSignal.timeout(10_000) });
  await cmd({ type: "stage", kind: "scene", scene: "opening", data: {
    tag: "Phòng chờ", title: String(card?.title || await chatName(g)), subtitle: "Mời mọi người chờ trong giây lát, buổi họp sắp bắt đầu.",
    ...(start ? { date: `${hhmm(start)} · ${new Date(start).toLocaleDateString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh" })}` } : {}),
    ...(start > Date.now() + 30_000 ? { starts_at: start } : {}),
  } });
  const man: any = await (await fetch(process.env.MEET_MUSIC ?? "https://chat.flygo.vn/static/plugins/flygo-update/music/meeting/manifest.json", { signal: AbortSignal.timeout(10_000) })).json();
  const lobby = (man.tracks ?? []).filter((t: any) => t.stage === "lobby");
  const t = lobby[Math.floor(Math.random() * lobby.length)];
  if (t) await cmd({ type: "audio", kind: "music", action: "play", url: `${String(man.base).replace(/\/+$/, "")}/${t.id}.mp3`, volume: 0.35, loop: true, title: t.title });
  log(`họp: phòng chờ nhóm ${group}${t ? ` · nhạc ${t.id}` : ""}`);
}
function startMeetWatch(group: string, session: string, owner: string, why: string) {
  const cur = meetWatches.get(group);
  if (cur && !cur.stopped) { cur.session = session; cur.owner = owner || cur.owner; return; }
  const w: MeetWatch = { group, session, owner: owner || cfg.ownerUserIds[0], ws: null, buf: [], timer: null, poll: null, stopped: false, names: new Map(), thread: null };
  meetWatches.set(group, w);
  log(`họp: theo dõi nhóm ${group} -> phiên ${session} (${why})`);
  const open = () => {
    if (w.stopped) return;
    const ws = new WebSocket(`${meetBase.replace(/^http/, "ws")}/ws?channel=${group}`, { headers: { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl } } as any);
    w.ws = ws;
    ws.onmessage = (e) => { try { onMeetEvent(w, JSON.parse(String(e.data))); } catch {} };
    ws.onclose = () => { w.ws = null; if (!w.stopped) setTimeout(open, 5000); };
    ws.onerror = () => {};
  };
  open();
  // Hết cuộc gọi (kiểm mỗi phút; cũng dừng ngay khi nhận sự kiện call_end của Calls).
  w.poll = setInterval(async () => { if (!(await callActive(group))) stopMeetWatch(group, "cuộc gọi đã kết thúc"); }, 60_000);
}
function stopMeetWatch(group: string, why: string) {
  const w = meetWatches.get(group);
  if (!w || w.stopped) return;
  w.stopped = true; meetWatches.delete(group);
  clearInterval(w.poll); clearTimeout(w.timer);
  try { w.ws?.close(); } catch {}
  log(`họp: dừng theo dõi nhóm ${group} (${why})`);
  if (w.buf.length) flushMeet(w).catch(() => {});
  // Hết cuộc gọi: xoá luồng bình luận trong phòng để cuộc họp sau mở luồng mới.
  if (/kết thúc/.test(why)) fetch(`${meetBase}/${group}/cmd`, { method: "POST", headers: { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl, "content-type": "application/json" }, body: JSON.stringify({ type: "meet_thread", root_id: null }) }).catch(() => {});
  mm.createPost({ channel_id: w.session, root_id: "", message: `🎙️ Em dừng theo dõi cuộc họp (${why}).`, props: { flygo_meet_batch: { group, stopped: true }, flygo_agent_owner: w.owner } }).catch(() => {});
}
function onMeetEvent(w: MeetWatch, ev: any) {
  if (ev?.from?.user_id) w.names.set(ev.from.user_id, ev.from.name);
  if (ev.type === "state") { w.thread = ev.state?.meet_thread ?? w.thread; return; }
  if (ev.type === "meet_thread") { w.thread = ev.root_id ?? null; return; } // luồng công khai lưu bình luận của cuộc họp
  if (ev.from?.user_id === BOT_ID) return; // sự kiện của chính bot
  const keep = ev.type === "comment" || (ev.type === "hand" && ev.up) || ev.type === "join" || ev.type === "leave";
  if (!keep) return;
  w.buf.push(ev);
  const urgent = w.buf.filter((x) => x.type === "comment" || x.type === "hand").length;
  if (urgent >= MEET_BATCH_MAX) { clearTimeout(w.timer); w.timer = null; flushMeet(w).catch((e) => log(`họp: ${e?.message ?? e}`)); }
  else if (urgent && !w.timer) w.timer = setTimeout(() => { w.timer = null; flushMeet(w).catch((e) => log(`họp: ${e?.message ?? e}`)); }, MEET_BATCH_MS);
}
async function flushMeet(w: MeetWatch) {
  const evs = w.buf.splice(0);
  if (!evs.some((x) => x.type === "comment" || x.type === "hand")) { w.buf.unshift(...evs); return; } // chỉ vào / ra: gộp vào lượt sau
  const hhmm = (ms: number) => new Date(ms).toLocaleTimeString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour: "2-digit", minute: "2-digit", hour12: false });
  const lines = evs.map((e) => e.type === "comment" ? `💬 [${hhmm(e.at)}] ${e.from.name}: ${e.text}` : e.type === "hand" ? `✋ [${hhmm(e.at)}] ${e.from.name} giơ tay` : `${e.type === "join" ? "👋" : "🚪"} [${hhmm(e.at)}] ${e.from.name} ${e.type === "join" ? "vào" : "rời"} phòng`);
  const nC = evs.filter((e) => e.type === "comment").length, nH = evs.filter((e) => e.type === "hand").length;
  const group = await mm.channel(w.group).catch(() => null);
  const trigger = await mm.createPost({
    channel_id: w.session, root_id: "", message: `🎙️ Cuộc họp: ${[nC ? `${nC} bình luận` : "", nH ? `${nH} giơ tay` : ""].filter(Boolean).join(", ")} mới\n${lines.join("\n")}${w.thread ? `\n🧵 Luồng bình luận: ${cfg.serverUrl}/_redirect/pl/${w.thread}` : ""}`,
    props: { flygo_meet_batch: { group: w.group, events: evs.length, ...(w.thread ? { thread_root: w.thread } : {}) }, flygo_agent_owner: w.owner, flygo_agent_requester: w.owner },
  });
  const post = { ...trigger, user_id: w.owner, message: lines.join("\n") } as Post;
  const key = mainKey(w.session);
  const text = [
    `(Sự kiện mới trong cuộc họp ở nhóm "${group ? await chatName(group) : w.group}", runner tự gửi cho bạn; chủ trì đang họp, không ngồi chờ ở đây.)`,
    ...lines,
    ``,
    `Việc của bạn: theo dõi ai nói gì và các câu hỏi còn mở. Với mỗi câu hỏi / ý kiến cần trả lời, gọi meeting_suggest(question_id ngắn tự đặt, ví dụ "q3"; who; question; answer_md) để soạn gợi ý trả lời cho chủ trì duyệt; câu đã có gợi ý thì gọi lại với cùng question_id để sửa. Lời chào / cảm ơn / tán gẫu thì bỏ qua.`,
    `KHÔNG tự đưa lên màn hình hay nói trong cuộc họp (meeting_show / meeting_slides / meeting_say…) khi chủ trì chưa đồng ý, trừ khi chủ trì đã bảo bạn tự trình bày.`,
    `Câu trả lời cuối của lượt này chỉ MỘT dòng tóm tắt (vd. "Đã soạn 2 gợi ý · còn 3 câu hỏi mở: q1, q3, q4").`,
  ].join("\n");
  enqueuedPosts.add(post.id);
  enqueue(key, async () => { await runTurn(post, key, text, {}).catch((e) => log(`họp: lượt ${e?.message ?? e}`)); });
}
async function meetSuggest(a: any): Promise<string> {
  const ctx = orchRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  const qid = String(a.question_id ?? "").trim().slice(0, 40) || `q${Date.now().toString(36)}`;
  const who = String(a.who ?? "").slice(0, 80), question = String(a.question ?? "").slice(0, 1000), answer = String(a.answer_md ?? "").slice(0, 6000);
  const status = ["draft", "shown", "answered", "dropped"].includes(a.status) ? a.status : "draft";
  if (!answer && status === "draft") return "Thiếu answer_md.";
  const ch = await mm.channel(ctx.channelId).catch(() => null);
  const group = meetChannelOf(ch);
  const badge = { draft: "💡 Gợi ý trả lời", shown: "📺 Đã đưa lên màn hình", answered: "✅ Đã trả lời", dropped: "🗑️ Bỏ qua" }[status as "draft"];
  const message = `💬 **${who || "Câu hỏi"}**${question ? `: ${question}` : ""} \`${qid}\`\n\n**${badge}:**\n${answer}`;
  const props = { flygo_meet_suggestion: { question_id: qid, who, question, answer_md: answer, meet_channel: group, status }, flygo_agent_owner: ctx.assigner ?? cfg.ownerUserIds[0] };
  const k = `${ctx.channelId} ${qid}`;
  const row = db.query("SELECT post_id FROM meet_suggestions WHERE key = ?").get(k) as { post_id: string } | null;
  if (row) {
    const old = await mm.api<Post>("GET", `/posts/${row.post_id}`).catch(() => null);
    if (old && !(old as any).delete_at) {
      await mm.api("PUT", `/posts/${row.post_id}/patch`, { message, props: { ...old.props, ...props } });
      ctx.card.step({ id: `meet-${qid}-${Date.now()}`, kind: "tool", title: `Cập nhật gợi ý ${qid}`, label: `Gợi ý ${qid}`, status: "done" });
      return `Đã cập nhật gợi ý ${qid} (tin #${row.post_id}).`;
    }
  }
  const p = await mm.createPost({ channel_id: ctx.channelId, root_id: "", message, props });
  db.query("INSERT OR REPLACE INTO meet_suggestions VALUES (?, ?, ?)").run(k, p.id, Date.now());
  ctx.card.step({ id: `meet-${qid}`, kind: "tool", title: `Gợi ý ${qid}: ${who}`, label: `Gợi ý ${qid}`, status: "done" });
  return `Đã gửi gợi ý ${qid} cho chủ trì (tin #${p.id}).`;
}
async function meetWatchTool(a: any): Promise<string> {
  const ctx = orchRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  const ch = await mm.channel(ctx.channelId).catch(() => null);
  const group = meetChannelOf(ch);
  if (a.action === "stop") { if (!meetWatches.has(group)) return "Đang không theo dõi cuộc họp nào."; stopMeetWatch(group, "chủ trì bảo dừng"); return "Đã dừng theo dõi cuộc họp."; }
  if (!aiOf(ch)) return "Chỉ theo dõi được từ phiên AI của nhóm.";
  if (!(await callActive(group))) return "Nhóm chưa có cuộc gọi nào đang diễn ra.";
  startMeetWatch(group, ctx.channelId, ctx.assigner ?? "", "chủ trì bảo theo dõi");
  return "Đang theo dõi cuộc họp: bình luận / giơ tay mới sẽ được gửi vào phiên này mỗi ~15 giây.";
}

// ---- tự đặt tên phiên AI: app tạo kênh "AI · <nhóm> · Phiên mới"; tin đầu của chủ -> assistant đặt tên ngắn theo chủ đề ----
const UNTITLED = "Phiên mới";
/** Kênh phiên AI chưa có tên (tên sau " · " thứ hai là "Phiên mới" hoặc trống): trả tiền tố "AI · <nhóm> · " giữ nguyên; null nếu không phải. */
function untitledPrefix(ch: any): string | null {
  if (!aiOf(ch)) return null;
  const dn = String(ch?.display_name ?? "");
  const parts = dn.split(" · ");
  if (parts[0] !== "AI" || parts.length < 2) return null;
  if (dn.endsWith(` · ${UNTITLED}`)) return dn.slice(0, -UNTITLED.length);
  if (parts.length === 2 || /\s·\s*$/.test(dn)) return `${dn.replace(/\s*·\s*$/, "")} · `;
  return null;
}
/** Tên phiên gọn: bỏ @tag, ngoặc kép, ký tự markdown, dấu câu cuối; tối đa 40 ký tự (cắt ở ranh giới từ). */
function cleanTitle(s: string, words = 0) {
  let t = String(s ?? "").split("\n").map((l) => l.trim()).find(Boolean) ?? "";
  t = t.replace(/@[\w.-]+/g, " ").replace(/["'“”‘’«»`*_#>~\[\]]/g, " ").replace(/\s+/g, " ").trim();
  if (words) t = t.split(" ").slice(0, words).join(" ");
  if (t.length > 40) { t = t.slice(0, 41); t = t.includes(" ") ? t.slice(0, t.lastIndexOf(" ")) : t.slice(0, 40); }
  return t.replace(/[\s.。,;:!?…·-]+$/u, "").trim();
}
async function setSessionTitle(channelId: string, name: string): Promise<string> {
  mm.forgetChannel(channelId);
  const ch = await mm.channel(channelId).catch(() => null);
  const prefix = untitledPrefix(ch);
  if (!prefix) return "Phiên này đã có tên, không đổi.";
  const t = cleanTitle(name);
  if ([...t].length < 2) return "Tên trống hoặc quá ngắn.";
  await mm.api("PUT", `/channels/${channelId}/patch`, { display_name: (prefix + t).slice(0, 64).trim() });
  mm.forgetChannel(channelId);
  log(`auto-title ${channelId} -> ${t}`);
  return `Đã đặt tên phiên: ${t}`;
}
async function sessionTitleTool(a: any): Promise<string> {
  const ctx = orchRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  return setSessionTitle(ctx.channelId, String(a.name ?? ""));
}

async function postOp(a: any): Promise<string> {
  const ctx = orchRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  const op = a.op === "edit" ? "edit" : a.op === "recall" ? "recall" : "";
  if (!op) return "Thao tác không hợp lệ.";
  const id = String(a.post_id ?? "").trim().replace(/^#/, "");
  if (!/^[a-z0-9]{26}$/.test(id)) return "post_id không hợp lệ (26 ký tự, lấy từ #id trong chat_history / chat_thread).";
  const p = await mm.api<Post>("GET", `/posts/${id}`).catch(() => null);
  if (!p || (p as any).delete_at) return `Không thấy tin ${id} (đã xoá hoặc bot không đọc được).`;
  if (p.user_id !== BOT_ID) return `Tin ${id} không phải do bạn (@${BOT_NAME}) gửi, nên không ${op === "edit" ? "sửa" : "thu hồi"} được. Chỉ sửa / thu hồi được tin của chính mình.`;
  const fa = p.props?.flygo_agent_message;
  // Câu trả lời đã xong của lượt trước (thẻ + chữ chung một post, final) thì được; thẻ trơn / lời xin duyệt / tin đang viết / lượt này thì không.
  if (p.props?.flygo_agent_approval || fa?.streaming || fa?.run_id === ctx.runId || p.props?.flygo_agent?.run_id === ctx.runId || (p.props?.flygo_agent && !fa?.final))
    return "Đây là thẻ tiến trình, lời xin duyệt hoặc câu trả lời đang viết của lượt này: không sửa / thu hồi bằng tool. Muốn đổi câu trả lời hiện tại thì cứ viết lại trong câu trả lời.";
  if (!isOwner(ctx.assigner ?? "") && p.channel_id !== ctx.channelId) return "Chỉ chủ bot mới nhờ sửa / thu hồi tin ở kênh khác được; người giao việc này chỉ thao tác được tin trong kênh hiện tại.";
  const where = p.channel_id === ctx.channelId ? "" : ` ở "${await chatName(await mm.channel(p.channel_id)).catch(() => p.channel_id)}"`;
  const short = clip((p.message || "(tệp)").replace(/\s+/g, " "), 50);
  const sid = `postop-${crypto.randomUUID().slice(0, 8)}`;
  const link = `${cfg.serverUrl}/_redirect/pl/${id}`;
  if (op === "edit") {
    const message = String(a.message ?? "");
    if (!message.trim()) return "Thiếu nội dung mới (muốn xoá hẳn thì dùng chat_recall_message).";
    try { await mm.api("PUT", `/posts/${id}/patch`, { message: defuseMentions(message) }); } // chỉ gửi message: props và tệp giữ nguyên
    catch (e: any) { ctx.card.step({ id: sid, kind: "tool", title: `Sửa tin${where} lỗi: "${short}"`, label: "Sửa tin (lỗi)", status: "error", detail: String(e?.message ?? e) }); return `Không sửa được: ${e?.message ?? e}`; }
    ctx.card.step({ id: sid, kind: "tool", title: `Đã sửa tin${where}: "${short}"`, label: "Sửa tin đã gửi", status: "done", detail: message.slice(0, 600) });
    return `Đã sửa tin ${id}${where}. ${link}`;
  }
  // thu hồi: tin gốc có trả lời thì cả luồng mất gốc -> ghi cảnh báo
  const replies = !p.root_id ? ((await mm.thread(id).catch(() => [] as Post[])).filter((x) => x.id !== id).length) : 0;
  try { await mm.deletePost(id); }
  catch (e: any) { ctx.card.step({ id: sid, kind: "tool", title: `Thu hồi tin${where} lỗi: "${short}"`, label: "Thu hồi tin (lỗi)", status: "error", detail: String(e?.message ?? e) }); return `Không thu hồi được: ${e?.message ?? e}`; }
  const reason = clip(String(a.reason ?? ""), 200);
  ctx.card.step({ id: sid, kind: "tool", title: `${replies ? "⚠️ " : ""}Đã thu hồi tin${where}: "${short}"${replies ? ` (tin gốc của luồng ${replies} trả lời)` : ""}`, label: replies ? "Thu hồi tin gốc của luồng" : "Thu hồi tin đã gửi", status: "done", detail: reason || undefined });
  return `Đã thu hồi tin ${id}${where}.${replies ? ` Lưu ý: đây là tin gốc của một luồng có ${replies} trả lời, luồng đó giờ mất tin gốc.` : ""}`;
}

async function reportOut(a: any): Promise<string> {
  const ctx = reportRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  const { outer, card } = ctx;
  const message = String(a.message ?? "").trim();
  if (!message) return "Thiếu nội dung báo cáo.";
  if (ctx.sent >= 3) return "Đã gửi báo cáo ra ngoài 3 lần trong lượt này.";
  if (outer.noAccess) return `Không gửi được: bạn (@${BOT_NAME}) không phải thành viên nhóm gắn với chat AI này (nhóm riêng tư, thường vì nhóm đã có trợ lý khác), nên không đọc hay gửi tin vào đó được. Báo người giao việc đúng lý do này, đưa sẵn nội dung báo cáo để họ tự gửi vào nhóm; muốn bạn gửi thẳng thì chủ nhóm phải thêm @${BOT_NAME} vào nhóm.`;
  const paths: string[] = [], bad: string[] = [];
  for (const f of Array.isArray(a.files) ? a.files.slice(0, 10) : []) {
    try { paths.push(insideDir(ctx.dir, String(f))); } catch (e: any) { bad.push(`${f}: ${e?.message ?? e}`); }
  }
  if (bad.length) return `Chưa gửi báo cáo vì tệp lỗi:\n- ${bad.join("\n- ")}`;
  const names = paths.map((p) => basename(p));
  const sid = `report-${crypto.randomUUID().slice(0, 8)}`;
  const title = `Báo cáo ra ngoài → ${outer.name}`;
  const detail = message + (names.length ? `\n📎 ${names.join(", ")}` : "");
  // Không cần duyệt (Sếp quyết 19/10): gửi luôn, thẻ ghi một bước "Báo cáo ra ngoài → <nơi> (đã gửi)".
  card.step({ id: sid, kind: "tool", title, status: "running", detail });
  let sentId = "";
  try {
    const fileIds: string[] = [];
    for (const p of paths) fileIds.push(await uploadTo(outer.channelId, p));
    const share = outer.ai ? { flygo_ai_report: { channel_id: ctx.channelId, post_id: ctx.postId } }
      : outer.secret ? { flygo_sub_report: { channel_id: ctx.channelId, post_id: ctx.postId } } : { flygo_thread_share: { root_id: outer.rootId, post_id: ctx.postId } };
    sentId = (await mm.createPost({
      channel_id: outer.channelId, root_id: "", file_ids: fileIds,
      message, // đúng nội dung agent viết, không thêm dòng tiêu đề (app hiện nguồn qua props share)
      props: { ...share, flygo_agent_owner: ctx.assigner, flygo_agent_report: true },
    }))?.id ?? "";
  } catch (e: any) {
    card.step({ id: sid, kind: "tool", title: `${title} (lỗi)`, status: "error", detail: `${detail}\n\n❌ ${e?.message ?? e}` });
    return `Gửi báo cáo ra ngoài lỗi: ${e?.message ?? e}`;
  }
  ctx.sent++;
  card.step({ id: sid, kind: "tool", title: `${title} (đã gửi)`, status: "done", detail });
  return `Đã gửi báo cáo ra chat chính của ${outer.name}${names.length ? ` kèm ${names.join(", ")}` : ""} (tin #${sentId}).`;
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
  const ai = aiOf(ch);
  const aiKind = await aiKindOf(ch);
  const aiDm = aiKind === "dm"; // phiên riêng của chat 1-1 (app 155)
  const aiProj = aiKind === "project"; // phiên của dự án (app 156)
  const tree: string[] = [];
  chain.forEach((l, i) => {
    const pad = i ? "  ".repeat(i - 1) + "└ " : "";
    tree.push(`  ${pad}Tầng ${l.tier} · ${l.kind === "ai" ? aiDm || aiProj ? "phiên " : "chat AI riêng " : ""}"${l.name}" (id ${l.id})${i === 0 && n ? aiDm ? " — chat 1-1" : aiProj ? " — dự án" : " — nhóm gốc" : ""}${l.rootId ? ` — tách từ tin ${l.rootId}: "${clip(l.rootText, 120)}"` : ""}${i === n ? " ← đang ở đây" : ""}`);
  });
  const kpad = "  " + "  ".repeat(n);
  const kidLines = [
    ...kids.secret.map((c) => `luồng bí mật con: "${c.display_name}" (id ${c.id})`),
    ...kids.open.map((p) => `luồng mở: "${clip(p.message.replace(mentionRe, ""), 60)}" (root_id ${p.id})${p.id === threadRoot ? " ← đang ở đây" : ""}`),
  ];
  mentionRe.lastIndex = 0;
  kidLines.forEach((t, i) => tree.push(`${kpad}${i === kidLines.length - 1 ? "└" : "├"} ${t}`));
  const isAi = chain[n].kind === "ai";
  const chanHelp = n
    ? `channel = ${isAi ? `"group" (= "parent", ${aiProj ? "dự án" : aiDm ? "chat 1-1" : "nhóm"} "${chain[n - 1].name}" id ${chain[n - 1].id}), ` : `"parent" (id ${chain[n - 1].id}), `}"top" (id ${chain[0].id}), "top" (id ${chain[0].id}), số tầng 0…${n}, hoặc id một tầng trong cây; bỏ trống = kênh hiện tại. Chỉ ĐỌC được kênh hiện tại và các tầng trên (bot phải là thành viên); luồng con chỉ để biết, không đọc.`
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
    ai && aiDm ? `- Đây là phiên riêng của ${aiOwner} với trợ lý, tách khỏi chat 1-1 "${n ? chain[n - 1].name : ai.group}" (id ${ai.group}); chat 1-1 không thấy phiên này. Đọc chat 1-1 bằng channel="group". KHÔNG gửi gì vào chat 1-1 trừ khi ${aiOwner} yêu cầu rõ (chat_report_out).` : "",
    ai && aiProj ? `- Đây là một phiên của ${aiOwner} với trợ lý trong dự án "${n ? chain[n - 1].name : ai.group}" (id ${ai.group}). Dự án gom các phiên làm cùng một việc; kênh dự án không phải nhóm chat, không có người khác đọc. Phiên khác của dự án không thấy phiên này.` : "",
    ai && !aiDm && !aiProj ? `- Đây là chat riêng của ${aiOwner} với trợ lý, gắn với nhóm "${n ? chain[n - 1].name : ai.group}" (id ${ai.group}); chỉ ${aiOwner} (và các bot của họ) thấy. Đọc nhóm bằng channel="group". KHÔNG gửi gì vào nhóm trừ khi ${aiOwner} yêu cầu rõ (chat_report_out). Tin mở đầu bằng trích dẫn "> **Tên:** …" là đang hỏi về tin đó của nhóm: tìm bằng chat_search(terms, channel="group") nếu cần thêm ngữ cảnh.` : "",
    ai && aiThreadOf(ch) ? `- Phiên AI này dành cho MỘT luồng của nhóm (root_id ${aiThreadOf(ch)}): bám theo luồng đó, đọc lại bằng chat_thread(root_id="${aiThreadOf(ch)}", channel="group").` : "",
    `- Cây nhóm${n && !isAi ? ` (bạn ở luồng bí mật tầng ${n}: ${chain.map((l) => l.name).join(" › ")})` : ""}:`,
    ...tree,
    `- Kênh hiện tại: id ${ch.id}; ${threadRoot ? `chủ đề hiện tại: root_id ${threadRoot}` : "đang ở chat chính (không trong chủ đề)"}`,
    n && !isAi ? `- Thông tin chỉ đi vào trong: các tầng trên không thấy luồng này; không gửi gì lên trên trừ chat_report_out.` : "",
    `## Công cụ flygo_chat`,
    `- chat_history(limit?, before_post_id?, channel?) · chat_thread(root_id?, channel?) · chat_search(terms, channel?)`,
    `- chat_files(scope?: thread|channel, root_id?, channel?) · chat_read_file(file_id, channel?) · chat_info() · chat_ancestors()`,
    `- chat_send_files(paths, message?): gửi tệp vào chủ đề hiện tại`,
    o.report ? `- chat_report_out(message, files?): báo cáo ra ${n ? `${isAi ? "chat chính của nhóm" : `tầng ${n - 1}`} "${chain[n - 1].name}"` : "chat chính của nhóm"}, chỉ khi được yêu cầu` : "",
    a2a ? `- list_agents() · ask_agent(bot, message, files?, data?): nhờ agent khác qua A2A` : "",
    `- schedule_create(title, prompt, kind, at? | repeat?, target?) · schedule_list() · schedule_update(id, …) · schedule_delete(id): lịch hẹn — bot tự chạy prompt vào giờ hẹn ở chỗ này (hoặc target), kết quả hiện ở đó. Giờ theo Asia/Ho_Chi_Minh. Tạo khi người dùng muốn việc lặp lại / làm vào giờ nào đó ("mỗi sáng 8h…", "5 giờ chiều mai nhắc…").`,
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

/** App 146+: chat AI riêng cho một luồng mở của nhóm — header có [flygo-ai-thread <root post id>]. */
const aiThreadOf = (ch: any) => /\[flygo-ai-thread (\w+)\]/.exec(ch?.header ?? "")?.[1] ?? "";

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
    // App "Tách phiên AI": mốc [flygo-ai-fork <kênh chat AI nguồn>] trong header -> tách từ phiên chính của kênh đó (cùng chủ, cùng nhóm).
    const fid = /\[flygo-ai-fork (\w+)\]/.exec(ch.header ?? "")?.[1];
    if (fid && fid !== ch.id) {
      const srcCh = await mm.channel(fid).catch(() => null);
      const src = aiOf(srcCh);
      if (src && src.owner === ai.owner && src.group === ai.group) return mainKey(fid);
      // App 155 "phiên riêng" của chat 1-1: tách thẳng từ chính chat 1-1 (DM chủ ↔ bot) mà phiên này gắn vào.
      if (fid === ai.group && srcCh?.type === "D" && isDmOf(srcCh, ai.owner)) return mainKey(fid);
      // Chuyển việc dở vào dự án (tab Agents): phiên của dự án do chính chủ sở hữu được nối tiếp từ chat chính của
      // chat 1-1 chủ↔bot, của phiên AI riêng cùng chủ, hoặc của nhóm mà cả chủ lẫn bot đều ở trong.
      const g = await mm.channel(ai.group).catch(() => null);
      if (srcCh && isProject(g) && new RegExp(`\\[flygo-agent-project owner=${ai.owner}\\]`).test(g?.purpose ?? "")) {
        if (srcCh.type === "D" ? isDmOf(srcCh, ai.owner) : src ? src.owner === ai.owner
          : !!(await mm.api("GET", `/channels/${fid}/members/${ai.owner}`).catch(() => null))) return mainKey(fid);
      }
      log(`chat AI ${ch.id}: bỏ qua flygo-ai-fork ${fid} (không cùng chủ / nhóm)`);
    }
    if (aiThreadOf(ch)) return ""; // phiên AI cho một luồng: chỉ tách khi có mốc flygo-ai-fork, không kế thừa
    const x = await mm.channel(ai.group).catch(() => null);
    const xl = linkOf(x);
    if (!xl || xl.kind !== "secret") return ""; // chat AI của nhóm gốc: không có chat AI cha
    // Thường chỉ có một chat AI cho mỗi (nhóm, chủ); lỡ có nhiều thì lấy chat có phiên của bot này dùng gần nhất.
    const cands = (await botChannels(ch.team_id, true)).filter((c) => { const a = aiOf(c); return !!a && c.id !== ch.id && !aiThreadOf(c) && a.group === xl.parent && a.owner === ai.owner; });
    const best = cands.map((c) => getSession(mainKey(c.id))).filter((x): x is Session => !!x?.session_id).sort((a, b) => b.updated_at - a.updated_at)[0];
    return best ? best.root_id : "";
  }
  if (l.kind === "secret" && aiOf(await mm.channel(l.parent).catch(() => null))) return ""; // cha là chat AI riêng: không tách ra
  return mainKey(l.parent);
}

/** props.flygo_ai_ref (chat AI riêng: "hỏi về tin này"): post id | { post_id } | danh sách. Đọc tin và luồng của nó,
 *  chỉ khi cả người hỏi lẫn bot đều là thành viên kênh chứa tin. */
async function aiRefNote(post: Post): Promise<string> {
  let ref: any = post.props?.flygo_ai_ref;
  if (!ref) return "";
  if (typeof ref === "string" && ref.trim().startsWith("{") || typeof ref === "string" && ref.trim().startsWith("[")) try { ref = JSON.parse(ref); } catch {}
  const ids = (Array.isArray(ref) ? ref : [ref]).map((r: any) => typeof r === "string" ? r : r?.post_id).filter((x: any) => typeof x === "string" && /^\w{26}$/.test(x)).slice(0, 5);
  const out: string[] = [];
  for (const id of ids) {
    const p = await mm.api<Post>("GET", `/posts/${id}`).catch(() => null);
    if (!p) { out.push(`- ${id}: không đọc được (bot không thấy tin này)`); continue; }
    const m = await channelMembers(p.channel_id).catch(() => null);
    if (!m || !m.bots.includes(BOT_ID) || !m.humans.includes(post.user_id)) { out.push(`- ${id}: không đọc (bạn hoặc người hỏi không ở kênh chứa tin này)`); continue; }
    const ch = await mm.channel(p.channel_id).catch(() => null);
    const thread = (await mm.thread(p.root_id || p.id).catch(() => [p])).filter((x) => !x.props?.flygo_agent_message?.streaming);
    const N = 40, shown = thread.length > N ? [thread[0], ...thread.slice(-(N - 1))] : thread;
    out.push(`### Tin ${id} ở "${ch ? await chatName(ch) : p.channel_id}" (kênh ${p.channel_id})${thread.length > 1 ? `, cả luồng ${thread.length} tin${thread.length > N ? ` (hiện tin gốc + ${N - 1} tin cuối)` : ""}` : ""}\n${await fmtPosts(shown)}`);
  }
  return out.length ? `\n\n## Tin được tham chiếu (người hỏi đang hỏi về các tin này)\n${out.join("\n")}` : "";
}

/** Chat AI riêng: tin chat chính của nhóm gắn từ lần trước (lượt đầu: các tin gần nhất), để nắm tình hình nhóm. */
async function groupNews(outer: Outer, root: string, first: boolean): Promise<string> {
  const gid = outer.channelId;
  const member = (await channelMembers(gid).catch(() => null))?.bots.includes(BOT_ID);
  if (!member) return `\n## ${outer.dm ? "Chat 1-1" : "Nhóm"} "${outer.name}"\n(Bạn chưa là thành viên nhóm này nên chưa đọc được tin của nhóm. Nhờ chủ thêm bạn vào nhóm.)`;
  const since = first ? 0 : (db.query("SELECT ts FROM group_seen WHERE root_id = ?").get(root) as { ts: number } | null)?.ts ?? 0;
  const posts = (await mm.channelPosts(gid, 100).catch(() => [] as Post[]))
    .filter((p) => isMainPost(p) && !p.props?.flygo_agent_message?.streaming && p.create_at > since);
  if (posts.length) db.query("INSERT OR REPLACE INTO group_seen VALUES (?, ?)").run(root, posts[posts.length - 1].create_at);
  const N = 30, shown = posts.slice(-N);
  const text = await fmtPosts(shown);
  const where = outer.dm ? `chat 1-1 "${outer.name}"` : `chat chính nhóm "${outer.name}"`;
  if (!text) return first ? `\n## ${where[0].toUpperCase()}${where.slice(1)}\n(chưa có tin)` : "";
  return `\n## ${first ? "Tin gần đây" : "Tin mới"} ở ${where} (id ${gid}) — chỉ để nắm tình hình${posts.length > N ? `; còn ${posts.length - N} tin cũ hơn, đọc bằng chat_history(channel="group")` : ""}\n${text}`;
}

// ---- chat / luồng được tag kèm quyền tạm (app gửi props.flygo_refs; relay /ref cấp quyền đọc / gửi cho đúng bot này) ----
interface RefItem { ref_id: string; kind: "chat" | "thread"; channel_id: string; root_id?: string; name: string }
interface RefGrant { grant_id: string; expires_at: number; write: boolean; server: string; items: RefItem[] }
/** Relay /ref: cấu hình refRelay, không có thì trạm đẩy cùng tên miền với server ("chat.x" -> "push.x"). */
const refRelay = () => ((cfg as any).refRelay as string | undefined)?.replace(/\/+$/, "") || cfg.serverUrl.replace(/\/\/chat\./, "//push.").replace(/\/+$/, "");
function saveRefs(post: Post, root: string) {
  let raw: any = post.props?.flygo_refs;
  if (typeof raw === "string") try { raw = JSON.parse(raw); } catch { raw = null; }
  // Một bot: {grant_id, …, bot_id}; nhiều bot trong một tin: {grants:[…]} — mỗi runner chỉ giữ grant của chính mình.
  for (const r of Array.isArray(raw?.grants) ? raw.grants : raw ? [raw] : []) if (!r?.bot_id || r.bot_id === BOT_ID) saveGrant(r, root);
}
function saveGrant(r: any, root: string) {
  if (!r?.grant_id || !Array.isArray(r.items) || !(Number(r.expires_at) > Date.now())) return;
  const g: RefGrant = { grant_id: String(r.grant_id), expires_at: Number(r.expires_at), write: !!r.write, server: String(r.server ?? ""),
    items: r.items.filter((x: any) => x?.ref_id && x?.channel_id).slice(0, 10).map((x: any) => ({ ref_id: String(x.ref_id), kind: x.kind === "thread" && x.root_id ? "thread" : "chat", channel_id: String(x.channel_id), ...(x.root_id ? { root_id: String(x.root_id) } : {}), name: String(x.name ?? x.channel_id).slice(0, 200) })) };
  if (!g.items.length) return;
  db.query("INSERT OR REPLACE INTO ref_grants VALUES (?, ?, ?, ?)").run(g.grant_id, root, JSON.stringify(g), g.expires_at);
}
const refGrants = (root: string): RefGrant[] => {
  db.query("DELETE FROM ref_grants WHERE expires_at < ?").run(Date.now() - 86_400_000); // giữ 1 ngày sau hạn để báo "hết hạn" cho rõ
  return (db.query("SELECT data FROM ref_grants WHERE root_id = ? ORDER BY expires_at").all(root) as { data: string }[]).map((x) => JSON.parse(x.data));
};
const hhmm = (ms: number) => new Date(ms).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false, hour: "2-digit", minute: "2-digit", day: "2-digit", month: "2-digit" });
/** Dòng ngữ cảnh: các chat / luồng đang được tag cho phiên này (còn hạn). */
function tagNote(post: Post, root: string): string {
  saveRefs(post, root);
  const live = refGrants(root).filter((g) => g.expires_at > Date.now());
  if (!live.length) return "";
  const lines = live.flatMap((g) => g.items.map((x) => `- ref_id "${x.ref_id}": ${x.kind === "thread" ? "luồng" : "chat"} ${x.name} — ${g.write ? "đọc + gửi tin" : "chỉ đọc"}, tới ${hhmm(g.expires_at)}`));
  return `\n\n## Chat được tag cho bạn (quyền tạm, bạn KHÔNG là thành viên các chat này)\n${lines.join("\n")}\nĐọc CÓ CHỌN LỌC để tiết kiệm token: ref_read(ref_id, q) để tìm theo từ khoá, limit nhỏ (10–30), before=<id tin cũ nhất đã đọc> để xem trang trước; ref_thread(ref_id, root) khi cần cả một luồng. ref_post(ref_id, message, root_id?) chỉ khi được phép gửi VÀ người giao việc muốn gửi vào đó.`;
}
async function refTool(op: string, a: any): Promise<string> {
  const ctx = orchRuns.get(a.key);
  if (!ctx) return "Phiên không còn chạy.";
  const id = String(a.ref_id ?? "");
  const all = refGrants(ctx.root);
  const g = all.find((x) => x.items.some((i) => i.ref_id === id));
  if (!g) return all.length ? `Không có ref_id "${id}" trong các chat được tag của phiên này.` : "Phiên này chưa có chat nào được tag. Nhờ người dùng tag chat / luồng cần dùng.";
  if (g.expires_at <= Date.now()) return "Quyền đã hết hạn, nhờ người dùng tag lại chat này.";
  const item = g.items.find((i) => i.ref_id === id)!;
  const call = async (method: string, path: string, body?: any) => {
    const r = await fetch(`${refRelay()}${path}`, { method, headers: { Authorization: `Bearer ${cfg.botToken}`, "X-MM-Server": cfg.serverUrl, ...(body ? { "content-type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(30_000) });
    const j: any = await r.json().catch(() => ({}));
    if (r.status === 410) throw new Error("Quyền đã hết hạn, nhờ người dùng tag lại chat này.");
    if (!r.ok) throw new Error(j?.error ?? `relay ${r.status}`);
    return j;
  };
  const fmtPosts = (ps: any[]) => ps.map((p) => `[${new Date(p.at).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false })}] ${p.user}${p.root_id ? ` (trả lời trong luồng ${p.root_id})` : ""} #${p.id}: ${p.message}${p.files?.length ? ` [tệp: ${p.files.join(", ")}]` : ""}`).join("\n") || "(không có tin nào)";
  try {
    if (op === "read") {
      const q = new URLSearchParams({ grant: g.grant_id, ref: id, limit: String(Math.max(1, Math.min(50, Number(a.limit) || 30))), ...(a.before ? { before: String(a.before) } : {}), ...(a.q ? { q: String(a.q) } : {}) });
      const r = await call("GET", `/ref/read?${q}`);
      return `${item.name}${a.q ? ` — tìm "${a.q}"` : ""}:\n${fmtPosts(r.posts ?? [])}${r.more ? `\n(còn tin cũ hơn: ref_read với before="${r.posts?.[0]?.id ?? ""}")` : ""}`;
    }
    if (op === "thread") {
      const root = String(a.root ?? item.root_id ?? "");
      const r = await call("GET", `/ref/thread?${new URLSearchParams({ grant: g.grant_id, ref: id, root })}`);
      return `Luồng ${root} trong ${item.name}${r.truncated ? " (dài: tin gốc + 199 tin cuối)" : ""}:\n${fmtPosts(r.posts ?? [])}`;
    }
    if (op === "post") {
      if (!g.write) return "Quyền với chat này chỉ cho đọc, không gửi được. Nhờ người dùng tag lại và cho phép gửi.";
      const sid = `refpost-${crypto.randomUUID().slice(0, 8)}`;
      const r = await call("POST", "/ref/post", { grant: g.grant_id, ref: id, message: String(a.message ?? ""), ...(a.root_id ? { root_id: String(a.root_id) } : {}), from_channel: ctx.channelId });
      ctx.card.step({ id: sid, kind: "tool", title: `Đã gửi vào ${item.name}`, label: clip(`Gửi vào ${item.name}`, 60), status: "done", detail: String(a.message ?? "").slice(0, 600) });
      return `Đã gửi vào ${item.name}${r.post_id ? ` (tin #${r.post_id})` : ""}.`;
    }
    return "Thao tác không hợp lệ.";
  } catch (e: any) { return `Lỗi: ${e?.message ?? e}`; }
}

async function runTurn(post: Post, root: string, rawText: string, out?: { text?: string; error?: string; onStart?: (ac: AbortController) => void }) {
  markSeen(post.id); enqueuedPosts.delete(post.id);
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
  const refNote = (await aiRefNote(post).catch((e) => `\n(Không đọc được tin được tham chiếu: ${e?.message ?? e})`)) + tagNote(post, root);
  const firstLine = (t: string) => t.replace(mentionRe, "").replace(/\s+/g, " ").trim().slice(0, 60).trim();
  mentionRe.lastIndex = 0;
  const threadTitle = threadRoot
    ? firstLine(threadRoot === post.id ? post.message : (await mm.api<Post>("GET", `/posts/${threadRoot}`).catch(() => post)).message) || "Luồng"
    : subParentOf(ch) ? `Bí mật · ${ch.display_name}` : aiOf(ch) ? "Chat AI riêng" : "Luồng chính";
  const sessTitle = `${chat} · ${threadTitle}`;
  // Phiên AI mới chưa có tên: nhờ assistant đặt tên theo tin đầu (tool chat_session_title); quên thì runner lấy vài chữ đầu.
  const needTitle = !threadRoot && isOwner(post.user_id) && !!untitledPrefix(ch);
  // Cuộc họp: nhóm của phiên (hoặc chính kênh) đang có cuộc gọi -> bật tool meeting_*, phiên AI của chủ thì tự theo dõi bình luận.
  const meetCh = meetChannelOf(ch);
  const meeting = await callActive(meetCh);
  if (meeting && aiOf(ch) && isOwner(post.user_id) && !threadRoot) startMeetWatch(meetCh, post.channel_id, post.user_id, "chủ trì nhắn trong phiên AI khi đang họp");
  const meetNote = meeting ? `\n(Nhóm ${aiOf(ch) ? `"${(await mm.channel(meetCh).then(chatName).catch(() => meetCh))}" của phiên này` : "này"} đang có cuộc họp trực tuyến. Bạn có tool meeting_* để dẫn họp: meeting_state (ai đang họp, giơ tay, bình luận), meeting_say (NÓI bằng giọng cho cả phòng nghe), meeting_show / meeting_slides / meeting_web / meeting_draw (chiếu lên màn hình chung), meeting_people (mời phát biểu, tắt mic, làm nổi bật), meeting_suggest (soạn gợi ý trả lời câu hỏi cho chủ trì duyệt), meeting_watch (bật / tắt theo dõi bình luận), meeting_music_* (nhạc nền theo giai đoạn). Chỉ đưa lên màn hình / nói / phát nhạc trong cuộc họp khi chủ trì yêu cầu hoặc đã cho bạn tự trình bày. Khi tự dẫn cả buổi, gợi ý trình tự nhạc: lobby khi chờ người vào → stinger transition + nhạc opening khi mở màn → present nhỏ khi chiếu slide → transition giữa các phần → qa khi hỏi đáp → closing khi kết thúc.)` : "";
  const titleNote = needTitle ? `\n(Phiên này chưa có tên. Gọi chat_session_title đúng một lần với tên ngắn tiếng Việt 2–6 từ (tối đa 40 ký tự), nói đúng chủ đề tin nhắn này; không dấu chấm cuối, không ngoặc kép. Không nhắc chuyện đặt tên trong câu trả lời.)` : "";
  const peers: string[] = (post as any).a2a_peers ?? [];
  const peerNote = (peers.length && a2a
    ? `\n(Tin này tag thêm ${peers.map((u) => `@${u}`).join(", ")}. Bạn là agent chủ trì: nhờ các agent đó bằng tool ask_agent (A2A), tổng hợp kết quả rồi trả lời trong chat. Các agent kia không tự trả lời trong chat.)`
    : "") + a2aPeersNote(post);
  const outer = await outerOf(ch, threadRoot, threadTitle);
  const reportNote = outer?.ai
    ? outer.noAccess ? `\n(Đây là chat AI riêng, nhưng bạn không phải thành viên nhóm gắn với nó nên không đọc hay gửi vào nhóm được. Nếu được yêu cầu báo ra ngoài: nói rõ lý do này và đưa sẵn nội dung để người giao việc tự gửi.)`
    : outer.dm ? `\n(Đây là phiên riêng tách khỏi chat 1-1 "${outer.name}": chat 1-1 không thấy phiên này. Chỉ khi người giao việc yêu cầu rõ mới gửi vào chat 1-1, bằng chat_report_out.)` : `\n(Đây là chat AI riêng: nhóm "${outer.name}" không thấy. Chỉ khi người giao việc yêu cầu rõ mới gửi vào nhóm, bằng chat_report_out.)`
    : outer
    ? `\n(Có tool chat_report_out để gửi báo cáo ra chat chính của ${outer.secret ? "nhóm cha" : "nhóm"} "${outer.name}". Chỉ dùng khi người giao việc yêu cầu báo cáo ra ngoài (vd. "xong thì báo cáo ra ngoài", "gửi báo cáo ra nhóm") hoặc đã dặn trước là xong thì báo.${outer.secret ? " Đây là luồng bí mật: báo cáo được gửi thẳng ra nhóm ngoài, chỉ đưa vào nội dung được phép công khai cho nhóm ngoài." : ""})`
    : "";
  const outerCtx = outer?.ai ? await groupNews(outer, root, !session) : outer
    ? `\n## Nhóm ngoài\n${outer.secret ? `Bạn đang ở luồng bí mật "${outer.label}" (kênh riêng, nhóm ngoài không thấy), tách từ ${outer.top ? `luồng bí mật "${outer.name}" (id ${outer.channelId}) thuộc nhóm gốc "${outer.top}"` : `nhóm "${outer.name}" (id ${outer.channelId})`}. Báo cáo ra ngoài chỉ lên một tầng: tới "${outer.name}".` : `Bạn đang ở trong luồng "${outer.label}" của nhóm "${outer.name}" (id ${outer.channelId}); chat chính của nhóm nằm ngoài luồng.`}\nTin gốc (id ${outer.rootId}): ${outer.rootText.slice(0, 1500) || "(không đọc được)"}`
    : "";
  // Lượt đầu của luồng / luồng bí mật: tách phiên cha (cùng bot, cùng engine) để mang theo hiểu biết. Chỉ chảy vào trong.
  let forkFrom = "", forkNote = "";
  const pkey = brandNew ? await parentKeyOf(ch, threadRoot) : "";
  let parent = pkey ? getSession(pkey) : null;
  // Rào chắn: không tách khi kênh con có người không ở kênh cha (ngữ cảnh cha sẽ lộ ra), hoặc đã quá FORK_MAX_DEPTH tầng.
  if (parent?.session_id && parent.engine === ENGINE) {
    const pchId = pkey.startsWith("ch:") ? pkey.slice(3) : parent.channel_id;
    if (pchId && pchId !== ch.id) {
      const [cm, pm] = await Promise.all([channelMembers(ch.id).catch(() => null), channelMembers(pchId).catch(() => null)]);
      const outsiders = cm && pm ? cm.humans.filter((h) => !pm.humans.includes(h)) : ["?"];
      if (outsiders.length) { log(`phiên ${root}: không tách từ ${pkey} (có ${outsiders.length} người không ở kênh cha)`); parent = null; }
    }
    if (parent && forkDepth(pkey) >= FORK_MAX_DEPTH) { log(`phiên ${root}: không tách từ ${pkey} (đã ${FORK_MAX_DEPTH} tầng tách)`); parent = null; }
  }
  let forkedFrom: { key: string; name: string; depth: number } | null = null;
  if (parent?.session_id && parent.engine === ENGINE) {
    const pch = pkey.slice(3);
    const pc = pch === ch.id ? null : await mm.channel(pch).catch(() => ({ id: pch, name: pch }));
    const pname = !pc ? "chat chính của nhóm này" : aiOf(pc) ? `chat AI riêng "${pc.display_name || pc.name}"` : `chat chính của chat cha "${await chatName(pc)}"`;
    forkFrom = parent.session_id;
    forkedFrom = { key: pkey, name: pname, depth: forkDepth(pkey) + 1 };
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
    const chName = ch.type === "D" ? "tin nhắn riêng" : aiOf(ch) ? (await aiKindOf(ch)) === "project" ? `phiên "${ch.display_name}" của dự án "${await chatName(await mm.channel(aiOf(ch)!.group))}"` : outer?.dm ? `phiên riêng tách khỏi chat 1-1 "${outer.name}"` : `chat AI riêng (cột phải) gắn với nhóm "${outer?.name ?? chat}"` : `nhóm "${ch.display_name}"`;
    prompt = [
      forkNote,
      `Bạn đang được giao việc trong ${chName} trên Flygo Chat.`,
      ...(await Promise.all([["Tin nhắn gần đây trong nhóm (ngữ cảnh)", before], ["Chủ đề đang trao đổi", thread]].map(async ([h, ps]) => {
        const t = await fmtPosts(ps as Post[]);
        return t ? `\n## ${h}\n${t}` : "";
      }))),
      outerCtx,
      `\n${block}`,
      `\n## Việc ${owner} giao ${trigger}\n${text}${filesNote(post)}${quoteNote}${refNote}${peerNote}${reportNote}${titleNote}${meetNote}`,
    ].filter(Boolean).join("\n");
  } else {
    const recent = inline ? (await mm.channelPosts(post.channel_id, 50)).filter(isMainPost) : await mm.thread(root);
    // Chỉ các tin sau lượt trả lời gần nhất của bot (việc cũ đã qua thì không nhắc lại).
    const lastBot = Math.max(session.last_seen_at, ...recent.filter((p) => p.user_id === BOT_ID).map((p) => p.create_at));
    const since = recent.filter((p) => p.create_at > lastBot && p.create_at < post.create_at && p.id !== post.id && p.user_id !== BOT_ID);
    const sinceText = since.length ? await fmtPosts(since) : "";
    prompt = [block ? `${block}\n` : "", outer?.ai && outerCtx ? `${outerCtx.trim()}\n` : "", sinceText ? `## Tin khác ${inline ? "trong nhóm" : "trong chủ đề"} từ lần trả lời trước (chỉ để tham khảo, không cần trả lời)\n${sinceText}\n` : "", `## ${owner} nhắn ${trigger}\n${text}${filesNote(post)}${quoteNote}${refNote}${peerNote}${reportNote}${titleNote}${meetNote}`].filter(Boolean).join("\n");
  }

  // Model / mức suy nghĩ người dùng chọn trên app: props.flygo_agent_config = { "<bot>": { model, effort } }. Thiếu = mặc định.
  const opts = botOptions();
  let want: any = post.props?.flygo_agent_config;
  if (typeof want === "string") try { want = JSON.parse(want); } catch { want = null; }
  want = want?.[BOT_NAME] ?? want?.[BOT_ID] ?? {}; // khoá theo username hiện tại (hoặc id bot)
  const bad: string[] = [];
  const model = want.model && !opts.models.includes(want.model) ? (bad.push(`model ${want.model}`), opts.default.model) : want.model || opts.default.model;
  const effort = want.effort && !opts.efforts.includes(want.effort) ? (bad.push(`mức ${want.effort}`), opts.default.effort) : want.effort || opts.default.effort;
  // Chế độ quyền: props.flygo_agent_config["<bot>"].mode = manual | acceptEdits | plan | auto (thiếu = mặc định của engine).
  // "Bỏ qua kiểm tra" (bypassPermissions): chỉ Claude, chỉ chủ bot (như "Luôn cho phép").
  const okMode = (m: any) => PERM_MODES.includes(m) && (m !== "bypassPermissions" || (ENGINE === "claude" && isOwner(post.user_id)));
  const mode: PermMode | undefined = okMode(want.mode) ? want.mode : undefined;
  if (want.mode && !mode) bad.push(`chế độ ${want.mode}`);
  const runConfig = { model, effort, mode: mode ?? defaultMode(), ...(bad.length ? { note: `Không hỗ trợ ${bad.join(", ")}, dùng mặc định.` } : {}) };
  const planNote = mode === "plan" && ENGINE === "codex" ? `\n(Chế độ Lập kế hoạch: chỉ đọc và tìm hiểu, KHÔNG sửa tệp hay chạy lệnh làm thay đổi. Trả lời bằng kế hoạch từng bước, rồi hỏi ${owner} duyệt; ${owner} chuyển chế độ khác thì mới làm.)` : "";

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
  card.forkedFrom = forkedFrom;
  if (forkedFrom) db.query("INSERT OR REPLACE INTO fork_depth VALUES (?, ?)").run(root, forkedFrom.depth);
  session = session ?? { root_id: root, channel_id: post.channel_id, engine: engineName, session_id: "", status: "running", title, card_post_id: card.postId, last_seen_at: 0, updated_at: 0 };
  session.status = "running"; session.card_post_id = card.postId; session.last_seen_at = post.create_at; session.updated_at = Date.now();
  saveSession(session);
  if (post.id) db.query("INSERT OR REPLACE INTO turn_triggers VALUES (?, ?, ?, ?)").run(root, post.id, post.channel_id, Date.now());

  const ac = new AbortController();
  running.set(root, { ac, assigner: post.user_id, channel_id: post.channel_id, posts: () => [reply.id].filter(Boolean) });
  out?.onStart?.(ac);
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
    reply.hold(true);
    const r = await askUser(where, qs, post.user_id, ac.signal).finally(() => { waitingHuman--; reply.hold(false); });
    card.step({ id: sid, kind: "approval", title: "answers" in r ? `Đã trả lời: ${r.answers.map(answerText).join(" · ").slice(0, 100)}` : `Không trả lời: ${title}`, status: "answers" in r ? "done" : "error" });
    card.setStatus("running");
    return r;
  };
  runsByKey.set(runId, ask);
  askByKey.set(runId, askQ);
  skillRuns.set(runId, { assigner: post.user_id, ask, dir });
  schedRuns.set(runId, { assigner: post.user_id, channel_id: post.channel_id, root_id: threadRoot });
  orchRuns.set(runId, { card, dir, root, channelId: post.channel_id, signal: ac.signal, calls: 0, chat, waiting: new Map(), assigner: post.user_id, runId });
  const bypass = isBypass(root);
  if (bypass) card.step({ id: "bypass", kind: "approval", title: BYPASS_NOTE, status: "done" });
  else if (mode === "bypassPermissions") card.step({ id: "bypass", kind: "approval", title: "🔓 Bỏ qua kiểm tra quyền (chủ bot chọn cho lượt này)", status: "done" });
  if (outer) reportRuns.set(runId, { outer, card, reply, assigner: post.user_id, channelId: post.channel_id, postId: post.id, dir, signal: ac.signal, sent: 0 });

  let release = () => {};
  try {
    release = await acquireSlot(ac.signal, () => { card.setStatus("queued"); reply.touch(); });
    if (card.status === "queued") card.setStatus("thinking");
    const res = await engines[engineName].runTurn(
      {
        sessionId: session.session_id || undefined,
        forkFrom: session.session_id ? undefined : forkFrom || undefined,
        cwd: dir,
        prompt: prompt + planNote,
        persona: botPersona(),
        ...skillDirs(),
        title: sessTitle,
        group: chat,
        model,
        effort,
        fallbackModel: opts.default.model,
        bypass,
        mode,
        mcpEnv: mcpEnvFor(root, {
          MM_URL: cfg.serverUrl, MM_TOKEN: cfg.botToken, CHANNEL_ID: post.channel_id, ROOT_ID: threadRoot,
          RUN_KEY: runId, WORKDIR: dir, OWNER_ID: post.user_id,
          ...(a2a ? { A2A_ROLE: "orchestrator" } : {}),
          ...(outer ? { REPORT_OUT: "1" } : {}),
          MEET_BASE: meetBase, ...(meeting ? { MEET_CHANNEL: meetCh } : {}),
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
    if (out) out.text = res.text;
    session.status = "done";
  } catch (e: any) {
    const cancelled = ac.signal.aborted;
    card.error = cancelled ? (stopping ? STOP_NOTE : "") : String(e?.message ?? e).slice(0, 400);
    if (out) out.error = cancelled ? "đã dừng" : card.error;
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
    release();
    publishMeta().catch(() => {});
    orchRuns.delete(runId);
    if (needTitle) setSessionTitle(post.channel_id, cleanTitle(rawText, 6)).catch((e) => log(`auto-title ${post.channel_id}: ${e?.message ?? e}`)); // chưa đặt được thì lấy 6 chữ đầu
    skillRuns.delete(runId);
    schedRuns.delete(runId);
    if (mcpCtx.get(root)?.RUN_KEY === runId) mcpCtx.delete(root);
    reportRuns.delete(runId);
    session.updated_at = Date.now();
    saveSession(session);
    db.query("DELETE FROM turn_triggers WHERE root_id = ? AND post_id = ?").run(root, post.id);
  }
}

/** Xét một tin (một lần). Có lượt chạy thì lượt tự ghi "đã xử lý" khi bắt đầu. */
function handlePosted(post: Post, channelType: string) {
  if (inFlight.has(post.id) || enqueuedPosts.has(post.id) || isSeen(post.id)) return;
  inFlight.add(post.id);
  onPosted(post, channelType)
    .catch((e) => log(`onPosted error ${e}`))
    .finally(() => { inFlight.delete(post.id); if (!enqueuedPosts.has(post.id)) markSeen(post.id); });
}
const inFlight = new Set<string>();
const CATCHUP_MS = 15 * 60_000;
let catchingUp = false;
/** Khởi động / nối lại websocket / định kỳ: xét các tin trong 15 phút gần nhất ở các kênh bot là thành viên mà chưa xử lý.
 *  `only`: chỉ quét một kênh (bot vừa được thêm vào). */
async function catchUp(why = "nối lại", only?: string) {
  if (stopping || (!only && catchingUp)) return;
  if (!only) catchingUp = true;
  try {
    const since = Date.now() - CATCHUP_MS;
    const chans = new Map<string, any>();
    if (only) {
      const c = await mm.api<any>("GET", `/channels/${only}`).catch(() => null);
      if (c) chans.set(c.id, c);
    } else {
      const teams = await mm.api<any[]>("GET", `/users/${BOT_ID}/teams`).catch(() => [] as any[]);
      for (const t of teams) for (const c of await mm.api<any[]>("GET", `/users/${BOT_ID}/teams/${t.id}/channels`).catch(() => [] as any[])) chans.set(c.id, c);
    }
    let n = 0;
    for (const c of chans.values()) {
      if ((c.last_post_at ?? 0) < since) continue;
      const r = await mm.api<any>("GET", `/channels/${c.id}/posts?since=${since}`).catch(() => null);
      const all = Object.values<any>(r?.posts ?? {}) as (Post & { delete_at?: number })[];
      // Bot đã đăng sau tin này ở cùng chỗ (chat chính / luồng) -> coi như đã trả lời (an toàn cả khi bảng seen_posts mới có).
      const botAfter = (p: Post) => all.some((b) => b.user_id === BOT_ID && b.create_at > p.create_at && (b.root_id === (p.root_id || "") || b.root_id === p.id));
      const ps = all.filter((p) => p.create_at >= since && !p.delete_at && p.user_id !== BOT_ID && !(p.type && p.type !== "") && !isSeen(p.id) && !inFlight.has(p.id) && !botAfter(p))
        .sort((a, b) => a.create_at - b.create_at);
      for (const p of ps) { n++; handlePosted(p, c.type); }
    }
    if (n) log(`bắt bù (${why}): xét lại ${n} tin chưa xử lý (15 phút gần nhất)`);
  } finally { if (!only) catchingUp = false; }
}
// Lưới an toàn khi websocket mất tin mà không báo lỗi.
setInterval(() => catchUp("định kỳ").catch((e) => log(`bắt bù: ${e?.message ?? e}`)), 5 * 60_000);

// ---- WebSocket Mattermost ----
const typing = mm.connect((ev) => {
  if (ev.event === "hello") { emit({ event: "connected" }); catchUp().catch((e) => log(`bắt bù: ${e?.message ?? e}`)); }
  if (ev.event === "posted") {
    const post = JSON.parse(ev.data.post) as Post;
    handlePosted(post, ev.data.channel_type);
  } else if (ev.event === "user_updated") {
    const uid = ev.data?.user?.id;
    if (uid) { mm.forgetUser(uid); usernameCache.clear(); } // đổi tên / tên hiển thị
    if (uid === BOT_ID) refreshAllow(); // sự kiện có thể không mang bot_description: đọc lại từ /users/me
  } else if (ev.event === "channel_updated") {
    const id = ev.broadcast?.channel_id ?? ev.data?.channel_id ?? "";
    mm.forgetChannel(id);
    purposeOwner.delete(id);
  } else if (ev.event === "user_added" || ev.event === "user_removed") {
    const cid = ev.broadcast?.channel_id ?? ev.data?.channel_id;
    memberCache.delete(cid);
    // Bot vừa vào kênh: tin gửi trước đó không đi qua websocket của bot.
    if (ev.event === "user_added" && ev.data?.user_id === BOT_ID && cid) setTimeout(() => catchUp("vào kênh", cid).catch((e) => log(`bắt bù: ${e?.message ?? e}`)), 2000);
  } else if (ev.event === "custom_com.mattermost.calls_call_start" || ev.event === "custom_com.mattermost.calls_call_end") {
    // Cuộc gọi bắt đầu ở nhóm có phiên AI của chủ -> theo dõi bình luận vào phiên AI gần nhất; kết thúc -> dừng.
    const gid = ev.broadcast?.channel_id ?? ev.data?.channelID ?? ev.data?.channel_id ?? "";
    if (gid && ev.event.endsWith("call_end")) stopMeetWatch(gid, "cuộc gọi đã kết thúc");
    else if (gid) meetStart(gid).catch((e) => log(`họp: ${e?.message ?? e}`));
  } else if (ev.event === "direct_added" || ev.event === "group_added" || ev.event === "channel_created") {
    const cid = ev.broadcast?.channel_id ?? ev.data?.channel_id ?? ev.data?.channel?.id;
    if (cid) setTimeout(() => catchUp("kênh mới", cid).catch((e) => log(`bắt bù: ${e?.message ?? e}`)), 2000);
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
      emoji: isPaused() ? "double_vertical_bar" : "large_green_circle", text: `${isPaused() ? "Tạm tắt" : "Đang chạy"} trên ${host} · ${ENGINE}`,
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

const RERUN_MAX_AGE_MS = 30 * 60_000;
/** Khởi động: phiên còn ghi "running" (lần trước runner chết / bị tắt cứng giữa lượt) -> chốt thẻ, LUÔN báo vào chỗ giao việc,
 *  và tự chạy lại lượt đó một lần (tin giao việc còn mới, chưa chạy lại lần nào). */
async function recoverInterrupted() {
  const rows = db.query("SELECT * FROM sessions WHERE status = 'running' AND updated_at > ?").all(Date.now() - 7 * 86400_000) as Session[];
  for (const s of rows) {
    try {
      const tr = db.query("SELECT post_id FROM turn_triggers WHERE root_id = ?").get(s.root_id) as { post_id: string } | null;
      db.query("DELETE FROM turn_triggers WHERE root_id = ?").run(s.root_id);
      if (s.root_id.startsWith("a2a:")) { s.status = "cancelled"; saveSession(s); continue; }
      const main = s.root_id.startsWith("ch:");
      const posts = main ? await mm.channelPosts(s.channel_id, 40) : await mm.thread(s.root_id);
      let fixed = 0;
      for (const p of posts) if (p.create_at >= s.updated_at - 3600_000 && (await finalizeStale(p))) fixed++;
      s.status = "cancelled"; saveSession(s);
      const trigger = tr ? await mm.api<Post>("GET", `/posts/${tr.post_id}`).catch(() => null) : null;
      const where = { channel_id: s.channel_id, root_id: main ? "" : s.root_id };
      const props = { ...(main ? {} : { flygo_reply: "thread" }), flygo_agent_owner: trigger?.user_id ?? cfg.ownerUserIds[0] };
      const retried = trigger && !!db.query("SELECT 1 FROM turn_retried WHERE post_id = ?").get(trigger.id);
      if (trigger && !(trigger as any).delete_at && !retried && Date.now() - trigger.create_at < RERUN_MAX_AGE_MS && !isPaused()) {
        db.query("INSERT OR REPLACE INTO turn_retried VALUES (?, ?)").run(trigger.id, Date.now());
        await mm.createPost({ ...where, message: "⚠️ Lượt trước bị ngắt giữa chừng (trợ lý khởi động lại). Em chạy lại ngay.", props });
        log(`phiên ${s.root_id}: lượt bị bỏ dở (đã chốt ${fixed} post), chạy lại tin ${trigger.id}`);
        const ch = await mm.channel(trigger.channel_id);
        (trigger as any).resume = true;
        const sr = trigger.props?.flygo_schedule_run;
        if (trigger.user_id === BOT_ID && sr) { const sc = schedules.get(String(sr.schedule_id ?? "")); if (sc) runScheduled(sc, trigger, true).catch((e) => log(`chạy lại lịch: ${e}`)); }
        else onPosted(trigger, ch.type).catch((e) => log(`chạy lại ${trigger.id}: ${e}`));
        continue;
      }
      await mm.createPost({ ...where, message: fixed ? STOP_NOTE : "⚠️ Lượt trước bị ngắt giữa chừng (trợ lý khởi động lại) và chưa xong. Nhờ gửi lại yêu cầu.", props });
      log(`phiên ${s.root_id}: lượt bị bỏ dở, đã chốt ${fixed} post${retried ? " (đã chạy lại một lần trước đó)" : ""}`);
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
  const sr = trigger.props?.flygo_schedule_run;
  if (trigger.user_id === BOT_ID && sr) { // lượt của lịch hẹn: chạy lại đúng lịch đó
    const s = schedules.get(String(sr.schedule_id ?? ""));
    if (s) await runScheduled(s, trigger, true);
    return;
  }
  await onPosted(trigger, ch.type);
}

// ---- lịch hẹn ("Hẹn giờ", src/schedule.ts) ----
// Bản ghi lưu ở bảng schedules; mỗi 30 giây xét lịch đến hạn. Đến hạn: đăng "⏰ Lịch hẹn: <tên>" (props.flygo_schedule_run)
// ở chỗ đích rồi chạy prompt như một lượt của người tạo lịch (phiên bình thường của chỗ đó; duyệt: người tạo hoặc chủ bot).
// Trễ quá 1 giờ (máy tắt / runner không chạy) thì bỏ qua lần đó và ghi lại. Danh sách gửi relay -> props.flygo_schedules.
db.run(`CREATE TABLE IF NOT EXISTS schedules (id TEXT PRIMARY KEY, data TEXT)`);
const schedules = new Map<string, Schedule>();
for (const r of db.query("SELECT data FROM schedules").all() as { data: string }[]) { try { const x = JSON.parse(r.data); schedules.set(x.id, x); } catch {} }
const SCHED_LATE_MS = 3600_000;
const SCHED_MAX = 50;
const schedRunning = new Set<string>();
function saveSchedule(s: Schedule) { schedules.set(s.id, s); db.query("INSERT OR REPLACE INTO schedules VALUES (?, ?)").run(s.id, JSON.stringify(s)); }
function dropSchedule(id: string) { schedules.delete(id); db.query("DELETE FROM schedules WHERE id = ?").run(id); }
const schedPublic = (s: Schedule) => { const { history: _h, ...rest } = s; return rest; };
let schedPubTimer: Timer | null = null;
/** Gửi danh sách lịch lên relay (props.flygo_schedules), gộp các thay đổi liền nhau. */
function publishSchedules() {
  if (schedPubTimer) clearTimeout(schedPubTimer);
  schedPubTimer = setTimeout(async () => {
    schedPubTimer = null;
    const items = [...schedules.values()].sort((a, b) => a.created_at - b.created_at).map(schedPublic);
    const r = await fetch(`${relayBase}/meta`, { method: "POST", headers: { ...relayAuth, "content-type": "application/json" }, body: JSON.stringify({ schedules: { v: 1, at: Date.now(), items } }), signal: AbortSignal.timeout(15_000) })
      .then((x) => x.json()).catch((e) => ({ error: String(e) }));
    if (!r?.ok) log(`lịch hẹn: relay không nhận danh sách (${r?.error ?? "?"})`);
  }, 1_000);
}
function recordRun(s: Schedule, rec: RunRecord) {
  const cur = schedules.get(s.id);
  if (!cur) return;
  cur.last_run = rec;
  cur.history = [...(cur.history ?? []), rec].slice(-HISTORY_MAX);
  saveSchedule(cur);
  publishSchedules();
  log(`lịch hẹn "${cur.title}": ${rec.status}${rec.error ? ` (${rec.error})` : ""}`);
}
/** Chỗ đích dùng được không: bot và người tạo đều trong kênh, kênh chưa lưu trữ, luồng (nếu có) còn. */
async function targetProblem(t: Schedule["target"], creator: string): Promise<string> {
  const ch = await mm.channel(t.channel_id).catch(() => null);
  if (!ch || ch.delete_at) return "kênh không còn hoặc bot không thấy kênh";
  const m = await channelMembers(t.channel_id).catch(() => null);
  if (!m?.bots.includes(BOT_ID)) return "bot không còn là thành viên kênh";
  if (!m.humans.includes(creator)) return "người tạo lịch không còn ở kênh";
  if (t.root_id) {
    const r = await mm.api<Post>("GET", `/posts/${t.root_id}`).catch(() => null);
    if (!r || (r as any).delete_at || r.channel_id !== t.channel_id) return "luồng không còn";
  }
  return "";
}
/** Đến hạn (hoặc "chạy ngay"): kiểm tra, đăng tin "⏰ Lịch hẹn" rồi chạy lượt. */
async function fireSchedule(s: Schedule, manual = false) {
  const now = Date.now();
  if (manual && schedRunning.has(s.id)) return;
  if (!manual) {
    const due = s.next_run_at ?? now;
    s.next_run_at = s.kind === "once" ? null : nextRun(s, Math.max(now, due));
    if (s.kind === "once") s.enabled = false;
    saveSchedule(s);
    publishSchedules();
    if (schedRunning.has(s.id)) return recordRun(s, { at: now, status: "skipped", error: "lần trước chưa chạy xong" });
    if (now - due > SCHED_LATE_MS) return recordRun(s, { at: now, status: "skipped", error: `trễ ${Math.round((now - due) / 60_000)} phút (máy tắt / runner không chạy lúc đến giờ)` });
  }
  if (isPaused()) return recordRun(s, { at: now, status: "skipped", error: "bot đang tạm tắt" });
  if (!isAllowed(s.created_by)) return recordRun(s, { at: now, status: "skipped", error: "người tạo lịch không còn được giao việc cho bot" });
  const why = await targetProblem(s.target, s.created_by);
  if (why) return recordRun(s, { at: now, status: "skipped", error: why });
  const root = s.target.root_id ?? "";
  const trigger = await mm.createPost({
    channel_id: s.target.channel_id, root_id: root, message: `⏰ Lịch hẹn: **${s.title}**`,
    props: { ...(root ? { flygo_reply: "thread" } : {}), flygo_schedule_run: { schedule_id: s.id, manual }, flygo_agent_owner: s.created_by, flygo_agent_requester: s.created_by },
  }).catch((e) => { recordRun(s, { at: now, status: "error", error: `không đăng được tin: ${e?.message ?? e}` }); return null; });
  if (trigger) await runScheduled(s, trigger, false);
}
/** Chạy prompt của lịch như một lượt của người tạo, tại tin "⏰ Lịch hẹn" (trigger). */
async function runScheduled(s: Schedule, trigger: Post, resume: boolean) {
  schedRunning.add(s.id);
  const post = { ...trigger, user_id: s.created_by, message: s.prompt } as Post;
  if (resume) (post as any).resume = true;
  const key = threadRootOf(post) || mainKey(post.channel_id);
  const { rule } = schedDescribe(s);
  const by = await mm.displayName(s.created_by).catch(() => s.created_by);
  const text = `(Lịch hẹn "${s.title}" của ${by} — ${rule}; tự chạy, ${by} không ngồi chờ: làm xong rồi báo kết quả ở đây.)\n${s.prompt}`;
  const out: { text?: string; error?: string } = {};
  enqueuedPosts.add(post.id);
  enqueue(key, async () => {
    try { await runTurn(post, key, text, out); }
    finally {
      schedRunning.delete(s.id);
      recordRun(s, { at: Date.now(), status: out.error ? "error" : "done", post_id: trigger.id, ...(out.error ? { error: out.error } : {}) });
    }
  });
}
function scheduleTick() {
  const now = Date.now();
  for (const s of schedules.values()) if (s.enabled && s.next_run_at && s.next_run_at <= now) fireSchedule(s).catch((e) => log(`lịch hẹn ${s.id}: ${e?.message ?? e}`));
}
/** Thao tác lịch (tool của model, hoặc app qua relay). by = người thao tác. */
async function scheduleAction(by: string, action: string, a: any, here?: Schedule["target"]): Promise<{ ok: boolean; schedule?: any; schedules?: any[]; error?: string }> {
  const fail = (error: string) => ({ ok: false, error });
  const mine = (s: Schedule) => s.created_by === by || isOwner(by);
  if (action === "list") return { ok: true, schedules: [...schedules.values()].filter((s) => isOwner(by) || s.created_by === by || (here && s.target.channel_id === here.channel_id)).map(schedPublic) };
  if (action === "create") {
    if (!isAllowed(by)) return fail("chỉ chủ bot hoặc người được chủ cho phép mới tạo lịch hẹn");
    if (schedules.size >= SCHED_MAX) return fail(`bot đã có ${SCHED_MAX} lịch hẹn, xoá bớt trước`);
    const input = { ...(a ?? {}) };
    if (!input.target && here) input.target = here;
    const n = schedNormalize(input);
    if (typeof n === "string") return fail(n);
    const why = await targetProblem(n.target, by);
    if (why) return fail(`chỗ đích không dùng được: ${why}`);
    const next = n.enabled ? nextRun(n, Date.now()) : null;
    if (n.enabled && next === null) return fail(n.kind === "once" ? "thời điểm đã qua" : "không tính được lần chạy kế tiếp");
    const s: Schedule = { id: crypto.randomUUID(), ...n, created_by: by, created_at: Date.now(), updated_at: Date.now(), next_run_at: next, history: [] };
    saveSchedule(s); publishSchedules();
    log(`tạo lịch hẹn "${s.title}" (${schedDescribe(s).rule}) bởi ${by}`);
    return { ok: true, schedule: schedPublic(s) };
  }
  const s = schedules.get(String(a?.id ?? ""));
  if (!s) return fail("không có lịch hẹn này");
  if (!mine(s)) return fail("chỉ người tạo lịch hoặc chủ bot mới sửa / xoá được");
  if (action === "delete") { dropSchedule(s.id); publishSchedules(); log(`xoá lịch hẹn "${s.title}" bởi ${by}`); return { ok: true }; }
  if (action === "run_now") { fireSchedule(s, true).catch((e) => log(`lịch hẹn ${s.id}: ${e?.message ?? e}`)); return { ok: true, schedule: schedPublic(s) }; }
  let patch: any = action === "pause" ? { enabled: false } : action === "resume" ? { enabled: true } : action === "update" ? { ...(a?.schedule ?? a ?? {}) } : null;
  if (!patch) return fail(`thao tác ${action} không hỗ trợ`);
  delete patch.id; delete patch.created_by; delete patch.history; delete patch.last_run; delete patch.next_run_at;
  if (patch.repeat?.freq === "once") { patch.kind = "once"; delete patch.repeat; }
  if (patch.repeat && !patch.kind) patch.kind = "repeat";
  if (patch.kind === "repeat") patch.at = undefined;
  if (patch.kind === "once") patch.repeat = undefined;
  const n = schedNormalize(patch, s);
  if (typeof n === "string") return fail(n);
  if (n.target.channel_id !== s.target.channel_id || n.target.root_id !== s.target.root_id) {
    const why = await targetProblem(n.target, s.created_by);
    if (why) return fail(`chỗ đích không dùng được: ${why}`);
  }
  const next = n.enabled ? nextRun(n, Date.now()) : null;
  if (n.enabled && next === null) return fail(n.kind === "once" ? "thời điểm đã qua" : "không tính được lần chạy kế tiếp");
  const u: Schedule = { ...s, ...n, ...(n.kind === "once" ? { repeat: undefined } : { at: undefined }), next_run_at: next, updated_at: Date.now() };
  saveSchedule(u); publishSchedules();
  log(`${action} lịch hẹn "${u.title}" bởi ${by}`);
  return { ok: true, schedule: schedPublic(u) };
}
const schedRuns = new Map<string, { assigner: string; channel_id: string; root_id: string }>(); // run key -> chỗ của lượt
/** Tool schedule_* của model: người thao tác = người giao việc của lượt; chỗ mặc định = chỗ của lượt. */
async function scheduleTool(op: string, a: any): Promise<string> {
  const ctx = schedRuns.get(a.key);
  if (!ctx) return "Lịch hẹn chỉ tạo / sửa được trong lượt chat với người dùng.";
  const { key: _k, ...args } = a ?? {};
  const here = { channel_id: ctx.channel_id, ...(ctx.root_id ? { root_id: ctx.root_id } : {}) };
  const r = await scheduleAction(ctx.assigner, op, op === "update" ? { id: args.id, schedule: args } : args, here);
  if (!r.ok) return `Lỗi: ${r.error}`;
  const line = (s: any) => { const d = schedDescribe(s as Schedule); return `- [${s.id}] "${s.title}" · ${d.rule} · ${s.enabled ? `lần tới ${d.next}` : "đang tắt"}${s.target.root_id ? " · trong luồng" : ""}${s.last_run ? ` · lần trước ${s.last_run.status}${s.last_run.error ? ` (${s.last_run.error})` : ""}` : ""}`; };
  if (op === "list") return r.schedules!.length ? `Lịch hẹn (${r.schedules!.length}):\n${r.schedules!.map(line).join("\n")}` : "Chưa có lịch hẹn nào.";
  if (op === "delete") return "Đã xoá lịch hẹn.";
  return `Đã ${op === "create" ? "tạo" : "cập nhật"} lịch hẹn:\n${line(r.schedule)}`;
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
emit({ event: "ready", a2a: a2a ? cfg.a2a.relay : null, bot: { id: BOT_ID, username: BOT_NAME }, owners: cfg.ownerUserIds, allow: allowIds, engine: ENGINE, options: botOptions(), doctor: report, workspace_root: cfg.workspaceRoot });
// Kiểm kê kỹ năng / model: lúc khởi động, sau mỗi lượt (Claude chỉ báo kỹ năng khi chạy), và mỗi giờ.
setTimeout(() => publishMeta().catch(() => {}), 5_000);
setInterval(() => publishMeta().catch(() => {}), 3600_000);
recoverInterrupted().catch((e) => log(`recoverInterrupted: ${e}`));
// Lịch hẹn: app gọi qua relay (POST /a2a/schedules -> {t:"sched"}), xét đến hạn mỗi 30 giây, đăng danh sách lúc khởi động.
// Chọn thư mục dự án trên app: relay (GET /a2a/dirs) -> {t:"dirs"}; chỉ chủ bot, chỉ trong projectRoots.
if (a2a) a2a.onDirs = (m) => {
  let r: any;
  try { r = listDirs(String(m.user?.id ?? ""), String(m.path ?? "")); } catch (e: any) { r = { ok: false, status: 500, error: String(e?.message ?? e) }; }
  a2a!.send({ t: "dirs_res", cid: m.cid, result: r });
};
if (a2a) a2a.onSched = (m) => {
  const u = m.user ?? {};
  scheduleAction(String(u.id ?? ""), String(m.body?.action ?? ""), m.body?.action === "create" ? m.body?.schedule : m.body)
    .catch((e) => ({ ok: false, error: String(e?.message ?? e) }))
    .then((r) => a2a!.send({ t: "sched_res", cid: m.cid, result: r }));
};
setTimeout(scheduleTick, 10_000);
setInterval(scheduleTick, 30_000);
setTimeout(publishSchedules, 6_000);
log(`runner sẵn sàng · engine ${ENGINE} · thư mục làm việc ${cfg.workspaceRoot}`);
}

