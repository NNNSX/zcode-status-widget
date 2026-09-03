import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_CONFIG, type AppConfig } from "../src/shared/config";

const previousWindow = global.window;
const previousDocument = global.document;

afterEach(() => {
  global.window = previousWindow;
  global.document = previousDocument;
  vi.resetModules();
});

describe("settings renderer", () => {
  it("keeps the header close control semantic after Lucide replaces its child icon", async () => {
    const dom = new JSDOM("<!doctype html><body><main id=\"app\"></main></body>", { url: "http://localhost/?surface=settings" });
    const cancelSettings = vi.fn(async (): Promise<AppConfig> => DEFAULT_CONFIG);
    const saveSettings = vi.fn(async (input: Partial<AppConfig>): Promise<AppConfig> => ({ ...DEFAULT_CONFIG, ...input }));
    const previewSettings = vi.fn(async (input: Partial<AppConfig>): Promise<AppConfig> => ({ ...DEFAULT_CONFIG, ...input }));
    const configuredHookSetup = {
      configPath: "C:\\Users\\test\\.zcode\\cli\\config.json",
      databasePath: "C:\\Users\\test\\.zcode\\cli\\db\\db.sqlite",
      status: "configured" as const,
      message: "已配置 6 条本机状态 Hook。",
      isConfigured: true,
      requiresEnableConfirmation: false,
      ruleCount: 6,
    };
    const readyHookSetup = {
      configPath: "C:\\Users\\test\\.zcode\\cli\\config.json",
      databasePath: "C:\\Users\\test\\.zcode\\cli\\db\\db.sqlite",
      status: "ready" as const,
      message: "将添加 6 条仅发送到本机回环地址的状态 Hook。",
      isConfigured: false,
      requiresEnableConfirmation: false,
      ruleCount: 6,
    };
    const providerHookSetup = {
      configPath: "C:\\Users\\test\\.zcode\\v2\\config.json",
      databasePath: "C:\\Users\\test\\.zcode\\v2\\db\\db.sqlite",
      status: "invalid" as const,
      message: "所选文件是 ZCode provider 配置，不能写入 Hook。",
      isConfigured: false,
      requiresEnableConfirmation: false,
      ruleCount: 6,
    };
    const disabledHookSetup = {
      configPath: "C:\\Users\\test\\.zcode\\cli\\config.json",
      databasePath: "C:\\Users\\test\\.zcode\\cli\\db\\db.sqlite",
      status: "disabled" as const,
      message: "ZCode Hooks 已被明确关闭。",
      isConfigured: false,
      requiresEnableConfirmation: true,
      ruleCount: 6,
    };
    const getHookSetup = vi.fn()
      .mockResolvedValueOnce(providerHookSetup)
      .mockResolvedValueOnce(configuredHookSetup)
      .mockResolvedValueOnce(readyHookSetup);
    const chooseHookConfig = vi.fn(async () => disabledHookSetup);
    const configureHooks = vi.fn(async () => configuredHookSetup);
    const unconfigureHooks = vi.fn(async () => readyHookSetup);
    const beginSettingsDrag = vi.fn();
    const moveSettingsDrag = vi.fn();
    const endSettingsDrag = vi.fn();

    global.window = dom.window as unknown as Window & typeof globalThis;
    global.document = dom.window.document;
    Object.assign(dom.window, {
      zcodeStatus: {
        getSurface: () => "settings",
        getPanelSnapshot: async () => ({ sessions: [], showIdle: true }),
        getSettings: async () => DEFAULT_CONFIG,
        onPanelSnapshot: () => () => undefined,
        onSettingsChanged: () => () => undefined,
        getAttentionContent: async () => ({ sessionId: "test", kind: "waiting", title: "", workspace: "", summary: "" }),
        openSettings: async () => undefined,
        showAttention: async () => undefined,
        showPanel: async () => undefined,
        togglePanel: async () => undefined,
        resetPosition: async () => DEFAULT_CONFIG,
        closeSettings: async () => undefined,
        cancelSettings,
        saveSettings,
        previewSettings,
        getHookSetup,
        chooseHookConfig,
        configureHooks,
        unconfigureHooks,
        quit: async () => undefined,
        beginSettingsDrag,
        moveSettingsDrag,
        endSettingsDrag,
      },
    });

    try {
      await import("../src/renderer/main");
      await Promise.resolve();
      const close = dom.window.document.querySelector<HTMLButtonElement>("button[aria-label='关闭设置']");
      const header = dom.window.document.querySelector<HTMLElement>(".settings-header");
      const topDrag = dom.window.document.querySelector<HTMLElement>(".settings-top-drag");
      expect(close).not.toBeNull();
      expect(header).not.toBeNull();
      expect(topDrag).not.toBeNull();
      expect(close?.querySelector("svg")).not.toBeNull();
      topDrag?.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, button: 0, screenX: 100, screenY: 80 }));
      topDrag?.dispatchEvent(new dom.window.MouseEvent("pointermove", { bubbles: true, screenX: 116, screenY: 94 }));
      topDrag?.dispatchEvent(new dom.window.MouseEvent("pointerup", { bubbles: true, screenX: 116, screenY: 94 }));
      expect(beginSettingsDrag).toHaveBeenCalledWith(100, 80);
      expect(moveSettingsDrag).toHaveBeenCalledWith(116, 94);
      expect(endSettingsDrag).toHaveBeenCalledOnce();
      header?.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, button: 0, screenX: 300, screenY: 200 }));
      header?.dispatchEvent(new dom.window.MouseEvent("pointermove", { bubbles: true, screenX: 346, screenY: 242 }));
      header?.dispatchEvent(new dom.window.MouseEvent("pointerup", { bubbles: true, screenX: 346, screenY: 242 }));
      expect(beginSettingsDrag).toHaveBeenCalledWith(300, 200);
      expect(moveSettingsDrag).toHaveBeenCalledWith(346, 242);
      expect(endSettingsDrag).toHaveBeenCalledTimes(2);
      close?.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, button: 0, screenX: 300, screenY: 200 }));
      expect(beginSettingsDrag).toHaveBeenCalledTimes(2);
      close?.click();
      expect(cancelSettings).toHaveBeenCalledOnce();

      const opacity = dom.window.document.querySelector<HTMLInputElement>("#opacity-range");
      if (!opacity) {
        throw new Error("Opacity range is missing.");
      }
      opacity.value = "55";
      opacity.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
      await Promise.resolve();
      await Promise.resolve();
      dom.window.document.querySelector<HTMLButtonElement>("[data-action='save']")?.click();
      expect(saveSettings).toHaveBeenCalledWith(expect.objectContaining({ opacity: 55 }));

      expect(dom.window.document.querySelector("[aria-label='全局提醒方式']")).not.toBeNull();
      const settingsContent = dom.window.document.querySelector<HTMLElement>(".settings-content");
      const settingsActions = dom.window.document.querySelector<HTMLElement>(".settings-actions");
      expect(settingsContent).not.toBeNull();
      expect(settingsContent?.querySelectorAll(".settings-section")).toHaveLength(5);
      expect(settingsActions?.parentElement).toBe(dom.window.document.querySelector("#app"));
      expect(settingsActions?.parentElement).not.toBe(settingsContent);
      expect(settingsActions?.querySelector("[data-action='save']")).not.toBeNull();
      expect(dom.window.document.querySelector("#attention-duration-output")?.textContent).toContain("1800 毫秒");
      const duration = dom.window.document.querySelector<HTMLInputElement>("#attention-duration-range");
      if (!duration) {
        throw new Error("Attention duration range is missing.");
      }
      expect(dom.window.document.querySelector("[data-attention='panel-pulse']")?.textContent).toBe("边缘");
      duration.value = "3200";
      duration.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
      dom.window.document.querySelector<HTMLButtonElement>("[data-attention='panel-pulse']")?.click();
      await Promise.resolve();
      expect(previewSettings).toHaveBeenCalledWith({ attentionMode: "panel-pulse" });
      dom.window.document.querySelector<HTMLButtonElement>("[data-attention='corner-overlay']")?.click();
      await Promise.resolve();
      await Promise.resolve();
      expect(previewSettings).toHaveBeenCalledWith({ attentionDurationMs: 3200 });
      expect(previewSettings).toHaveBeenCalledWith({ attentionMode: "corner-overlay" });

      await Promise.resolve();
      expect(getHookSetup).toHaveBeenCalledOnce();
      const configureHooksButton = dom.window.document.querySelector<HTMLButtonElement>("[data-action='configure-hooks']");
      const unconfigureHooksButton = dom.window.document.querySelector<HTMLButtonElement>("[data-action='unconfigure-hooks']");
      const chooseHookConfigButton = dom.window.document.querySelector<HTMLButtonElement>("[data-action='choose-hook-config']");
      expect(dom.window.document.querySelector("#hook-setup-status")?.textContent).toContain("provider 配置");
      expect(configureHooksButton?.disabled).toBe(true);
      expect(chooseHookConfigButton?.textContent).toContain("Hook config.json");
      chooseHookConfigButton?.click();
      await Promise.resolve();
      await Promise.resolve();
      expect(configureHooksButton?.textContent).toContain("确认启用");
      expect(unconfigureHooksButton?.disabled).toBe(true);
      configureHooksButton?.click();
      await Promise.resolve();
      await Promise.resolve();
      expect(configureHooks).toHaveBeenCalledWith();
      expect(unconfigureHooksButton?.disabled).toBe(false);
      unconfigureHooksButton?.click();
      await Promise.resolve();
      await Promise.resolve();
      expect(unconfigureHooks).toHaveBeenCalledWith();
      expect(unconfigureHooksButton?.disabled).toBe(true);
      expect(configureHooksButton?.disabled).toBe(false);
    } finally {
      dom.window.close();
    }
  });
});
