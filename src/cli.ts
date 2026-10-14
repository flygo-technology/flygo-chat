#!/usr/bin/env bun
// flygo-agent: một file chạy cho mọi chế độ.
//   run [--config <file> | --config-stdin] [--json] [--takeover]   chạy runner (app gọi: --config-stdin --json)
//   doctor [--json]                                   kiểm tra Codex / Claude trên máy
//   mcp-chat                                          MCP server của một phiên (runner tự gọi)
//   codex-shared [--config <file>]                    giữ codex app-server dùng chung + chuyển tiếp TCP
//   install-service --config <file> | uninstall-service | service-status   dịch vụ nền khi đăng nhập máy
//   version
import pkg from "../package.json";
import { extendPath, loadConfig } from "./config";

extendPath();
const [cmd = "run", ...args] = process.argv.slice(2);
const json = args.includes("--json");
// Bản đóng gói (bun build --compile) chạy từ /$bunfs (hoặc B:/~BUN trên Windows); bản dev chạy bun + đường dẫn file.
const compiled = import.meta.path.includes("$bunfs") || import.meta.path.includes("~BUN");
const selfCommand = compiled ? [process.execPath] : [process.execPath, import.meta.path];

switch (cmd) {
  case "run": {
    const { startRunner } = await import("./runner");
    const log = (s: string) => (json ? console.error : console.log)(`${new Date().toISOString()} ${s}`);
    const emit = (ev: Record<string, any>) => {
      if (json) process.stdout.write(JSON.stringify({ ts: Date.now(), ...ev }) + "\n");
      else if (ev.event === "error") log(`LỖI ${ev.code}: ${ev.message}${ev.doctor ? " " + JSON.stringify(ev.doctor) : ""}`);
    };
    try {
      const cfg = await loadConfig(args);
      await startRunner(cfg, { emit, log, selfCommand, takeover: args.includes("--takeover") });
    } catch (e: any) {
      emit({ event: "error", code: "fatal", message: String(e?.message ?? e) });
      log(`lỗi: ${e?.stack ?? e}`);
      process.exit(1);
    }
    break;
  }
  case "doctor": {
    const { doctor } = await import("./doctor");
    const r = await doctor();
    if (json) console.log(JSON.stringify(r));
    else for (const e of ["codex", "claude"] as const) console.log(`${e}: ${r[e].installed ? `${r[e].version} · ${r[e].loggedIn ? `đã đăng nhập (${r[e].account ?? ""})` : "CHƯA đăng nhập"}` : "chưa cài"}`);
    break;
  }
  case "mcp-chat": {
    const { runMcpChat } = await import("./mcp-chat");
    await runMcpChat();
    break;
  }
  case "codex-shared": {
    const { runCodexShared } = await import("./codex-shared");
    await runCodexShared(await loadConfig(args, false));
    break;
  }
  case "install-service": {
    // app ghi cấu hình ra file (chmod 600) rồi gọi: install-service --config <file>
    const { installService } = await import("./service");
    const i = args.indexOf("--config");
    if (i < 0) { console.error("cần --config <file>"); process.exit(2); }
    console.log(JSON.stringify(installService(selfCommand, args[i + 1])));
    break;
  }
  case "uninstall-service": {
    const { uninstallService } = await import("./service");
    console.log(JSON.stringify(uninstallService()));
    break;
  }
  case "service-status": {
    const { serviceStatus } = await import("./service");
    console.log(JSON.stringify(serviceStatus()));
    break;
  }
  case "version":
    console.log(pkg.version);
    break;
  default:
    console.error(`lệnh không hợp lệ: ${cmd}`);
    process.exit(2);
}
