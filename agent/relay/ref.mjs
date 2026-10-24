// Tag chat / luồng cho agent kèm quyền tạm (chạy trong trạm đẩy, https://<trạm>/ref/…).
// Người dùng tag một chat (hoặc một luồng) mà bot KHÔNG phải thành viên, kèm hạn dùng: relay cấp "grant" để bot đọc
// (và nếu cho phép thì gửi tin) vào đúng các chat đó trong thời hạn, bằng token quản trị của server. Bot không được
// thêm vào chat nên không thấy gì ngoài phần được tag.
//
//   Người dùng (token máy chủ chat của người + X-MM-Server):
//     POST /ref/grants {bot_id, ttl_sec 60..86400, write, refs:[{channel_id, root_id?}] (≤10)}
//       -> {grant_id, expires_at, write, refs:[{ref_id, kind, channel_id, root_id?, name}]}
//   Bot (token của bot được cấp + X-MM-Server; grant phải cấp cho đúng bot đó và còn hạn):
//     GET  /ref/read?grant=&ref=&before=&limit=&q=   -> {posts:[{id,user,at,message,root_id,files}], more}
//     GET  /ref/thread?grant=&ref=&root=             -> {posts:[…]} (cả luồng, root phải thuộc chat của ref)
//     POST /ref/post {grant, ref, message, root_id?, from_channel?} -> {post_id} (chỉ khi write)
//       Gửi qua incoming webhook của chat đó (relay tạo một lần, mô tả "flygo agent ref"), đứng tên hiển thị + ảnh của
//       bot (cần EnablePostUsernameOverride / EnablePostIconOverride), props.flygo_ref_post = {bot_id, grant_id, from_channel}.
// Log: cấp grant (người, bot, chat, hạn, write) và mỗi lần đọc / gửi (số tin). Không log nội dung tin.
//
// Cấu hình: ref: { servers: { "<url server>": { internal?, adminTokenFile } }, dataDir? }
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const httpErr = (status, message) => Object.assign(new Error(message), { status });
const normServer = (s) => String(s || '').trim().replace(/\/+$/, '').toLowerCase();
const clip = (s, n) => { const t = String(s ?? '').replace(/\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n - 1) + '…' : t; };
const rid = () => crypto.randomBytes(9).toString('base64url');
const EXPIRED = 'quyền đã hết hạn, nhờ người dùng tag lại chat này';

