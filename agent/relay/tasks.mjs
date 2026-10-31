// Nhắc việc của Flygo Chat (chạy trong trạm đẩy, cạnh retention.mjs): theo dõi bảng việc (plugin Boards) bằng token quản trị
// và nhắn tin riêng từ một bot thông báo (KHÔNG phải trợ lý AI cá nhân) — máy chủ chat tự đẩy thông báo như tin thường,
// nên app đang tắt vẫn nhận được.
//   - được giao việc (người làm mới xuất hiện trên thẻ; người tự giao cho mình thì bỏ qua);
//   - trước hạn 1 ngày (hạn theo ngày: 16:00 hôm trước; hạn có giờ: 24 giờ trước);
//   - quá hạn (hạn theo ngày: 08:00 hôm sau, gộp vào tin mỗi sáng nếu người đó bật; hạn có giờ: ngay khi qua giờ);
//   - việc chuyển sang trạng thái "xong" → báo người tạo thẻ (nếu người khác làm xong);
//   - 08:00 mỗi sáng: tin tóm tắt việc hôm nay + quá hạn cho từng người (tắt bằng preference flygo_chat/task_digest = "off",
//     công tắc "Nhắc việc mỗi sáng" trong app).
// Tin mang props.flygo_task = { v:1, kind: assigned|due_soon|overdue|done|digest, by?, items:[{team_id, board_id, view_id?,
// card_id, title, due?, assignees}] } để app hiện thành thẻ bấm được; nội dung chữ (markdown + link thẻ) cho app khác.
//
// Lần chạy đầu với mỗi máy chủ chỉ ghi nhận hiện trạng (không gửi gì) để khỏi dội tin cũ.
// Giới hạn: chỉ thấy bảng mở cho team và bảng mà tài khoản quản trị là thành viên (bảng riêng tư khác không đọc được).
//
// Cấu hình: tasks: { servers: { "<url>": { internal, adminTokenFile, botTokenFile } }, dataDir: "/app/data",
//   intervalSec?: 120, tz?: "Asia/Ho_Chi_Minh", digestHour?: 8, dueSoonHour?: 16, overdueHour?: 8, dryRun?: false }
// Log: số bảng / thẻ / tin gửi theo vòng, không log nội dung việc.
import fs from 'node:fs';

const DAY = 86_400_000;
const FB = '/plugins/focalboard/api/v2';

// ---------------------------------------------------------------- phần thuần (kiểm thử được)

/** Bỏ dấu, chữ thường (giống normText của app). */
const VI_FROM = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
const VI_TO = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
export function normText(s) {
  return [...String(s || '').toLowerCase().trim()].map((ch) => { const i = VI_FROM.indexOf(ch); return i < 0 ? ch : VI_TO[i]; }).join('');
}

/** Trạng thái "xong" (cùng danh sách với app). */
export function isDoneStatus(name) {
  return /^(xong|hoan thanh|da xong|done|completed?|closed|finished|完了|完成|已完成|완료|เสร็จ|เสร็จแล้ว)$/.test(normText(name));
}

/** Các thuộc tính chính của bảng theo cùng quy tắc với app: trạng thái, người làm, hạn. */
export function boardProps(board) {
  const props = board.cardProperties || [];
  const sel = props.filter((p) => p.type === 'select');
  const status = sel.find((p) => /status|trang thai|tinh trang/.test(normText(p.name)))
    || sel.find((p) => !/priority|uu tien/.test(normText(p.name)));
  const ppl = props.filter((p) => p.type === 'multiPerson' || p.type === 'person');
  const work = ppl.filter((p) => !/giao|reporter|requester|owner/.test(normText(p.name)));
  const assignee = work.find((p) => p.type === 'multiPerson') || work[0] || ppl[0];
  const ds = props.filter((p) => p.type === 'date');
  const due = ds.find((p) => /due|han|deadline|ngay/.test(normText(p.name))) || ds[0];
  return { status, assignee, due, people: ppl };
}

