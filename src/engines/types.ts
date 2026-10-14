import type { StepKind, StepStatus } from "../card";

export interface ApprovalRequest {
  kind: "command" | "file" | "tool";
  title: string; // một dòng: lệnh / file / tool
  detail?: string;
}
export type ApprovalDecision = "accept" | "decline";

export interface TurnHooks {
  step(s: { id: string; kind: StepKind; title: string; status: StepStatus; detail?: string }): void;
  approval(req: ApprovalRequest): Promise<ApprovalDecision>;
  session(id: string): void; // engine báo session/thread id ngay khi có
}

export interface TurnInput {
  sessionId?: string; // trống = phiên mới
  cwd: string;
  prompt: string;
  persona: string; // hướng dẫn hệ thống (xưng hô, quy tắc)
  mcpEnv: Record<string, string>; // env cho MCP server flygo_chat của phiên này
}

export interface TurnResult {
  sessionId: string;
  text: string; // câu trả lời cuối
  usage?: Record<string, any>;
}

export interface Engine {
  name: "codex" | "claude";
  runTurn(input: TurnInput, hooks: TurnHooks, signal: AbortSignal): Promise<TurnResult>;
}
