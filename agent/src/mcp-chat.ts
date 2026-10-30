// MCP server (stdio) cho một phiên agent. Phạm vi cố định theo env: chỉ đọc kênh CHANNEL_ID.
// Tools: chat_thread, chat_history, chat_search, approve (dùng cho --permission-prompt-tool của Claude).
// Kênh bí mật lồng nhau: các tool đọc nhận thêm `channel` ("parent" / "top" / số tầng / id kênh) để ĐỌC các tầng trên
// (chỉ tổ tiên của kênh hiện tại, bot phải là thành viên); không đọc kênh anh em / kênh con, không ghi lên trên.
// A2A: A2A_ROLE=orchestrator -> thêm list_agents / ask_agent; A2A_ROLE=callee (đang làm việc được agent khác nhờ)
// -> chỉ approve + return_files (không đọc/gửi chat, không nhờ tiếp agent khác).
// Giao việc trên Boards: task_boards / task_list (đọc), task_create / task_update (ghi, tự xin duyệt qua runner) — xem tasks-mcp.ts.
// Bộ công cụ chat (0.6.61): chat_list / chat_unread / chat_send / chat_poll / thread_close… ở MỌI chat trong phạm vi của bot —
// runner xử lý (POST /chat_op/<tool>, chat-ops.ts), kể cả chat_history / chat_thread / chat_search khi có tham số `chat`.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { ancestorChain, type Level } from "./chain";
import { MM, type Post } from "./mm";
import { Boards } from "./boards";
import { TASK_TOOLS, TASK_TOOL_NAMES, taskTool } from "./tasks-mcp";
import { CHAT_OP_TOOLS } from "./chat-ops";

export async function runMcpChat() {
const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`thiếu env ${k}`); return v; };
const mm = new MM(env("MM_URL"), env("MM_TOKEN"));
const boards = new Boards(env("MM_URL"), env("MM_TOKEN"));
const A2A_ROLE = process.env.A2A_ROLE ?? "";
// Ngữ cảnh lượt: env lúc khởi động, rồi làm mới từ runner mỗi lần gọi tool (SCOPE = khoá phiên). Codex app-server giữ MCP
// sống qua nhiều lượt (thread còn nạp khi Codex app đang mở nó) -> env cũ (RUN_KEY, cổng runner) sẽ sai nếu không hỏi lại.
let CHANNEL = A2A_ROLE === "callee" ? "" : env("CHANNEL_ID");
let ROOT = process.env.ROOT_ID ?? "";
let RUNNER = process.env.RUNNER_URL ?? "";
let RUN_KEY = process.env.RUN_KEY ?? "";
let WORKDIR = process.env.WORKDIR ?? process.cwd();
let OWNER_ID = process.env.OWNER_ID ?? "";
let REPORT_OUT = process.env.REPORT_OUT === "1"; // lượt trong luồng / kênh bí mật: được gửi báo cáo ra nhóm ngoài
let MEET_CHANNEL = process.env.MEET_CHANNEL ?? ""; // kênh đang có cuộc họp (nhóm của phiên): bật các tool meeting_*
const MEET_BASE = process.env.MEET_BASE ?? "";
const SCOPE = process.env.SCOPE ?? "", PORT_FILE = process.env.PORT_FILE ?? "";
async function refreshCtx() {
  if (!SCOPE || !PORT_FILE) return;
  try {
    const port = (await Bun.file(PORT_FILE).text()).trim();
    const r = await fetch(`http://127.0.0.1:${port}/ctx?scope=${encodeURIComponent(SCOPE)}`, { signal: AbortSignal.timeout(3000) });
    if (!r.ok) return;
    const c = await r.json() as Record<string, string>;
    if (c.CHANNEL_ID !== CHANNEL) chainP = null;
    RUNNER = `http://127.0.0.1:${port}`;
    CHANNEL = c.CHANNEL_ID ?? CHANNEL; ROOT = c.ROOT_ID ?? ""; RUN_KEY = c.RUN_KEY ?? ""; WORKDIR = c.WORKDIR || WORKDIR; OWNER_ID = c.OWNER_ID ?? OWNER_ID; REPORT_OUT = c.REPORT_OUT === "1"; MEET_CHANNEL = c.MEET_CHANNEL ?? "";
  } catch {}
}

const fmtTime = (ms: number) => new Date(ms).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false });
async function fmt(posts: Post[]) {
  const out: string[] = [];
  for (const p of posts) {
    if (p.type && p.type.startsWith("system_")) continue;
    if (p.props?.flygo_thread_name !== undefined) { out.push(`[${fmtTime(p.create_at)}] (luồng được đổi tên thành "${String(p.props.flygo_thread_name).replace(/\s+/g, " ").slice(0, 80)}")`); continue; }
    // Bỏ thẻ tiến trình / yêu cầu duyệt / tin đang stream; giữ câu trả lời (post có cả thẻ lẫn chữ: flygo_agent_message).
    const msg = p.props?.flygo_agent_message;
    if (msg ? msg.streaming : p.props?.flygo_agent || p.props?.flygo_agent_approval) continue;
    if (!p.message?.trim() && !p.file_ids?.length) continue;
    const name = await mm.displayName(p.user_id);
    const fl = (p as any).metadata?.files as any[] | undefined;
    const files = fl?.length ? ` [tệp: ${fl.map((f) => `${f.name} (id=${f.id}, ${f.mime_type}, ${f.size}B)`).join("; ")}]` : p.file_ids?.length ? ` [tệp id: ${p.file_ids.join(", ")}]` : "";
    const where = p.root_id ? ` (trả lời trong chủ đề ${p.root_id})` : "";
    const shared = p.props?.flygo_ai_share ? " (bot đăng theo lệnh 📤 \"Gửi ra ngoài bằng bot\" của chủ, từ chat AI riêng)" : "";
    out.push(`[${fmtTime(p.create_at)}] ${name}${where} #${p.id}: ${p.message}${files}${shared}`);
  }
  return out.join("\n") || "(không có tin nào)";
}
const text = (s: string) => ({ content: [{ type: "text", text: s }] });

// ---- phòng họp (trạm của máy chủ: push.<tên miền>/meet): AI dẫn cuộc họp của nhóm — nói (TTS), chiếu nội dung / slide / web, mời phát biểu ----
async function meet(method: string, path: string, body?: any): Promise<any> {
  if (!MEET_CHANNEL || !MEET_BASE) throw new Error("Nhóm này không có cuộc họp nào đang diễn ra.");
  const r = await fetch(`${MEET_BASE}/${MEET_CHANNEL}/${path}`, {
    method, headers: { Authorization: `Bearer ${env("MM_TOKEN")}`, "X-MM-Server": env("MM_URL"), "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(90_000),
  });
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j?.error ?? `phòng họp ${r.status}`);
  return j;
}
const cmd = (b: any) => meet("POST", "cmd", b);
/** Giọng đọc: nam (mặc định của trạm, NamMinh giọng Bắc) | nu (HoaiMy) | google (giọng nữ Google Dịch) | tên giọng đầy đủ. */
const voiceOf = (v: any): string | undefined => v === "nu" ? "vi-VN-HoaiMyNeural" : v === "google" ? "google-vi" : !v || v === "nam" ? undefined : String(v);
/** Link xem từ xa (https) của phòng; lần đầu trong cuộc họp (hoặc force) thì gửi vào nhóm để ai không vào cuộc gọi cũng theo dõi được. */
async function liveLink(force = false): Promise<string> {
  const j = await meet("POST", "live");
  if (j.first || force) await mm.createPost({ channel_id: MEET_CHANNEL, message: `📺 Theo dõi trình chiếu trực tiếp (không cần vào cuộc gọi, mở được trên mọi trình duyệt): ${j.url}` });
  return j.url;
}
/** Tải tệp cục bộ lên trạm phòng họp (ảnh / video / âm thanh / font cho slide): trả URL công khai. */
const ASSET_TYPES: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", svg: "image/svg+xml", avif: "image/avif",
  mp4: "video/mp4", webm: "video/webm", mp3: "audio/mpeg", ogg: "audio/ogg", wav: "audio/wav", woff2: "font/woff2", ttf: "font/ttf", pdf: "application/pdf" };
async function meetAsset(file: string): Promise<string> {
  if (!MEET_CHANNEL || !MEET_BASE) throw new Error("Nhóm này không có cuộc họp nào đang diễn ra.");
  const ext = file.split(".").pop()?.toLowerCase() ?? "";
  const type = ASSET_TYPES[ext];
  if (!type) throw new Error(`Không hỗ trợ .${ext} (được: ${Object.keys(ASSET_TYPES).join(", ")}).`);
  const f = Bun.file(file);
  if (!(await f.exists())) throw new Error(`Không có tệp ${file}`);
  const r = await fetch(`${MEET_BASE}/${MEET_CHANNEL}/asset`, {
    method: "POST", headers: { Authorization: `Bearer ${env("MM_TOKEN")}`, "X-MM-Server": env("MM_URL"), "content-type": type },
    body: await f.arrayBuffer(), signal: AbortSignal.timeout(120_000),
  });
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j?.error ?? `phòng họp ${r.status}`);
  return j.url;
}
// Hiệu ứng âm (phát một lần cho cả phòng): bộ âm có sẵn theo manifest.
// Âm hiệu ứng / nhạc họp: tệp tĩnh của chính máy chủ chat (MM_URL), đặt khác bằng MEET_SFX / MEET_MUSIC.
const SFX_MANIFEST = process.env.MEET_SFX ?? `${env("MM_URL").replace(/\/+$/, "")}/static/plugins/flygo-update/sfx/manifest.json`;
let sfxCache: { at: number; base: string; sounds: any[] } | null = null;
async function sfxSounds() {
  if (sfxCache && Date.now() - sfxCache.at < 600_000) return sfxCache;
  const j: any = await (await fetch(SFX_MANIFEST, { signal: AbortSignal.timeout(10_000) })).json();
  sfxCache = { at: Date.now(), base: String(j.base ?? "").replace(/\/+$/, ""), sounds: Array.isArray(j.sounds) ? j.sounds : [] };
  return sfxCache;
}
/** Chụp từng bước của bộ slide (Chrome / Edge / Chromium chạy ngầm trên máy bot) rồi gửi trạm: máy không chạy được web
 *  (Windows / Linux) hiện ảnh đúng bước đang chiếu. Không có trình duyệt thì bỏ qua (máy đó hiện chữ của trang). */
function chromePath(): string | null {
  const c = process.platform === "darwin"
    ? ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge", "/Applications/Chromium.app/Contents/MacOS/Chromium"]
    : process.platform === "win32"
      ? [`${process.env["ProgramFiles"]}\\Google\\Chrome\\Application\\chrome.exe`, `${process.env["ProgramFiles(x86)"]}\\Microsoft\\Edge\\Application\\msedge.exe`, `${process.env["LOCALAPPDATA"]}\\Google\\Chrome\\Application\\chrome.exe`]
      : ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/snap/bin/chromium", "/usr/bin/microsoft-edge"];
  for (const p of c) { try { if (require("node:fs").existsSync(p)) return p; } catch {} }
  return null;
}
async function renderFrames(d: { deck: string; url: string; slides: { steps: number }[] }) {
  const chrome = chromePath();
  if (!chrome) return;
  const os = require("node:os"), path = require("node:path"), fs = require("node:fs");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "flygo-deck-"));
  const jobs = d.slides.flatMap((s, i) => Array.from({ length: s.steps + 1 }, (_, k) => `${i}.${k}`));
  const frames: Record<string, string> = {};
  const one = async (k: string) => {
    const out = path.join(dir, `${k}.png`);
    const p = Bun.spawn([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--mute-audio", "--no-first-run", `--user-data-dir=${path.join(dir, `p-${k}`)}`,
      "--window-size=1280,720", "--virtual-time-budget=3000", `--screenshot=${out}`, `${d.url}#${k}`], { stdout: "ignore", stderr: "ignore" });
    const t = setTimeout(() => p.kill(), 30_000);
    await p.exited; clearTimeout(t);
    if (fs.existsSync(out)) frames[k] = await meetAsset(out).catch(() => "");
  };
  try {
    for (let i = 0; i < jobs.length; i += 4) await Promise.all(jobs.slice(i, i + 4).map(one));
    const ok = Object.fromEntries(Object.entries(frames).filter(([, v]) => v));
    if (Object.keys(ok).length) await meet("POST", "deck_frames", { deck: d.deck, frames: ok });
  } catch (e) {
    console.error("deck frames:", e);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}
