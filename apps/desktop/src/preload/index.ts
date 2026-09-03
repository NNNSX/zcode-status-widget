import { contextBridge, ipcRenderer } from "electron";
import type { AppConfig } from "../shared/config";
import type { AttentionContent, PanelSnapshot } from "../shared/protocol";
import type { HookSetupSnapshot } from "../shared/hook-setup";

export type RendererSurface = "panel" | "settings" | "attention";

type AppConfigInput = {
  readonly panelWidth?: number;
  readonly opacity?: number;
  readonly showIdle?: boolean;
  readonly showTodoProgress?: boolean;
  readonly showDuration?: boolean;
  readonly corner?: "bottom-right" | "bottom-left" | "top-right" | "top-left";
  readonly doneTtlMinutes?: number;
  readonly attentionMode?: "off" | "panel-pulse" | "corner-overlay" | "center-overlay";
  readonly attentionDurationMs?: number;
};

const getSurface = (): RendererSurface => {
  const value = new URLSearchParams(window.location.search).get("surface");
  if (value === "settings" || value === "attention" || value === "panel") {
    return value;
  }
  return "panel";
};

contextBridge.exposeInMainWorld("zcodeStatus", {
  getSurface,
  getPanelSnapshot: (): Promise<PanelSnapshot> => ipcRenderer.invoke("zcode-status:get-panel-snapshot"),
  getSettings: (): Promise<AppConfig> => ipcRenderer.invoke("zcode-status:get-settings"),
  onPanelSnapshot: (listener: (snapshot: PanelSnapshot) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, snapshot: PanelSnapshot): void => listener(snapshot);
    ipcRenderer.on("zcode-status:panel-snapshot", handler);
    return () => ipcRenderer.removeListener("zcode-status:panel-snapshot", handler);
  },
  onSettingsChanged: (listener: (config: AppConfig) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, config: AppConfig): void => listener(config);
    ipcRenderer.on("zcode-status:settings-changed", handler);
    return () => ipcRenderer.removeListener("zcode-status:settings-changed", handler);
  },
  getAttentionContent: (): Promise<AttentionContent> => ipcRenderer.invoke("zcode-status:get-attention-content"),
  onAttentionContent: (listener: (content: AttentionContent) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, content: AttentionContent): void => listener(content);
    ipcRenderer.on("zcode-status:attention-content", handler);
    return () => ipcRenderer.removeListener("zcode-status:attention-content", handler);
  },
  openSettings: (): Promise<void> => ipcRenderer.invoke("zcode-status:open-settings"),
  showAttention: (): Promise<void> => ipcRenderer.invoke("zcode-status:show-attention"),
  showPanel: (): Promise<void> => ipcRenderer.invoke("zcode-status:show-panel"),
  togglePanel: (): Promise<void> => ipcRenderer.invoke("zcode-status:toggle-panel"),
  resetPosition: (input?: AppConfigInput): Promise<AppConfig> => ipcRenderer.invoke("zcode-status:reset-position", input),
  closeSettings: (): Promise<void> => ipcRenderer.invoke("zcode-status:close-settings"),
  cancelSettings: (): Promise<AppConfig> => ipcRenderer.invoke("zcode-status:cancel-settings"),
  saveSettings: (input: AppConfigInput): Promise<AppConfig> => ipcRenderer.invoke("zcode-status:save-settings", input),
  previewSettings: (input: AppConfigInput): Promise<AppConfig> => ipcRenderer.invoke("zcode-status:preview-settings", input),
  getHookSetup: (): Promise<HookSetupSnapshot> => ipcRenderer.invoke("zcode-status:get-hook-setup"),
  chooseHookConfig: (): Promise<HookSetupSnapshot> => ipcRenderer.invoke("zcode-status:choose-hook-config"),
  configureHooks: (): Promise<HookSetupSnapshot> => ipcRenderer.invoke("zcode-status:configure-hooks"),
  unconfigureHooks: (): Promise<HookSetupSnapshot> => ipcRenderer.invoke("zcode-status:unconfigure-hooks"),
  quit: (): Promise<void> => ipcRenderer.invoke("zcode-status:quit"),
  beginSettingsDrag: (pointerX: number, pointerY: number): void => {
    ipcRenderer.send("zcode-status:settings-drag-start", pointerX, pointerY);
  },
  moveSettingsDrag: (pointerX: number, pointerY: number): void => {
    ipcRenderer.send("zcode-status:settings-drag-move", pointerX, pointerY);
  },
  endSettingsDrag: (): void => {
    ipcRenderer.send("zcode-status:settings-drag-end");
  },
});
