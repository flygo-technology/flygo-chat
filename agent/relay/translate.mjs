// Dịch tin nhắn cho Flygo Chat (nút "Dịch AI" ở ô nhắn tin): https://<trạm>/translate
//   POST /translate {text, to}  -> {text, from, to, engine}
//   to / from: mã ngôn ngữ (vi, en, ko, ja, th, zh…). Tin song ngữ do app ghép từ bản gốc + bản dịch.
// Xác thực: Authorization: Bearer <token Mattermost> + X-MM-Server (như a2a). Không log nội dung.
// Bộ dịch, theo thứ tự: API Claude (translate.model, khoá ở translate.anthropicKeyFile, nếu có); bot Claude đã tích hợp
// (translate.bots: [{server, username}], runner dịch bằng claude -p --model sonnet trên máy bot); cuối cùng Google Dịch.
// Cấu hình: translate: { anthropicKeyFile?, model?, perUserDaily?, bots? }
import crypto from 'node:crypto';
import fs from 'node:fs';

const httpErr = (status, message) => Object.assign(new Error(message), { status });
const NAMES = { vi: 'Vietnamese', en: 'English', ko: 'Korean', ja: 'Japanese', th: 'Thai', zh: 'Simplified Chinese', id: 'Indonesian', ms: 'Malay', fr: 'French', de: 'German', es: 'Spanish', ru: 'Russian' };

export function createTranslate(conf = {}, shared, log = console.log) {
  const MODEL = conf.model || 'claude-haiku-5-5';
  const DAILY = conf.perUserDaily || 2000;
  const key = () => { try { return fs.readFileSync(conf.anthropicKeyFile, 'utf8').trim(); } catch { return ''; } };
  const cache = new Map(); // sha(to + text) -> {text, from, engine}
  const used = new Map(); // `${server} ${user} ${ngày}` -> số lượt

  async function claude(text, to) {
    const k = key();
    if (!k) return null;
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': k, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: Math.min(4096, 256 + text.length * 2),
        system: `You translate chat messages into ${NAMES[to] || to}. Reply with JSON only: {"from":"<ISO 639-1 code of the source language>","text":"<translation>"}. ` +
          'Keep the meaning, tone, line breaks, emoji, @mentions, links, code and numbers unchanged. Do not add explanations.',
        messages: [{ role: 'user', content: text }],
      }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!r.ok) throw httpErr(502, `claude ${r.status}`);
    const j = await r.json();
    const out = (j.content || []).map((c) => c.text || '').join('').trim();
    const m = /\{[\s\S]*\}/.exec(out);
    const p = m ? JSON.parse(m[0]) : null;
    if (!p?.text) throw httpErr(502, 'claude: bad reply');
    return { text: String(p.text), from: String(p.from || '').slice(0, 5).toLowerCase(), engine: MODEL };
  }

  // Google Dịch miễn phí: hai đường (translate_a/single, rồi clients5) vì đường đầu hay bị giới hạn (429) theo IP.
  async function google(text, to) {
    const tl = encodeURIComponent(to === 'zh' ? 'zh-CN' : to), q = encodeURIComponent(text);
    try {
      const r = await fetch(`https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${tl}&dt=t&q=${q}`, { signal: AbortSignal.timeout(10_000) });
      if (!r.ok) throw httpErr(502, `google ${r.status}`);
      const j = await r.json();
      const out = (j[0] || []).map((x) => x[0] || '').join('');
      if (out) return { text: out, from: String(j[2] || '').split('-')[0].toLowerCase(), engine: 'google' };
    } catch (e) { log(`[translate] google: ${e.message}`); }
    const r = await fetch(`https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=${tl}&q=${q}`, {
      headers: { 'user-agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(10_000),
    });
    if (!r.ok) throw httpErr(502, `google ${r.status}`);
    const j = await r.json();
    const first = Array.isArray(j) ? j[0] : null;
    const out = Array.isArray(first) ? String(first[0] || '') : String(first || '');
    if (!out) throw httpErr(502, 'google: empty');
    return { text: out, from: Array.isArray(first) ? String(first[1] || '').split('-')[0].toLowerCase() : '', engine: 'google' };
  }

  async function handle(req, res, url) {
    const reply = (status, body) => { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(body)); };
    try {
      if (req.method !== 'POST' || url.pathname !== '/translate') return reply(404, { error: 'not found' });
      const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''));
      if (!m) throw httpErr(401, 'thiếu token');
      const who = await shared.identify(req.headers['x-mm-server'] || 'https://chat.flygo.vn', m[1]);
      const chunks = [];
      for await (const c of req) { chunks.push(c); if (chunks.reduce((n, x) => n + x.length, 0) > 64_000) throw httpErr(413, 'tin quá dài'); }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      const text = String(body.text || '').trim();
      const to = String(body.to || '').trim().toLowerCase();
      if (!text || !/^[a-z]{2,3}(-[a-z]{2,4})?$/.test(to)) throw httpErr(400, 'thiếu text / to');
      const day = new Date().toISOString().slice(0, 10);
      const uk = `${who.server} ${who.id} ${day}`;
      const n = (used.get(uk) || 0) + 1;
      if (n > DAILY) throw httpErr(429, 'hết lượt dịch hôm nay');
      used.set(uk, n);
      if (used.size > 20_000) for (const k of used.keys()) if (!k.endsWith(day)) used.delete(k);
      const ck = crypto.createHash('sha256').update(`${to}\n${text}`).digest('base64url');
      let out = cache.get(ck);
      if (!out) {
        out = await claude(text, to).catch((e) => { log(`[translate] claude: ${e.message}`); return null; })
          || await shared.botTranslate?.(conf.bots, text, to).catch((e) => { log(`[translate] bot: ${e.message}`); return null; })
          || await google(text, to);
        cache.set(ck, out);
        if (cache.size > 5000) cache.delete(cache.keys().next().value);
      }
      log(`[translate] ${who.server} ${who.username} -> ${to} ${text.length}c ${out.engine}`);
      return reply(200, { text: out.text, from: out.from, to, engine: out.engine });
    } catch (e) {
      if (!e.status || e.status >= 500) log(`[translate] error: ${e.message}`);
      return reply(e.status || 500, { error: e.status && e.status < 500 ? e.message : 'dịch tạm thời lỗi, thử lại sau' });
    }
  }
  return { handle };
}
