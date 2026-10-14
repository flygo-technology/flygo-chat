# flygo-agent

Runner chạy **trên máy cá nhân**, nối bot Mattermost (Flygo Chat) với Codex / Claude Code.
Agent không chạy trên máy chủ: Hub không có, mọi lệnh chạy trên máy của chủ bot, bằng tài khoản Codex/Claude của người đó.

## Cách dùng trong chat

- `@<bot> <việc>`: giao việc bằng engine mặc định (`defaultEngine`, hiện là codex).
- `@<bot> claude <việc>` hoặc `@<bot> codex <việc>`: chọn engine cho phiên mới.
- Mỗi chủ đề (thread) là một phiên. Trả lời trong chủ đề đó (không cần @tag) để nói tiếp đúng phiên.
- Nhắn `dừng` trong chủ đề khi agent đang chạy để dừng lượt hiện tại.
- Chỉ người trong `ownerUserIds` được giao việc. Người khác @tag bot thì bot từ chối; tin của họ chỉ là ngữ cảnh.
- Khi agent cần quyền (lệnh ngoài sandbox, ghi file với Claude, MCP server lạ), bot gửi post "✋ Cần Sếp duyệt" trong chủ đề. Chủ bot thả 👍 để cho phép hoặc 👎 để từ chối. Hết hạn sau `approvalTimeoutSec` thì coi như từ chối.

## Lọc phiên AI

Thẻ tiến trình có hashtag trạng thái (Mattermost cập nhật chỉ mục hashtag khi post được sửa):

| Hashtag | Trạng thái |
|---|---|
| `#flygo_ai` | mọi phiên |
| `#ai_dang_lam` | đang suy nghĩ / đang làm |
| `#ai_cho_duyet` | chờ duyệt |
| `#ai_xong` | xong |
| `#ai_loi` | lỗi |
| `#ai_da_dung` | đã dừng |

Ví dụ: `#ai_dang_lam in:agent-test`, `#flygo_ai from:sep-ai` (API: `POST /teams/{team}/posts/search`).

## Giao thức hiển thị (cho app Flutter)

Mọi post của agent đều nằm trong chủ đề của tin giao việc (`root_id` = tin gốc) và theo quy ước `props.flygo_reply`.

**1. Thẻ tiến trình**: `props.flygo_reply = "thread"`, `props.flygo_agent`:

```jsonc
{
  "v": 1,
  "run_id": "uuid",
  "engine": "codex" | "claude",
  "title": "dòng đầu của việc được giao",
  "status": "thinking" | "running" | "awaiting_approval" | "done" | "error" | "cancelled",
  "session_id": "id thread Codex / session Claude",
  "started_at": 1791947702137, "ended_at": 1791947710882,  // ms
  "steps": [                                               // tối đa 40 bước gần nhất; Mattermost có thể trả null khi rỗng
    { "id": "…", "kind": "command" | "file" | "tool" | "search" | "message" | "thinking" | "approval" | "other",
      "title": "$ ls -la", "status": "running" | "done" | "error" | "waiting",
      "detail": "output (≤600 ký tự)", "started_at": 0, "ended_at": 0 }
  ],
  "usage": { /* token, cost_usd (claude) */ },
  "error": "thông báo lỗi nếu status=error"
}
```

Post này được sửa liên tục (cách nhau ít nhất 0,8 giây), nên app nhận sự kiện `post_edited`. Phần `message` là bản văn bản dự phòng (markdown, kèm hashtag) cho client không đọc props.

**2. Tin nhắn của agent**: mỗi tin là một post riêng, `props.flygo_agent_message = { run_id, engine, seq, streaming, final? }`. Nội dung (markdown) được sửa dần khi `streaming=true` (khoảng 0,5 giây một lần). Tin trung gian dùng `flygo_reply="thread"`. Khi lượt kết thúc, tin cuối được PATCH thành `flygo_reply="thread_broadcast"` và `final=true`, nên hiện ở cả chat chính. Nếu agent không có tin nào, runner tạo một post broadcast với nội dung kết quả.

**3. Yêu cầu duyệt**: `props.flygo_reply = "thread"`, `props.flygo_agent_approval = { kind, title, detail, status: "pending" | "accepted" | "declined" | "expired" }`. App hiện nút **Xác nhận** / **Từ chối**: bấm nút thì gửi reaction `+1` hoặc `-1` lên post (`POST /reactions`). Runner chạy trên máy cá nhân, server không gọi vào được, nên dùng reaction làm kênh truyền. Runner chỉ nhận reaction của chủ bot. App nên ẩn chip reaction và dòng hướng dẫn trên các post này.

