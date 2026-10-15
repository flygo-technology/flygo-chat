// Chuỗi tổ tiên của kênh:
// - kênh bí mật lồng nhau: mốc "[flygo-sub parent=<kênh cha> root=<tin gốc trong kênh cha>]"
// - chat AI cột phải: mốc "[flygo-ai group=<nhóm gắn> owner=<user>]" (kênh riêng của một người với các bot của họ)
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
  const p = ch?.purpose ?? "";
  let m = /\[flygo-sub parent=(\w+)(?: root=(\w+))?/.exec(p);
  if (m) return { parent: m[1], root: m[2] ?? "", kind: "secret" };
  m = /\[flygo-ai group=(\w+)/.exec(p);
  return m ? { parent: m[1], root: "", kind: "ai" } : null;
}
/** Chat AI cột phải: { group, owner } hoặc null. */
export function aiOf(ch: any): { group: string; owner: string } | null {
  const m = /\[flygo-ai group=(\w+)(?: owner=(\w+))?/.exec(ch?.purpose ?? "");
  return m ? { group: m[1], owner: m[2] ?? "" } : null;
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
