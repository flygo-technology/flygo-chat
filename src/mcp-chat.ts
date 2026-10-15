// MCP server (stdio) cho một phiên agent. Phạm vi cố định theo env: chỉ đọc kênh CHANNEL_ID.
// Tools: chat_thread, chat_history, chat_search, approve (dùng cho --permission-prompt-tool của Claude).
// Kênh bí mật lồng nhau: các tool đọc nhận thêm `channel` ("parent" / "top" / số tầng / id kênh) để ĐỌC các tầng trên
// (chỉ tổ tiên của kênh hiện tại, bot phải là thành viên); không đọc kênh anh em / kênh con, không ghi lên trên.
// A2A: A2A_ROLE=orchestrator -> thêm list_agents / ask_agent; A2A_ROLE=callee (đang làm việc được agent khác nhờ)
// -> chỉ approve + return_files (không đọc/gửi chat, không nhờ tiếp agent khác).
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { ancestorChain, type Level } from "./chain";
import { MM, type Post } from "./mm";

export async function runMcpChat() {
const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`thiếu env ${k}`); return v; };
const mm = new MM(env("MM_URL"), env("MM_TOKEN"));
const A2A_ROLE = process.env.A2A_ROLE ?? "";
const CHANNEL = A2A_ROLE === "callee" ? "" : env("CHANNEL_ID");
const ROOT = process.env.ROOT_ID ?? "";
const RUNNER = process.env.RUNNER_URL ?? "";
const RUN_KEY = process.env.RUN_KEY ?? "";
const WORKDIR = process.env.WORKDIR ?? process.cwd();
const OWNER_ID = process.env.OWNER_ID ?? "";
const REPORT_OUT = process.env.REPORT_OUT === "1"; // lượt trong luồng / kênh bí mật: được gửi báo cáo ra nhóm ngoài

