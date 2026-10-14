// Cấu hình runner: ~/.config/flygo-agent/config.json (chmod 600). Xem config.example.json.
import { homedir } from "node:os";
import { join } from "node:path";

export type EngineName = "codex" | "claude";

export interface Config {
  serverUrl: string; // https://chat.flygo.vn
  botToken: string; // token của bot cá nhân (vd. sep-ai)
  ownerUserIds: string[]; // chỉ những người này mới giao việc được
  defaultEngine: EngineName;
  profile: string; // tên thư mục trong profiles/
  workspaceRoot: string; // nơi tạo thư mục làm việc theo kênh
  approvalTimeoutSec: number;
  localPort: number; // HTTP nội bộ cho MCP server gọi về (duyệt quyền Claude)
  codex: {
    socket: string; // app-server dùng chung (Codex app có thể nối cùng socket)
    spawnArgs: string[]; // tham số thêm khi runner phải tự chạy app-server, vd. ["-c", "openai_base_url=..."]
    sandbox: "read-only" | "workspace-write" | "danger-full-access";
    model?: string;
  };
  claude: {
    bin: string;
    allowedTools: string[]; // chạy không cần hỏi; còn lại hỏi qua Flygo
    deny: string[]; // cấm hẳn, không hỏi
    model?: string;
  };
  // Chuyển tiếp TCP bằng bun (vì macOS chặn Local Network với binary codex/node)
  forwards: Array<{ listen: number; host: string; port: number }>;
}

export const CONFIG_DIR = join(homedir(), ".config", "flygo-agent");
export const ROOT = join(import.meta.dir, "..");

const defaults: Omit<Config, "serverUrl" | "botToken" | "ownerUserIds"> = {
  defaultEngine: "codex",
  profile: "default",
  workspaceRoot: join(homedir(), "flygo-agent", "workspaces"),
  approvalTimeoutSec: 600,
  localPort: 8791,
  codex: {
    socket: join(homedir(), ".codex", "flygo-shared.sock"),
    spawnArgs: [],
    sandbox: "workspace-write",
  },
  claude: {
    bin: "claude",
    allowedTools: ["Read", "Grep", "Glob", "LS", "TodoWrite", "WebSearch", "WebFetch", "mcp__flygo_chat__chat_thread", "mcp__flygo_chat__chat_history", "mcp__flygo_chat__chat_search", "mcp__flygo_chat__chat_info", "mcp__flygo_chat__chat_files", "mcp__flygo_chat__chat_read_file"],
    deny: [
      "Bash(rm -rf:*)", "Bash(sudo:*)", "Bash(git push:*)", "Bash(ssh:*)", "Bash(scp:*)",
      "Read(~/.ssh/**)", "Read(~/.config/flygo-agent/**)", "Read(~/.codex/auth.json)", "Read(~/.aws/**)",
    ],
  },
  forwards: [],
};

export async function loadConfig(): Promise<Config> {
  const path = process.env.FLYGO_AGENT_CONFIG ?? join(CONFIG_DIR, "config.json");
  const raw = await Bun.file(path).json();
  const cfg = { ...defaults, ...raw, codex: { ...defaults.codex, ...raw.codex }, claude: { ...defaults.claude, ...raw.claude } } as Config;
  for (const k of ["serverUrl", "botToken", "ownerUserIds"] as const) if (!cfg[k]) throw new Error(`config thiếu ${k} (${path})`);
  cfg.serverUrl = cfg.serverUrl.replace(/\/$/, "");
  return cfg;
}
