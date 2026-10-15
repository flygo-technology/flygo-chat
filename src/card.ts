// Thẻ tiến trình: một post trong chủ đề mang props.flygo_agent, sửa dần (có throttle).
// Trả lời ở chat chính (onChange): thẻ không có post riêng, props của thẻ gắn vào post trả lời đang stream (InlineReply).
// Định dạng props.flygo_agent xem README.md ("Giao thức hiển thị").
import type { MM } from "./mm";

export type StepKind = "command" | "file" | "tool" | "search" | "message" | "thinking" | "approval" | "other";
export type StepStatus = "running" | "done" | "error" | "waiting";
export interface Step {
  id: string;
  kind: StepKind;
  title: string;
  status: StepStatus;
  detail?: string;
  started_at: number;
  ended_at?: number;
}
export type RunStatus = "thinking" | "running" | "awaiting_approval" | "done" | "error" | "cancelled" | "stopped"; // stopped: runner tắt giữa lượt

const MAX_STEPS = 40;
const MAX_DETAIL = 600;
const ICON: Record<StepStatus, string> = { running: "⏳", done: "✅", error: "❌", waiting: "✋" };
// Hashtag để lọc phiên AI bằng tìm kiếm Mattermost: "#ai_dang_lam in:kenh", "#flygo_ai from:sep-ai".
export const STATUS_TAG: Record<RunStatus, string> = {
  thinking: "#ai_dang_lam", running: "#ai_dang_lam", awaiting_approval: "#ai_cho_duyet", done: "#ai_xong", error: "#ai_loi", cancelled: "#ai_da_dung", stopped: "#ai_da_dung",
};
const STATUS_TEXT: Record<RunStatus, string> = {
  thinking: "đang suy nghĩ…", running: "đang làm…", awaiting_approval: "chờ Sếp duyệt", done: "xong", error: "lỗi", cancelled: "đã dừng", stopped: "bị dừng giữa chừng",
};

export class RunCard {
  postId = "";
  status: RunStatus = "thinking";
  steps: Step[] = [];
  usage: Record<string, any> | undefined;
  sessionId = "";
  error = "";
  triggerId = ""; // tin giao việc của lượt (để "Tiếp tục")
  interrupted = false; // bị dừng vì runner tắt: app hiện nút "Tiếp tục" (▶️)
  config: { model?: string; effort?: string; note?: string } | undefined; // model / mức suy nghĩ của lượt
  private timer: Timer | null = null;
  private dirty = false;
  private flushing: Promise<void> = Promise.resolve();
  readonly startedAt = Date.now();
  endedAt = 0;

  constructor(
    private mm: MM,
    private where: { channel_id: string; root_id: string },
    readonly runId: string,
    readonly engine: string,
    readonly title: string,
    readonly ownerId: string,
    private onChange?: () => void,
  ) {}

  async create() {
    if (this.onChange) return;
    const p = await this.mm.createPost({ ...this.where, message: this.render(), props: this.props() });
    this.postId = p.id;
  }

  step(s: Omit<Step, "started_at"> & { started_at?: number }) {
    const old = this.steps.find((x) => x.id === s.id);
    const max = s.kind === "message" ? 4000 : MAX_DETAIL; // câu trả lời của agent khác (A2A): giữ dài hơn để xem lại
    const detail = s.detail && s.detail.length > max ? s.detail.slice(0, max) + "…" : s.detail;
    if (old) {
      Object.assign(old, { ...s, detail: detail ?? old.detail, started_at: old.started_at });
      if (s.status !== "running" && s.status !== "waiting" && !old.ended_at) old.ended_at = Date.now();
    } else {
      this.steps.push({ ...s, detail, started_at: s.started_at ?? Date.now(), ended_at: s.status === "done" || s.status === "error" ? Date.now() : undefined });
      if (this.steps.length > MAX_STEPS) this.steps.splice(0, this.steps.length - MAX_STEPS);
    }
    if (this.status === "thinking") this.status = "running";
    this.touch();
  }

  setStatus(st: RunStatus) { this.status = st; if (st === "done" || st === "error" || st === "cancelled" || st === "stopped") this.endedAt = Date.now(); this.touch(); }

  props() {
    return {
      ...(this.where.root_id ? { flygo_reply: "thread" } : {}),
      flygo_agent_owner: this.ownerId,
      flygo_agent: {
        v: 1,
        run_id: this.runId,
        engine: this.engine,
        config: this.config,
        title: this.title,
        status: this.status,
        session_id: this.sessionId,
        started_at: this.startedAt,
        ended_at: this.endedAt || undefined,
        steps: this.steps,
        usage: this.usage,
        error: this.error || undefined,
        post_id: this.triggerId || undefined,
        ...(this.interrupted ? { interrupted: true, resume_post_id: this.triggerId } : {}),
      },
    };
  }

  /** Văn bản dự phòng cho client không hiểu props (webapp, app Mattermost chính thức). */
  render() {
    const secs = Math.round(((this.endedAt || Date.now()) - this.startedAt) / 1000);
    const cfg = this.config ? [this.config.model, this.config.effort].filter(Boolean).join(" ") : "";
    const head = `🤖 **${this.engine}**${cfg ? ` (${cfg})` : ""} · ${STATUS_TEXT[this.status]} · ${secs}s`;
    const lines = this.steps.slice(-8).map((s) => `${ICON[s.status]} ${s.title}`);
    if (this.steps.length > 8) lines.unshift(`… ${this.steps.length - 8} bước trước`);
    if (this.config?.note) lines.push(`⚠️ ${this.config.note}`);
    if (this.error) lines.push(`❌ ${this.error}`);
    return [head, ...lines, "", `#flygo_ai ${STATUS_TAG[this.status]}`].join("\n");
  }

  private touch() {
    this.dirty = true;
    if (!this.timer) this.timer = setTimeout(() => { this.timer = null; this.flush(); }, 800);
  }

  flush(): Promise<void> {
    if (this.onChange) { this.dirty = false; this.onChange(); return this.flushing; }
    if (!this.postId || !this.dirty) return this.flushing;
    this.dirty = false;
    const body = { message: this.render(), props: this.props() };
    this.flushing = this.flushing.then(() => this.mm.patchPost(this.postId, body).then(() => {}, () => {}));
    return this.flushing;
  }

  async finish() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    this.dirty = true;
    await this.flush();
  }
}
