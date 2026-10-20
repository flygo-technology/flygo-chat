// Đăng nhập máy tính bằng QR (chạy trong trạm đẩy flygo-push và các bản sao riêng của từng công ty, https://<trạm>/qr/…).
// Điện thoại đã đăng nhập quét QR trên máy tính, rồi xin relay tạo một token cá nhân (personal access token)
// cho CHÍNH người dùng đó; máy tính đăng nhập bằng token này. Người dùng thường không có quyền tự tạo token
// (create_user_access_token), nên relay tạo bằng token quản trị của server.
//
//   POST   /qr/token              {device, ip}  -> {token, token_id, user_id}
//   GET    /qr/tokens                           -> {tokens: [{token_id, description, is_active}]}
//   DELETE /qr/tokens/<token_id>                -> {ok: true}
// Xác thực: Authorization: Bearer <token Mattermost của người gọi> + X-MM-Server: <url server>.
// Chỉ nhận người dùng thật (không bot, không tài khoản đã khoá). Mattermost không cho biết token đang gọi là
// session hay token cá nhân, nên chặn "token sinh token" bằng giới hạn: tối đa maxActive token QR còn hiệu lực
// mỗi người và perMinute lần tạo mỗi phút. Log ghi email, máy, ip, token_id; KHÔNG ghi token.
//
// Cấu hình (config.json): qr: { servers: { "<url server>": { internal?, adminTokenFile } }, maxActive?, perMinute? }
import fs from 'node:fs';

const PREFIX = 'QR login';
const httpErr = (status, message) => Object.assign(new Error(message), { status });
const normServer = (s) => String(s || '').trim().replace(/\/+$/, '').toLowerCase();
const clean = (s, n) => String(s ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, n);
const stamp = (d = new Date()) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    .formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.day}/${p.month}/${p.year} ${p.hour}:${p.minute}`;
};

export function createQR(conf = {}, log = console.log) {
  const SERVERS = Object.fromEntries(Object.entries(conf.servers || {}).map(([k, v]) => [normServer(k), v]));
  const MAX_ACTIVE = conf.maxActive ?? 5;
  const PER_MINUTE = conf.perMinute ?? 5;
  const hits = new Map(); // server\nuser -> [ms…] (lần tạo token trong 60 giây gần nhất)

  const base = (server) => SERVERS[server]?.internal || server;
  const adminToken = (server) => { try { return fs.readFileSync(SERVERS[server].adminTokenFile, 'utf8').trim(); } catch { return ''; } };
  async function mm(server, token, method, path, body) {
    const r = await fetch(`${base(server)}/api/v4${path}`, {
      method, headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(10_000),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw httpErr(r.status, `${method} ${path} -> ${r.status}${j?.id ? ` ${j.id}` : ''}`);
    return j;
  }

  /** Người gọi: token Mattermost thật của một người dùng (không bot, không bị khoá) trên server đã cấu hình. */
  async function caller(req) {
    const server = normServer(req.headers['x-mm-server']);
    if (!SERVERS[server]) throw httpErr(400, `server ${server || '(trống)'} không dùng trạm này`);
    if (!adminToken(server)) throw httpErr(503, 'trạm chưa có quyền quản trị trên server này');
    const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
    if (!m) throw httpErr(401, 'thiếu token');
    const me = await mm(server, m[1], 'GET', '/users/me').catch((e) => {
      throw e.status === 401 || e.status === 403 ? httpErr(401, 'token không hợp lệ') : httpErr(503, `chưa kiểm tra được với ${server}`);
    });
    if (me.is_bot) throw httpErr(403, 'bot không dùng đăng nhập QR');
    if (me.delete_at) throw httpErr(403, 'tài khoản đã bị khoá');
    return { server, id: me.id, email: String(me.email || ''), username: me.username };
  }

  const qrTokens = async (who) => (await mm(who.server, adminToken(who.server), 'GET', `/users/${who.id}/tokens?per_page=200`))
    .filter((t) => String(t.description || '').startsWith(PREFIX));

  async function create(who, body) {
    const device = clean(body?.device, 60) || 'máy tính';
    const ip = clean(body?.ip, 45).replace(/[^0-9a-fA-F:.]/g, '');
    const key = `${who.server}\n${who.id}`;
    const now = Date.now();
    const recent = (hits.get(key) || []).filter((t) => now - t < 60_000);
    if (recent.length >= PER_MINUTE) throw httpErr(429, `quá ${PER_MINUTE} lần mỗi phút, thử lại sau`);
    recent.push(now); hits.set(key, recent);
    const active = (await qrTokens(who)).filter((t) => t.is_active);
    if (active.length >= MAX_ACTIVE) throw httpErr(409, `đã có ${active.length} máy đăng nhập bằng QR, đăng xuất bớt một máy (GET /qr/tokens, DELETE /qr/tokens/<id>) rồi thử lại`);
    const t = await mm(who.server, adminToken(who.server), 'POST', `/users/${who.id}/tokens`, { description: `${PREFIX} · ${device} · ${stamp()}` });
    log('qr token', who.server, who.email || who.username, JSON.stringify(device), ip || '-', t.id);
    return { token: t.token, token_id: t.id, user_id: who.id };
  }

  async function revoke(who, id) {
    if (!/^[a-z0-9]{26}$/.test(id)) throw httpErr(400, 'token_id không hợp lệ');
    const t = await mm(who.server, adminToken(who.server), 'GET', `/users/tokens/${id}`).catch((e) => { throw e.status === 404 ? httpErr(404, 'không có token này') : e; });
    if (t.user_id !== who.id || !String(t.description || '').startsWith(PREFIX)) throw httpErr(404, 'không có token này');
    await mm(who.server, adminToken(who.server), 'POST', '/users/tokens/revoke', { token_id: id });
    log('qr revoke', who.server, who.email || who.username, id);
    return { ok: true };
  }

  async function readJson(req, max = 4096) {
    let n = 0; const chunks = [];
    for await (const c of req) { n += c.length; if (n > max) throw httpErr(413, 'body quá lớn'); chunks.push(c); }
    if (!n) return {};
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw httpErr(400, 'body không phải JSON'); }
  }

  async function handle(req, res, url) {
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)); };
    try {
      const p = url.pathname;
      if (p === '/qr/token' && req.method === 'POST') { const who = await caller(req); return send(200, await create(who, await readJson(req))); }
      if (p === '/qr/tokens' && req.method === 'GET') {
        const who = await caller(req);
        return send(200, { tokens: (await qrTokens(who)).map((t) => ({ token_id: t.id, description: t.description, is_active: !!t.is_active })) });
      }
      const m = /^\/qr\/tokens\/([^/]+)$/.exec(p);
      if (m && req.method === 'DELETE') { const who = await caller(req); return send(200, await revoke(who, m[1])); }
      return send(404, { error: 'not found' });
    } catch (e) {
      if (!e.status || e.status >= 500) log('qr lỗi', e.message);
      return send(e.status || 500, { error: e.status ? e.message : 'lỗi trạm' });
    }
  }
  return { handle };
}
