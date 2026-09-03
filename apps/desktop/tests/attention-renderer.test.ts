import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AttentionContent } from "../src/shared/protocol";

const previousWindow = global.window;
const previousDocument = global.document;

const attention = (content: AttentionContent, presentation: "card" | "edge" = "card"): { emitContent: (next: AttentionContent) => void } => {
  const dom = new JSDOM("<!doctype html><body><main id=\"app\"></main></body>", {
    url: `http://localhost/?surface=attention&presentation=${presentation}`,
  });
  global.window = dom.window as unknown as Window & typeof globalThis;
  global.document = dom.window.document;
  let emitContent: (next: AttentionContent) => void = () => undefined;
  Object.assign(dom.window, {
    zcodeStatus: {
      getSurface: () => "attention",
      getPanelSnapshot: async () => ({ sessions: [], showIdle: true }),
      getSettings: async () => undefined,
      onPanelSnapshot: () => () => undefined,
      onSettingsChanged: () => () => undefined,
      getAttentionContent: async () => content,
      onAttentionContent: (listener: (next: AttentionContent) => void) => {
        emitContent = listener;
        return () => { emitContent = () => undefined; };
      },
      openSettings: async () => undefined,
      showAttention: async () => undefined,
      showPanel: async () => undefined,
      togglePanel: async () => undefined,
      resetPosition: async () => undefined,
      closeSettings: async () => undefined,
      cancelSettings: async () => undefined,
      saveSettings: async () => undefined,
      previewSettings: async () => undefined,
      getHookSetup: async () => undefined,
      chooseHookConfig: async () => undefined,
      configureHooks: async () => undefined,
      quit: async () => undefined,
    },
  });
  return { emitContent: (next) => emitContent(next) };
};

afterEach(() => {
  global.window = previousWindow;
  global.document = previousDocument;
  vi.resetModules();
});

describe("attention renderer", () => {
  it("keeps the waiting icon inside its semantic mark and preserves the summary", async () => {
    attention({
      sessionId: "waiting-session",
      kind: "waiting",
      title: "请完成审批",
      workspace: "ZCode 工作区",
      summary: "2/3 Todo",
    });

    await import("../src/renderer/main");
    await Promise.resolve();

    const root = document.querySelector<HTMLElement>("#app");
    const mark = root?.querySelector<HTMLElement>(".attention-mark");
    expect(root?.dataset.kind).toBe("waiting");
    expect(mark?.tagName).toBe("DIV");
    expect(mark?.querySelector("svg.lucide-bell-ring")).not.toBeNull();
    expect(root?.querySelector(".attention-copy")?.textContent).toContain("等待用户操作");
    expect(root?.querySelector(".attention-title")?.textContent).toBe("请完成审批");
    expect(root?.querySelector(".attention-workspace")?.textContent).toBe("ZCode 工作区");
    expect(root?.querySelector(".attention-summary")?.textContent).toBe("2/3 Todo");
  });

  it("renders an edge-only status layer for waiting without card content", async () => {
    attention({
      sessionId: "edge-session",
      kind: "waiting",
      title: "请完成审批",
      workspace: "ZCode 工作区",
      summary: "2/3 Todo",
    }, "edge");

    await import("../src/renderer/main");
    await Promise.resolve();

    const root = document.querySelector<HTMLElement>("#app");
    const live = root?.querySelector<HTMLElement>(".attention-live");
    expect(root?.classList.contains("surface--attention-edge")).toBe(true);
    expect(root?.dataset.kind).toBe("waiting");
    expect(root?.querySelectorAll(".attention-edge")).toHaveLength(4);
    expect(live?.getAttribute("role")).toBe("status");
    expect(live?.getAttribute("aria-live")).toBe("polite");
    expect(live?.textContent).toBe("等待用户操作：请完成审批");
    expect(root?.querySelector(".attention-copy")).toBeNull();
    expect(root?.querySelector(".attention-mark")).toBeNull();
  });

  it("uses completed semantics for an edge-only status layer", async () => {
    attention({
      sessionId: "edge-done-session",
      kind: "done",
      title: "本轮任务完成",
      workspace: "ZCode 工作区",
      summary: "12 秒",
    }, "edge");

    await import("../src/renderer/main");
    await Promise.resolve();

    const root = document.querySelector<HTMLElement>("#app");
    expect(root?.classList.contains("surface--attention-edge")).toBe(true);
    expect(root?.dataset.kind).toBe("done");
    expect(root?.querySelector(".attention-live")?.textContent).toBe("任务已完成：本轮任务完成");
  });
  it("updates card content when the main process publishes a repeated reminder", async () => {
    const bridge = attention({
      sessionId: "repeat-session",
      kind: "waiting",
      title: "第一次审批",
      workspace: "旧工作区",
      summary: "1/2",
    });

    await import("../src/renderer/main");
    await Promise.resolve();
    bridge.emitContent({
      sessionId: "repeat-session",
      kind: "waiting",
      title: "第二次审批",
      workspace: "新工作区",
      summary: "2/3",
    });

    expect(document.querySelector(".attention-title")?.textContent).toBe("第二次审批");
    expect(document.querySelector(".attention-workspace")?.textContent).toBe("新工作区");
    expect(document.querySelector(".attention-summary")?.textContent).toBe("2/3");
  });

  it("uses the done icon and omits the separator when no summary is available", async () => {
    attention({
      sessionId: "done-session",
      kind: "done",
      title: "本轮任务完成",
      workspace: "一个很长且没有自然断点的工作区名称".repeat(20),
      summary: "",
    });

    await import("../src/renderer/main");
    await Promise.resolve();

    const root = document.querySelector<HTMLElement>("#app");
    const mark = root?.querySelector<HTMLElement>(".attention-mark");
    expect(root?.dataset.kind).toBe("done");
    expect(mark?.tagName).toBe("DIV");
    expect(mark?.querySelector("svg.lucide-circle-check")).not.toBeNull();
    expect(root?.querySelector(".attention-copy")?.textContent).toContain("任务已完成");
    expect(root?.querySelector(".attention-workspace")?.textContent).toContain("一个很长且没有自然断点的工作区名称");
    expect(root?.querySelector(".attention-separator")).toBeNull();
    expect(root?.querySelector(".attention-summary")).toBeNull();
  });
});