const deckPos = (e: any) => `trang ${e.slide + 1}/${e.slides}${e.steps ? `, bước ${e.step}/${e.steps}` : ""}${e.title ? ` "${e.title}"` : ""}`;
/** Người trong cuộc họp theo user_id / @username / tên (khớp một phần, không phân biệt hoa thường). */
async function meetUser(q: string): Promise<{ user_id: string; name: string }> {
  const st = await meet("GET", "state");
  const people = [...(st.participants ?? []), ...(st.online ?? [])] as any[];
  const k = String(q ?? "").trim().replace(/^@/, "").toLowerCase();
  const hit = people.find((p) => p.user_id === k) ?? people.find((p) => p.username?.toLowerCase() === k) ?? people.find((p) => String(p.name ?? "").toLowerCase() === k)
    ?? people.find((p) => String(p.name ?? "").toLowerCase().includes(k) || p.username?.toLowerCase().includes(k));
  if (!hit) throw new Error(`Không thấy "${q}" trong cuộc họp. Người đang trong cuộc họp: ${[...new Set(people.map((p) => p.name))].join(", ") || "(không ai)"}.`);
  return { user_id: hit.user_id, name: hit.name };
}
/** Cắt lời nói thành đoạn ~220 ký tự theo câu, để phụ đề chạy theo. */
function sayChunks(t: string): string[] {
  const parts = String(t).replace(/\s+/g, " ").trim().match(/[^.!?…;:]+[.!?…;:]*\s*/g) ?? [];
  const out: string[] = [];
  for (const p of parts) { const last = out[out.length - 1]; if (last && last.length + p.length <= 220) out[out.length - 1] = last + p; else out.push(p); }
  return out.map((x) => x.trim()).filter(Boolean).flatMap((x) => (x.length <= 400 ? [x] : x.match(/.{1,400}(\s|$)/g) ?? [x]));
}
// Nhạc nền cho cuộc họp: bộ nhạc theo giai đoạn (manifest), giảm âm lượng khi đang nói (auto-duck).
const MUSIC_MANIFEST = process.env.MEET_MUSIC ?? `${env("MM_URL").replace(/\/+$/, "")}/static/plugins/flygo-update/music/meeting/manifest.json`;
let musicCache: { at: number; base: string; tracks: any[] } | null = null;
async function musicTracks() {
  if (musicCache && Date.now() - musicCache.at < 600_000) return musicCache;
  const j: any = await (await fetch(MUSIC_MANIFEST, { signal: AbortSignal.timeout(10_000) })).json();
  musicCache = { at: Date.now(), base: String(j.base ?? "").replace(/\/+$/, ""), tracks: Array.isArray(j.tracks) ? j.tracks : [] };
  return musicCache;
}
const musicRR = new Map<string, number>(); // giai đoạn -> lượt chọn kế tiếp (xoay vòng)
const QUIET = new Set(["present", "qa"]);
const musicVol = async (volume: number) => cmd({ type: "audio", kind: "music", action: "volume", volume: Math.min(1, Math.max(0, volume)) });
async function musicNow(): Promise<any | null> { const st = await meet("GET", "state").catch(() => null); return st?.music && st.music.action === "play" ? st.music : null; }
async function meetingTool(name: string, a: any): Promise<string> {
  switch (name) {
    case "meeting_state": {
      const st = await meet("GET", "state");
      const ppl = (st.participants ?? []).map((p: any) => `- ${p.name} (@${p.username ?? p.user_id})${p.muted ? " · tắt mic" : " · đang bật mic"}${p.video ? " · camera" : ""}${p.screen ? " · chia sẻ màn hình" : ""}${p.hand ? " · ✋" : ""}`);
      const hands = (st.hands ?? []).map((h: any) => `${h.name} (${fmtTime(h.at)})`);
      const cm = (st.comments ?? []).slice(-(Number(a.comments) || 20)).map((c: any) => `[${fmtTime(c.at)}] ${c.from?.name}: ${c.text}`);
      const stage = st.stage ? (st.stage.kind === "html" ? `slide HTML ${deckPos(st.stage)}` : st.stage.kind === "slides" ? `slide ${(st.stage.index ?? 0) + 1}/${st.stage.items?.length} "${st.stage.items?.[st.stage.index ?? 0]?.title ?? ""}"` : st.stage.kind) : "trống";
      return [
        `Cuộc họp: ${st.call?.active ? `đang diễn ra từ ${fmtTime(st.call.start_at)}` : "chưa thấy cuộc gọi đang diễn ra"}${st.you?.host ? " · bạn có quyền chủ trì" : " · bạn KHÔNG có quyền chủ trì (không chiếu / nói / tắt mic được)"}`,
        `Người tham gia (${ppl.length}):`, ...(ppl.length ? ppl : ["- (không đọc được danh sách)"]),
        `Giơ tay: ${hands.join(", ") || "không ai"}`,
        `Đang làm nổi bật: ${st.star ? ((st.participants ?? []).find((p: any) => p.user_id === st.star)?.name ?? st.star) : "không"}`,
        `Sân khấu: ${stage}${st.web ? ` · web ${st.web.url} (${st.web.driver_name} điều khiển)` : ""}${st.audio ? ` · âm thanh ${st.audio.kind} ${st.audio.action}` : ""}`,
        `Bình luận gần đây:`, ...(cm.length ? cm : ["(chưa có)"]),
      ].join("\n");
    }
    case "meeting_say": {
      const chunks = sayChunks(a.text);
      if (!chunks.length) return "Không có gì để nói.";
      let ms = 0;
      const music = await musicNow(); // đang có nhạc nền: hạ nhỏ khi nói, nói xong trả lại
      const duck = music && (music.volume ?? 1) > 0.1 ? music.volume : null;
      if (duck !== null) await musicVol(0.1).catch(() => {});
      try {
      for (const c of chunks) {
        const r = await meet("POST", "tts", { text: c, voice: voiceOf(a.voice), rate: a.rate, play: true });
        const d = Math.min(Number(r.duration_ms) || 2000, 120_000);
        ms += d;
        await Bun.sleep(d + 250); // chờ nói xong đoạn này rồi mới phát đoạn sau
      }
      } finally { if (duck !== null) await musicVol(duck).catch(() => {}); }
      await cmd({ type: "caption", text: "" }).catch(() => {});
      return `Đã nói xong (${Math.round(ms / 1000)} giây, ${chunks.length} đoạn).`;
    }
    case "meeting_show": {
      const kind = String(a.kind ?? (a.image_url ? "image" : a.video_url ? "video" : a.markdown ? "markdown" : ""));
      if (kind === "clear") { await cmd({ type: "stage", kind: "clear" }); return "Đã tắt sân khấu."; }
      if (kind === "caption") { await cmd({ type: "caption", text: String(a.text ?? a.markdown ?? "") }); return a.text ? "Đang hiện phụ đề." : "Đã tắt phụ đề."; }
      if (kind === "markdown") { await cmd({ type: "stage", kind, content: String(a.markdown ?? a.content ?? "") }); return "Đang chiếu nội dung cho cả phòng."; }
      if (kind === "image" || kind === "video") { await cmd({ type: "stage", kind, url: String(a.url ?? a.image_url ?? a.video_url ?? "") }); return `Đang chiếu ${kind === "image" ? "ảnh" : "video"} cho cả phòng.`; }
      return "kind phải là markdown | image | video | clear.";
    }
    case "meeting_slides": {
      if (Array.isArray(a.items) && a.items.length) {
        const r = await cmd({ type: "stage", kind: "slides", items: a.items, index: Number(a.index) || 0 });
        return `Đang chiếu slide ${(r.event.index ?? 0) + 1}/${r.event.items.length}: "${r.event.items[r.event.index ?? 0]?.title ?? ""}".`;
      }
      const st = await meet("GET", "state");
      if (st.stage?.kind !== "slides") return "Chưa có bộ slide nào đang chiếu: gửi items để chiếu.";
      const cur = st.stage.index ?? 0, n = st.stage.items.length;
      const to = a.index === "next" || a.go === "next" ? cur + 1 : a.index === "prev" || a.go === "prev" ? cur - 1 : Number(a.index);
      if (!Number.isFinite(to) || to < 0 || to >= n) return `Trang không hợp lệ (đang ở ${cur + 1}/${n}).`;
      await cmd({ type: "stage", kind: "slides", index: to });
      return `Đã chuyển sang slide ${to + 1}/${n}: "${st.stage.items[to]?.title ?? ""}".`;
    }
    case "meeting_deck": {
      let html = a.html ? String(a.html) : "";
      if (!html && a.path) html = await Bun.file(String(a.path)).text();
      if (!html) return "Cần html (nội dung bộ slide) hoặc path (tệp .html trên máy).";
      const d = await meet("POST", "deck", { html, title: a.title });
      if (a.show !== false) await liveLink().catch(() => {});
      void renderFrames(d); // chạy nền: ảnh từng bước cho máy Windows / Linux
      const list = d.slides.map((x: any, i: number) => `${i + 1}. ${x.title || "(không tiêu đề)"}${x.steps ? ` · ${x.steps} bước` : ""}`).join("\n");
      if (a.show !== false) { const r = await cmd({ type: "stage", kind: "html", deck: d.deck, slide: Number(a.slide) || 0, step: 0 }); return `Đang chiếu bộ slide (${deckPos(r.event)}). Xem thử trên trình duyệt: ${d.url}\n${list}`; }
      return `Đã tải bộ slide (chưa chiếu): ${d.url}\n${list}`;
    }
    case "meeting_deck_go": {
      const b: any = { type: "stage", kind: "html" };
      if (a.go === "next" || a.go === "prev") b.go = a.go;
      if (a.slide !== undefined) b.slide = Number(a.slide) - 1;
      if (a.step !== undefined) b.step = a.step === "all" ? "all" : Number(a.step);
      const r = await cmd(b);
      return `Đang ở ${deckPos(r.event)}.`;
    }
    case "meeting_asset": {
      const files: string[] = Array.isArray(a.paths) ? a.paths : a.path ? [a.path] : [];
      if (!files.length) return "Cần path hoặc paths.";
      const out: string[] = [];
      for (const f of files) out.push(`${f} → ${await meetAsset(String(f)).catch((e) => `LỖI ${e?.message ?? e}`)}`);
      return out.join("\n");
    }
    case "meeting_sfx": {
      const m = await sfxSounds();
      if (!a.name || a.name === "list") return m.sounds.map((x) => `- ${x.id} · ${x.desc} · ${x.duration_s}s`).join("\n");
      const x = m.sounds.find((y) => y.id === a.name);
      const url = x ? `${m.base}/${x.id}.mp3` : /^https?:\/\//.test(String(a.name)) ? String(a.name) : "";
      if (!url) return `Không có hiệu ứng "${a.name}". Có: ${m.sounds.map((y) => y.id).join(", ")}.`;
      await cmd({ type: "audio", kind: "sfx", action: "play", url, volume: a.volume ?? 0.8 });
      return `Đã phát "${a.name}".`;
    }
    case "meeting_present": {
      if (a.action) {
        const j = await meet("POST", "present", { action: a.action });
        const sh = j.show;
        return sh ? `Trình chiếu tự chạy: câu ${sh.i + 1}/${sh.n}, trang ${sh.slide + 1}${sh.paused ? " (đang tạm dừng)" : ""}.` : "Không có trình chiếu tự chạy nào.";
      }
      // Kịch bản: items [{slide (từ 1), step, text}] hoặc tệp, mỗi dòng "trang N, bước K: câu đọc".
      let items: any[] = Array.isArray(a.items) ? a.items.map((x: any) => ({ slide: Number(x.slide) - 1, step: x.step ?? 0, text: String(x.text ?? "") })) : [];
      if (!items.length && a.script) {
        const src = await Bun.file(String(a.script)).text();
        for (const m of src.matchAll(/trang\s+(\d+)\s*,\s*bước\s+(\d+|all)\s*:\s*(.+)/gi)) items.push({ slide: Number(m[1]) - 1, step: m[2] === "all" ? "all" : Number(m[2]), text: m[3].trim() });
      }
      if (!items.length) return "Cần items [{slide, step, text}] hoặc script (tệp có các dòng \"trang N, bước K: câu đọc\").";
      let deck: string | undefined;
      if (a.deck_path) {
        const d = await meet("POST", "deck", { html: await Bun.file(String(a.deck_path)).text(), title: a.title });
        void renderFrames(d);
        deck = d.deck;
      }
      await liveLink().catch(() => {});
      const j = await meet("POST", "present", { deck, items, voice: voiceOf(a.voice), rate: a.rate ?? "+15%", from: a.from ? Number(a.from) - 1 : 0 });
      return `Đã tạo sẵn giọng đọc ${j.items} câu; trạm đang tự chạy (khoảng ${Math.round(j.duration_ms / 60000 * 10) / 10} phút). Không cần gọi meeting_deck_go / meeting_say nữa. Xem tiến độ: meeting_present action=status; dừng / tạm dừng / chạy tiếp: action=stop | pause | resume.`;
    }
    case "meeting_lobby": {
      if (a.action === "start") { await cmd({ type: "lobby", action: "start" }); return "Đã bắt đầu cuộc họp: đóng phòng chờ, nhạc phòng chờ nhỏ dần rồi tắt."; }
      await cmd({ type: "lobby", action: "show", title: a.title, subtitle: a.subtitle, starts_at: a.starts_at });
      return "Đang hiện phòng chờ (cảnh chờ + nhạc phòng chờ).";
    }
    case "meeting_link": return `Đã gửi link vào nhóm: ${await liveLink(true)}`;
    case "meeting_scene": {
      await liveLink().catch(() => {});
      const b: any = { type: "stage", kind: "scene", scene: a.scene, data: a.data ?? {} };
      if (a.theme) b.theme = a.theme;
      await cmd(b);
      return `Đang chiếu cảnh "${a.scene}".`;
    }
    case "meeting_qa": {
      // Câu hỏi lên màn hình, câu trả lời hiện dần đúng theo giọng đọc (mỗi đoạn TTS: reveal tới cuối đoạn trong đúng thời lượng).
      const answer = String(a.answer ?? "").replace(/\s+/g, " ").trim();
      const data: any = { who: a.who ?? "", question: a.question ?? "", answer, ...(Array.isArray(a.queue) ? { queue: a.queue } : {}), ...(a.data ?? {}) };
      await cmd({ type: "stage", kind: "scene", scene: "qa", data, reveal: { from: 0, to: 0, duration_ms: 0 }, ...(a.theme ? { theme: a.theme } : {}) });
      if (a.say === false || !answer) {
        if (answer) await cmd({ type: "stage", kind: "scene", scene: "qa", reveal: { from: 0, to: answer.length, duration_ms: 1500 } });
        return "Đã đưa câu hỏi và câu trả lời lên màn hình.";
      }
      if (a.read_question !== false && data.question) {
        const q = await meet("POST", "tts", { text: `${data.who ? `${data.who} hỏi: ` : ""}${data.question}`, voice: voiceOf(a.voice), play: false });
        await cmd({ type: "audio", kind: "tts", action: "play", url: q.url, volume: 1 });
        await Bun.sleep(Math.min(Number(q.duration_ms) || 2000, 60_000) + 400);
      }
      const music = await musicNow();
      const duck = music && (music.volume ?? 1) > 0.1 ? music.volume : null;
      if (duck !== null) await musicVol(0.1).catch(() => {});
      let pos = 0, ms = 0;
      try {
        for (const c of sayChunks(answer)) {
          const at = answer.indexOf(c, pos);
          const end = at >= 0 ? at + c.length : Math.min(answer.length, pos + c.length);
          const t = await meet("POST", "tts", { text: c, voice: voiceOf(a.voice), rate: a.rate, play: false });
          const d = Math.min(Number(t.duration_ms) || 2000, 120_000);
          await Promise.all([
            cmd({ type: "stage", kind: "scene", scene: "qa", reveal: { from: pos, to: end, duration_ms: d } }),
            cmd({ type: "audio", kind: "tts", action: "play", url: t.url, volume: 1 }),
          ]);
          await Bun.sleep(d + 250);
          pos = end; ms += d;
        }
      } finally { if (duck !== null) await musicVol(duck).catch(() => {}); }
      await cmd({ type: "stage", kind: "scene", scene: "qa", reveal: { from: answer.length, to: answer.length, duration_ms: 0 } }).catch(() => {});
      return `Đã trả lời trên màn hình và đọc xong (${Math.round(ms / 1000)} giây).`;
    }
    case "meeting_poll": {
      // Bình chọn thật (props.flygo_poll, mọi người bỏ phiếu qua trạm /poll) + cảnh poll cập nhật số phiếu 2 giây một lần.
      const texts = (Array.isArray(a.options) ? a.options : []).map((x: any) => String(x ?? "").replace(/\s+/g, " ").trim()).filter(Boolean).slice(0, 6);
      if (texts.length < 2) throw new Error("Cần ít nhất 2 phương án.");
      const secs = Math.min(600, Math.max(10, Number(a.seconds) || 60));
      const question = String(a.question ?? "").trim();
      const ends = Date.now() + secs * 1000;
      const poll: any = { v: 1, question, options: texts.map((text: string, i: number) => ({ id: `o${i + 1}`, text })), multi: !!a.multi, revote: true, allow_add: false, ends_at: ends, closed: false, votes: {}, created_by: await botId() };
      const post = await mm.createPost({ channel_id: MEET_CHANNEL, message: `📊 Bình chọn: ${question}`, props: { flygo_poll: poll } });
      const scene = (p: any, closed: boolean) => {
        const n = new Map<string, number>();
        for (const ids of Object.values<any>(p.votes ?? {})) for (const id of Array.isArray(ids) ? ids : []) n.set(String(id), (n.get(String(id)) ?? 0) + 1);
        return { question, options: (p.options ?? []).map((o: any) => ({ text: o.text, votes: n.get(String(o.id)) ?? 0 })), ends_at: ends, closed, ...(a.hint ? { hint: a.hint } : {}) };
      };
      let last = "";
      const show = async (p: any, closed: boolean) => { const d = scene(p, closed); const k = JSON.stringify(d); if (k !== last) { last = k; await cmd({ type: "stage", kind: "scene", scene: "poll", data: d }); } return d; };
      await show(poll, false);
      let cur = poll;
      while (Date.now() < ends) {
        await Bun.sleep(Math.min(2000, Math.max(0, ends - Date.now())));
        cur = (await mm.api<any>("GET", `/posts/${post.id}`).catch(() => null))?.props?.flygo_poll ?? cur;
        await show(cur, false).catch(() => {});
      }
      const fin = await mm.api<any>("GET", `/posts/${post.id}`).catch(() => null);
      cur = fin?.props?.flygo_poll ?? cur;
      await mm.patchPost(post.id, { props: { ...(fin?.props ?? post.props ?? {}), flygo_poll: { ...cur, closed: true } } }).catch(() => {});
      const d = await show(cur, true);
      const total = d.options.reduce((s: number, o: any) => s + o.votes, 0);
      return `Bình chọn đã khoá (${total} phiếu):\n${d.options.map((o: any) => `- ${o.text}: ${o.votes}${total ? ` (${Math.round((o.votes / total) * 100)}%)` : ""}`).join("\n")}`;
    }
    case "meeting_draw": {
      if (a.clear) { await cmd({ type: "stage", kind: "draw", strokes: [] }); return "Đã xoá hình vẽ."; }
      await cmd({ type: "stage", kind: "draw", strokes: a.strokes ?? [] });
      return `Đã vẽ ${(a.strokes ?? []).length} nét lên sân khấu.`;
    }
    case "meeting_web": {
      const act = String(a.action ?? "open");
      if (act === "open") { await cmd({ type: "web_open", url: a.url }); return `Đã mở ${a.url} cho cả phòng (bạn điều khiển).`; }
      if (act === "go") { await cmd({ type: "web_nav", url: a.url }); return `Đã chuyển trang sang ${a.url}.`; }
      if (act === "scroll") { await cmd({ type: "web_scroll", x: a.x ?? 0, y: a.y ?? 0 }); return `Đã cuộn tới ${Math.round((a.y ?? 0) * 100)}% trang.`; }
      if (act === "click") { await cmd({ type: "web_click", x: a.x, y: a.y }); return "Đã bấm."; }
      if (act === "close") { await cmd({ type: "web_close" }); return "Đã đóng trang web."; }
      return "action phải là open | go | scroll | click | close.";
    }
    case "meeting_people": {
      const act = String(a.action ?? "");
      if (act === "mute_all") {
        const except = await Promise.all((a.except ?? []).map((u: string) => meetUser(u).then((x) => x.user_id)));
        await cmd({ type: "mute_all", except }); return `Đã tắt mic mọi người${except.length ? ` (trừ ${except.length} người)` : ""}.`;
      }
      if (act === "unspotlight") { await cmd({ type: "star", user_id: null }); return "Đã bỏ làm nổi bật."; }
      const u = await meetUser(a.user);
      const type = { spotlight: "star", mute: "mute", ask_unmute: "unmute_request", request_screen: "screen_request", lower_hand: "lower_hand" }[act];
      if (!type) return "action phải là spotlight | unspotlight | mute | mute_all | ask_unmute | request_screen | lower_hand.";
      await cmd({ type, user_id: u.user_id });
      return { star: `Đang làm nổi bật ${u.name}.`, mute: `Đã tắt mic ${u.name}.`, unmute_request: `Đã mời ${u.name} bật mic (họ tự bấm Bật).`, screen_request: `Đã mời ${u.name} chia sẻ màn hình (họ tự bấm đồng ý).`, lower_hand: `Đã hạ tay ${u.name}.` }[type]!;
    }
    case "meeting_music_list": {
      const m = await musicTracks();
      const list = m.tracks.filter((t) => !a.stage || t.stage === a.stage);
      return list.length ? list.map((t) => `- ${t.id} · ${t.stage} · "${t.title}" · ${t.duration_s}s${t.loop ? " · lặp" : " · không lặp"}${t.desc ? ` · ${t.desc}` : ""}`).join("\n") : `Không có bài nào${a.stage ? ` cho giai đoạn ${a.stage}` : ""}.`;
    }
    case "meeting_music_play": {
      const m = await musicTracks();
      let t = a.track_id ? m.tracks.find((x) => x.id === a.track_id) : null;
      if (!t && a.url) t = { id: "url", title: "Nhạc", url: a.url, loop: !!a.loop, stage: "" };
      if (!t) {
        const st = String(a.stage ?? a.track_id ?? "");
        const cands = m.tracks.filter((x) => x.stage === st);
        if (!cands.length) return `Không có bài "${a.track_id ?? a.stage}". Các giai đoạn: ${[...new Set(m.tracks.map((x) => x.stage))].join(", ")}.`;
        const i = musicRR.get(st) ?? Math.floor(Math.random() * cands.length);
        t = cands[i % cands.length]; musicRR.set(st, i + 1);
      }
      const volume = a.volume ?? (QUIET.has(t.stage) ? 0.12 : 0.35);
      await cmd({ type: "audio", kind: "music", action: "play", url: t.url ?? `${m.base}/${t.id}.mp3`, volume, loop: a.loop ?? !!t.loop, title: t.title });
      return `Đang phát "${t.title}" (${t.id}, âm lượng ${Math.round(volume * 100)}%${(a.loop ?? t.loop) ? ", lặp" : ""}).`;
    }
    case "meeting_music_volume": await musicVol(Number(a.volume)); return `Âm lượng nhạc: ${Math.round(Number(a.volume) * 100)}%.`;
    case "meeting_music_pause": await cmd({ type: "audio", kind: "music", action: "pause" }); return "Đã tạm dừng nhạc.";
    case "meeting_music_stop": await cmd({ type: "audio", kind: "music", action: "stop" }); return "Đã tắt nhạc.";
    case "meeting_music_fade": {
      const cur = await musicNow();
      if (!cur) return "Không có nhạc đang phát.";
      const from = Number(cur.volume ?? 1), to = Math.min(1, Math.max(0, Number(a.to_volume ?? 0))), sec = Math.min(30, Math.max(1, Number(a.seconds ?? 3)));
      const steps = Math.max(3, Math.round(sec * 2));
      for (let i = 1; i <= steps; i++) { await musicVol(from + ((to - from) * i) / steps); await Bun.sleep((sec * 1000) / steps); }
      if (to === 0 && a.stop !== false) await cmd({ type: "audio", kind: "music", action: "stop" });
      return `Đã chỉnh nhạc từ ${Math.round(from * 100)}% về ${Math.round(to * 100)}% trong ${sec} giây${to === 0 && a.stop !== false ? " rồi tắt" : ""}.`;
    }
  }
  return `tool không hợp lệ: ${name}`;
}
const USER_ARG = { type: "string", description: "người trong cuộc họp: @username, tên hiển thị (khớp một phần) hoặc user_id" };
const MEETING_TOOLS = [
  { name: "meeting_state", description: "Xem cuộc họp đang diễn ra ở nhóm: người tham gia (mic / camera / màn hình / giơ tay), ai đang giơ tay, sân khấu đang chiếu gì, bình luận gần đây. Gọi trước khi dẫn họp và mỗi khi cần nắm tình hình (ai hỏi, ai giơ tay).", inputSchema: { type: "object", properties: { comments: { type: "number", description: "số bình luận gần nhất (mặc định 20)" } } } },
  { name: "meeting_say", description: "NÓI trong cuộc họp: đọc thành giọng nói tiếng Việt cho cả phòng nghe (kèm phụ đề), trả về khi đã nói xong. Đây là cách bạn phát biểu khi dẫn họp; viết như văn nói, câu ngắn, tự nhiên, không markdown, không emoji, không đọc đường dẫn.", inputSchema: { type: "object", properties: { text: { type: "string" }, voice: { type: "string", description: "nam (mặc định, NamMinh giọng Bắc) | nu (HoaiMy) | google (giọng nữ Google Dịch)" }, rate: { type: "string", description: "tốc độ, vd. \"+10%\" / \"-5%\"" } }, required: ["text"] } },
  { name: "meeting_show", description: "CHIẾU lên sân khấu (toàn màn hình mọi máy trong cuộc họp): nội dung markdown, ảnh hoặc video theo URL; kind=caption để hiện một dòng phụ đề; kind=clear để tắt sân khấu.", inputSchema: { type: "object", properties: { kind: { type: "string", enum: ["markdown", "image", "video", "caption", "clear"] }, markdown: { type: "string" }, url: { type: "string", description: "URL ảnh / video (https)" }, text: { type: "string", description: "phụ đề (kind=caption; trống = tắt)" } }, required: ["kind"] } },
  { name: "meeting_slides", description: "Chiếu BỘ SLIDE (items) hoặc chuyển trang của bộ đang chiếu (index = số trang từ 0, hoặc \"next\" / \"prev\").", inputSchema: { type: "object", properties: { items: { type: "array", items: { type: "object", properties: { title: { type: "string" }, body_md: { type: "string" }, image_url: { type: "string" } }, required: ["title"] } }, index: { description: "trang (0..), \"next\" hoặc \"prev\"" } } } },
  { name: "meeting_deck", description: "CHIẾU BỘ SLIDE HTML (cách trình chiếu chính: đẹp, có hiệu ứng). Viết cả bộ thành MỘT trang HTML: mỗi <section> cấp đầu trong <body> là một trang, khung cố định 1920×1080 (tự co vừa mọi màn hình; dùng px, đừng dùng vw/vh), không lồng section. Có sẵn phông Be Vietnam Pro, nền tối mặc định, cỡ chữ h1 96 / h2 64 / p,li 36px — tự viết <style> để đổi màu, bố cục (grid / flex), nền gradient, bo góc, bóng… theo thương hiệu. Hiệu ứng: phần tử có data-step=\"1..n\" hiện lần lượt từng bước (meeting_deck_go next); data-anim = fade-up (mặc định) | fade | zoom | pop | left | right | down | blur | type (đánh máy); <section data-transition=\"fade|slide|zoom|none\">; data-count-to=\"1200\" (+ data-count-prefix / data-count-suffix / data-count-dur ms) để số đếm lên; data-sfx=\"ting\" trên phần tử / section để phát hiệu ứng âm khi nó hiện (tên từ meeting_sfx list). Được dùng CSS animation / @keyframes, SVG, <video autoplay muted>; JS ngoài chỉ khi cần (Chart.js từ cdn.jsdelivr.net). Ảnh / video: URL https — tệp trên máy thì tải bằng meeting_asset trước. Không chèn chữ quá nhiều: 3–5 ý / trang. Trả về danh sách trang + số bước, và link xem thử.", inputSchema: { type: "object", properties: { html: { type: "string", description: "toàn bộ HTML của bộ slide" }, path: { type: "string", description: "hoặc đường dẫn tệp .html trên máy" }, title: { type: "string" }, show: { type: "boolean", description: "chiếu ngay (mặc định true)" }, slide: { type: "number", description: "trang bắt đầu (từ 0, mặc định 0)" } } } },
  { name: "meeting_deck_go", description: "Điều khiển bộ slide HTML đang chiếu: go=next (hiện bước kế; hết bước thì sang trang sau) | prev; hoặc slide (số trang từ 1) và/hoặc step (số bước, \"all\" = hiện hết). Mọi máy chuyển cùng lúc.", inputSchema: { type: "object", properties: { go: { type: "string", enum: ["next", "prev"] }, slide: { type: "number" }, step: { description: "số bước hoặc \"all\"" } } } },
  { name: "meeting_asset", description: "Tải tệp trên máy (ảnh png/jpg/webp/gif/svg, video mp4/webm, âm thanh mp3, font, pdf) lên phòng họp, trả URL công khai để dùng trong slide HTML (meeting_deck) hoặc meeting_show. Tải nhiều tệp một lần bằng paths.", inputSchema: { type: "object", properties: { path: { type: "string" }, paths: { type: "array", items: { type: "string" } } } } },
  { name: "meeting_sfx", description: "Phát HIỆU ỨNG ÂM một lần cho cả phòng (ting, pop, click, success, notify, rise, impact, whoosh, swoosh, sparkle, typing, drumroll, applause, transition). name=list để xem mô tả. Dùng tiết chế: lúc chuyển phần, tiết lộ điểm nhấn, kết thúc.", inputSchema: { type: "object", properties: { name: { type: "string" }, volume: { type: "number", description: "0..1, mặc định 0.8" } }, required: ["name"] } },
  { name: "meeting_scene", description: "CHIẾU CẢNH CÓ SẴN của buổi trình diễn (đẹp, theo màu thương hiệu, không cần tự viết HTML). Trong title, *chữ* = tô màu nhấn. scene:\n- opening (mở đầu / phòng chờ): title, subtitle, presenter, date, place, tag, logo, starts_at = epoch ms để đếm ngược\n- agenda (chương trình): title, subtitle, items=[\"…\" | {title, note}] (≤8), current = phần đang nói (từ 0, -1 = chưa bắt đầu). Gọi lại với current mới khi sang phần — phần đã qua có dấu ✓\n- section (chuyển phần, hiện 3–5 giây rồi sang slide): number, title, subtitle\n- demo (đang demo trực tiếp): title, now = đang làm gì (1 câu), steps=[\"…\"], current (từ 0), url. Gọi lại khi sang bước\n- poll (bình chọn — thường dùng meeting_poll): question, options=[{text, votes}], ends_at, closed\n- break (giải lao): title, subtitle, until = epoch ms\n- qa (hỏi đáp — thường dùng meeting_qa)\n- recap (tổng kết): title, points=[\"…\" | {title, detail}] (3 ý là đẹp nhất, ≤6), shown = số ý đang hiện (bỏ trống: tự hiện lần lượt)\n- closing (kết thúc): title, subtitle, contacts=[{label,value}], qr = URL ảnh QR, qr_caption.\nGọi lại cùng scene không kèm data thì giữ data cũ. theme (gửi một lần, trạm nhớ cho cả buổi): {brand, logo (URL), accent, primary, bg, bg2, text, muted, font}. Phần trình bày chính dùng meeting_deck; chuyển qua lại giữa cảnh và bộ slide thoải mái (meeting_deck_go slide=… để quay lại slide).", inputSchema: { type: "object", properties: { scene: { type: "string", enum: ["opening", "agenda", "section", "demo", "poll", "break", "qa", "recap", "closing"] }, data: { type: "object" }, theme: { type: "object" } }, required: ["scene"] } },
  { name: "meeting_present", description: "TRÌNH CHIẾU TỰ CHẠY (cách nên dùng khi đã có kịch bản): trạm tạo sẵn giọng đọc cho mọi câu rồi tự lật slide + đọc + phụ đề liền mạch, không có khoảng chờ giữa các câu. Kịch bản: script = đường dẫn tệp có các dòng \"trang N, bước K: câu đọc\" (N từ 1; K = bước hiện ra trước khi đọc câu) hoặc items=[{slide (từ 1), step, text}]. deck_path = tệp HTML bộ slide (bỏ trống: bộ đang chiếu). voice: nam (mặc định) | nu | google; rate mặc định \"+15%\"; from = câu bắt đầu (từ 1). Trả về ngay khi bắt đầu chạy. action=status | pause | resume | stop để xem tiến độ / tạm dừng (vd. khi có người hỏi) / chạy tiếp / dừng.", inputSchema: { type: "object", properties: { script: { type: "string" }, items: { type: "array", items: { type: "object" } }, deck_path: { type: "string" }, title: { type: "string" }, voice: { type: "string" }, rate: { type: "string" }, from: { type: "number" }, action: { type: "string", enum: ["status", "pause", "resume", "stop"] } } } },
  { name: "meeting_lobby", description: "PHÒNG CHỜ của cuộc họp. Trạm tự hiện phòng chờ (cảnh chờ có đếm ngược + nhạc) khi người đầu tiên vào họp và GIỮ cho tới lệnh bắt đầu. action=start: bắt đầu họp (đóng cảnh chờ, nhạc phòng chờ nhỏ dần rồi tắt) — gọi khi chủ trì bảo bắt đầu; chiếu slide / cảnh khác cũng tự kết thúc phòng chờ. action=show: hiện lại hoặc sửa phòng chờ (title, subtitle, starts_at = epoch ms để đếm ngược).", inputSchema: { type: "object", properties: { action: { type: "string", enum: ["start", "show"] }, title: { type: "string" }, subtitle: { type: "string" }, starts_at: { type: "number" } }, required: ["action"] } },
  { name: "meeting_link", description: "Gửi lại vào nhóm link xem trình chiếu từ xa (https, mở trên trình duyệt, không cần vào cuộc gọi): slide, phụ đề, giọng đọc, nhạc chạy cùng lúc với cuộc họp. Lần chiếu đầu tiên (meeting_deck / meeting_scene) đã tự gửi; chỉ gọi khi cần gửi lại.", inputSchema: { type: "object", properties: {} } },
  { name: "meeting_poll", description: "BÌNH CHỌN NHANH trong cuộc họp: gửi một bình chọn vào nhóm chat của cuộc họp (mọi người bấm chọn ngay trong tin nhắn) và chiếu cảnh kết quả chạy trực tiếp lên màn hình. Chờ hết seconds (mặc định 60, tối đa 600) rồi khoá bình chọn, để kết quả cuối trên màn hình và trả về số phiếu từng phương án. Câu hỏi ngắn, 2–6 phương án ngắn.", inputSchema: { type: "object", properties: { question: { type: "string" }, options: { type: "array", items: { type: "string" } }, seconds: { type: "number" }, multi: { type: "boolean", description: "cho chọn nhiều phương án" }, hint: { type: "string", description: "dòng nhắc dưới cùng" } }, required: ["question", "options"] } },
  { name: "meeting_qa", description: "HỎI & ĐÁP trên màn hình: hiện câu hỏi (người hỏi + câu hỏi) rồi ĐỌC câu trả lời, chữ trả lời hiện dần đúng theo giọng đọc. Trả về khi đọc xong. queue = các câu hỏi đang chờ [{who, question}] (hiện ở cột phải). Viết answer như văn nói, ngắn gọn (2–5 câu), không markdown. say=false: chỉ hiện chữ, không đọc. read_question=false: không đọc lại câu hỏi.", inputSchema: { type: "object", properties: { who: { type: "string" }, question: { type: "string" }, answer: { type: "string" }, queue: { type: "array", items: { type: "object" } }, say: { type: "boolean" }, read_question: { type: "boolean" }, voice: { type: "string" }, rate: { type: "string" }, theme: { type: "object" } }, required: ["question", "answer"] } },
  { name: "meeting_draw", description: "VẼ lên sân khấu (nét vẽ theo toạ độ 0..1 của màn hình): strokes=[{points:[[x,y]...], color, width}]; clear=true để xoá.", inputSchema: { type: "object", properties: { strokes: { type: "array", items: { type: "object" } }, clear: { type: "boolean" } } } },
  { name: "meeting_web", description: "Mở một TRANG WEB chung cho cả phòng và điều khiển nó (mọi máy cuộn / bấm theo bạn). action: open (url) | go (url) | scroll (y 0..1 = vị trí theo chiều dọc trang) | click (x,y 0..1 của khung nhìn) | close.", inputSchema: { type: "object", properties: { action: { type: "string", enum: ["open", "go", "scroll", "click", "close"] }, url: { type: "string" }, x: { type: "number" }, y: { type: "number" } }, required: ["action"] } },
  { name: "meeting_people", description: "Điều phối người tham gia: spotlight (làm nổi bật một người trên màn hình mọi máy) | unspotlight | mute (tắt mic) | mute_all (tắt mic mọi người, except = danh sách giữ lại) | ask_unmute (mời bật mic để phát biểu) | request_screen (mời chia sẻ màn hình) | lower_hand (hạ tay).", inputSchema: { type: "object", properties: { action: { type: "string", enum: ["spotlight", "unspotlight", "mute", "mute_all", "ask_unmute", "request_screen", "lower_hand"] }, user: USER_ARG, except: { type: "array", items: { type: "string" } } }, required: ["action"] } },
  { name: "meeting_suggest", description: "Soạn GỢI Ý TRẢ LỜI một câu hỏi / ý kiến trong cuộc họp cho chủ trì duyệt: hiện thành thẻ trong phiên này, chủ trì bấm \"Đưa lên màn hình\" hoặc bảo bạn trình bày. Gọi lại cùng question_id để sửa; status: draft (mặc định) | shown (đã đưa lên màn hình) | answered | dropped.", inputSchema: { type: "object", properties: { question_id: { type: "string", description: "mã ngắn tự đặt, vd. q1" }, who: { type: "string", description: "người hỏi" }, question: { type: "string" }, answer_md: { type: "string", description: "gợi ý trả lời (markdown, ngắn gọn, đưa lên màn hình được)" }, status: { type: "string", enum: ["draft", "shown", "answered", "dropped"] } }, required: ["question_id", "answer_md"] } },
  { name: "meeting_watch", description: "Bật (start) / tắt (stop) theo dõi cuộc họp: khi bật, bình luận và giơ tay mới được gửi vào phiên này mỗi ~15 giây để bạn soạn gợi ý. Tự bật khi chủ trì nhắn trong phiên AI lúc đang họp, tự tắt khi hết cuộc gọi.", inputSchema: { type: "object", properties: { action: { type: "string", enum: ["start", "stop"] } }, required: ["action"] } },
  { name: "meeting_music_list", description: "Danh sách NHẠC NỀN cho cuộc họp theo giai đoạn: lobby (chờ), opening (mở màn), intro, present (rất nhẹ, nền khi trình bày), demo, transition (đoạn chuyển ngắn, không lặp), qa (hỏi đáp), break (giải lao), wrapup, closing (kết).", inputSchema: { type: "object", properties: { stage: { type: "string" } } } },
  { name: "meeting_music_play", description: "Phát nhạc nền cho cả phòng: track_id, hoặc stage để tự chọn bài của giai đoạn đó. Âm lượng mặc định 0.35 (present / qa: 0.12 để nằm dưới giọng nói). Khi bạn meeting_say, nhạc tự nhỏ lại rồi trả về.", inputSchema: { type: "object", properties: { track_id: { type: "string" }, stage: { type: "string" }, volume: { type: "number" }, loop: { type: "boolean" } } } },
  { name: "meeting_music_volume", description: "Đổi âm lượng nhạc nền (0..1).", inputSchema: { type: "object", properties: { volume: { type: "number" } }, required: ["volume"] } },
  { name: "meeting_music_fade", description: "Chỉnh dần âm lượng nhạc nền tới to_volume trong seconds giây (to_volume 0 = nhỏ dần rồi tắt).", inputSchema: { type: "object", properties: { to_volume: { type: "number" }, seconds: { type: "number" } }, required: ["to_volume"] } },
  { name: "meeting_music_pause", description: "Tạm dừng nhạc nền.", inputSchema: { type: "object", properties: {} } },
  { name: "meeting_music_stop", description: "Tắt nhạc nền.", inputSchema: { type: "object", properties: {} } },
];

