// Cài / gỡ dịch vụ nền chạy runner khi đăng nhập máy (macOS LaunchAgent, Linux systemd --user, Windows Task Scheduler).
import { existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LABEL = "vn.flygo.agent.runner";
const home = homedir();
const plistPath = join(home, "Library", "LaunchAgents", `${LABEL}.plist`);
const unitPath = join(home, ".config", "systemd", "user", "flygo-agent.service");
const logDir = process.platform === "darwin" ? join(home, "Library", "Logs", "flygo-agent") : join(home, ".local", "state", "flygo-agent");

const sh = (cmd: string[]) => { const p = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" }); return { code: p.exitCode, out: (p.stdout.toString() + p.stderr.toString()).trim() }; };
const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

export function serviceStatus() {
  if (process.platform === "darwin") return { installed: existsSync(plistPath), path: plistPath, running: sh(["launchctl", "print", `gui/${process.getuid!()}/${LABEL}`]).code === 0 };
  if (process.platform === "linux") return { installed: existsSync(unitPath), path: unitPath, running: sh(["systemctl", "--user", "is-active", "flygo-agent"]).out === "active" };
  return { installed: sh(["schtasks", "/Query", "/TN", "FlygoAgent"]).code === 0, path: "FlygoAgent", running: false };
}

/** selfCommand: lệnh chạy chính chương trình; configPath: file cấu hình (chmod 600). */
export function installService(selfCommand: string[], configPath: string) {
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
  <key>StandardOutPath</key><string>${xml(join(logDir, "runner.log"))}</string>
  <key>StandardErrorPath</key><string>${xml(join(logDir, "runner.log"))}</string>
</dict></plist>
`);
    const r = sh(["launchctl", "bootstrap", `gui/${uid}`, plistPath]);
    if (r.code !== 0) throw new Error(`launchctl bootstrap: ${r.out}`);
  } else if (process.platform === "linux") {
    mkdirSync(join(home, ".config", "systemd", "user"), { recursive: true });
    writeFileSync(unitPath, `[Unit]\nDescription=Flygo Agent runner\nAfter=network-online.target\n\n[Service]\nExecStart=${args.map((a) => JSON.stringify(a)).join(" ")}\nRestart=on-failure\nRestartSec=15\n\n[Install]\nWantedBy=default.target\n`);
    sh(["systemctl", "--user", "daemon-reload"]);
    const r = sh(["systemctl", "--user", "enable", "--now", "flygo-agent"]);
    if (r.code !== 0) throw new Error(`systemctl: ${r.out}`);
  } else {
    const r = sh(["schtasks", "/Create", "/F", "/SC", "ONLOGON", "/TN", "FlygoAgent", "/TR", args.map((a) => `"${a}"`).join(" ")]);
    if (r.code !== 0) throw new Error(`schtasks: ${r.out}`);
    sh(["schtasks", "/Run", "/TN", "FlygoAgent"]);
  }
  return serviceStatus();
}

export function uninstallService() {
  if (process.platform === "darwin") {
    sh(["launchctl", "bootout", `gui/${process.getuid!()}/${LABEL}`]);
    if (existsSync(plistPath)) unlinkSync(plistPath);
  } else if (process.platform === "linux") {
    sh(["systemctl", "--user", "disable", "--now", "flygo-agent"]);
    if (existsSync(unitPath)) unlinkSync(unitPath);
  } else {
    sh(["schtasks", "/End", "/TN", "FlygoAgent"]);
    sh(["schtasks", "/Delete", "/F", "/TN", "FlygoAgent"]);
  }
  return serviceStatus();
}

/** Dừng dịch vụ nền (không gỡ) để app tiếp quản bot; trả về true nếu đã dừng thứ gì đó. */
export function stopServiceForTakeover(): boolean {
  if (process.platform === "darwin" && existsSync(plistPath)) {
    sh(["launchctl", "bootout", `gui/${process.getuid!()}/${LABEL}`]);
    renameSync(plistPath, `${plistPath}.disabled`);
    return true;
  }
  if (process.platform === "linux" && existsSync(unitPath)) { sh(["systemctl", "--user", "disable", "--now", "flygo-agent"]); return true; }
  return false;
}
