# flygo-agent

Runner chạy **trên máy cá nhân**, nối bot của máy chủ chat (Flygo Chat) với Codex / Claude Code.
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
- **Bot gắn cứng một máy (từ 0.4.2)**: mốc `[flygo-agent … host=<máy>]` (app đặt khi bật "Chạy trên máy này"). So sánh theo `normHost`: chữ thường, bỏ đuôi `.local`, khoảng trắng và `]` thành `-`. Runner khởi động trên máy khác thì phát `{event:"error", code:"bound_elsewhere", host}` và **thoát mã 0** (launchd `SuccessfulExit=false` / systemd `Restart=on-failure` không chạy lại). Đang chạy mà mốc đổi sang máy khác (`user_updated` hoặc đọc lại mỗi 60 giây) thì dừng êm. Mốc chưa có host: runner thử tự ghi (máy chủ chat thường cấm bot sửa mô tả của mình), không được thì phát `{event:"unbound", host}` và vẫn chạy. Bỏ `--takeover`: runner khác đang giữ bot thì luôn báo `already_running`.
- **Bot bị tắt/xoá (từ 0.4.3)**: token bị từ chối (401) lúc khởi động thì phát `{event:"error", code:"auth_revoked"}` và thoát mã 0 (dịch vụ nền không chạy lại); đang chạy thì phát hiện trong lần đọc `/users/me` kế tiếp (≤ 60 giây) và dừng êm. Lỗi mạng vẫn thoát lỗi để dịch vụ nền thử lại.
- **Đổi tên bot (từ 0.4.1)**: chủ bot đổi username / tên hiển thị trên app (`PUT /bots/{id}`) thì runner nhận ngay, không cần chạy lại: sự kiện `user_updated` của bot (và đọc lại `/users/me` mỗi 60 giây) cập nhật tên và mẫu @nhắc, rồi phát sự kiện JSON `bot_renamed`. `props.flygo_agent_config` khớp theo username **hiện tại**; khoá bằng id bot cũng được.
- **Nút Dừng (từ 0.3.3)**: thả reaction `octagonal_sign` (🛑) lên post của lượt đang chạy (thẻ `props.flygo_agent`, ở chat chính là chính post trả lời; tin stream trong luồng cũng được) thì lượt đó dừng, giống nhắn `dừng`: huỷ engine, thôi chờ duyệt nếu đang chờ, thẻ chuyển `cancelled` và được chốt. Chỉ nhận từ người giao việc hoặc chủ bot. Chạy ở chat chính, trong luồng và kênh `[flygo-sub …]`. Runner **không gỡ** reaction 🛑 (bot không có quyền xoá reaction của người khác). Ở chat chính, post stream giữ nguyên khi dừng nên reaction còn đó; app nên ẩn chip 🛑 trên post có `flygo_agent`.
- **Ai được gọi bot**: chủ bot (`ownerUserIds` trong cấu hình) cùng những người có trong `allow=` của mốc trong mô tả bot, ví dụ `[flygo-agent engine=codex allow=<user_id1>,<user_id2>]`. Chủ bot sửa mô tả qua `PUT /api/v4/bots/{id}`. Runner đọc lại `bot_description` từ `GET /users/me` mỗi 60 giây và khi có sự kiện `user_updated` của bot. Người được phép gọi thì lượt đó **người giao việc = người gửi**: `flygo_agent_owner` là người gửi và tin cuối @nhắc người gửi. Duyệt và lệnh "dừng" nhận từ người giao việc hoặc chủ bot. Người ngoài danh sách @tag bot thì bot từ chối; tin của họ chỉ là ngữ cảnh.
- Khi agent cần quyền (lệnh ngoài sandbox, ghi file với Claude, MCP server lạ), bot gửi post "✋ Cần Sếp duyệt" trong chủ đề. Chủ bot thả 👍 để cho phép hoặc 👎 để từ chối. Hết hạn sau `approvalTimeoutSec` thì coi như từ chối.

## Lọc phiên AI

