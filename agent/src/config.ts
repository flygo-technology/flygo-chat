// Cấu hình runner. Nguồn (theo thứ tự): --config-stdin (app truyền qua stdin), --config <file>,
// ~/.config/flygo-agent/config.json. Xem config.example.json.
import { existsSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { delimiter, join } from "node:path";

export type EngineName = "codex" | "claude";

export interface Config {
  serverUrl: string; // https://chat.flygo.vn
  botToken: string; // token của bot cá nhân
  ownerUserIds: string[]; // chỉ những người này mới giao việc được
  engine: EngineName; // mỗi bot gắn cố định một engine: bot Claude chỉ chạy Claude, bot Codex chỉ chạy Codex
  persona?: string; // ghi đè persona mặc định
  skillsDir?: string; // thư mục skill (SKILL.md) chép vào thư mục làm việc
  workspaceRoot: string; // nơi tạo thư mục làm việc theo chat (mỗi chat một thư mục "<tên chat>-<id>")
  projectRoots: string[]; // chat được gắn thư mục code ([flygo-project path=…] / "@bot dự án <path>") chỉ khi path nằm dưới các thư mục này; rỗng = tắt
  mainIdleHours: number; // chat chính nghỉ quá N giờ thì mở phiên mới; 0 = không bao giờ (mặc định)
  approvalTimeoutSec: number;
  codex: {
    bin?: string; // đường dẫn codex (Windows cài qua npm: …\\npm\\codex.cmd)
    skipLoginCheck?: boolean; // bỏ qua kiểm tra đăng nhập (codex xác thực theo cách runner không nhận ra)
    transport: "socket" | "stdio"; // socket: app-server dùng chung (Codex app nối cùng); stdio: runner tự chạy app-server riêng (mặc định trên Windows)
    socket: string; // app-server dùng chung (Codex app có thể nối cùng socket)
    /** Thư mục dữ liệu Codex riêng cho bot (CODEX_HOME), để không dùng chung ~/.codex với Codex Desktop / codex CLI của người dùng. */
    home?: string;
    spawnArgs: string[]; // tham số thêm khi phải tự chạy app-server, vd. ["-c", "openai_base_url=..."]
    sandbox: "read-only" | "workspace-write" | "danger-full-access";
    model?: string;
    models?: string[]; // model cho người dùng chọn theo tin (props.flygo_agent_config); mặc định [model ?? "gpt-5.6-terra"]
    efforts?: string[]; // mặc định low,medium,high,xhigh
    effort?: string; // mức suy nghĩ mặc định (medium)
    sections?: boolean; // xếp thread vào section "Flygo · <tên chat>" trên Codex app (mặc định bật)
  };
  claude: {
    bin: string;
    allowedTools: string[]; // chạy không cần hỏi; còn lại hỏi qua Flygo
    deny: string[]; // cấm hẳn, không hỏi
    fullAccess?: boolean; // toàn quyền (bypassPermissions): không hỏi duyệt, bỏ cả deny — chỉ bật khi chủ máy yêu cầu
    model?: string;
    models?: string[]; // mặc định opus,sonnet
    efforts?: string[]; // mặc định low,medium,high,xhigh,max
    effort?: string; // mặc định high
  };
  // A2A: các bot nhờ nhau qua relay (push.flygo.vn/a2a). Tin tag nhiều agent: agent tag đầu tiên chủ trì.
  a2a: {
    enabled: boolean; // mặc định bật
    relay: string; // wss://push.flygo.vn/a2a/connect
    maxCalls: number; // số lần ask_agent tối đa mỗi lượt (5)
    timeoutSec: number; // chờ một agent tối đa (900)
  };
  // Chuyển tiếp TCP bằng bun (macOS chặn Local Network với binary codex/node). Chỉ codex-shared dùng.
  forwards: Array<{ listen: number; host: string; port: number }>;
}

export const CONFIG_DIR = join(homedir(), ".config", "flygo-agent");

const defaults: Omit<Config, "serverUrl" | "botToken" | "ownerUserIds" | "engine"> = {
  workspaceRoot: join(homedir(), "flygo-agent", "workspaces"),
  projectRoots: [],
  mainIdleHours: 0,
  approvalTimeoutSec: 600,
  codex: {
    transport: process.platform === "win32" ? "stdio" : "socket",
    socket: join(homedir(), ".codex", "flygo-shared.sock"),
    spawnArgs: [],
    sandbox: "workspace-write",
  },
  claude: {
    bin: "claude",
    allowedTools: ["Read", "Grep", "Glob", "LS", "TodoWrite", "WebSearch", "WebFetch", "mcp__flygo_chat__chat_thread", "mcp__flygo_chat__chat_history", "mcp__flygo_chat__chat_search", "mcp__flygo_chat__chat_info", "mcp__flygo_chat__chat_files", "mcp__flygo_chat__chat_read_file", "mcp__flygo_chat__chat_send_files", "mcp__flygo_chat__chat_send_bilingual"],
    // Cấm hẳn (không hiện thẻ duyệt): xoá đệ quy, đọc khoá/token. ssh/scp/sudo/git push: không cấm, hỏi duyệt từng lần như lệnh khác.
    deny: [
      "Bash(rm -rf:*)",
      "Read(~/.ssh/**)", "Read(~/.config/flygo-agent/**)", "Read(~/.codex/auth.json)", "Read(~/.aws/**)",
    ],
  },
  a2a: { enabled: true, relay: "wss://push.flygo.vn/a2a/connect", maxCalls: 5, timeoutSec: 900 },
  forwards: [],
};

export function parseConfig(raw: any, requireBot = true): Config {
  const cfg = { ...defaults, ...raw, codex: { ...defaults.codex, ...raw.codex }, claude: { ...defaults.claude, ...raw.claude }, a2a: { ...defaults.a2a, ...raw.a2a } } as Config;
  cfg.engine ??= raw.defaultEngine; // cấu hình cũ
  if (requireBot) for (const k of ["serverUrl", "botToken", "ownerUserIds", "engine"] as const) if (!cfg[k]) throw new Error(`config thiếu ${k}`);
  if (requireBot && !["codex", "claude"].includes(cfg.engine)) throw new Error(`engine không hợp lệ: ${cfg.engine}`);
  cfg.serverUrl = (cfg.serverUrl ?? "").replace(/\/$/, "");
  cfg.workspaceRoot = cfg.workspaceRoot.replace(/^~(?=\/|$)/, homedir());
  cfg.projectRoots = (cfg.projectRoots ?? []).map((p) => p.replace(/^~(?=\/|$)/, homedir()));
  cfg.codex.socket = cfg.codex.socket.replace(/^~(?=\/|$)/, homedir());
  return cfg;
}

export async function loadConfig(args: string[], requireBot = true): Promise<Config> {
  if (args.includes("--config-stdin")) return parseConfig(JSON.parse(await Bun.stdin.text()), requireBot);
  const i = args.indexOf("--config");
  const path = i >= 0 ? args[i + 1] : process.env.FLYGO_AGENT_CONFIG ?? join(CONFIG_DIR, "config.json");
  return parseConfig(await Bun.file(path).json(), requireBot);
}

/** App mở từ giao diện có PATH rất ngắn: thêm các nơi hay cài codex/claude/bun. */
export function extendPath() {
  const h = homedir();
  const extra = [join(h, ".local", "bin"), join(h, ".bun", "bin"), join(h, ".claude", "local"), join(h, ".npm-global", "bin"),
    "/opt/homebrew/bin", "/usr/local/bin", join(h, "AppData", "Roaming", "npm"),
    join(h, "AppData", "Local", "Programs", "codex"), join(h, "AppData", "Local", "Programs", "claude"), join(h, ".codex", "bin")];
  const cur = (process.env.PATH ?? "").split(delimiter);
  process.env.PATH = [...cur, ...extra.filter((d) => existsSync(d) && !cur.includes(d))].join(delimiter);
  // Claude Code đọc token trong keychain theo USER; launchd/app có thể không đặt biến này.
  // (userInfo() của Bun trả "unknown" khi thiếu USER nên hỏi hệ điều hành bằng `id -un`.)
  if (process.platform !== "win32" && (!process.env.USER || process.env.USER === "unknown")) {
    const u = Bun.spawnSync(["/usr/bin/id", "-un"]).stdout.toString().trim() || userInfo().username;
    process.env.USER = u;
    process.env.LOGNAME ??= u;
  }
  process.env.HOME ??= homedir();
}

/** Tên máy để so mốc host=: chữ thường, bỏ đuôi ".local" (macOS), khoảng trắng và "]" thành "-". App dùng cùng quy tắc. */
export const normHost = (h: string) => h.trim().toLowerCase().replace(/\.local\.?$/, "").replace(/[\s\]]+/g, "-");

