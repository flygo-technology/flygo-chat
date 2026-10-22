// Phòng họp Flygo (chạy trong flygo-push, https://push.flygo.vn/meet/…): đồng bộ "sân khấu" của cuộc gọi nhóm giữa mọi
// máy trong cuộc gọi, để một AI agent dẫn buổi họp (nói bằng TTS, chiếu slide / web / ảnh, mời phát biểu, tắt mic…).
// Âm thanh / hình của cuộc gọi vẫn đi qua plugin Calls của Mattermost; relay chỉ chuyển sự kiện và giữ trạng thái.
//
//   WS   /meet/ws?channel=<id>[&token=&server=]   (hoặc Authorization: Bearer + X-MM-Server)
//        vào phòng: relay gửi {type:"state", state, you:{user_id, host}}; mỗi sự kiện hợp lệ được phát cho cả phòng
//        kèm from:{user_id, name, bot} và at (ms). Lỗi: {type:"error", message, ref?} (ref = id client gửi kèm).
//   POST /meet/<channel>/cmd   {type, …}          -> {ok, event}     (bot / người dùng; như gửi qua WS)
//   GET  /meet/<channel>/state                    -> {…state, participants, online}
//   POST /meet/<channel>/tts   {text, voice?, rate?, play?} -> {url, duration_ms}  (play: phát cho cả phòng + phụ đề)
//   GET  /meet/tts/<file>.mp3                     (tệp TTS, tên theo băm nội dung)
//   POST /meet/<channel>/deck  {html, title?}      -> {url, deck, slides:[{steps,title}]}  (host; bộ slide HTML, chèn deck-runtime)
//   POST /meet/<channel>/asset (thân = tệp, content-type ảnh / âm thanh / video / font) -> {url}  (host; ảnh, video cho slide)
//   POST /meet/<channel>/deck_frames {deck, frames:{"<trang>.<bước>": url ảnh}}  (host; ảnh chụp từng bước cho máy không chạy được web)
//   GET  /meet/deck/<hash>.html · GET /meet/asset/<hash>.<ext>   (công khai, tên = băm nội dung, không đoán được)
//   POST /meet/<channel>/present {deck, items:[{slide, step, text}], voice?, rate?, gap_ms?, music_swell?, swell_ms?}  (host) tạo sẵn giọng đọc cho
//        cả kịch bản rồi TRẠM tự chạy: lật slide + đọc + phụ đề liền mạch -> {ok, items, duration_ms} (trả về khi bắt đầu chạy)
//   POST /meet/<channel>/present {action: "stop" | "pause" | "resume" | "status"}; trạng thái chạy ở state.show
//   POST /meet/<channel>/live  -> {url, first}  (thành viên; link xem từ xa của phòng; first = lần đầu xin trong cuộc họp này)
//   GET  /meet/live/<channel>/<key>?s=<server>         trang xem từ xa (không cần đăng nhập, key = HMAC của server + kênh):
//   GET  /meet/live/<channel>/<key>/events?s=<server>  sân khấu, phụ đề, giọng đọc, nhạc theo thời gian thực (SSE)
// Người gọi phải là thành viên kênh. Chủ trì (host): người bắt đầu / host cuộc gọi, quản trị kênh, quản trị hệ thống,
// hoặc bot có chủ là host.
//
// Sự kiện: hand{up} · lower_hand{user_id} · react{emoji} · comment{text} · mute{user_id} · mute_all{except} ·
//   unmute_request{user_id} · star{user_id|null} · screen_request{user_id} · web_open{url} · web_nav{url} ·
//   web_scroll{x,y} · web_click{x,y} · web_close · stage{kind, …} · audio{kind, url, action, volume, loop} · caption{text}
//   stage{kind:"html", deck, slide, step} chiếu bộ slide HTML (app nạp /meet/deck/<deck>.html rồi gọi flygoGo(slide, step));
//   stage{kind:"html", go:"next"|"prev"} hoặc {slide, step}: chuyển bước / trang của bộ đang chiếu (trạm biết số bước từng trang).
//   audio{kind:"sfx", url}: hiệu ứng âm phát một lần, không lưu trạng thái.
//   stage{kind:"scene", scene, data, theme?, reveal?}: cảnh có sẵn (/meet/scenes.html: opening | qa | break | closing …);
//   cùng cảnh mà không gửi data thì giữ data cũ (vd. chỉ đổi reveal = chữ trả lời hiện tới đâu); theme nhớ theo phòng.
// Chỉ host: mute, mute_all, unmute_request, star, screen_request, web_open, stage, audio, caption, lower_hand (người khác).
// Chỉ người đang điều khiển web (người mở): web_nav, web_scroll, web_click; web_close: người đó hoặc host.
//
// Trạng thái: audio = giọng nói (tts) gần nhất, music = nhạc nền (audio{kind:"music"}, action volume chỉ đổi âm lượng).
// Cấu hình: meet: { ttsUrl, ttsDir?, publicBase?, deckDir? }
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const httpErr = (status, message) => Object.assign(new Error(message), { status });
const CALLS = '/plugins/com.mattermost.calls';
const HOST_ONLY = new Set(['mute', 'mute_all', 'unmute_request', 'star', 'screen_request', 'web_open', 'stage', 'audio', 'caption']);
const TYPES = new Set([...HOST_ONLY, 'hand', 'lower_hand', 'react', 'comment', 'web_nav', 'web_scroll', 'web_click', 'web_close', 'meet_thread']);
const frac = (v) => { const n = Number(v); return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0; };
const str = (v, n) => String(v ?? '').slice(0, n);
const idOk = (v) => /^[a-z0-9]{26}$/.test(String(v ?? ''));
const MIME_EXT = { 'image/png': '.png', 'image/jpeg': '.jpg', 'image/webp': '.webp', 'image/gif': '.gif', 'image/svg+xml': '.svg', 'image/avif': '.avif',
  'video/mp4': '.mp4', 'video/webm': '.webm', 'audio/mpeg': '.mp3', 'audio/ogg': '.ogg', 'audio/wav': '.wav', 'font/woff2': '.woff2', 'font/ttf': '.ttf', 'application/pdf': '.pdf' };
const EXT_MIME = Object.fromEntries(Object.entries(MIME_EXT).map(([k, v]) => [v, k]));
const urlOk = (u) => { try { const x = new URL(String(u)); return x.protocol === 'https:' || x.protocol === 'http:'; } catch { return false; } };

