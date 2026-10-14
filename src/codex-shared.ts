// Giữ `codex app-server` dùng chung luôn chạy (Codex app + runner cùng nối vào socket).
// - Bộ chuyển tiếp TCP bằng bun cho model provider trong LAN (macOS chặn Local Network với binary codex).
// - Nếu app-server / cổng chuyển tiếp đã chạy sẵn thì dùng lại, không khởi động lại.
import { existsSync, unlinkSync } from "node:fs";
import { loadConfig } from "./config";

const log = (s: string) => console.log(`${new Date().toISOString()} ${s}`);
const cfg = await loadConfig();
const sock = cfg.codex.socket;

const portBusy = (port: number) =>
  Bun.connect({ hostname: "127.0.0.1", port, socket: { data() {}, open(s) { s.end(); } } }).then(() => true, () => false);

const bound = new Set<number>();
async function ensureForwards() {
 for (const f of cfg.forwards) {
  if (bound.has(f.listen) || (await portBusy(f.listen))) continue;
  bound.add(f.listen);
  Bun.listen<{ up: any; buf: Uint8Array[] }>({
    hostname: "127.0.0.1",
    port: f.listen,
    socket: {
      async open(c) {
        c.data = { up: null, buf: [] };
        c.data.up = await Bun.connect({ hostname: f.host, port: f.port, socket: { data(_s, d) { c.write(d); }, close() { c.end(); }, error() { c.end(); } } }).catch(() => (c.end(), null));
        for (const b of c.data.buf) c.data.up?.write(b);
        c.data.buf = [];
      },
      data(c, d) { c.data.up ? c.data.up.write(d) : c.data.buf.push(new Uint8Array(d)); },
      close(c) { c.data.up?.end(); },
    },
  });
  log(`forward 127.0.0.1:${f.listen} -> ${f.host}:${f.port}`);
 }
}

function alive(): Promise<boolean> {
  if (!existsSync(sock)) return Promise.resolve(false);
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws+unix://${sock}:/rpc`);
    const t = setTimeout(() => { ws.close(); resolve(false); }, 3000);
    ws.onopen = () => { clearTimeout(t); ws.close(); resolve(true); };
    ws.onerror = () => { clearTimeout(t); resolve(false); };
  });
}

let child: ReturnType<typeof Bun.spawn> | null = null;
async function ensure() {
  if (await alive()) return;
  if (child && child.exitCode === null) return; // đang khởi động
  try { if (existsSync(sock)) unlinkSync(sock); } catch {}
  log(`khởi động codex app-server ở ${sock}`);
  child = Bun.spawn(["codex", "app-server", "--listen", `unix://${sock}`, ...cfg.codex.spawnArgs], { stdout: "inherit", stderr: "inherit", stdin: "ignore" });
}

await ensureForwards();
await ensure();
setInterval(() => { ensureForwards(); ensure(); }, 15000);
log("codex-shared đang giám sát");
