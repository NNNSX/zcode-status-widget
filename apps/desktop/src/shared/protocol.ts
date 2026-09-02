export type SessionState = "working" | "waiting" | "done" | "unknown";

export interface HookTodo {
  readonly content?: unknown;
  readonly status?: unknown;
}

export interface HookEvent {
  readonly event?: unknown;
  readonly session_id?: unknown;
  readonly project?: unknown;
  readonly project_dir?: unknown;
  readonly workspace_dir?: unknown;
  readonly workspace_source?: unknown;
  readonly prompt_preview?: unknown;
  readonly last_tool?: unknown;
  readonly error_preview?: unknown;
  readonly todos?: unknown;
  readonly current_task?: unknown;
  readonly turn_id?: unknown;
  readonly ts?: unknown;
}

export interface TodoItem {
  readonly content: string;
  readonly status: string;
}

export interface DisplaySession {
  readonly id: string;
  readonly state: SessionState;
  readonly workspace: string;
  readonly task: string;
  readonly todoProgress: string;
  readonly duration: string;
}

export interface PanelSnapshot {
  readonly sessions: readonly DisplaySession[];
  readonly showIdle: boolean;
}

export interface AttentionContent {
  readonly sessionId: string;
  readonly kind: "waiting" | "done";
  readonly title: string;
  readonly workspace: string;
  readonly summary: string;
}

export interface ReducerEffect {
  readonly kind: "show-attention" | "cancel-attention";
  readonly sessionId: string;
  readonly attention?: AttentionContent;
}