const list = (v) => (Array.isArray(v) ? v.map(String) : typeof v === 'string' && v ? [v] : []);

/** Giá trị ngày của thẻ: {ms, includeTime} (ngày bắt đầu nếu là khoảng); null nếu trống. */
export function parseDue(v) {
  if (typeof v !== 'string' || !v) return null;
  if (/^\d+$/.test(v)) return { ms: Number(v), includeTime: false };
  try {
    const j = JSON.parse(v);
    const ms = Number(j.from ?? j.to);
    return Number.isFinite(ms) ? { ms, includeTime: j.includeTime === true } : null;
  } catch {
    return null;
  }
}

/** Ngày (YYYY-MM-DD) và giờ theo múi giờ [tz]. */
export function zoned(ms, tz) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' })
    .formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return { day: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) };
}

const addDay = (day, n) => new Date(Date.parse(`${day}T00:00:00Z`) + n * DAY).toISOString().slice(0, 10);

/** Ngày hạn theo lịch: hạn không giờ lưu ở 00:00 UTC của ngày đó (như bản web); hạn có giờ đổi sang múi giờ [tz]. */
export function dueDay(due, tz) {
  return due.includeTime ? zoned(due.ms, tz).day : new Date(due.ms).toISOString().slice(0, 10);
}

/**
 * Giai đoạn nhắc của một hạn tại thời điểm [now]: 'soon' (trước hạn 1 ngày), 'overdue' (đã quá hạn) hoặc null.
 * Hạn theo ngày: 'soon' từ [soonHour] giờ hôm trước tới hết hôm đó; 'overdue' từ [overdueHour] giờ hôm sau hạn.
 * Hạn có giờ: 'soon' trong 24 giờ trước hạn; 'overdue' ngay khi qua giờ.
 */
export function dueStage(due, now, { tz = 'Asia/Ho_Chi_Minh', soonHour = 16, overdueHour = 8 } = {}) {
  if (!due) return null;
  if (due.includeTime) {
    if (now >= due.ms) return 'overdue';
    return now >= due.ms - DAY ? 'soon' : null;
  }
  const d = dueDay(due, tz);
  const z = zoned(now, tz);
  if (z.day > d) return z.day > addDay(d, 1) || z.hour >= overdueHour ? 'overdue' : null;
  if (z.day === addDay(d, -1) && z.hour >= soonHour) return 'soon';
  return null;
}

/** Việc có thuộc tin mỗi sáng không: chưa xong, hạn hôm nay hoặc trước đó. */
export function inDigest(due, now, tz) {
  return !!due && dueDay(due, tz) <= zoned(now, tz).day;
}

/** Tóm tắt một thẻ để so với lần trước. */
export function cardSnapshot(board, card, tz) {
  const { status, assignee, due, people } = boardProps(board);
  const p = card.fields?.properties || card.properties || {};
  const assignees = assignee ? list(p[assignee.id]) : [...new Set(people.flatMap((x) => list(p[x.id])))];
  const opt = status?.options?.find((o) => o.id === p[status.id]);
  const dueRaw = due ? p[due.id] || '' : '';
  return {
    assignees,
    done: isDoneStatus(opt?.value || ''),
    dueRaw,
    due: parseDue(dueRaw),
    createdBy: card.createdBy || '',
    modifiedBy: card.modifiedBy || card.createdBy || '',
    title: card.title || '',
    tz,
  };
}

/**
 * So hiện trạng [cards] (danh sách {key, board, card}) với trạng thái đã lưu [prev] (key → {a, d, due, soon, over}) và trả
 * về {next, events}. events: {kind: assigned|done|due_soon|overdue, user, by?, key, snap}. [baseline]: chỉ ghi nhận.
 */
