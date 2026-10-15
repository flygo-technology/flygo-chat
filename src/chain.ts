// Chuỗi tổ tiên của kênh bí mật lồng nhau: kênh bí mật mang mốc "[flygo-sub parent=<kênh cha> root=<tin gốc trong kênh cha>]".
// Dùng chung cho runner (ngữ cảnh "đang ở tầng mấy") và MCP flygo_chat (đọc các tầng trên).
import type { MM, Post } from "./mm";

export interface Level {
  tier: number; // 0 = nhóm gốc, N = kênh hiện tại
  id: string;
  name: string;
  rootId: string; // tin gốc trong kênh cha mà kênh này tách ra ("" với nhóm gốc)
  rootText: string;
}

export const MAX_TIERS = 10;
const subOf = (ch: any) => /\[flygo-sub parent=(\w+)(?: root=(\w+))?/.exec(ch?.purpose ?? "");

/** Từ nhóm gốc tới kênh `channelId` (phần tử cuối). Kênh thường: một phần tử. */
export async function ancestorChain(mm: MM, channelId: string, nameOf?: (ch: any) => Promise<string>): Promise<Level[]> {
  const name = async (ch: any) => (nameOf ? await nameOf(ch) : ch.display_name || ch.name);
  const out: Omit<Level, "tier">[] = [];
  let ch = await mm.channel(channelId);
  for (let i = 0; i <= MAX_TIERS && ch; i++) {
    const m = subOf(ch);
    const rp = m?.[2] ? await mm.api<Post>("GET", `/posts/${m[2]}`).catch(() => null) : null;
    out.unshift({ id: ch.id, name: await name(ch), rootId: m?.[2] ?? "", rootText: rp?.message ?? "" });
    if (!m || out.some((x) => x.id === m[1])) break;
    ch = await mm.channel(m[1]).catch(() => null);
  }
  return out.map((x, tier) => ({ tier, ...x }));
}
