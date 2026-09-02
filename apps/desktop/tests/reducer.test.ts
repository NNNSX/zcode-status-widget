import { describe, expect, it } from "vitest";
import { normalizeConfig, resetPositionConfig } from "../src/shared/config";
import { SessionReducer } from "../src/shared/reducer";

const displayOptions = { showTodoProgress: true, showDuration: true } as const;

describe("session reducer", () => {
  it("preserves a closed round against late events and resets only on a new prompt", () => {
    const reducer = new SessionReducer();
    const start = 1_000_000;

    expect(reducer.apply({
      event: "user_prompt_submit",
      session_id: "session-1",
      project: "ZCode_ws",
      project_dir: "D:/ZCode_ws",
      workspace_source: "session_root",
      prompt_preview: "实现状态机",
      turn_id: "turn-1",
    }, start).accepted).toBe(true);

    const waiting = reducer.apply({
      event: "permission_request",
      session_id: "session-1",
      last_tool: "filesystem",
      turn_id: "turn-1",
    }, start + 2_000);
    expect(waiting.effects).toMatchObject([{ kind: "show-attention", attention: { kind: "waiting", title: "请完成审批" } }]);

    const resumed = reducer.apply({ event: "permission_bash", session_id: "session-1", turn_id: "turn-1" }, start + 3_000);
    expect(resumed.effects).toContainEqual({ kind: "cancel-attention", sessionId: "session-1" });

    const completed = reducer.apply({ event: "stop", session_id: "session-1", turn_id: "turn-1" }, start + 5_500);
    expect(completed.effects).toMatchObject([{ kind: "show-attention", attention: { kind: "done", title: "本轮任务完成" } }]);
    expect(reducer.displaySessions(start + 5_500, 5, displayOptions)[0]).toMatchObject({
      state: "done",
      duration: "0:05",
      task: "实现状态机",
    });

    expect(reducer.apply({
      event: "todo_update",
      session_id: "session-1",
      turn_id: "turn-1",
      todos: [{ content: "迟到事件", status: "in_progress" }],
    }, start + 6_000).accepted).toBe(false);

    expect(reducer.apply({
      event: "user_prompt_submit",
      session_id: "session-1",
      project: "ZCode_ws",
      turn_id: "turn-2",
      prompt_preview: "下一轮",
    }, start + 7_000).accepted).toBe(true);
    expect(reducer.displaySessions(start + 7_000, 5, displayOptions)[0]).toMatchObject({
      state: "working",
      task: "下一轮",
      todoProgress: "",
    });
    expect(reducer.apply({ event: "stop", session_id: "session-1", turn_id: "turn-1" }, start + 8_000).accepted).toBe(false);
  });

  it("keeps Bash approvals working and tool failures out of the session lamp", () => {
    const reducer = new SessionReducer();
    const now = 2_000_000;
    reducer.apply({ event: "user_prompt_submit", session_id: "bash-session", project: "terminal", turn_id: "turn" }, now);
    reducer.apply({ event: "tool_failure", session_id: "bash-session", error_preview: "transient failure", turn_id: "turn" }, now + 100);
    reducer.apply({ event: "permission_request", session_id: "bash-session", last_tool: "Bash", turn_id: "turn" }, now + 200);

    expect(reducer.displaySessions(now + 200, 5, displayOptions)[0]).toMatchObject({ state: "working" });
  });

  it("rejects late timestamped prompts and does not infer Bash from a prior event", () => {
    const reducer = new SessionReducer();
    const start = 4_000_000;
    reducer.apply({ event: "user_prompt_submit", session_id: "ordered", turn_id: "first", ts: 20 }, start);
    reducer.apply({ event: "permission_request", session_id: "ordered", turn_id: "first", last_tool: "Bash", ts: 21 }, start + 100);
    const nextRound = reducer.apply({ event: "user_prompt_submit", session_id: "ordered", turn_id: "second", ts: 30 }, start + 200);
    const latePrompt = reducer.apply({ event: "user_prompt_submit", session_id: "ordered", turn_id: "first", ts: 25 }, start + 300);
    const missingToolPermission = reducer.apply({ event: "permission_request", session_id: "ordered", turn_id: "second", ts: 31 }, start + 400);

    expect(nextRound.accepted).toBe(true);
    expect(latePrompt.accepted).toBe(false);
    expect(missingToolPermission.effects).toMatchObject([{ kind: "show-attention", attention: { kind: "waiting" } }]);
    expect(reducer.displaySessions(start + 400, 5, displayOptions)[0]).toMatchObject({ state: "waiting" });
  });

  it("resumes a waiting session when a Todo update is the first recovery event", () => {
    const reducer = new SessionReducer();
    const now = 5_000_000;
    reducer.apply({ event: "user_prompt_submit", session_id: "todo-resume", turn_id: "turn" }, now);
    reducer.apply({ event: "permission_request", session_id: "todo-resume", turn_id: "turn" }, now + 100);
    const resumed = reducer.apply({ event: "todo_update", session_id: "todo-resume", turn_id: "turn", todos: [] }, now + 200);

    expect(resumed.effects).toContainEqual({ kind: "cancel-attention", sessionId: "todo-resume" });
    expect(reducer.displaySessions(now + 200, 5, displayOptions)[0]).toMatchObject({ state: "working" });
  });

  it("uses a root workspace name in preference to transient event directories and honors done TTL", () => {
    const reducer = new SessionReducer();
    const now = 3_000_000;
    reducer.apply({
      event: "user_prompt_submit",
      session_id: "workspace-session",
      project: "temporary-folder",
      project_dir: "D:/temporary-folder",
      workspace_source: "event_dir",
      turn_id: "turn",
    }, now);
    reducer.apply({
      event: "todo_update",
      session_id: "workspace-session",
      project: "ZCode_ws",
      project_dir: "D:/ZCode_ws",
      workspace_source: "session_root",
      turn_id: "turn",
      todos: [{ content: "实施", status: "completed" }, { content: "验证", status: "pending" }],
    }, now + 100);
    reducer.apply({ event: "stop", session_id: "workspace-session", turn_id: "turn" }, now + 1_000);

    expect(reducer.displaySessions(now + 1_000, 5, displayOptions)[0]).toMatchObject({
      workspace: "ZCode_ws",
      todoProgress: "1/2",
      duration: "0:01",
    });
    expect(reducer.displaySessions(now + 61_001, 1, displayOptions)).toHaveLength(0);
  });
});

