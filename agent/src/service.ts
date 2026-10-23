// Cài / gỡ dịch vụ nền chạy runner khi đăng nhập máy (macOS LaunchAgent, Linux systemd --user, Windows Task Scheduler).
import { existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const BASE = "vn.flygo.agent.runner";
const home = homedir();
// Mỗi file cấu hình (mỗi bot) một dịch vụ: config.json -> vn.flygo.agent.runner, config-sep-claude.json -> vn.flygo.agent.runner.sep-claude
const nameOf = (configPath?: string) => {
  const b = configPath ? basename(configPath).replace(/\.json$/, "").replace(/^config-?/, "").replace(/[^a-zA-Z0-9._-]/g, "_") : "";
  return b;
};
const labelOf = (n: string) => (n ? `${BASE}.${n}` : BASE);
const plistOf = (n: string) => join(home, "Library", "LaunchAgents", `${labelOf(n)}.plist`);
const unitOf = (n: string) => join(home, ".config", "systemd", "user", n ? `flygo-agent-${n}.service` : "flygo-agent.service");
const unitName = (n: string) => (n ? `flygo-agent-${n}` : "flygo-agent");
const taskName = (n: string) => (n ? `FlygoAgent-${n}` : "FlygoAgent");
export const logDir = process.platform === "darwin" ? join(home, "Library", "Logs", "flygo-agent") : process.platform === "win32" ? join(home, "AppData", "Local", "flygo-agent", "logs") : join(home, ".local", "state", "flygo-agent");

const sh = (cmd: string[]) => { const p = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" }); return { code: p.exitCode, out: (p.stdout.toString() + p.stderr.toString()).trim() }; };
const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

export function serviceStatus(configPath?: string) {
  const n = nameOf(configPath), LABEL = labelOf(n), plistPath = plistOf(n), unitPath = unitOf(n);
  if (process.platform === "darwin") return { installed: existsSync(plistPath), path: plistPath, running: sh(["launchctl", "print", `gui/${process.getuid!()}/${LABEL}`]).code === 0 };
  if (process.platform === "linux") return { installed: existsSync(unitPath), path: unitPath, running: sh(["systemctl", "--user", "is-active", unitName(n)]).out === "active" };
  if (sh(["schtasks", "/Query", "/TN", taskName(n)]).code === 0) return { installed: true, path: taskName(n), running: false };
  // Máy không có quyền quản trị: tự chạy khi đăng nhập bằng khoá Run của người dùng (xem installService).
  return { installed: sh(["reg", "query", RUN_KEY, "/v", taskName(n)]).code === 0, path: `${RUN_KEY}\\${taskName(n)}`, running: false };
}

const RUN_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
/** Windows: dừng runner đang chạy với file cấu hình này (chế độ khoá Run không có schtasks /End). */
function stopWinRunner(configPath?: string) {
  if (!configPath) return;
  const esc = configPath.replace(/'/g, "''");
  sh(["powershell", "-NoProfile", "-Command", `Get-CimInstance Win32_Process -Filter "Name='flygo-agent.exe'" | Where-Object { $_.CommandLine -like '*${esc}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }`]);
}

/** selfCommand: lệnh chạy chính chương trình; configPath: file cấu hình (chmod 600). */
export function installService(selfCommand: string[], configPath: string) {
  const n = nameOf(configPath), LABEL = labelOf(n), plistPath = plistOf(n), unitPath = unitOf(n);
  mkdirSync(logDir, { recursive: true });
  const args = [...selfCommand, "run", "--config", configPath];
  if (process.platform === "darwin") {
    const uid = process.getuid!();
    sh(["launchctl", "bootout", `gui/${uid}/${LABEL}`]);
    mkdirSync(join(home, "Library", "LaunchAgents"), { recursive: true });
    writeFileSync(plistPath, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>${args.map((a) => `<string>${xml(a)}</string>`).join("")}</array>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>${xml(home)}</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>${xml(join(logDir, `runner${n ? "-" + n : ""}.log`))}</string>
  <key>StandardErrorPath</key><string>${xml(join(logDir, `runner${n ? "-" + n : ""}.log`))}</string>
</dict></plist>
`);
    // Đợi bản cũ dừng hẳn (runner tắt êm mất vài giây) rồi mới nạp, thử lại vài lần.
    for (let i = 0; i < 40 && sh(["launchctl", "print", `gui/${uid}/${LABEL}`]).code === 0; i++) Bun.sleepSync(250);
    let r = sh(["launchctl", "bootstrap", `gui/${uid}`, plistPath]);
    for (let i = 0; i < 5 && r.code !== 0; i++) { Bun.sleepSync(1000); r = sh(["launchctl", "bootstrap", `gui/${uid}`, plistPath]); }
    if (r.code !== 0) throw new Error(`launchctl bootstrap: ${r.out}`);
  } else if (process.platform === "linux") {
    mkdirSync(join(home, ".config", "systemd", "user"), { recursive: true });
    writeFileSync(unitPath, `[Unit]\nDescription=Flygo Agent runner\nAfter=network-online.target\n\n[Service]\nExecStart=${args.map((a) => JSON.stringify(a)).join(" ")}\nRestart=on-failure\nRestartSec=15\n\n[Install]\nWantedBy=default.target\n`);
    sh(["systemctl", "--user", "daemon-reload"]);
    const r = sh(["systemctl", "--user", "enable", "--now", unitName(n)]);
    if (r.code !== 0) throw new Error(`systemctl: ${r.out}`);
  } else {
    // Task Scheduler không giữ output: runner tự ghi log ra file.
    const winArgs = [...args, "--log", join(logDir, `runner${n ? "-" + n : ""}.log`)];
    const cmdLine = winArgs.map((a) => `"${a}"`).join(" ");
    const r = sh(["schtasks", "/Create", "/F", "/SC", "ONLOGON", "/TN", taskName(n), "/TR", cmdLine]);
    if (r.code === 0) {
      sh(["schtasks", "/Run", "/TN", taskName(n)]);
    } else {
      // Tác vụ "khi đăng nhập" cần quyền quản trị (máy dùng tài khoản thường báo "Access is denied"): dùng khoá Run của
      // người dùng (không cần quyền quản trị) để tự chạy khi đăng nhập, rồi chạy luôn bây giờ.
      const k = sh(["reg", "add", RUN_KEY, "/v", taskName(n), "/t", "REG_SZ", "/d", cmdLine, "/f"]);
      if (k.code !== 0) throw new Error(`Không cài được chạy nền (schtasks: ${r.out}; khoá Run: ${k.out})`);
      stopWinRunner(configPath);
      Bun.spawn(winArgs, { stdin: "ignore", stdout: "ignore", stderr: "ignore" }).unref();
    }
  }
  return serviceStatus(configPath);
}

export function uninstallService(configPath?: string) {
  const n = nameOf(configPath), LABEL = labelOf(n), plistPath = plistOf(n), unitPath = unitOf(n);
  if (process.platform === "darwin") {
    sh(["launchctl", "bootout", `gui/${process.getuid!()}/${LABEL}`]);
    if (existsSync(plistPath)) unlinkSync(plistPath);
  } else if (process.platform === "linux") {
    sh(["systemctl", "--user", "disable", "--now", unitName(n)]);
    if (existsSync(unitPath)) unlinkSync(unitPath);
  } else {
    sh(["schtasks", "/End", "/TN", taskName(n)]);
    sh(["schtasks", "/Delete", "/F", "/TN", taskName(n)]);
    sh(["reg", "delete", RUN_KEY, "/v", taskName(n), "/f"]);
    stopWinRunner(configPath);
  }
  return serviceStatus(configPath);
}

/** Dừng (và tắt tự chạy) dịch vụ nền đang giữ tiến trình pid, để app tiếp quản bot. */
export function stopServiceForTakeover(pid: number): boolean {
  if (process.platform === "darwin") {
    const uid = process.getuid!();
    const line = sh(["launchctl", "list"]).out.split("\n").find((l) => l.startsWith(`${pid}\t`) && l.includes(BASE));
    if (!line) return false;
    const label = line.split("\t")[2];
    sh(["launchctl", "bootout", `gui/${uid}/${label}`]);
    const p = join(home, "Library", "LaunchAgents", `${label}.plist`);
    if (existsSync(p)) renameSync(p, `${p}.disabled`);
    return true;
  }
  if (process.platform === "linux") {
    const unit = sh(["ps", "-o", "unit=", "-p", String(pid)]).out.trim();
    if (!unit.startsWith("flygo-agent")) return false;
    sh(["systemctl", "--user", "disable", "--now", unit]);
    return true;
  }
  return false;
}
