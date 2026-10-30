// Kiểm thử bộ đọc stream-json của agy và hook duyệt: `bun test src/engines`.
// Dòng mẫu: theo tài liệu headless (antigravity.google/docs/cli/headless) và dòng thật của agy 1.4.11 (lỗi đăng nhập).
import { describe, expect, test } from "bun:test";
import { AgyStream, approvalInput, describeAgy, hookPlan, mcpName, parseModels, stepStatus, toolClass } from "./antigravity";

function collect() {
  const ev: { steps: any[]; texts: any[]; sessions: string[] } = { steps: [], texts: [], sessions: [] };
  const p = new AgyStream({ step: (s) => ev.steps.push(s), text: (t) => ev.texts.push(t), session: (id) => ev.sessions.push(id) });
  return { p, ev };
}

describe("AgyStream", () => {
  test("lượt trả lời chữ (mẫu trong tài liệu)", () => {
    const { p, ev } = collect();
    const lines = [
      `{"event":"init","conversation_id":"c-1","init":{"cwd":"/tmp","tools":["run_command"],"permission_mode":"request-review"}}`,
      `{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":0,"state":"DONE","step_type":"user_input"}}`,
      `{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":3,"state":"RUNNING","step_type":"agent_response","text_delta":"Xin "}}`,
      `{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"chào","duration_seconds":6.28,"usage":{"input_tokens":1200,"output_tokens":5,"cache_read_tokens":300}}}`,
      `{"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"Xin chào","duration_seconds":6.88,"num_turns":1,"usage":{"input_tokens":1200,"output_tokens":5,"thinking_tokens":0,"cache_read_tokens":300,"total_tokens":1505}}}`,
    ];
    const ends = lines.map((l) => p.line(l));
    expect(ends).toEqual([false, false, false, false, true]);
    expect(ev.sessions).toEqual(["c-1"]);
    expect(ev.texts.filter((t) => t.delta).map((t) => t.delta).join("")).toBe("Xin chào");
    expect(ev.texts.at(-1)).toEqual({ id: "agy-3", full: "Xin chào", done: true });
    expect(p.final).toBe("Xin chào");
    expect(p.ctxTokens).toBe(1500);
    expect(p.result.status).toBe("SUCCESS");
  });

  test("bước công cụ: chạy lệnh rồi xong, không báo trùng khi đang chạy", () => {
    const { p, ev } = collect();
    p.line(`{"event":"step_update","step_update":{"conversation_id":"c-2","step_index":1,"state":"RUNNING","step_type":"tool_call","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la src","Cwd":"/tmp"}}}}`);
    p.line(`{"event":"step_update","step_update":{"conversation_id":"c-2","step_index":1,"state":"RUNNING","step_type":"tool_call","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la src","Cwd":"/tmp"}}}}`);
    p.line(`{"event":"step_update","step_update":{"conversation_id":"c-2","step_index":1,"state":"DONE","step_type":"tool_call","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la src"},"output":"a.ts\\nb.ts"}}}`);
    expect(ev.steps.length).toBe(2);
    expect(ev.steps[0]).toMatchObject({ id: "agy-1", kind: "command", title: "$ ls -la src", label: "Liệt kê src", status: "running" });
    expect(ev.steps[1]).toMatchObject({ status: "done", detail: "a.ts\nb.ts" });
  });

  test("tool flygo_chat runner tự ghi bước thì ẩn; tool đọc thì hiện nhãn", () => {
    const { p, ev } = collect();
    p.line(`{"event":"step_update","step_update":{"step_index":2,"state":"RUNNING","tool_info":{"name":"mcp_flygo_chat_chat_report_out","parameters":{"message":"x"}}}}`);
    p.line(`{"event":"step_update","step_update":{"step_index":4,"state":"DONE","tool_info":{"name":"flygo_chat/chat_history","parameters":{}}}}`);
    expect(ev.steps.length).toBe(1);
    expect(ev.steps[0]).toMatchObject({ id: "agy-4", label: "Đọc tin nhắn", status: "done" });
  });

  test("lỗi đăng nhập (dòng thật agy 1.4.11)", () => {
    const { p } = collect();
    expect(p.line(`{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"finished_reason":"error"}}`)).toBe(true);
    expect(p.result.error).toBe("authentication failed or timed out");
    expect(p.sessionId).toBe("");
  });

  test("bỏ qua dòng rác / không phải JSON", () => {
    const { p, ev } = collect();
    expect(p.line("Waiting for authentication (timeout 60s)...")).toBe(false);
    expect(p.line("{bad")).toBe(false);
    expect(ev.steps.length + ev.texts.length).toBe(0);
  });
});

