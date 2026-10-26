// Client tối giản cho plugin Boards (id `focalboard`) của máy chủ chat: bảng, thành viên, thẻ (card), bình luận.
// API: `/plugins/focalboard/api/v2/…`, cần header X-Requested-With như webapp. Thẻ là block type "card":
// properties = { <id thuộc tính>: chuỗi | mảng chuỗi }; cardProperties của bảng mô tả kiểu (select / multiPerson / person / date…).
// Lưu ý: PATCH /cards/{id} với updatedProperties THAY CẢ bộ properties -> luôn gửi đủ (gộp ở client).

export interface PropOption { id: string; value: string; color?: string }
export interface PropTemplate { id: string; name: string; type: string; options?: PropOption[] }
export interface Board {
  id: string; teamId: string; channelId: string; type: "O" | "P"; minimumRole: string; title: string; description: string; icon: string;
  isTemplate: boolean; cardProperties: PropTemplate[]; createdBy: string; deleteAt: number; properties?: Record<string, any>;
}
export interface Card {
  id: string; boardId: string; title: string; icon: string; properties: Record<string, string | string[]>;
  contentOrder: string[]; createdBy: string; createAt: number; updateAt: number; deleteAt: number; isTemplate: boolean;
}
export interface Member { boardId: string; userId: string; schemeAdmin: boolean; schemeEditor: boolean; schemeCommenter: boolean; schemeViewer: boolean; synthetic?: boolean }

const B32 = "ybndrfg8ejkmcpqxot1uwisza345h769";
/** id kiểu máy chủ chat (26 ký tự base32) với tiền tố loại của Boards (a = block, c = card, v = view). */
export const newId = (prefix = "a") => prefix + Array.from(crypto.getRandomValues(new Uint8Array(26)), (b) => B32[b & 31]).join("");

/** Trạng thái mặc định của bảng việc mới. */
export const DEFAULT_STATUSES: [string, string][] = [["Chưa làm", "propColorGray"], ["Đang làm", "propColorBlue"], ["Chờ duyệt", "propColorYellow"], ["Xong", "propColorGreen"]];
export const DEFAULT_PRIORITIES: [string, string][] = [["Cao", "propColorRed"], ["Trung bình", "propColorYellow"], ["Thấp", "propColorGray"]];

const norm = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/đ/g, "d").replace(/Đ/g, "D").toLowerCase().trim();

/** Thuộc tính trạng thái: select tên "status / trạng thái", không có thì select đầu tiên (bảng mới của webapp có sẵn "Status"). */
export function statusProp(b: Board): PropTemplate | undefined {
  const sel = b.cardProperties.filter((p) => p.type === "select");
  return sel.find((p) => /status|trang thai|tinh trang/.test(norm(p.name))) ?? sel.find((p) => !/priority|uu tien/.test(norm(p.name)));
}
export function priorityProp(b: Board): PropTemplate | undefined {
  return b.cardProperties.find((p) => p.type === "select" && /priority|uu tien|muc do/.test(norm(p.name)));
}
/** Thuộc tính người làm: multiPerson trước, rồi person (bỏ qua "người giao / reporter"). */
export function assigneeProp(b: Board): PropTemplate | undefined {
  const ppl = b.cardProperties.filter((p) => p.type === "multiPerson" || p.type === "person");
  const notReporter = ppl.filter((p) => !/giao|reporter|requester|owner/.test(norm(p.name)));
  return notReporter.find((p) => p.type === "multiPerson") ?? notReporter[0] ?? ppl[0];
}
export function dueProp(b: Board): PropTemplate | undefined {
  const ds = b.cardProperties.filter((p) => p.type === "date");
  return ds.find((p) => /due|han|deadline|ngay/.test(norm(p.name))) ?? ds[0];
}
/** Mọi người có trong các thuộc tính person / multiPerson của thẻ. */
export function peopleOf(b: Board, c: Card): string[] {
  const out = new Set<string>();
  for (const p of b.cardProperties) {
    if (p.type !== "person" && p.type !== "multiPerson") continue;
    const v = c.properties[p.id];
    for (const id of Array.isArray(v) ? v : v ? [v] : []) out.add(id);
  }
  return [...out];
}
/** Ngày của thuộc tính date: chuỗi JSON {"from": ms}; ngày không kèm giờ lưu ở 00:00 UTC của ngày đó. */
export function dateOf(v: unknown): number | null {
  if (typeof v !== "string" || !v) return null;
  try { const j = JSON.parse(v); return typeof j.from === "number" ? j.from : typeof j.to === "number" ? j.to : null; } catch { return null; }
}
/** "2026-10-30" (hoặc ISO có giờ) -> giá trị thuộc tính date (00:00 UTC của ngày, như webapp). */
export function dateValue(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso.trim());
  if (!m) throw new Error(`Ngày không hợp lệ: ${iso} (dùng YYYY-MM-DD)`);
  return JSON.stringify({ from: Date.UTC(+m[1], +m[2] - 1, +m[3]) });
}
export const optionValue = (p: PropTemplate | undefined, id: unknown) => p?.options?.find((o) => o.id === id)?.value ?? "";
/** Tìm phương án select theo tên (không phân biệt dấu / hoa thường) hoặc id. */
export function findOption(p: PropTemplate | undefined, q: string): PropOption | undefined {
  if (!p) return undefined;
  const k = norm(q);
  return p.options?.find((o) => o.id === q) ?? p.options?.find((o) => norm(o.value) === k) ?? p.options?.find((o) => norm(o.value).includes(k));
}
/** Phương án "xong" của trạng thái (để lọc việc quá hạn / chưa xong). */
export const isDoneOption = (v: string) => /^(xong|hoan thanh|da xong|done|completed?|closed|finished)$/.test(norm(v));

