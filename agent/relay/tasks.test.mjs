// Kiểm thử phần chọn nhắc việc của relay/tasks.mjs: node --test relay/tasks.test.mjs (hoặc bun test relay/tasks.test.mjs)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { dueStage, inDigest, isDoneStatus, parseDue, planReminders } from './tasks.mjs';

const TZ = 'Asia/Ho_Chi_Minh';
// Giờ Việt Nam (UTC+7) → ms.
const vn = (s) => Date.parse(`${s}+07:00`);
// Hạn theo ngày: 00:00 UTC của ngày đó (như bản web).
const dayDue = (d) => JSON.stringify({ from: Date.parse(`${d}T00:00:00Z`) });

const board = {
  id: 'b1',
  cardProperties: [
    { id: 's', name: 'Trạng thái', type: 'select', options: [{ id: 'todo', value: 'Chưa làm' }, { id: 'done', value: 'Xong' }] },
    { id: 'a', name: 'Người làm', type: 'multiPerson' },
    { id: 'h', name: 'Hạn', type: 'date' },
  ],
};
const card = (id, props, extra = {}) => ({ id, title: `Việc ${id}`, createdBy: 'boss', modifiedBy: 'boss', fields: { properties: props }, ...extra });
const entry = (c) => ({ key: c.id, board, card: c });

test('dueStage: hạn theo ngày', () => {
  const due = parseDue(dayDue('2026-11-05'));
  assert.equal(dueStage(due, vn('2026-11-04T10:00:00'), { tz: TZ }), null, 'hôm trước, trước 16h');
  assert.equal(dueStage(due, vn('2026-11-04T16:30:00'), { tz: TZ }), 'soon', 'hôm trước, sau 16h');
  assert.equal(dueStage(due, vn('2026-11-05T09:00:00'), { tz: TZ }), null, 'đúng ngày hạn: chưa quá hạn');
  assert.equal(dueStage(due, vn('2026-11-06T07:00:00'), { tz: TZ }), null, 'hôm sau, trước 8h');
  assert.equal(dueStage(due, vn('2026-11-06T08:05:00'), { tz: TZ }), 'overdue', 'hôm sau, từ 8h');
  assert.equal(dueStage(due, vn('2026-11-09T03:00:00'), { tz: TZ }), 'overdue', 'nhiều ngày sau');
});

test('dueStage: hạn có giờ', () => {
  const due = parseDue(JSON.stringify({ from: vn('2026-11-05T14:00:00'), includeTime: true }));
  assert.equal(dueStage(due, vn('2026-11-04T13:00:00'), { tz: TZ }), null);
  assert.equal(dueStage(due, vn('2026-11-04T14:30:00'), { tz: TZ }), 'soon');
  assert.equal(dueStage(due, vn('2026-11-05T14:01:00'), { tz: TZ }), 'overdue');
});

test('inDigest: hôm nay và quá hạn, không gồm ngày mai', () => {
  const now = vn('2026-11-05T08:00:00');
  assert.equal(inDigest(parseDue(dayDue('2026-11-05')), now, TZ), true);
  assert.equal(inDigest(parseDue(dayDue('2026-11-01')), now, TZ), true);
  assert.equal(inDigest(parseDue(dayDue('2026-11-06')), now, TZ), false);
  assert.equal(inDigest(null, now, TZ), false);
});

test('isDoneStatus nhiều ngôn ngữ', () => {
  for (const s of ['Xong', 'Hoàn thành', 'Done', '완료', '完成', 'เสร็จ']) assert.equal(isDoneStatus(s), true, s);
  assert.equal(isDoneStatus('Đang làm'), false);
});

test('planReminders: lần đầu chỉ ghi nhận, không gửi', () => {
  const now = vn('2026-11-06T09:00:00');
  const c = card('c1', { s: 'todo', a: ['u1'], h: dayDue('2026-11-05') });
  const r = planReminders({}, [entry(c)], now, { tz: TZ, baseline: true });
  assert.equal(r.events.length, 0);
  // Vòng sau: đã coi như nhắc quá hạn rồi → không gửi lại.
  const r2 = planReminders(r.next, [entry(c)], now + 120_000, { tz: TZ });
  assert.equal(r2.events.length, 0);
});

