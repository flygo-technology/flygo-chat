// Lịch hẹn ("Hẹn giờ") của bot: bản ghi, kiểm tra đầu vào, tính lần chạy kế tiếp theo múi giờ.
// Runner lưu trong state db (bảng schedules), tới giờ chạy prompt như một lượt ở đúng chỗ đích (chat chính / luồng / chat AI).

export type Freq = "daily" | "weekly" | "monthly" | "cron";
export interface Repeat { freq: Freq; time?: string; days?: number[]; day_of_month?: number; cron?: string }
export interface RunRecord { at: number; status: "done" | "error" | "skipped"; post_id?: string; error?: string }
export interface Schedule {
  id: string; title: string; prompt: string; kind: "once" | "repeat";
  at?: string; repeat?: Repeat; tz: string;
  target: { channel_id: string; root_id?: string };
  created_by: string; created_at: number; updated_at: number;
  enabled: boolean; next_run_at: number | null;
  last_run?: RunRecord; history: RunRecord[];
}

export const DEFAULT_TZ = "Asia/Ho_Chi_Minh";
export const HISTORY_MAX = 20;

// ---- múi giờ (Intl, không cần thư viện) ----
const fmts = new Map<string, Intl.DateTimeFormat>();
function fmt(tz: string) {
  let f = fmts.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", weekday: "short" });
    fmts.set(tz, f);
  }
  return f;
}
const DOW: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
/** Giờ địa phương của mốc ms: y, m (1-12), d, h, mi, dow (1=Thứ Hai … 7=Chủ nhật). */
export function zparts(ms: number, tz: string) {
  const p: Record<string, string> = {};
  for (const x of fmt(tz).formatToParts(new Date(ms))) p[x.type] = x.value;
  return { y: +p.year, m: +p.month, d: +p.day, h: +p.hour % 24, mi: +p.minute, s: +p.second, dow: DOW[p.weekday] ?? 1 };
}
/** ms của giờ địa phương y-m-d h:mi ở múi tz. */
export function zmake(y: number, m: number, d: number, h: number, mi: number, tz: string) {
  const guess = Date.UTC(y, m - 1, d, h, mi);
  const off = (ms: number) => { const z = zparts(ms, tz); return Date.UTC(z.y, z.m - 1, z.d, z.h, z.mi, z.s) - Math.floor(ms / 1000) * 1000; };
  let ms = guess - off(guess);
  ms = guess - off(ms); // đổi giờ mùa hè: chỉnh lần hai
  return ms;
}
const daysIn = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();
export function validTz(tz: string) { try { fmt(tz); return true; } catch { return false; } }

// ---- cron 5 trường: phút giờ ngày tháng thứ (0/7 = CN) ----
function cronField(f: string, lo: number, hi: number): Set<number> | null {
  const out = new Set<number>();
  for (const part of f.split(",")) {
    const m = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(part.trim());
    if (!m) return null;
    let a = lo, b = hi;
    if (m[2] !== undefined) { a = +m[2]; b = m[3] !== undefined ? +m[3] : m[4] ? hi : a; }
    const step = m[4] ? +m[4] : 1;
    if (a < lo || b > hi || a > b || step < 1) return null;
    for (let i = a; i <= b; i += step) out.add(i);
  }
  return out;
}
export function parseCron(expr: string) {
  const f = expr.trim().split(/\s+/);
  if (f.length !== 5) return null;
  const [mi, h, dom, mon, dow] = [cronField(f[0], 0, 59), cronField(f[1], 0, 23), cronField(f[2], 1, 31), cronField(f[3], 1, 12), cronField(f[4], 0, 7)];
  if (!mi || !h || !dom || !mon || !dow) return null;
  if (dow.has(7)) dow.add(0);
  return { mi, h, dom, mon, dow, domAny: f[2] === "*", dowAny: f[4] === "*" };
}

const hm = (t?: string) => { const m = /^(\d{1,2}):(\d{2})$/.exec(t ?? ""); return m && +m[1] < 24 && +m[2] < 60 ? { h: +m[1], mi: +m[2] } : null; };

/** Lần chạy kế tiếp SAU mốc `after` (ms), hoặc null (lịch một lần đã qua / không hợp lệ). */
export function nextRun(s: Pick<Schedule, "kind" | "at" | "repeat" | "tz">, after: number): number | null {
  if (s.kind === "once") { const t = parseAt(s.at ?? "", s.tz); return t !== null && t > after ? t : null; }
  const r = s.repeat;
  if (!r) return null;
  const z = zparts(after, s.tz);
  if (r.freq === "cron") {
    const c = parseCron(r.cron ?? "");
    if (!c) return null;
    for (let day = 0; day < 400; day++) {
      const base = Date.UTC(z.y, z.m - 1, z.d + day);
      const dt = new Date(base), y = dt.getUTCFullYear(), m = dt.getUTCMonth() + 1, d = dt.getUTCDate(), wd = dt.getUTCDay();
      if (!c.mon.has(m)) continue;
      const domOk = c.dom.has(d), dowOk = c.dow.has(wd);
      // cron chuẩn: cả hai trường ngày đều hạn chế thì khớp một trong hai
      if (!(c.domAny && c.dowAny ? true : c.domAny ? dowOk : c.dowAny ? domOk : domOk || dowOk)) continue;
      for (const hh of [...c.h].sort((a, b) => a - b)) for (const mm of [...c.mi].sort((a, b) => a - b)) {
        const t = zmake(y, m, d, hh, mm, s.tz);
        if (t > after) return t;
      }
    }
    return null;
  }
  const t = hm(r.time);
  if (!t) return null;
  const days = (r.days ?? []).filter((x) => x >= 1 && x <= 7);
  for (let day = 0; day < 400; day++) {
    const dt = new Date(Date.UTC(z.y, z.m - 1, z.d + day));
    const y = dt.getUTCFullYear(), m = dt.getUTCMonth() + 1, d = dt.getUTCDate(), wd = dt.getUTCDay() || 7;
    if (r.freq === "weekly" || (r.freq === "daily" && days.length)) { if (days.length && !days.includes(wd)) continue; }
    if (r.freq === "monthly") { const want = Math.min(Math.max(1, r.day_of_month ?? 1), daysIn(y, m)); if (d !== want) continue; }
    const ms = zmake(y, m, d, t.h, t.mi, s.tz);
    if (ms > after) return ms;
  }
  return null;
}

