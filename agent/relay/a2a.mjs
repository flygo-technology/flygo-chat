// A2A relay cho flygo-agent (chạy trong flygo-push, https://push.flygo.vn/a2a/…).
// Runner nằm sau NAT trên máy cá nhân: mỗi runner giữ MỘT WebSocket ra relay (/a2a/connect), xác thực bằng token bot
// Mattermost (kiểm qua /api/v4/users/me). Relay chuyển JSON-RPC A2A giữa các bot và kiểm quyền:
//   - cùng chủ, hoặc chủ của bên gọi nằm trong allow= của bot được gọi;
//   - khác server (chat.flygo.vn ↔ chat.example.com) chỉ khi email chủ trùng nhau, hoặc hai chủ nằm chung một nhóm
//     ownerAliases (liệt kê tường minh "<server>/<user_id>", không đoán theo email/tên miền);
//   - chủ trong blockedOwners bị chặn cả hai chiều;
//   - độ sâu 1: bot đang làm việc được nhờ thì không nhờ tiếp được.
// Client A2A chuẩn (HTTP) cũng gọi được: GET /a2a/agents/<bot_id>/.well-known/agent-card.json, POST /a2a/agents/<bot_id>
// (JSON-RPC; message/stream trả SSE). Agent Card do relay ký (JWS EdDSA, khoá công khai ở /a2a/.well-known/jwks.json).
// Tệp lớn: bên gửi tải lên Mattermost rồi xin "grant" -> URL /a2a/files/<id> ngắn hạn, chỉ bot được chỉ định tải được.
//
// Giao thức WebSocket (JSON mỗi frame; chuỗi dài được chia thành {t:"part",k,i,n,d}):
//   runner -> relay: hello{card} | list{id} | call{id,to,depth,req} | cancel{id} | grant{id,file_id,to} | ev{cid,data} | done{cid,result?,error?} | ping
//   relay -> runner: welcome{agent} | res{id,result?,error?} | ev{id,data} | done{id,result?,error?} | req{cid,from,depth,req} | cancel{cid} | error{code,message} | pong
//   lịch hẹn (app -> POST /a2a/schedules): relay -> runner sched{cid,user,body}; runner -> relay sched_res{cid,result}
import crypto from 'node:crypto';
import fs from 'node:fs';

const PART = 200_000; // chia chuỗi JSON dài (Cloudflare giới hạn kích thước một message WebSocket)
const METHODS = {
  'message/send': 'message/send', SendMessage: 'message/send',
  'message/stream': 'message/stream', SendStreamingMessage: 'message/stream',
  'tasks/get': 'tasks/get', GetTask: 'tasks/get',
  'tasks/cancel': 'tasks/cancel', CancelTask: 'tasks/cancel',
};

const b64url = (b) => Buffer.from(b).toString('base64url');
/** JSON chuẩn hoá (RFC 8785 rút gọn: khoá sắp xếp, không khoảng trắng) để ký. */
const canon = (v) => (Array.isArray(v) ? `[${v.map(canon).join(',')}]`
  : v && typeof v === 'object' ? `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`
  : JSON.stringify(v));
const httpErr = (status, message) => Object.assign(new Error(message), { status });
const normServer = (s) => String(s || '').trim().replace(/\/+$/, '').toLowerCase();

