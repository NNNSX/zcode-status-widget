import { EventEmitter } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Socket } from "node:net";
import type { AddressInfo } from "node:net";
import type { HookEvent } from "../shared/protocol";

export const EVENT_HOST = "127.0.0.1";
export const EVENT_PORT = 57310;
export const MAX_EVENT_BYTES = 64 * 1024;
export const MAX_EVENT_QUEUE = 256;
export const MAX_EVENTS_PER_TICK = 32;
export const REQUEST_TIMEOUT_MS = 30_000;
export const MAX_EVENT_STRING_LENGTH = 512;
export const MAX_EVENT_TODOS = 64;
export const EVENT_SERVER_STOP_TIMEOUT_MS = 1_000;

const supportedEventNames = new Set([
  "user_prompt_submit",
  "permission_bash",
  "permission_request",
  "todo_update",
  "tool_failure",
  "stop",
]);

const stringValue = (value: unknown, maximumLength = MAX_EVENT_STRING_LENGTH): string | undefined => (
  typeof value === "string" && value.length <= maximumLength ? value : undefined
);

const sanitizedTodos = (value: unknown): readonly { readonly content?: string; readonly status?: string }[] | undefined => {
  if (!Array.isArray(value) || value.length > MAX_EVENT_TODOS) {
    return undefined;
  }
  const todos: { content?: string; status?: string }[] = [];
  for (const rawTodo of value) {
    if (!rawTodo || typeof rawTodo !== "object" || Array.isArray(rawTodo)) {
      return undefined;
    }
    const todo = rawTodo as { readonly content?: unknown; readonly status?: unknown };
    const content = stringValue(todo.content);
    const status = stringValue(todo.status, 64);
    if ((todo.content !== undefined && content === undefined) || (todo.status !== undefined && status === undefined)) {
      return undefined;
    }
    todos.push({ ...(content === undefined ? {} : { content }), ...(status === undefined ? {} : { status }) });
  }
  return todos;
};

export const sanitizeHookEvent = (payload: unknown): HookEvent | undefined => {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return undefined;
  }
  const raw = payload as Record<string, unknown>;
  const event = stringValue(raw.event, 64)?.trim().toLowerCase();
  if (!event || !supportedEventNames.has(event)) {
    return undefined;
  }
  const strings: Record<string, string> = {};
  for (const field of [
    "session_id", "project", "project_dir", "workspace_dir", "workspace_source",
    "prompt_preview", "last_tool", "error_preview", "current_task", "turn_id",
  ]) {
    if (raw[field] === undefined) {
      continue;
    }
    const value = stringValue(raw[field]);
    if (value === undefined) {
      return undefined;
    }
    strings[field] = value;
  }
  const todos = raw.todos === undefined ? undefined : sanitizedTodos(raw.todos);
  if (raw.todos !== undefined && todos === undefined) {
    return undefined;
  }
  const timestamp = raw.ts;
  if (timestamp !== undefined && (typeof timestamp !== "number" || !Number.isFinite(timestamp))) {
    return undefined;
  }
  return {
    event,
    ...strings,
    ...(todos === undefined ? {} : { todos }),
    ...(timestamp === undefined ? {} : { ts: timestamp }),
  };
};

export interface EventServerOptions {
  readonly host?: string;
  readonly port?: number;
  readonly maxBytes?: number;
  readonly maxQueue?: number;
  readonly requestTimeoutMs?: number;
}

const response = (res: ServerResponse, status: number, close = false): void => {
  if (res.writableEnded || res.destroyed) {
    return;
  }
  res.statusCode = status;
  res.setHeader("Content-Length", "0");
  if (close) {
    res.setHeader("Connection", "close");
  }
  res.end();
};

export class EventServer extends EventEmitter {
  private readonly host: string;
  private readonly port: number;
  private readonly maxBytes: number;
  private readonly maxQueue: number;
  private readonly requestTimeoutMs: number;
  private readonly queue: HookEvent[] = [];
  private readonly sockets = new Set<Socket>();
  private server: Server | undefined;