export function createRef(conf = {}, log = console.log) {
  const SERVERS = Object.fromEntries(Object.entries(conf.servers || {}).map(([k, v]) => [normServer(k), v]));
  const dataDir = conf.dataDir || './data';
  const grantsFile = path.join(dataDir, 'ref-grants.json');
  const hooksFile = path.join(dataDir, 'ref-hooks.json');
  const load = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return {}; } };
  const save = (f, v) => { try { fs.mkdirSync(dataDir, { recursive: true }); fs.writeFileSync(f + '.tmp', JSON.stringify(v)); fs.renameSync(f + '.tmp', f); } catch (e) { log('ref lưu lỗi', e.message); } };
  const grants = new Map(Object.entries(load(grantsFile))); // grant_id -> grant
  const hooks = load(hooksFile); // "<server> <channel>" -> hook id
  // Hết hạn vẫn giữ thêm 1 ngày để bot nhận đúng lỗi "quyền đã hết hạn" (410) thay cho "không có quyền".
  const prune = () => { const now = Date.now(); let n = 0; for (const [k, g] of grants) if (g.expires_at + 86_400_000 <= now) { grants.delete(k); n++; } if (n) save(grantsFile, Object.fromEntries(grants)); };
  setInterval(prune, 60_000).unref?.();
  prune();

  const base = (server) => SERVERS[server]?.internal || server;
  const adminToken = (server) => { try { return fs.readFileSync(SERVERS[server].adminTokenFile, 'utf8').trim(); } catch { return ''; } };
  async function mm(server, token, method, p, body) {
    const r = await fetch(`${base(server)}/api/v4${p}`, {
      method, headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15_000),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw httpErr(r.status, `${method} ${p.split('?')[0]} -> ${r.status}`);
    return j;
  }
  const admin = (server, method, p, body) => mm(server, adminToken(server), method, p, body);

  const users = new Map(); // server user -> {name, exp}
  async function userName(server, id) {
    const k = `${server} ${id}`, c = users.get(k);
    if (c && c.exp > Date.now()) return c.name;
    const u = await admin(server, 'GET', `/users/${id}`).catch(() => null);
    const name = u ? (u.nickname || [u.first_name, u.last_name].filter(Boolean).join(' ') || u.username) : id;
    users.set(k, { name, exp: Date.now() + 10 * 60_000 });
    return name;
  }
  async function chatName(server, ch, viewer) {
    if (ch.type === 'D') {
      const other = String(ch.name).split('__').find((x) => x !== viewer) || viewer;
      return `Chat với ${await userName(server, other)}`;
    }
    return ch.display_name || ch.name;
  }

  /** Người gọi theo token: {server, id, name, is_bot}. */
  const idCache = new Map();
  async function caller(req) {
    const server = normServer(req.headers['x-mm-server']);
    if (!SERVERS[server]) throw httpErr(400, `server ${server || '(trống)'} không dùng trạm này`);
    if (!adminToken(server)) throw httpErr(503, 'trạm chưa có quyền quản trị trên server này');
    const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
    if (!m) throw httpErr(401, 'thiếu token');
    const key = `${server}\n${m[1]}`, c = idCache.get(key);
    if (c && c.exp > Date.now()) return c.who;
    const me = await mm(server, m[1], 'GET', '/users/me').catch((e) => {
      throw e.status === 401 || e.status === 403 ? httpErr(401, 'token không hợp lệ') : httpErr(503, `chưa kiểm tra được với ${server}`);
    });
    if (me.delete_at) throw httpErr(403, 'tài khoản đã bị khoá');
    const who = { server, id: me.id, username: me.username, is_bot: !!me.is_bot };
    idCache.set(key, { who, exp: Date.now() + 60_000 });
    return who;
  }

  // ---------------------------------------------------------------- người dùng cấp quyền
  async function createGrant(who, b) {
    if (who.is_bot) throw httpErr(403, 'bot không tự cấp quyền được');
    const botId = String(b?.bot_id || '');
    if (!/^[a-z0-9]{26}$/.test(botId)) throw httpErr(400, 'bot_id không hợp lệ');
    const ttl = Math.round(Number(b?.ttl_sec));
    if (!(ttl >= 60 && ttl <= 86400)) throw httpErr(400, 'ttl_sec phải trong 60..86400');
    const raw = Array.isArray(b?.refs) ? b.refs : [];
    if (!raw.length || raw.length > 10) throw httpErr(400, 'refs cần 1..10 chat / luồng');
    // bot: trợ lý flygo-agent mà người gọi được dùng (chủ, hoặc trong allow= của mốc)
    const bu = await admin(who.server, 'GET', `/users/${botId}`).catch(() => null);
    if (!bu?.is_bot || bu.delete_at || !/\[flygo-agent/i.test(bu.bot_description || '')) throw httpErr(404, 'không có trợ lý này');
    const bot = await admin(who.server, 'GET', `/bots/${botId}`);
    const allow = (/\[flygo-agent[^\]]*\ballow=([a-z0-9,]+)/i.exec(bu.bot_description || '')?.[1] || '').split(',').filter(Boolean);
    if (bot.owner_id !== who.id && !allow.includes(who.id)) throw httpErr(403, 'bạn không được dùng trợ lý này');
    const refs = [];
    for (const r of raw) {
      const cid = String(r?.channel_id || '');
      if (!/^[a-z0-9]{26}$/.test(cid)) throw httpErr(400, `channel_id không hợp lệ: ${cid}`);
      const ch = await admin(who.server, 'GET', `/channels/${cid}`).catch(() => null);
      if (!ch || ch.delete_at) throw httpErr(404, `không có chat ${cid}`);
      const member = await admin(who.server, 'GET', `/channels/${cid}/members/${who.id}`).then(() => true, () => false);
      if (!member) throw httpErr(403, `bạn không ở chat ${cid}`);
      let root = '', name = await chatName(who.server, ch, who.id);
      if (r.root_id) {
        const p = await admin(who.server, 'GET', `/posts/${String(r.root_id)}`).catch(() => null);
        if (!p || p.channel_id !== cid) throw httpErr(404, `không có luồng ${r.root_id} trong chat ${cid}`);
        root = p.root_id || p.id; // tag một tin trả lời = tag cả luồng của nó
        const rp = root === p.id ? p : await admin(who.server, 'GET', `/posts/${root}`);
        name = `${name} › "${clip(rp.message || '(tệp)', 60)}"`;
      }
      if (refs.some((x) => x.channel_id === cid && x.root_id === root)) continue;
      refs.push({ ref_id: rid(), kind: root ? 'thread' : 'chat', channel_id: cid, ...(root ? { root_id: root } : {}), name, team_id: ch.team_id || '' });
    }
    const g = { grant_id: rid(), server: who.server, user_id: who.id, user: who.username, bot_id: botId, bot: bu.username, bot_display: bot.display_name || bu.username,
      write: !!b.write, created_at: Date.now(), expires_at: Date.now() + ttl * 1000, refs };
    grants.set(g.grant_id, g); save(grantsFile, Object.fromEntries(grants));
    log('ref grant', who.server, `user=${who.username}`, `bot=${bu.username}`, `chats=${refs.map((x) => x.channel_id + (x.root_id ? '/' + x.root_id : '')).join(',')}`, `ttl=${ttl}`, `write=${g.write}`, g.grant_id);
    return { grant_id: g.grant_id, expires_at: g.expires_at, write: g.write, refs: refs.map(({ team_id, ...x }) => x) };
  }

  // ---------------------------------------------------------------- bot dùng quyền
  function grantFor(who, gid, refId) {
    const g = grants.get(String(gid || ''));
    if (!g || g.server !== who.server || g.bot_id !== who.id) throw httpErr(404, 'không có quyền này (grant không đúng bot)');
    if (g.expires_at <= Date.now()) throw httpErr(410, EXPIRED);
    const ref = g.refs.find((x) => x.ref_id === refId);
    if (!ref) throw httpErr(404, 'không có ref này trong grant');
    return { g, ref };
  }
  async function compact(server, posts) {
    const out = [];
    for (const p of posts) {
      if (p.type && p.type.startsWith('system_')) continue;
      out.push({ id: p.id, user: p.props?.override_username || await userName(server, p.user_id), at: new Date(p.create_at).toISOString(),
        message: String(p.message || '').slice(0, 4000), root_id: p.root_id || '', files: (p.metadata?.files || []).map((f) => f.name) });
    }
    return out;
  }
  const ordered = (r) => (r.order || []).map((id) => r.posts[id]).filter(Boolean);

  async function read(who, q) {
    const { g, ref } = grantFor(who, q.get('grant'), q.get('ref'));
    const limit = Math.max(1, Math.min(50, Number(q.get('limit')) || 30));
    const before = String(q.get('before') || '');
    const term = String(q.get('q') || '').trim().toLowerCase();
    let posts = [], more = false;
    if (ref.root_id) { // luồng: cả luồng rồi lọc tại chỗ
      let all = ordered(await admin(g.server, 'GET', `/posts/${ref.root_id}/thread`)).sort((a, b) => a.create_at - b.create_at);
      if (before) { const t = all.find((p) => p.id === before)?.create_at; if (t) all = all.filter((p) => p.create_at < t); }
      if (term) all = all.filter((p) => String(p.message || '').toLowerCase().includes(term));
      more = all.length > limit; posts = all.slice(-limit);
    } else if (!term) {
      const r = await admin(g.server, 'GET', `/channels/${ref.channel_id}/posts?per_page=${limit}${before ? `&before=${before}` : ''}`);
      posts = ordered(r).reverse(); more = posts.length === limit;
    } else { // tìm từ khoá: quét ngược tối đa 2000 tin của chat
      let cur = before, scanned = 0;
      while (scanned < 2000 && posts.length < limit) {
        const page = ordered(await admin(g.server, 'GET', `/channels/${ref.channel_id}/posts?per_page=200${cur ? `&before=${cur}` : ''}`));
        if (!page.length) break;
        scanned += page.length;
        for (const p of page) if (String(p.message || '').toLowerCase().includes(term) && posts.length < limit) posts.push(p);
        cur = page[page.length - 1].id;
        if (page.length < 200) break;
      }
      posts.reverse(); more = posts.length === limit;
    }
    const out = await compact(g.server, posts);
    log('ref read', g.server, `bot=${who.username}`, g.grant_id, ref.channel_id + (ref.root_id ? '/' + ref.root_id : ''), `n=${out.length}${term ? ' (tìm)' : ''}`);
    return { posts: out, more };
  }

  async function thread(who, q) {
    const { g, ref } = grantFor(who, q.get('grant'), q.get('ref'));
    const root = String(q.get('root') || ref.root_id || '');
    if (!/^[a-z0-9]{26}$/.test(root)) throw httpErr(400, 'thiếu root');
    if (ref.root_id && root !== ref.root_id) throw httpErr(403, 'ref này chỉ cho đọc đúng luồng đã tag');
    const rp = await admin(g.server, 'GET', `/posts/${root}`).catch(() => null);
    if (!rp || rp.channel_id !== ref.channel_id) throw httpErr(404, 'luồng không thuộc chat của ref');
    const all = ordered(await admin(g.server, 'GET', `/posts/${rp.root_id || rp.id}/thread`)).sort((a, b) => a.create_at - b.create_at);
    const out = await compact(g.server, all.length > 200 ? [all[0], ...all.slice(-199)] : all);
    log('ref thread', g.server, `bot=${who.username}`, g.grant_id, `${ref.channel_id}/${rp.root_id || rp.id}`, `n=${out.length}`);
    return { posts: out, truncated: all.length > 200 };
  }

  async function hookFor(server, channelId) {
    const k = `${server} ${channelId}`;
    if (hooks[k]) {
      const h = await admin(server, 'GET', `/hooks/incoming/${hooks[k]}`).catch(() => null);
      if (h && !h.delete_at && h.channel_id === channelId) return hooks[k];
    }
    const h = await admin(server, 'POST', '/hooks/incoming', { channel_id: channelId, display_name: 'flygo agent ref', description: 'flygo agent ref', channel_locked: true });
    hooks[k] = h.id; save(hooksFile, hooks);
    log('ref hook', server, channelId, h.id);
    return h.id;
  }

  async function post(who, b) {
    const { g, ref } = grantFor(who, b?.grant, b?.ref);
    if (!g.write) throw httpErr(403, 'quyền này chỉ cho đọc, không cho gửi tin');
    const message = String(b?.message ?? '');
    if (!message.trim()) throw httpErr(400, 'thiếu message');
    if (message.length > 16000) throw httpErr(400, 'message quá dài');
    let root = ref.root_id || '';
    if (!root && b?.root_id) {
      const rp = await admin(g.server, 'GET', `/posts/${String(b.root_id)}`).catch(() => null);
      if (!rp || rp.channel_id !== ref.channel_id) throw httpErr(404, 'root_id không thuộc chat của ref');
      root = rp.root_id || rp.id;
    }
    const nonce = rid();
    const hook = await hookFor(g.server, ref.channel_id);
    const t = Date.now() - 2000;
    const r = await fetch(`${base(g.server)}/hooks/${hook}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(15_000),
      body: JSON.stringify({ text: message, username: g.bot_display, icon_url: `${g.server}/api/v4/users/${g.bot_id}/image`, ...(root ? { root_id: root } : {}),
        props: { flygo_ref_post: { bot_id: g.bot_id, grant_id: g.grant_id, from_channel: String(b?.from_channel || ''), nonce } } }),
    });
    if (!r.ok) throw httpErr(502, `gửi tin lỗi ${r.status}`);
    // webhook không trả id: tìm lại tin vừa gửi theo nonce
    let postId = '';
    for (let i = 0; i < 5 && !postId; i++) {
      const recent = ordered(await admin(g.server, 'GET', `/channels/${ref.channel_id}/posts?since=${t}`).catch(() => ({})));
      postId = recent.find((p) => p.props?.flygo_ref_post?.nonce === nonce)?.id || '';
      if (!postId) await new Promise((res) => setTimeout(res, 300));
    }
    log('ref post', g.server, `bot=${who.username}`, g.grant_id, ref.channel_id + (root ? '/' + root : ''), postId || '(chưa thấy id)');
    return { post_id: postId };
  }

  async function readJson(req, max = 64 * 1024) {
    let n = 0; const chunks = [];
    for await (const c of req) { n += c.length; if (n > max) throw httpErr(413, 'body quá lớn'); chunks.push(c); }
    if (!n) return {};
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw httpErr(400, 'body không phải JSON'); }
  }

  async function handle(req, res, url) {
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)); };
    try {
      const p = url.pathname;
      if (p === '/ref/grants' && req.method === 'POST') return send(200, await createGrant(await caller(req), await readJson(req)));
      const needBot = async () => { const who = await caller(req); if (!who.is_bot) throw httpErr(403, 'chỉ bot được cấp mới dùng được'); return who; };
      if (p === '/ref/read' && req.method === 'GET') return send(200, await read(await needBot(), url.searchParams));
      if (p === '/ref/thread' && req.method === 'GET') return send(200, await thread(await needBot(), url.searchParams));
      if (p === '/ref/post' && req.method === 'POST') { const who = await needBot(); return send(200, await post(who, await readJson(req))); }
      return send(404, { error: 'not found' });
    } catch (e) {
      if (!e.status || e.status >= 500) log('ref lỗi', e.message);
      return send(e.status || 500, { error: e.status ? e.message : 'lỗi trạm' });
    }
  }
  return { handle };
}
