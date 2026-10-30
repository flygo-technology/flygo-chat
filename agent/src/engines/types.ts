import type { StepKind, StepStatus } from "../card";

export interface ApprovalRequest {
  kind: "command" | "file" | "tool" | "report" | "plan";
  title: string; // một dòng: lệnh / file / tool
  detail?: string;
}
export type ApprovalDecision = "accept" | "decline";
/** Chế độ quyền người dùng chọn trên app: Thủ công / Chấp nhận chỉnh sửa / Lập kế hoạch / Tự động. */
export type PermMode = "manual" | "acceptEdits" | "plan" | "auto" | "bypassPermissions";
export const PERM_MODES: PermMode[] = ["manual", "acceptEdits", "plan", "auto", "bypassPermissions"];

/** Câu hỏi agent hỏi người dùng (Claude AskUserQuestion, Codex request_user_input, tool MCP ask_user). */
export interface UserQuestion {
  id: string;
  question: string;
  header?: string;
  options: { label: string; description?: string }[];
  multi?: boolean;
}
/** Trả lời từng câu (cùng thứ tự); null = người dùng huỷ / hết hạn / không hỏi được. */
export interface UserAnswer { choices: string[]; other?: string }
export type AskResult = { answers: UserAnswer[] } | { cancelled: true; reason: string };
/** Câu trả lời dạng chữ cho agent: các lựa chọn + ý khác. */
export const answerText = (a: UserAnswer) => [...a.choices, ...(a.other ? [a.other] : [])].join(", ");

export interface TurnHooks {
  step(s: { id: string; kind: StepKind; title: string; label?: string; status: StepStatus; detail?: string }): void;
  /** Tin nhắn của agent đang stream: `delta` nối thêm, hoặc `full` thay toàn bộ; `done` khi tin đã xong. */
  text(m: { id: string; delta?: string; full?: string; done?: boolean }): void;
  approval(req: ApprovalRequest): Promise<ApprovalDecision>;
  /** Hỏi người dùng (trả lời ngay trong lượt). */
  ask(questions: UserQuestion[]): Promise<AskResult>;
  session(id: string): void; // engine báo session/thread id ngay khi có
}

export interface TurnInput {
  sessionId?: string; // trống = phiên mới
  forkFrom?: string; // phiên mới tách (fork) từ phiên này (phiên cha: chat chính / nhóm cha), mang theo ngữ cảnh của nó
  cwd: string;
  prompt: string;
  persona: string; // hướng dẫn hệ thống (xưng hô, quy tắc)
  title: string; // tên phiên hiện trên Codex app / claude --resume: "<tên chat> · <tên luồng | Luồng chính>"
  group: string; // nhóm phiên theo chat (Codex: section "Flygo · <tên chat>")
  mcpEnv: Record<string, string>; // env cho MCP server flygo_chat của phiên này
  model?: string; // model cho lượt này (người dùng chọn hoặc mặc định)
  effort?: string; // mức suy nghĩ cho lượt này
  fallbackModel?: string; // model mặc định của bot: model đã chọn bị upstream từ chối thì chạy lại bằng model này (Codex)
  addDirs?: string[]; // thư mục thêm (Claude: --add-dir; dùng cho kỹ năng riêng của bot)
  bypass?: boolean; // chủ bot "luôn cho phép" phạm vi này: không hỏi duyệt, toàn quyền
  mode?: PermMode; // chế độ quyền của lượt (thiếu = mặc định của engine: Claude thủ công, Codex chấp nhận chỉnh sửa)
}

export interface TurnResult {
  sessionId: string;
  text: string; // câu trả lời cuối
  usage?: Record<string, any>;
}

/** Kiểm kê của engine trên máy: kỹ năng engine tự nạp, model dùng được. */
export interface EngineInventory {
  skills: { name: string; description: string }[];
  models: { id: string; name?: string; efforts: string[]; defaultEffort?: string; isDefault?: boolean }[];
}

export interface Engine {
  name: "codex" | "claude" | "agy";
  inventory(): Promise<EngineInventory>;
  runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult>;
  /** Cỡ ngữ cảnh hiện tại của phiên (token của lần gọi model gần nhất); null = không đọc được (không có phiên trên máy). */
  contextTokens(sessionId: string): Promise<number | null>;
}
