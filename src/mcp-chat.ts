// MCP server (stdio) cho một phiên agent. Phạm vi cố định theo env: chỉ đọc kênh CHANNEL_ID.
// Tools: chat_thread, chat_history, chat_search, approve (dùng cho --permission-prompt-tool của Claude).
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { MM, type Post } from "./mm";

export async function runMcpChat() {
const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`thiếu env ${k}`); return v; };
const mm = new MM(env("MM_URL"), env("MM_TOKEN"));
const CHANNEL = env("CHANNEL_ID");
const ROOT = process.env.ROOT_ID ?? "";
const RUNNER = process.env.RUNNER_URL ?? "";
const RUN_KEY = process.env.RUN_KEY ?? "";
const WORKDIR = process.env.WORKDIR ?? process.cwd();
const OWNER_ID = process.env.OWNER_ID ?? "";

const fmtTime = (ms: number) => new Date(ms).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false });
async function fmt(posts: Post[]) {
  const out: string[] = [];
  for (const p of posts) {
    if (p.type && p.type.startsWith("system_")) continue;
    if (p.props?.flygo_agent || p.props?.flygo_agent_approval) continue; // thẻ tiến trình / yêu cầu duyệt của agent
    const name = await mm.displayName(p.user_id);
    const fl = (p as any).metadata?.files as any[] | undefined;
    const files = fl?.length ? ` [tệp: ${fl.map((f) => `${f.name} (id=${f.id}, ${f.mime_type}, ${f.size}B)`).join("; ")}]` : p.file_ids?.length ? ` [tệp id: ${p.file_ids.join(", ")}]` : "";
    const where = p.root_id ? ` (trả lời trong chủ đề ${p.root_id})` : "";
    out.push(`[${fmtTime(p.create_at)}] ${name}${where} #${p.id}: ${p.message}${files}`);
  }
  return out.join("\n") || "(không có tin nào)";
}
const text = (s: string) => ({ content: [{ type: "text", text: s }] });

const server = new Server(
  { name: "flygo_chat", version: "0.1.0" },
  { capabilities: { tools: {} }, instructions: "Đọc tin nhắn của kênh Flygo Chat nơi Sếp giao việc. Chỉ đọc được kênh hiện tại." },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "chat_thread",
      description: "Đọc toàn bộ một chủ đề (thread) trong kênh hiện tại. Mặc định là chủ đề đang làm việc.",
      inputSchema: { type: "object", properties: { root_id: { type: "string", description: "id tin gốc; bỏ trống = chủ đề hiện tại" } } },
    },
    {
      name: "chat_history",
      description: "Đọc tin nhắn gần nhất của kênh hiện tại (cũ hơn before_post_id nếu có). Tối đa 100 tin/lần.",
      inputSchema: { type: "object", properties: { limit: { type: "number" }, before_post_id: { type: "string" } } },
    },
    {
      name: "chat_search",
      description: "Tìm tin nhắn trong kênh hiện tại theo từ khoá (cú pháp tìm kiếm Mattermost).",
      inputSchema: { type: "object", properties: { terms: { type: "string" } }, required: ["terms"] },
    },
    {
      name: "chat_info",
      description: "Thông tin nhóm chat hiện tại: tên, mô tả, loại, danh sách thành viên (tên, chức danh, quản trị nhóm, bot).",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "chat_files",
      description: "Liệt kê tệp đính kèm trong chủ đề hiện tại (hoặc root_id), hoặc trong N tin gần nhất của nhóm nếu scope=channel.",
      inputSchema: { type: "object", properties: { scope: { type: "string", enum: ["thread", "channel"] }, root_id: { type: "string" }, limit: { type: "number" } } },
    },
    {
      name: "chat_read_file",
      description: "Tải một tệp đính kèm (theo file_id) về thư mục làm việc. Tệp văn bản (txt, md, csv, json, code…) trả luôn nội dung; tệp khác (pdf, ảnh, office) trả đường dẫn đã lưu để đọc bằng công cụ khác.",
      inputSchema: { type: "object", properties: { file_id: { type: "string" } }, required: ["file_id"] },
    },
    {
      name: "chat_send_files",
      description: "GỬI tệp vào chủ đề hiện tại của nhóm (ảnh, video, ghi âm, pdf, office, tệp bất kỳ). Dùng tool này mỗi khi tạo hoặc tải được tệp cho Sếp, KHÔNG dán đường dẫn trên máy vào tin nhắn. Tệp phải nằm trong thư mục làm việc. Ghi âm nên là m4a/mp3/ogg, ảnh png/jpg, video mp4 để app hiển thị/phát được.",
      inputSchema: { type: "object", properties: { paths: { type: "array", items: { type: "string" }, description: "đường dẫn tệp (tuyệt đối hoặc tương đối với thư mục làm việc)" }, message: { type: "string", description: "lời nhắn kèm (tuỳ chọn)" } }, required: ["paths"] },
    },
    {
      name: "approve",
      description: "Nội bộ: xin Sếp duyệt quyền dùng công cụ. Không tự gọi.",
      inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } }, required: ["tool_name", "input"] },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const a = (req.params.arguments ?? {}) as any;
  switch (req.params.name) {
    case "chat_thread": {
      const root = a.root_id || ROOT;
      if (!root) return text("Không có chủ đề hiện tại.");
      const posts = await mm.thread(root);
      if (posts[0] && posts[0].channel_id !== CHANNEL) return text("Chủ đề này không thuộc kênh hiện tại.");
      return text(await fmt(posts));
    }
    case "chat_history": {
      const limit = Math.min(Math.max(Number(a.limit) || 30, 1), 100);
      return text(await fmt(await mm.channelPosts(CHANNEL, limit, a.before_post_id || undefined)));
    }
    case "chat_search": {
      const ch = await mm.channel(CHANNEL);
      const r = await mm.api<any>("POST", `/teams/${ch.team_id}/posts/search`, { terms: String(a.terms), is_or_search: false, per_page: 60 });
      const posts = (r.order as string[]).map((id) => r.posts[id] as Post).filter((p) => p.channel_id === CHANNEL).sort((x, y) => x.create_at - y.create_at);
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
      const posts = a.scope === "channel" ? await mm.channelPosts(CHANNEL, Math.min(Number(a.limit) || 100, 200)) : await mm.thread(a.root_id || ROOT);
      const out: string[] = [];
      for (const p of posts) {
        if (p.channel_id !== CHANNEL) continue;
        for (const f of ((p as any).metadata?.files ?? []) as any[]) out.push(`- ${f.name} (file_id=${f.id}, ${f.mime_type}, ${f.size}B) — gửi bởi ${await mm.displayName(p.user_id)} lúc ${fmtTime(p.create_at)}`);
      }
      return text(out.join("\n") || "Không có tệp đính kèm.");
    }
    case "chat_read_file": {
      const info = await mm.api<any>("GET", `/files/${a.file_id}/info`);
      if (info.channel_id && info.channel_id !== CHANNEL) return text("Tệp này không thuộc nhóm hiện tại.");
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
            props: { flygo_reply: reply, flygo_agent_owner: OWNER_ID, flygo_agent_files: true },
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
});

await server.connect(new StdioServerTransport());
}