**4. Lỗi**: `flygo_reply="thread"`, message bắt đầu bằng "❌".

## Thành phần

| File | Vai trò |
|---|---|
| `src/runner.ts` | Nghe WebSocket Mattermost, chọn engine, dựng ngữ cảnh, quản lý phiên (SQLite `~/.config/flygo-agent/state.db`), duyệt quyền |
| `src/engines/codex.ts` | Nối `codex app-server` dùng chung qua `ws+unix://<socket>:/rpc`. Codex app nối cùng socket nên thấy các phiên realtime và chat tiếp được |
| `src/engines/claude.ts` | `claude -p --output-format stream-json`, `--resume` để nói tiếp. Không nạp settings cá nhân (`--setting-sources project,local`); quyền gồm `allowedTools` + `deny`, còn lại hỏi qua `--permission-prompt-tool` |
| `src/mcp-chat.ts` | MCP server của mỗi phiên, chỉ đọc kênh của phiên: `chat_thread`, `chat_history`, `chat_search`, `chat_info` (nhóm và thành viên), `chat_files`, `chat_read_file` (tải tệp đính kèm về `attachments/`, trả nội dung nếu là tệp văn bản); thêm `approve` (cho Claude) |
| `src/messages.ts` | Stream tin nhắn của agent thành các post riêng |
| `src/codex-shared.ts` | Giữ app-server dùng chung và bộ chuyển tiếp TCP luôn chạy |
| `src/card.ts` | Thẻ tiến trình |
| `profiles/<tên>/persona.md` | Hướng dẫn hệ thống (xưng em/Sếp…). Ghi vào AGENTS.md/CLAUDE.md của thư mục làm việc |
| `profiles/<tên>/skills/` | Skill riêng (định dạng SKILL.md), chép vào `.claude/skills` và `.agents/skills` của thư mục làm việc |

Thư mục làm việc: `~/flygo-agent/workspaces/<tên kênh>/`.

## Cài đặt trên một máy

1. Cài bun, Codex CLI và/hoặc Claude Code; đăng nhập cả hai.
2. Tạo bot cá nhân (trang "Quản lý bot" trong app hoặc `POST /api/v4/bots`), lấy token, thêm bot vào nhóm cần dùng.
3. `~/.config/flygo-agent/config.json` (chmod 600), xem `config.example.json`.
4. `bun install`, sau đó cài 3 LaunchAgent trong `~/Library/LaunchAgents/`:
   - `vn.flygo.agent.codex-shared`: `bun src/codex-shared.ts` (KeepAlive)
   - `vn.flygo.agent.runner`: `bun src/runner.ts` (KeepAlive)
   - `vn.flygo.agent.codex-env`: `launchctl setenv CODEX_APP_SERVER_WS_URL ws+unix://localhost$HOME/.codex/flygo-shared.sock:/rpc`. Codex app mở **sau** đó sẽ dùng app-server chung. Đây là cách không chính thức, có thể hỏng khi ChatGPT.app cập nhật.

   Log nằm ở `~/Library/Logs/flygo-agent/`.
5. macOS: binary `codex` và `node` cần quyền Local Network mới gọi được IP LAN. Nếu chưa cấp, dùng `forwards` (bun chuyển tiếp) và `codex.spawnArgs` trỏ `openai_base_url` về `127.0.0.1`.

Vận hành:
```
launchctl kickstart -k gui/$(id -u)/vn.flygo.agent.runner     # khởi động lại runner
launchctl bootout gui/$(id -u)/vn.flygo.agent.runner          # tắt
tail -f ~/Library/Logs/flygo-agent/runner.log
```

## Hạn chế đã biết

- Codex: lệnh mạng (`curl`) vẫn chạy được dù sandbox ghi `network_access: false` (lệnh chạy qua "code mode"). Ghi file ngoài thư mục làm việc thì bị chặn và phải xin duyệt.
- MCP server `flygo_chat` dùng token của bot. Agent chạy cùng user hệ điều hành nên về lý thuyết đọc được env của tiến trình. Chấp nhận được với bot cá nhân trên máy cá nhân; không dùng bot có quyền rộng.
- Claude chạy chế độ `-p` (mỗi lượt một tiến trình), chưa gắn vào phiên Claude Code đang mở trên terminal. Chế độ "attach" qua channels đã thử thành công nhưng chưa đưa vào runner.
