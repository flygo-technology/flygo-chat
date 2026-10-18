#!/usr/bin/env bun
// flygo-agent: một file chạy cho mọi chế độ.
//   run [--config <file> | --config-stdin] [--json]   chạy runner (app gọi: --config-stdin --json)
//   doctor [--json]                                   kiểm tra Codex / Claude trên máy
//   mcp-chat                                          MCP server của một phiên (runner tự gọi)
//   ask-hook                                          hook PreToolUse AskUserQuestion của Claude (runner tự đặt)
//   codex-shared [--config <file>]                    giữ codex app-server dùng chung + chuyển tiếp TCP
//   install-service --config <file> | uninstall-service | service-status   dịch vụ nền khi đăng nhập máy
//   skills --bot <id> [--config <file>] [--json]       vai trò + kỹ năng của bot (app desktop hiện danh sách "Kỹ năng")
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
    const li = args.indexOf("--log");
    const logFile = li >= 0 ? args[li + 1] : "";
    const { appendFileSync, mkdirSync } = await import("node:fs");
    if (logFile) mkdirSync((await import("node:path")).dirname(logFile), { recursive: true });
    const log = (s: string) => {
      const line = `${new Date().toISOString()} ${s}`;
      if (logFile) appendFileSync(logFile, line + "\n"); else (json ? console.error : console.log)(line);
    };
    const emit = (ev: Record<string, any>) => {
      if (json) process.stdout.write(JSON.stringify({ ts: Date.now(), ...ev }) + "\n");
      else if (ev.event === "error") log(`LỖI ${ev.code}: ${ev.message}${ev.doctor ? " " + JSON.stringify(ev.doctor) : ""}`);
    };
    try {
      const cfg = await loadConfig(args);
      await startRunner(cfg, { emit, log, selfCommand, }); // --takeover bỏ (0.4.2): bot gắn cứng một máy, không còn runner trong app
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
  case "ask-hook": {
    // stdin: sự kiện PreToolUse của Claude. Hỏi người dùng qua runner (/ask), trả câu trả lời bằng updatedInput.answers.
    const ev = JSON.parse((await Bun.stdin.text()) || "{}");
    const input = ev.tool_input ?? {};
    const qs = (input.questions ?? []) as any[];
    const out = (o: any) => console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", ...o } }));
    const deny = (reason: string) => out({ permissionDecision: "deny", permissionDecisionReason: reason });
    const url = process.env.FLYGO_RUNNER_URL, key = process.env.FLYGO_RUN_KEY;
    if (!url || !key) { deny("Không hỏi được người dùng lúc này. Tự quyết theo hướng hợp lý nhất và nói rõ đã chọn gì."); break; }
    const r: any = await fetch(`${url}/ask`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ key, questions: qs.map((q, i) => ({ id: String(i), question: q.question, header: q.header, options: q.options ?? [], multi: !!q.multiSelect })) }),
    }).then((x) => x.json()).catch((e) => ({ cancelled: true, reason: String(e) }));
    if (r.cancelled || !Array.isArray(r.answers)) { deny(r.reason || "Người dùng không trả lời."); break; }
    const answers: Record<string, string> = {};
    qs.forEach((q, i) => { const a = r.answers[i]; if (a) answers[q.question] = [...(a.choices ?? []), ...(a.other ? [a.other] : [])].join(", "); });
    out({ permissionDecision: "allow", updatedInput: { ...input, answers } });
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
    const i = args.indexOf("--config");
    console.log(JSON.stringify(uninstallService(i >= 0 ? args[i + 1] : undefined)));
    break;
  }
  case "service-status": {
    const { serviceStatus } = await import("./service");
    const i = args.indexOf("--config");
    console.log(JSON.stringify(serviceStatus(i >= 0 ? args[i + 1] : undefined)));
    break;
  }
  case "skills": {
    const { listSkills, readRole, roleLine, roleSlug, botHome } = await import("./skills");
    const bi = args.indexOf("--bot");
    if (bi < 0 || !args[bi + 1]) { console.error("cần --bot <id>"); process.exit(2); }
    const bot = args[bi + 1];
    const base = args.includes("--config") ? (await loadConfig(args, false).catch(() => null))?.skillsDir : undefined;
    const role = readRole(bot);
    const skills = listSkills(bot, base);
    if (json) console.log(JSON.stringify({ bot, home: botHome(bot), role, role_line: roleLine(role), role_slug: roleSlug(role), skills }));
    else { console.log(`Vai trò: ${roleLine(role) || "(chưa đặt)"}`); for (const s of skills) console.log(`- ${s.name}${s.source === "base" ? " (chung)" : ""}: ${s.description}`); }
    break;
  }
  case "version":
    console.log(pkg.version);
    break;
  default:
    console.error(`lệnh không hợp lệ: ${cmd}`);
    process.exit(2);
}
