import type {
  AttentionContent,
  DisplaySession,
  HookEvent,
  ReducerEffect,
  SessionState,
  TodoItem,
} from "./protocol";

export const ANY_SESSION_TTL_MS = 30 * 60 * 1000;
export const MAX_SESSIONS = 128;

const supportedEventNames = new Set([
  "user_prompt_submit",
  "permission_bash",
  "permission_request",
  "todo_update",
  "tool_failure",
  "stop",
]);

interface SessionRecord {
  readonly key: string;
  createdAt: number;
  updatedAt: number;
  state: SessionState;
  stateSince: number;
  workspaceName: string;
  workspaceSource: "session_root" | "event_dir" | "";
  label: string;
  promptPreview: string;
  currentTask: string;
  todos: TodoItem[];
  roundStartedAt: number;
  lastEventTimestamp: number | undefined;
  completedDurationMs: number | undefined;
  activeTurnId: string;
  roundClosed: boolean;
  errorCount: number;
  lastError: string;
  lastTool: string;
}

export interface ApplyResult {
  readonly accepted: boolean;
  readonly effects: readonly ReducerEffect[];
}

const stringValue = (value: unknown): string => typeof value === "string" ? value.trim() : "";

const eventName = (value: unknown): string => stringValue(value).toLowerCase();

const eventTimestamp = (value: unknown): number | undefined => {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    return undefined;
  }
  return value < 10_000_000_000 ? Math.trunc(value * 1000) : Math.trunc(value);
};

const sessionKey = (event: HookEvent): string => stringValue(event.session_id)
  || stringValue(event.project_dir)
  || stringValue(event.project)
  || "default";

const eventTodos = (value: unknown): TodoItem[] => {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.flatMap((item): TodoItem[] => {
    if (!item || typeof item !== "object") {
      return [];
    }
    const todo = item as { readonly content?: unknown; readonly status?: unknown };
    return [{ content: stringValue(todo.content), status: stringValue(todo.status) || "pending" }];
  });
};