  public constructor(options: EventServerOptions = {}) {
    super();
    this.host = options.host ?? EVENT_HOST;
    this.port = options.port ?? EVENT_PORT;
    this.maxBytes = options.maxBytes ?? MAX_EVENT_BYTES;
    this.maxQueue = options.maxQueue ?? MAX_EVENT_QUEUE;
    this.requestTimeoutMs = options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS;
  }

  public async start(): Promise<void> {
    if (this.server) {
      return;
    }
    const server = createServer((request, reply) => this.handle(request, reply));
    server.on("connection", (socket: Socket) => {
      this.sockets.add(socket);
      socket.once("close", () => this.sockets.delete(socket));
    });
    server.on("error", (error: Error) => this.emit("server-error", error));
    server.requestTimeout = this.requestTimeoutMs;
    server.headersTimeout = Math.min(this.requestTimeoutMs, 60_000);
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => {
        server.off("listening", onListening);
        this.server = undefined;
        reject(error);
      };
      const onListening = (): void => {
        server.off("error", onError);
        resolve();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen({ host: this.host, port: this.port, exclusive: true });
    });
  }

  public async stop(): Promise<void> {
    const server = this.server;
    this.server = undefined;
    if (!server) {
      return;
    }
    const closed = new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    const deadline = setTimeout(() => {
      for (const socket of this.sockets) {
        socket.destroy();
      }
    }, EVENT_SERVER_STOP_TIMEOUT_MS);
    try {
      await closed;
    } finally {
      clearTimeout(deadline);
      this.sockets.clear();
    }
  }

  public drain(limit = MAX_EVENTS_PER_TICK): HookEvent[] {
    return this.queue.splice(0, Math.max(0, Math.min(limit, this.queue.length)));
  }

  public get pending(): number {
    return this.queue.length;
  }

  public get address(): AddressInfo | undefined {
    const address = this.server?.address();
    return address && typeof address !== "string" ? address : undefined;
  }

  private handle(request: IncomingMessage, reply: ServerResponse): void {
    const pathname = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    if (request.method !== "POST" || pathname !== "/event") {
      response(reply, 404);
      return;
    }

    const rawLength = request.headers["content-length"];
    const length = typeof rawLength === "string" && /^\d+$/.test(rawLength) ? Number(rawLength) : Number.NaN;
    if (!Number.isSafeInteger(length) || length < 0) {
      response(reply, 400);
      return;
    }
    if (length > this.maxBytes) {
      request.resume();
      response(reply, 413, true);
      return;
    }

    const chunks: Buffer[] = [];
    let received = 0;
    let completed = false;
    const requestTimer = setTimeout(() => {
      if (!completed) {
        completed = true;
        response(reply, 408, true);
      }
    }, this.requestTimeoutMs);
    const complete = (status?: number, close = false): void => {
      if (completed) {
        return;
      }
      completed = true;
      clearTimeout(requestTimer);
      if (status !== undefined) {
        response(reply, status, close);
      }
    };
    request.on("data", (chunk: Buffer) => {
      if (completed) {
        return;
      }
      received += chunk.length;
      if (received > this.maxBytes) {
        complete(413, true);
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.once("aborted", () => {
      complete();
    });
    reply.once("close", () => {
      if (!reply.writableEnded) {
        complete();
      }
    });
    request.once("error", () => {
      complete(400);
    });
    request.once("end", () => {
      if (completed) {
        return;
      }
      let payload: unknown;
      try {
        payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch {
        complete(400);
        return;
      }
      const event = sanitizeHookEvent(payload);
      if (!event) {
        complete(400);
        return;
      }
      if (this.queue.length >= this.maxQueue) {
        complete(503);
        return;
      }
      this.queue.push(event);
      this.emit("enqueued");
      complete(204);
    });
  }
}
