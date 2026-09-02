import type { DisplaySession, SessionState } from "./protocol";

export type { DisplaySession, SessionState } from "./protocol";

export const stateLabels: Readonly<Record<SessionState, string>> = {
  working: "执行中",
  waiting: "等待确认",
  done: "已完成",
  unknown: "暂无活跃会话",
};

export const idleSession: DisplaySession = {
  id: "idle",
  state: "unknown",
  workspace: "暂无活跃会话",
  task: "等待新的 ZCode 会话",
  todoProgress: "",
  duration: "",
};