/** "2026-10-18T08:00" (giờ địa phương theo tz) hoặc ISO có múi ("…Z", "+07:00"). */
export function parseAt(at: string, tz: string): number | null {
  const s = String(at ?? "").trim();
  if (!s) return null;
  if (/(Z|[+-]\d{2}:?\d{2})$/i.test(s)) { const t = Date.parse(s); return Number.isFinite(t) ? t : null; }
  const m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{1,2}):(\d{2})/.exec(s);
  return m ? zmake(+m[1], +m[2], +m[3], +m[4], +m[5], tz) : null;
}

/** Kiểm tra + chuẩn hoá đầu vào (tạo mới hoặc sửa: `base` là bản cũ). Trả về lỗi dạng chuỗi nếu sai. */
export function normalize(input: any, base: Partial<Schedule> = {}): Omit<Schedule, "id" | "created_by" | "created_at" | "updated_at" | "next_run_at" | "history" | "last_run"> | string {
  const v = { ...base, ...(input ?? {}) } as any;
  if (v.repeat?.freq === "once") { v.kind = "once"; v.repeat = undefined; } // app gửi freq "once" cho lịch một lần
  const title = String(v.title ?? "").trim().slice(0, 120);
  const prompt = String(v.prompt ?? "").trim().slice(0, 8000);
  if (!prompt) return "thiếu prompt (việc cần làm)";
  const kind = v.kind === "once" || v.kind === "repeat" ? v.kind : v.at && !v.repeat ? "once" : "repeat";
  const tz = String(v.tz || DEFAULT_TZ);
  if (!validTz(tz)) return `múi giờ không hợp lệ: ${tz}`;
  const target = v.target && typeof v.target === "object" ? { channel_id: String(v.target.channel_id ?? ""), ...(v.target.root_id ? { root_id: String(v.target.root_id) } : {}) } : null;
  if (!target || !/^\w{26}$/.test(target.channel_id)) return "thiếu target.channel_id";
  if (target.root_id && !/^\w{26}$/.test(target.root_id)) return "target.root_id không hợp lệ";
  const enabled = v.enabled === undefined ? true : !!v.enabled;
  if (kind === "once") {
    const t = parseAt(v.at, tz);
    if (t === null) return "lịch một lần cần at (vd. 2026-10-18T08:00, giờ theo tz)";
    return { title: title || prompt.slice(0, 60), prompt, kind, at: new Date(t).toISOString(), tz, target, enabled };
  }
  const r = v.repeat ?? {};
  const freq = ["daily", "weekly", "monthly", "cron"].includes(r.freq) ? r.freq as Freq : null;
  if (!freq) return "repeat.freq phải là daily | weekly | monthly | cron";
  const repeat: Repeat = { freq };
  if (freq === "cron") {
    if (!parseCron(String(r.cron ?? ""))) return "repeat.cron không hợp lệ (5 trường: phút giờ ngày tháng thứ)";
    repeat.cron = String(r.cron).trim();
  } else {
    if (!hm(r.time)) return "repeat.time phải dạng HH:MM";
    repeat.time = String(r.time).padStart(5, "0");
    const days = Array.isArray(r.days) ? [...new Set(r.days.map(Number).filter((x: number) => x >= 1 && x <= 7))].sort() as number[] : [];
    if (freq === "weekly" && !days.length) return "lịch hằng tuần cần repeat.days (1=Thứ Hai … 7=Chủ nhật)";
    if (days.length && freq !== "monthly") repeat.days = days;
    if (freq === "monthly") {
      const dom = Number(r.day_of_month);
      if (!(dom >= 1 && dom <= 31)) return "lịch hằng tháng cần repeat.day_of_month (1-31; tháng ngắn hơn thì chạy ngày cuối tháng)";
      repeat.day_of_month = Math.floor(dom);
    }
  }
  return { title: title || prompt.slice(0, 60), prompt, kind, repeat, tz, target, enabled };
}

/** Mô tả ngắn cho người đọc: "08:00 hằng ngày (T2, T4)", "một lần lúc 18/10 08:00"… */
export function describe(s: Schedule) {
  const dn = (d: number) => (d === 7 ? "CN" : `T${d + 1}`);
  const when = (ms: number | null) => {
    if (!ms) return "—";
    const z = zparts(ms, s.tz);
    return `${String(z.d).padStart(2, "0")}/${String(z.m).padStart(2, "0")}/${z.y} ${String(z.h).padStart(2, "0")}:${String(z.mi).padStart(2, "0")}`;
  };
  const r = s.repeat;
  const rule = s.kind === "once" ? `một lần lúc ${when(parseAt(s.at ?? "", s.tz))}`
    : r?.freq === "cron" ? `cron "${r.cron}"`
    : r?.freq === "monthly" ? `${r.time} ngày ${r.day_of_month} hằng tháng`
    : r?.freq === "weekly" ? `${r.time} hằng tuần (${(r.days ?? []).map(dn).join(", ")})`
    : `${r?.time} hằng ngày${r?.days?.length ? ` (${r.days.map(dn).join(", ")})` : ""}`;
  return { rule, next: when(s.next_run_at) };
}
