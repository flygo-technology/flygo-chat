// Chuỗi tổ tiên của kênh:
// - kênh bí mật lồng nhau: tên "s-<kênh cha>-<tin gốc>-…" hoặc mốc cũ "[flygo-sub parent=<kênh cha> root=<tin gốc trong kênh cha>]"
// - chat AI cột phải: tên "a-<nhóm gắn>-<user>-…" hoặc mốc cũ "[flygo-ai group=<nhóm gắn> owner=<user>]" (kênh riêng của một người với các bot của họ)
// Dùng chung cho runner (ngữ cảnh "đang ở đâu") và MCP flygo_chat (đọc các tầng trên).
import type { MM, Post } from "./mm";

export type LevelKind = "group" | "secret" | "ai";
export interface Level {
  tier: number; // 0 = nhóm gốc, N = kênh hiện tại
  id: string;
  name: string;
  kind: LevelKind; // group: nhóm thường (gốc); secret: luồng bí mật; ai: chat AI riêng gắn với kênh trên nó
  rootId: string; // tin gốc trong kênh cha mà kênh này tách ra ("" với nhóm gốc / chat AI)
  rootText: string;
}

export const MAX_TIERS = 10;
/** Kênh trên của `ch` (nếu có): luồng bí mật -> kênh cha; chat AI -> nhóm gắn. */
export function linkOf(ch: any): { parent: string; root: string; kind: "secret" | "ai" } | null {
  const sub = subOf(ch);
  if (sub) return { parent: sub.parent, root: sub.root, kind: "secret" };
  const ai = aiOf(ch);
  return ai ? { parent: ai.group, root: "", kind: "ai" } : null;
}
// App mới ghi quan hệ vào TÊN kỹ thuật của kênh (mô tả để trống cho người dùng); kênh cũ vẫn có mốc trong purpose.
// Đọc tên trước, không khớp thì đọc mốc cũ (giống lib/data/models.dart):
//   luồng bí mật  s-<kênh cha>-<tin gốc>-<ngẫu nhiên>   | [flygo-sub parent=… root=…]
//   chat AI       a-<nhóm gắn>-<chủ>-<ngẫu nhiên>       | [flygo-ai group=… owner=…]
//   dự án         p-<chủ>-<ngẫu nhiên>                  | [flygo-agent-project owner=…]
const SUB_NAME = /^s-([a-z0-9]{26})-([a-z0-9]{26})(?:-[a-z0-9]+)?$/;
const AI_NAME = /^a-([a-z0-9]{26})-([a-z0-9]{26})(?:-[a-z0-9]+)?$/;
const PROJECT_NAME = /^p-([a-z0-9]{26})(?:-[a-z0-9]+)?$/;
const rand32 = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => "abcdefghijklmnopqrstuvwxyz234567"[b & 31]).join("");
/** Tên kỹ thuật cho chat AI mới (runner tạo phiên họp). */
export const aiChannelName = (group: string, owner: string) => `a-${group}-${owner}-${rand32(4)}`;
/** Tên kỹ thuật cho dự án trợ lý mới (runner tạo dự án bằng project_create), giống app: p-<chủ>-<8 ký tự>. */
export const projectChannelName = (owner: string) => `p-${owner}-${rand32(8)}`;
/** Luồng bí mật: { parent, root } hoặc null. */
export function subOf(ch: any): { parent: string; root: string } | null {
  const n = SUB_NAME.exec(ch?.name ?? "");
  if (n) return { parent: n[1], root: n[2] };
  const m = /\[flygo-sub parent=(\w+)(?: root=(\w+))?/.exec(ch?.purpose ?? "");
  return m ? { parent: m[1], root: m[2] ?? "" } : null;
}
/** Chat AI cột phải: { group, owner } hoặc null. */
export function aiOf(ch: any): { group: string; owner: string } | null {
  const n = AI_NAME.exec(ch?.name ?? "");
  if (n) return { group: n[1], owner: n[2] };
  const m = /\[flygo-ai group=(\w+)(?: owner=(\w+))?/.exec(ch?.purpose ?? "");
  return m ? { group: m[1], owner: m[2] ?? "" } : null;
}
/** Kênh dự án trợ lý: id chủ dự án ("" nếu mốc cũ thiếu owner) hoặc null. */
export function projectOwnerOf(ch: any): string | null {
  const n = PROJECT_NAME.exec(ch?.name ?? "");
  if (n) return n[1];
  const m = /\[flygo-agent-project\b(?: owner=(\w+))?/.exec(ch?.purpose ?? "");
  return m ? m[1] ?? "" : null;
}

/** Từ nhóm gốc tới kênh `channelId` (phần tử cuối). Kênh thường: một phần tử. */
export async function ancestorChain(mm: MM, channelId: string, nameOf?: (ch: any) => Promise<string>): Promise<Level[]> {
  const name = async (ch: any) => (nameOf ? await nameOf(ch) : ch.display_name || ch.name);
  const out: Omit<Level, "tier">[] = [];
  let ch = await mm.channel(channelId);
  for (let i = 0; i <= MAX_TIERS && ch; i++) {
    const l = linkOf(ch);
    const rp = l?.root ? await mm.api<Post>("GET", `/posts/${l.root}`).catch(() => null) : null;
    out.unshift({ id: ch.id, name: await name(ch), kind: l?.kind ?? "group", rootId: l?.root ?? "", rootText: rp?.message ?? "" });
    if (!l || out.some((x) => x.id === l.parent)) break;
    ch = await mm.channel(l.parent).catch(() => null);
  }
  return out.map((x, tier) => ({ tier, ...x }));
}