// ---------------------------------------------------------------- WebSocket tối giản (RFC 6455, chỉ phía server)
class WsConn {
  constructor(socket) {
    this.s = socket;
    this.buf = Buffer.alloc(0);
    this.frag = [];
    this.parts = new Map();
    this.alive = true;
    this.closed = false;
    this.onmessage = null;
    this.onclose = null;
    socket.on('data', (d) => this.feed(d));
    socket.on('close', () => this.#closed());
    socket.on('error', () => this.#closed());
    this.ping = setInterval(() => {
      if (!this.alive) return this.s.destroy();
      this.alive = false;
      this.#frame(9, Buffer.alloc(0));
    }, 25_000);
  }
  feed(d) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, d]) : d;
    for (;;) {
      if (this.buf.length < 2) return;
      const b0 = this.buf[0], b1 = this.buf[1];
      const fin = b0 & 0x80, op = b0 & 0x0f, masked = b1 & 0x80;
      let len = b1 & 0x7f, off = 2;
      if (len === 126) { if (this.buf.length < 4) return; len = this.buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (this.buf.length < 10) return; len = Number(this.buf.readBigUInt64BE(2)); off = 10; }
      if (len > 32 * 1024 * 1024) return this.close(1009, 'too big');
      const mo = off;
      if (masked) off += 4;
      if (this.buf.length < off + len) return;
      let p = Buffer.from(this.buf.subarray(off, off + len));
      if (masked) { const mk = this.buf.subarray(mo, mo + 4); for (let i = 0; i < p.length; i++) p[i] ^= mk[i & 3]; }
      this.buf = this.buf.subarray(off + len);
      this.alive = true;
      if (op === 8) return this.close();
      if (op === 9) { this.#frame(10, p); continue; }
      if (op === 10) continue;
      this.frag.push(p);
      if (!fin) continue;
      const text = Buffer.concat(this.frag).toString('utf8');
      this.frag = [];
      let msg;
      try { msg = JSON.parse(text); } catch { continue; }
      if (msg.t === 'part') { // ráp chuỗi dài
        const arr = this.parts.get(msg.k) ?? [];
        arr[msg.i] = msg.d;
        this.parts.set(msg.k, arr);
        if (arr.filter((x) => x !== undefined).length < msg.n) continue;
        this.parts.delete(msg.k);
        try { msg = JSON.parse(arr.join('')); } catch { continue; }
      }
      try { this.onmessage?.(msg); } catch (e) { console.error('a2a ws handler', e); }
    }
  }
  #frame(op, payload) {
    if (this.closed) return;
    const n = payload.length;
    const head = n < 126 ? Buffer.from([0x80 | op, n]) : n < 65536 ? Buffer.alloc(4) : Buffer.alloc(10);
    if (n >= 126 && n < 65536) { head[0] = 0x80 | op; head[1] = 126; head.writeUInt16BE(n, 2); }
    else if (n >= 65536) { head[0] = 0x80 | op; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2); }
    this.s.write(Buffer.concat([head, payload]));
  }
  send(obj) {
    const s = JSON.stringify(obj);
    if (s.length <= PART) return this.#frame(1, Buffer.from(s));
    const k = crypto.randomUUID(), n = Math.ceil(s.length / PART);
    for (let i = 0; i < n; i++) this.#frame(1, Buffer.from(JSON.stringify({ t: 'part', k, i, n, d: s.slice(i * PART, (i + 1) * PART) })));
  }
  close(code = 1000, reason = '') {
    if (this.closed) return;
    const r = Buffer.from(reason);
    const p = Buffer.alloc(2 + r.length);
    p.writeUInt16BE(code, 0);
    r.copy(p, 2);
    this.#frame(8, p);
    this.s.end();
    this.#closed();
  }
  #closed() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.ping);
    this.s.destroy();
    this.onclose?.();
  }
}

