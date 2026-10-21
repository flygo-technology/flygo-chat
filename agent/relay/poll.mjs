// Bình chọn trong Flygo Chat (chạy trong trạm đẩy, https://<trạm>/poll/…).
// Bình chọn nằm ở props.flygo_poll của tin do app tạo:
//   { v:1, question, options:[{id, text, by?}], multi, revote, allow_add, ends_at:<ms|0>, closed, votes:{<user_id>:[option_id…]}, created_by }
// Bỏ phiếu là sửa props tin của người khác (người dùng thường không có quyền), nên relay sửa bằng token quản trị
// sau khi kiểm tra luật. Mỗi tin sửa lần lượt (hàng đợi theo post) để các phiếu đồng thời không ghi đè nhau.
//
//   POST /poll/vote   {post_id, options:[ids]}  ([] = rút phiếu, chỉ khi revote)
//   POST /poll/option {post_id, text}           -> thêm {id, text, by} (khi allow_add), trả kèm option_id
//   POST /poll/close  {post_id}                 (chỉ người tạo)
//   -> {ok:true, poll:<flygo_poll mới>}; app nhận thêm post_edited qua websocket.
// Xác thực: Authorization: Bearer <token Mattermost của người gọi> + X-MM-Server; người gọi phải ở kênh của tin.
// Log: thao tác, server, người, tin. Không log nội dung.
//
// Cấu hình: poll: { servers: { "<url server>": { internal?, adminTokenFile } } }
import crypto from 'node:crypto';
import fs from 'node:fs';

const httpErr = (status, message) => Object.assign(new Error(message), { status });
const normServer = (s) => String(s || '').trim().replace(/\/+$/, '').toLowerCase();
const oid = () => crypto.randomBytes(6).toString('base64url');

export function createPoll(conf = {}, log = console.log) {
  const SERVERS = Object.fromEntries(Object.entries(conf.servers || {}).map(([k, v]) => [normServer(k), v]));
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
    const who = { server, id: me.id, username: me.username };
    idCache.set(key, { who, exp: Date.now() + 60_000 });
    if (idCache.size > 5000) for (const [k, v] of idCache) if (v.exp <= Date.now()) idCache.delete(k);
    return who;
  }

  // Hàng đợi theo tin: mỗi lần sửa chờ lần trước xong.
  const queues = new Map();
  function serial(key, fn) {
    const prev = queues.get(key) || Promise.resolve();
    const run = prev.then(fn, fn);
    const tail = run.catch(() => {});
    queues.set(key, tail);
    tail.then(() => { if (queues.get(key) === tail) queues.delete(key); });
    return run;
  }

  /** Đọc tin + kiểm tra người gọi ở kênh, rồi sửa flygo_poll bằng change(poll) và ghi lại toàn bộ props. */
  function update(who, postId, op, change) {
    if (!/^[a-z0-9]{26}$/.test(String(postId || ''))) return Promise.reject(httpErr(400, 'post_id không hợp lệ'));
    return serial(`${who.server} ${postId}`, async () => {
      const post = await admin(who.server, 'GET', `/posts/${postId}`).catch((e) => { throw e.status === 404 || e.status === 403 ? httpErr(404, 'không có tin này') : e; });
      if (post.delete_at) throw httpErr(404, 'tin đã bị xoá');
      const member = await admin(who.server, 'GET', `/channels/${post.channel_id}/members/${who.id}`).then(() => true, () => false);
      if (!member) throw httpErr(403, 'bạn không ở chat có bình chọn này');
      const props = post.props || {};
      const old = props.flygo_poll;
      if (!old || typeof old !== 'object' || !Array.isArray(old.options)) throw httpErr(404, 'tin này không có bình chọn');
      const poll = structuredClone(old);
      poll.votes = poll.votes && typeof poll.votes === 'object' ? poll.votes : {};
      const extra = change(poll) || {};
      await admin(who.server, 'PUT', `/posts/${postId}/patch`, { props: { ...props, flygo_poll: poll } });
      log(`poll ${op}`, who.server, `user=${who.username}`, `post=${postId}`);
      return { ok: true, poll, ...extra };
    });
  }
  const open = (poll) => {
    if (poll.closed) throw httpErr(409, 'bình chọn đã kết thúc');
    const ends = Number(poll.ends_at) || 0;
    if (ends > 0 && ends <= Date.now()) throw httpErr(409, 'bình chọn đã hết hạn');
  };

  const vote = (who, b) => update(who, b?.post_id, 'vote', (poll) => {
    open(poll);
    if (!Array.isArray(b?.options)) throw httpErr(400, 'options phải là danh sách');
    const ids = [...new Set(b.options.map(String))];
    const had = Array.isArray(poll.votes[who.id]) && poll.votes[who.id].length > 0;
    if (!ids.length) {
      if (!poll.revote) throw httpErr(409, 'bình chọn này không cho rút phiếu');
      delete poll.votes[who.id];
      return;
    }
    if (!poll.multi && ids.length > 1) throw httpErr(409, 'bình chọn này chỉ được chọn một phương án');
    const valid = new Set(poll.options.map((o) => String(o.id)));
    if (ids.some((id) => !valid.has(id))) throw httpErr(409, 'phương án không có trong bình chọn');
    if (had && !poll.revote) throw httpErr(409, 'bạn đã bình chọn, không đổi được nữa');
    poll.votes[who.id] = ids;
  });

  const addOption = (who, b) => update(who, b?.post_id, 'option', (poll) => {
    open(poll);
    if (!poll.allow_add) throw httpErr(409, 'bình chọn này không cho thêm phương án');
    const text = String(b?.text ?? '').replace(/\s+/g, ' ').trim();
    if (!text) throw httpErr(400, 'phương án trống');
    if ([...text].length > 100) throw httpErr(400, 'phương án tối đa 100 ký tự');
    if (poll.options.some((o) => String(o.text ?? '').trim().toLocaleLowerCase('vi') === text.toLocaleLowerCase('vi'))) throw httpErr(409, 'phương án này đã có');
    let id = oid();
    while (poll.options.some((o) => String(o.id) === id)) id = oid();
    poll.options.push({ id, text, by: who.id });
    return { option_id: id };
  });

  const close = (who, b) => update(who, b?.post_id, 'close', (poll) => {
    if (poll.created_by !== who.id) throw httpErr(403, 'chỉ người tạo được kết thúc bình chọn');
    poll.closed = true;
  });

  async function readJson(req, max = 16 * 1024) {
    let n = 0; const chunks = [];
    for await (const c of req) { n += c.length; if (n > max) throw httpErr(413, 'body quá lớn'); chunks.push(c); }
    if (!n) return {};
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw httpErr(400, 'body không phải JSON'); }
  }

  async function handle(req, res, url) {
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)); };
    try {
      const fn = req.method === 'POST' && { '/poll/vote': vote, '/poll/option': addOption, '/poll/close': close }[url.pathname];
      if (!fn) return send(404, { error: 'not found' });
      const who = await caller(req);
      return send(200, await fn(who, await readJson(req)));
    } catch (e) {
      if (!e.status || e.status >= 500) log('poll lỗi', e.message);
      return send(e.status || 500, { error: e.status ? e.message : 'lỗi trạm' });
    }
  }
  return { handle };
}
