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
- **Luồng đã đóng** (app: tab "Luồng riêng", nút Đóng luồng): bot không nhận việc mới, kể cả khi được @tag hoặc thuộc trường hợp tự xử lý. Mở lại luồng thì bot nhận việc bình thường.
  - Luồng công việc (thread gốc R): app đăng một reply có `props.flygo_thread_closed` (`true` = đóng, `false` = mở lại). Tin mới nhất mang prop này quyết định trạng thái. Runner cache theo root; khi chưa có trong cache thì đọc `/posts/{R}/thread`.
  - Kênh luồng riêng `[flygo-sub …]`: đóng khi purpose có `[flygo-closed]`. Cache kênh được xoá khi có sự kiện `channel_updated` hoặc tin mốc ở chat chính kênh.
  - Khi tin mốc đóng tới (reply trong thread, hoặc tin ở chat chính kênh), lượt đang chạy trong luồng/kênh đó bị dừng như lệnh `dừng`. Tin mốc không bao giờ được coi là tin giao việc.
- Nhắn `dừng` trong chủ đề khi agent đang chạy để dừng lượt hiện tại.
- **Đổi tên bot (từ 0.4.1)**: chủ bot đổi username / tên hiển thị trên app (`PUT /bots/{id}`) thì runner nhận ngay, không cần chạy lại: sự kiện `user_updated` của bot (và đọc lại `/users/me` mỗi 60 giây) cập nhật tên và mẫu @nhắc, rồi phát sự kiện JSON `bot_renamed`. `props.flygo_agent_config` khớp theo username **hiện tại**; khoá bằng id bot cũng được.
- **Nút Dừng (từ 0.3.3)**: thả reaction `octagonal_sign` (🛑) lên post của lượt đang chạy (thẻ `props.flygo_agent`, ở chat chính là chính post trả lời; tin stream trong luồng cũng được) thì lượt đó dừng, giống nhắn `dừng`: huỷ engine, thôi chờ duyệt nếu đang chờ, thẻ chuyển `cancelled` và được chốt. Chỉ nhận từ người giao việc hoặc chủ bot. Chạy ở chat chính, trong luồng và kênh `[flygo-sub …]`. Runner **không gỡ** reaction 🛑 (bot không có quyền xoá reaction của người khác). Ở chat chính, post stream giữ nguyên khi dừng nên reaction còn đó; app nên ẩn chip 🛑 trên post có `flygo_agent`.
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

**Chọn model / mức suy nghĩ theo tin (từ 0.3.1).**
- Bot khai các lựa chọn trong mốc mô tả: `[flygo-agent engine=… allow=… models=a,b efforts=low,medium,high default=<model>:<effort>]`. Bot **không tự sửa được mô tả của mình** (`PUT /bots/{id}` bằng token bot trả 404, `PUT /users/me/patch` bị cấm), nên mốc do **chủ bot** ghi bằng token của chủ. Runner gửi lựa chọn hiệu lực trong sự kiện `ready.options` để app (đăng nhập bằng chủ bot) ghi mốc.
- Lựa chọn hiệu lực = cấu hình runner (`codex.model/models/effort/efforts`, `claude.model/models/effort/efforts`) ∪ `models=` / `efforts=` trong mốc. `default=model:mức` trong mốc đặt mặc định (vd. `default=gpt-5.6-sol:medium`, từ 0.3.6). Mặc định: codex [model ?? gpt-5.6-sol] × low,medium,high,xhigh, mức mặc định medium; claude opus,sonnet × low,medium,high,xhigh,max, mặc định opus:high.
- Tin giao việc mang `props.flygo_agent_config = { "<username bot>": { "model": "...", "effort": "..." } }`. Không có thì dùng mặc định. Giá trị ngoài danh sách thì dùng mặc định, và `flygo_agent.config.note` ghi lý do.
- Codex: truyền `model` và `effort` vào `turn/start`, lượt nào cũng truyền rõ vì giá trị ghi đè còn giữ cho các lượt sau. Claude: `--model` và `--effort`.
- Thẻ có `props.flygo_agent.config = { model, effort, note? }`. Sự kiện `run_started` cũng có `config`.

