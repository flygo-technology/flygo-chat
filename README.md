# flygo-agent

Runner chạy **trên máy cá nhân**, nối bot Mattermost (Flygo Chat) với Codex / Claude Code.
Agent không chạy trên máy chủ: Hub không có, mọi lệnh chạy trên máy của chủ bot, bằng tài khoản Codex/Claude của người đó.

## Cách dùng trong chat

- `@<bot> <việc>`: giao việc. **Mỗi bot gắn cố định một engine** (`engine` trong cấu hình, mốc `[flygo-agent engine=codex|claude]` trong mô tả bot): bot Codex chỉ chạy Codex, bot Claude chỉ chạy Claude, không đổi được theo tin nhắn. Muốn dùng cả hai thì tạo hai bot.
- Mỗi chủ đề (thread) là một phiên.
- **Khi nào không cần @tag**: ở đâu chỉ có đúng **1 người** (người gửi, phải là chủ bot) và **1 bot** (bot này) thì mọi tin của người đó giao luôn cho bot. Từ 2 người hoặc từ 2 bot trở lên thì phải @tag. Thứ tự xét:
  - DM với bot: luôn tự xử lý.
  - Thành viên kênh (nhóm, kênh luồng riêng `[flygo-sub …]`): đúng 1 người + bot này thì tự xử lý mọi tin, kể cả tin gốc.
  - Tin trong thread: người tham gia gồm người đã đăng trong thread (kể cả tin gốc) và các bot đã trả lời hoặc được @tag trong thread. Chỉ có người gửi + bot này thì tự xử lý.
  - Còn lại (tin gốc ở chat chính nhóm đông người, thread nhiều người hoặc nhiều bot): phải @tag.
  - **Không bao giờ** trả lời tin có `props.flygo_private_thread=true`, tức tin "Bắt đầu công việc trong luồng riêng tư" ở chat chính. Bot chỉ làm việc trong kênh luồng riêng mà app tạo ra, nơi có bản chép kèm @tag.
  - Danh sách người tham gia thread được cache và cập nhật theo WebSocket. Thành viên kênh cache 60 giây, làm mới khi có `user_added` / `user_removed`.
- Nhắn `dừng` trong chủ đề khi agent đang chạy để dừng lượt hiện tại.
- **Ai được gọi bot**: chủ bot (`ownerUserIds` trong cấu hình) cùng những người có trong `allow=` của mốc trong mô tả bot, ví dụ `[flygo-agent engine=codex allow=<user_id1>,<user_id2>]`. Chủ bot sửa mô tả qua `PUT /api/v4/bots/{id}`. Runner đọc lại `bot_description` từ `GET /users/me` mỗi 60 giây và khi có sự kiện `user_updated` của bot. Người được phép gọi thì lượt đó **người giao việc = người gửi**: `flygo_agent_owner` là người gửi và tin cuối @nhắc người gửi. Duyệt và lệnh "dừng" nhận từ người giao việc hoặc chủ bot. Người ngoài danh sách @tag bot thì bot từ chối; tin của họ chỉ là ngữ cảnh.
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

**2. Tin nhắn của agent**: mỗi tin là một post riêng, `props.flygo_agent_message = { run_id, engine, seq, streaming, final? }`. Nội dung (markdown) được sửa dần khi `streaming=true` (khoảng 0,5 giây một lần). Tin trung gian dùng `flygo_reply="thread"`. Khi lượt kết thúc, tin cuối được PATCH thành `flygo_reply="thread_broadcast"` và `final=true` để hiện ở cả chat chính, **trừ khi** tin giao việc là reply trong luồng có `flygo_reply="thread"` (hỏi trong luồng, không tích "Gửi cả vào chat chính"). Khi đó mọi tin, kể cả tin cuối, giữ `flygo_reply="thread"`. Tin gốc, reply có `thread_broadcast`, hay reply không có `flygo_reply` (client khác) thì tin cuối đều ra chat chính. Nếu agent không có tin nào, runner tạo một post kết quả theo đúng quy tắc trên.

**Không làm phiền**: mọi post của bot có `props.disable_group_highlight=true`, và mọi `@tên` / `@all` / `@channel` / `@here` ngoài phần code được chèn U+2060 sau dấu `@`, nên không nhắc ai cả.

**Chỉ báo cho người giao việc**: mọi post của bot (thẻ, tin, duyệt, lỗi) có `props.flygo_agent_owner = <user_id người giao việc>`. Khi kết thúc lượt, tin cuối được **đăng lại thành post mới** dạng `@<username người giao việc> <nội dung>`, với `@nhắc` thật (Mattermost chỉ gửi thông báo khi tạo post, không gửi khi sửa), và post đã stream bị xoá. Tin cuối luôn có `final=true`. Việc nó ra chat chính hay không do `flygo_reply` quyết định, theo quy tắc ở trên.

