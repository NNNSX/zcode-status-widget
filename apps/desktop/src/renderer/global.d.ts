export {};

import type { AppConfig } from "../shared/config";
import type { AttentionContent, PanelSnapshot } from "../shared/protocol";
import type { HookSetupSnapshot } from "../shared/hook-setup";

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

declare global {
  interface Window {
    zcodeStatus: {
      getSurface(): "panel" | "settings" | "attention";
      getPanelSnapshot(): Promise<PanelSnapshot>;
      getSettings(): Promise<AppConfig>;
      onPanelSnapshot(listener: (snapshot: PanelSnapshot) => void): () => void;
      onSettingsChanged(listener: (config: AppConfig) => void): () => void;
      getAttentionContent(): Promise<AttentionContent>;
      openSettings(): Promise<void>;
      showAttention(): Promise<void>;
      showPanel(): Promise<void>;
      togglePanel(): Promise<void>;
      resetPosition(input?: AppConfigInput): Promise<AppConfig>;
      closeSettings(): Promise<void>;
      cancelSettings(): Promise<AppConfig>;
      saveSettings(input: AppConfigInput): Promise<AppConfig>;
      previewSettings(input: AppConfigInput): Promise<AppConfig>;
      getHookSetup(): Promise<HookSetupSnapshot>;
      chooseHookConfig(): Promise<HookSetupSnapshot>;
      configureHooks(): Promise<HookSetupSnapshot>;
      unconfigureHooks(): Promise<HookSetupSnapshot>;
      quit(): Promise<void>;
      beginSettingsDrag(pointerX: number, pointerY: number): void;
      moveSettingsDrag(pointerX: number, pointerY: number): void;
      endSettingsDrag(): void;
    };
  }
}
