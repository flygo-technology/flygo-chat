// Tool giao việc trên Boards cho agent (MCP flygo_chat): task_boards, task_list (đọc) · task_create, task_update (ghi).
// Mọi thao tác bằng token của bot trên cùng máy chủ chat, nên chỉ thấy / sửa được bảng bot thấy: bảng mở của team
// (ai trong team cũng vào được) và bảng bot là thành viên. Tool ghi xin người giao việc duyệt qua runner (/approve) trước khi
// làm — cùng một bước duyệt cho cả Claude lẫn Codex; "luôn cho phép" của phiên thì tự duyệt.
import { Boards, assigneeProp, dateOf, dateValue, dueProp, findOption, isDoneOption, optionValue, peopleOf, priorityProp, statusProp, type Board, type Card } from "./boards";
import type { MM } from "./mm";

export interface TaskCtx {
  mm: MM;
  boards: Boards;
  /** Kênh của lượt (mặc định cho channel_id). */
  channel: string;
  /** Người giao việc của lượt (được thêm vào bảng mới cùng người được giao). */
  requester: string;
  /** Xin duyệt một thao tác ghi; trả về true nếu được phép. */
  approve: (tool: string, input: any) => Promise<boolean>;
}

const ID = { type: "string" };
export const TASK_TOOLS = [
  {
    name: "task_boards",
    description: "Liệt kê các bảng việc (Boards) bot thấy trong team: bảng mở của team và bảng bot là thành viên. channel_id: chỉ bảng gắn với kênh đó (bỏ trống = tất cả, đánh dấu bảng của kênh hiện tại).",
    inputSchema: { type: "object", properties: { channel_id: ID } },
  },
  {
    name: "task_list",
    description: "Liệt kê việc (thẻ) trên Boards: của một bảng (board_id) hoặc mọi bảng bot thấy; lọc theo người làm (assignee = username, \"me\" = người giao việc), trạng thái (status = tên phương án), chỉ việc quá hạn (overdue). Mặc định bỏ việc đã xong (include_done=true để lấy cả). Mỗi việc kèm id thẻ và link mở thẻ.",
    inputSchema: {
      type: "object",
      properties: {
        board_id: ID, assignee: { type: "string", description: "username (không cần @) hoặc \"me\"" }, status: { type: "string" },
        overdue: { type: "boolean" }, include_done: { type: "boolean" }, limit: { type: "number", description: "tối đa (mặc định 50)" },
      },
    },
  },
  {
    name: "task_create",
    description: "GIAO VIỆC: tạo một thẻ việc trên Boards rồi trả link thẻ (gửi link vào chat cho mọi người). Bảng: board_id; hoặc bảng gắn với channel_id (mặc định kênh hiện tại) — chưa có thì tự tạo bảng mới mở cho cả team (tên board_title, mặc định \"Việc · <tên kênh>\") cho kênh đó. Người được giao (username) và người giao việc được thêm làm thành viên bảng để thấy việc. due: ngày YYYY-MM-DD. status / priority: tên phương án có trên bảng (bảng mới: Chưa làm / Đang làm / Chờ duyệt / Xong; ưu tiên Cao / Trung bình / Thấp). Cần người giao việc duyệt.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" }, description: { type: "string", description: "mô tả (markdown, tuỳ chọn)" },
        board_id: ID, channel_id: ID, board_title: { type: "string" },
        assignees: { type: "array", items: { type: "string" }, description: "username người làm" },
        due: { type: "string", description: "YYYY-MM-DD" }, status: { type: "string" }, priority: { type: "string" },
      },
      required: ["title"],
    },
  },
  {
    name: "task_update",
    description: "Sửa một việc trên Boards (card_id lấy từ task_list / link thẻ): đổi tiêu đề, trạng thái, hạn (due YYYY-MM-DD, \"\" = bỏ hạn), ưu tiên, người làm (assignees = thay cả danh sách; add_assignees / remove_assignees = thêm / bớt), thêm bình luận (comment). Trả link thẻ. Cần người giao việc duyệt.",
    inputSchema: {
      type: "object",
      properties: {
        card_id: ID, title: { type: "string" }, status: { type: "string" }, due: { type: "string" }, priority: { type: "string" },
        assignees: { type: "array", items: { type: "string" } }, add_assignees: { type: "array", items: { type: "string" } },
        remove_assignees: { type: "array", items: { type: "string" } }, comment: { type: "string" },
      },
      required: ["card_id"],
    },
  },
];
export const TASK_TOOL_NAMES = new Set(TASK_TOOLS.map((t) => t.name));