export const formatDuration = (durationMs: number): string => {
  const seconds = Math.max(0, Math.trunc(durationMs / 1000));
  if (seconds < 3600) {
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  }
  return `${Math.floor(seconds / 3600)}:${String(Math.floor(seconds / 60) % 60).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
};

const stateLabel: Readonly<Record<SessionState, string>> = {
  working: "执行中",
  waiting: "等待确认",
  done: "已完成",
  unknown: "暂无活跃会话",
};

export class SessionReducer {
  private readonly sessions = new Map<string, SessionRecord>();

  public apply(event: HookEvent, now = Date.now()): ApplyResult {
    const name = eventName(event.event);
    const effects: ReducerEffect[] = [];
    if (!supportedEventNames.has(name)) {
      return { accepted: false, effects };
    }
    const key = sessionKey(event);
    const turnId = stringValue(event.turn_id);
    const timestamp = eventTimestamp(event.ts);
    const existing = this.sessions.get(key);
    if (name === "user_prompt_submit" && existing && turnId && existing.activeTurnId === turnId && !existing.roundClosed) {
      return { accepted: false, effects };
    }
    if (name === "user_prompt_submit" && existing && timestamp !== undefined && existing.lastEventTimestamp !== undefined && timestamp <= existing.lastEventTimestamp) {
      return { accepted: false, effects };
    }
    const session = existing ?? this.createSession(key, now);
    if (!session) {
      return { accepted: false, effects };
    }
    if (timestamp !== undefined && session.lastEventTimestamp !== undefined && timestamp < session.lastEventTimestamp) {
      return { accepted: false, effects };
    }

    if (name === "user_prompt_submit") {
      session.activeTurnId = turnId;
      session.roundClosed = false;
    } else {
      if (session.activeTurnId && turnId !== session.activeTurnId) {
        return { accepted: false, effects };
      }
      if (!session.activeTurnId && turnId) {
        session.activeTurnId = turnId;
      }
      if (session.roundClosed) {
        return { accepted: false, effects };
      }
    }

    if (timestamp !== undefined) {
      session.lastEventTimestamp = timestamp;
    }
    const previousState = session.state;
    session.updatedAt = now;
    this.updateWorkspace(session, event);

    const lastTool = stringValue(event.last_tool);
    const errorPreview = stringValue(event.error_preview);
    if (lastTool) {
      session.lastTool = lastTool;
    }
    if (errorPreview) {
      session.lastError = errorPreview;
    }

    switch (name) {
      case "user_prompt_submit":
        effects.push({ kind: "cancel-attention", sessionId: key });
        session.roundStartedAt = now;
        session.completedDurationMs = undefined;
        session.promptPreview = stringValue(event.prompt_preview);
        session.todos = [];
        session.currentTask = "";
        session.errorCount = 0;
        session.lastError = "";
        session.lastTool = "";
        this.setState(session, "working", now);
        break;
      case "todo_update":
        session.todos = eventTodos(event.todos);
        session.currentTask = stringValue(event.current_task);
        if (session.state === "done" || session.state === "unknown" || session.state === "waiting") {
          this.setState(session, "working", now);
        }
        break;
      case "permission_bash":
        this.setState(session, "working", now);
        break;
      case "permission_request":
        this.setState(session, lastTool.toLowerCase() === "bash" ? "working" : "waiting", now);
        break;
      case "tool_failure":
        session.errorCount += 1;
        break;
      case "stop":
        session.completedDurationMs = Math.max(0, now - session.roundStartedAt);
        this.setState(session, "done", now);
        session.roundClosed = true;
        break;
      default:
        break;
    }

    if (session.state === "working" && previousState === "waiting") {
      effects.push({ kind: "cancel-attention", sessionId: key });
    }
    if (previousState !== session.state && (session.state === "waiting" || session.state === "done")) {
      effects.push({
        kind: "show-attention",
        sessionId: key,
        attention: this.attentionContent(session),
      });
    }
    return { accepted: true, effects };
  }

  public visibleSessions(now: number, doneTtlMinutes: number): readonly SessionRecord[] {
    const doneTtlMs = doneTtlMinutes * 60 * 1000;
    const visible: SessionRecord[] = [];
    for (const [key, session] of this.sessions) {
      const age = now - session.updatedAt;
      if (age > ANY_SESSION_TTL_MS || (session.state === "done" && age > doneTtlMs)) {
        this.sessions.delete(key);
        continue;
      }
      visible.push(session);
    }
    return visible.sort((left, right) => right.updatedAt - left.updatedAt);
  }

  public displaySessions(now: number, doneTtlMinutes: number, options: {
    readonly showTodoProgress: boolean;
    readonly showDuration: boolean;
  }): readonly DisplaySession[] {
    return this.visibleSessions(now, doneTtlMinutes).map((session) => this.toDisplaySession(session, now, options));
  }

  private evictInactiveSessions(now: number): void {
    for (const [key, session] of this.sessions) {
      if (now - session.updatedAt > ANY_SESSION_TTL_MS) {
        this.sessions.delete(key);
      }
    }
  }

  private createSession(key: string, now: number): SessionRecord | undefined {
    this.evictInactiveSessions(now);
    if (this.sessions.size >= MAX_SESSIONS) {
      const eviction = [...this.sessions.values()]
        .filter((candidate) => candidate.state === "done" || candidate.state === "unknown")
        .sort((left, right) => left.updatedAt - right.updatedAt)[0];
      if (!eviction) {
        return undefined;
      }
      this.sessions.delete(eviction.key);
    }
    const session: SessionRecord = {
      key,
      createdAt: now,
      updatedAt: now,
      state: "unknown",
      stateSince: now,
      workspaceName: "",
      workspaceSource: "",
      label: "",
      promptPreview: "",
      currentTask: "",
      todos: [],
      roundStartedAt: now,
      lastEventTimestamp: undefined,
      completedDurationMs: undefined,
      activeTurnId: "",
      roundClosed: false,
      errorCount: 0,
      lastError: "",
      lastTool: "",
    };
    this.sessions.set(key, session);
    return session;
  }

  private setState(session: SessionRecord, state: SessionState, now: number): void {
    if (session.state !== state) {
      session.state = state;
      session.stateSince = now;
    }
  }

  private updateWorkspace(session: SessionRecord, event: HookEvent): void {
    const project = stringValue(event.project);
    const hasProjectDirectory = Boolean(stringValue(event.project_dir));
    const source = stringValue(event.workspace_source) === "session_root" ? "session_root" : "event_dir";
    const canUpdate = !session.workspaceName || (source === "session_root" && session.workspaceSource !== "session_root");
    if (!canUpdate || !project || (project === "ZCode" && !hasProjectDirectory)) {
      return;
    }

    session.workspaceName = project;
    session.workspaceSource = source;
    if (!session.label || source === "session_root") {
      const labels = new Set(
        [...this.sessions.values()].filter((candidate) => candidate !== session).map((candidate) => candidate.label),
      );
      let label = project;
      let suffix = 2;
      while (labels.has(label)) {
        label = `${project}·${suffix}`;
        suffix += 1;
      }
      session.label = label;
    }
  }

  private attentionContent(session: SessionRecord): AttentionContent {
    const done = session.todos.filter((todo) => todo.status === "completed").length;
    const progress = session.todos.length ? `${done}/${session.todos.length}` : "";
    const summary = progress || (session.state === "done" && session.completedDurationMs !== undefined
      ? formatDuration(session.completedDurationMs)
      : "");
    return {
      sessionId: session.key,
      kind: session.state === "waiting" ? "waiting" : "done",
      title: session.state === "waiting" ? "请完成审批" : "本轮任务完成",
      workspace: session.label || session.workspaceName || "ZCode",
      summary,
    };
  }

  private toDisplaySession(session: SessionRecord, now: number, options: {
    readonly showTodoProgress: boolean;
    readonly showDuration: boolean;
  }): DisplaySession {
    const completedTodos = session.todos.filter((todo) => todo.status === "completed").length;
    const todoProgress = options.showTodoProgress && session.todos.length
      ? `${completedTodos}/${session.todos.length}`
      : "";
    let duration = "";
    if (options.showDuration) {
      if (session.state === "done" && session.completedDurationMs !== undefined) {
        duration = formatDuration(session.completedDurationMs);
      } else if (session.state === "working" || session.state === "waiting") {
        duration = formatDuration(now - session.stateSince);
      }
    }
    return {
      id: session.key,
      state: session.state,
      workspace: session.label || session.workspaceName || "ZCode",
      task: session.currentTask || session.promptPreview || stateLabel[session.state],
      todoProgress,
      duration,
    };
  }
}