Thẻ tiến trình có hashtag trạng thái (máy chủ chat cập nhật chỉ mục hashtag khi post được sửa):

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
  "steps": [                                               // tối đa 40 bước gần nhất; máy chủ chat có thể trả null khi rỗng
    { "id": "…", "kind": "command" | "file" | "tool" | "search" | "message" | "thinking" | "approval" | "other",
      "title": "$ ls -la", "label": "Liệt kê thư mục",       // label: từ 0.6.24, mô tả ngắn việc của bước
      "status": "running" | "done" | "error" | "waiting",
      "detail": "output (≤600 ký tự)", "started_at": 0, "ended_at": 0,
      "seg": 0 }                                           // từ 0.6.19: số đoạn chữ đã bắt đầu trước bước này
  ],
  "texts": ["đoạn 1", "đoạn 2"],                           // từ 0.6.19: mọi đoạn chữ agent viết trong lượt (≤40 đoạn × 4000 ký tự)
  "usage": { /* token, cost_usd (claude) */ },
  "error": "thông báo lỗi nếu status=error"
}
```

**Đoạn chữ xen bước (từ 0.6.19).**
- `texts`: các đoạn chữ của agent theo thứ tự (Codex: mỗi item agentMessage; Claude: mỗi tin assistant có chữ). Đoạn đang stream được cập nhật tại chỗ. Đoạn cuối chính là câu trả lời cuối (`message` của post final).
- Mỗi bước có `seg`. App dựng theo thứ tự: [bước seg=0] texts[0] [bước seg=1] texts[1] … Bước có `seg = texts.length` đứng sau đoạn cuối.
- Quá 40 đoạn thì các đoạn đầu gộp thành `"…"` (là texts[0]), và `seg` được đánh lại tương ứng.
- Thiếu `texts` / `seg` (runner cũ): hiện như trước.

**Nhãn bước (từ 0.6.24).** Mỗi bước có `label`: mô tả ngắn (khoảng 3–8 chữ, ≤60 ký tự) việc của bước, để app hiện kiểu "Đã chạy <label>" thay cho câu lệnh. `title` / `detail` giữ như cũ; bước lỗi vẫn `status: "error"`. Thiếu `label` (runner cũ) thì app dùng `title`.
- Claude: Bash lấy `description` của tool (thiếu thì rút gọn lệnh như Codex). Read "Đọc <file>", Edit/MultiEdit "Sửa <file>", Write "Tạo <file>", Grep/Glob "Tìm <pattern>", WebFetch "Mở <host>", WebSearch "Tìm web <query>", Task/Agent lấy `description`, MCP "<server> · <tool>".
- Codex: commandExecution rút gọn lệnh: bỏ vỏ shell (zsh/bash -lc, powershell -Command, cmd /c) và `cd … &&`, lấy lệnh đầu của pipe. Lệnh đọc (cat/head/tail/sed -n/Get-Content) thành "Đọc <file>", lệnh tìm (rg/grep/Select-String) thành "Tìm <pattern> trong <file>", lệnh liệt kê (ls/dir/Get-ChildItem) thành "Liệt kê <thư mục>", còn lại là chương trình + tham số. fileChange "Sửa <file>" ("Tạo" nếu toàn file mới), mcpToolCall "<server> · <tool>", webSearch "Tìm web <query>".
- Bước runner tự ghi (duyệt, A2A, báo cáo…): `label` = `title` rút gọn.

Post này được sửa liên tục (cách nhau ít nhất 0,8 giây), nên app nhận sự kiện `post_edited`. Phần `message` là bản văn bản dự phòng (markdown, kèm hashtag) cho client không đọc props.

**Chọn model / mức suy nghĩ theo tin (từ 0.3.1).**
- Bot khai các lựa chọn trong mốc mô tả: `[flygo-agent engine=… allow=… models=a,b efforts=low,medium,high default=<model>:<effort>]`. Bot **không tự sửa được mô tả của mình** (`PUT /bots/{id}` bằng token bot trả 404, `PUT /users/me/patch` bị cấm), nên mốc do **chủ bot** ghi bằng token của chủ. Runner gửi lựa chọn hiệu lực trong sự kiện `ready.options` để app (đăng nhập bằng chủ bot) ghi mốc.
- Lựa chọn hiệu lực = cấu hình runner (`codex.model/models/effort/efforts`, `claude.model/models/effort/efforts`) ∪ `models=` / `efforts=` trong mốc. `default=model:mức` trong mốc đặt mặc định (vd. `default=gpt-5.6-terra:medium`, từ 0.3.6). Mặc định: codex [model ?? gpt-5.6-terra] × low,medium,high,xhigh, mức mặc định medium; claude opus,sonnet × low,medium,high,xhigh,max, mặc định opus:high.
- Tin giao việc mang `props.flygo_agent_config = { "<username bot>": { "model": "...", "effort": "..." } }`. Không có thì dùng mặc định. Giá trị ngoài danh sách thì dùng mặc định, và `flygo_agent.config.note` ghi lý do.
- Codex: truyền `model` và `effort` vào `turn/start`, lượt nào cũng truyền rõ vì giá trị ghi đè còn giữ cho các lượt sau. Claude: `--model` và `--effort`.
- Thẻ có `props.flygo_agent.config = { model, effort, note? }`. Sự kiện `run_started` cũng có `config`.
- Codex, model bị upstream từ chối ("not supported", từ 0.6.22): model người dùng chọn bị từ chối thì lượt tự chạy lại bằng model mặc định của bot, thẻ có bước "Mô hình X không dùng được, chuyển sang Y". Runner nhớ model đó 30 phút và các lượt sau đi thẳng sang mặc định. Nếu thread cũ vướng model cũ bị từ chối (Codex nén lịch sử bằng model cũ của thread) thì mở thread mới (từ 0.6.21). Hai cách cứu này nối nhau được theo cả hai thứ tự, mỗi cách tối đa một lần mỗi lượt (từ 0.6.23).
- Thứ tự `models=` trong mốc và `props.flygo_models` (từ 0.6.22): model mặc định, rồi các model trong `codex.models` / `claude.models` của cấu hình, rồi phần còn lại theo thứ tự engine báo.

**0. Vị trí trả lời (từ 0.3.0): bot không tự tạo luồng.**
- Tin giao việc ở **chat chính** (`root_id` rỗng, kể cả tin đầu đã chép sang kênh luồng riêng `[flygo-sub …]`): bot trả lời **ngay ở chat chính** bằng **một post duy nhất**, không có `flygo_reply`. Post này mang cả `props.flygo_agent` (thẻ: trạng thái, bước) lẫn `props.flygo_agent_message` (`seq=1`). Chưa có chữ thì `message` là bản văn bản của thẻ; có chữ thì chữ được stream vào chính post đó, khoảng 0,5 giây sửa một lần. Agent có nhiều tin thì post hiện tin mới nhất. Kết thúc lượt: đăng lại thành post mới có `final=true`, rồi xoá post stream. Ở kênh không phải DM thì post mới có `@nhắc` thật người giao việc; trong DM thì không cần nhắc. Khi lỗi hoặc dừng, post giữ nguyên và chỉ chốt thẻ (`final=true`).
- **Từ 0.3.4, trong luồng cũng chỉ một post mỗi lượt**, cùng dạng với chat chính: `props.flygo_agent` + `flygo_agent_message` (+ `flygo_agent_approval` khi chờ duyệt), có thêm `flygo_reply="thread"`. Kết thúc thì đăng lại post `final=true` (@nhắc người giao việc ngoài DM; `flygo_reply="thread_broadcast"` nếu tin giao việc là reply không có `flygo_reply="thread"`), rồi xoá post stream. Không còn thẻ riêng và tin stream riêng.
- **Trả lời trích dẫn ở chat chính (từ 0.4.4)**: tin có `root_id` = tin được trích và `props.flygo_reply="quote"` được coi là tin **chat chính**: phiên chat chính, trả lời một post ở chat chính (`root_id` rỗng), typing `parent_id` rỗng; nội dung tin được trích kèm vào prompt. App cũ (không gửi `flygo_reply`): cũng coi là trích dẫn nếu tin gốc là câu trả lời ở chat chính của chính bot (có `flygo_agent`) và chưa có luồng (chỉ có tin này).
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

**Chỉ báo cho người giao việc**: mọi post của bot (thẻ, tin, duyệt, lỗi) có `props.flygo_agent_owner = <user_id người giao việc>`. Khi kết thúc lượt, tin cuối được **đăng lại thành post mới** dạng `@<username người giao việc> <nội dung>`, với `@nhắc` thật (máy chủ chat chỉ gửi thông báo khi tạo post, không gửi khi sửa), và post đã stream bị xoá. Tin cuối luôn có `final=true`. Việc nó ra chat chính hay không do `flygo_reply` quyết định, theo quy tắc ở trên.

**3. Yêu cầu duyệt**: `props.flygo_reply = "thread"`, `props.flygo_agent_approval = { kind, title, detail, status: "pending" | "accepted" | "declined" | "expired" }`. App hiện nút **Xác nhận** / **Từ chối**: bấm nút thì gửi reaction `+1` hoặc `-1` lên post (`POST /reactions`). Runner chạy trên máy cá nhân, server không gọi vào được, nên dùng reaction làm kênh truyền. Runner chỉ nhận reaction của chủ bot. App nên ẩn chip reaction và dòng hướng dẫn trên các post này.

**4. Lỗi**: `flygo_reply="thread"`, message bắt đầu bằng "❌".

## Nhiều agent cùng làm (A2A, từ 0.5.0)

Tin nhắn @tag từ 2 agent trở lên (bot có mốc `[flygo-agent …]`): agent được tag **đầu tiên** là agent chủ trì. Chỉ agent này trả lời trong chat. Các agent còn lại không trả lời tin đó; chúng chỉ làm khi agent chủ trì nhờ qua giao thức [A2A](https://a2a-protocol.org) (Agent2Agent).

- **Relay**: `https://push.<tên miền>/a2a/…`, nằm trong trạm push của máy chủ chat (`/opt/flygo-push/a2a.mjs`, mã nguồn ở `relay/a2a.mjs` trong repo này).
  - Mỗi runner giữ một WebSocket ra `wss://push.<tên miền>/a2a/connect`, xác thực bằng token bot và header `X-MM-Server`. Relay kiểm token qua `/api/v4/users/me`, rồi dùng token quản trị (`push-watcher`) để đọc chủ bot.
  - Server chưa có token quản trị trong cấu hình relay (hiện là chat.example.com) thì chưa dùng được A2A.