**0. Vị trí trả lời (từ 0.3.0): bot không tự tạo luồng.**
- Tin giao việc ở **chat chính** (`root_id` rỗng, kể cả tin đầu đã chép sang kênh luồng riêng `[flygo-sub …]`): bot trả lời **ngay ở chat chính** bằng **một post duy nhất**, không có `flygo_reply`. Post này mang cả `props.flygo_agent` (thẻ: trạng thái, bước) lẫn `props.flygo_agent_message` (`seq=1`). Chưa có chữ thì `message` là bản văn bản của thẻ; có chữ thì chữ được stream vào chính post đó, khoảng 0,5 giây sửa một lần. Agent có nhiều tin thì post hiện tin mới nhất. Kết thúc lượt: đăng lại thành post mới có `final=true`, rồi xoá post stream. Ở kênh không phải DM thì post mới có `@nhắc` thật người giao việc; trong DM thì không cần nhắc. Khi lỗi hoặc dừng, post giữ nguyên và chỉ chốt thẻ (`final=true`).
- **Từ 0.3.4, trong luồng cũng chỉ một post mỗi lượt**, cùng dạng với chat chính: `props.flygo_agent` + `flygo_agent_message` (+ `flygo_agent_approval` khi chờ duyệt), có thêm `flygo_reply="thread"`. Kết thúc thì đăng lại post `final=true` (@nhắc người giao việc ngoài DM; `flygo_reply="thread_broadcast"` nếu tin giao việc là reply không có `flygo_reply="thread"`), rồi xoá post stream. Không còn thẻ riêng và tin stream riêng.
- **"Mở luồng riêng" (`props.flygo_open_thread=true`, từ 0.3.4)**: tin ở chat chính có prop này thì bot trả lời **trong luồng dưới chính tin đó** (`root_id` = id tin, không broadcast). Các tin sau trong luồng là cuộc trò chuyện của luồng như thường. Quy tắc gọi bot giữ nguyên: nhóm nhiều người thì tin gốc vẫn phải @tag. ("Bí mật" vẫn là `flygo_private_thread` → kênh `[flygo-sub …]`.)
- Phiên ở chat chính tính **theo kênh**: các tin tiếp theo ở chat chính nói tiếp cùng phiên, prompt kèm các tin mới ở chat chính kể từ lần trước. Từ 0.4.0 **không tự mở phiên mới khi nghỉ lâu** (cấu hình `mainIdleHours`, mặc định 0 = tắt). Lệnh "dừng" ở chat chính dừng lượt của kênh.
- **Tổ chức phiên theo chat (từ 0.4.0)**: mỗi chat là một "dự án", chat chính là một phiên, mỗi luồng một phiên.
  - Thư mục làm việc: `workspaceRoot/<tên chat dạng slug>-<6 ký tự id kênh>` (DM: `chat-voi-<tên người>-…`). Thư mục kiểu cũ (`dm-<id>`, `<tên kênh>`) được đổi tên sang; đổi tên chat thì thư mục đổi theo. Claude: file phiên được chép sang thư mục dự án mới của `~/.claude/projects` để `--resume` vẫn chạy.
  - Kênh bí mật `[flygo-sub parent=…]` dùng thư mục (và section) của **chat cha**, phiên riêng.
  - Tên phiên: `<tên chat> · <dòng đầu tin gốc của luồng | Luồng chính | Bí mật · <tên kênh>>`. Codex: `thread/name/set` + section `Flygo · <tên chat>` (`threadSection/create`, `thread/section/move`; tắt bằng `codex.sections: false`). Claude: `--name`.
- **Gắn chat với thư mục code (từ 0.4.0)**: chỉ path nằm dưới `projectRoots` trong cấu hình runner (rỗng = tắt). Hai cách, đều chỉ chủ bot:
  - Mốc `[flygo-project path=~/dev/…]` trong mô tả kênh; chỉ có hiệu lực khi lần đổi mô tả gần nhất (tin hệ thống `system_purpose_change`) do chủ bot làm.
  - Lệnh `@bot dự án <path>` (gắn), `dự án bỏ` (gỡ), `dự án` (xem); lưu trong DB của runner. Mốc trong mô tả được ưu tiên.
  - Thư mục code: runner **không** ghi AGENTS.md/CLAUDE.md/skill vào; persona đi qua engine (Codex `developerInstructions`, Claude `--append-system-prompt`). Mọi luồng của chat chạy trong thư mục đó, mỗi luồng một phiên. Kênh bí mật theo gắn của chat cha.
