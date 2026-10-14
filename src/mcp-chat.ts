#!/usr/bin/env bun
// MCP server (stdio) cho một phiên agent. Phạm vi cố định theo env: chỉ đọc kênh CHANNEL_ID.
// Tools: chat_thread, chat_history, chat_search, approve (dùng cho --permission-prompt-tool của Claude).
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { MM, type Post } from "./mm";

const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`thiếu env ${k}`); return v; };
const mm = new MM(env("MM_URL"), env("MM_TOKEN"));
const CHANNEL = env("CHANNEL_ID");
const ROOT = process.env.ROOT_ID ?? "";
const RUNNER = process.env.RUNNER_URL ?? "";
const RUN_KEY = process.env.RUN_KEY ?? "";

const fmtTime = (ms: number) => new Date(ms).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour12: false });
async function fmt(posts: Post[]) {
  const out: string[] = [];
  for (const p of posts) {
    if (p.type && p.type.startsWith("system_")) continue;
    if (p.props?.flygo_agent || p.props?.flygo_agent_approval) continue; // thẻ tiến trình / yêu cầu duyệt của agent
    const name = await mm.displayName(p.user_id);
    const files = p.file_ids?.length ? ` [${p.file_ids.length} tệp đính kèm]` : "";
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