**3. Yêu cầu duyệt**: `props.flygo_reply = "thread"`, `props.flygo_agent_approval = { kind, title, detail, status: "pending" | "accepted" | "declined" | "expired" }`. App hiện nút **Xác nhận** / **Từ chối**: bấm nút thì gửi reaction `+1` hoặc `-1` lên post (`POST /reactions`). Runner chạy trên máy cá nhân, server không gọi vào được, nên dùng reaction làm kênh truyền. Runner chỉ nhận reaction của chủ bot. App nên ẩn chip reaction và dòng hướng dẫn trên các post này.

**4. Lỗi**: `flygo_reply="thread"`, message bắt đầu bằng "❌".

## Thành phần

| File | Vai trò |
|---|---|
| `src/runner.ts` | Nghe WebSocket Mattermost, chọn engine, dựng ngữ cảnh, quản lý phiên (SQLite `~/.config/flygo-agent/state.db`), duyệt quyền |
| `src/engines/codex.ts` | Nối `codex app-server` dùng chung qua `ws+unix://<socket>:/rpc`. Codex app nối cùng socket nên thấy các phiên realtime và chat tiếp được |
| `src/engines/claude.ts` | `claude -p --output-format stream-json`, `--resume` để nói tiếp. Không nạp settings cá nhân (`--setting-sources project,local`); quyền gồm `allowedTools` + `deny`, còn lại hỏi qua `--permission-prompt-tool` |
| `src/mcp-chat.ts` | MCP server của mỗi phiên, chỉ đọc kênh của phiên: `chat_thread`, `chat_history`, `chat_search`, `chat_info` (nhóm và thành viên), `chat_files`, `chat_read_file` (tải tệp đính kèm về `attachments/`, trả nội dung nếu là tệp văn bản), `chat_send_files` (gửi tệp trong thư mục làm việc vào luồng, tối đa 10 tệp mỗi post, giới hạn theo `MaxFileSize` của server, post mang `props.flygo_agent_files=true` và `flygo_reply` giống tin cuối của lượt); thêm `approve` (cho Claude) |
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

## Windows

- File chạy `dist/flygo-agent-windows-x64.exe` (build kèm `--windows-hide-console`, chạy nền không hiện cửa sổ). **Chưa thử trên máy Windows thật.**
- Codex mặc định dùng `codex.transport = "stdio"`: runner tự chạy `codex app-server` riêng, không dùng chung với Codex app.
- Đường dẫn codex: runner tìm trong PATH, `%APPDATA%\\npm`, `%LOCALAPPDATA%\\Programs\\codex`. Cài qua npm thì là `codex.cmd`; nếu không chạy được, đặt `codex.bin` trỏ thẳng tới `codex.exe` (thường nằm trong `%APPDATA%\\npm\\node_modules\\@openai\\codex\\…\\codex.exe`). Claude: `claude.bin`.
- `openai_base_url` (nếu dùng proxy): sửa `%USERPROFILE%\\.codex\\config.toml`, hoặc trong cấu hình runner `codex.spawnArgs: ["-c", "openai_base_url=\"http://…/v1\""]`.
- Codex xác thực qua provider (`model_provider` có `experimental_bearer_token`, hoặc `env_key` với biến đã đặt, hoặc `OPENAI_API_KEY`) cũng được tính là đã đăng nhập, dù `codex login status` báo chưa. Muốn bỏ hẳn bước kiểm tra thì đặt `codex.skipLoginCheck: true`.
- MCP server nào của Codex lỗi khi chạy dưới service thì tắt bằng `codex.spawnArgs`, ví dụ `["-c", "mcp_servers.mattermost.required=false"]`.
- Sandbox `workspace-write` của Codex trên Windows còn thử nghiệm. Nếu lệnh lỗi vì sandbox, cân nhắc `codex.sandbox`.
- Dịch vụ nền: `install-service --config <file>` tạo task `FlygoAgent-<bot>` (ONLOGON, chỉ chạy khi người dùng đã đăng nhập). Log ở `%LOCALAPPDATA%\\flygo-agent\\logs\\runner-<bot>.log` (`--log`).
- Windows không có SIGTERM: khi tắt máy hoặc kill, bot không kịp về offline; custom status tự hết hạn sau 10 phút. Khoá chạy một runner kiểm theo pid.

## Hạn chế đã biết

- Codex: lệnh mạng (`curl`) vẫn chạy được dù sandbox ghi `network_access: false` (lệnh chạy qua "code mode"). Ghi file ngoài thư mục làm việc thì bị chặn và phải xin duyệt.
- MCP server `flygo_chat` dùng token của bot. Agent chạy cùng user hệ điều hành nên về lý thuyết đọc được env của tiến trình. Chấp nhận được với bot cá nhân trên máy cá nhân; không dùng bot có quyền rộng.
- Claude chạy chế độ `-p` (mỗi lượt một tiến trình), chưa gắn vào phiên Claude Code đang mở trên terminal. Chế độ "attach" qua channels đã thử thành công nhưng chưa đưa vào runner.

