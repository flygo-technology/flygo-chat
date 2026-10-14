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
  workspaceRoot: string; // nơi tạo thư mục làm việc theo kênh
  approvalTimeoutSec: number;
  codex: {
    socket: string; // app-server dùng chung (Codex app có thể nối cùng socket)
    spawnArgs: string[]; // tham số thêm khi phải tự chạy app-server, vd. ["-c", "openai_base_url=..."]
    sandbox: "read-only" | "workspace-write" | "danger-full-access";
    model?: string;
  };
  claude: {
    bin: string;
    allowedTools: string[]; // chạy không cần hỏi; còn lại hỏi qua Flygo
    deny: string[]; // cấm hẳn, không hỏi
    model?: string;
  };
  // Chuyển tiếp TCP bằng bun (macOS chặn Local Network với binary codex/node). Chỉ codex-shared dùng.
  forwards: Array<{ listen: number; host: string; port: number }>;
}

export const CONFIG_DIR = join(homedir(), ".config", "flygo-agent");

const defaults: Omit<Config, "serverUrl" | "botToken" | "ownerUserIds" | "engine"> = {
  workspaceRoot: join(homedir(), "flygo-agent", "workspaces"),
  approvalTimeoutSec: 600,
  codex: {
    socket: join(homedir(), ".codex", "flygo-shared.sock"),
    spawnArgs: [],
    sandbox: "workspace-write",
  },
  claude: {
    bin: "claude",
    allowedTools: ["Read", "Grep", "Glob", "LS", "TodoWrite", "WebSearch", "WebFetch", "mcp__flygo_chat__chat_thread", "mcp__flygo_chat__chat_history", "mcp__flygo_chat__chat_search", "mcp__flygo_chat__chat_info", "mcp__flygo_chat__chat_files", "mcp__flygo_chat__chat_read_file", "mcp__flygo_chat__chat_send_files"],
    deny: [
      "Bash(rm -rf:*)", "Bash(sudo:*)", "Bash(git push:*)", "Bash(ssh:*)", "Bash(scp:*)",
      "Read(~/.ssh/**)", "Read(~/.config/flygo-agent/**)", "Read(~/.codex/auth.json)", "Read(~/.aws/**)",
    ],
  },
  forwards: [],
};

export function parseConfig(raw: any, requireBot = true): Config {
  const cfg = { ...defaults, ...raw, codex: { ...defaults.codex, ...raw.codex }, claude: { ...defaults.claude, ...raw.claude } } as Config;
  cfg.engine ??= raw.defaultEngine; // cấu hình cũ
  if (requireBot) for (const k of ["serverUrl", "botToken", "ownerUserIds", "engine"] as const) if (!cfg[k]) throw new Error(`config thiếu ${k}`);
  if (requireBot && !["codex", "claude"].includes(cfg.engine)) throw new Error(`engine không hợp lệ: ${cfg.engine}`);
  cfg.serverUrl = (cfg.serverUrl ?? "").replace(/\/$/, "");
  cfg.workspaceRoot = cfg.workspaceRoot.replace(/^~(?=\/|$)/, homedir());
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
    "/opt/homebrew/bin", "/usr/local/bin", join(h, "AppData", "Roaming", "npm")];
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

/** Đường dẫn đầy đủ của một lệnh theo PATH hiện tại (đã extendPath). */
export const resolveBin = (name: string) => Bun.which(name, { PATH: process.env.PATH ?? "" }) ?? name;
