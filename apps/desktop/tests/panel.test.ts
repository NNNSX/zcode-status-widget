import { JSDOM } from "jsdom";
import { describe, expect, it } from "vitest";
import { renderSessionRow } from "../src/renderer/panel";
import type { DisplaySession } from "../src/shared/ui-model";

const session: DisplaySession = {
  id: "long-task",
  state: "working",
  workspace: "ZCode_ws",
  task: "非常长的任务摘要仍然不能影响固定 Todo 与时间列的可见性",
  todoProgress: "1/3",
  duration: "01:42",
};

describe("session row", () => {
  it("uses fixed right-side summary cells with a flexible task cell", () => {
    const dom = new JSDOM("<!doctype html><body></body>");
    const previousDocument = global.document;
    global.document = dom.window.document;
    try {
      const row = renderSessionRow(session);
      const cells = row.querySelectorAll(".task, .summary");
      expect(cells).toHaveLength(3);
      expect(row.querySelector(".task")?.textContent).toBe(session.task);
      expect(row.querySelector(".summary--todo")?.textContent).toBe("1/3");
      expect(row.querySelector(".summary--duration")?.textContent).toBe("01:42");
    } finally {
      global.document = previousDocument;
    }
  });
});