## Tích hợp vào app Flygo Chat (bản máy tính)

File chạy: `dist/flygo-agent-{darwin-arm64,darwin-x64,linux-x64,linux-arm64,windows-x64.exe}` (build: `bun scripts/build.ts`). Bản phát hành: `https://chat.flygo.vn/static/plugins/flygo-agent/<tên file>`, kèm `version.json` (version, sha256 từng file). Server lưu ở `/srv/apps/mattermost/client-plugins/flygo-agent/`.

1. **Kiểm tra máy**: `flygo-agent doctor --json` trả về `{codex:{installed,loggedIn,version,account}, claude:{…}, platform, hostname}`. Chưa đăng nhập thì chạy `codex login` / `claude auth login` (cả hai đều mở trình duyệt).
2. **Bot của tôi**:
   - Tìm bot đã có: `GET /api/v4/bots?per_page=200`, lọc `owner_id == me` và `description` chứa `[flygo-agent]`.
   - Chưa có thì tạo: `POST /api/v4/bots {username: "<username>-ai", display_name: "Trợ lý của <tên>", description: "… [flygo-agent engine=codex]"}`. Khi tạo, người dùng chọn Codex hoặc Claude (không có lựa chọn tự động). User thường có sẵn quyền `create_bot`.
   - Token: `POST /api/v4/users/<bot_id>/tokens {description: "flygo-agent <hostname>"}`, lưu trong secure storage, mỗi máy một token.
3. **Chạy trong app**: `flygo-agent run --config-stdin --json [--takeover]`.
   - Ghi JSON cấu hình vào stdin rồi đóng stdin: `{"serverUrl","botToken","ownerUserIds":[me.id],"engine":"codex"|"claude"}`.
   - Stdout là các sự kiện JSON, mỗi dòng một sự kiện:
     - `connected`
     - `ready {bot, engine, doctor}`
     - `run_started {run_id, channel_id, root_id, engine, title}`
     - `run_finished {run_id, root_id, status}`
     - `took_over {pid}`
     - `stopped`
     - `error {code: auth | no_engine | already_running | fatal, message}`
   - Log đi ra stderr. Thoát app thì gửi SIGTERM: runner dừng các lượt đang chạy, đưa bot về offline rồi thoát.
   - Gặp `already_running` (đang có dịch vụ nền hoặc app khác chạy cùng bot) thì hỏi người dùng, rồi chạy lại với `--takeover`. Runner sẽ dừng runner cũ và tắt dịch vụ nền.
4. **Chạy nền khi đăng nhập máy** (tuỳ chọn):
   - Chép file chạy ra chỗ cố định (`~/.local/share/flygo-agent/flygo-agent`). **Khi cập nhật phải chép ra file tạm rồi `mv` đè** (đổi inode). `cp` đè lên file đang chạy thì macOS sẽ giết tiến trình (chữ ký mã hỏng).
   - Ghi cấu hình ra `~/.config/flygo-agent/config-<bot username>.json` (chmod 600). Mỗi file cấu hình là một dịch vụ riêng (`vn.flygo.agent.runner.<bot>`), log ở `runner-<bot>.log`.
   - Chạy `flygo-agent install-service --config <file>`. Gỡ bằng `uninstall-service --config <file>`, xem trạng thái bằng `service-status --config <file>`.
5. **Trạng thái trên mọi thiết bị**: khi đang chạy, bot có status `online` và custom status 🟢 "Đang chạy trên <máy> · codex, claude". Custom status hết hạn sau 10 phút và được làm mới mỗi 5 phút, nên runner chết đột ngột thì tự mất.
6. **Thêm trợ lý vào nhóm**: `POST /api/v4/channels/<id>/members {user_id: <bot_id>}`.

**macOS: App Sandbox.** Bản macOS đang bật `com.apple.security.app-sandbox`. Tiến trình con kế thừa sandbox, nên runner sẽ không đọc được `~/.codex`, `~/.claude` và không chạy được `codex`/`claude`. Có hai cách:
- (a) Tắt sandbox. App phân phối ngoài Mac App Store nên vẫn notarize được. Lưu ý dữ liệu đang nằm ở `~/Library/Containers/vn.flygo.chat`, cần chuyển sang chỗ mới.
- (b) Giữ sandbox, app chỉ cài dịch vụ nền một lần qua lệnh người dùng chạy trong Terminal, sau đó điều khiển và theo dõi qua trạng thái của bot.
