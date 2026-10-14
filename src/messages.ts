// Mỗi tin nhắn của agent là một post riêng trong chủ đề, nội dung sửa dần khi stream.
// props.flygo_agent_message = { run_id, engine, seq, streaming, final? }. Tin cuối được chuyển thành thread_broadcast.
import type { MM } from "./mm";

interface Msg { postId: string; text: string; seq: number; streaming: boolean; timer: Timer | null; creating: Promise<void> | null; chain: Promise<void> }

export class MessageStream {
  private msgs = new Map<string, Msg>();
  private order: string[] = [];

  constructor(private mm: MM, private where: { channel_id: string; root_id: string }, private runId: string, private engine: string) {}

  private props(m: Msg, final = false) {
    return {
      flygo_reply: final ? "thread_broadcast" : "thread",
      flygo_agent_message: { run_id: this.runId, engine: this.engine, seq: m.seq, streaming: m.streaming, ...(final ? { final: true } : {}) },
    };
  }

  update(u: { id: string; delta?: string; full?: string; done?: boolean }) {
    let m = this.msgs.get(u.id);
    if (!m) {
      m = { postId: "", text: "", seq: this.order.length + 1, streaming: true, timer: null, creating: null, chain: Promise.resolve() };
      this.msgs.set(u.id, m);
      this.order.push(u.id);
    }
    if (u.full !== undefined) m.text = u.full; else m.text += u.delta ?? "";
    if (u.done) m.streaming = false;
    if (!m.text.trim()) return; // chưa có chữ thì chưa tạo post
    if (!m.postId && !m.creating) {
      const msg = m;
      msg.creating = this.mm.createPost({ ...this.where, message: msg.text, props: this.props(msg) }).then((p) => { msg.postId = p.id; }, () => {});
      msg.chain = msg.creating;
      if (!u.done) return;
    }
    this.schedule(m, u.done ? 0 : 500);
  }

  private schedule(m: Msg, delay: number) {
    if (m.timer) { if (delay > 0) return; clearTimeout(m.timer); }
    m.timer = setTimeout(() => {
      m.timer = null;
      const body = { message: m.text, props: this.props(m) };
      m.chain = m.chain.then(() => (m.postId ? this.mm.patchPost(m.postId, body).then(() => {}, () => {}) : undefined));
    }, delay);
  }

  /** Kết thúc lượt: chốt mọi tin; tin cuối (hoặc `fallback` nếu agent không có tin nào) hiện cả ở chat chính. */
  async finish(fallback: string, broadcast = true) {
    for (const id of this.order) { const m = this.msgs.get(id)!; m.streaming = false; if (m.timer) { clearTimeout(m.timer); m.timer = null; } }
    const lastId = [...this.order].reverse().find((id) => this.msgs.get(id)!.text.trim());
    for (const id of this.order) {
      const m = this.msgs.get(id)!;
      await m.chain;
      if (!m.postId) continue;
      await this.mm.patchPost(m.postId, { message: m.text, props: this.props(m, broadcast && id === lastId) }).catch(() => {});
    }
    if (broadcast && !lastId && fallback.trim()) {
      await this.mm.createPost({ ...this.where, message: fallback, props: { flygo_reply: "thread_broadcast", flygo_agent_message: { run_id: this.runId, engine: this.engine, seq: 1, streaming: false, final: true } } });
    }
  }
}