export function createMeet(conf = {}, a2a, log = console.log) {
  const { identify, WsConn, mmGet, mmRaw, adminGet } = a2a;
  const TTS_URL = conf.ttsUrl || '';
  const TTS_DIR = conf.ttsDir || '/app/meet-tts';
  const PUBLIC = (conf.publicBase || 'https://push.flygo.vn').replace(/\/+$/, '');
  const DECK_DIR = conf.deckDir || '/app/data/meet-deck';
  const VOICE = conf.voice || 'vi-VN-NamMinhNeural'; // giọng đọc mặc định khi không chọn: nam, giọng Bắc
  // Link xem từ xa: khoá bí mật lưu cạnh thư mục slide (giữ qua lần khởi động lại).
  const LIVE_KEY_FILE = path.join(path.dirname(DECK_DIR), 'meet-live.key');
  let LIVE_SECRET = '';
  try { LIVE_SECRET = fs.readFileSync(LIVE_KEY_FILE, 'utf8').trim(); } catch {}
  if (!LIVE_SECRET) { LIVE_SECRET = crypto.randomBytes(32).toString('hex'); try { fs.mkdirSync(path.dirname(LIVE_KEY_FILE), { recursive: true }); fs.writeFileSync(LIVE_KEY_FILE, LIVE_SECRET, { mode: 0o600 }); } catch {} }
  const liveKey = (server, channel) => crypto.createHmac('sha256', LIVE_SECRET).update(`${server} ${channel}`).digest('base64url').slice(0, 22);
  const liveUrl = (server, channel) => `${PUBLIC}/meet/live/${channel}/${liveKey(server, channel)}${server === 'https://chat.flygo.vn' ? '' : `?s=${encodeURIComponent(server)}`}`;
  let RUNTIME = '';
  let SCENES = '';
  try { SCENES = fs.readFileSync(new URL('./scenes.html', import.meta.url), 'utf8'); } catch { log('meet: thiếu scenes.html — không có cảnh mở đầu / hỏi đáp / kết thúc'); }
  try { RUNTIME = fs.readFileSync(new URL('./deck-runtime.html', import.meta.url), 'utf8'); } catch { log('meet: thiếu deck-runtime.html — slide HTML chạy không có hiệu ứng từng bước'); }
  fs.mkdirSync(DECK_DIR, { recursive: true });
  const rooms = new Map();
  const freshState = () => ({ hands: {}, comments: [], star: null, web: null, stage: null, audio: null, music: null, caption: null, meet_thread: null }); // `${server} ${channel}` -> {server, channel, clients:Set, state, touched}

  const room = (server, channel) => {
    const k = `${server} ${channel}`;
    let r = rooms.get(k);
    if (!r) {
      r = { server, channel, clients: new Set(), watchers: new Set(), touched: Date.now(), callId: '', state: freshState() };
      rooms.set(k, r);
    }
    // Phòng trống quá 2 phút: coi như cuộc họp mới, không phát lại slide / phụ đề / nhạc cũ.
    if (!r.clients.size && Date.now() - r.touched > 120_000) r.state = freshState();
    r.touched = Date.now();
    return r;
  };
  setInterval(() => { for (const [k, r] of rooms) if (!r.clients.size && Date.now() - r.touched > 6 * 3600_000) rooms.delete(k); }, 600_000).unref?.();

  // ---------------------------------------------------------------- quyền
  const memo = new Map(); // khoá -> {v, exp}
  const cached = async (k, ms, fn) => { const c = memo.get(k); if (c && c.exp > Date.now()) return c.v; const v = await fn(); memo.set(k, { v, exp: Date.now() + ms }); if (memo.size > 5000) memo.clear(); return v; };
  /** Thành viên kênh (dùng token của chính người gọi): {roles} hoặc ném 403. */
  async function member(who, channel) {
    return cached(`m ${who.server} ${channel} ${who.id}`, 60_000, async () => {
      const m = await mmGet(who.server, who.token, `/channels/${channel}/members/${who.id}`).catch(() => null);
      if (!m) throw httpErr(403, 'bạn không ở kênh này');
      return { roles: String(m.roles || '') };
    });
  }
  /** Cuộc gọi đang diễn ra ở kênh (Calls API), hoặc null. */
  async function callOf(who, channel) {
    const r = await mmRaw(who.server, who.token, `${CALLS}/${channel}`).catch(() => null);
    return r?.call && (r.call.id || r.call.start_at) && !(Number(r.call.end_at) > 0) ? r.call : null;
  }
  async function isHostUser(server, uid, channel, who) {
    const call = await callOf(who, channel).catch(() => null);
    if (call && (call.host_id === uid || call.owner_id === uid)) return true;
    const m = who.id === uid ? await member(who, channel).catch(() => null)
      : await cached(`m ${server} ${channel} ${uid}`, 60_000, () => adminGet(server, `/channels/${channel}/members/${uid}`).then((x) => ({ roles: String(x.roles || '') }))).catch(() => null);
    if (m && /\bchannel_admin\b/.test(m.roles)) return true;
    const u = await cached(`r ${server} ${uid}`, 300_000, () => (who.id === uid ? mmGet(server, who.token, '/users/me') : adminGet(server, `/users/${uid}`)).then((x) => String(x.roles || ''))).catch(() => '');
    return /\bsystem_admin\b/.test(u);
  }
  async function isHost(who, channel) {
    return cached(`h ${who.server} ${channel} ${who.id}`, 15_000, async () =>
      who.is_bot ? !!who.owner && isHostUser(who.server, who.owner, channel, who) : isHostUser(who.server, who.id, channel, who));
  }
  async function auth(token, server, channel) {
    if (!idOk(channel)) throw httpErr(400, 'channel không hợp lệ');
    if (!token) throw httpErr(401, 'thiếu token');
    const who = await identify(server || 'https://chat.flygo.vn', token);
    await member(who, channel);
    return who;
  }
  const bearer = (req) => /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''))?.[1] || '';

  // ---------------------------------------------------------------- bộ slide HTML
  const deckMeta = new Map(); // deck -> {slides:[{steps,title,text}]}
  const deckFile = (id) => path.join(DECK_DIR, `${id}.html`);
  const metaFile = (id) => path.join(DECK_DIR, `${id}.json`);
  const stripTags = (h) => String(h).replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();
  /** Đọc số bước, tiêu đề, chữ của từng trang (mỗi <section> là một trang; không lồng section). */
  function parseDeck(html) {
    const body = String(html).replace(/<!--[\s\S]*?-->/g, '').replace(/<(script|style)[\s\S]*?<\/\1>/gi, '');
    const parts = body.split(/<section\b/i).slice(1).map((x) => x.split(/<\/section>/i)[0]);
    return parts.map((sec) => {
      const steps = Math.max(0, ...[...sec.matchAll(/data-step\s*=\s*["']?(\d+)/gi)].map((m) => Number(m[1])));
      const h = /<h[1-3]\b[^>]*>([\s\S]*?)<\/h[1-3]>/i.exec(sec);
      const title = h ? stripTags(h[1]).slice(0, 200) : '';
      // Hiệu ứng âm theo bước (data-sfx trên section = bước 0, trên phần tử data-step=n = bước n): máy không chạy web tự phát.
      const sfx = {};
      const add = (k, v) => { (sfx[k] ||= []).push(v); };
      const open = /^([^>]*)>/.exec(sec)?.[1] ?? '';
      const own = /data-sfx\s*=\s*["']?([\w-]+)/i.exec(open);
      if (own) add(0, own[1]);
      for (const t of sec.slice(open.length).matchAll(/<[a-z][^>]*>/gi)) {
        const st = /data-step\s*=\s*["']?(\d+)/i.exec(t[0]), fx = /data-sfx\s*=\s*["']?([\w-]+)/i.exec(t[0]);
        if (fx) add(st ? Number(st[1]) : 0, fx[1]);
      }
      return { steps, title, text: stripTags(sec.replace(/^[^>]*>/, '')).slice(0, 800), sfx };
    });
  }
  function loadMeta(id) {
    if (deckMeta.has(id)) return deckMeta.get(id);
    try { const m = JSON.parse(fs.readFileSync(metaFile(id), 'utf8')); deckMeta.set(id, m); return m; } catch { return null; }
  }
  function saveDeck(html, title) {
    let src = String(html || '');
    if (!/<section\b/i.test(src)) throw httpErr(400, 'bộ slide cần ít nhất một <section>');
    const slides = parseDeck(src);
    if (!/<html\b/i.test(src)) src = `<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>${(title || 'Flygo').replace(/[<>&]/g, '')}</title></head><body>${src}</body></html>`;
    const viewport = '<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">';
    src = /<head\b[^>]*>/i.test(src) ? src.replace(/<head\b[^>]*>/i, (m) => `${m}${viewport}${RUNTIME}`) : src.replace(/<html\b[^>]*>/i, (m) => `${m}<head>${viewport}${RUNTIME}</head>`);
    const id = crypto.createHash('sha256').update(src).digest('hex').slice(0, 24);
    fs.writeFileSync(deckFile(id), src);
    const meta = { slides, title: str(title, 200), at: Date.now() };
    fs.writeFileSync(metaFile(id), JSON.stringify(meta));
    deckMeta.set(id, meta);
    return { deck: id, url: `${PUBLIC}/meet/deck/${id}.html`, slides: slides.map(({ steps, title: t }) => ({ steps, title: t })) };
  }
  /** stage{kind:html}: bộ mới (deck) hoặc chuyển bước của bộ đang chiếu (go next/prev, slide/step). */
  function htmlStage(s, raw) {
    const cur = s.stage?.kind === 'html' ? s.stage : null;
    const id = raw.deck ? String(raw.deck) : cur?.deck;
    if (!id || !/^[a-f0-9]{24}$/.test(id)) throw httpErr(400, cur ? 'deck không hợp lệ' : 'chưa có bộ slide HTML nào đang chiếu: gửi deck');
    const meta = loadMeta(id);
    if (!meta) throw httpErr(404, 'không có bộ slide này (tải lên bằng /deck trước)');
    const n = meta.slides.length, same = cur && cur.deck === id;
    let slide = same ? cur.slide : 0, step = same ? cur.step : 0;
    if (raw.go === 'next') { if (step < (meta.slides[slide]?.steps ?? 0)) step++; else if (slide < n - 1) { slide++; step = 0; } }
    else if (raw.go === 'prev') { if (step > 0) step--; else if (slide > 0) { slide--; step = meta.slides[slide]?.steps ?? 0; } }
    if (raw.slide !== undefined) { slide = Math.floor(Number(raw.slide) || 0); step = 0; }
    if (raw.step !== undefined) step = raw.step === 'all' ? Infinity : Math.floor(Number(raw.step) || 0);
    slide = Math.max(0, Math.min(n - 1, slide));
    step = Math.max(0, Math.min(meta.slides[slide]?.steps ?? 0, step));
    const sl = meta.slides[slide] ?? { steps: 0, title: '', text: '' };
    // title / text: app không chạy được web (Windows / Linux) thì hiện chữ của trang thay cho slide.
    // frame: ảnh chụp đúng bước này (nếu đã có); sfx: âm của bước này — cho máy không chạy được web.
    const frame = meta.frames?.[`${slide}.${step}`];
    const sfx = sl.sfx?.[step];
    return { kind: 'html', deck: id, url: `${PUBLIC}/meet/deck/${id}.html`, slide, step, slides: n, steps: sl.steps, title: sl.title, text: sl.text,
      ...(frame ? { frame } : {}), ...(sfx?.length ? { sfx } : {}) };
  }

  /** stage{kind:scene}: cảnh có sẵn; data / theme giữ lại khi chỉ cập nhật một phần (reveal). */
  const SCENE_NAMES = new Set(['opening', 'agenda', 'section', 'demo', 'poll', 'qa', 'break', 'recap', 'closing']);
  function sceneStage(s, raw) {
    const cur = s.stage?.kind === 'scene' ? s.stage : null;
    const scene = raw.scene ? String(raw.scene) : cur?.scene;
    if (!scene || !SCENE_NAMES.has(scene)) throw httpErr(400, `scene phải là ${[...SCENE_NAMES].join(' | ')}`);
    const clip = (o, n) => { const j = JSON.stringify(o ?? {}); if (j.length > n) throw httpErr(413, 'dữ liệu cảnh quá lớn'); return JSON.parse(j); };
    if (raw.theme && typeof raw.theme === 'object') s.theme = clip(raw.theme, 4000);
    const data = raw.data && typeof raw.data === 'object' ? clip(raw.data, 30000) : (cur && cur.scene === scene ? cur.data : {});
    const rv = raw.reveal && typeof raw.reveal === 'object'
      ? { from: Math.max(0, Number(raw.reveal.from) || 0), to: Math.max(0, Number(raw.reveal.to) || 0), duration_ms: Math.min(120000, Math.max(0, Number(raw.reveal.duration_ms) || 0)) }
      : (raw.data ? null : cur?.reveal ?? null);
    return { kind: 'scene', url: `${PUBLIC}/meet/scenes.html`, scene, data, theme: s.theme ?? {}, ...(rv ? { reveal: rv } : {}) };
  }

  // ---------------------------------------------------------------- sự kiện
  /** Kiểm + chuẩn hoá một sự kiện, cập nhật trạng thái phòng; trả sự kiện để phát (hoặc ném lỗi). */
  async function apply(r, who, raw) {
    const type = String(raw?.type || '');
    if (!TYPES.has(type)) throw httpErr(400, `type không hợp lệ: ${type || '(trống)'}`);
    const host = HOST_ONLY.has(type) || type === 'lower_hand' ? await isHost(who, r.channel) : false;
    if (HOST_ONLY.has(type) && !host) throw httpErr(403, 'chỉ người chủ trì cuộc họp');
    const s = r.state, me = who.id;
    let ev;
    switch (type) {
      case 'hand': ev = { up: !!raw.up }; if (ev.up) s.hands[me] = { name: who.name, at: Date.now() }; else delete s.hands[me]; break;
      case 'lower_hand': {
        const uid = idOk(raw.user_id) ? raw.user_id : me;
        if (uid !== me && !host) throw httpErr(403, 'chỉ người chủ trì hạ tay người khác');
        delete s.hands[uid]; ev = { user_id: uid }; break;
      }
      case 'react': ev = { emoji: str(raw.emoji, 32) }; if (!ev.emoji) throw httpErr(400, 'emoji trống'); break;
      case 'comment': {
        const text = str(raw.text, 500).trim();
        if (!text) throw httpErr(400, 'bình luận trống');
        ev = { id: crypto.randomBytes(6).toString('base64url'), text, ...(idOk(raw.post_id) ? { post_id: raw.post_id } : {}) };
        break;
      }
      case 'meet_thread': {
        // Luồng công khai lưu bình luận của cuộc họp: người gửi đầu tiên thắng; host gửi root_id null để xoá (hết cuộc gọi).
        if (raw.root_id === null || raw.root_id === '') {
          if (!(await isHost(who, r.channel))) throw httpErr(403, 'chỉ người chủ trì xoá luồng bình luận');
          s.meet_thread = null; ev = { root_id: null }; break;
        }
        if (!idOk(raw.root_id)) throw httpErr(400, 'root_id không hợp lệ');
        // Luồng của cuộc gọi trước (khác mã cuộc gọi) không dùng lại: mỗi cuộc họp một luồng mới.
        if (s.meet_thread && !(s.meet_thread_call && r.callId && s.meet_thread_call !== r.callId))
          return { type, root_id: s.meet_thread, existing: true, from: { user_id: me, name: who.name, bot: !!who.is_bot }, at: Date.now() };
        s.meet_thread = raw.root_id; s.meet_thread_call = r.callId || ''; ev = { root_id: raw.root_id }; break;
      }
      case 'mute': case 'unmute_request': case 'screen_request':
        if (!idOk(raw.user_id)) throw httpErr(400, 'user_id không hợp lệ');
        ev = { user_id: raw.user_id }; break;
      case 'mute_all': ev = { except: (Array.isArray(raw.except) ? raw.except : []).filter(idOk).slice(0, 50) }; break;
      case 'star': ev = { user_id: idOk(raw.user_id) ? raw.user_id : null }; s.star = ev.user_id; break;
      case 'web_open': case 'web_nav': {
        if (!urlOk(raw.url)) throw httpErr(400, 'url phải là http(s)');
        if (type === 'web_nav' && s.web?.driver !== me) throw httpErr(403, 'chỉ người đang mở trang web điều khiển được');
        ev = { url: str(raw.url, 2000) };
        s.web = { url: ev.url, x: 0, y: 0, driver: type === 'web_open' ? me : s.web.driver, driver_name: type === 'web_open' ? who.name : s.web.driver_name };
        break;
      }
      case 'web_scroll': case 'web_click':
        if (!s.web || s.web.driver !== me) throw httpErr(403, 'chỉ người đang mở trang web điều khiển được');
        ev = { x: frac(raw.x), y: frac(raw.y) };
        if (type === 'web_scroll') Object.assign(s.web, ev);
        break;
      case 'web_close':
        if (s.web && s.web.driver !== me && !(await isHost(who, r.channel))) throw httpErr(403, 'chỉ người mở trang hoặc người chủ trì');
        s.web = null; ev = {}; break;
      case 'stage': {
        const kind = String(raw.kind || '');
        if (!['markdown', 'image', 'video', 'slides', 'draw', 'html', 'scene', 'clear'].includes(kind)) throw httpErr(400, 'stage.kind không hợp lệ');
        if (kind === 'html') { ev = htmlStage(s, raw); s.stage = ev; break; }
        if (kind === 'scene') { ev = sceneStage(s, raw); s.stage = ev; break; }
        if ((kind === 'image' || kind === 'video') && !urlOk(raw.url)) throw httpErr(400, 'stage.url phải là http(s)');
        ev = kind === 'clear' ? { kind } : {
          kind,
          ...(raw.content !== undefined || raw.text !== undefined ? { content: str(raw.content ?? raw.text, 20_000) } : {}),
          ...(raw.url ? { url: str(raw.url, 2000) } : {}),
          ...(Array.isArray(raw.items) ? { items: raw.items.slice(0, 40).map((it) => ({ title: str(it?.title, 200), body_md: str(it?.body_md, 3000), ...(urlOk(it?.image_url) ? { image_url: str(it.image_url, 2000) } : {}) })) } : {}),
          ...(raw.index !== undefined ? { index: Math.max(0, Math.floor(Number(raw.index) || 0)) } : {}),
          ...(Array.isArray(raw.strokes) ? { strokes: raw.strokes.slice(0, 200).map((st) => ({ points: (Array.isArray(st?.points) ? st.points : []).slice(0, 500).map((p) => [frac(p?.[0]), frac(p?.[1])]), color: str(st?.color || '#ff3b30', 16), width: Math.min(40, Math.max(1, Number(st?.width) || 4)) })) } : {}),
        };
        if (kind === 'slides' && !ev.items?.length) {
          if (s.stage?.kind !== 'slides') throw httpErr(400, 'slides cần items');
          ev = { ...s.stage, index: ev.index ?? s.stage.index ?? 0 }; // chỉ đổi trang
        }
        if (ev.kind === 'slides') ev.index = Math.min(ev.index ?? 0, ev.items.length - 1);
        s.stage = kind === 'clear' ? null : ev;
        break;
      }
      case 'audio': {
        const action = String(raw.action || 'play');
        const kind = raw.kind === 'music' ? 'music' : raw.kind === 'sfx' ? 'sfx' : 'tts';
        if (!['play', 'pause', 'stop', 'volume'].includes(action)) throw httpErr(400, 'audio.action phải là play | pause | stop | volume');
        if (action === 'play' && !urlOk(raw.url)) throw httpErr(400, 'audio.url phải là http(s)');
        if (kind === 'sfx') { ev = { kind, action: 'play', url: str(raw.url, 2000), volume: raw.volume === undefined ? 0.8 : frac(raw.volume) }; break; }
        const prev = kind === 'music' ? s.music : s.audio;
        ev = { kind, action, ...(raw.url ? { url: str(raw.url, 2000) } : {}), volume: raw.volume === undefined ? (prev?.volume ?? 1) : frac(raw.volume), loop: raw.loop === undefined ? !!prev?.loop : !!raw.loop, ...(raw.title ? { title: str(raw.title, 120) } : {}) };
        // Nhạc nền (music) và giọng nói (tts) giữ riêng: phát TTS không xoá trạng thái nhạc của người vào sau.
        const next = action === 'stop' ? null : { ...prev, ...ev, url: ev.url || prev?.url, started_at: action === 'play' ? Date.now() : prev?.started_at, action: action === 'volume' ? (prev?.action ?? 'play') : action };
        if (kind === 'music') s.music = next; else s.audio = next;
        break;
      }
      case 'caption': ev = { text: str(raw.text, 500) }; s.caption = ev.text || null; break;
    }
    const out = { type, ...ev, from: { user_id: me, name: who.name, bot: !!who.is_bot }, at: Date.now() };
    if (type === 'comment') { s.comments.push(out); if (s.comments.length > 100) s.comments.splice(0, s.comments.length - 100); }
    return out;
  }
  // Người xem từ xa chỉ nhận phần sân khấu: slide / cảnh, phụ đề, âm thanh (không bình luận, không danh sách người).
  const LIVE_TYPES = new Set(['stage', 'caption', 'audio']);
  const liveView = (st) => ({ stage: st.stage, caption: st.caption, audio: st.audio, music: st.music });
  const liveSend = (res, ev) => { try { res.write(`data: ${JSON.stringify(ev)}\n\n`); } catch {} };
  const broadcast = (r, ev) => {
    for (const c of r.clients) c.conn.send(ev);
    if (r.watchers?.size && LIVE_TYPES.has(ev.type)) { const { from, ...pub } = ev; for (const w of r.watchers) liveSend(w, pub); }
  };
  const pubState = (r) => ({ ...r.state, hands: Object.entries(r.state.hands).map(([user_id, h]) => ({ user_id, ...h })), comments: r.state.comments.slice(-50) });
  const online = (r) => [...new Map([...r.clients].map((c) => [c.who.id, { user_id: c.who.id, name: c.who.name, bot: !!c.who.is_bot }])).values()];

  async function send(r, who, raw, conn) {
    const ev = await apply(r, who, raw);
    r.touched = Date.now();
    if (ev.existing) { conn?.send(ev); return ev; } // meet_thread đã có: chỉ trả lại cho người gửi
    broadcast(r, ev); return ev;
  }

  // ---------------------------------------------------------------- WebSocket
  async function upgrade(req, socket, head) {
    const url = new URL(req.url, 'http://x');
    if (url.pathname !== '/meet/ws' || !req.headers['sec-websocket-key']) return socket.destroy();
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.setNoDelay(true);
    socket.setTimeout(0);
    const conn = new WsConn(socket);
    if (head?.length) conn.feed(head);
    const channel = String(url.searchParams.get('channel') || '');
    let who;
    try {
      who = await auth(bearer(req) || url.searchParams.get('token') || '', req.headers['x-mm-server'] || url.searchParams.get('server') || '', channel);
    } catch (e) {
      conn.send({ type: 'error', message: e.message });
      return conn.close(e.status === 401 ? 4401 : e.status === 403 ? 4403 : 4400, e.message.slice(0, 100));
    }
    const r = room(who.server, channel);
    const call = await callOf(who, channel).catch(() => null);
    if (call?.id && r.callId && call.id !== r.callId) r.state = freshState(); // cuộc gọi mới ở kênh: bỏ trạng thái cuộc trước
    if (call?.id) r.callId = call.id;
    const me = { who, conn };
    r.clients.add(me);
    conn.send({ type: 'state', state: pubState(r), online: online(r), you: { user_id: who.id, host: await isHost(who, channel).catch(() => false) } });
    broadcast(r, { type: 'join', from: { user_id: who.id, name: who.name, bot: !!who.is_bot }, at: Date.now() });
    conn.onmessage = async (m) => {
      if (m?.t === 'ping' || m?.type === 'ping') return conn.send({ type: 'pong' });
      try { await send(r, who, m, conn); } catch (e) { conn.send({ type: 'error', message: e.message, ...(m?.ref ? { ref: str(m.ref, 64) } : {}) }); }
    };
    conn.onclose = () => {
      r.clients.delete(me);
      r.touched = Date.now();
      if (r.state.web?.driver === who.id && ![...r.clients].some((c) => c.who.id === who.id)) { r.state.web = null; broadcast(r, { type: 'web_close', from: { user_id: who.id, name: who.name, bot: !!who.is_bot }, at: Date.now() }); }
      broadcast(r, { type: 'leave', from: { user_id: who.id, name: who.name, bot: !!who.is_bot }, at: Date.now() });
    };
  }

  // ---------------------------------------------------------------- HTTP
  async function readJson(req, max = 512 * 1024) {
    let n = 0; const chunks = [];
    for await (const c of req) { n += c.length; if (n > max) throw httpErr(413, 'body quá lớn'); chunks.push(c); }
    if (!n) return {};
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw httpErr(400, 'body không phải JSON'); }
  }
  async function readBody(req, max) {
    let n = 0; const chunks = [];
    for await (const c of req) { n += c.length; if (n > max) throw httpErr(413, 'tệp quá lớn'); chunks.push(c); }
    return Buffer.concat(chunks);
  }
  /** Slide (.html) và tệp của slide: công khai theo tên băm; hỗ trợ Range cho video / âm thanh. */
  function serveFile(req, res, kind, id, ext) {
    if (kind === 'deck' && ext !== '.html') { res.writeHead(404); return res.end(); }
    const file = path.join(DECK_DIR, `${id}${ext}`);
    let st; try { st = fs.statSync(file); } catch { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('not found'); }
    const type = kind === 'deck' ? 'text/html; charset=utf-8' : EXT_MIME[ext] || 'application/octet-stream';
    const base = { 'content-type': type, 'accept-ranges': 'bytes', 'cache-control': 'public, max-age=31536000, immutable', 'access-control-allow-origin': '*',
      ...(ext === '.svg' ? { 'content-security-policy': "script-src 'none'" } : {}) };
    const range = /^bytes=(\d*)-(\d*)$/.exec(String(req.headers.range || ''));
    if (range && (range[1] || range[2])) {
      const start = range[1] ? Number(range[1]) : Math.max(0, st.size - Number(range[2]));
      const end = range[1] && range[2] ? Math.min(Number(range[2]), st.size - 1) : st.size - 1;
      if (start > end || start >= st.size) { res.writeHead(416, { 'content-range': `bytes */${st.size}` }); return res.end(); }
      res.writeHead(206, { ...base, 'content-length': end - start + 1, 'content-range': `bytes ${start}-${end}/${st.size}` });
      return req.method === 'HEAD' ? res.end() : fs.createReadStream(file, { start, end }).pipe(res);
    }
    res.writeHead(200, { ...base, 'content-length': st.size });
    return req.method === 'HEAD' ? res.end() : fs.createReadStream(file).pipe(res);
  }
  async function participants(who, channel) {
    const call = await callOf(who, channel).catch(() => null);
    if (!call) return { active: false, list: [] };
    const sessions = Array.isArray(call.sessions) ? call.sessions : Object.entries(call.sessions || call.states || {}).map(([session_id, v]) => ({ session_id, ...v }));
    const list = [];
    for (const x of sessions) {
      const uid = x.user_id || x.userId;
      if (!uid) continue;
      const u = await cached(`u ${who.server} ${uid}`, 600_000, () => mmGet(who.server, who.token, `/users/${uid}`)).catch(() => null);
      list.push({ user_id: uid, name: u ? (u.nickname || [u.first_name, u.last_name].filter(Boolean).join(' ') || u.username) : uid, username: u?.username,
        muted: !(x.unmuted ?? false), video: !!(x.video ?? false), screen: !!(call.screen_sharing_session_id && call.screen_sharing_session_id === x.session_id) || call.screen_sharing_id === uid,
        hand: !!(x.raised_hand) });
    }
    return { active: true, call_id: call.id, start_at: call.start_at, host_id: call.host_id || call.owner_id, list };
  }
  async function tts(b) {
    if (!TTS_URL) throw httpErr(503, 'trạm chưa bật TTS');
    const text = str(b?.text, 3000).trim();
    if (!text) throw httpErr(400, 'text trống');
    const r = await fetch(`${TTS_URL}/tts`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text, voice: b.voice || VOICE, rate: b.rate }), signal: AbortSignal.timeout(60_000) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.file) throw httpErr(424, j.error || `tts ${r.status}`); // không dùng 5xx: Cloudflare thay bằng trang HTML
    return { url: `${PUBLIC}/meet/tts/${j.file}`, duration_ms: j.duration_ms, text };
  }

  // ---------------------------------------------------------------- trình chiếu tự chạy
  // r.show = {id, deck, items:[{slide, step, text, url, duration_ms}], i, paused, timer, who, gap, duck}; state.show = tiến độ công khai.
  const showPub = (sh) => sh ? { i: sh.i, n: sh.items.length, paused: sh.paused, slide: sh.items[Math.min(sh.i, sh.items.length - 1)]?.slide ?? 0, started_at: sh.started_at } : null;
  function showEnd(r, sh, why) {
    clearTimeout(sh.timer);
    if (r.show !== sh) return;
    r.show = null; r.state.show = null;
    send(r, sh.who, { type: 'caption', text: '' }).catch(() => {});
    if (sh.duck !== null) send(r, sh.who, { type: 'audio', kind: 'music', action: 'volume', volume: sh.duck }).catch(() => {});
    log('meet', r.server, r.channel, 'present', why, `${sh.i}/${sh.items.length}`);
  }
  async function showStep(r, sh) {
    if (r.show !== sh || sh.paused) return;
    if (sh.i >= sh.items.length) return showEnd(r, sh, 'xong');
    const it = sh.items[sh.i];
    try {
      const cur = r.state.stage;
      if (!(cur?.kind === 'html' && cur.deck === sh.deck && cur.slide === it.slide && cur.step === it.step))
        await send(r, sh.who, { type: 'stage', kind: 'html', deck: sh.deck, slide: it.slide, step: it.step });
      await send(r, sh.who, { type: 'audio', kind: 'tts', action: 'play', url: it.url, volume: 1 });
      await send(r, sh.who, { type: 'caption', text: it.text.slice(0, 500) });
    } catch (e) { log('meet lỗi', 'present', e.message); }
    r.state.show = showPub(sh);
    const nx = sh.items[sh.i + 1];
    const next = () => { sh.i++; showStep(r, sh); };
    // Sang trang mới: nhạc nền dâng lên trong lúc chuyển trang rồi hạ lại trước câu kế (nếu đang có nhạc).
    if (nx && nx.slide !== it.slide && sh.swell > 0 && r.state.music?.action === 'play') {
      sh.timer = setTimeout(() => swell(r, sh, nx, next), it.duration_ms + 150);
    } else sh.timer = setTimeout(next, it.duration_ms + (nx && nx.slide !== it.slide ? sh.gap * 2.5 : sh.gap));
  }
  /** Chuyển sang trang của câu nx ngay, nhạc nền 0.1 -> sh.swell (3 nấc, ~0.6 giây), giữ sh.hold, hạ về 0.1 (~0.45 giây), rồi đọc tiếp. */
  function swell(r, sh, nx, then) {
    send(r, sh.who, { type: 'caption', text: '' }).catch(() => {});
    send(r, sh.who, { type: 'stage', kind: 'html', deck: sh.deck, slide: nx.slide, step: nx.step }).catch(() => {});
    const lo = 0.1, hi = sh.swell, up = [0.4, 0.7, 1], down = [0.6, 0.25, 0];
    const vol = (v) => send(r, sh.who, { type: 'audio', kind: 'music', action: 'volume', volume: Math.round(v * 100) / 100 }).catch(() => {});
    const seq = [...up.map((k) => [200, lo + (hi - lo) * k]), [sh.hold, null], ...down.map((k) => [150, lo + (hi - lo) * k])];
    let j = 0;
    const tick = () => {
      if (r.show !== sh || sh.paused) return;
      if (j >= seq.length) return then();
      const [ms, v] = seq[j++];
      if (v !== null) vol(v);
      sh.timer = setTimeout(tick, ms);
    };
    tick();
  }
  async function present(r, who, b) {
    const sh0 = r.show;
    if (b.action) {
      if (b.action === 'status') return { ok: true, show: showPub(sh0) };
      if (!sh0) return { ok: true, show: null };
      if (b.action === 'stop') { showEnd(r, sh0, 'dừng'); return { ok: true, show: null }; }
      if (b.action === 'pause') { sh0.paused = true; clearTimeout(sh0.timer); await send(r, who, { type: 'audio', kind: 'tts', action: 'stop' }).catch(() => {}); r.state.show = showPub(sh0); return { ok: true, show: r.state.show }; }
      if (b.action === 'resume') { if (sh0.paused) { sh0.paused = false; showStep(r, sh0); } return { ok: true, show: showPub(sh0) }; }
      throw httpErr(400, 'action phải là stop | pause | resume | status');
    }
    const deck = String(b.deck || r.state.stage?.deck || '');
    const meta = /^[a-f0-9]{24}$/.test(deck) ? loadMeta(deck) : null;
    if (!meta) throw httpErr(404, 'không có bộ slide này (tải lên bằng /deck trước)');
    const raw = Array.isArray(b.items) ? b.items.slice(0, 400) : [];
    const items = raw.map((x) => ({ slide: Math.max(0, Math.min(meta.slides.length - 1, Math.floor(Number(x.slide) || 0))), step: x.step === 'all' ? 999 : Math.max(0, Math.floor(Number(x.step) || 0)), text: str(x.text, 1500).trim() })).filter((x) => x.text);
    if (!items.length) throw httpErr(400, 'items trống: [{slide (từ 0), step, text}]');
    for (const it of items) it.step = Math.min(it.step, meta.slides[it.slide]?.steps ?? 0);
    // Tạo sẵn giọng đọc (4 câu song song); câu nào lỗi thì thử lại.
    let k = 0;
    const one = async (it) => { for (let a = 0; ; a++) { try { const t = await tts({ text: it.text, voice: b.voice, rate: b.rate }); it.url = t.url; it.duration_ms = Number(t.duration_ms) || 2000; return; } catch (e) { if (a >= 3) throw e; await new Promise((ok) => setTimeout(ok, 1500 * (a + 1))); } } };
    await Promise.all(Array.from({ length: Math.min(4, items.length) }, async () => { while (k < items.length) await one(items[k++]); }));
    if (sh0) showEnd(r, sh0, 'thay bằng bản mới');
    const music = r.state.music;
    const duck = music && music.action === 'play' && (music.volume ?? 1) > 0.1 ? music.volume : null;
    if (duck !== null) await send(r, who, { type: 'audio', kind: 'music', action: 'volume', volume: 0.1 }).catch(() => {});
    const sh = { deck, items, i: Math.max(0, Math.min(items.length - 1, Math.floor(Number(b.from) || 0))), paused: false, timer: null, who, gap: Math.max(150, Math.min(3000, Number(b.gap_ms) || 350)), duck, swell: b.music_swell === undefined ? 0.4 : Math.max(0, Math.min(1, Number(b.music_swell) || 0)), hold: Math.max(300, Math.min(8000, Number(b.swell_ms) || 1800)), started_at: Date.now() };
    r.show = sh;
    log('meet', r.server, r.channel, `@${who.username}`, 'present', `${items.length} câu`);
    showStep(r, sh);
    return { ok: true, items: items.length, duration_ms: items.reduce((a, x) => a + x.duration_ms + sh.gap, 0) };
  }

  async function handle(req, res, url) {
    const json = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)); };
    try {
      const p = url.pathname;
      const f = /^\/meet\/tts\/([a-f0-9]{24}\.mp3)$/.exec(p);
      if (f && (req.method === 'GET' || req.method === 'HEAD')) {
        const file = path.join(TTS_DIR, f[1]);
        let st; try { st = fs.statSync(file); } catch { return json(404, { error: 'không có tệp' }); }
        const range = /^bytes=(\d*)-(\d*)$/.exec(String(req.headers.range || ''));
        if (range && (range[1] || range[2])) {
          const start = range[1] ? Number(range[1]) : Math.max(0, st.size - Number(range[2]));
          const end = range[1] && range[2] ? Math.min(Number(range[2]), st.size - 1) : st.size - 1;
          if (start > end || start >= st.size) { res.writeHead(416, { 'content-range': `bytes */${st.size}` }); return res.end(); }
          res.writeHead(206, { 'content-type': 'audio/mpeg', 'content-length': end - start + 1, 'content-range': `bytes ${start}-${end}/${st.size}`, 'accept-ranges': 'bytes', 'cache-control': 'public, max-age=86400' });
          return req.method === 'HEAD' ? res.end() : fs.createReadStream(file, { start, end }).pipe(res);
        }
        res.writeHead(200, { 'content-type': 'audio/mpeg', 'content-length': st.size, 'accept-ranges': 'bytes', 'cache-control': 'public, max-age=86400' });
        return req.method === 'HEAD' ? res.end() : fs.createReadStream(file).pipe(res);
      }
      if (p === '/meet/scenes.html' && (req.method === 'GET' || req.method === 'HEAD')) {
        res.writeHead(SCENES ? 200 : 404, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=300', 'access-control-allow-origin': '*' });
        return res.end(req.method === 'HEAD' ? undefined : SCENES);
      }
      const lv = /^\/meet\/live\/([a-z0-9]{26})\/([A-Za-z0-9_-]{22})(\/events)?$/.exec(p);
      if (lv && req.method === 'GET') {
        const server = String(url.searchParams.get('s') || 'https://chat.flygo.vn').replace(/\/+$/, '').toLowerCase();
        const want = liveKey(server, lv[1]);
        if (lv[2].length !== want.length || !crypto.timingSafeEqual(Buffer.from(lv[2]), Buffer.from(want))) return json(404, { error: 'link không hợp lệ' });
        if (!lv[3]) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); return res.end(LIVE_HTML); }
        const r = room(server, lv[1]);
        res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-transform', 'x-accel-buffering': 'no', connection: 'keep-alive' });
        liveSend(res, { type: 'snapshot', ...liveView(r.state) });
        r.watchers.add(res);
        const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 15_000);
        req.on('close', () => { clearInterval(ping); r.watchers.delete(res); });
        return;
      }
      const d = /^\/meet\/(deck|asset)\/([a-f0-9]{24})(\.[a-z0-9]{2,5})$/.exec(p);
      if (d && (req.method === 'GET' || req.method === 'HEAD')) return serveFile(req, res, d[1], d[2], d[3]);
      const m = /^\/meet\/([a-z0-9]{26})\/(cmd|state|tts|deck|deck_frames|asset|live|present)$/.exec(p);
      if (!m) return json(404, { error: 'not found' });
      const [, channel, op] = m;
      const who = await auth(bearer(req), req.headers['x-mm-server'], channel);
      const r = room(who.server, channel);
      if (op === 'state' && req.method === 'GET') {
        const parts = await participants(who, channel);
        if (parts.call_id && r.callId && parts.call_id !== r.callId) r.state = freshState(); // cuộc gọi mới
        if (parts.call_id) r.callId = parts.call_id;
        return json(200, { ...pubState(r), call: { active: parts.active, call_id: parts.call_id, start_at: parts.start_at, host_id: parts.host_id }, participants: parts.list, online: online(r), you: { user_id: who.id, host: await isHost(who, channel).catch(() => false) } });
      }
      if (op === 'present' && req.method === 'POST') {
        if (!(await isHost(who, channel))) throw httpErr(403, 'chỉ người chủ trì');
        return json(200, await present(r, who, await readJson(req, 2 * 1024 * 1024)));
      }
      if (op === 'live' && req.method === 'POST') {
        const first = !r.state.live_announced;
        r.state.live_announced = true;
        return json(200, { url: liveUrl(who.server, channel), first });
      }
      if (op === 'cmd' && req.method === 'POST') {
        const ev = await send(r, who, await readJson(req));
        if (ev.type !== 'react' && ev.type !== 'comment' && ev.type !== 'hand') log('meet', who.server, channel, `@${who.username}`, ev.type);
        return json(200, { ok: true, event: ev });
      }
      if (op === 'tts' && req.method === 'POST') {
        const b = await readJson(req);
        if (b.play && !(await isHost(who, channel))) throw httpErr(403, 'chỉ người chủ trì phát âm thanh cho cả phòng');
        const t = await tts(b);
        if (b.play) {
          await send(r, who, { type: 'audio', kind: 'tts', action: 'play', url: t.url, volume: 1 });
          const cap = t.text.slice(0, 500);
          await send(r, who, { type: 'caption', text: cap });
          // Nói xong (+1 giây): xoá phụ đề và trạng thái giọng nói, nếu chưa có câu khác thay vào.
          const url = t.url;
          setTimeout(() => {
            if (r.state.caption === cap) send(r, who, { type: 'caption', text: '' }).catch(() => {});
            if (r.state.audio?.url === url) r.state.audio = null;
          }, (Number(t.duration_ms) || 3000) + 1000).unref?.();
          log('meet', who.server, channel, `@${who.username}`, 'say', `${t.duration_ms}ms`);
        }
        return json(200, { url: t.url, duration_ms: t.duration_ms });
      }
      if (op === 'deck_frames' && req.method === 'POST') {
        if (!(await isHost(who, channel))) throw httpErr(403, 'chỉ người chủ trì');
        const b = await readJson(req, 1024 * 1024);
        const id = String(b.deck || '');
        const meta = /^[a-f0-9]{24}$/.test(id) ? loadMeta(id) : null;
        if (!meta) throw httpErr(404, 'không có bộ slide này');
        const ok = `${PUBLIC}/meet/asset/`;
        const frames = { ...(meta.frames || {}) };
        for (const [k, v] of Object.entries(b.frames || {})) if (/^\d+\.\d+$/.test(k) && String(v).startsWith(ok)) frames[k] = str(v, 300);
        meta.frames = frames;
        fs.writeFileSync(metaFile(id), JSON.stringify(meta));
        // Đang chiếu đúng bộ này: phát lại sân khấu để máy không chạy web nhận ảnh ngay.
        if (r.state.stage?.kind === 'html' && r.state.stage.deck === id) {
          r.state.stage = htmlStage(r.state, {});
          broadcast(r, { type: 'stage', ...r.state.stage, refresh: true, from: { user_id: who.id, name: who.name, bot: !!who.is_bot }, at: Date.now() });
        }
        return json(200, { ok: true, frames: Object.keys(frames).length });
      }
      if ((op === 'deck' || op === 'asset') && req.method === 'POST') {
        if (!(await isHost(who, channel))) throw httpErr(403, 'chỉ người chủ trì tải slide / tệp cho cuộc họp');
        if (op === 'deck') {
          const b = await readJson(req, 4 * 1024 * 1024);
          const out = saveDeck(b.html, b.title);
          log('meet', who.server, channel, `@${who.username}`, 'deck', out.deck, `${out.slides.length} trang`);
          return json(200, out);
        }
        const ext = MIME_EXT[String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase()];
        if (!ext) throw httpErr(415, `loại tệp không hỗ trợ (được: ${Object.keys(MIME_EXT).join(', ')})`);
        const buf = await readBody(req, 60 * 1024 * 1024);
        if (!buf.length) throw httpErr(400, 'tệp trống');
        const id = crypto.createHash('sha256').update(buf).digest('hex').slice(0, 24);
        fs.writeFileSync(path.join(DECK_DIR, `${id}${ext}`), buf);
        return json(200, { url: `${PUBLIC}/meet/asset/${id}${ext}`, bytes: buf.length });
      }
      return json(405, { error: 'method không hợp lệ' });
    } catch (e) {
      if (!e.status || e.status >= 500) log('meet lỗi', e.message);
      return json(e.status || 500, { error: e.status ? e.message : 'lỗi trạm' });
    }
  }
  return { handle, upgrade };
}