- **Quyền** (relay kiểm): hai bot cùng chủ; hoặc chủ của bên gọi nằm trong `allow=` của bot được gọi. Bot ở server khác chỉ gọi được khi email chủ trùng nhau. Chủ trong `blockedOwners` bị chặn cả hai chiều (hiện có một người dùng).
- **Độ sâu 1**: agent đang làm việc được nhờ thì không nhờ tiếp agent khác. Relay kiểm điều này, và tool nhờ agent cũng bị ẩn với agent đó.
- **Agent Card**:
  - Runner gửi card khi nối, relay chuẩn hoá rồi **ký** (JWS EdDSA, `kid=flygo-a2a-1`). Khoá công khai ở `/a2a/.well-known/jwks.json`.
  - Card có `url = <a2a.publicBase>/agents/<bot_id>`, `provider = a2a.providerName (mặc định Flygo Chat)`, extension `urn:flygo-chat:a2a-ext:agent-options:v1` (engine, models, efforts, default, host) và `x-flygo` (bot, chủ).
- **JSON-RPC**: `message/send`, `message/stream` (SSE), `tasks/get`, `tasks/cancel`; nhận cả tên v1.0 `SendMessage` / `SendStreamingMessage` / `GetTask` / `CancelTask`.
  - Message, Task, Artifact và các phần `text` / `data` / `file` theo đặc tả A2A.
  - Client A2A ngoài cũng gọi được: `GET /a2a/agents/<bot_id>/.well-known/agent-card.json`, `POST /a2a/agents/<bot_id>`, kèm `Authorization: Bearer <token máy chủ chat>` và `X-MM-Server`.