export function planReminders(prev, cards, now, opts = {}) {
  const tz = opts.tz || 'Asia/Ho_Chi_Minh';
  const next = {}, events = [];
  for (const { key, board, card } of cards) {
    const s = cardSnapshot(board, card, tz);
    const old = prev[key];
    const st = s.done ? null : dueStage(s.due, now, { tz, soonHour: opts.soonHour, overdueHour: opts.overdueHour });
    const stageKey = st ? `${st}:${s.dueRaw}` : '';
    const rec = { a: s.assignees, d: s.done, due: s.dueRaw, soon: old?.soon || '', over: old?.over || '' };
    if (opts.baseline) {
      // Lần đầu: coi như đã nhắc mọi thứ đang có.
      if (st === 'soon') rec.soon = stageKey;
      if (st === 'overdue') rec.over = stageKey;
      next[key] = rec;
      continue;
    }
    // Được giao: người làm mới (thẻ mới: mọi người làm), trừ người tự giao cho mình.
    const before = new Set(old ? old.a : []);
    for (const u of s.assignees) {
      if (!before.has(u) && u !== s.modifiedBy && !(old == null && u === s.createdBy)) events.push({ kind: 'assigned', user: u, by: s.modifiedBy, key, snap: s });
    }
    // Xong: báo người tạo thẻ nếu người khác bấm xong.
    if (old && !old.d && s.done && s.createdBy && s.createdBy !== s.modifiedBy) {
      events.push({ kind: 'done', user: s.createdBy, by: s.modifiedBy, key, snap: s });
    }
    // Hạn: mỗi (giai đoạn, giá trị hạn) chỉ nhắc một lần; đổi hạn thì nhắc lại theo hạn mới.
    if (st === 'soon' && rec.soon !== stageKey) {
      rec.soon = stageKey;
      for (const u of s.assignees) events.push({ kind: 'due_soon', user: u, key, snap: s });
    }
    if (st === 'overdue' && rec.over !== stageKey) {
      rec.over = stageKey;
      for (const u of s.assignees) events.push({ kind: 'overdue', user: u, key, snap: s });
    }
    next[key] = rec;
  }
  return { next, events };
}

// ---------------------------------------------------------------- chạy trong trạm đẩy