describe("tên công cụ / duyệt", () => {
  test("trạng thái bước", () => {
    expect(stepStatus("DONE")).toBe("done");
    expect(stepStatus("CORTEX_STEP_STATUS_ERROR")).toBe("error");
    expect(stepStatus("CORTEX_STEP_STATUS_WAITING")).toBe("waiting");
    expect(stepStatus("GENERATING")).toBe("running");
  });
  test("tên MCP", () => {
    expect(mcpName("mcp_flygo_chat_ask_user")).toBe("mcp__flygo_chat__ask_user");
    expect(mcpName("flygo_chat/chat_send_files")).toBe("mcp__flygo_chat__chat_send_files");
    expect(mcpName("run_command")).toBeNull();
    expect(toolClass("flygo_chat/chat_send_files")).toBe("flygo");
  });
  test("nhóm công cụ và quyết định theo chế độ", () => {
    expect(toolClass("view_file")).toBe("read");
    expect(toolClass("write_to_file")).toBe("edit");
    expect(toolClass("run_command")).toBe("command");
    expect(toolClass("browser_click")).toBe("other");
    expect(hookPlan("run_command", "manual")).toBe("ask");
    expect(hookPlan("write_to_file", "manual")).toBe("ask");
    expect(hookPlan("write_to_file", "acceptEdits")).toEqual({ decision: "auto_approve" });
    expect(hookPlan("run_command", "acceptEdits")).toBe("ask");
    expect(hookPlan("view_file", "manual")).toEqual({ decision: "allow" });
    expect((hookPlan("run_command", "plan") as any).decision).toBe("deny");
    expect(hookPlan("run_command", "auto")).toEqual({ decision: "allow" });
    expect(hookPlan("run_command", "bypassPermissions")).toEqual({ decision: "auto_approve" });
    expect(hookPlan("mcp_flygo_chat_chat_send_files", "plan")).toEqual({ decision: "auto_approve" });
  });
  test("lời xin duyệt dạng Claude", () => {
    expect(approvalInput("run_command", { CommandLine: "rm x", Cwd: "/w" })).toEqual({ tool_name: "Bash", input: { command: "rm x", description: "trong /w" } });
    expect(approvalInput("write_to_file", { TargetFile: "/w/a.md", CodeContent: "hi" })).toEqual({ tool_name: "Write", input: { file_path: "/w/a.md", content: "hi" } });
    expect(approvalInput("multi_replace_file_content", { TargetFile: "/w/a", ReplacementChunks: [{ TargetContent: "a", ReplacementContent: "b" }] }).input.edits).toEqual([{ old_string: "a", new_string: "b" }]);
    expect(describeAgy("write_to_file", { TargetFile: "/w/a.md" })).toMatchObject({ kind: "file", label: "Tạo a.md" });
  });
});

describe("parseModels", () => {
  test("mảng JSON", () => {
    const m = parseModels(`[{"slug":"gemini-3.8-flash-medium","display_name":"Gemini 3.8 Flash","is_default":true},{"slug":"gpt-oss-120b"}]`);
    expect(m.map((x) => x.id)).toEqual(["gemini-3.8-flash-medium", "gpt-oss-120b"]);
    expect(m[0]).toMatchObject({ name: "Gemini 3.8 Flash", isDefault: true });
  });
  test("{models:[…]} và chữ thường", () => {
    expect(parseModels(`{"models":[{"id":"a","efforts":["low","high"]}]}`)[0]).toMatchObject({ id: "a", efforts: ["low", "high"] });
    expect(parseModels("gemini-3.8-flash-medium (default)\nclaude-sonnet-5-5\n").map((x) => x.id)).toEqual(["gemini-3.8-flash-medium", "claude-sonnet-5-5"]);
    const t = parseModels("Available models:\n  * gemini-3.8-flash-medium   Gemini 3.8 Flash\n  - gpt-oss-120b   GPT-OSS 120B\nMODEL NAME\n");
    expect(t.map((x) => [x.id, x.isDefault])).toEqual([["gemini-3.8-flash-medium", true], ["gpt-oss-120b", false]]);
  });
});
