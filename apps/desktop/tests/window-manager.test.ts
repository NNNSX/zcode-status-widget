import { describe, expect, it, vi } from "vitest";
import { DEFAULT_CONFIG } from "../src/shared/config";

type Listener = (...args: unknown[]) => void;

class FakeWindow {
  public static instances: FakeWindow[] = [];
  public static nextWebContentsId = 1;

  public readonly webContents = {
    id: FakeWindow.nextWebContentsId++,
    getURL: vi.fn(() => ""),
    on: vi.fn(),
    send: vi.fn(),
    setWindowOpenHandler: vi.fn(),
  };

  public readonly setIgnoreMouseEvents = vi.fn();
  public readonly setAlwaysOnTop = vi.fn();
  public readonly showInactive = vi.fn(() => { this.visible = true; });
  public readonly moveTop = vi.fn();
  public readonly focus = vi.fn();
  public readonly setBounds = vi.fn((bounds) => { this.bounds = { ...bounds }; });
  public readonly setPosition = vi.fn((x: number, y: number) => { this.bounds = { ...this.bounds, x, y }; });
  public readonly getBounds = vi.fn(() => ({ ...this.bounds }));
  public readonly setOpacity = vi.fn();
  public readonly hide = vi.fn(() => { this.visible = false; });
  public readonly isVisible = vi.fn(() => this.visible);
  public readonly isDestroyed = vi.fn(() => this.destroyed);
  public readonly close = vi.fn(() => { this.destroyed = true; this.emit("closed"); });
  public readonly destroy = vi.fn(() => { this.destroyed = true; this.emit("closed"); });
  public readonly loadURL = vi.fn(async () => undefined);
  public readonly on = vi.fn((event: string, listener: Listener) => {
    this.listeners.set(event, listener);
    return this;
  });
  public readonly once = vi.fn((event: string, listener: Listener) => {
    this.listeners.set(event, listener);
    return this;
  });

  private bounds = { x: 0, y: 0, width: 520, height: 47 };
  private visible = false;
  private destroyed = false;
  private readonly listeners = new Map<string, Listener>();

  public constructor(options: { x?: number; y?: number; width: number; height: number }) {
    this.bounds = {
      x: options.x ?? 0,
      y: options.y ?? 0,
      width: options.width,
      height: options.height,
    };
    FakeWindow.instances.push(this);
  }

  public emit(event: string, ...args: unknown[]): void {
    this.listeners.get(event)?.(...args);
  }
}

const displays = {
  primary: {
    id: 1,
    bounds: { x: 0, y: 0, width: 1920, height: 1080 },
    workArea: { x: 0, y: 0, width: 1920, height: 1080 },
  },
  secondary: {
    id: 2,
    bounds: { x: -1600, y: 0, width: 1600, height: 900 },
    workArea: { x: -1600, y: 0, width: 1600, height: 860 },
  },
};
const screenListeners = new Map<string, Listener>();
let availableDisplays = [displays.primary];
const emitScreen = (event: string, ...args: unknown[]): void => {
  screenListeners.get(event)?.(...args);
};
const resetScreen = (): void => {
  displays.primary.workArea = { x: 0, y: 0, width: 1920, height: 1080 };
  displays.secondary.workArea = { x: -1600, y: 0, width: 1600, height: 860 };
  availableDisplays = [displays.primary];
  screenListeners.clear();
};

vi.mock("electron", () => ({
  BrowserWindow: FakeWindow,
  screen: {
    getAllDisplays: () => availableDisplays,
    getDisplayNearestPoint: (point: { x: number; y: number }) => {
      const containing = availableDisplays.find((display) => (
        point.x >= display.bounds.x
        && point.x < display.bounds.x + display.bounds.width
        && point.y >= display.bounds.y
        && point.y < display.bounds.y + display.bounds.height
      ));
      return containing ?? availableDisplays[0] ?? displays.primary;
    },
    getDisplayMatching: () => availableDisplays[0] ?? displays.primary,
    getPrimaryDisplay: () => displays.primary,
    on: vi.fn((event: string, listener: Listener) => {
      screenListeners.set(event, listener);
    }),
    off: vi.fn((event: string, listener: Listener) => {
      if (screenListeners.get(event) === listener) {
        screenListeners.delete(event);
      }
    }),
  },
}));