// ---- tầng trên (kênh bí mật lồng nhau) ----
let chainP: Promise<Level[]> | null = null;
const chain = () => (chainP ??= ancestorChain(mm, CHANNEL).catch((e) => { chainP = null; throw e; }));
let meP: Promise<string> | null = null;
const botId = () => (meP ??= mm.me().then((u: any) => u.id as string));
const memberOk = new Set<string>();
interface Target { id: string; level: Level; chain: Level[]; current: boolean; defaultRoot: string }
/** Kênh được đọc: hiện tại (bỏ trống) hoặc một tổ tiên. Tổ tiên: bot phải là thành viên. */
async function target(arg: any): Promise<Target> {
  const c = await chain();
  const n = c.length - 1;
  const s = String(arg ?? "").trim();
  const low = s.toLowerCase();
  const level = !s || s === CHANNEL || low === "current" ? c[n]
    : low === "parent" || low === "cha" ? c[n - 1]
    : low === "group" || low === "nhóm" || low === "nhom" ? (c[n].kind === "ai" ? c[n - 1] : undefined)
    : low === "top" || low === "root" || low === "gốc" || low === "goc" ? c[0]
    : /^\d+$/.test(s) ? c[Number(s)]
    : c.find((l) => l.id === s);
  if (!level) {
    if (n === 0) throw new Error(c[0].kind === "ai"
      ? `channel=${s}: không đọc được nhóm gắn với chat AI này (bot chưa là thành viên nhóm). Nhờ chủ thêm bot vào nhóm.`
      : `channel=${s}: nhóm hiện tại không phải luồng bí mật hay chat AI, không có tầng trên.`);
    if (/^(group|nhóm|nhom)$/.test(low)) throw new Error(`channel=${s}: "group" chỉ dùng trong chat AI riêng; ở đây dùng "parent" / "top" / số tầng.`);
    throw new Error(`channel=${s}: chỉ đọc được kênh hiện tại hoặc các tầng trên của nó (tầng 0…${n}, "parent", "top" hoặc id trong chat_ancestors). Không đọc được kênh anh em / kênh con.`);
  }
  if (level.id !== CHANNEL && !memberOk.has(level.id)) {
    const me = await botId();
    const ok = await mm.api("GET", `/channels/${level.id}/members/${me}`).then(() => true, () => false);
    if (!ok) throw new Error(`Bot không phải thành viên của "${level.name}" (tầng ${level.tier}, id ${level.id}) nên không đọc được. Nhờ chủ bot thêm bot vào nhóm đó.`);
    memberOk.add(level.id);
  }
  // Tầng trên: chủ đề mặc định = tin gốc mà tầng dưới tách ra.
  return { id: level.id, level, chain: c, current: level.id === CHANNEL, defaultRoot: level.id === CHANNEL ? ROOT : c[level.tier + 1]?.rootId ?? "" };
}
const CHAT_ARG = { type: "string", description: "chat KHÁC trong phạm vi của bot: id kênh, ~tên kênh / tên chat, @username (chat 1-1 giữa bot và người đó) hoặc ref_id của chat được tag. Bỏ trống = chat hiện tại (khi đó dùng channel cho các tầng trên)" };
const CHANNEL_ARG = { type: "string", description: "tuỳ chọn, trong luồng bí mật / chat AI riêng: đọc kênh trên — \"group\" (nhóm gắn với chat AI), \"parent\" (tầng cha), \"top\" (nhóm gốc), số tầng (0 = nhóm gốc) hoặc id kênh tổ tiên. Bỏ trống = kênh hiện tại" };