export function createTasks(conf = {}, log = console.log) {
  const servers = conf.servers || {};
  const tz = conf.tz || 'Asia/Ho_Chi_Minh';
  const interval = Math.max(30, conf.intervalSec || 120) * 1000;
  const digestHour = Number.isInteger(conf.digestHour) ? conf.digestHour : 8;
  const opts = { tz, soonHour: Number.isInteger(conf.dueSoonHour) ? conf.dueSoonHour : 16, overdueHour: Number.isInteger(conf.overdueHour) ? conf.overdueHour : 8 };
  const stateFile = `${conf.dataDir || '/app/data'}/tasks-state.json`;
  let state = {};
  try { state = JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch { state = {}; }
  const save = () => {
    try {
      fs.writeFileSync(`${stateFile}.tmp`, JSON.stringify(state));
      fs.renameSync(`${stateFile}.tmp`, stateFile);
    } catch (e) { log('tasks: save', e.message); }
  };
  let running = false;

  const token = (f) => fs.readFileSync(f, 'utf8').trim();
  async function call(srv, tok, method, path, body) {
    const r = await fetch(`${srv.internal}${path.startsWith(FB) ? '' : '/api/v4'}${path}`, {
      method,
      headers: { authorization: `Bearer ${tok}`, 'x-requested-with': 'XMLHttpRequest', ...(body ? { 'content-type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(30_000),
    });
    if (!r.ok) throw Object.assign(new Error(`${method} ${path.split('?')[0]} -> ${r.status}`), { status: r.status });
    return r.status === 204 ? null : r.json();
  }

  /** Mọi thẻ đang có trên các bảng đọc được: [{key, board, card, team, view}]. */
  async function collect(srv) {
    const adm = token(srv.adminTokenFile);
    const teams = await call(srv, adm, 'GET', '/teams?per_page=200');
    const out = [];
    let boards = 0;
    for (const t of teams) {
      let bs = [];
      try { bs = await call(srv, adm, 'GET', `${FB}/teams/${t.id}/boards`); } catch (e) { if (e.status !== 404) log('tasks: boards', t.id, e.message); continue; }
      for (const b of bs || []) {
        if (b.isTemplate || b.deleteAt) continue;
        const p = boardProps(b);
        if (!p.assignee && !p.people.length) continue; // bảng không giao việc cho ai
        boards++;
        let blocks = [];
        try { blocks = await call(srv, adm, 'GET', `${FB}/boards/${b.id}/blocks?all=true`); } catch (e) { log('tasks: blocks', b.id, e.message); continue; }
        const view = (blocks || []).find((x) => x.type === 'view' && !x.deleteAt)?.id || '';
        for (const c of blocks || []) {
          if (c.type !== 'card' || c.deleteAt || c.fields?.isTemplate) continue;
          out.push({ key: c.id, board: b, card: c, team: t.id, view });
        }
      }
    }
    return { cards: out, boards };
  }

  async function runServer(url, srv) {
    const st = (state[url] ||= { cards: {}, digestDay: '' });
    const now = Date.now();
    const { cards, boards } = await collect(srv);
    const baseline = !st.baselined;
    const { next, events } = planReminders(st.cards, cards, now, { ...opts, baseline });
    const byKey = Object.fromEntries(cards.map((c) => [c.key, c]));

    // Tin mỗi sáng (một lần mỗi ngày, từ [digestHour] giờ).
    const z = zoned(now, tz);
    const digest = !baseline && z.hour >= digestHour && st.digestDay !== z.day;
    const digestFor = new Map(); // user → [card]
    if (digest) {
      for (const c of cards) {
        const s = cardSnapshot(c.board, c.card, tz);
        if (s.done || !inDigest(s.due, now, tz)) continue;
        for (const u of s.assignees) {
          if (!digestFor.has(u)) digestFor.set(u, []);
          digestFor.get(u).push(c);
        }
      }
    }

    const sender = srv.botTokenFile ? makeSender(url, srv) : null;
    let sent = 0;
    if (!baseline && sender && (events.length || digestFor.size)) {
      const optOut = new Map();
      const digestOff = async (u) => {
        if (!optOut.has(u)) {
          let off = false;
          try { off = (await call(srv, token(srv.adminTokenFile), 'GET', `/users/${u}/preferences/flygo_chat/name/task_digest`))?.value === 'off'; } catch { off = false; }
          optOut.set(u, off);
        }
        return optOut.get(u);
      };
      // Gom theo người: được giao / xong gửi từng việc; sắp hạn / quá hạn gộp thành một tin.
      const group = new Map();
      for (const e of events) {
        if (e.kind === 'assigned' || e.kind === 'done') {
          sent += await sender.send(e.user, e.kind, [byKey[e.key]], e.by).catch((err) => (log('tasks: send', e.kind, err.message), 0));
        } else {
          const k = `${e.user}\n${e.kind}`;
          if (!group.has(k)) group.set(k, []);
          group.get(k).push(byKey[e.key]);
        }
      }
      for (const [k, items] of group) {
        const [user, kind] = k.split('\n');
        // Quá hạn theo ngày rơi đúng giờ tin mỗi sáng: người bật tin mỗi sáng thì đã thấy trong tin đó.
        if (kind === 'overdue' && digestFor.has(user) && !(await digestOff(user))) continue;
        sent += await sender.send(user, kind, items).catch((err) => (log('tasks: send', kind, err.message), 0));
      }
      for (const [user, items] of digestFor) {
        if (await digestOff(user)) continue;
        sent += await sender.send(user, 'digest', items).catch((err) => (log('tasks: send digest', err.message), 0));
      }
    }
    if (digest) st.digestDay = z.day;
    st.cards = next;
    st.baselined = true;
    save();
    log('tasks', url, `boards=${boards} cards=${cards.length} events=${events.length} digest=${digest ? digestFor.size : '-'} sent=${sent}${baseline ? ' (baseline)' : ''}${conf.dryRun ? ' (dry-run)' : ''}`);
  }

  /** Gửi tin riêng từ bot thông báo. */
  function makeSender(url, srv) {
    const dm = new Map();
    const names = new Map();
    let botId = '';
    const bot = () => token(srv.botTokenFile);
    const adm = () => token(srv.adminTokenFile);
    const nameOf = async (id) => {
      if (!id) return '';
      if (!names.has(id)) {
        try {
          const u = await call(srv, adm(), 'GET', `/users/${id}`);
          names.set(id, [u.first_name, u.last_name].filter(Boolean).join(' ') || u.nickname || u.username || '');
        } catch { names.set(id, ''); }
      }
      return names.get(id);
    };
    const link = (c) => `${url}/boards/team/${c.team}/${c.board.id}${c.view ? `/${c.view}/${c.card.id}` : ''}`;
    const fmtDay = (snap) => {
      if (!snap.due) return '';
      const d = dueDay(snap.due, tz).split('-');
      return `${Number(d[2])}/${Number(d[1])}`;
    };
    const line = (c) => {
      const s = cardSnapshot(c.board, c.card, tz);
      const d = fmtDay(s);
      return `- [${(s.title || '(Không có tiêu đề)').replace(/[[\]]/g, '')}](${link(c)})${d ? ` · hạn ${d}` : ''}`;
    };
    return {
      async send(user, kind, items, by) {
        items = items.filter(Boolean);
        if (!items.length) return 0;
        const byName = await nameOf(by);
        const one = items[0];
        let text;
        if (kind === 'assigned') text = `**${byName || 'Ai đó'}** giao cho bạn một việc:\n${line(one)}`;
        else if (kind === 'done') text = `**${byName || 'Ai đó'}** đã xong việc bạn giao:\n${line(one)}`;
        else if (kind === 'due_soon') text = `Sắp đến hạn (${items.length} việc):\n${items.map(line).join('\n')}`;
        else if (kind === 'overdue') text = `Việc đã quá hạn (${items.length}):\n${items.map(line).join('\n')}`;
        else {
          const today = zoned(Date.now(), tz).day;
          const late = items.filter((c) => dueDay(cardSnapshot(c.board, c.card, tz).due, tz) < today);
          const now = items.filter((c) => !late.includes(c));
          text = ['Chào buổi sáng! Việc hôm nay của bạn:',
            ...(late.length ? [`**Quá hạn (${late.length})**`, ...late.map(line)] : []),
            ...(now.length ? [`**Hôm nay (${now.length})**`, ...now.map(line)] : []),
            '_Tắt tin này: app Flygo Chat > Bạn > Nhắc việc mỗi sáng._'].join('\n');
        }
        const props = {
          flygo_task: {
            v: 1, kind, ...(by ? { by } : {}),
            items: items.slice(0, 30).map((c) => {
              const s = cardSnapshot(c.board, c.card, tz);
              return { team_id: c.team, board_id: c.board.id, ...(c.view ? { view_id: c.view } : {}), card_id: c.card.id, title: s.title, ...(s.dueRaw ? { due: s.dueRaw } : {}), assignees: s.assignees };
            }),
          },
        };
        if (conf.dryRun) {
          log('tasks: dry-run', kind, user, items.length);
          return 1;
        }
        if (!botId) botId = (await call(srv, bot(), 'GET', '/users/me')).id;
        if (user === botId) return 0;
        if (!dm.has(user)) dm.set(user, (await call(srv, bot(), 'POST', '/channels/direct', [botId, user])).id);
        await call(srv, bot(), 'POST', '/posts', { channel_id: dm.get(user), message: text, props });
        return 1;
      },
    };
  }

  async function tick() {
    if (running) return;
    running = true;
    try {
      for (const [url, srv] of Object.entries(servers)) {
        try { await runServer(url.replace(/\/+$/, ''), srv); } catch (e) { log('tasks: server', url, e.message); }
      }
    } finally {
      running = false;
    }
  }
  const first = setTimeout(tick, 15_000);
  const timer = setInterval(tick, interval);
  return { tick, stop: () => { clearTimeout(first); clearInterval(timer); } };
}