describe("WindowManager", () => {
  it("ignores system moves but persists a completed manual drag", async () => {
    vi.useFakeTimers();
    try {
      resetScreen();
      availableDisplays = [displays.primary, displays.secondary];
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();
      const onPositionChanged = vi.fn();
      manager.setPanelPositionListener(onPositionChanged);
      await manager.createPanel(DEFAULT_CONFIG);
      const panel = FakeWindow.instances[0];
      if (!panel) {
        throw new Error("Panel window was not created.");
      }

      panel.setBounds({ x: 1500, y: 900, width: 380, height: 47 });
      panel.emit("move");
      vi.advanceTimersByTime(220);
      expect(onPositionChanged).not.toHaveBeenCalled();

      panel.emit("will-move", {}, { x: -1500, y: 120, width: 380, height: 47 });
      panel.setBounds({ x: -1500, y: 120, width: 380, height: 47 });
      panel.emit("move");
      vi.advanceTimersByTime(220);
      expect(onPositionChanged).toHaveBeenCalledOnce();
      expect(onPositionChanged).toHaveBeenCalledWith({
        corner: "top-left",
        marginX: 100,
        marginY: 120,
        displayId: "2",
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("reanchors after display metrics changes without persisting temporary system coordinates", async () => {
    vi.useFakeTimers();
    try {
      resetScreen();
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();
      const onPositionChanged = vi.fn();
      manager.setPanelPositionListener(onPositionChanged);
      const config = { ...DEFAULT_CONFIG, panelWidth: 380, marginX: 14, marginY: 52 };
      await manager.createPanel(config);
      const panel = FakeWindow.instances[0];
      if (!panel) {
        throw new Error("Panel window was not created.");
      }
      panel.setBounds.mockClear();
      displays.primary.workArea = { x: 0, y: 0, width: 1280, height: 720 };
      panel.setBounds({ x: 900, y: 620, width: 380, height: 47 });
      panel.emit("move");
      emitScreen("display-metrics-changed", {}, displays.primary, ["workArea"]);
      emitScreen("display-metrics-changed", {}, displays.primary, ["bounds"]);
      vi.advanceTimersByTime(100);

      expect(panel.setBounds).toHaveBeenCalledWith({ x: 886, y: 621, width: 380, height: 47 });
      expect(onPositionChanged).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
      resetScreen();
    }
  });

  it("falls back to the primary display after a display is removed without saving a replacement position", async () => {
    vi.useFakeTimers();
    try {
      resetScreen();
      availableDisplays = [displays.primary, displays.secondary];
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();
      const onPositionChanged = vi.fn();
      manager.setPanelPositionListener(onPositionChanged);
      const config = { ...DEFAULT_CONFIG, displayId: "2", panelWidth: 380, marginX: 14, marginY: 52 };
      await manager.createPanel(config);
      const panel = FakeWindow.instances[0];
      if (!panel) {
        throw new Error("Panel window was not created.");
      }
      panel.setBounds.mockClear();
      availableDisplays = [displays.primary];
      emitScreen("display-removed", {}, displays.secondary);
      vi.advanceTimersByTime(100);

      expect(panel.setBounds).toHaveBeenCalledWith({ x: 1526, y: 981, width: 380, height: 47 });
      expect(onPositionChanged).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
      resetScreen();
    }
  });

  it("restores the panel above ordinary windows without focusing it", async () => {
    FakeWindow.instances.splice(0);
    const { WindowManager } = await import("../src/main/window-manager");
    const manager = new WindowManager();

    await manager.createPanel(DEFAULT_CONFIG);
    const panel = FakeWindow.instances[0];
    if (!panel) {
      throw new Error("Panel window was not created.");
    }

    panel.setAlwaysOnTop.mockClear();
    panel.showInactive.mockClear();
    panel.moveTop.mockClear();
    panel.focus.mockClear();
    panel.hide();
    manager.applyConfig(DEFAULT_CONFIG);

    expect(panel.setAlwaysOnTop).toHaveBeenCalledWith(true, "floating");
    expect(panel.showInactive).toHaveBeenCalledOnce();
    expect(panel.moveTop).toHaveBeenCalledOnce();
    expect(panel.focus).not.toHaveBeenCalled();
  });

  it("shows edge attention across the display containing the panel without focusing it", async () => {
    resetScreen();
    availableDisplays = [displays.primary, displays.secondary];
    FakeWindow.instances.splice(0);
    const { WindowManager } = await import("../src/main/window-manager");
    const manager = new WindowManager();

    await manager.createPanel(DEFAULT_CONFIG);
    const panel = FakeWindow.instances[0];
    if (!panel) {
      throw new Error("Panel window was not created.");
    }
    panel.setBounds({ x: -900, y: 500, width: 380, height: 47 });

    await manager.showAttention({
      sessionId: "edge-session",
      kind: "waiting",
      title: "请完成审批",
      workspace: "ZCode",
      summary: "",
    }, 800, "edge");

    const attention = FakeWindow.instances[1];
    if (!attention) {
      throw new Error("Attention window was not created.");
    }
    expect(attention.getBounds()).toEqual({ x: -1600, y: 0, width: 1600, height: 900 });
    expect(attention.showInactive).toHaveBeenCalledOnce();
    expect(attention.setAlwaysOnTop).toHaveBeenCalledWith(true, "pop-up-menu");
    expect(attention.moveTop).toHaveBeenCalled();
    expect(attention.setIgnoreMouseEvents).toHaveBeenCalledWith(true, { forward: true });
    expect(attention.focus).not.toHaveBeenCalled();
    expect(attention.loadURL).toHaveBeenCalledWith(expect.stringContaining("surface=attention&presentation=edge"));
  });

  it("moves settings from trusted header drag messages only", async () => {
    resetScreen();
    availableDisplays = [displays.primary, displays.secondary];
    FakeWindow.instances.splice(0);
    const { WindowManager } = await import("../src/main/window-manager");
    const manager = new WindowManager();
    await manager.createPanel(DEFAULT_CONFIG);
    await manager.openSettings();
    const settings = FakeWindow.instances[1];
    const panel = FakeWindow.instances[0];
    if (!settings || !panel) {
      throw new Error("Settings and panel windows were not created.");
    }

    const initial = settings.getBounds();
    manager.beginSettingsDrag(settings.webContents.id, 300, 200);
    manager.moveSettingsDrag(settings.webContents.id, 344, 238);
    expect(settings.setPosition).toHaveBeenCalledWith(1564, initial.y + 38);

    manager.endSettingsDrag(settings.webContents.id);
    manager.moveSettingsDrag(settings.webContents.id, 390, 260);
    expect(settings.setPosition).toHaveBeenCalledTimes(1);

    manager.beginSettingsDrag(panel.webContents.id, 100, 100);
    manager.moveSettingsDrag(panel.webContents.id, 160, 160);
    expect(settings.setPosition).toHaveBeenCalledTimes(1);
  });

  it("opens settings on the panel display and reclamps it after display changes", async () => {
    vi.useFakeTimers();
    try {
      resetScreen();
      availableDisplays = [displays.primary, displays.secondary];
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();
      await manager.createPanel(DEFAULT_CONFIG);
      const panel = FakeWindow.instances[0];
      if (!panel) {
        throw new Error("Panel window was not created.");
      }
      panel.setBounds({ x: -900, y: 500, width: 380, height: 47 });
      await manager.openSettings();
      const settings = FakeWindow.instances[1];
      if (!settings) {
        throw new Error("Settings window was not created.");
      }
      expect(settings.getBounds()).toEqual({ x: -372, y: 16, width: 356, height: 760 });

      displays.secondary.workArea = { x: -1200, y: 0, width: 1200, height: 600 };
      emitScreen("display-metrics-changed", {}, displays.secondary, ["workArea"]);
      vi.advanceTimersByTime(100);
      expect(settings.getBounds()).toEqual({ x: -372, y: 16, width: 356, height: 568 });
    } finally {
      vi.useRealTimers();
      resetScreen();
    }
  });

  it("repositions active edge attention after a display layout change", async () => {
    vi.useFakeTimers();
    try {
      resetScreen();
      availableDisplays = [displays.primary, displays.secondary];
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();
      await manager.createPanel(DEFAULT_CONFIG);
      const panel = FakeWindow.instances[0];
      if (!panel) {
        throw new Error("Panel window was not created.");
      }
      panel.setBounds({ x: -900, y: 500, width: 380, height: 47 });
      await manager.showAttention({
        sessionId: "display-session",
        kind: "waiting",
        title: "请完成审批",
        workspace: "ZCode",
        summary: "",
      }, 800, "edge");
      const attention = FakeWindow.instances[1];
      if (!attention) {
        throw new Error("Attention window was not created.");
      }
      displays.secondary.bounds = { x: -1400, y: 0, width: 1400, height: 900 };
      emitScreen("display-metrics-changed", {}, displays.secondary, ["bounds"]);
      vi.advanceTimersByTime(100);
      expect(attention.getBounds()).toEqual({ x: -1400, y: 0, width: 1400, height: 900 });
    } finally {
      vi.useRealTimers();
      resetScreen();
    }
  });

  it("only closes attention for its owning session", async () => {
    FakeWindow.instances.splice(0);
    const { WindowManager } = await import("../src/main/window-manager");
    const manager = new WindowManager();
    await manager.showAttention({
      sessionId: "current-session",
      kind: "waiting",
      title: "请完成审批",
      workspace: "ZCode",
      summary: "",
    }, 800, "edge");
    const attention = FakeWindow.instances[0];
    if (!attention) {
      throw new Error("Attention window was not created.");
    }

    manager.closeAttention("other-session");
    expect(attention.close).not.toHaveBeenCalled();
    manager.closeAttention("current-session");
    expect(attention.close).toHaveBeenCalledOnce();
  });

  it("reasserts an active attention window and refreshes repeated content without recreating it", async () => {
    vi.useFakeTimers();
    try {
      resetScreen();
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();
      await manager.showAttention({
        sessionId: "repeat-session",
        kind: "waiting",
        title: "请完成审批",
        workspace: "ZCode",
        summary: "",
      }, 800, "center");
      const attention = FakeWindow.instances[0];
      if (!attention) {
        throw new Error("Attention window was not created.");
      }
      const initialRaises = attention.setAlwaysOnTop.mock.calls.length;
      vi.advanceTimersByTime(250);
      expect(attention.setAlwaysOnTop.mock.calls.length).toBeGreaterThan(initialRaises);

      await manager.showAttention({
        sessionId: "repeat-session",
        kind: "waiting",
        title: "请完成审批",
        workspace: "ZCode",
        summary: "1/2",
      }, 800, "center");
      expect(FakeWindow.instances).toHaveLength(1);
      vi.advanceTimersByTime(799);
      expect(attention.close).not.toHaveBeenCalled();
      vi.advanceTimersByTime(1);
      expect(attention.close).toHaveBeenCalledOnce();
    } finally {
      vi.useRealTimers();
      resetScreen();
    }
  });
  it("replaces an active edge reminder and only lets its latest timer close the layer", async () => {
    vi.useFakeTimers();
    try {
      FakeWindow.instances.splice(0);
      const { WindowManager } = await import("../src/main/window-manager");
      const manager = new WindowManager();

      await manager.showAttention({
        sessionId: "first-session",
        kind: "waiting",
        title: "请完成审批",
        workspace: "ZCode",
        summary: "",
      }, 800, "edge");
      const first = FakeWindow.instances[0];
      if (!first) {
        throw new Error("First attention window was not created.");
      }

      await manager.showAttention({
        sessionId: "second-session",
        kind: "done",
        title: "本轮任务完成",
        workspace: "ZCode",
        summary: "12 秒",
      }, 800, "edge");
      const second = FakeWindow.instances[1];
      if (!second) {
        throw new Error("Second attention window was not created.");
      }

      expect(first.close).toHaveBeenCalledOnce();
      vi.advanceTimersByTime(800);
      expect(second.close).toHaveBeenCalledOnce();
    } finally {
      vi.useRealTimers();
    }
  });
});