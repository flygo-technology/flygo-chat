// Tự xoá tin nhắn cũ theo nhóm (Mattermost bản Entry không có chính sách lưu giữ theo kênh).
// Chủ nhóm đặt trong app: mốc "[flygo-retention days=N]" (10–365) trong mô tả kênh. Mỗi đêm trạm:
//   1. liệt kê mọi kênh (token quản trị) có mốc;
//   2. chỉ tin mốc khi lần đổi mô tả gần nhất (tin hệ thống system_purpose_change có mốc) do quản trị kênh / quản trị
//      máy chủ làm (thành viên thường sửa mô tả để xoá tin thì bỏ qua);
//   3. xoá hẳn tin cũ hơn N ngày (cả trả lời trong luồng và tệp đính kèm), giữ tin đã ghim.
// Cấu hình: retention: { servers: { "<url>": { internal, adminTokenFile } }, hour?: 19 (giờ UTC, 02:00 VN),
//   permanent?: true (cần ServiceSettings.EnableAPIPostDeletion), maxPerChannel?: 20000, dryRun?: false }
import fs from 'node:fs';

const MARK = /\[flygo-retention days=(\d+)\]/;
const DAY = 86_400_000;

export function createRetention(conf = {}, log = console.log) {
  const servers = conf.servers || {};
  const hour = Number.isInteger(conf.hour) ? conf.hour : 19;
  const permanent = conf.permanent !== false;
  const maxPerChannel = conf.maxPerChannel || 20000;
  let running = false, lastDay = '';

  async function api(srv, method, path) {
    const tok = fs.readFileSync(srv.adminTokenFile, 'utf8').trim();
    const r = await fetch(`${srv.internal}/api/v4${path}`, { method, headers: { authorization: `Bearer ${tok}` }, signal: AbortSignal.timeout(30_000) });
    if (!r.ok) throw new Error(`${method} ${path} -> ${r.status}`);
    return r.status === 204 ? null : r.json();
  }

  /** Người đặt mốc hiện tại: tin hệ thống đổi mô tả gần nhất mà mô tả mới có đúng mốc này. */
  async function setterOf(srv, ch, days) {
    for (let page = 0; page < 50; page++) {
      const r = await api(srv, 'GET', `/channels/${ch.id}/posts?page=${page}&per_page=200`);
      for (const id of r.order) {
        const p = r.posts[id];
        if (p.type !== 'system_purpose_change') continue;
        const m = MARK.exec(String(p.props?.new_purpose || ''));
        return m && Number(m[1]) === days ? p.user_id : null; // lần đổi gần nhất không khớp: không tin
      }
      if (r.order.length < 200) break;
    }
    return null;
  }

  async function isAdmin(srv, chId, userId) {
    const u = await api(srv, 'GET', `/users/${userId}`).catch(() => null);
    if (String(u?.roles || '').includes('system_admin')) return true;
    const m = await api(srv, 'GET', `/channels/${chId}/members/${userId}`).catch(() => null);
    return !!m && (m.scheme_admin === true || String(m.roles || '').includes('channel_admin'));
  }

  async function cleanChannel(srv, url, ch, days) {
    const cutoff = Date.now() - days * DAY;
    const old = [];
    for (let page = 0; page < 1000 && old.length < maxPerChannel; page++) {
      const r = await api(srv, 'GET', `/channels/${ch.id}/posts?page=${page}&per_page=200`);
      for (const id of r.order) {
        const p = r.posts[id];
        if (p.create_at < cutoff && !p.is_pinned && p.delete_at === 0) old.push(p);
      }
      if (r.order.length < 200) break;
    }
    // Trả lời trước, tin gốc sau (xoá tin gốc cũng xoá luồng, nhưng làm vậy để không sót trả lời cũ của luồng còn mới).
    old.sort((a, b) => (a.root_id ? 0 : 1) - (b.root_id ? 0 : 1));
    let n = 0;
    for (const p of old.slice(0, maxPerChannel)) {
      if (conf.dryRun) { n++; continue; }
      await api(srv, 'DELETE', `/posts/${p.id}${permanent ? '?permanent=true' : ''}`).then(() => n++, (e) => log(`[retention] ${url} ${ch.name}: ${e.message}`));
    }
    if (n) log(`[retention] ${url} "${ch.display_name}" (${days} ngày): ${conf.dryRun ? 'sẽ xoá' : 'đã xoá'} ${n} tin`);
    return n;
  }

  async function runOnce() {
    if (running) return;
    running = true;
    try {
      for (const [url, srv] of Object.entries(servers)) {
        for (let page = 0; page < 200; page++) {
          const list = await api(srv, 'GET', `/channels?page=${page}&per_page=200&include_deleted=false`).catch((e) => { log(`[retention] ${url}: ${e.message}`); return []; });
          for (const ch of list) {
            const m = MARK.exec(String(ch.purpose || ''));
            if (!m) continue;
            const days = Number(m[1]);
            if (days < 10 || days > 365) { log(`[retention] ${url} "${ch.display_name}": ${days} ngày ngoài 10–365, bỏ qua`); continue; }
            const who = await setterOf(srv, ch, days).catch(() => null);
            if (!who || !(await isAdmin(srv, ch.id, who))) { log(`[retention] ${url} "${ch.display_name}": người đặt mốc không phải quản trị nhóm, bỏ qua`); continue; }
            await cleanChannel(srv, url, ch, days).catch((e) => log(`[retention] ${url} "${ch.display_name}": ${e.message}`));
          }
          if (list.length < 200) break;
        }
      }
    } finally {
      running = false;
    }
  }

  // Mỗi phút xem đã tới giờ chạy của ngày hôm nay chưa (một lần mỗi ngày).
  const timer = setInterval(() => {
    const now = new Date(), day = now.toISOString().slice(0, 10);
    if (now.getUTCHours() === hour && lastDay !== day) { lastDay = day; runOnce().catch((e) => log(`[retention] ${e.message}`)); }
  }, 60_000);
  timer.unref?.();
  log(`[retention] bật: ${Object.keys(servers).join(', ')} · ${hour}:00 UTC mỗi ngày${conf.dryRun ? ' · chạy thử (không xoá)' : ''}`);
  return { runOnce };
}
