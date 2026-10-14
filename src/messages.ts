// Mỗi tin nhắn của agent là một post riêng trong chủ đề, nội dung sửa dần khi stream.
// props.flygo_agent_message = { run_id, engine, seq, streaming, final? }; props.flygo_agent_owner = người giao việc.
// Kết thúc lượt: tin cuối được ĐĂNG LẠI thành post mới có @nhắc thật người giao việc (Mattermost chỉ báo khi tạo post,
// không báo khi sửa), post stream cũ bị xoá. Tin cuối ra chat chính (thread_broadcast) tuỳ quy tắc của runner.
import type { RunCard } from "./card";
import type { MM } from "./mm";

interface Msg { postId: string; text: string; seq: number; streaming: boolean; timer: Timer | null; creating: Promise<void> | null; chain: Promise<void> }

export class MessageStream {
  private msgs = new Map<string, Msg>();
  private order: string[] = [];

  constructor(private mm: MM, private where: { channel_id: string; root_id: string }, private runId: string, private engine: string,
    private owner: { id: string; username: string }) {}

  private props(m: Msg, final = false) {
    return {
      flygo_reply: final ? "thread_broadcast" : "thread",
      flygo_agent_message: { run_id: this.runId, engine: this.engine, seq: m.seq, streaming: m.streaming },
      flygo_agent_owner: this.owner.id,
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

  /** Kết thúc lượt: chốt mọi tin; tin cuối (hoặc `fallback` nếu agent không có tin nào) đăng lại có @nhắc người giao việc. */
  async finish(fallback: string, broadcast = true) {
    for (const id of this.order) { const m = this.msgs.get(id)!; m.streaming = false; if (m.timer) { clearTimeout(m.timer); m.timer = null; } }
    const lastId = [...this.order].reverse().find((id) => this.msgs.get(id)!.text.trim());
    for (const id of this.order) {
      const m = this.msgs.get(id)!;
      await m.chain;
      if (!m.postId || id === lastId) continue;
      await this.mm.patchPost(m.postId, { message: m.text, props: this.props(m) }).catch(() => {});
    }
    const last = lastId ? this.msgs.get(lastId)! : null;
    const text = last ? last.text : fallback;
    if (!text.trim()) return;
    const props = {
      flygo_reply: broadcast ? "thread_broadcast" : "thread",
      flygo_agent_message: { run_id: this.runId, engine: this.engine, seq: last?.seq ?? 1, streaming: false, final: true },
      flygo_agent_owner: this.owner.id,
    };
    await this.mm.createPost({ ...this.where, message: `@${this.owner.username} ${text}`, props }, [this.owner.username]);
    if (last?.postId) await this.mm.deletePost(last.postId).catch(() => {});
  }
}

/** Trả lời ở chat chính (tin gốc không nằm trong luồng): MỘT post duy nhất, không tạo luồng.
 *  Post mang cả thẻ tiến trình (props.flygo_agent) lẫn tin stream (props.flygo_agent_message); chưa có chữ thì hiện thẻ.
 *  Kết thúc: đăng lại thành post mới (để có thông báo; ngoài DM thì @nhắc thật người giao việc) rồi xoá post stream. */
export class InlineReply {
  private postId = "";
  private text = "";
  private lastMsg = "";
  private timer: Timer | null = null;
  private creating: Promise<void> | null = null;
  private chain: Promise<void> = Promise.resolve();
  card!: RunCard;

  constructor(private mm: MM, private channelId: string, private runId: string, private engine: string,
    private owner: { id: string; username: string }, private mention: boolean) {}

  private body(streaming: boolean, final = false) {
    const { flygo_reply, ...cardProps } = this.card.props() as any;
    return {
      message: this.text.trim() ? this.text : this.card.render(),
      props: { ...cardProps, flygo_agent_message: { run_id: this.runId, engine: this.engine, seq: 1, streaming, ...(final ? { final: true } : {}) } },
    };
  }

  /** Thẻ đổi trạng thái/bước. */
  touch() { this.schedule(800); }

  update(u: { id: string; delta?: string; full?: string; done?: boolean }) {
    if (u.id !== this.lastMsg) { this.lastMsg = u.id; if (u.full === undefined) this.text = ""; } // tin mới của agent thay tin trước
    if (u.full !== undefined) this.text = u.full; else this.text += u.delta ?? "";
    if (this.card.status === "thinking") this.card.status = "running";
    this.schedule(500);
  }

  private schedule(delay: number) {
    if (!this.postId && !this.creating) {
      this.creating = this.mm.createPost({ channel_id: this.channelId, root_id: "", ...this.body(true) }).then((p) => { this.postId = p.id; }, () => {});
      this.chain = this.creating;
      return;
    }
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      const b = this.body(true);
      this.chain = this.chain.then(() => (this.postId ? this.mm.patchPost(this.postId, b).then(() => {}, () => {}) : undefined));
    }, delay);
  }

  /** text: câu trả lời cuối (rỗng khi lỗi/dừng: giữ post, chỉ chốt thẻ). */
  async finish(text: string) {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    await this.chain;
    if (text.trim()) this.text = text;
    if (!this.text.trim()) {
      const b = this.body(false, true);
      if (this.postId) await this.mm.patchPost(this.postId, b).catch(() => {});
      else await this.mm.createPost({ channel_id: this.channelId, root_id: "", ...b }).catch(() => {});
      return;
    }
    const b = this.body(false, true);
    const prefix = this.mention ? `@${this.owner.username} ` : "";
    await this.mm.createPost({ channel_id: this.channelId, root_id: "", message: prefix + b.message, props: b.props }, this.mention ? [this.owner.username] : []);
    if (this.postId) await this.mm.deletePost(this.postId).catch(() => {});
  }
}
