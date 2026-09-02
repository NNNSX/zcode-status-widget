import type { DisplaySession } from "../shared/ui-model";

export const renderSessionRow = (session: DisplaySession): HTMLElement => {
  const row = document.createElement("article");
  row.className = "session-row";
  row.dataset.state = session.state;
  row.dataset.testid = `session-${session.id}`;

  const signal = document.createElement("span");
  signal.className = "signal-group";
  signal.setAttribute("aria-label", session.state);
  for (const color of ["red", "yellow", "green"] as const) {
    const dot = document.createElement("span");
    dot.className = `signal-dot signal-dot--${color}`;
    dot.dataset.active = String(
      (session.state === "working" && color === "yellow") ||
      (session.state === "waiting" && color === "red") ||
      (session.state === "done" && color === "green"),
    );
    signal.append(dot);
  }

  const workspace = document.createElement("strong");
  workspace.className = "workspace";
  workspace.textContent = session.workspace;

  const task = document.createElement("span");
  task.className = "task";
  task.textContent = session.task;
  task.title = session.task;

  const todo = document.createElement("span");
  todo.className = "summary summary--todo";
  todo.textContent = session.todoProgress;

  const duration = document.createElement("time");
  duration.className = "summary summary--duration";
  duration.textContent = session.duration;

  row.append(signal, workspace, task, todo, duration);
  return row;
};