const server = new Server(
  { name: "flygo_chat", version: "0.1.0" },
  { capabilities: { tools: {} }, instructions: "Công cụ Flygo Chat của bot: đọc kênh nơi Sếp giao việc (và các tầng trên với channel), đọc / gửi / thao tác ở mọi chat bot thấy (tham số chat / to; gửi ra chat khác cần người giao việc duyệt)." },
);

const runner = async (path: string, body: any) => {
  if (!RUNNER) throw new Error("không có runner");
  const r = await fetch(`${RUNNER}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ key: RUN_KEY, ...body }) });
  return r.json() as Promise<any>;
};
const A2A_TOOLS = [
  {
    name: "list_agents",
    description: "Liệt kê các agent AI khác (bot Flygo) đang trực tuyến mà bạn được phép nhờ qua A2A: tên, mô tả, engine, chủ.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "ask_agent",
    description: "Nhờ một agent AI khác (vd. @ba-codex) làm việc qua A2A rồi chờ kết quả. Agent đó làm bằng quyền và máy của nó, không thấy nhóm chat: hãy gửi đủ ngữ cảnh. Dùng khi tin nhắn tag nhiều agent và bạn là agent chủ trì, hoặc khi được gắn phiên của agent khác (tham số session). Tệp gửi kèm phải nằm trong thư mục làm việc; tệp agent trả về được lưu vào thư mục làm việc.",
    inputSchema: {
      type: "object",
      properties: {
        bot: { type: "string", description: "username agent, vd. ba-codex" },
        message: { type: "string", description: "việc nhờ, viết đủ ngữ cảnh" },
        files: { type: "array", items: { type: "string" }, description: "đường dẫn tệp gửi kèm (tuỳ chọn)" },
        data: { type: "object", description: "dữ liệu có cấu trúc gửi kèm (tuỳ chọn)" },
        session: { type: "string", description: "nói tiếp một phiên có sẵn của agent đó (session trong mục \"Phiên của agent khác\"); chỉ agent cùng chủ" },
      },
      required: ["bot", "message"],
    },
  },
];
const REPORT_TOOL = {
  name: "chat_report_out",
  description: "Gửi báo cáo ra chat chính của nhóm ngoài (luồng mở: chat chính của nhóm; luồng bí mật: nhóm cha; chat AI riêng: nhóm gắn). Gửi ngay, không qua bước duyệt. CHỈ dùng khi người giao việc yêu cầu báo cáo ra ngoài hoặc đã dặn trước là xong thì báo. Tệp kèm phải nằm trong thư mục làm việc.",
  inputSchema: {
    type: "object",
    properties: {
      message: { type: "string", description: "nội dung báo cáo, viết cho người ngoài luồng đọc hiểu được, không cần dòng tiêu đề" },
      files: { type: "array", items: { type: "string" }, description: "đường dẫn tệp gửi kèm (tuỳ chọn, tối đa 10)" },
      lang: { type: "string", description: "gửi SONG NGỮ (như nút Dịch AI, có nút cờ đổi bản gốc / bản dịch): mã ngôn ngữ của message, vd. vi" },
      translation: { type: "string", description: "gửi song ngữ: bản dịch của message (tự dịch)" },
      translation_lang: { type: "string", description: "gửi song ngữ: mã ngôn ngữ của bản dịch, vd. th" },
    },
    required: ["message"],
  },
};
const SKILL_TOOLS = [
  { name: "skill_list", description: "Liệt kê vai trò và các kỹ năng (skill) của bot này.", inputSchema: { type: "object", properties: {} } },
  { name: "skill_read", description: "Đọc nội dung một kỹ năng (SKILL.md) của bot.", inputSchema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } },
  {
    name: "skill_save",
    description: "Lưu (tạo mới hoặc ghi đè) một kỹ năng của bot — chỉ khi CHỦ BOT yêu cầu. Viết content là hướng dẫn từng bước rõ ràng để lần sau làm lại được; description nói khi nào dùng kỹ năng này. Cần chủ bot duyệt; có hiệu lực từ lượt sau.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "tên ngắn, chữ thường không dấu, gạch ngang, vd. hoa-don-vat" },
        description: { type: "string", description: "một câu: kỹ năng làm gì, dùng khi nào" },
        content: { type: "string", description: "nội dung SKILL.md (markdown, không cần frontmatter)" },
        files: { type: "array", description: "tệp kèm (tuỳ chọn): đường dẫn tệp trong thư mục làm việc, hoặc {path, content}", items: {} },
      },
      required: ["name", "description", "content"],
    },
  },
  { name: "skill_delete", description: "Xoá một kỹ năng của bot — chỉ khi chủ bot yêu cầu. Cần duyệt.", inputSchema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } },
  { name: "role_set", description: "Đặt vai trò / chuyên môn của bot (vd. \"Kế toán: xử lý hoá đơn, đối chiếu công nợ\") — chỉ khi chủ bot yêu cầu. Dòng đầu là tóm tắt ngắn. text rỗng = bỏ vai trò. Cần duyệt.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
];
const SCHED_PROPS = {
  title: { type: "string", description: "tên ngắn của lịch, vd. \"Báo cáo doanh thu sáng\"" },
  prompt: { type: "string", description: "việc bot sẽ làm mỗi lần chạy, viết đầy đủ như giao việc (bot lúc đó không nhớ cuộc trò chuyện này)" },
  kind: { type: "string", enum: ["once", "repeat"] },
  at: { type: "string", description: "kind=once: thời điểm, giờ địa phương, vd. 2026-10-18T08:00" },
  repeat: {
    type: "object",
    description: "kind=repeat. freq daily|weekly|monthly|cron; time HH:MM; days [1-7] (1=Thứ Hai … 7=Chủ nhật; bắt buộc với weekly, tuỳ chọn với daily); day_of_month (monthly); cron 5 trường (freq=cron)",
    properties: { freq: { type: "string", enum: ["daily", "weekly", "monthly", "cron"] }, time: { type: "string" }, days: { type: "array", items: { type: "integer" } }, day_of_month: { type: "integer" }, cron: { type: "string" } },
  },
  tz: { type: "string", description: "múi giờ IANA, mặc định Asia/Ho_Chi_Minh" },
  target: { type: "object", description: "chỗ chạy & báo kết quả; bỏ trống = chỗ hiện tại (kênh + luồng)", properties: { channel_id: { type: "string" }, root_id: { type: "string" } } },
  enabled: { type: "boolean" },
};
const SCHEDULE_TOOLS = [
  { name: "schedule_create", description: "Tạo lịch hẹn: đến giờ bot tự chạy prompt ở chỗ đích (mặc định chỗ hiện tại) và báo kết quả ở đó. Người tạo = người giao việc hiện tại.", inputSchema: { type: "object", properties: SCHED_PROPS, required: ["title", "prompt"] } },
  { name: "schedule_list", description: "Liệt kê lịch hẹn của bot (chủ bot: tất cả; người khác: lịch của mình và lịch ở chỗ này).", inputSchema: { type: "object", properties: {} } },
  { name: "schedule_update", description: "Sửa lịch hẹn (chỉ người tạo hoặc chủ bot). Chỉ truyền các trường cần đổi; enabled=false để tạm dừng.", inputSchema: { type: "object", properties: { id: { type: "string" }, ...SCHED_PROPS }, required: ["id"] } },
  { name: "schedule_delete", description: "Xoá lịch hẹn (chỉ người tạo hoặc chủ bot).", inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } },
];
const CALLEE_TOOLS = [
  {
    name: "return_files",
    description: "Gửi tệp kết quả về cho agent đã nhờ bạn (A2A). Tệp phải nằm trong thư mục làm việc.",
    inputSchema: { type: "object", properties: { paths: { type: "array", items: { type: "string" } } }, required: ["paths"] },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: A2A_ROLE === "callee" ? [...CALLEE_TOOLS, APPROVE_TOOL] : [...(A2A_ROLE === "orchestrator" ? A2A_TOOLS : []), ...CHAT_TOOLS, ...CHAT_OPS, REPORT_TOOL, ...SKILL_TOOLS, ...SCHEDULE_TOOLS, ...TASK_TOOLS, ...(MEET_CHANNEL ? MEETING_TOOLS : []), ASK_TOOL, APPROVE_TOOL] // luôn cùng danh sách tool (phiên tách từ chat chính trúng prompt cache); report_out tự báo khi không dùng được,
}));
const CHAT_TOOLS = [
    {
      name: "chat_thread",
      description: "Đọc toàn bộ một chủ đề (thread) trong kênh hiện tại (hoặc tầng trên với channel, hoặc chat khác với chat). Mặc định là chủ đề đang làm việc; ở tầng trên mặc định là chủ đề của tin gốc mà luồng bí mật tách ra.",
      inputSchema: { type: "object", properties: { root_id: { type: "string", description: "id tin gốc; bỏ trống = chủ đề hiện tại" }, channel: CHANNEL_ARG, chat: CHAT_ARG } },
    },
    {
      name: "chat_history",
      description: "Đọc tin nhắn gần nhất của kênh hiện tại, tầng trên (channel) hoặc một chat khác bot thấy (chat) — cũ hơn before_post_id nếu có. Tối đa 100 tin/lần.",
      inputSchema: { type: "object", properties: { limit: { type: "number" }, before_post_id: { type: "string" }, channel: CHANNEL_ARG, chat: CHAT_ARG } },
    },
    {
      name: "chat_search",
      description: "Tìm tin nhắn trong kênh hiện tại (hoặc tầng trên với channel, hoặc chat khác với chat) theo từ khoá (cú pháp tìm kiếm của máy chủ chat).",
      inputSchema: { type: "object", properties: { terms: { type: "string" }, channel: CHANNEL_ARG, chat: CHAT_ARG }, required: ["terms"] },
    },
    {
      name: "chat_info",
      description: "Thông tin nhóm chat hiện tại: tên, mô tả, loại, danh sách thành viên (tên, chức danh, quản trị nhóm, bot).",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "chat_files",
      description: "Liệt kê tệp đính kèm trong chủ đề hiện tại (hoặc root_id), hoặc trong N tin gần nhất của nhóm nếu scope=channel. Với channel: tệp ở tầng trên.",
      inputSchema: { type: "object", properties: { scope: { type: "string", enum: ["thread", "channel"] }, root_id: { type: "string" }, limit: { type: "number" }, channel: CHANNEL_ARG } },
    },
    {
      name: "chat_read_file",
      description: "Tải một tệp đính kèm (theo file_id) về thư mục làm việc. Tệp văn bản (txt, md, csv, json, code…) trả luôn nội dung; tệp khác (pdf, ảnh, office) trả đường dẫn đã lưu để đọc bằng công cụ khác. Tệp phải thuộc kênh hiện tại hoặc tầng trên (channel).",
      inputSchema: { type: "object", properties: { file_id: { type: "string" }, channel: CHANNEL_ARG }, required: ["file_id"] },
    },
    {
      name: "chat_ancestors",
      description: "Chuỗi tầng của luồng bí mật hiện tại, từ nhóm gốc (tầng 0) tới đây: tầng, tên, id kênh, tin gốc mà mỗi tầng tách ra. Kênh thường chỉ có một tầng.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "ref_read",
      description: "Đọc tin của một chat / luồng mà người dùng TAG cho bạn kèm quyền tạm (xem mục \"Chat được tag\" trong ngữ cảnh; bạn không là thành viên chat đó). Đọc có chọn lọc: dùng q để tìm theo từ khoá, limit nhỏ, before=<id tin cũ nhất đã đọc> để xem trang trước. Hết hạn thì báo người dùng tag lại.",
      inputSchema: { type: "object", properties: { ref_id: { type: "string" }, q: { type: "string", description: "từ khoá cần tìm (tuỳ chọn)" }, before: { type: "string", description: "id tin: chỉ lấy tin cũ hơn tin này (tuỳ chọn)" }, limit: { type: "number", description: "số tin, tối đa 50, mặc định 30" } }, required: ["ref_id"] },
    },
    {
      name: "ref_thread",
      description: "Đọc cả một luồng trong chat được tag (root = id tin gốc, lấy từ ref_read). Ref là một luồng thì chỉ đọc được đúng luồng đó.",
      inputSchema: { type: "object", properties: { ref_id: { type: "string" }, root: { type: "string", description: "id tin gốc của luồng (ref là luồng thì bỏ trống)" } }, required: ["ref_id"] },
    },
    {
      name: "ref_post",
      description: "GỬI tin vào một chat / luồng được tag (chỉ khi quyền cho phép gửi, và chỉ khi người giao việc muốn gửi vào đó). Tin hiện dưới tên bạn. root_id để trả lời trong một luồng của chat đó (ref là luồng thì tự trả lời trong luồng đó).",
      inputSchema: { type: "object", properties: { ref_id: { type: "string" }, message: { type: "string" }, root_id: { type: "string", description: "tuỳ chọn" } }, required: ["ref_id", "message"] },
    },
    {
      name: "chat_session_title",
      description: "ĐẶT TÊN cho phiên chat AI mới (chỉ dùng khi lời nhắc báo phiên chưa có tên). Tên ngắn tiếng Việt 2–6 từ, tối đa 40 ký tự, nói đúng chủ đề; không dấu chấm cuối, không ngoặc kép. Phiên đã có tên thì không đổi.",
      inputSchema: { type: "object", properties: { name: { type: "string", description: "tên phiên, vd. \"Lịch họp quý 4\"" } }, required: ["name"] },
    },
    {
      name: "session_rename",
      description: "ĐỔI TÊN phiên AI hiện tại bất cứ lúc nào (khác chat_session_title chỉ đặt tên lần đầu): khi chủ đề phiên đã đổi hoặc người dùng bảo đổi tên. Tên ngắn tiếng Việt 2–6 từ, tối đa 40 ký tự, không dấu chấm cuối, không ngoặc kép. Không cần duyệt.",
      inputSchema: { type: "object", properties: { name: { type: "string", description: "tên mới, vd. \"Sửa lỗi đăng nhập iOS\"" } }, required: ["name"] },
    },
    {
      name: "session_fork",
      description: "TÁCH (fork) phiên AI hiện tại thành một phiên mới cùng nhóm / dự án, cùng chủ: phiên mới NHỚ mọi thứ đã bàn ở đây, rồi đi theo nhánh riêng (thử một hướng khác, làm song song một việc con) mà không làm rối phiên này. Cần người giao việc duyệt (tự duyệt khi đang \"Luôn cho phép\"). Trả về link phiên mới; người dùng nhắn ở đó để làm tiếp nhánh.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "tên phiên mới, 2–6 từ" },
          note: { type: "string", description: "lời nhắn đầu phiên mới: nhánh này để làm gì (tuỳ chọn)" },
          project_id: { type: "string", description: "tạo phiên trong một dự án khác của chủ (id từ project_list); bỏ trống = cùng nhóm / dự án với phiên này" },
        },
        required: ["title"],
      },
    },
    {
      name: "session_new",
      description: "CHUYỂN SANG PHIÊN MỚI sạch ngữ cảnh khi phiên này đã quá dài (ngữ cảnh phình, chậm, hay quên) hoặc việc đã sang chủ đề khác: tạo phiên AI mới cùng nhóm / dự án, cùng chủ, tin đầu là BẢN BÀN GIAO có cấu trúc (phiên mới chỉ biết những gì ghi trong bàn giao, nên viết đủ), phiên này được đánh dấu xong kèm link sang phiên mới. start=true: bạn làm tiếp ngay ở phiên mới (lượt mới chạy ở đó). Cần người giao việc duyệt (tự duyệt khi đang \"Luôn cho phép\"). Trả về link phiên mới.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "tên phiên mới, 2–6 từ" },
          handoff: {
            type: "object",
            description: "bản bàn giao (mỗi mục là chuỗi hoặc danh sách chuỗi)",
            properties: {
              goal: { description: "mục tiêu chung của việc" },
              done: { description: "đã làm xong những gì (kết quả, quyết định đã chốt)" },
              remaining: { description: "còn lại những gì, theo thứ tự nên làm" },
              files: { description: "tệp, thư mục, nhánh git, link liên quan (đường dẫn đầy đủ)" },
              cautions: { description: "lưu ý: điều Sếp dặn, chỗ dễ sai, việc không được làm" },
            },
            required: ["goal", "remaining"],
          },
          start: { type: "boolean", description: "true = làm tiếp ngay ở phiên mới; mặc định false (chờ Sếp nhắn ở phiên mới)" },
          project_id: { type: "string", description: "tạo phiên trong một dự án khác của chủ (id từ project_list); bỏ trống = cùng nhóm / dự án" },
        },
        required: ["title", "handoff"],
      },
    },
    {
      name: "project_list",
      description: "Liệt kê các DỰ ÁN trợ lý của chủ bot (tab Agents trên app) mà bot là thành viên: tên, id, thư mục làm việc, số phiên đang mở. Chỉ chủ bot.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "project_create",
      description: "TẠO DỰ ÁN trợ lý mới cho chủ bot (hiện ở tab Agents, gom các phiên cùng một việc), tuỳ chọn gắn thư mục làm việc trên máy chạy bot (phải nằm trong projectRoots). Chỉ chủ bot; cần duyệt (tự duyệt khi đang \"Luôn cho phép\"). Sau đó tạo phiên trong dự án bằng session_new / session_fork với project_id.",
      inputSchema: { type: "object", properties: { name: { type: "string" }, path: { type: "string", description: "thư mục làm việc, vd. ~/dev/du-an (tuỳ chọn)" } }, required: ["name"] },
    },
    {
      name: "project_rename",
      description: "ĐỔI TÊN một dự án của chủ bot (id từ project_list). Chỉ chủ bot, chỉ dự án của chính chủ; không cần duyệt.",
      inputSchema: { type: "object", properties: { project_id: { type: "string" }, name: { type: "string" } }, required: ["project_id", "name"] },
    },
    {
      name: "chat_edit_message",
      description: "SỬA nội dung một tin nhắn do CHÍNH BẠN (bot này) đã gửi trước đó: gửi sai số liệu, sai chính tả, thiếu ý, hoặc người dùng bảo sửa lại tin đó. Không sửa được tin của người khác hay của bot khác; không dùng cho câu trả lời đang viết của lượt này (cứ viết lại trong câu trả lời). Thay toàn bộ nội dung chữ, giữ nguyên tệp đính kèm. post_id lấy từ #id trong chat_history / chat_thread / chat_search hoặc kết quả các tool gửi tin. Không cần duyệt; thẻ ghi lại bước \"Đã sửa tin\".",
      inputSchema: { type: "object", properties: { post_id: { type: "string", description: "id tin cần sửa (26 ký tự)" }, message: { type: "string", description: "nội dung mới, thay toàn bộ nội dung cũ" } }, required: ["post_id", "message"] },
    },
    {
      name: "chat_recall_message",
      description: "THU HỒI (xoá) một tin nhắn do CHÍNH BẠN đã gửi trước đó: gửi nhầm chỗ, nhầm người, lộ thông tin, hoặc người dùng bảo thu hồi. Người khác thấy \"Tin nhắn đã được thu hồi\". Không thu hồi được tin của người khác hay của bot khác. Lưu ý: nếu tin là TIN GỐC của một luồng thì cả luồng mất tin gốc (các trả lời còn đó nhưng mồ côi), chỉ làm khi thật cần. Không cần duyệt; thẻ ghi lại bước \"Đã thu hồi tin\".",
      inputSchema: { type: "object", properties: { post_id: { type: "string", description: "id tin cần thu hồi (26 ký tự)" }, reason: { type: "string", description: "lý do ngắn (tuỳ chọn, ghi vào thẻ)" } }, required: ["post_id"] },
    },
    {
      name: "session_list",
      description: "Liệt kê các PHIÊN AI khác của Sếp với bot này (chat AI riêng / phiên trong dự án, kèm nhóm gắn, tin cuối, đang chạy hay không). Chỉ chủ bot.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "session_read",
      description: "ĐỌC các tin gần đây của một phiên AI khác (để biết phiên đó đang làm gì / đã làm tới đâu). session_id lấy từ session_list.",
      inputSchema: { type: "object", properties: { session_id: { type: "string" }, limit: { type: "number", description: "số tin (mặc định 20, tối đa 100)" } }, required: ["session_id"] },
    },
    {
      name: "session_ask",
      description: "HỎI một phiên AI khác của Sếp: chạy thẳng nối tiếp phiên làm việc của phiên đó (đủ ngữ cảnh của nó, chỉ đọc), KHÔNG hiện gì trong chat của phiên đó trên app; câu trả lời trả về đây. Dùng khi Sếp bảo hỏi phiên khác / việc nằm ở phiên khác. Chờ tối đa wait_sec (mặc định 300).",
      inputSchema: { type: "object", properties: { session_id: { type: "string" }, message: { type: "string" }, wait_sec: { type: "number" } }, required: ["session_id", "message"] },
    },
    {
      name: "cc_list",
      description: "Liệt kê các phiên CLAUDE CODE đang chạy trên cùng máy với bot (tên, rảnh / đang làm, thư mục). Chỉ chủ bot.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "cc_read",
      description: "ĐỌC lịch sử gần đây của một phiên Claude Code trên máy (biết nó đang làm gì). name lấy từ cc_list.",
      inputSchema: { type: "object", properties: { name: { type: "string" }, limit: { type: "number", description: "số tin (mặc định 12, tối đa 60)" } }, required: ["name"] },
    },
    {
      name: "cc_ask",
      description: "HỎI một phiên Claude Code trên máy: hỏi trên một bản sao của phiên đó (đủ ngữ cảnh, chỉ đọc), phiên gốc không nhận tin và không hiện gì; câu trả lời trả về đây (tối đa wait_sec, mặc định 300).",
      inputSchema: { type: "object", properties: { name: { type: "string" }, message: { type: "string" }, wait_sec: { type: "number" } }, required: ["name", "message"] },
    },
    {
      name: "chat_send_bilingual",
      description: "GỬI TIN SONG NGỮ vào chủ đề hiện tại, giống nút \"Dịch AI\" của app: người đọc thấy phần theo ngôn ngữ của họ và có nút cờ để đổi giữa bản gốc và bản dịch. Dùng khi người giao việc bảo gửi / trả lời song ngữ, nhắn cho người nói tiếng khác (vd. đối tác Hàn, Thái), hoặc nhóm có người không đọc được ngôn ngữ của tin. Tự dịch rồi truyền cả hai bản; không dùng cho câu trả lời thường của lượt (cứ viết trong câu trả lời). Tool này gửi vào CHỖ ĐANG Ở; đang ở chat AI riêng / luồng mà cần gửi song ngữ ra nhóm thì dùng chat_report_out kèm lang, translation, translation_lang. Mã ngôn ngữ ISO 639-1: vi, en, ko, ja, th, zh…",
      inputSchema: {
        type: "object",
        properties: {
          text: { type: "string", description: "bản gốc" },
          lang: { type: "string", description: "mã ngôn ngữ của bản gốc, vd. vi" },
          translation: { type: "string", description: "bản dịch (cùng ý, giữ @nhắc tên, link, số, emoji)" },
          translation_lang: { type: "string", description: "mã ngôn ngữ của bản dịch, vd. ko" },
        },
        required: ["text", "lang", "translation", "translation_lang"],
      },
    },
    {
      name: "chat_send_files",
      description: "GỬI tệp vào chủ đề hiện tại của nhóm (ảnh, video, ghi âm, pdf, office, tệp bất kỳ). Dùng tool này mỗi khi tạo hoặc tải được tệp cho Sếp, KHÔNG dán đường dẫn trên máy vào tin nhắn. Tệp phải nằm trong thư mục làm việc. Ghi âm nên là m4a/mp3/ogg, ảnh png/jpg, video mp4 để app hiển thị/phát được.",
      inputSchema: { type: "object", properties: { paths: { type: "array", items: { type: "string" }, description: "đường dẫn tệp (tuyệt đối hoặc tương đối với thư mục làm việc)" }, message: { type: "string", description: "lời nhắn kèm (tuỳ chọn)" } }, required: ["paths"] },
    },
];
// ---- bộ công cụ chat (runner: chat-ops.ts) ----
const TO_ARG = { type: "string", description: "chat đích: id kênh, ~tên kênh / tên chat, @username (nhắn riêng giữa bot và người đó), ref_id của chat được tag; bỏ trống / \"here\" = chat hiện tại" };
const POST_ARG = { type: "string", description: "id tin (26 ký tự, #id trong chat_history / chat_thread / chat_search / chat_unread)" };
const WHEN = "giờ Việt Nam dạng 2026-11-02T08:00, hoặc tương đối \"30m\" / \"2h\" / \"1d\"";
const CHAT_OPS = [
  // ---- đọc (không cần duyệt) ----
  { name: "chat_list", description: "DANH SÁCH CHAT bot thấy (nhóm, kênh, luồng bí mật, nhóm nhắn tin, chat 1-1 giữa bot và người khác, phiên AI của người giao việc): tên, loại, id, số tin bot chưa đọc, tin cuối. Mới hoạt động trước. Dùng để tìm id chat trước khi đọc / gửi. Người giao việc không phải chủ bot chỉ thấy chat mình cũng ở trong.", inputSchema: { type: "object", properties: { type: { type: "string", enum: ["all", "channel", "group", "dm", "private_thread", "ai", "project"], description: "lọc loại (mặc định all)" }, query: { type: "string", description: "lọc theo tên (không dấu cũng được)" }, unread_only: { type: "boolean" }, active_since: { type: "string", description: `chỉ chat có tin từ lúc này (${WHEN}, "1d" = 1 ngày qua)` }, limit: { type: "number", description: "mặc định 30, tối đa 100" } } } },
  { name: "chat_unread", description: "TIN MỚI trên mọi chat bot thấy kể từ một thời điểm (mặc định 24 giờ qua), gom theo chat; ⚑ đánh dấu tin nhắc @bot / @chủ bot / @all hoặc tin nhắn riêng. only=mentions để chỉ lấy tin nhắc. Dùng khi được hỏi \"có gì mới\", \"ai nhắc tôi\", \"tin chưa đọc\".", inputSchema: { type: "object", properties: { since: { type: "string", description: `từ lúc nào (${WHEN}; "3h" = 3 giờ qua)` }, only: { type: "string", enum: ["all", "mentions"] }, limit: { type: "number", description: "tổng số tin tối đa (mặc định 80)" } } } },
  { name: "chat_get_message", description: "XEM ĐỦ MỘT TIN: người gửi, thời gian, nội dung, cảm xúc (ai thả gì), ưu tiên và ai đã xác nhận đã đọc, tệp, bình chọn (số phiếu), vị trí trong luồng, đã ghim chưa, link.", inputSchema: { type: "object", properties: { post_id: POST_ARG }, required: ["post_id"] } },
  { name: "chat_members", description: "THÀNH VIÊN của một chat bot thấy (tên, @username, id, chức danh, quản trị, bot).", inputSchema: { type: "object", properties: { chat: CHAT_ARG } } },
  { name: "chat_find_user", description: "TÌM NGƯỜI trong máy chủ chat theo tên / username / chức danh (gõ tiếng Việt không dấu được, vd. \"nguyen van a\", \"ke toan\"). Trả tên, @username, id.", inputSchema: { type: "object", properties: { query: { type: "string" }, limit: { type: "number" } }, required: ["query"] } },
  { name: "user_info", description: "THÔNG TIN MỘT NGƯỜI: tên, chức danh, trạng thái (trực tuyến / vắng / không làm phiền), trạng thái tuỳ chỉnh, hoạt động gần nhất, múi giờ và giờ địa phương.", inputSchema: { type: "object", properties: { user: { type: "string", description: "@username, id hoặc tên" } }, required: ["user"] } },
  { name: "chat_pinned", description: "TIN ĐÃ GHIM của một chat.", inputSchema: { type: "object", properties: { chat: CHAT_ARG } } },
  { name: "chat_digest", description: "DỮ LIỆU ĐỂ TÓM TẮT một hay nhiều chat từ một thời điểm: số tin, ai nói nhiều, luồng sôi nổi, tin khẩn, bình chọn, tệp và các tin (cũ → mới). Bạn tự viết bản tóm tắt (việc cần làm, quyết định, câu hỏi chưa trả lời). Bỏ trống chats = các chat có tin mới (tối đa 15).", inputSchema: { type: "object", properties: { chats: { type: "array", items: { type: "string" }, description: "danh sách chat (id / ~tên / @username)" }, since: { type: "string", description: `từ lúc nào (${WHEN}; mặc định 24 giờ qua)` }, limit_per_chat: { type: "number", description: "số tin tối đa mỗi chat (mặc định 40)" } } } },
  // ---- gửi (cần người giao việc duyệt, trừ khi gửi vào chat hiện tại; tự duyệt khi "Luôn cho phép") ----
  { name: "chat_send", description: "GỬI TIN tới bất kỳ chat nào bot thấy, hoặc NHẮN RIÊNG một người (to=@username: chat 1-1 giữa bot và người đó). Chỉ gửi khi người giao việc muốn gửi tới đó. Gửi ra chat khác cần người giao việc duyệt. Tuỳ chọn: thread_root (trả lời trong luồng của tin đó), files (tệp trong thư mục làm việc), priority important|urgent và ack (tin gốc: gắn nhãn, người nhận bấm xác nhận đã đọc), silent (không báo), mention (username được @nhắc thật; mặc định @tên trong tin không báo ai). Tin hiện dưới tên bot.", inputSchema: { type: "object", properties: { to: TO_ARG, message: { type: "string" }, files: { type: "array", items: { type: "string" } }, thread_root: POST_ARG, priority: { type: "string", enum: ["important", "urgent"] }, ack: { type: "boolean" }, silent: { type: "boolean" }, mention: { type: "array", items: { type: "string" } } }, required: ["to", "message"] } },
  { name: "chat_reply", description: "TRẢ LỜI một tin (trong luồng của tin đó), ở bất kỳ chat nào bot thấy. Chat khác chat hiện tại cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, message: { type: "string" }, files: { type: "array", items: { type: "string" } } }, required: ["post_id", "message"] } },
  { name: "chat_forward", description: "CHUYỂN TIẾP một tin (kèm tệp) sang chat khác, tuỳ chọn kèm lời nhắn. Cần duyệt nếu đích không phải chat hiện tại.", inputSchema: { type: "object", properties: { post_id: POST_ARG, to: TO_ARG, comment: { type: "string" } }, required: ["post_id", "to"] } },
  { name: "chat_schedule_message", description: "HẸN GIỜ GỬI một tin (tin hẹn giờ của máy chủ, như nút Hẹn giờ gửi của app): máy chủ tự gửi đúng giờ dưới tên bot, kể cả khi máy chạy bot tắt. Cần duyệt nếu đích không phải chat hiện tại. Việc bot phải TỰ LÀM lúc đó thì dùng schedule_create.", inputSchema: { type: "object", properties: { to: TO_ARG, message: { type: "string" }, at: { type: "string", description: WHEN }, thread_root: POST_ARG }, required: ["to", "message", "at"] } },
  { name: "chat_poll", description: "TẠO BÌNH CHỌN (hiện thành thẻ bình chọn trên app, mọi người bấm chọn ngay trong tin). Câu hỏi ngắn, 2–20 phương án. Tuỳ chọn: multi (chọn nhiều), revote (đổi phiếu, mặc định có), allow_add (người khác thêm phương án), duration_min hoặc ends_at (hết hạn), pin (ghim). Người giao việc là người tạo (khoá được trên app). Xem kết quả bằng chat_get_message.", inputSchema: { type: "object", properties: { to: TO_ARG, question: { type: "string" }, options: { type: "array", items: { type: "string" } }, multi: { type: "boolean" }, revote: { type: "boolean" }, allow_add: { type: "boolean" }, duration_min: { type: "number" }, ends_at: { type: "string", description: WHEN }, thread_root: POST_ARG, pin: { type: "boolean" } }, required: ["to", "question", "options"] } },
  { name: "chat_send_card", description: "GỬI THẺ CÓ NÚT (1–9 nút) vào một chat: ai trong chat bấm một nút thì bạn được gọi lại ở CHỖ NÀY trong một lượt mới, kèm người bấm và lựa chọn (thẻ chỉ nhận lần bấm đầu tiên). Dùng để xin xác nhận / lựa chọn của người khác (vd. \"Duyệt chi 5 triệu?\" [Đồng ý] [Từ chối]). Hỏi chính người giao việc ngay trong lượt thì dùng ask_user. Cần duyệt nếu đích không phải chat hiện tại.", inputSchema: { type: "object", properties: { to: TO_ARG, text: { type: "string" }, buttons: { type: "array", items: { type: "object", properties: { label: { type: "string" }, description: { type: "string" } }, required: ["label"] } }, multi: { type: "boolean", description: "cho chọn nhiều nút rồi xác nhận" }, header: { type: "string", description: "nhãn ngắn ≤12 ký tự" }, thread_root: POST_ARG }, required: ["to", "text", "buttons"] } },
  // ---- thao tác trên tin ----
  { name: "chat_react", description: "THẢ CẢM XÚC lên một tin (tên cảm xúc: +1, white_check_mark, heart, eyes, tada…). Không cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, emoji: { type: "string" } }, required: ["post_id", "emoji"] } },
  { name: "chat_unreact", description: "GỠ CẢM XÚC bot đã thả trên một tin. Không cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, emoji: { type: "string" } }, required: ["post_id", "emoji"] } },
  { name: "chat_pin", description: "GHIM một tin lên đầu chat. Cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG }, required: ["post_id"] } },
  { name: "chat_unpin", description: "BỎ GHIM một tin. Cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG }, required: ["post_id"] } },
  { name: "chat_ack", description: "XÁC NHẬN ĐÃ ĐỌC (thay bot) một tin quan trọng / khẩn có yêu cầu xác nhận. Không cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG }, required: ["post_id"] } },
  { name: "chat_mark_read", description: "ĐÁNH DẤU ĐÃ ĐỌC một chat (với bot; số chưa đọc trong chat_list về 0). Không cần duyệt.", inputSchema: { type: "object", properties: { chat: CHAT_ARG } } },
  { name: "chat_remind_me", description: "NHẮC HẸN về một tin: for=bot (mặc định) — tới giờ bạn được gọi lại ở chỗ này trong một lượt mới để xử lý tin đó; for=owner — nhắc chủ bot (nhắc của máy chủ, không được thì bot hẹn một tin nhắn riêng cho chủ; chỉ khi người giao việc là chủ bot). Không cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, at: { type: "string", description: WHEN }, for: { type: "string", enum: ["bot", "owner"] }, note: { type: "string", description: "ghi chú: cần làm gì khi tới giờ" } }, required: ["post_id", "at"] } },
  // ---- quản lý cuộc trò chuyện (cần duyệt; bớt người chỉ chủ bot) ----
  { name: "chat_create", description: "TẠO NHÓM / KÊNH mới trong team (mặc định nhóm riêng; private=false = kênh công khai) với các thành viên; người giao việc luôn được thêm và làm quản trị. Cần duyệt.", inputSchema: { type: "object", properties: { name: { type: "string", description: "tên hiển thị" }, members: { type: "array", items: { type: "string" }, description: "@username / id" }, private: { type: "boolean" }, purpose: { type: "string" } }, required: ["name"] } },
  { name: "chat_add_members", description: "THÊM NGƯỜI vào một nhóm / kênh bot đang ở. Cần duyệt.", inputSchema: { type: "object", properties: { chat: CHAT_ARG, users: { type: "array", items: { type: "string" } } }, required: ["chat", "users"] } },
  { name: "chat_remove_member", description: "BỚT MỘT NGƯỜI khỏi nhóm / kênh. Chỉ khi người giao việc là chủ bot; cần duyệt.", inputSchema: { type: "object", properties: { chat: CHAT_ARG, user: { type: "string" } }, required: ["chat", "user"] } },
  { name: "chat_rename", description: "ĐỔI TÊN một nhóm / kênh / luồng bí mật (phiên AI dùng session_rename). Cần duyệt.", inputSchema: { type: "object", properties: { chat: CHAT_ARG, name: { type: "string" } }, required: ["chat", "name"] } },
  { name: "chat_set_purpose", description: "ĐỔI MÔ TẢ (mục đích) của một nhóm / kênh (giữ các mốc kỹ thuật của app). purpose rỗng = xoá mô tả. Cần duyệt.", inputSchema: { type: "object", properties: { chat: CHAT_ARG, purpose: { type: "string" } }, required: ["chat", "purpose"] } },
  { name: "thread_create_private", description: "TẠO LUỒNG BÍ MẬT (luồng riêng của app) từ một tin: kênh riêng chỉ gồm người giao việc, bot và các thành viên chọn (phải ở chat chứa tin), tin gốc được chép vào làm tin đầu. Cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, members: { type: "array", items: { type: "string" } }, name: { type: "string", description: "tên luồng (mặc định: đầu tin gốc)" } }, required: ["post_id"] } },
  { name: "thread_close", description: "ĐÓNG LUỒNG như nút Đóng luồng của app: post_id = một tin trong luồng công việc, hoặc chat = một luồng bí mật. Luồng đã đóng thì bot không nhận việc mới ở đó tới khi mở lại. Cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, chat: CHAT_ARG } } },
  { name: "thread_reopen", description: "MỞ LẠI LUỒNG đã đóng (post_id trong luồng, hoặc chat = luồng bí mật). Cần duyệt.", inputSchema: { type: "object", properties: { post_id: POST_ARG, chat: CHAT_ARG } } },
  { name: "user_set_status", description: "ĐẶT TRẠNG THÁI TUỲ CHỈNH CỦA BOT (dòng trạng thái mọi người thấy, thay cho \"Đang chạy trên …\"), vd. \"Đang tổng hợp báo cáo tháng\". text rỗng = bỏ. expires: hết hạn (giờ Việt Nam hoặc \"2h\"). Chỉ khi người giao việc là chủ bot.", inputSchema: { type: "object", properties: { text: { type: "string" }, emoji: { type: "string", description: "tên cảm xúc, vd. hourglass" }, expires: { type: "string" } }, required: ["text"] } },
];
const ASK_TOOL = {
  name: "ask_user",
  description: "Hỏi người đang giao việc một hoặc vài câu trắc nghiệm và CHỜ trả lời ngay trong lượt này (người dùng bấm chọn trên app, hoặc gõ ý khác). Dùng khi cần người dùng quyết định giữa vài hướng; đừng hỏi điều tự tìm được. Claude: dùng AskUserQuestion thay tool này.",
  inputSchema: {
    type: "object",
    properties: {
      questions: {
        type: "array", minItems: 1, maxItems: 4,
        items: {
          type: "object",
          properties: {
            question: { type: "string" },
            header: { type: "string", description: "nhãn ngắn (≤12 ký tự)" },
            options: { type: "array", minItems: 2, maxItems: 4, items: { type: "object", properties: { label: { type: "string" }, description: { type: "string" } }, required: ["label"] } },
            multi: { type: "boolean", description: "cho chọn nhiều" },
          },
          required: ["question", "options"],
        },
      },
    },
    required: ["questions"],
  },
};
const APPROVE_TOOL = {
  name: "approve",
  description: "Nội bộ: xin Sếp duyệt quyền dùng công cụ. Không tự gọi.",
  inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } }, required: ["tool_name", "input"] },
};

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  await refreshCtx();
  try { return await callTool(req); } catch (e: any) {
    if (/^channel=|^Bot không phải thành viên/.test(e?.message ?? "")) return text(e.message); // lỗi phạm vi đọc: trả rõ cho agent
    throw e;
  }
});
async function callTool(req: any): Promise<any> {
  const a = (req.params.arguments ?? {}) as any;
  if (A2A_ROLE === "callee" && !["return_files", "approve"].includes(req.params.name)) throw new Error(`tool không dùng được khi làm việc được nhờ: ${req.params.name}`);
  if (req.params.name === "meeting_suggest" || req.params.name === "meeting_watch") {
    const r = await runner(req.params.name === "meeting_suggest" ? "/meet_suggest" : "/meet_watch", a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
    return text(r.text ?? JSON.stringify(r));
  }
  if (String(req.params.name).startsWith("meeting_")) return text(await meetingTool(req.params.name, a).catch((e) => `Lỗi: ${e?.message ?? e}`));
  if (TASK_TOOL_NAMES.has(req.params.name)) {
    // Tool ghi (task_create / task_update) xin người giao việc duyệt qua runner, như thẻ duyệt của engine; ngoài lượt chat thì từ chối.
    const approve = async (tool: string, input: any) => {
      if (!RUNNER || !RUN_KEY) return false;
      const r = await fetch(`${RUNNER}/approve`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ key: RUN_KEY, tool_name: `mcp__flygo_chat__${tool}`, input }) })
        .then((x) => x.json()).catch(() => ({ allow: false }));
      return !!r.allow;
    };
    return text(await taskTool(req.params.name, a, { mm, boards, channel: CHANNEL, requester: OWNER_ID, approve }).catch((e) => `Lỗi: ${e?.message ?? e}`));
  }
  // Bộ công cụ chat: runner xử lý (phạm vi + duyệt); chat_history / chat_thread / chat_search có `chat` cũng qua runner.
  if (CHAT_OP_TOOLS.has(req.params.name) || (["chat_history", "chat_thread", "chat_search"].includes(req.params.name) && String(a.chat ?? "").trim())) {
    const r = await runner(`/chat_op/${req.params.name}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
    return text(r.text ?? JSON.stringify(r));
  }
  switch (req.params.name) {
    case "list_agents": case "ask_agent": case "return_files": {
      if (req.params.name !== "return_files" && A2A_ROLE !== "orchestrator") throw new Error("A2A không bật cho phiên này");
      const r = await runner(`/a2a/${req.params.name}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "schedule_create": case "schedule_list": case "schedule_update": case "schedule_delete": {
      const r = await runner(`/schedule/${req.params.name.slice(9)}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "skill_list": case "skill_read": case "skill_save": case "skill_delete": case "role_set": {
      const op = { skill_list: "list", skill_read: "read", skill_save: "save", skill_delete: "delete", role_set: "role" }[req.params.name as string];
      const r = await runner(`/skill/${op}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "ref_read": case "ref_thread": case "ref_post": {
      const r = await runner(`/ref/${req.params.name.slice(4)}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "session_list": case "session_read": case "session_ask": case "cc_list": case "cc_read": case "cc_ask": {
      const [kind, op] = String(req.params.name).split("_");
      const r = await runner(`/${kind}/${op}`, { ...a, owner: OWNER_ID, channel: CHANNEL }).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "session_rename": case "session_fork": case "session_new": case "project_list": case "project_create": case "project_rename": {
      const r = await runner(`/sess_op/${req.params.name}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "chat_session_title": {
      const r = await runner("/session_title", a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "chat_edit_message": case "chat_recall_message": {
      const r = await runner("/post_op", { ...a, op: req.params.name === "chat_edit_message" ? "edit" : "recall" }).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "chat_report_out": {
      if (!REPORT_OUT) return text("chat_report_out chỉ dùng được trong luồng, luồng bí mật hoặc chat AI riêng; ở chat chính của nhóm cứ trả lời bình thường. Muốn gửi song ngữ ngay tại đây thì dùng chat_send_bilingual.");
      const r = await runner("/report_out", a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "chat_ancestors": {
      const c = await chain();
      const n = c.length - 1;
      if (!n) return text(`Nhóm hiện tại không có tầng trên: "${c[0].name}" (id ${c[0].id}).${c[0].kind === "ai" ? " Đây là chat AI riêng nhưng bot chưa đọc được nhóm gắn với nó." : ""}`);
      const kindName = (l: Level) => l.kind === "ai" ? "chat AI riêng" : l.kind === "secret" ? "luồng bí mật" : "nhóm";
      return text([`${c[n].kind === "ai" ? `Chat AI riêng gắn với "${c[n - 1].name}"` : `Luồng bí mật tầng ${n}`}:`, ...c.map((l) => `- Tầng ${l.tier} · ${kindName(l)}${l.tier === 0 ? " (gốc)" : l.tier === n - 1 ? (c[n].kind === "ai" ? " (nhóm gắn — channel=\"group\")" : " (cha)") : ""}${l.tier === n ? " (đang ở đây)" : ""}: "${l.name}" — id ${l.id}${l.rootId ? `; tách từ tin ${l.rootId}: ${l.rootText.slice(0, 500)}` : ""}`)].join("\n"));
    }
    case "chat_thread": {
      const t = await target(a.channel);
      const root = a.root_id || t.defaultRoot;
      if (!root) return text("Đang trò chuyện ở chat chính, không có chủ đề hiện tại — dùng chat_history.");
      const posts = await mm.thread(root);
      if (posts[0] && posts[0].channel_id !== t.id) return text(`Chủ đề này không thuộc kênh "${t.level.name}".`);
      return text(await fmt(posts));
    }
    case "chat_history": {
      const t = await target(a.channel);
      const limit = Math.min(Math.max(Number(a.limit) || 30, 1), 100);
      return text(await fmt(await mm.channelPosts(t.id, limit, a.before_post_id || undefined)));
    }
    case "chat_search": {
      const t = await target(a.channel);
      const ch = await mm.channel(t.id);
      const r = await mm.api<any>("POST", `/teams/${ch.team_id}/posts/search`, { terms: String(a.terms), is_or_search: false, per_page: 60 });
      const posts = (r.order as string[]).map((id) => r.posts[id] as Post).filter((p) => p.channel_id === t.id).sort((x, y) => x.create_at - y.create_at);
      return text(await fmt(posts));
    }
    case "chat_info": {
      const ch = await mm.channel(CHANNEL);
      const members = await mm.api<any[]>("GET", `/channels/${CHANNEL}/members?per_page=200`);
      const users = await mm.api<any[]>("POST", "/users/ids", members.map((m) => m.user_id));
      const byId = new Map(users.map((u) => [u.id, u]));
      const lines = members.map((m) => {
        const u = byId.get(m.user_id) ?? { username: m.user_id };
        const name = u.nickname || [u.first_name, u.last_name].filter(Boolean).join(" ") || u.username;
        const tags = [u.position, m.scheme_admin ? "quản trị nhóm" : "", u.is_bot ? "bot" : ""].filter(Boolean).join(", ");
        return `- ${name} (@${u.username})${tags ? " — " + tags : ""}`;
      });
      const type = { O: "nhóm công khai", P: "nhóm riêng", D: "tin nhắn riêng", G: "nhóm nhắn tin" }[ch.type as string] ?? ch.type;
      return text([`Nhóm: ${ch.display_name || ch.name} (${type})`, ch.purpose ? `Mục đích: ${ch.purpose}` : "", ch.header ? `Tiêu đề: ${ch.header}` : "", `Thành viên (${members.length}):`, ...lines].filter(Boolean).join("\n"));
    }
    case "chat_files": {
      const t = await target(a.channel);
      const root = a.root_id || t.defaultRoot;
      if (a.scope !== "channel" && !root) return text("Không có chủ đề hiện tại — dùng scope=channel.");
      const posts = a.scope === "channel" ? await mm.channelPosts(t.id, Math.min(Number(a.limit) || 100, 200)) : await mm.thread(root);
      const out: string[] = [];
      for (const p of posts) {
        if (p.channel_id !== t.id) continue;
        for (const f of ((p as any).metadata?.files ?? []) as any[]) out.push(`- ${f.name} (file_id=${f.id}, ${f.mime_type}, ${f.size}B) — gửi bởi ${await mm.displayName(p.user_id)} lúc ${fmtTime(p.create_at)}`);
      }
      return text(out.join("\n") || "Không có tệp đính kèm.");
    }
    case "chat_read_file": {
      const info = await mm.api<any>("GET", `/files/${a.file_id}/info`);
      if (a.channel) {
        const t = await target(a.channel);
        if (info.channel_id && info.channel_id !== t.id) return text(`Tệp này không thuộc "${t.level.name}".`);
      } else if (info.channel_id && info.channel_id !== CHANNEL) {
        // Không ghi channel: vẫn cho đọc nếu tệp thuộc một tầng trên (kiểm thành viên như khi ghi rõ).
        if (!(await chain()).some((l) => l.id === info.channel_id)) return text("Tệp này không thuộc nhóm hiện tại hay các tầng trên của nó.");
        await target(info.channel_id);
      }
      const r = await fetch(`${mm.url}/api/v4/files/${a.file_id}`, { headers: { Authorization: `Bearer ${process.env.MM_TOKEN}` } });
      if (!r.ok) return text(`Không tải được tệp: ${r.status}`);
      const buf = new Uint8Array(await r.arrayBuffer());
      const safe = String(info.name ?? a.file_id).replace(/[^\p{L}\p{N}._ -]/gu, "_");
      const path = `${WORKDIR}/attachments/${a.file_id}-${safe}`;
      await Bun.write(path, buf);
      const textual = /^text\/|json|xml|csv|javascript|typescript|yaml|x-sh|markdown/.test(info.mime_type ?? "") ||
        /\.(txt|md|csv|json|ya?ml|xml|html?|js|ts|py|go|rs|java|sql|log|ini|toml|sh|dart)$/i.test(info.name ?? "");
      const head = `Tệp ${info.name} (${info.mime_type}, ${info.size}B) đã lưu tại: ${path}`;
      if (textual && buf.length <= 300_000) return text(`${head}\n\n--- nội dung ---\n${new TextDecoder().decode(buf).slice(0, 100_000)}`);
      return text(`${head}\nĐây không phải tệp văn bản thuần (hoặc quá lớn) — hãy đọc tệp từ đường dẫn trên bằng công cụ phù hợp.`);
    }
    case "chat_send_files": {
      const { realpathSync, statSync } = await import("node:fs");
      const { resolve, basename, sep } = await import("node:path");
      const root = realpathSync(WORKDIR);
      const paths: string[] = Array.isArray(a.paths) ? a.paths.map(String) : [];
      if (!paths.length) return text("Chưa có tệp nào để gửi.");
      const cfg = await mm.api<any>("GET", "/config/client?format=old").catch(() => ({}));
      const maxSize = Number(cfg.MaxFileSize) || 100 * 1024 * 1024;
      const errors: string[] = [], ok: { id: string; name: string }[] = [], sentIds: string[] = [];
      for (const p of paths) {
        let real: string;
        try { real = realpathSync(resolve(WORKDIR, p)); } catch { errors.push(`${p}: không tồn tại`); continue; }
        if (real !== root && !real.startsWith(root + sep)) { errors.push(`${p}: nằm ngoài thư mục làm việc (${root}) — hãy chép vào thư mục làm việc rồi gửi`); continue; }
        const st = statSync(real);
        if (!st.isFile()) { errors.push(`${p}: không phải tệp`); continue; }
        if (st.size > maxSize) { errors.push(`${p}: ${st.size}B vượt giới hạn ${maxSize}B của server`); continue; }
        const form = new FormData();
        form.append("channel_id", CHANNEL);
        form.append("files", Bun.file(real), basename(real));
        const r = await fetch(`${mm.url}/api/v4/files`, { method: "POST", headers: { Authorization: `Bearer ${process.env.MM_TOKEN}` }, body: form });
        if (!r.ok) { errors.push(`${p}: tải lên lỗi ${r.status} ${(await r.text()).slice(0, 200)}`); continue; }
        const info = (await r.json()).file_infos?.[0];
        ok.push({ id: info.id, name: info.name });
      }
      if (ok.length) {
        // Gửi giống tin cuối của lượt: Sếp hỏi trong luồng không tích "gửi cả vào chat chính" -> chỉ trong luồng.
        let reply = "thread_broadcast";
        if (ROOT) {
          const posts = await mm.thread(ROOT);
          const lastOwner = [...posts].reverse().find((x) => x.user_id === OWNER_ID && !x.props?.flygo_agent_message);
          if (lastOwner?.root_id && lastOwner.props?.flygo_reply === "thread") reply = "thread";
        }
        for (let i = 0; i < ok.length; i += 10) {
          sentIds.push((await mm.createPost({
            channel_id: CHANNEL, root_id: ROOT, message: i === 0 ? String(a.message ?? "") : "",
            file_ids: ok.slice(i, i + 10).map((f) => f.id),
            props: { ...(ROOT ? { flygo_reply: reply } : {}), flygo_agent_owner: OWNER_ID, flygo_agent_files: true },
          })).id);
        }
      }
      return text([ok.length ? `Đã gửi ${ok.length} tệp vào nhóm: ${ok.map((f) => f.name).join(", ")} (tin ${sentIds.map((x) => `#${x}`).join(", ")}).` : "", errors.length ? `Không gửi được:\n- ${errors.join("\n- ")}` : ""].filter(Boolean).join("\n"));
    }
    case "chat_send_bilingual": {
      const code = (x: any) => String(x ?? "").trim().toLowerCase().split(/[-_]/)[0];
      const t0 = String(a.text ?? "").trim(), t1 = String(a.translation ?? "").trim(), l0 = code(a.lang), l1 = code(a.translation_lang);
      if (!t0 || !t1 || !/^[a-z]{2,3}$/.test(l0) || !/^[a-z]{2,3}$/.test(l1)) return text("Thiếu text / translation hoặc mã ngôn ngữ không hợp lệ (dùng mã ISO 639-1 như vi, en, ko).");
      if (l0 === l1) return text("Hai bản cùng một ngôn ngữ; gửi tin thường (viết trong câu trả lời) thay vì tin song ngữ.");
      // Như app (lib/api/translate.dart): nội dung = bản gốc + dòng kẻ + bản dịch, để app khác vẫn đọc được cả hai.
      let reply = "thread_broadcast";
      if (ROOT) {
        const posts = await mm.thread(ROOT);
        const lastOwner = [...posts].reverse().find((x) => x.user_id === OWNER_ID && !x.props?.flygo_agent_message);
        if (lastOwner?.root_id && lastOwner.props?.flygo_reply === "thread") reply = "thread";
      }
      const p = await mm.createPost({
        channel_id: CHANNEL, root_id: ROOT, message: `${t0}\n\n───\n${t1}`,
        props: { ...(ROOT ? { flygo_reply: reply } : {}), flygo_agent_owner: OWNER_ID, flygo_bilingual: { v: 1, langs: [l0, l1], texts: [t0, t1] } },
      });
      return text(`Đã gửi tin song ngữ ${l0}/${l1} (tin #${p.id}).`);
    }
    case "ask_user": {
      const qs = ((a.questions ?? []) as any[]).map((q, i) => ({ id: String(i), question: q.question, header: q.header, options: q.options ?? [], multi: !!q.multi }));
      const r = await runner("/ask", { questions: qs }).catch((e) => ({ cancelled: true, reason: String(e?.message ?? e) }));
      if (r.cancelled || !Array.isArray(r.answers)) return text(`Không có câu trả lời: ${r.reason || "người dùng huỷ"}. Đừng hỏi lại câu này; tự quyết theo hướng hợp lý nhất và nói rõ đã chọn gì.`);
      return text(qs.map((q, i) => { const x = r.answers[i] ?? {}; return `${q.question} → ${[...(x.choices ?? []), ...(x.other ? [x.other] : [])].join(", ") || "(không chọn)"}`; }).join("\n"));
    }
    case "approve": {
      let decision = { behavior: "deny", message: "Không có kênh duyệt." } as any;
      if (RUNNER && a.tool_name === "AskUserQuestion") { // dự phòng khi hook không chạy: hỏi như hook
        const qs = ((a.input?.questions ?? []) as any[]);
        const r = await runner("/ask", { questions: qs.map((q, i) => ({ id: String(i), question: q.question, header: q.header, options: q.options ?? [], multi: !!q.multiSelect })) })
          .catch((e) => ({ cancelled: true, reason: String(e?.message ?? e) }));
        if (r.cancelled || !Array.isArray(r.answers)) return text(JSON.stringify({ behavior: "deny", message: r.reason || "Người dùng không trả lời." }));
        const answers: Record<string, string> = {};
        qs.forEach((q, i) => { const x = r.answers[i]; if (x) answers[q.question] = [...(x.choices ?? []), ...(x.other ? [x.other] : [])].join(", "); });
        return text(JSON.stringify({ behavior: "allow", updatedInput: { ...a.input, answers } }));
      }
      if (RUNNER) {
        const r = await fetch(`${RUNNER}/approve`, {
          method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ key: RUN_KEY, tool_name: a.tool_name, input: a.input }),
        }).then((x) => x.json()).catch((e) => ({ allow: false, message: String(e) }));
        decision = r.allow ? { behavior: "allow", updatedInput: a.input } : { behavior: "deny", message: r.message || "Sếp không duyệt." };
      }
      return text(JSON.stringify(decision));
    }
  }
  throw new Error(`tool không tồn tại: ${req.params.name}`);
}

await server.connect(new StdioServerTransport());
}