/** Kênh của bảng: kênh gắn sẵn của Boards, hoặc kênh ghi trong properties.flygo_channel (bảng do task_create tạo). */
const boardChannel = (b: Board) => b.channelId || String(b.properties?.flygo_channel ?? "");
const todayUtc = () => { const d = new Date(); return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()); };
const isoDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export async function taskTool(name: string, a: any, ctx: TaskCtx): Promise<string> {
  const { mm, boards } = ctx;
  const meId = (await mm.me()).id as string;

  // ---- team, người dùng, bảng ----
  async function teamOf(channelId?: string): Promise<string> {
    const ch = channelId ? await mm.channel(channelId).catch(() => null) : null;
    if (ch?.team_id) return ch.team_id;
    const teams = await mm.api<any[]>("GET", "/users/me/teams");
    if (!teams.length) throw new Error("Bot chưa ở trong team nào.");
    return teams[0].id;
  }
  const userIdOf = async (u: string): Promise<string> => {
    const k = String(u ?? "").trim().replace(/^@/, "");
    if (!k) throw new Error("Thiếu username.");
    if (k === "me" || k === "tôi") return ctx.requester || meId;
    if (/^[a-z0-9]{26}$/.test(k)) return k;
    const usr = await mm.api<any>("GET", `/users/username/${encodeURIComponent(k.toLowerCase())}`).catch(() => null);
    if (!usr?.id) throw new Error(`Không tìm thấy người dùng @${k}.`);
    return usr.id;
  };
  const uname = async (id: string) => { const u = await mm.user(id); return `@${u.username ?? id}`; };
  const viewCache = new Map<string, string>();
  const viewOf = async (boardId: string) => {
    if (!viewCache.has(boardId)) viewCache.set(boardId, (await boards.views(boardId).catch(() => []))[0]?.id ?? "");
    return viewCache.get(boardId)!;
  };
  const link = async (b: Board, cardId?: string) => boards.cardUrl(b.teamId, b.id, await viewOf(b.id), cardId);
  /** Bảng bot được phép ghi: bot là thành viên thật, hoặc bảng mở của team (quyền theo vai tối thiểu của bảng). */
  async function writable(b: Board) {
    if (b.type === "O") return;
    if ((await boards.myBoardIds()).has(b.id)) return;
    throw new Error(`Bot không phải thành viên của bảng "${b.title}" nên không sửa được. Nhờ quản trị bảng thêm bot vào bảng.`);
  }
  async function visibleBoard(boardId: string): Promise<Board> {
    const b = await boards.board(boardId).catch(() => null);
    if (!b || b.deleteAt) throw new Error(`Không thấy bảng ${boardId} (đã xoá hoặc bot không có quyền xem).`);
    return b;
  }
  async function describe(b: Board, c: Card): Promise<string> {
    const st = statusProp(b), pr = priorityProp(b), du = dueProp(b), as = assigneeProp(b);
    const who = as ? (Array.isArray(c.properties[as.id]) ? c.properties[as.id] as string[] : c.properties[as.id] ? [String(c.properties[as.id])] : []) : peopleOf(b, c);
    const due = dateOf(c.properties[du?.id ?? ""]);
    const status = optionValue(st, c.properties[st?.id ?? ""]);
    const late = due !== null && due < todayUtc() && !isDoneOption(status);
    return [
      `- ${status ? `[${status}] ` : ""}${c.title || "(không tiêu đề)"}`,
      who.length ? `người làm: ${(await Promise.all(who.map(uname))).join(", ")}` : "",
      due !== null ? `hạn ${isoDay(due)}${late ? " (QUÁ HẠN)" : ""}` : "",
      optionValue(pr, c.properties[pr?.id ?? ""]) ? `ưu tiên ${optionValue(pr, c.properties[pr?.id ?? ""])}` : "",
      `bảng "${b.title}"`, `id ${c.id}`, await link(b, c.id),
    ].filter(Boolean).join(" — ");
  }
  async function addMembers(b: Board, ids: string[]): Promise<string[]> {
    const have = new Set((await boards.members(b.id).catch(() => [])).filter((m) => !m.synthetic).map((m) => m.userId));
    const notes: string[] = [];
    for (const id of [...new Set(ids)].filter((x) => x && !have.has(x))) {
      await boards.addMember(b.id, id).catch(async (e) => notes.push(`không thêm được ${await uname(id)} vào bảng: ${e.message ?? e}`));
    }
    return notes;
  }
  const setPeople = (b: Board, props: Record<string, any>, ids: string[]) => {
    const as = assigneeProp(b);
    if (!as) throw new Error(`Bảng "${b.title}" không có cột người làm (person / multiPerson).`);
    props[as.id] = as.type === "multiPerson" ? [...new Set(ids)] : ids[0] ?? "";
  };
  const setOption = (b: Board, props: Record<string, any>, kind: "status" | "priority", q: string) => {
    const p = kind === "status" ? statusProp(b) : priorityProp(b);
    if (!p) throw new Error(`Bảng "${b.title}" không có cột ${kind === "status" ? "trạng thái" : "ưu tiên"}.`);
    const o = findOption(p, q);
    if (!o) throw new Error(`"${q}" không có trong ${p.name}: ${(p.options ?? []).map((x) => x.value).join(", ")}.`);
    props[p.id] = o.id;
  };

  switch (name) {
    case "task_boards": {
      const team = await teamOf(a.channel_id || ctx.channel);
      const mine = await boards.myBoardIds();
      let list = await boards.teamBoards(team);
      if (a.channel_id) list = list.filter((b) => boardChannel(b) === a.channel_id);
      if (!list.length) return a.channel_id ? "Kênh này chưa có bảng việc nào (task_create sẽ tự tạo)." : "Team chưa có bảng việc nào bot thấy (task_create sẽ tự tạo).";
      const out = await Promise.all(list.map(async (b) => `- ${b.icon ? `${b.icon} ` : ""}${b.title} — id ${b.id} — ${b.type === "O" ? "mở cho cả team" : "riêng tư"}${mine.has(b.id) ? " · bot là thành viên" : ""}${boardChannel(b) ? ` · của kênh ${boardChannel(b)}${boardChannel(b) === ctx.channel ? " (kênh hiện tại)" : ""}` : ""} — ${await link(b)}`));
      return out.join("\n");
    }
    case "task_list": {
      const limit = Math.max(1, Math.min(200, Number(a.limit) || 50));
      const list = a.board_id ? [await visibleBoard(a.board_id)] : await boards.teamBoards(await teamOf(ctx.channel));
      const who = a.assignee ? await userIdOf(a.assignee) : "";
      const rows: { b: Board; c: Card; due: number | null }[] = [];
      for (const b of list) {
        const cards = await boards.cards(b.id).catch(() => [] as Card[]);
        const st = statusProp(b), du = dueProp(b);
        for (const c of cards) {
          const status = optionValue(st, c.properties[st?.id ?? ""]);
          const due = dateOf(c.properties[du?.id ?? ""]);
          if (who && !peopleOf(b, c).includes(who)) continue;
          if (a.status && findOption(st, String(a.status))?.id !== c.properties[st?.id ?? ""]) continue;
          if (!a.status && !a.include_done && isDoneOption(status)) continue;
          if (a.overdue && !(due !== null && due < todayUtc() && !isDoneOption(status))) continue;
          rows.push({ b, c, due });
        }
      }
      if (!rows.length) return "Không có việc nào khớp.";
      rows.sort((x, y) => (x.due ?? Infinity) - (y.due ?? Infinity) || y.c.updateAt - x.c.updateAt);
      const lines = await Promise.all(rows.slice(0, limit).map((r) => describe(r.b, r.c)));
      return [`${rows.length} việc${rows.length > limit ? ` (hiện ${limit})` : ""}:`, ...lines].join("\n");
    }
    case "task_create": {
      const title = String(a.title ?? "").trim();
      if (!title) return "Thiếu title.";
      const assignees = await Promise.all(((a.assignees ?? []) as string[]).map(userIdOf));
      if (a.due) dateValue(String(a.due)); // kiểm tra ngày trước khi xin duyệt
      // Bảng đích: board_id, hoặc bảng gắn với kênh (chưa có thì tạo).
      const channelId = String(a.channel_id || ctx.channel || "");
      let board: Board | undefined = a.board_id ? await visibleBoard(a.board_id) : undefined;
      let created = false;
      if (!board) {
        const team = await teamOf(channelId);
        board = channelId ? (await boards.teamBoards(team)).find((b) => boardChannel(b) === channelId) : undefined;
        if (!board) {
          const ch = channelId ? await mm.channel(channelId).catch(() => null) : null;
          const chName = ch && (ch.type === "O" || ch.type === "P") ? String(ch.display_name || ch.name || "") : "";
          const boardTitle = String(a.board_title || (chName ? `Việc · ${chName}` : "Việc chung"));
          if (!(await ctx.approve("task_create", { ...a, board: `(bảng mới, mở cho cả team) ${boardTitle}` }))) return "Người giao việc không duyệt tạo việc.";
          // Không gắn channelId của Boards (bảng gắn kênh riêng tư có thể chỉ thành viên kênh vào được): ghi kênh vào
          // properties.flygo_channel để lần sau tìm lại, bảng vẫn mở cho cả team.
          board = (await boards.createBoard(team, boardTitle, { properties: channelId ? { flygo_channel: channelId } : {} })).board;
          created = true;
        }
      }
      await writable(board);
      if (!created && !(await ctx.approve("task_create", { ...a, board: board.title }))) return "Người giao việc không duyệt tạo việc.";
      const props: Record<string, any> = {};
      const st = statusProp(board);
      if (a.status) setOption(board, props, "status", String(a.status));
      else if (st?.options?.length) props[st.id] = st.options[0].id;
      if (a.priority) setOption(board, props, "priority", String(a.priority));
      if (assignees.length) setPeople(board, props, assignees);
      if (a.due) { const du = dueProp(board); if (!du) throw new Error(`Bảng "${board.title}" không có cột hạn (date).`); props[du.id] = dateValue(String(a.due)); }
      const notes = await addMembers(board, [...assignees, ctx.requester]);
      const card = await boards.createCard(board.id, title, props);
      if (a.description) await boards.addDescription(card, String(a.description));
      return [
        `Đã tạo việc${created ? ` trên bảng mới "${board.title}" (mở cho cả team)` : ` trên bảng "${board.title}"`}:`,
        await describe(board, card),
        `Link thẻ (gửi vào chat): ${await link(board, card.id)}`,
        ...notes.map((n) => `Lưu ý: ${n}`),
      ].join("\n");
    }
    case "task_update": {
      const card = await boards.card(String(a.card_id ?? "")).catch(() => null);
      if (!card || card.deleteAt) return `Không thấy việc ${a.card_id} (đã xoá hoặc bot không có quyền xem).`;
      const board = await visibleBoard(card.boardId);
      await writable(board);
      const props: Record<string, any> = { ...card.properties };
      if (a.status) setOption(board, props, "status", String(a.status));
      if (a.priority) setOption(board, props, "priority", String(a.priority));
      if (a.due !== undefined) {
        const du = dueProp(board);
        if (!du) throw new Error(`Bảng "${board.title}" không có cột hạn (date).`);
        if (String(a.due).trim()) props[du.id] = dateValue(String(a.due)); else delete props[du.id];
      }
      const added: string[] = [];
      if (a.assignees || a.add_assignees || a.remove_assignees) {
        const as = assigneeProp(board);
        const cur = as ? (Array.isArray(props[as.id]) ? props[as.id] as string[] : props[as.id] ? [String(props[as.id])] : []) : [];
        const repl = a.assignees ? await Promise.all((a.assignees as string[]).map(userIdOf)) : cur;
        const add = await Promise.all(((a.add_assignees ?? []) as string[]).map(userIdOf));
        const rm = new Set(await Promise.all(((a.remove_assignees ?? []) as string[]).map(userIdOf)));
        const next = [...repl, ...add].filter((x) => !rm.has(x));
        added.push(...next.filter((x) => !cur.includes(x)));
        setPeople(board, props, next);
      }
      const changes = a.title || a.status || a.priority || a.due !== undefined || a.assignees || a.add_assignees || a.remove_assignees;
      if (!changes && !a.comment) return "Không có gì để sửa.";
      if (!(await ctx.approve("task_update", { ...a, card: card.title, board: board.title }))) return "Người giao việc không duyệt sửa việc.";
      const notes = added.length ? await addMembers(board, added) : [];
      const next = changes ? await boards.patchCard(card.id, { ...(a.title ? { title: String(a.title) } : {}), properties: props }) : card;
      if (a.comment) await boards.addComment(next, String(a.comment));
      return [`Đã cập nhật việc${a.comment ? " (kèm bình luận)" : ""}:`, await describe(board, next), ...notes.map((n) => `Lưu ý: ${n}`)].join("\n");
    }
  }
  throw new Error(`tool không tồn tại: ${name}`);
}