export class Boards {
  constructor(private url: string, private token: string) {}

  async req<T = any>(method: string, path: string, body?: any): Promise<T> {
    const r = await fetch(`${this.url.replace(/\/+$/, "")}/plugins/focalboard/api/v2${path}`, {
      method,
      headers: { Authorization: `Bearer ${this.token}`, "X-Requested-With": "XMLHttpRequest", "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
    if (r.status === 404 && path === "/teams") throw new Error("Máy chủ chưa bật plugin Boards.");
    if (!r.ok) {
      const t = await r.text();
      let msg = t;
      try { msg = JSON.parse(t).error ?? t; } catch {}
      throw new Error(`Boards ${method} ${path} -> ${r.status} ${String(msg).slice(0, 300)}`);
    }
    const t = await r.text();
    return (t ? JSON.parse(t) : undefined) as T;
  }

  /** Bảng của team mà người dùng (bot) thấy: bảng mở của team + bảng mình là thành viên. */
  async teamBoards(teamId: string): Promise<Board[]> {
    const bs = await this.req<Board[]>("GET", `/teams/${teamId}/boards`);
    return (bs ?? []).filter((b) => !b.isTemplate && !b.deleteAt);
  }
  board(id: string) { return this.req<Board>("GET", `/boards/${id}`); }
  members(boardId: string) { return this.req<Member[]>("GET", `/boards/${boardId}/members`); }
  /** Bảng mình là thành viên thật (không tính quyền "ảo" của bảng mở). */
  async myBoardIds(): Promise<Set<string>> {
    const ms = await this.req<Member[]>("GET", "/users/me/memberships");
    return new Set((ms ?? []).filter((m) => !m.synthetic).map((m) => m.boardId));
  }
  async cards(boardId: string): Promise<Card[]> {
    const out: Card[] = [];
    for (let page = 0; page < 50; page++) {
      const r = await this.req<Card[]>("GET", `/boards/${boardId}/cards?page=${page}&per_page=100`);
      out.push(...(r ?? []));
      if (!r || r.length < 100) break;
    }
    return out.filter((c) => !c.deleteAt && !c.isTemplate);
  }
  card(id: string) { return this.req<Card>("GET", `/cards/${id}`); }
  async views(boardId: string): Promise<{ id: string; title: string; fields: any }[]> {
    return (await this.req<any[]>("GET", `/boards/${boardId}/blocks?type=view`)) ?? [];
  }

  /** Tạo bảng việc: mở cho cả team (type O, ai trong team cũng vào và sửa được), có sẵn Trạng thái / Người làm / Hạn / Ưu tiên
   *  và một view Kanban nhóm theo trạng thái. Người tạo là quản trị bảng. */
  async createBoard(teamId: string, title: string, opts: { channelId?: string; description?: string; icon?: string; properties?: Record<string, any> } = {}): Promise<{ board: Board; viewId: string }> {
    const opt = (list: [string, string][]) => list.map(([value, color]) => ({ id: newId(), value, color }));
    const status: PropTemplate = { id: newId(), name: "Trạng thái", type: "select", options: opt(DEFAULT_STATUSES) };
    const props: PropTemplate[] = [
      status,
      { id: newId(), name: "Người làm", type: "multiPerson", options: [] },
      { id: newId(), name: "Hạn", type: "date", options: [] },
      { id: newId(), name: "Ưu tiên", type: "select", options: opt(DEFAULT_PRIORITIES) },
    ];
    const now = Date.now();
    const board = await this.req<Board>("POST", "/boards", {
      teamId, channelId: opts.channelId ?? "", type: "O", minimumRole: "editor", title, description: opts.description ?? "", icon: opts.icon ?? "📋",
      showDescription: false, isTemplate: false, templateVersion: 0, properties: opts.properties ?? {}, cardProperties: props, createAt: now, updateAt: now, deleteAt: 0,
    });
    const view = {
      id: newId("v"), boardId: board.id, parentId: board.id, schema: 1, type: "view", title: "Kanban", createAt: now, updateAt: now, deleteAt: 0, limited: false,
      fields: {
        viewType: "board", groupById: status.id, sortOptions: [], visiblePropertyIds: props.slice(1).map((p) => p.id), visibleOptionIds: [], hiddenOptionIds: [],
        collapsedOptionIds: [], filter: { operation: "and", filters: [] }, cardOrder: [], columnWidths: {}, columnCalculations: {}, kanbanCalculations: {}, defaultTemplateId: "",
      },
    };
    const vs = await this.req<any[]>("POST", `/boards/${board.id}/blocks`, [view]);
    return { board, viewId: vs?.[0]?.id ?? "" };
  }

  /** Thêm thành viên (quyền sửa thẻ). Đã là thành viên thì bỏ qua. */
  async addMember(boardId: string, userId: string) {
    return this.req<Member>("POST", `/boards/${boardId}/members`, { boardId, userId, schemeEditor: true, schemeAdmin: false, schemeCommenter: false, schemeViewer: false });
  }

  async createCard(boardId: string, title: string, properties: Record<string, string | string[]>, icon = ""): Promise<Card> {
    const now = Date.now();
    return this.req<Card>("POST", `/boards/${boardId}/cards`, { boardId, title, icon, properties, contentOrder: [], isTemplate: false, createAt: now, updateAt: now, deleteAt: 0 });
  }
  /** Sửa thẻ: properties là BỘ ĐẦY ĐỦ sau khi sửa (API thay cả bộ). */
  patchCard(cardId: string, patch: { title?: string; properties?: Record<string, string | string[]>; contentOrder?: string[] }) {
    const body: any = {};
    if (patch.title !== undefined) body.title = patch.title;
    if (patch.properties) body.updatedProperties = patch.properties;
    if (patch.contentOrder) body.contentOrder = patch.contentOrder;
    return this.req<Card>("PATCH", `/cards/${cardId}`, body);
  }
  /** Mô tả của thẻ: khối text (markdown) gắn vào thẻ và thêm vào contentOrder. */
  async addDescription(card: Card, text: string) {
    const now = Date.now();
    const [b] = await this.req<any[]>("POST", `/boards/${card.boardId}/blocks`, [{
      id: newId(), boardId: card.boardId, parentId: card.id, schema: 1, type: "text", title: text, fields: {}, createAt: now, updateAt: now, deleteAt: 0, limited: false,
    }]);
    if (b?.id) await this.patchCard(card.id, { contentOrder: [...(card.contentOrder ?? []), b.id] });
  }
  async addComment(card: Card, text: string) {
    const now = Date.now();
    await this.req("POST", `/boards/${card.boardId}/blocks`, [{
      id: newId(), boardId: card.boardId, parentId: card.id, schema: 1, type: "comment", title: text, fields: {}, createAt: now, updateAt: now, deleteAt: 0, limited: false,
    }]);
  }
  deleteBoard(boardId: string) { return this.req("DELETE", `/boards/${boardId}`); }

  /** Link mở thẻ trên giao diện web Boards (đường dẫn thẻ cần id view; bảng chưa có view thì chỉ mở bảng). */
  cardUrl(teamId: string, boardId: string, viewId: string, cardId?: string) {
    return `${this.url.replace(/\/+$/, "")}/boards/team/${teamId}/${boardId}${viewId ? `/${viewId}${cardId ? `/${cardId}` : ""}` : ""}`;
  }
}