export function createA2A(conf, log) {
  const C = conf || {};
  const PUBLIC = String(C.publicBase || 'https://push.flygo.vn/a2a').replace(/\/+$/, '');
  const SERVERS = Object.fromEntries(Object.entries(C.servers || {}).map(([k, v]) => [normServer(k), v]));
  const blocked = new Set(C.blockedOwners || []);
  // ownerAliases: [{ note?, owners: ["https://chat.flygo.vn/<user_id>", "https://chat.example.com/<user_id>"] }]
  const aliasOf = new Map();
  (C.ownerAliases || []).forEach((g, i) => {
    for (const o of g?.owners || []) {
      const m = /^(.*)\/(\w+)$/.exec(String(o));
      if (m) aliasOf.set(`${normServer(m[1])}/${m[2]}`, i);
    }
  });
  const sameAlias = (a, b) => {
    const x = aliasOf.get(`${a.server}/${a.owner}`);
    return x !== undefined && x === aliasOf.get(`${b.server}/${b.owner}`);
  };
  const CALL_TIMEOUT = (C.callTimeoutSec || 1800) * 1000;
  const MAX_CONCURRENT = C.maxConcurrentCalls || 3;
  const GRANT_TTL = (C.grantTtlSec || 1800) * 1000;

  // ---- khoá ký Agent Card (Ed25519) ----
  const KID = 'flygo-a2a-1';
  let priv = null, jwk = null;
  try {
    priv = crypto.createPrivateKey(fs.readFileSync(C.signingKeyFile));
    jwk = { ...crypto.createPublicKey(priv).export({ format: 'jwk' }), kid: KID, alg: 'EdDSA', use: 'sig' };
  } catch (e) { log('a2a: không có khoá ký Agent Card', e.message); }
  const sign = (card) => {
    if (!priv) return card;
    const { signatures, ...body } = card;
    const protectedHeader = b64url(JSON.stringify({ alg: 'EdDSA', kid: KID, typ: 'JOSE', jku: `${PUBLIC}/.well-known/jwks.json` }));
    const payload = b64url(canon(body));
    const signature = b64url(crypto.sign(null, Buffer.from(`${protectedHeader}.${payload}`), priv));
    return { ...body, signatures: [{ protected: protectedHeader, signature }] };
  };

  const agents = new Map(); // bot id -> { who, conn, card }
  const calls = new Map(); // cid -> { caller, callId, callee, timer, http? }
  const grants = new Map(); // gid -> { fileId, server, token, to, exp }
  const scheds = new Map(); // cid -> { resolve, timer, botId } (app thao tác lịch hẹn, chờ runner trả lời)
  const idCache = new Map(); // server\ntoken -> { who, exp }

  // ---- danh tính qua Mattermost ----
  const base = (server) => SERVERS[server]?.internal || server;
  const adminToken = (server) => { try { return fs.readFileSync(SERVERS[server].adminTokenFile, 'utf8').trim(); } catch { return ''; } };
  async function mmGet(server, token, path) {
    const r = await fetch(`${base(server)}/api/v4${path}`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
    if (!r.ok) throw httpErr(r.status, `${path} -> ${r.status}`);
    return r.json();
  }
  const nameOf = (u) => u.nickname || [u.first_name, u.last_name].filter(Boolean).join(' ') || u.username;
  async function identify(serverRaw, token) {
    const server = normServer(serverRaw);
    if (!SERVERS[server]) throw httpErr(403, `server ${server || '(trống)'} chưa bật A2A`);
    const key = `${server}\n${token}`;
    const c = idCache.get(key);
    if (c && c.exp > Date.now()) return c.who;
    // Chỉ 401/403 của Mattermost mới là token hỏng; lỗi mạng / timeout / 5xx là tạm thời (503) để runner nối lại sớm.
    const transient = (e) => { throw e.status && e.status < 500 ? e : httpErr(503, `chưa kiểm tra được với ${server}: ${e.message}`); };
    const me = await mmGet(server, token, '/users/me').catch((e) => { throw e.status === 401 || e.status === 403 ? httpErr(401, 'token không hợp lệ') : transient(e); });
    const who = { id: me.id, username: me.username, server, is_bot: !!me.is_bot, name: nameOf(me), email: String(me.email || '').toLowerCase(), description: me.bot_description || '', token };
    if (who.is_bot) {
      const adm = adminToken(server);
      if (!adm) throw httpErr(403, 'relay chưa có quyền đọc chủ bot trên server này');
      const bot = await mmGet(server, adm, `/bots/${me.id}`).catch(transient);
      const owner = await mmGet(server, adm, `/users/${bot.owner_id}`).catch(transient);
      Object.assign(who, {
        owner: bot.owner_id, ownerEmail: String(owner.email || '').toLowerCase(), ownerName: nameOf(owner),
        allow: (/\[flygo-agent[^\]]*\ballow=([a-z0-9,]+)/i.exec(who.description)?.[1] || '').split(',').filter(Boolean),
        isAgent: /\[flygo-agent/i.test(who.description),
      });
    } else Object.assign(who, { owner: me.id, ownerEmail: who.email, ownerName: who.name, allow: [], isAgent: false });
    idCache.set(key, { who, exp: Date.now() + 60_000 });
    return who;
  }
  async function authReq(req) {
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''));
    if (!m) throw httpErr(401, 'thiếu token (Authorization: Bearer <token Mattermost>)');
    return identify(req.headers['x-mm-server'] || 'https://chat.flygo.vn', m[1]);
  }
  /** a (bên gọi) được gọi b (agent) không? */
  function canCall(a, b) {
    if (a.id === b.id) return false;
    if (blocked.has(a.owner) || blocked.has(b.owner)) return false;
    if (a.server !== b.server) return (!!a.ownerEmail && a.ownerEmail === b.ownerEmail) || sameAlias(a, b);
    return a.owner === b.owner || b.allow.includes(a.owner);
  }
  const pub = (w) => ({ id: w.id, username: w.username, name: w.name, server: w.server, is_bot: w.is_bot, owner_id: w.owner, owner_name: w.ownerName });
  const busyAsCallee = (id) => [...calls.values()].some((c) => c.callee.who.id === id);

  function normalizeCard(who, card) {
    const c = card && typeof card === 'object' ? card : {};
    return sign({
      ...c,
      protocolVersion: c.protocolVersion || '1.0',
      name: who.name,
      description: c.description || who.description.replace(/\[flygo-agent[^\]]*\]/i, '').trim() || `Trợ lý AI @${who.username}`,
      url: `${PUBLIC}/agents/${who.id}`,
      preferredTransport: 'JSONRPC',
      provider: { organization: 'Flygo', url: 'https://flygo.vn' },
      capabilities: { streaming: true, pushNotifications: false, ...(c.capabilities || {}) },
      defaultInputModes: c.defaultInputModes || ['text/plain', 'application/json', '*/*'],
      defaultOutputModes: c.defaultOutputModes || ['text/plain', 'application/json', '*/*'],
      skills: Array.isArray(c.skills) && c.skills.length ? c.skills : [{ id: 'general', name: 'Trợ lý', description: 'Làm việc theo yêu cầu', tags: ['general'] }],
      securitySchemes: { mattermost: { type: 'http', scheme: 'bearer', description: 'Token Mattermost của bot/người gọi, kèm header X-MM-Server' } },
      security: [{ mattermost: [] }],
      'x-flygo': { bot_id: who.id, username: who.username, server: who.server, owner_id: who.owner, owner_name: who.ownerName },
    });
  }

  // ---- định tuyến cuộc gọi ----
  function finish(cid, msg) {
    const call = calls.get(cid);
    if (!call) return;
    calls.delete(cid);
    clearTimeout(call.timer);
    call.caller.deliver({ t: 'done', id: call.callId, ...msg });
  }
  function startCall(caller, callerWho, callId, to, depth, req) {
    const fail = (code, message) => caller.deliver({ t: 'done', id: callId, error: { code, message } });
    const callee = agents.get(to) || [...agents.values()].find((a) => a.who.username === String(to).replace(/^@/, '') && a.who.server === callerWho.server);
    if (!callee) return fail(-32001, `agent ${to} không trực tuyến`);
    if (!canCall(callerWho, callee.who)) return fail(-32003, `không được phép gọi @${callee.who.username}`);
    if ((depth | 0) >= 1 || busyAsCallee(callerWho.id)) return fail(-32004, 'agent đang làm việc được nhờ thì không nhờ tiếp agent khác (giới hạn độ sâu 1)');
    if ([...calls.values()].filter((c) => c.callerId === callerWho.id).length >= MAX_CONCURRENT) return fail(-32005, 'quá nhiều cuộc gọi A2A cùng lúc');
    const method = METHODS[req?.method];
    if (!method) return fail(-32601, `method ${req?.method} không hỗ trợ`);
    const cid = crypto.randomUUID();
    const timer = setTimeout(() => { callee.conn.send({ t: 'cancel', cid }); finish(cid, { error: { code: -32006, message: 'quá thời gian' } }); }, CALL_TIMEOUT);
    calls.set(cid, { caller, callerId: callerWho.id, callId, callee, timer });
    callee.conn.send({ t: 'req', cid, from: pub(callerWho), depth: (depth | 0) + 1, req: { ...req, method } });
    log('a2a call', `@${callerWho.username} -> @${callee.who.username}`, method);
    return cid;
  }

  // ---- WebSocket của runner ----
  async function upgrade(req, socket, head) {
    const url = new URL(req.url, 'http://x');
    if (url.pathname !== '/a2a/connect' || !req.headers['sec-websocket-key']) return socket.destroy();
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.setNoDelay(true);
    socket.setTimeout(0);
    const conn = new WsConn(socket);
    if (head?.length) conn.feed(head);
    let who;
    try {
      who = await authReq(req);
      if (!who.is_bot || !who.isAgent) throw httpErr(403, 'chỉ bot flygo-agent mới nối relay');
      if (blocked.has(who.owner)) throw httpErr(403, 'bot này không được dùng A2A');
    } catch (e) {
      conn.send({ t: 'error', code: e.status || 500, message: e.message });
      // 1013 (try again later) cho lỗi tạm thời: runner nối lại theo backoff thường, không chờ lâu như 4401/4403.
      return conn.close(e.status === 401 ? 4401 : !e.status || e.status >= 500 ? 1013 : 4403, e.message.slice(0, 100));
    }
    const old = agents.get(who.id);
    if (old) old.conn.close(4409, 'replaced');
    const me = { who, conn, card: normalizeCard(who, {}), deliver: (m) => conn.send(m) };
    agents.set(who.id, me);
    log('a2a connect', `@${who.username}`, who.server);
    conn.send({ t: 'welcome', agent: pub(who), card_url: `${PUBLIC}/agents/${who.id}/.well-known/agent-card.json` });
    conn.onclose = () => {
      if (agents.get(who.id) === me) agents.delete(who.id);
      for (const [cid, c] of calls) {
        if (c.callee === me) finish(cid, { error: { code: -32002, message: `@${who.username} mất kết nối` } });
        else if (c.caller === me) { c.callee.conn.send({ t: 'cancel', cid }); calls.delete(cid); clearTimeout(c.timer); }
      }
      log('a2a disconnect', `@${who.username}`);
    };
    conn.onmessage = async (m) => {
      const res = (result, error) => conn.send({ t: 'res', id: m.id, ...(error ? { error } : { result }) });
      switch (m.t) {
        case 'ping': return conn.send({ t: 'pong' });
        case 'hello': me.card = normalizeCard(who, m.card); return;
        case 'list': {
          const fresh = await identify(who.server, who.token).catch(() => who);
          return res(await Promise.all([...agents.values()].filter((a) => canCall(fresh, a.who)).map(async (a) => ({ ...pub(a.who), card: a.card }))));
        }
        case 'call': {
          const fresh = await identify(who.server, who.token).catch(() => who);
          return startCall(me, fresh, m.id, m.to, m.depth, m.req);
        }
        case 'cancel': {
          for (const [cid, c] of calls) if (c.caller === me && c.callId === m.id) { c.callee.conn.send({ t: 'cancel', cid }); finish(cid, { error: { code: -32007, message: 'đã huỷ' } }); }
          return;
        }
        case 'ev': { const c = calls.get(m.cid); if (c?.callee === me) c.caller.deliver({ t: 'ev', id: c.callId, data: m.data }); return; }
        case 'done': { const c = calls.get(m.cid); if (c?.callee === me) finish(m.cid, { result: m.result, error: m.error }); return; }
        case 'dirs_res':
        case 'sched_res': { const w = scheds.get(m.cid); if (w && w.botId === who.id) { scheds.delete(m.cid); clearTimeout(w.timer); w.resolve(m.result); } return; }
        case 'grant': {
          const to = agents.get(m.to);
          if (!to || !(canCall(who, to.who) || canCall(to.who, who))) return res(null, { code: -32003, message: 'không cấp được tệp cho agent này' });
          const info = await mmGet(who.server, who.token, `/files/${m.file_id}/info`).catch(() => null);
          if (!info) return res(null, { code: -32008, message: 'không đọc được tệp' });
          const gid = crypto.randomBytes(24).toString('base64url');
          grants.set(gid, { fileId: m.file_id, server: who.server, token: who.token, to: to.who.id, exp: Date.now() + GRANT_TTL, name: info.name, mime: info.mime_type, size: info.size });
          return res({ uri: `${PUBLIC}/files/${gid}`, name: info.name, mimeType: info.mime_type, size: info.size, expires_at: Date.now() + GRANT_TTL });
        }
      }
    };
  }
  setInterval(() => { const now = Date.now(); for (const [k, g] of grants) if (g.exp < now) grants.delete(k); for (const [k, c] of idCache) if (c.exp < now) idCache.delete(k); }, 60_000).unref();

  // ---- HTTP (client A2A chuẩn, jwks, tệp) ----
  async function handle(req, res, url) {
    const json = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    const p = url.pathname;
    try {
      if (p === '/a2a/health') return json(200, { status: 'OK', agents: agents.size, calls: calls.size });
      if (p === '/a2a/.well-known/jwks.json') return json(200, { keys: jwk ? [jwk] : [] });
      let m = p.match(/^\/a2a\/files\/([\w-]+)$/);
      if (m && req.method === 'GET') {
        const who = await authReq(req);
        const g = grants.get(m[1]);
        if (!g || g.exp < Date.now() || g.to !== who.id) return json(404, { error: 'not found' });
        const r = await fetch(`${base(g.server)}/api/v4/files/${g.fileId}`, { headers: { authorization: `Bearer ${g.token}` } });
        if (!r.ok) return json(502, { error: `mattermost ${r.status}` });
        res.writeHead(200, { 'content-type': r.headers.get('content-type') || 'application/octet-stream', ...(r.headers.get('content-length') ? { 'content-length': r.headers.get('content-length') } : {}), 'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(g.name || 'file')}` });
        for await (const chunk of r.body) if (!res.write(chunk)) await new Promise((ok) => res.once('drain', ok));
        return res.end();
      }
      // Runner báo kiểm kê (kỹ năng / model) của bot: bot không tự sửa được props / mô tả của mình -> relay ghi hộ bằng token admin,
      // chỉ cho chính bot đó: props.flygo_skills, props.flygo_models và các mốc models= efforts= default= trong [flygo-agent …].
      if (p === '/a2a/meta' && req.method === 'POST') {
        const who = await authReq(req);
        if (!who.is_bot) return json(403, { error: 'chỉ bot' });
        let raw = '';
        for await (const c of req) { raw += c; if (raw.length > 200_000) return json(413, { error: 'quá lớn' }); }
        const body = JSON.parse(raw || '{}');
        const adm = adminToken(who.server);
        if (!adm) return json(403, { error: 'relay chưa có quyền admin trên server này' });
        const mmSend = async (method, path, data) => {
          const r = await fetch(`${base(who.server)}/api/v4${path}`, { method, headers: { authorization: `Bearer ${adm}`, 'content-type': 'application/json' }, body: JSON.stringify(data), signal: AbortSignal.timeout(10_000) });
          if (!r.ok) throw httpErr(502, `${path} -> ${r.status}`);
          return r.json();
        };
        const u = await mmGet(who.server, adm, `/users/${who.id}`);
        const props = { ...(u.props || {}) };
        const clip = (v) => JSON.stringify(v).slice(0, 60_000);
        if (body.skills) props.flygo_skills = clip(body.skills);
        if (body.models) props.flygo_models = clip(body.models);
        if (body.schedules) props.flygo_schedules = clip(body.schedules);
        await mmSend('PUT', `/users/${who.id}/patch`, { props });
        const out = { props: Object.keys(props).filter((k) => k.startsWith('flygo_')) };
        // mốc trong mô tả bot
        const clean = (v) => String(v ?? '').replace(/[^\w.:,-]/g, '');
        const attrs = { models: clean(body.marker?.models), efforts: clean(body.marker?.efforts), default: clean(body.marker?.default) };
        if (Object.values(attrs).some(Boolean)) {
          const bot = await mmGet(who.server, adm, `/bots/${who.id}`);
          const desc = bot.description || '';
          const cur = /\[flygo-agent([^\]]*)\]/i.exec(desc);
          if (cur) {
            let a = cur[1];
            for (const [k, v] of Object.entries(attrs)) if (v) a = new RegExp(`\\s${k}=\\S+`).test(a) ? a.replace(new RegExp(`(\\s${k}=)[^\\s\\]]+`), `$1${v}`) : `${a} ${k}=${v}`;
            const next = desc.replace(cur[0], `[flygo-agent${a}]`);
            if (next !== desc) { await mmSend('PUT', `/bots/${who.id}`, { username: bot.username, display_name: bot.display_name, description: next }); out.marker = next; }
          }
        }
        idCache.forEach((v, k) => { if (v.who.id === who.id) idCache.delete(k); });
        return json(200, { ok: true, ...out });
      }
      // App thao tác lịch hẹn của bot ("Hẹn giờ"): người dùng (token Mattermost + X-MM-Server) là chủ bot hoặc trong allow=,
      // cùng server với bot. Relay chuyển xuống runner qua WebSocket ({t:"sched"}), runner kiểm lại quyền và trả {ok, schedule?|error}.
      if (p === '/a2a/schedules' && req.method === 'POST') {
        const who = await authReq(req);
        if (who.is_bot) return json(403, { error: 'chỉ người dùng' });
        let raw = '';
        for await (const c of req) { raw += c; if (raw.length > 100_000) return json(413, { error: 'quá lớn' }); }
        let body;
        try { body = JSON.parse(raw || '{}'); } catch { return json(400, { error: 'JSON không hợp lệ' }); }
        const ACTIONS = ['create', 'update', 'delete', 'pause', 'resume', 'run_now', 'list'];
        if (!ACTIONS.includes(body.action)) return json(400, { error: `action phải là ${ACTIONS.join(' | ')}` });
        const target = agents.get(String(body.bot_id || ''));
        if (!target) return json(503, { error: 'bot offline' });
        const bot = await identify(target.who.server, target.who.token).catch(() => target.who);
        if (bot.server !== who.server || !(who.id === bot.owner || bot.allow.includes(who.id))) return json(403, { error: 'chỉ chủ bot hoặc người được chủ cho phép' });
        const cid = crypto.randomUUID();
        const result = await new Promise((resolve) => {
          const timer = setTimeout(() => { scheds.delete(cid); resolve(null); }, 20_000);
          scheds.set(cid, { resolve, timer, botId: bot.id });
          target.conn.send({ t: 'sched', cid, user: { id: who.id, username: who.username }, body: { action: body.action, id: body.id, schedule: body.schedule } });
        });
        if (!result) return json(504, { error: 'bot không trả lời' });
        log('a2a schedules', `@${who.username} -> @${bot.username}`, body.action, result.ok ? 'ok' : result.error);
        return json(result.ok ? 200 : 400, result);
      }
      // App chọn thư mục dự án trên máy của bot: chỉ chủ bot (cùng server). Relay chuyển xuống runner ({t:"dirs"}),
      // runner kiểm lại chủ và projectRoots, trả {ok, path, parent, root, machine, dirs:[{name, path}]}.
      if (p === '/a2a/dirs' && req.method === 'GET') {
        const who = await authReq(req);
        if (who.is_bot) return json(403, { error: 'chỉ người dùng' });
        const target = agents.get(String(url.searchParams.get('bot') || ''));
        if (!target) return json(404, { error: 'bot offline hoặc chưa nối relay' });
        const bot = await identify(target.who.server, target.who.token).catch(() => target.who);
        if (bot.server !== who.server || who.id !== bot.owner) return json(403, { error: 'chỉ chủ bot' });
        const cid = crypto.randomUUID();
        const result = await new Promise((resolve) => {
          const timer = setTimeout(() => { scheds.delete(cid); resolve(null); }, 15_000);
          scheds.set(cid, { resolve, timer, botId: bot.id });
          target.conn.send({ t: 'dirs', cid, user: { id: who.id }, path: String(url.searchParams.get('path') || '').slice(0, 1000) });
        });
        if (!result) return json(504, { error: 'bot không trả lời' });
        const { status, ...rest } = result;
        return json(rest.ok ? 200 : status || 400, rest);
      }
      if (p === '/a2a/agents' && req.method === 'GET') {
        const who = await authReq(req);
        return json(200, [...agents.values()].filter((a) => canCall(who, a.who)).map((a) => a.card));
      }
      m = p.match(/^\/a2a\/agents\/(\w+)(\/\.well-known\/agent(?:-card)?\.json)?$/);
      if (!m) return json(404, { error: 'not found' });
      const who = await authReq(req);
      const target = agents.get(m[1]);
      if (!target || !canCall(who, target.who)) return json(404, { error: 'agent không trực tuyến hoặc không được phép' });
      if (m[2]) return json(200, target.card);
      if (req.method !== 'POST') return json(405, { error: 'POST JSON-RPC' });
      let raw = '';
      for await (const c of req) { raw += c; if (raw.length > 10e6) return json(413, { error: 'quá lớn' }); }
      let rpc;
      try { rpc = JSON.parse(raw); } catch { return json(400, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
      const stream = METHODS[rpc.method] === 'message/stream';
      if (stream) res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', 'x-accel-buffering': 'no' });
      const caller = {
        deliver(msg) {
          if (msg.t === 'ev' && stream) res.write(`data: ${JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result: msg.data })}\n\n`);
          if (msg.t !== 'done') return;
          const body = { jsonrpc: '2.0', id: rpc.id, ...(msg.error ? { error: msg.error } : { result: msg.result ?? null }) };
          if (stream) { if (msg.error) res.write(`data: ${JSON.stringify(body)}\n\n`); res.end(); } else json(200, body);
        },
      };
      const cid = startCall(caller, who, rpc.id, target.who.id, 0, rpc);
      req.on('close', () => { if (cid && calls.has(cid) && !res.writableEnded) { target.conn.send({ t: 'cancel', cid }); calls.delete(cid); } });
    } catch (e) {
      if (!res.headersSent) json(e.status || 500, { error: e.message });
      else res.end();
    }
  }

  return { handle, upgrade };
}