// Trang xem từ xa: nạp slide / cảnh trong khung (cùng nguồn push.flygo.vn nên gọi được flygoGo / flygoScene), phụ đề và âm thanh
// theo sự kiện SSE. Trình duyệt chặn tự phát tiếng: người xem bấm "Bật âm thanh" một lần.
const LIVE_HTML = `<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Flygo · Xem trực tiếp</title>
<style>
html,body{margin:0;height:100%;background:#05070d;color:#fff;font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0;background:#05070d}
#wait{position:absolute;inset:0;display:grid;place-items:center;text-align:center;color:#9fb3c6;font-size:18px;padding:24px}
#md{position:absolute;inset:0;display:none;place-items:center;padding:6vh 8vw;box-sizing:border-box}
#md div{max-width:1100px;background:#fff;color:#1f1f1f;border-radius:18px;padding:32px 40px;font-size:clamp(16px,2.2vw,26px);line-height:1.5;white-space:pre-wrap;max-height:88vh;overflow:auto}
#md img{max-width:100%;max-height:88vh;border-radius:12px}
#cap{position:absolute;left:50%;bottom:4vh;transform:translateX(-50%);max-width:86vw;padding:10px 22px;border-radius:14px;background:rgba(0,0,0,.66);font-size:clamp(14px,2.1vw,24px);line-height:1.4;text-align:center;backdrop-filter:blur(8px)}
#cap:empty{display:none}
#snd{position:absolute;right:14px;top:14px;z-index:5;border:0;border-radius:999px;padding:10px 18px;font-size:15px;font-weight:600;background:#2ee0bd;color:#04211c;cursor:pointer;box-shadow:0 8px 24px rgba(0,0,0,.4)}
#live{position:absolute;left:14px;top:14px;z-index:5;font-size:13px;font-weight:700;letter-spacing:.08em;padding:6px 12px;border-radius:999px;background:rgba(229,72,77,.9)}
#live.off{background:rgba(120,120,120,.8)}
</style></head><body>
<div id="wait">Đang chờ người trình bày chiếu nội dung…</div>
<iframe id="f" hidden></iframe>
<div id="md"><div></div></div>
<div id="cap"></div>
<span id="live" class="off">ĐANG KẾT NỐI</span>
<button id="snd">🔊 Bật âm thanh</button>
<script>
const $=(i)=>document.getElementById(i), f=$('f');
let st=null, frameUrl='', ready=false, soundOn=false;
const voice=new Audio(), music=new Audio(); music.loop=true;
function call(live){ if(!ready||!st)return; const w=f.contentWindow; try{
  if(st.kind==='html'&&w.flygoGo) w.flygoGo(st.slide||0, st.step||0, live);
  if(st.kind==='scene'&&w.flygoScene) w.flygoScene({scene:st.scene,data:st.data,theme:st.theme,reveal:st.reveal}, live);
}catch(e){} }
function show(s, live){
  st=s; const web=s&&(s.kind==='html'||s.kind==='scene');
  $('wait').style.display=s?'none':'grid';
  $('md').style.display=s&&!web?'grid':'none';
  f.hidden=!web;
  if(!s)return;
  if(web){ if(s.url!==frameUrl){ frameUrl=s.url; ready=false; f.onload=()=>{ready=true; call(false);}; f.src=s.url; } else call(live); return; }
  const box=$('md').firstElementChild;
  if(s.kind==='image') box.innerHTML='<img src="'+String(s.url).replace(/"/g,'')+'">';
  else box.textContent=s.content||s.text||s.title||'';
}
function audio(a, live){
  if(!a)return;
  const el=a.kind==='music'?music:a.kind==='sfx'?new Audio():voice;
  if(a.action==='stop'||a.action==='pause'){ el.pause(); return; }
  if(typeof a.volume==='number') el.volume=Math.max(0,Math.min(1,a.volume));
  if(a.action==='volume')return;
  if(a.url&&el.src!==a.url) el.src=a.url;
  if(a.kind==='tts'&&!live)return;
  if(soundOn) el.play().catch(()=>{});
}
$('snd').onclick=()=>{ soundOn=true; $('snd').remove(); if(music.src&&music.dataset.on) music.play().catch(()=>{}); };
function connect(){
  const es=new EventSource(location.pathname+'/events'+location.search);
  es.onopen=()=>{$('live').textContent='TRỰC TIẾP';$('live').className='';};
  es.onerror=()=>{$('live').textContent='ĐANG KẾT NỐI LẠI';$('live').className='off';};
  es.onmessage=(m)=>{ const e=JSON.parse(m.data);
    if(e.type==='snapshot'){ show(e.stage,false); $('cap').textContent=e.caption||''; if(e.music&&e.music.action==='play'){ music.dataset.on=1; audio(e.music,false);} return; }
    if(e.type==='stage'){ const {type,at,...s}=e; show(s.kind==='clear'?null:s,true); }
    else if(e.type==='caption') $('cap').textContent=e.text||'';
    else if(e.type==='audio'){ if(e.kind==='music') music.dataset.on=e.action==='play'||e.action==='volume'?1:''; audio(e,true); }
  };
}
connect();
</script></body></html>`;