describe("configuration normalization", () => {
  it("resets only the stored panel position", () => {
    const config = normalizeConfig({
      corner: "top-left",
      marginX: 90,
      marginY: 120,
      opacity: 65,
      panelWidth: 560,
      showDuration: false,
      doneTtlMinutes: 12,
      attentionMode: "corner-overlay",
    });

    expect(resetPositionConfig(config)).toMatchObject({
      corner: "bottom-right",
      marginX: 14,
      marginY: 52,
      displayId: "",
      opacity: 65,
      panelWidth: 560,
      showDuration: false,
      doneTtlMinutes: 12,
      attentionMode: "corner-overlay",
    });
  });
  it("normalizes registry-shaped values into bounded application settings", () => {
    expect(normalizeConfig({
      opacity: "120",
      panelWidth: "100",
      doneTtlMinutes: "99",
      attentionDurationMs: "10",
      showDuration: "0",
      corner: "invalid",
    })).toMatchObject({
      opacity: 100,
      panelWidth: 320,
      doneTtlMinutes: 30,
      attentionDurationMs: 800,
      showDuration: false,
      corner: "bottom-right",
    });
    expect(normalizeConfig({ attentionMode: "center_overlay" })).toMatchObject({
      attentionMode: "center-overlay",
    });
    expect(normalizeConfig({ displayId: 42 })).toMatchObject({ displayId: "42" });
  });
});
