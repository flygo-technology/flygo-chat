// flygo-agent runner: chạy trên máy cá nhân, nối bot Mattermost với Codex/Claude.
// - Chủ bot @tag bot (hoặc nhắn DM, hoặc trả lời trong chủ đề đã có phiên) -> agent làm việc trong chủ đề đó.
// - Thẻ tiến trình (props.flygo_agent) cập nhật trực tiếp; kết quả cuối gửi kiểu thread_broadcast.
// - Duyệt quyền: post "Cần Sếp duyệt" trong chủ đề, chủ bot thả 👍 / 👎.
import { Database } from "bun:sqlite";
import { cpSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { RunCard } from "./card";
import { MessageStream } from "./messages";
import { CONFIG_DIR, ROOT, loadConfig, type EngineName } from "./config";
import { ClaudeEngine } from "./engines/claude";
import { CodexEngine } from "./engines/codex";
import type { ApprovalDecision, ApprovalRequest, Engine } from "./engines/types";
import { MM, type Post } from "./mm";

const log = (s: string) => console.log(`${new Date().toISOString()} ${s}`);
const cfg = await loadConfig();
const mm = new MM(cfg.serverUrl, cfg.botToken);
const me = await mm.me();
const BOT_ID: string = me.id;
const BOT_NAME: string = me.username;
log(`bot @${BOT_NAME} (${BOT_ID}), chủ: ${cfg.ownerUserIds.join(", ")}`);

// (Chuyển tiếp TCP cho model provider do src/codex-shared.ts đảm nhận.)

// ---- trạng thái phiên ----
mkdirSync(CONFIG_DIR, { recursive: true });
const db = new Database(join(CONFIG_DIR, "state.db"));
db.run(`CREATE TABLE IF NOT EXISTS sessions (
  root_id TEXT PRIMARY KEY, channel_id TEXT, engine TEXT, session_id TEXT, status TEXT,
  title TEXT, card_post_id TEXT, last_seen_at INTEGER, updated_at INTEGER)`);
interface Session { root_id: string; channel_id: string; engine: EngineName; session_id: string; status: string; title: string; card_post_id: string; last_seen_at: number; updated_at: number }
const getSession = (root: string) => db.query("SELECT * FROM sessions WHERE root_id = ?").get(root) as Session | null;
const saveSession = (s: Session) =>
  db.query(`INSERT OR REPLACE INTO sessions VALUES ($root_id,$channel_id,$engine,$session_id,$status,$title,$card_post_id,$last_seen_at,$updated_at)`)
    .run(Object.fromEntries(Object.entries(s).map(([k, v]) => [`$${k}`, v])) as any);

// ---- engine ----
const mcpCommand = { command: process.execPath, args: [join(ROOT, "src", "mcp-chat.ts")] };
const engines: Record<EngineName, Engine> = {
  codex: new CodexEngine(cfg, mcpCommand, log),
  claude: new ClaudeEngine(cfg, mcpCommand, log),
};

// ---- duyệt quyền ----
const pendingApprovals = new Map<string, (d: ApprovalDecision) => void>(); // post_id -> resolve
const runsByKey = new Map<string, (req: ApprovalRequest) => Promise<ApprovalDecision>>();

async function askApproval(where: { channel_id: string; root_id: string }, engine: string, req: ApprovalRequest): Promise<ApprovalDecision> {
  const body = (status: string) =>
    `✋ **Cần Sếp duyệt** · ${engine}\n\`\`\`\n${req.title}\n\`\`\`${req.detail ? `\n${req.detail}` : ""}\n${status}`;
  const props = (status: string) => ({ flygo_reply: "thread", flygo_agent_approval: { kind: req.kind, title: req.title, detail: req.detail, status } });
  const post = await mm.createPost({ ...where, message: body("Thả 👍/👎 để Xác nhận / Từ chối."), props: props("pending") });
  await mm.react(post.id, BOT_ID, "+1").catch(() => {});
  await mm.react(post.id, BOT_ID, "-1").catch(() => {});
  const decision = await new Promise<ApprovalDecision | "expired">((resolve) => {
    pendingApprovals.set(post.id, resolve);
    setTimeout(() => resolve("expired"), cfg.approvalTimeoutSec * 1000);
  });
  pendingApprovals.delete(post.id);
  const label = decision === "accept" ? "✅ Sếp đã cho phép." : decision === "decline" ? "🚫 Sếp đã từ chối." : "⌛ Hết hạn, coi như từ chối.";
  await mm.patchPost(post.id, { message: body(label), props: props(decision === "accept" ? "accepted" : decision === "decline" ? "declined" : "expired") }).catch(() => {});
  return decision === "accept" ? "accept" : "decline";
}

// HTTP nội bộ: MCP server của Claude gọi /approve
Bun.serve({
  hostname: "127.0.0.1",
  port: cfg.localPort,
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
const persona = await Bun.file(join(ROOT, "profiles", cfg.profile, "persona.md")).text();

async function workspaceFor(channelId: string) {
  const ch = await mm.channel(channelId);
  const name = (ch.type === "D" ? `dm-${channelId}` : ch.name || channelId).replace(/[^a-zA-Z0-9._-]/g, "_");
  const dir = join(cfg.workspaceRoot, name);
  mkdirSync(dir, { recursive: true });
  const skills = join(ROOT, "profiles", cfg.profile, "skills");
  if (existsSync(skills) && readdirSync(skills).length) {
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
    if (p.user_id === BOT_ID && p.props?.flygo_agent) continue; // bỏ thẻ tiến trình
    const t = new Date(p.create_at).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false });
    out.push(`[${t}] ${await mm.displayName(p.user_id)}: ${p.message}${filesNote(p)}`);
  }
  return out.join("\n");
}

const mentionRe = new RegExp(`@${BOT_NAME.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "gi");

// ---- xử lý tin ----
const queues = new Map<string, Promise<void>>();
const running = new Map<string, AbortController>(); // root_id -> đang chạy

function enqueue(root: string, job: () => Promise<void>) {
  const next = (queues.get(root) ?? Promise.resolve()).then(job, job).catch((e) => log(`job error ${e}`));
  queues.set(root, next);
}

async function onPosted(post: Post, channelType: string) {
  if (post.user_id === BOT_ID || (post.type && post.type !== "")) return;
  const root = post.root_id || post.id;
  const session = getSession(root);
  const isOwner = cfg.ownerUserIds.includes(post.user_id);
  const mentioned = mentionRe.test(post.message);
  mentionRe.lastIndex = 0;
  const isDM = channelType === "D";
  if (!(mentioned || isDM || session)) return;

  if (!isOwner) {
    if (mentioned) {
      const owners = await Promise.all(cfg.ownerUserIds.map((id) => mm.user(id).then((u) => `@${u.username}`)));
      await mm.createPost({ channel_id: post.channel_id, root_id: root, message: `Em là trợ lý riêng của ${owners.join(", ")}, em chỉ nhận việc từ chủ của em ạ.`, props: { flygo_reply: "thread" } });
    }
    return; // tin của người khác chỉ là ngữ cảnh
  }

  const text = post.message.replace(mentionRe, "").trim();
  if (session && running.has(root) && /^(dừng|dung|stop|\/stop)$/i.test(text)) {
    running.get(root)!.abort();
    return;
  }
  enqueue(root, () => runTurn(post, root, text));
}

async function runTurn(post: Post, root: string, rawText: string) {
  let session = getSession(root);
  let engineName: EngineName = (session?.engine as EngineName) ?? cfg.defaultEngine;
  let text = rawText;
  const m = /^(codex|claude)\b[:,]?\s*/i.exec(text);
  if (m && !session) { engineName = m[1].toLowerCase() as EngineName; text = text.slice(m[0].length); }
  if (!text) text = "(Sếp gọi em nhưng chưa nói việc gì — hãy hỏi lại Sếp cần gì.)";

  const { dir, ch } = await workspaceFor(post.channel_id);
  const owner = await mm.displayName(post.user_id);
  let prompt: string;
  if (!session) {
    const thread = post.root_id ? (await mm.thread(post.root_id)).filter((p) => p.id !== post.id) : [];
    const rootPost = thread[0];
    const before = (await mm.channelPosts(post.channel_id, 20, rootPost?.id ?? post.id)).filter((p) => !p.root_id);
    const chName = ch.type === "D" ? "tin nhắn riêng" : `nhóm "${ch.display_name}"`;
    prompt = [
      `Bạn đang được giao việc trong ${chName} trên Flygo Chat.`,
      before.length ? `\n## Tin nhắn gần đây trong nhóm (ngữ cảnh)\n${await fmtPosts(before)}` : "",
      thread.length ? `\n## Chủ đề đang trao đổi\n${await fmtPosts(thread)}` : "",
      `\n## Việc ${owner} giao\n${text}${filesNote(post)}`,
      `\n(Tool flygo_chat: chat_history / chat_thread / chat_search để đọc tin cũ; chat_info để xem nhóm và thành viên; chat_files / chat_read_file để đọc tệp đính kèm.)`,
    ].join("\n");
  } else {
    const since = (await mm.thread(root)).filter((p) => p.create_at > session!.last_seen_at && p.id !== post.id && p.user_id !== BOT_ID);
    prompt = [since.length ? `## Tin mới trong chủ đề kể từ lần trước\n${await fmtPosts(since)}\n` : "", `## ${owner} nhắn\n${text}${filesNote(post)}`].join("\n");
  }

  const runId = crypto.randomUUID();
  const title = text.split("\n")[0].slice(0, 80);
  const card = new RunCard(mm, { channel_id: post.channel_id, root_id: root }, runId, engineName, title);
  await card.create();
  const stream = new MessageStream(mm, { channel_id: post.channel_id, root_id: root }, runId, engineName);
  session = session ?? { root_id: root, channel_id: post.channel_id, engine: engineName, session_id: "", status: "running", title, card_post_id: card.postId, last_seen_at: 0, updated_at: 0 };
  session.status = "running"; session.card_post_id = card.postId; session.last_seen_at = post.create_at; session.updated_at = Date.now();
  saveSession(session);

  const ac = new AbortController();
  running.set(root, ac);
  const sendTyping = () => typing("user_typing", { channel_id: post.channel_id, parent_id: root });
  sendTyping();
  const typingTimer = setInterval(sendTyping, 4000);

  const where = { channel_id: post.channel_id, root_id: root };
  const ask = async (req: ApprovalRequest) => {
    const sid = `approval-${crypto.randomUUID()}`;
    card.step({ id: sid, kind: "approval", title: `Chờ duyệt: ${req.title.slice(0, 100)}`, status: "waiting" });
    card.setStatus("awaiting_approval");
    await card.flush();
    const d = await askApproval(where, engineName, req);
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
        mcpEnv: {
          MM_URL: cfg.serverUrl, MM_TOKEN: cfg.botToken, CHANNEL_ID: post.channel_id, ROOT_ID: root,
          RUNNER_URL: `http://127.0.0.1:${cfg.localPort}`, RUN_KEY: runId, WORKDIR: dir,
        },
      },
      {
        step: (s) => card.step(s),
        text: (t) => stream.update(t),
        approval: ask,
        session: (id) => { card.sessionId = id; session!.session_id = id; saveSession(session!); },
      },
      ac.signal,
    );
    card.usage = res.usage;
    card.sessionId = res.sessionId;
    card.setStatus("done");
    await card.finish();
    await stream.finish(res.text);
    session.status = "done";
  } catch (e: any) {
    const cancelled = ac.signal.aborted;
    card.error = cancelled ? "" : String(e?.message ?? e).slice(0, 400);
    card.setStatus(cancelled ? "cancelled" : "error");
    await card.finish();
    await stream.finish("", false);
    if (!cancelled) await mm.createPost({ ...where, message: `❌ Em gặp lỗi: ${card.error}`, props: { flygo_reply: "thread" } });
    session.status = cancelled ? "cancelled" : "error";
    log(`run ${runId} ${session.status}: ${e?.message ?? e}`);
  } finally {
    clearInterval(typingTimer);
    running.delete(root);
    runsByKey.delete(runId);
    session.updated_at = Date.now();
    saveSession(session);
  }
}

// ---- WebSocket Mattermost ----
const typing = mm.connect((ev) => {
  if (ev.event === "posted") {
    const post = JSON.parse(ev.data.post) as Post;
    onPosted(post, ev.data.channel_type).catch((e) => log(`onPosted error ${e}`));
  } else if (ev.event === "reaction_added") {
    const r = JSON.parse(ev.data.reaction);
    const resolve = pendingApprovals.get(r.post_id);
    if (!resolve || !cfg.ownerUserIds.includes(r.user_id)) return;
    if (r.emoji_name === "+1" || r.emoji_name === "white_check_mark") resolve("accept");
    else if (r.emoji_name === "-1" || r.emoji_name === "x") resolve("decline");
  }
}, log);

log(`runner sẵn sàng · engine mặc định ${cfg.defaultEngine} · thư mục làm việc ${cfg.workspaceRoot}`);