test('planReminders: được giao, bỏ qua người tự giao', () => {
  const now = vn('2026-11-01T10:00:00');
  const prev = planReminders({}, [entry(card('c1', { s: 'todo', a: ['u1'] }))], now, { tz: TZ, baseline: true }).next;
  const c = card('c1', { s: 'todo', a: ['u1', 'u2', 'boss'] });
  const { events } = planReminders(prev, [entry(c)], now, { tz: TZ });
  assert.deepEqual(events.map((e) => [e.kind, e.user, e.by]), [['assigned', 'u2', 'boss']]);
  // Thẻ mới: báo người làm, trừ người tạo.
  const nc = card('c2', { s: 'todo', a: ['boss', 'u3'] });
  const r = planReminders(prev, [entry(nc)], now, { tz: TZ });
  assert.deepEqual(r.events.map((e) => [e.kind, e.user]), [['assigned', 'u3']]);
});

test('planReminders: xong báo người tạo, một lần', () => {
  const now = vn('2026-11-01T10:00:00');
  const prev = planReminders({}, [entry(card('c1', { s: 'todo', a: ['u1'] }))], now, { tz: TZ, baseline: true }).next;
  const done = card('c1', { s: 'done', a: ['u1'] }, { modifiedBy: 'u1' });
  const r = planReminders(prev, [entry(done)], now, { tz: TZ });
  assert.deepEqual(r.events.map((e) => [e.kind, e.user, e.by]), [['done', 'boss', 'u1']]);
  assert.equal(planReminders(r.next, [entry(done)], now, { tz: TZ }).events.length, 0);
  // Người tạo tự bấm xong: không báo.
  const self = card('c1', { s: 'done', a: ['u1'] }, { modifiedBy: 'boss' });
  assert.equal(planReminders(prev, [entry(self)], now, { tz: TZ }).events.length, 0);
});

test('planReminders: sắp hạn / quá hạn mỗi hạn một lần, đổi hạn thì nhắc lại, việc xong thì thôi', () => {
  const t0 = vn('2026-11-03T10:00:00');
  const c = (h, s = 'todo') => card('c1', { s, a: ['u1', 'u2'], h: dayDue(h) });
  let st = planReminders({}, [entry(c('2026-11-05'))], t0, { tz: TZ, baseline: true }).next;
  // 16:30 hôm trước hạn → sắp hạn cho cả hai người làm.
  let r = planReminders(st, [entry(c('2026-11-05'))], vn('2026-11-04T16:30:00'), { tz: TZ });
  assert.deepEqual(r.events.map((e) => `${e.kind}:${e.user}`), ['due_soon:u1', 'due_soon:u2']);
  st = r.next;
  r = planReminders(st, [entry(c('2026-11-05'))], vn('2026-11-04T18:00:00'), { tz: TZ });
  assert.equal(r.events.length, 0, 'không nhắc lại');
  // Sáng hôm sau ngày hạn → quá hạn.
  r = planReminders(st, [entry(c('2026-11-05'))], vn('2026-11-06T08:01:00'), { tz: TZ });
  assert.deepEqual(r.events.map((e) => e.kind), ['overdue', 'overdue']);
  st = r.next;
  // Dời hạn sang 10/11: hôm 9/11 chiều nhắc sắp hạn lại.
  r = planReminders(st, [entry(c('2026-11-10'))], vn('2026-11-09T16:10:00'), { tz: TZ });
  assert.deepEqual(r.events.map((e) => e.kind), ['due_soon', 'due_soon']);
  // Việc đã xong: không nhắc hạn.
  r = planReminders(st, [entry(c('2026-11-10', 'done'))], vn('2026-11-09T16:10:00'), { tz: TZ });
  assert.equal(r.events.filter((e) => e.kind !== 'done').length, 0);
});