- **Agent chủ trì**: phiên có thêm tool `list_agents` và `ask_agent(bot, message, files?, data?)` (MCP `flygo_chat`).
  - Mỗi lượt nhờ tối đa `a2a.maxCalls` lần (mặc định 5), mỗi lần chờ tối đa `a2a.timeoutSec` (mặc định 900 giây). Dừng lượt thì huỷ cả cuộc gọi.
  - Cùng luồng chat và cùng agent thì dùng cùng `contextId`, nên agent kia nhớ các lần nhờ trước trong luồng.
  - Thẻ của lượt có bước `Hỏi @x: …` (kind `tool`, `detail` = việc nhờ, có tiến độ) và bước `@x trả lời: …` (kind `message`, `detail` = câu trả lời, tối đa 4000 ký tự).
  - Không có tin nhắn riêng nào trong chat cho cuộc trao đổi A2A.
- **Agent được nhờ**:
  - Làm trong phiên riêng `a2a:<bot gọi>:<contextId>`, thư mục `workspaces/a2a-<bot gọi>-<id>`.
  - Dùng engine, model mặc định và **quyền của chính nó**. Cần duyệt thì gửi lời xin duyệt vào **DM giữa bot và chủ bot** (👍/👎), quyết xong thì xoá.
  - Không đọc hay gửi chat. Muốn gửi tệp kết quả thì dùng tool `return_files`.
  - Kết quả trả về: artifact `answer` (text) và một artifact cho mỗi tệp.
- **Tệp**:
  - Từ 5 MB trở xuống: gửi `bytes` base64 ngay trong message.
  - Lớn hơn (tối đa 100 MB): tải lên máy chủ chat bằng upload session (mỗi khúc 8 MB), rồi xin relay `grant` → `uri = <a2a.publicBase>/files/<id>`. URI hết hạn sau 30 phút và chỉ bot được chỉ định tải được.
  - Tệp lớn của agent chủ trì tải vào kênh đang chat; tệp lớn của agent được nhờ tải vào DM với chủ bot. Tệp tải lên không gắn vào tin nào nên không hiện trong chat.
  - Tệp nhận được lưu ở `a2a-nhan/…` trong thư mục làm việc. Agent chủ trì gửi tệp vào nhóm bằng `chat_send_files` khi cần.
- **Cấu hình runner**: `a2a: { enabled: true, relay: "", maxCalls: 5, timeoutSec: 900 }` (relay rỗng = `wss://push.<tên miền của serverUrl>/a2a/connect`). Relay từ chối (4401/4403) thì runner thử lại thưa dần 1 phút → 2 → 4 … tối đa 6 giờ (nối được thì đếm lại). Lỗi tạm thời khi relay kiểm token (máy chủ chat timeout / 5xx / mạng) relay đóng bằng 1013 chứ không 4401, runner nối lại theo backoff thường (2 s → 60 s).

## Báo cáo ra ngoài (từ 0.5.3)

