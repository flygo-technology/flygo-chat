// Tệp trong A2A (FilePart): nhỏ -> bytes base64 ngay trong message; lớn -> tải lên máy chủ chat (upload session, từng khúc)
// rồi xin relay cấp URL ngắn hạn chỉ agent nhận tải được (/a2a/files/<id>).
import { mkdirSync, realpathSync, statSync } from "node:fs";
import { basename, join, resolve, sep } from "node:path";
import type { A2AClient } from "./a2a";
import type { MM } from "./mm";

export const INLINE_MAX = 5 * 1024 * 1024;
const MAX_FILE = 100 * 1024 * 1024;
const CHUNK = 5 * 1024 * 1024; // máy chủ chat: mỗi khúc (trừ khúc cuối) ≥ 5MB; khúc nhỏ nhất có thể vì Cloudflare cắt request quá 100 giây

const safeName = (n: string) => (n || "file").replace(/[^\p{L}\p{N}._ -]/gu, "_").slice(0, 120);

/** Đường dẫn tệp phải nằm trong thư mục làm việc; trả về realpath. */
export function insideDir(dir: string, p: string): string {
  const root = realpathSync(dir);
  const real = realpathSync(resolve(dir, p));
  if (real !== root && !real.startsWith(root + sep)) throw new Error(`${p} nằm ngoài thư mục làm việc`);
  if (!statSync(real).isFile()) throw new Error(`${p} không phải tệp`);
  return real;
}

export async function uploadLarge(mm: MM, token: string, channelId: string, path: string): Promise<string> {
  const f = Bun.file(path);
  const us = await mm.api<any>("POST", "/uploads", { channel_id: channelId, filename: basename(path), file_size: f.size });
  let off = 0, fails = 0;
  for (;;) {
    const end = Math.min(off + CHUNK, f.size);
    const r = await fetch(`${mm.url}/api/v4/uploads/${us.id}`, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/octet-stream" }, body: await f.slice(off, end).arrayBuffer(), signal: AbortSignal.timeout(90_000) }).catch((e) => e as Error);
    if (r instanceof Error || !r.ok) {
      // Lỗi giữa chừng: hỏi server đã nhận tới đâu rồi tải tiếp từ đó.
      if (++fails > 5) throw new Error(`tải lên lỗi ${r instanceof Error ? r.message : `${r.status} ${(await r.text()).slice(0, 200)}`}`);
      const st = await mm.api<any>("GET", `/uploads/${us.id}`).catch(() => null);
      if (st) off = Number(st.file_offset) || 0;
      continue;
    }
    off = end;
    if (r.status !== 204) { const info = await r.json().catch(() => null); if (info?.id) return info.id; }
    if (off >= f.size) throw new Error("tải lên không trả về tệp");
  }
}

/** FilePart cho tệp `path` gửi tới agent `toId`. Tệp lớn tải lên kênh `uploadChannel`. */
export async function toFilePart(a2a: A2AClient, mm: MM, token: string, uploadChannel: () => Promise<string>, path: string, toId: string) {
  const f = Bun.file(path);
  const name = basename(path), mimeType = f.type || "application/octet-stream";
  if (f.size > MAX_FILE) throw new Error(`${name}: ${f.size}B vượt giới hạn 100MB`);
  if (f.size <= INLINE_MAX) return { kind: "file", file: { name, mimeType, bytes: Buffer.from(await f.arrayBuffer()).toString("base64") } };
  const fileId = await uploadLarge(mm, token, await uploadChannel(), path);
  const g = await a2a.grant(fileId, toId);
  return { kind: "file", file: { name, mimeType, uri: g.uri }, metadata: { size: f.size } };
}

/** Lưu FilePart nhận được vào `dir`; URI chỉ chấp nhận URL tệp của relay (tải bằng token bot). */
export async function saveFilePart(file: any, dir: string, relayBase: string, auth: Record<string, string>): Promise<string> {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, safeName(file?.name ?? "file"));
  if (typeof file?.bytes === "string") {
    const buf = Buffer.from(file.bytes, "base64");
    if (buf.length > MAX_FILE) throw new Error("tệp quá lớn");
    await Bun.write(path, buf);
    return path;
  }
  const uri = String(file?.uri ?? "");
  if (!uri.startsWith(`${relayBase}/files/`)) throw new Error(`không tải tệp từ nguồn lạ: ${uri.slice(0, 80)}`);
  const r = await fetch(uri, { headers: auth });
  if (!r.ok) throw new Error(`tải tệp lỗi ${r.status}`);
  if (Number(r.headers.get("content-length") ?? 0) > MAX_FILE) throw new Error("tệp quá lớn");
  await Bun.write(path, r);
  return path;
}

/** Ghép các phần text / data / file của message hoặc artifact. */
export function splitParts(parts: any[]) {
  const texts: string[] = [], datas: any[] = [], files: any[] = [];
  for (const p of parts ?? []) {
    const kind = p?.kind ?? (p?.text !== undefined ? "text" : p?.data !== undefined ? "data" : p?.file ? "file" : "");
    if (kind === "text") texts.push(String(p.text ?? ""));
    else if (kind === "data") datas.push(p.data);
    else if (kind === "file") files.push(p.file);
  }
  return { texts, datas, files };
}