const fmtTime = (ms: number) => new Date(ms).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false });
async function fmt(posts: Post[]) {
  const out: string[] = [];
  for (const p of posts) {
    if (p.type && p.type.startsWith("system_")) continue;
    // Bỏ thẻ tiến trình / yêu cầu duyệt / tin đang stream; giữ câu trả lời (post có cả thẻ lẫn chữ: flygo_agent_message).
    const msg = p.props?.flygo_agent_message;
    if (msg ? msg.streaming : p.props?.flygo_agent || p.props?.flygo_agent_approval) continue;
    if (!p.message?.trim() && !p.file_ids?.length) continue;
    const name = await mm.displayName(p.user_id);
    const fl = (p as any).metadata?.files as any[] | undefined;
    const files = fl?.length ? ` [tệp: ${fl.map((f) => `${f.name} (id=${f.id}, ${f.mime_type}, ${f.size}B)`).join("; ")}]` : p.file_ids?.length ? ` [tệp id: ${p.file_ids.join(", ")}]` : "";
    const where = p.root_id ? ` (trả lời trong chủ đề ${p.root_id})` : "";
    out.push(`[${fmtTime(p.create_at)}] ${name}${where} #${p.id}: ${p.message}${files}`);
  }
  return out.join("\n") || "(không có tin nào)";
}
const text = (s: string) => ({ content: [{ type: "text", text: s }] });

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
    : low === "top" || low === "root" || low === "gốc" || low === "goc" ? c[0]
    : /^\d+$/.test(s) ? c[Number(s)]
    : c.find((l) => l.id === s);
  if (!level) {
    if (n === 0) throw new Error(`channel=${s}: nhóm hiện tại không phải luồng bí mật, không có tầng trên.`);
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
const CHANNEL_ARG = { type: "string", description: "tuỳ chọn, chỉ trong luồng bí mật: đọc tầng trên — \"parent\" (tầng cha), \"top\" (nhóm gốc), số tầng (0 = nhóm gốc) hoặc id kênh tổ tiên. Bỏ trống = kênh hiện tại" };

const server = new Server(
  { name: "flygo_chat", version: "0.1.0" },
  { capabilities: { tools: {} }, instructions: "Đọc tin nhắn của kênh Flygo Chat nơi Sếp giao việc. Đọc được kênh hiện tại; trong luồng bí mật đọc thêm được các tầng trên (tham số channel, xem chat_ancestors), chỉ đọc." },
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
    description: "Nhờ một agent AI khác (vd. @ba-codex) làm việc qua A2A rồi chờ kết quả. Agent đó làm bằng quyền và máy của nó, không thấy nhóm chat: hãy gửi đủ ngữ cảnh. Dùng khi tin nhắn tag nhiều agent và bạn là agent chủ trì. Giới hạn số lần gọi mỗi lượt. Tệp gửi kèm phải nằm trong thư mục làm việc; tệp agent trả về được lưu vào thư mục làm việc.",
    inputSchema: {
      type: "object",
      properties: {
        bot: { type: "string", description: "username agent, vd. ba-codex" },
        message: { type: "string", description: "việc nhờ, viết đủ ngữ cảnh" },
        files: { type: "array", items: { type: "string" }, description: "đường dẫn tệp gửi kèm (tuỳ chọn)" },
        data: { type: "object", description: "dữ liệu có cấu trúc gửi kèm (tuỳ chọn)" },
      },
      required: ["bot", "message"],
    },
  },
];
const REPORT_TOOL = {
  name: "chat_report_out",
  description: "Gửi báo cáo từ luồng hiện tại ra chat chính của nhóm ngoài (luồng mở: chat chính của nhóm; luồng bí mật: nhóm cha). CHỈ dùng khi người giao việc yêu cầu báo cáo ra ngoài hoặc đã dặn trước là xong thì báo. Luồng bí mật: người giao việc phải duyệt đúng nội dung này trước khi gửi (chờ tối đa 30 phút). Tệp kèm phải nằm trong thư mục làm việc.",
  inputSchema: {
    type: "object",
    properties: {
      message: { type: "string", description: "nội dung báo cáo, viết cho người ngoài luồng đọc hiểu được; KHÔNG viết dòng tiêu đề \"Báo cáo từ luồng…\" (tự thêm)" },
      files: { type: "array", items: { type: "string" }, description: "đường dẫn tệp gửi kèm (tuỳ chọn, tối đa 10)" },
    },
    required: ["message"],
  },
};
const CALLEE_TOOLS = [
  {
    name: "return_files",
    description: "Gửi tệp kết quả về cho agent đã nhờ bạn (A2A). Tệp phải nằm trong thư mục làm việc.",
    inputSchema: { type: "object", properties: { paths: { type: "array", items: { type: "string" } } }, required: ["paths"] },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: A2A_ROLE === "callee" ? [...CALLEE_TOOLS, APPROVE_TOOL] : [...(A2A_ROLE === "orchestrator" ? A2A_TOOLS : []), ...CHAT_TOOLS, REPORT_TOOL, APPROVE_TOOL] // luôn cùng danh sách tool (phiên tách từ chat chính trúng prompt cache); report_out tự báo khi không dùng được,
}));
const CHAT_TOOLS = [
    {
      name: "chat_thread",
      description: "Đọc toàn bộ một chủ đề (thread) trong kênh hiện tại (hoặc tầng trên với channel). Mặc định là chủ đề đang làm việc; ở tầng trên mặc định là chủ đề của tin gốc mà luồng bí mật tách ra.",
      inputSchema: { type: "object", properties: { root_id: { type: "string", description: "id tin gốc; bỏ trống = chủ đề hiện tại" }, channel: CHANNEL_ARG } },
    },
    {
      name: "chat_history",
      description: "Đọc tin nhắn gần nhất của kênh hiện tại hoặc tầng trên (cũ hơn before_post_id nếu có). Tối đa 100 tin/lần.",
      inputSchema: { type: "object", properties: { limit: { type: "number" }, before_post_id: { type: "string" }, channel: CHANNEL_ARG } },
    },
    {
      name: "chat_search",
      description: "Tìm tin nhắn trong kênh hiện tại (hoặc tầng trên với channel) theo từ khoá (cú pháp tìm kiếm Mattermost).",
      inputSchema: { type: "object", properties: { terms: { type: "string" }, channel: CHANNEL_ARG }, required: ["terms"] },
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
      name: "chat_send_files",
      description: "GỬI tệp vào chủ đề hiện tại của nhóm (ảnh, video, ghi âm, pdf, office, tệp bất kỳ). Dùng tool này mỗi khi tạo hoặc tải được tệp cho Sếp, KHÔNG dán đường dẫn trên máy vào tin nhắn. Tệp phải nằm trong thư mục làm việc. Ghi âm nên là m4a/mp3/ogg, ảnh png/jpg, video mp4 để app hiển thị/phát được.",
      inputSchema: { type: "object", properties: { paths: { type: "array", items: { type: "string" }, description: "đường dẫn tệp (tuyệt đối hoặc tương đối với thư mục làm việc)" }, message: { type: "string", description: "lời nhắn kèm (tuỳ chọn)" } }, required: ["paths"] },
    },
];
const APPROVE_TOOL = {
  name: "approve",
  description: "Nội bộ: xin Sếp duyệt quyền dùng công cụ. Không tự gọi.",
  inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } }, required: ["tool_name", "input"] },
};

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  try { return await callTool(req); } catch (e: any) {
    if (/^channel=|^Bot không phải thành viên/.test(e?.message ?? "")) return text(e.message); // lỗi phạm vi đọc: trả rõ cho agent
    throw e;
  }
});
async function callTool(req: any): Promise<any> {
  const a = (req.params.arguments ?? {}) as any;
  if (A2A_ROLE === "callee" && !["return_files", "approve"].includes(req.params.name)) throw new Error(`tool không dùng được khi làm việc được nhờ: ${req.params.name}`);
  switch (req.params.name) {
    case "list_agents": case "ask_agent": case "return_files": {
      if (req.params.name !== "return_files" && A2A_ROLE !== "orchestrator") throw new Error("A2A không bật cho phiên này");
      const r = await runner(`/a2a/${req.params.name}`, a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "chat_report_out": {
      if (!REPORT_OUT) return text("chat_report_out chỉ dùng được trong luồng hoặc luồng bí mật; ở chat chính cứ trả lời bình thường.");
      const r = await runner("/report_out", a).catch((e) => ({ text: `Lỗi: ${e.message ?? e}` }));
      return text(r.text ?? JSON.stringify(r));
    }
    case "chat_ancestors": {
      const c = await chain();
      const n = c.length - 1;
      if (!n) return text(`Nhóm hiện tại không phải luồng bí mật: chỉ một tầng, "${c[0].name}" (id ${c[0].id}).`);
      return text([`Luồng bí mật tầng ${n}:`, ...c.map((l) => `- Tầng ${l.tier}${l.tier === 0 ? " (nhóm gốc)" : l.tier === n - 1 ? " (cha)" : ""}${l.tier === n ? " (đang ở đây)" : ""}: "${l.name}" — id ${l.id}${l.rootId ? `; tách từ tin ${l.rootId}: ${l.rootText.slice(0, 500)}` : ""}`)].join("\n"));
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
      const errors: string[] = [], ok: { id: string; name: string }[] = [];
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
          await mm.createPost({
            channel_id: CHANNEL, root_id: ROOT, message: i === 0 ? String(a.message ?? "") : "",
            file_ids: ok.slice(i, i + 10).map((f) => f.id),
            props: { ...(ROOT ? { flygo_reply: reply } : {}), flygo_agent_owner: OWNER_ID, flygo_agent_files: true },
          });
        }
      }
      return text([ok.length ? `Đã gửi ${ok.length} tệp vào nhóm: ${ok.map((f) => f.name).join(", ")}.` : "", errors.length ? `Không gửi được:\n- ${errors.join("\n- ")}` : ""].filter(Boolean).join("\n"));
    }
    case "approve": {
      let decision = { behavior: "deny", message: "Không có kênh duyệt." } as any;
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