Lượt chạy trong luồng (luồng mở trong nhóm, hoặc kênh bí mật `[flygo-sub parent=… root=…]`) có thêm ngữ cảnh "Nhóm ngoài" (tên/id nhóm, tin gốc) và tool MCP `chat_report_out(message, files?, lang?, translation?, translation_lang?)`. Agent chỉ dùng khi người giao việc yêu cầu báo cáo ra ngoài. Kèm `lang` + `translation` + `translation_lang` thì báo cáo là tin song ngữ (từ 0.6.52, xem [Tin song ngữ](#tin-song-ngữ-và-dịch-ai-từ-0650)).

- Gửi thành tin mới ở chat chính (root_id rỗng) của nhóm ngoài: đúng nội dung agent viết (từ 0.6.20 không còn dòng tiêu đề `📋 Báo cáo từ …`; nguồn nằm ở props share), kèm tệp (tối đa 10, trong thư mục làm việc).
- Props: luồng mở `flygo_thread_share: {root_id, post_id}`; kênh bí mật `flygo_sub_report: {channel_id: <kênh bí mật>, post_id: <tin giao việc>}`; thêm `flygo_agent_report: true`.
- Từ 0.6.27 mọi nơi (luồng mở, kênh bí mật, chat AI riêng) đều gửi thẳng, không còn bước duyệt (trước đó kênh bí mật / chat AI xin duyệt bằng `flygo_agent_approval.kind = "report"`).
- Thẻ có bước "Báo cáo ra ngoài → <nhóm> (đã gửi)" (hoặc "(lỗi)"). Tối đa 3 báo cáo mỗi lượt.

Chat AI riêng (cột phải) cũng gửi được `chat_report_out` ngay từ chat chính của nó, vào chat chính của nhóm gắn. Nếu bot không phải thành viên nhóm gắn (nhóm riêng tư đã có trợ lý khác), từ 0.6.26 tool vẫn có mặt nhưng trả lý do rõ ràng (bot không ở nhóm; chủ tự gửi nội dung hoặc thêm bot vào nhóm) thay cho câu "chỉ dùng được trong luồng".

## Sửa / thu hồi tin của chính bot (từ 0.6.29)

Tool MCP `chat_edit_message(post_id, message)` và `chat_recall_message(post_id, reason?)`: agent sửa (PUT /posts/{id}/patch, chỉ `message`, giữ props và tệp) hoặc thu hồi (DELETE) tin do CHÍNH bot đó gửi, khi gửi nhầm chỗ, sai số liệu, hoặc người dùng bảo sửa / thu hồi.
- Từ chối: tin của người khác / bot khác; lời xin duyệt; tin đang stream hoặc thuộc lượt đang chạy; thẻ tiến trình chưa có câu trả lời. Câu trả lời đã xong của lượt trước (thẻ + chữ chung một post) thì sửa / thu hồi được.
- Người giao việc không phải chủ bot: chỉ tin trong kênh hiện tại. Chủ bot: tin của bot ở mọi kênh.
- Không cần duyệt. Thẻ ghi bước "Đã sửa tin: …" / "Đã thu hồi tin: …" (label "Sửa tin đã gửi" / "Thu hồi tin đã gửi"); thu hồi tin gốc của luồng có trả lời thì bước có ⚠️ và label "Thu hồi tin gốc của luồng".
- post_id: `#id` trong chat_history / chat_thread / chat_search; `chat_send_files` và `chat_report_out` trả kèm `#id` tin vừa gửi.

## Tin song ngữ và Dịch AI (từ 0.6.50)

Tin song ngữ là tin có bản gốc và bản dịch. App hiện phần theo ngôn ngữ của người đọc (không có thì bản gốc), kèm nút hai lá cờ ở đầu tin để đổi giữa bản gốc và bản dịch AI.

- Định dạng: `message` = bản gốc + `\n\n───\n` + bản dịch (app khác vẫn đọc được cả hai); `props.flygo_bilingual = {v: 1, langs: [gốc, dịch], texts: [bản gốc, bản dịch]}`, mã ngôn ngữ ISO 639-1 (`vi`, `en`, `ko`, `ja`, `th`, `zh`…). App đọc bằng `bilingualOf` trong `lib/api/translate.dart`.

**Nút "Dịch AI" của app.** Chỉ hiện trên máy tính có Claude Code hoặc Codex CLI (`machineHasAiCli` tìm trong PATH và các chỗ cài thường gặp); điện thoại không có nút. Chọn ngôn ngữ đích ở nút cạnh nút gửi; lựa chọn giữ cho từng chat tới khi chọn "Không dịch" (gõ `...` cuối câu để bật nhanh). Bấm gửi thì tin hiện ngay như tin đang gửi (`_translate` = ngôn ngữ đích, nhãn cờ + "Đang dịch…" và khung xương), app dịch rồi mới gửi tin song ngữ. Dịch lỗi thì tin chuyển sang lỗi, gửi lại sẽ dịch lại.

**Dịch bằng trợ lý của chính người gửi** (từ 0.6.53). Không bao giờ dùng bot của người khác.
1. App máy tính gọi thẳng runner trên cùng máy: runner ghi `~/.config/flygo-agent/local-<bot id>.json` (`{port, key, server, owners, engine, bot}`, quyền 0600, xoá khi dừng) và mở `POST http://127.0.0.1:<port>/translate {text, to, user}` với header `x-flygo-key`. App chọn runner cùng máy chủ, mình là chủ, Claude trước Codex. Tin không rời máy.
2. Không có runner trên máy (hoặc lỗi): trạm dịch `relay/translate.mjs` (`POST https://push.<máy chủ>/translate {text, to}` → `{text, from, to, engine}`, xác thực bằng token máy chủ chat + `X-MM-Server`, giới hạn `perUserDaily`, cache trong bộ nhớ, không log nội dung), theo thứ tự: API Claude nếu có khoá (`translate.anthropicKeyFile`, `translate.model`); bot của chính người dịch đang trực tuyến (cùng máy chủ, `who.owner`, có `card.capabilities.flygoTranslate`, Claude trước): trạm gửi `{t: "translate", cid, text, to, user: {id}}` qua WebSocket A2A, runner trả `{t: "translate_res", cid, result: {ok, text, from}}`; cuối cùng Google Dịch miễn phí (hai đường, đường đầu hay bị 429).

Runner chỉ dịch cho chủ bot (`isOwner`). Claude: `claude -p --model sonnet`, không công cụ, không MCP, không lưu phiên, tin qua stdin trong `<message>…</message>` (~3 giây; Haiku hay trả lại nguyên văn nên không dùng). Codex: `codex exec --ephemeral -s read-only`, mức suy nghĩ thấp (~10–20 giây do mỗi lần khởi động codex). Tối đa 3 lượt cùng lúc. Bản dịch trùng bản gốc (bỏ hoa thường, dấu câu) bị coi là lỗi.

**Agent gửi tin song ngữ.** Agent tự dịch rồi gửi đủ hai bản:
- `chat_send_bilingual(text, lang, translation, translation_lang)`: gửi vào chỗ đang ở (chat, luồng, chat AI riêng), `flygo_reply` giống tin cuối của lượt. Trả `#id` tin vừa gửi.
- Đang ở chat AI riêng hoặc luồng mà cần gửi song ngữ ra nhóm: `chat_report_out` kèm `lang`, `translation`, `translation_lang` (thêm `flygo_bilingual` vào props của báo cáo).
- Cả hai không cần duyệt (`chat_send_bilingual` có trong `allowedTools` mặc định).

## Hỏi phiên khác (từ 0.6.56; hỏi thẳng qua CLI, không hiện trên app từ 0.6.57)

Chỉ chủ bot dùng được (runner kiểm tra người giao việc là chủ).

**Phiên AI khác của chính bot** (chat AI riêng / phiên trong dự án của cùng chủ, kênh có mốc `[flygo-ai group=… owner=<chủ>]`):
- `session_list()`: các phiên (tên, nhóm gắn, tin cuối, đang chạy).
- `session_read(session_id, limit?)`: tin gần đây của phiên đó.
- `session_ask(session_id, message, wait_sec?)`: KHÔNG đăng gì lên app. Runner chạy `claude -p --resume <session_id engine của phiên đích>` trong thư mục làm việc của phiên đó (chỉ tool đọc: Read, Grep, Glob, LS; không MCP), xếp hàng cùng các lượt chat của phiên đó (`enqueue` cùng khoá), rồi trả câu trả lời về phiên hỏi. Phiên đích nhớ là đã được hỏi (nằm trong phiên engine), nhưng chat của nó trên app không hiện gì. Phiên chạy bằng Codex: chưa hỏi thẳng được (dùng session_read).

**Phiên Claude Code trên cùng máy với runner** (`~/.claude/sessions/*.json`, tiến trình còn sống):
- `cc_list()`: tên, trạng thái (idle / busy), thư mục.
- `cc_read(name, limit?)`: lịch sử gần đây (tệp `~/.claude/projects/<thư mục>/<sessionId>.jsonl`; phiên chạy `--resume` thì lấy tệp mới ghi gần nhất trong thư mục đó).
- `cc_ask(name, message, wait_sec?)`: hỏi trên một bản sao của phiên: `claude -p --resume <sessionId> --fork-session --no-session-persistence --setting-sources ""` (chỉ tool đọc, không nạp quyền của dự án đích). Phiên gốc không nhận tin, không hiện gì và lịch sử không đổi. Không cần duyệt.

## Luôn cho phép (từ 0.5.4)

- Chủ bot thả 🔓 (`unlock`) lên lời xin duyệt đang chờ = duyệt yêu cầu đó và bật chế độ không cần duyệt cho phạm vi phiên: chat chính của kênh, một luồng, hoặc kênh bí mật. Người giao việc không phải chủ bot thả 🔓 thì bị bỏ qua. Lưu trong bảng `bypass` của state DB nên khởi động lại vẫn giữ.
- Trạng thái duyệt `"always"`. Các lượt sau: Claude chạy `--permission-mode bypassPermissions`; Codex nhận `approvalPolicy: "never"` và `sandboxPolicy: dangerFullAccess` (gửi ở mỗi `turn/start`, lượt thường gửi lại `on-request` và sandbox trong config). Lời xin duyệt còn lại trong lượt đang chạy thì tự duyệt.
- Thẻ có bước "🔓 Đang chạy không cần duyệt (chủ bot cho phép)".
- Chủ bot nhắn "tắt luôn cho phép" hoặc "bật lại duyệt" trong chat/luồng đó để quay lại duyệt bình thường; bot xác nhận.
- A2A: bot được nhờ không kế thừa chế độ này. Chủ của bot được nhờ có thể thả 🔓 trong DM duyệt để bật cho phạm vi `a2a:<bên nhờ>:<context>` của bot đó.
- Báo cáo ra ngoài từ luồng bí mật (`kind: "report"`) luôn phải 👍, kể cả khi đang bật chế độ này.

## Lượt bị dừng giữa chừng và "Tiếp tục" (từ 0.5.7)

- Runner tắt (SIGTERM: cập nhật, khởi động lại) giữa lượt thì trong 8 giây nó chốt thẻ `flygo_agent.status = "stopped"`, `interrupted: true`, `resume_post_id` (tin giao việc), `error` = lời nhắn "⏹ Bị dừng do cập nhật trợ lý…"; lời xin duyệt đang chờ thành `expired`. Mọi thẻ đều mang thêm `flygo_agent.post_id` (tin giao việc).
- Không kịp chốt (bị kill): lúc khởi động, phiên còn ghi `running` trong DB được dò lại, post stream của lượt đó được chốt như trên và có thêm một tin nhắn báo.
- 👍/👎/🔓 lên lời xin duyệt của lượt không còn chạy: bot trả lời "Lượt này đã dừng (trợ lý vừa khởi động lại)…". 🔓 của chủ bot vẫn bật Luôn cho phép.
- ▶️ (`arrow_forward`, nút "Tiếp tục" trên app) từ người giao việc hoặc chủ bot lên post có `stopped` + `interrupted`: runner bỏ `interrupted` (chỉ tiếp tục một lần) rồi chạy lại tin giao việc trong cùng phiên/phạm vi (cùng model/mức suy nghĩ, cùng chế độ Luôn cho phép), kèm lời dặn "kiểm tra những gì đã làm rồi làm nốt".
- Lời xin duyệt vừa hiện mà người dùng bấm ngay: runner đăng ký chờ trước, rồi đọc lại các reaction đã có, nên không lỡ.

## Luồng bí mật lồng nhau (từ 0.5.8)

Kênh bí mật có thể tách từ một kênh bí mật khác (`[flygo-sub parent=<kênh bí mật> root=…]`, `root` có thể là tin trả lời trong luồng). Thư mục làm việc, thư mục code đã gắn và section Codex lấy theo chat gốc trên cùng (lần theo parent tối đa 10 tầng). Ngữ cảnh "Nhóm ngoài" và `chat_report_out` nhắm vào kênh cha trực tiếp (lên một tầng), có nêu thêm tên nhóm gốc. Khoá phiên vẫn riêng cho từng kênh bí mật.

## Phiên riêng của chat 1-1 (từ 0.6.24, app 155)

Phiên riêng là một chat AI (kênh P, purpose `[flygo-ai group=<chat 1-1 chủ↔bot> owner=<chủ>]`, thành viên: chủ + bot) gắn với chat 1-1 thay vì một nhóm.
- Tin không tag vẫn được bot trả lời (như mọi chat AI riêng).
- Ngữ cảnh: "chat 1-1" thay cho "nhóm". Bot đọc chat 1-1 bằng `channel="group"`, và `chat_report_out` gửi vào chat 1-1.
- Tách phiên: header `[flygo-ai-fork <id chat 1-1>]` tách từ phiên chính của chat 1-1 (chỉ khi đúng là chat 1-1 giữa chủ và bot này). `[flygo-ai-fork <id phiên riêng>]` tách từ phiên riêng khác cùng chủ, cùng chat 1-1. Không có header thì mở phiên mới.

## Dự án (từ 0.6.25, app 156)

Dự án là kênh P có `[flygo-agent-project owner=<chủ>]` trong purpose (không hiện ở tab Chat). Phiên của dự án là chat AI `[flygo-ai group=<id dự án> owner=<chủ>]` (chủ + một bot); bot cũng là thành viên kênh dự án.
- Tin không tag trong phiên vẫn được trả lời. Ngữ cảnh gọi là "dự án <tên>", không phải nhóm chat; không có `chat_report_out` (kênh dự án không phải chỗ để báo cáo).
- Tách phiên giữa các phiên cùng dự án: `[flygo-ai-fork <id phiên>]` như cũ.
- Thư mục code dùng chung: mốc `[flygo-project path=…]` trong purpose kênh dự án (đặt lúc tạo kênh bởi chủ bot, hoặc đổi sau bởi chủ bot), hoặc lệnh "@bot dự án <path>" gõ trong bất kỳ phiên nào của dự án. Mọi phiên của dự án làm việc trong thư mục đó (path phải nằm dưới `projectRoots`).
- Phiên đã lưu trữ (`[flygo-ai-archived]` trong header): bot bỏ qua tin không tag, vẫn trả lời khi được @tag. Bỏ mốc (khôi phục) thì như thường.

## Đăng nhập máy tính bằng QR (relay `relay/qr.mjs`)

Trạm đẩy (flygo-push và các bản sao riêng) có thêm `/qr/…`: điện thoại đã đăng nhập xin relay tạo token cá nhân cho chính người dùng đó để máy tính đăng nhập (người dùng thường có thể không có quyền `create_user_access_token`, nên relay tạo bằng token quản trị của server).
- `POST /qr/token` `{device, ip}` → `{token, token_id, user_id}`; description `QR login · <device> · dd/MM/yyyy HH:mm` (giờ Việt Nam).
- `GET /qr/tokens` → `{tokens: [{token_id, description, is_active}]}` (chỉ token "QR login" của người gọi); `DELETE /qr/tokens/<token_id>` thu hồi (chỉ token của người gọi).
- Header: `Authorization: Bearer <token máy chủ chat>` + `X-MM-Server: <url server>` (server phải nằm trong `qr.servers` của trạm).
- Từ chối bot và tài khoản bị khoá. Máy chủ chat không cho biết token đang gọi là session hay token cá nhân, nên chống "token sinh token" bằng giới hạn: tối đa `maxActive` (5) token QR còn hiệu lực mỗi người, `perMinute` (5) lần tạo mỗi phút. Log ghi email, máy, ip, token_id; không ghi token.
- Cấu hình: `qr: { servers: { "<url server>": { internal?, adminTokenFile } }, maxActive?, perMinute? }`.

## Tag chat / luồng cho agent kèm quyền tạm (từ 0.6.30, relay `relay/ref.mjs`)

Người dùng tag một chat (hoặc một luồng) mà bot KHÔNG là thành viên, kèm hạn dùng; bot đọc (và nếu được phép thì gửi tin) vào đúng phần được tag, không được thêm vào chat.
- Relay trên trạm đẩy: `POST /ref/grants` (token người dùng + X-MM-Server; body `{bot_id, ttl_sec 60..86400, write, refs:[{channel_id, root_id?}]}`, ≤10 ref; người gọi phải ở từng chat, và là chủ bot hoặc trong `allow=`) → `{grant_id, expires_at, write, refs:[{ref_id, kind, channel_id, root_id?, name}]}`. Bot (token của đúng bot đó): `GET /ref/read?grant&ref&before&limit≤50&q`, `GET /ref/thread?grant&ref&root`, `POST /ref/post {grant, ref, message, root_id?, from_channel?}` (chỉ khi `write`; gửi qua incoming webhook "flygo agent ref" của chat đó, đứng tên hiển thị + ảnh của bot, `props.flygo_ref_post`). Hết hạn: 410. Log không ghi nội dung tin.
- Tin giao việc có `props.flygo_refs` = `{grant_id, expires_at, write, server, bot_id, items:[…]}` hoặc `{grants:[…]}` (nhiều bot; mỗi runner giữ grant có `bot_id` của mình). Runner lưu theo khoá phiên (bảng `ref_grants`) và dùng cho các lượt sau tới khi hết hạn; ref `kind:"thread"` không có `root_id` (luồng bí mật) coi như chat.
- Ngữ cảnh có mục "Chat được tag cho bạn" (ref_id, tên, quyền, hạn) và dặn đọc có chọn lọc. Tool MCP: `ref_read(ref_id, q?, before?, limit?)`, `ref_thread(ref_id, root?)`, `ref_post(ref_id, message, root_id?)`; `ref_post` ghi bước "Đã gửi vào <tên>". Relay mặc định `chat.<miền>` → `push.<miền>`, đổi bằng `refRelay` trong cấu hình runner.

## Thành phần

| File | Vai trò |
|---|---|
| `src/runner.ts` | Nghe WebSocket của máy chủ chat, chọn engine, dựng ngữ cảnh, quản lý phiên (SQLite `~/.config/flygo-agent/state.db`), duyệt quyền |
| `src/engines/codex.ts` | Nối `codex app-server` dùng chung qua `ws+unix://<socket>:/rpc`. Codex app nối cùng socket nên thấy các phiên realtime và chat tiếp được |
| `src/engines/claude.ts` | `claude -p --output-format stream-json`, `--resume` để nói tiếp. Không nạp settings cá nhân (`--setting-sources project,local`); quyền gồm `allowedTools` + `deny`, còn lại hỏi qua `--permission-prompt-tool`. `claude.fullAccess: true` thì chạy `bypassPermissions`: không hỏi duyệt, bỏ cả `deny` (chỉ bật khi chủ máy yêu cầu) |
| `src/mcp-chat.ts` | MCP server của mỗi phiên, chỉ đọc kênh của phiên: `chat_thread`, `chat_history`, `chat_search`, `chat_info` (nhóm và thành viên), `chat_files`, `chat_read_file` (tải tệp đính kèm về `attachments/`, trả nội dung nếu là tệp văn bản), `chat_send_files` (gửi tệp trong thư mục làm việc vào luồng, tối đa 10 tệp mỗi post, giới hạn theo `MaxFileSize` của server, post mang `props.flygo_agent_files=true` và `flygo_reply` giống tin cuối của lượt), `chat_send_bilingual` (tin song ngữ); thêm `approve` (cho Claude) |
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
- MCP server nào của Codex lỗi khi chạy dưới service thì tắt bằng `codex.spawnArgs`, ví dụ `["-c", "mcp_servers.<tên MCP server>.required=false"]`.
- Sandbox `workspace-write` của Codex trên Windows còn thử nghiệm. Nếu lệnh lỗi vì sandbox, cân nhắc `codex.sandbox`.
- Dịch vụ nền: `install-service --config <file>` tạo task `FlygoAgent-<bot>` (ONLOGON, chỉ chạy khi người dùng đã đăng nhập). Log ở `%LOCALAPPDATA%\\flygo-agent\\logs\\runner-<bot>.log` (`--log`).
- Windows không có SIGTERM: khi tắt máy hoặc kill, bot không kịp về offline; custom status tự hết hạn sau 10 phút. Khoá chạy một runner kiểm theo pid.

## Hạn chế đã biết

- Codex: lệnh mạng (`curl`) vẫn chạy được dù sandbox ghi `network_access: false` (lệnh chạy qua "code mode"). Ghi file ngoài thư mục làm việc thì bị chặn và phải xin duyệt.
- MCP server `flygo_chat` dùng token của bot. Agent chạy cùng user hệ điều hành nên về lý thuyết đọc được env của tiến trình. Chấp nhận được với bot cá nhân trên máy cá nhân; không dùng bot có quyền rộng.
- Claude chạy chế độ `-p` (mỗi lượt một tiến trình), chưa gắn vào phiên Claude Code đang mở trên terminal. Chế độ "attach" qua channels đã thử thành công nhưng chưa đưa vào runner.

## Tích hợp vào app Flygo Chat (bản máy tính)

File chạy: `dist/flygo-agent-{darwin-arm64,darwin-x64,linux-x64,linux-arm64,windows-x64.exe}` (build: `bun scripts/build.ts`). Bản phát hành: `<máy chủ chat>/static/plugins/flygo-agent/<tên file>`, kèm `version.json` (version, sha256 từng file). Server lưu ở `client-plugins/flygo-agent/` trong thư mục cài máy chủ chat.

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
   - Gặp `already_running` (đang có dịch vụ nền hoặc app khác chạy cùng bot) thì hỏi người dùng, (từ 0.4.2 không còn `--takeover`).
4. **Chạy nền khi đăng nhập máy** (tuỳ chọn):
   - Chép file chạy ra chỗ cố định (`~/.local/share/flygo-agent/flygo-agent`). **Khi cập nhật phải chép ra file tạm rồi `mv` đè** (đổi inode). `cp` đè lên file đang chạy thì macOS sẽ giết tiến trình (chữ ký mã hỏng).
   - Ghi cấu hình ra `~/.config/flygo-agent/config-<bot username>.json` (chmod 600). Mỗi file cấu hình là một dịch vụ riêng (`vn.flygo.agent.runner.<bot>`), log ở `runner-<bot>.log`.
   - Chạy `flygo-agent install-service --config <file>`. Gỡ bằng `uninstall-service --config <file>`, xem trạng thái bằng `service-status --config <file>`.
5. **Trạng thái trên mọi thiết bị**: khi đang chạy, bot có status `online` và custom status 🟢 "Đang chạy trên <máy> · codex, claude". Custom status hết hạn sau 10 phút và được làm mới mỗi 5 phút, nên runner chết đột ngột thì tự mất.
6. **Thêm trợ lý vào nhóm**: `POST /api/v4/channels/<id>/members {user_id: <bot_id>}`.

**macOS: App Sandbox.** Bản macOS đang bật `com.apple.security.app-sandbox`. Tiến trình con kế thừa sandbox, nên runner sẽ không đọc được `~/.codex`, `~/.claude` và không chạy được `codex`/`claude`. Có hai cách:
- (a) Tắt sandbox. App phân phối ngoài Mac App Store nên vẫn notarize được. Lưu ý dữ liệu đang nằm ở `~/Library/Containers/vn.flygo.chat`, cần chuyển sang chỗ mới.
- (b) Giữ sandbox, app chỉ cài dịch vụ nền một lần qua lệnh người dùng chạy trong Terminal, sau đó điều khiển và theo dõi qua trạng thái của bot.