/** Đường dẫn đầy đủ của một lệnh theo PATH hiện tại (đã extendPath). */
export const resolveBin = (name: string) => Bun.which(name, { PATH: process.env.PATH ?? "" }) ?? name;

/** Model / mức suy nghĩ bot cho chọn, và mặc định. `marker`: thêm từ mốc "[flygo-agent … models=… efforts=… default=model:mức]" do chủ bot ghi. */
export function agentOptions(cfg: Config, marker = "") {
  const attr = (k: string) => new RegExp(`\\[flygo-agent[^\\]]*\\b${k}=([^\\s\\]]+)`, "i").exec(marker)?.[1];
  const list = (k: string) => attr(k)?.split(",").filter(Boolean) ?? [];
  const e = cfg.engine === "codex"
    ? { model: cfg.codex.model ?? "gpt-5.6-terra", models: cfg.codex.models, effort: cfg.codex.effort ?? "medium", efforts: cfg.codex.efforts ?? ["low", "medium", "high", "xhigh"] }
    : { model: cfg.claude.model ?? "opus", models: cfg.claude.models ?? ["opus", "sonnet"], effort: cfg.claude.effort ?? "high", efforts: cfg.claude.efforts ?? ["low", "medium", "high", "xhigh", "max"] };
  const models = [...new Set([e.model, ...(e.models ?? []), ...list("models")])];
  const efforts = [...new Set([...e.efforts, ...list("efforts")])];
  // default=model:mức trong mốc (thiếu phần nào thì giữ mặc định của cấu hình)
  const [dm, de] = (attr("default") ?? "").split(":");
  if (dm && !models.includes(dm)) models.push(dm);
  if (de && !efforts.includes(de)) efforts.push(de);
  return { models, efforts, default: { model: dm || e.model, effort: de || e.effort } };
}