- Tin giao việc **trong luồng** (`root_id` có giá trị): trả lời trong luồng đó như trước (mục 1, 2).
- **Duyệt ở chat chính (từ 0.3.2)**: không tạo post duyệt riêng. Lời xin duyệt nằm ngay trên post trả lời, ở `props.flygo_agent_approval = {kind, title, detail, status}` với status `pending` rồi `accepted`/`declined`/`expired`. Người dùng thả 👍/👎 lên chính post đó. Quyết xong thì bot gỡ reaction của bot, bỏ `flygo_agent_approval` khỏi post, và kết quả còn lại ở bước của thẻ.
- Duyệt trong luồng: vẫn là post riêng, nhưng **bị xoá khi đã quyết**, kết quả ghi ở bước của thẻ.
- Tin lỗi và tệp (`chat_send_files`) nằm cùng chỗ với câu trả lời. Ở chat chính thì không có `flygo_reply`.
- Ngữ cảnh khi nói tiếp: chỉ đưa các tin **sau lần trả lời gần nhất của bot**, ghi rõ là "chỉ để tham khảo". Tin có `flygo_private_thread` (việc đã chuyển sang luồng riêng) không bao giờ được đưa vào ngữ cảnh.
- Claude: lượt xong khi có `result`. Nếu sau đó `claude -p` im lặng quá 15 giây (đứng chờ lệnh nền) thì runner dừng cả cây tiến trình. Nếu còn lượt tiếp theo, ví dụ thông báo lệnh nền còn tồn khi resume, thì đọc tiếp và lấy `result` cuối.

**2. Tin nhắn của agent (trả lời trong luồng)**: mỗi tin là một post riêng, `props.flygo_agent_message = { run_id, engine, seq, streaming, final? }`. Nội dung (markdown) được sửa dần khi `streaming=true` (khoảng 0,5 giây một lần). Tin trung gian dùng `flygo_reply="thread"`. Khi lượt kết thúc, tin cuối được PATCH thành `flygo_reply="thread_broadcast"` và `final=true` để hiện ở cả chat chính, **trừ khi** tin giao việc là reply trong luồng có `flygo_reply="thread"` (hỏi trong luồng, không tích "Gửi cả vào chat chính"). Khi đó mọi tin, kể cả tin cuối, giữ `flygo_reply="thread"`. Tin gốc, reply có `thread_broadcast`, hay reply không có `flygo_reply` (client khác) thì tin cuối đều ra chat chính. Nếu agent không có tin nào, runner tạo một post kết quả theo đúng quy tắc trên.

**Không làm phiền**: mọi post của bot có `props.disable_group_highlight=true`, và mọi `@tên` / `@all` / `@channel` / `@here` ngoài phần code được chèn U+2060 sau dấu `@`, nên không nhắc ai cả.

**Chỉ báo cho người giao việc**: mọi post của bot (thẻ, tin, duyệt, lỗi) có `props.flygo_agent_owner = <user_id người giao việc>`. Khi kết thúc lượt, tin cuối được **đăng lại thành post mới** dạng `@<username người giao việc> <nội dung>`, với `@nhắc` thật (Mattermost chỉ gửi thông báo khi tạo post, không gửi khi sửa), và post đã stream bị xoá. Tin cuối luôn có `final=true`. Việc nó ra chat chính hay không do `flygo_reply` quyết định, theo quy tắc ở trên.

**3. Yêu cầu duyệt**: `props.flygo_reply = "thread"`, `props.flygo_agent_approval = { kind, title, detail, status: "pending" | "accepted" | "declined" | "expired" }`. App hiện nút **Xác nhận** / **Từ chối**: bấm nút thì gửi reaction `+1` hoặc `-1` lên post (`POST /reactions`). Runner chạy trên máy cá nhân, server không gọi vào được, nên dùng reaction làm kênh truyền. Runner chỉ nhận reaction của chủ bot. App nên ẩn chip reaction và dòng hướng dẫn trên các post này.

**4. Lỗi**: `flygo_reply="thread"`, message bắt đầu bằng "❌".

## Thành phần

| File | Vai trò |
|---|---|
| `src/runner.ts` | Nghe WebSocket Mattermost, chọn engine, dựng ngữ cảnh, quản lý phiên (SQLite `~/.config/flygo-agent/state.db`), duyệt quyền |
| `src/engines/codex.ts` | Nối `codex app-server` dùng chung qua `ws+unix://<socket>:/rpc`. Codex app nối cùng socket nên thấy các phiên realtime và chat tiếp được |
| `src/engines/claude.ts` | `claude -p --output-format stream-json`, `--resume` để nói tiếp. Không nạp settings cá nhân (`--setting-sources project,local`); quyền gồm `allowedTools` + `deny`, còn lại hỏi qua `--permission-prompt-tool`. `claude.fullAccess: true` thì chạy `bypassPermissions`: không hỏi duyệt, bỏ cả `deny` (chỉ bật khi chủ máy yêu cầu) |
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
