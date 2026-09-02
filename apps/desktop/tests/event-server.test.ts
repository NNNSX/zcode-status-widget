import { once } from "node:events";
import { request as httpRequest } from "node:http";
import { describe, expect, it } from "vitest";
import { EventServer } from "../src/main/event-server";

const request = async (url: string, body: string | undefined, method = "POST"): Promise<Response> => fetch(url, {
  method,
  headers: body === undefined ? undefined : { "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) },
  body,
});

const incompleteRequest = (url: string): Promise<number> => new Promise((resolve, reject) => {
  const target = new URL(`${url}/event`);
  const client = httpRequest({
    hostname: target.hostname,
    port: target.port,
    path: target.pathname,
    method: "POST",
    headers: { "content-type": "application/json", "content-length": "32" },
  }, (reply) => {
    reply.resume();
    reply.once("end", () => resolve(reply.statusCode ?? 0));
  });
  client.once("error", reject);
  client.flushHeaders();
});

const abortIncompleteRequest = (url: string): Promise<void> => new Promise((resolve) => {
  const target = new URL(`${url}/event`);
  const client = httpRequest({
    hostname: target.hostname,
    port: target.port,
    path: target.pathname,
    method: "POST",
    headers: { "content-type": "application/json", "content-length": "32" },
  });
  client.once("error", () => undefined);
  client.once("close", () => resolve());
  client.flushHeaders();
  client.write("{\"event\":");
  client.destroy();
});

const withServer = async (callback: (server: EventServer, url: string) => Promise<void>, options: ConstructorParameters<typeof EventServer>[0] = {}): Promise<void> => {
  const server = new EventServer({ host: "127.0.0.1", port: 0, ...options });
  await server.start();
  const address = server.address;
  if (!address) {
    throw new Error("Event server did not bind");
  }
  try {
    await callback(server, `http://127.0.0.1:${address.port}`);
  } finally {
    await server.stop();
  }
};

describe("loopback event server", () => {
  it("accepts only valid event objects and drains FIFO batches", async () => {
    await withServer(async (server, url) => {
      const enqueued = once(server, "enqueued");
      const reply = await request(`${url}/event`, JSON.stringify({ event: "user_prompt_submit", session_id: "one" }));
      await enqueued;
      expect(reply.status).toBe(204);
      expect(server.pending).toBe(1);
      expect(server.drain()).toEqual([{ event: "user_prompt_submit", session_id: "one" }]);
      expect(server.pending).toBe(0);
    });
  });

  it("rejects unknown events and unsafe field sizes before they enter the queue", async () => {
    await withServer(async (server, url) => {
      expect((await request(`${url}/event`, JSON.stringify({ event: "unknown" }))).status).toBe(400);
      expect((await request(`${url}/event`, JSON.stringify({ event: "stop", prompt_preview: "x".repeat(513) }))).status).toBe(400);
      expect((await request(`${url}/event`, JSON.stringify({ event: "todo_update", todos: Array.from({ length: 65 }, () => ({ content: "x" })) }))).status).toBe(400);
      expect(server.pending).toBe(0);
    });
  });

  it("keeps the HTTP compatibility responses for invalid requests", async () => {
    await withServer(async (_server, url) => {
      expect((await request(`${url}/wrong`, "{}")).status).toBe(404);
      expect((await request(`${url}/event`, "not-json")).status).toBe(400);
      expect((await request(`${url}/event`, "[]")).status).toBe(400);
      expect((await request(`${url}/event`, undefined, "GET")).status).toBe(404);
    });
  });

  it("enforces request and queue limits without dropping queued events", async () => {
    await withServer(async (server, url) => {
      expect((await request(`${url}/event`, JSON.stringify({ event: "stop" }))).status).toBe(204);
      expect((await request(`${url}/event`, JSON.stringify({ event: "todo_update" }))).status).toBe(503);
      expect(server.drain()).toEqual([{ event: "stop" }]);

      const largePayload = JSON.stringify({ event: "x", detail: "a".repeat(257) });
      expect((await request(`${url}/event`, largePayload)).status).toBe(413);
    }, { maxBytes: 256, maxQueue: 1 });
  });

  it("times out incomplete request bodies without queueing them", async () => {
    await withServer(async (server, url) => {
      expect(await incompleteRequest(url)).toBe(408);
      expect(server.pending).toBe(0);
      expect((await request(`${url}/event`, JSON.stringify({ event: "todo_update" }))).status).toBe(204);
    }, { requestTimeoutMs: 100 });
  });

  it("ignores client-aborted request bodies and continues serving events", async () => {
    await withServer(async (server, url) => {
      await abortIncompleteRequest(url);
      expect(server.pending).toBe(0);
      expect((await request(`${url}/event`, JSON.stringify({ event: "stop" }))).status).toBe(204);
      expect(server.drain()).toEqual([{ event: "stop" }]);
    });
  });

  it("rejects a second listener on an occupied loopback port", async () => {
    const first = new EventServer({ host: "127.0.0.1", port: 0 });
    await first.start();
    const address = first.address;
    if (!address) {
      throw new Error("First event server did not bind");
    }
    const second = new EventServer({ host: "127.0.0.1", port: address.port });
    try {
      await expect(second.start()).rejects.toMatchObject({ code: "EADDRINUSE" });
      expect(second.address).toBeUndefined();
      expect(first.address?.port).toBe(address.port);
    } finally {
      await second.stop();
      await first.stop();
    }
  });
});
