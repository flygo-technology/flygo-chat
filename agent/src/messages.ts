// Mỗi lượt của agent là MỘT post (chat chính hoặc trong luồng): thẻ tiến trình props.flygo_agent + chữ stream
// props.flygo_agent_message = { run_id, engine, seq, streaming, final? } + lời xin duyệt props.flygo_agent_approval.
// Kết thúc lượt: ĐĂNG LẠI thành post mới (Mattermost chỉ báo khi tạo post, không báo khi sửa), post stream bị xoá.
import type { RunCard } from "./card";
import type { MM } from "./mm";

/** Trả lời của một lượt: MỘT post duy nhất, ở chat chính (root_id rỗng) hoặc trong luồng (flygo_reply).
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
  approval: Record<string, any> | null = null; // lời xin duyệt nằm ngay trong post (props.flygo_agent_approval)

  broadcast = false; // trong luồng: tin cuối gửi cả ra chat chính (thread_broadcast)
  private lastSent = ""; // bỏ lần sửa trùng nội dung
  private held = false; // đang chờ người duyệt / trả lời: không sửa post (trừ lời xin duyệt)
  private heldDirty = false;

  /** where.root_id rỗng = chat chính; có = trong luồng (props.flygo_reply). */
  constructor(private mm: MM, private where: { channel_id: string; root_id: string }, private runId: string, private engine: string,
    private owner: { id: string; username: string }, private mention: boolean) {}

  private body(streaming: boolean, final = false) {
    const { flygo_reply, ...cardProps } = this.card.props() as any;
    return {
      message: this.text.trim() ? this.text : this.card.render(),
      props: {
        ...(this.where.root_id ? { flygo_reply: final && this.broadcast ? "thread_broadcast" : "thread" } : {}),
        ...cardProps,
        flygo_agent_message: { run_id: this.runId, engine: this.engine, seq: 1, streaming, ...(final ? { final: true } : {}) },
        ...(this.approval && !final ? { flygo_agent_approval: this.approval } : {}),
      },
    };
  }

  get id() { return this.postId; }
  /** chữ agent đã viết tới giờ */
  get current() { return this.text; }
  /** id post đang stream (tạo ngay nếu chưa có). */
  async ensurePost(): Promise<string> {
    if (!this.postId && !this.creating) this.schedule(0);
    await this.creating;
    return this.postId;
  }
  /** Đặt / bỏ lời xin duyệt trên post, sửa ngay. */
  async setApproval(a: Record<string, any> | null) {
    this.approval = a;
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    this.push();
    await this.chain;
  }
  /** Chờ người (duyệt / trả lời câu hỏi): ngừng sửa post; thôi chờ thì sửa một lần nếu có thay đổi. */
  hold(on: boolean) {
    this.held = on;
    if (!on && this.heldDirty) { this.heldDirty = false; this.schedule(0); }
  }
  private push() {
    const b = this.body(true);
    const key = JSON.stringify(b);
    if (key === this.lastSent) return;
    this.chain = this.chain.then(() => {
      if (!this.postId) return;
      this.lastSent = key;
      return this.mm.patchPost(this.postId, b).then(() => {}, () => { this.lastSent = ""; });
    });
  }

  /** Thẻ đổi trạng thái/bước. */
  touch() { this.schedule(800); }

  update(u: { id: string; delta?: string; full?: string; done?: boolean }) {
    this.card.text(u); // giữ mọi đoạn (props.flygo_agent.texts); post.message vẫn là đoạn đang / cuối
    if (u.id !== this.lastMsg) { this.lastMsg = u.id; if (u.full === undefined) this.text = ""; } // tin mới của agent thay tin trước
    if (u.full !== undefined) this.text = u.full; else this.text += u.delta ?? "";
    if (this.card.status === "thinking") this.card.status = "running";
    this.schedule(500);
  }

  private schedule(delay: number) {
    if (!this.postId && !this.creating) {
      this.creating = this.mm.createPost({ ...this.where, ...this.body(true) }).then((p) => { this.postId = p.id; }, () => {});
      this.chain = this.creating;
      return;
    }
    if (this.held) { this.heldDirty = true; return; }
    if (this.timer) return;
    this.timer = setTimeout(() => { this.timer = null; this.push(); }, delay);
  }

  /** text: câu trả lời cuối (rỗng khi lỗi/dừng: giữ post, chỉ chốt thẻ). */
  async finish(text: string) {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    await this.chain;
    if (text.trim()) this.text = text;
    if (!this.text.trim()) {
      const b = this.body(false, true);
      if (this.postId) await this.mm.patchPost(this.postId, b).catch(() => {});
      else await this.mm.createPost({ ...this.where, ...b }).catch(() => {});
      return;
    }
    const b = this.body(false, true);
    const prefix = this.mention ? `@${this.owner.username} ` : "";
    await this.mm.createPost({ ...this.where, message: prefix + b.message, props: b.props }, this.mention ? [this.owner.username] : []);
    if (this.postId) await this.mm.deletePost(this.postId).catch(() => {});
  }
}
