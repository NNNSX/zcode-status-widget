import path from "node:path";
import { pathToFileURL } from "node:url";
import { BrowserWindow, screen } from "electron";
import type { AppConfig, PanelCorner } from "../shared/config";
import { DEFAULT_CONFIG } from "../shared/config";
import type { AttentionContent, PanelSnapshot } from "../shared/protocol";
import {
  ATTENTION_BOUNDS,
  attentionOrigin,
  attentionWindowContract,
  clampOrigin,
  clampPanelWidth,
  PANEL_BOUNDS,
  panelHeightForRows,
  placementForBounds,
  panelWindowContract,
  rendererUrl,
  settingsBoundsForWorkArea,
  settingsWindowContract,
  shouldShowPanel,
  type AttentionPresentation,
  type PanelVisibilityOverride,
  type RendererSurface,
} from "./window-contract";

const preloadPath = path.join(__dirname, "..", "preload", "index.js");
const productionRendererPath = path.join(__dirname, "..", "..", "dist", "renderer", "index.html");
const DISPLAY_LAYOUT_SETTLE_MS = 100;

const defaultAttention: AttentionContent = {
  sessionId: "demo",
  kind: "waiting",
  title: "请完成审批",
  workspace: "ZCode",
  summary: "",
};

export interface PanelPosition {
  readonly corner: PanelCorner;
  readonly marginX: number;
  readonly marginY: number;
  readonly displayId: string;
}

const preventExternalNavigation = (window: BrowserWindow): void => {
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event, url) => {
    if (url !== window.webContents.getURL()) {
      event.preventDefault();
    }
  });
};

export class WindowManager {
  private panel: BrowserWindow | undefined;
  private settings: BrowserWindow | undefined;
  private attention: BrowserWindow | undefined;
  private latestSnapshot: PanelSnapshot = { sessions: [], showIdle: true };
  private attentionContent: AttentionContent = defaultAttention;
  private panelVisibilityOverride: PanelVisibilityOverride;
  private panelMoveTimer: NodeJS.Timeout | undefined;
  private displayLayoutTimer: NodeJS.Timeout | undefined;
  private userPanelMovePending = false;
  private userPanelMoveActive = false;
  private lastAppliedConfig: AppConfig | undefined;
  private lastAppliedPanelBounds: ReturnType<BrowserWindow["getBounds"]> | undefined;
  private readonly onDisplayLayoutChange = (): void => this.handleDisplayLayoutChange();
  private onPanelPositionChanged: ((position: PanelPosition) => void) | undefined;
  private onSettingsClosed: (() => void) | undefined;
  private attentionTimer: NodeJS.Timeout | undefined;
  private attentionGeneration = 0;
  private attentionSessionId: string | undefined;
  private attentionPlacement: "center" | "corner" | "edge" | undefined;
  private settingsDrag: {
    readonly webContentsId: number;
    readonly pointerX: number;
    readonly pointerY: number;
    readonly windowX: number;
    readonly windowY: number;
  } | undefined;

  public async createPanel(config?: AppConfig): Promise<void> {
    if (this.panel && !this.panel.isDestroyed()) {
      if (config) {
        this.applyConfig(config);
      }
      return;
    }

    const display = screen.getPrimaryDisplay();
    const { workArea } = display;
    const window = new BrowserWindow({
      ...panelWindowContract,
      x: workArea.x + workArea.width - PANEL_BOUNDS.width - 18,
      y: workArea.y + workArea.height - PANEL_BOUNDS.height - 54,
      show: false,
      resizable: false,
      hasShadow: true,
      backgroundColor: "#00000000",
      webPreferences: {
        preload: preloadPath,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        webSecurity: true,
      },
    });

    preventExternalNavigation(window);
    window.setAlwaysOnTop(true, "floating");
    this.lastAppliedPanelBounds = window.getBounds();
    window.on("will-move", () => this.beginUserPanelMove(window));
    window.on("move", () => this.handlePanelMove(window));
    window.on("closed", () => {
      if (this.panel !== window) {
        return;
      }
      this.clearPanelMoveTimer();
      this.clearDisplayLayoutTimer();
      this.unsubscribeFromDisplayLayoutChanges();
      this.userPanelMoveActive = false;
      this.userPanelMovePending = false;
      this.panel = undefined;
    });
    this.subscribeToDisplayLayoutChanges();
    this.panel = window;
    try {
      await this.loadSurface(window, "panel");
      this.publishSnapshot(this.latestSnapshot);
      this.applyConfig(config ?? this.lastAppliedConfig ?? DEFAULT_CONFIG);
    } catch (error) {
      this.cleanupFailedPanel(window);
      throw error;
    }
  }

  public setPanelPositionListener(listener: (position: PanelPosition) => void): void {
    this.onPanelPositionChanged = listener;
  }

  public setSettingsClosedListener(listener: () => void): void {
    this.onSettingsClosed = listener;
  }

  public async openSettings(): Promise<void> {
    if (this.settings && !this.settings.isDestroyed()) {
      this.settings.show();
      this.settings.focus();
      return;
    }

    const parent = this.panel && !this.panel.isDestroyed() ? this.panel : undefined;
    const display = parent ? screen.getDisplayMatching(parent.getBounds()) : screen.getPrimaryDisplay();
    const bounds = settingsBoundsForWorkArea(display.workArea);
    const window = new BrowserWindow({
      ...settingsWindowContract,
      ...bounds,
      parent,
      modal: false,
      show: false,
      resizable: false,
      hasShadow: true,
      backgroundColor: "#00000000",
      webPreferences: {
        preload: preloadPath,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        webSecurity: true,
      },
    });

    preventExternalNavigation(window);
    window.setAlwaysOnTop(true, "floating");
    window.on("closed", () => {
      if (this.settings === window) {
        this.settings = undefined;
        this.settingsDrag = undefined;
        this.onSettingsClosed?.();
      }
    });
    window.once("ready-to-show", () => {
      if (this.settings === window && !window.isDestroyed()) {
        window.show();
        window.focus();
      }
    });
    this.settings = window;
    try {
      await this.loadSurface(window, "settings");
    } catch (error) {
      this.cleanupFailedSettings(window);
      throw error;
    }
  }

  public closeSettings(): void {
    if (this.settings && !this.settings.isDestroyed()) {
      this.settings.close();
    }
  }

  public beginSettingsDrag(webContentsId: number, pointerX: number, pointerY: number): void {
    const window = this.settings;
    if (!window || window.isDestroyed() || window.webContents.id !== webContentsId) {
      return;
    }
    const bounds = window.getBounds();
    this.settingsDrag = {
      webContentsId,
      pointerX,
      pointerY,
      windowX: bounds.x,
      windowY: bounds.y,
    };
  }

  public moveSettingsDrag(webContentsId: number, pointerX: number, pointerY: number): void {
    const drag = this.settingsDrag;
    const window = this.settings;
    if (!drag || drag.webContentsId !== webContentsId || !window || window.isDestroyed() || window.webContents.id !== webContentsId) {
      return;
    }
    window.setPosition(
      Math.round(drag.windowX + pointerX - drag.pointerX),
      Math.round(drag.windowY + pointerY - drag.pointerY),
    );
  }

  public endSettingsDrag(webContentsId: number): void {
    if (this.settingsDrag?.webContentsId === webContentsId) {
      this.settingsDrag = undefined;
    }
  }

  public showPanel(config: AppConfig): void {
    this.panelVisibilityOverride = "visible";
    this.applyConfig(config);
    this.sendToSurface(this.panel, "zcode-status:panel-snapshot", this.panelSnapshot());
  }

  public togglePanel(config: AppConfig): void {
    if (this.panel && !this.panel.isDestroyed() && this.panel.isVisible()) {
      this.panelVisibilityOverride = "hidden";
      this.applyConfig(config);
      return;
    }
    this.showPanel(config);
  }

  public publishSettings(config: AppConfig): void {
    this.sendToSurface(this.settings, "zcode-status:settings-changed", config);
  }

  public getAttentionContent(): AttentionContent {
    return this.attentionContent;
  }

  public publishSnapshot(snapshot: PanelSnapshot): void {
    const hadSessions = this.latestSnapshot.sessions.length > 0;
    const hasSessions = snapshot.sessions.length > 0;
    if ((!hadSessions && hasSessions) || (hadSessions && !hasSessions && this.panelVisibilityOverride === "visible")) {
      this.panelVisibilityOverride = undefined;
    }
    this.latestSnapshot = snapshot;
    this.sendToSurface(this.panel, "zcode-status:panel-snapshot", this.panelSnapshot());
  }

  public applyConfig(config: AppConfig): void {
    this.lastAppliedConfig = config;
    if (!this.panel || this.panel.isDestroyed()) {
      return;
    }
    const display = this.displayForConfig(config);
    const { workArea } = display;
    const width = clampPanelWidth(config.panelWidth);
    const sessionRows = config.showIdle || this.latestSnapshot.sessions.length
      ? Math.max(1, this.latestSnapshot.sessions.length)
      : 0;
    const availableHeight = Math.max(PANEL_BOUNDS.height, workArea.height);
    const height = sessionRows ? panelHeightForRows(sessionRows, availableHeight) : PANEL_BOUNDS.height;
    const rawBounds = {
      x: config.corner.includes("right")
        ? workArea.x + workArea.width - width - config.marginX
        : workArea.x + config.marginX,
      y: config.corner.includes("bottom")
        ? workArea.y + workArea.height - height - config.marginY
        : workArea.y + config.marginY,
    };
    const origin = clampOrigin(workArea, { width, height }, rawBounds.x, rawBounds.y);
    const bounds = this.userPanelMovePending
      ? { ...this.panel.getBounds(), width, height }
      : { ...origin, width, height };
    this.lastAppliedPanelBounds = bounds;
    if (!this.sameBounds(this.panel.getBounds(), bounds)) {
      this.panel.setBounds(bounds);
    }
    this.panel.setOpacity(config.opacity / 100);
    if (shouldShowPanel(config.showIdle, this.latestSnapshot.sessions.length > 0, this.panelVisibilityOverride)) {
      this.revealPanel();
    } else {
      this.panel.hide();
    }
    this.restoreZOrder();
  }

  public async showAttention(
    content = defaultAttention,
    durationMs = 1800,
    placement: "center" | "corner" | "edge" = "center",
  ): Promise<void> {
    this.attentionContent = content;
    this.attentionSessionId = content.sessionId;
    this.attentionPlacement = placement;
    this.clearAttentionTimer();
    const generation = this.attentionGeneration + 1;
    this.attentionGeneration = generation;
    if (this.attention && !this.attention.isDestroyed()) {
      this.attention.close();
    }

    const panelBounds = this.panel && !this.panel.isDestroyed() ? this.panel.getBounds() : undefined;
    const display = panelBounds ? screen.getDisplayMatching(panelBounds) : screen.getPrimaryDisplay();
    const presentation: AttentionPresentation = placement === "edge" ? "edge" : "card";
    const bounds = placement === "edge"
      ? display.bounds
      : { ...attentionWindowContract, ...attentionOrigin(display.workArea, ATTENTION_BOUNDS, placement, panelBounds) };
    const window = new BrowserWindow({
      ...attentionWindowContract,
      ...bounds,
      show: false,
      resizable: false,
      hasShadow: presentation === "card",
      backgroundColor: "#00000000",
      webPreferences: {
        preload: preloadPath,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        webSecurity: true,
      },
    });

    const settingsWindow = this.settings;
    const restoreSettingsTopmost = Boolean(
      settingsWindow && !settingsWindow.isDestroyed() && settingsWindow.isVisible(),
    );
    if (restoreSettingsTopmost) {
      settingsWindow?.setAlwaysOnTop(false);
    }

    preventExternalNavigation(window);
    window.setAlwaysOnTop(true, "floating");
    window.on("closed", () => {
      if (restoreSettingsTopmost && settingsWindow && !settingsWindow.isDestroyed()) {
        settingsWindow.setAlwaysOnTop(true, "floating");
      }
      this.restoreZOrder();
      if (this.attention === window && this.attentionGeneration === generation) {
        this.attention = undefined;
        this.attentionSessionId = undefined;
        this.attentionPlacement = undefined;
        this.clearAttentionTimer();
      }
    });
    this.attention = window;
    try {
      await this.loadSurface(window, "attention", presentation);
    } catch (error) {
      this.cleanupFailedAttention(window, generation);
      throw error;
    }
    if (!window.isDestroyed() && this.attention === window && this.attentionGeneration === generation) {
      window.showInactive();
      window.setIgnoreMouseEvents(true, { forward: true });
      this.restoreZOrder();
      this.attentionTimer = setTimeout(() => {
        if (this.attention === window && !window.isDestroyed()) {
          window.close();
        }
      }, durationMs);
    }
  }

  public closeAttention(sessionId?: string): void {
    if (sessionId && this.attentionSessionId !== sessionId) {
      return;
    }
    this.attentionGeneration += 1;
    this.clearAttentionTimer();
    const window = this.attention;
    this.attention = undefined;
    this.attentionSessionId = undefined;
    this.attentionPlacement = undefined;
    if (window && !window.isDestroyed()) {
      window.close();
    }
  }

  public destroyAll(): void {
    this.closeAttention();
    this.clearPanelMoveTimer();
    this.clearDisplayLayoutTimer();
    this.unsubscribeFromDisplayLayoutChanges();
    this.userPanelMoveActive = false;
    this.userPanelMovePending = false;
    this.settingsDrag = undefined;
    for (const window of [this.settings, this.panel]) {
      if (window && !window.isDestroyed()) {
        window.destroy();
      }
    }
    this.settings = undefined;
    this.panel = undefined;
  }

  private restoreZOrder(): void {
    const panel = this.panel;
    const settings = this.settings;
    const attention = this.attention;
    const visibleWindows = [panel, settings, attention].filter((window): window is BrowserWindow => (
      Boolean(window && !window.isDestroyed() && window.isVisible())
    ));
    if (visibleWindows.length < 2) {
      return;
    }
    if (panel && !panel.isDestroyed() && panel.isVisible()) {
      panel.moveTop();
    }
    if (settings && !settings.isDestroyed() && settings.isVisible()) {
      settings.setAlwaysOnTop(true, "floating");
      settings.moveTop();
    }
    if (attention && !attention.isDestroyed() && attention.isVisible()) {
      attention.setAlwaysOnTop(true, "floating");
      attention.moveTop();
    }
  }

  private cleanupFailedPanel(window: BrowserWindow): void {
    if (this.panel !== window) {
      return;
    }
    this.panel = undefined;
    this.clearPanelMoveTimer();
    this.clearDisplayLayoutTimer();
    this.unsubscribeFromDisplayLayoutChanges();
    this.userPanelMoveActive = false;
    this.userPanelMovePending = false;
    if (!window.isDestroyed()) {
      window.destroy();
    }
  }

  private cleanupFailedSettings(window: BrowserWindow): void {
    if (this.settings === window) {
      this.settings = undefined;
      this.settingsDrag = undefined;
    }
    if (!window.isDestroyed()) {
      window.destroy();
    }
  }

  private cleanupFailedAttention(window: BrowserWindow, generation: number): void {
    if (this.attention === window && this.attentionGeneration === generation) {
      this.attention = undefined;
      this.attentionSessionId = undefined;
      this.attentionPlacement = undefined;
      this.clearAttentionTimer();
    }
    if (!window.isDestroyed()) {
      window.destroy();
    }
  }

  private revealPanel(): void {
    const window = this.panel;
    if (!window || window.isDestroyed()) {
      return;
    }
    window.setAlwaysOnTop(true, "floating");
    window.showInactive();
    window.moveTop();
  }

  private panelSnapshot(): PanelSnapshot {
    if (this.panelVisibilityOverride === "visible" && this.latestSnapshot.sessions.length === 0) {
      return { ...this.latestSnapshot, showIdle: true };
    }
    return this.latestSnapshot;
  }

  private displayForConfig(config: AppConfig) {
    return screen.getAllDisplays().find((display) => String(display.id) === config.displayId)
      ?? screen.getPrimaryDisplay();
  }

  private beginUserPanelMove(window: BrowserWindow): void {
    if (window !== this.panel || window.isDestroyed()) {
      return;
    }
    this.userPanelMoveActive = true;
    this.clearPanelMoveTimer();
  }

  private handlePanelMove(window: BrowserWindow): void {
    if (window !== this.panel || window.isDestroyed()) {
      return;
    }
    if (!this.userPanelMoveActive) {
      this.lastAppliedPanelBounds = window.getBounds();
      return;
    }
    this.userPanelMovePending = true;
    this.clearPanelMoveTimer();
    this.panelMoveTimer = setTimeout(() => {
      this.panelMoveTimer = undefined;
      if (window !== this.panel || window.isDestroyed()) {
        return;
      }
      const finalBounds = window.getBounds();
      const display = screen.getDisplayMatching(finalBounds);
      this.userPanelMoveActive = false;
      this.userPanelMovePending = false;
      this.lastAppliedPanelBounds = finalBounds;
      this.onPanelPositionChanged?.({
        ...placementForBounds(display.workArea, finalBounds),
        displayId: String(display.id),
      });
    }, 220);
  }

  private handleDisplayLayoutChange(): void {
    this.clearPanelMoveTimer();
    this.userPanelMoveActive = false;
    this.userPanelMovePending = false;
    this.clearDisplayLayoutTimer();
    this.displayLayoutTimer = setTimeout(() => {
      this.displayLayoutTimer = undefined;
      if (this.panel && !this.panel.isDestroyed() && this.lastAppliedConfig) {
        this.applyConfig(this.lastAppliedConfig);
      }
      this.repositionSettings();
      this.repositionAttention();
    }, DISPLAY_LAYOUT_SETTLE_MS);
  }

  private repositionSettings(): void {
    const window = this.settings;
    if (!window || window.isDestroyed()) {
      return;
    }
    const panelBounds = this.panel && !this.panel.isDestroyed() ? this.panel.getBounds() : undefined;
    const display = panelBounds ? screen.getDisplayMatching(panelBounds) : screen.getPrimaryDisplay();
    const bounds = settingsBoundsForWorkArea(display.workArea);
    if (!this.sameBounds(window.getBounds(), bounds)) {
      window.setBounds(bounds);
    }
  }

  private repositionAttention(): void {
    const window = this.attention;
    const placement = this.attentionPlacement;
    if (!window || window.isDestroyed() || !placement) {
      return;
    }
    const panelBounds = this.panel && !this.panel.isDestroyed() ? this.panel.getBounds() : undefined;
    const display = panelBounds ? screen.getDisplayMatching(panelBounds) : screen.getPrimaryDisplay();
    const bounds = placement === "edge"
      ? display.bounds
      : { ...attentionWindowContract, ...attentionOrigin(display.workArea, ATTENTION_BOUNDS, placement, panelBounds) };
    if (!this.sameBounds(window.getBounds(), bounds)) {
      window.setBounds(bounds);
    }
  }

  private subscribeToDisplayLayoutChanges(): void {
    screen.on("display-metrics-changed", this.onDisplayLayoutChange);
    screen.on("display-added", this.onDisplayLayoutChange);
    screen.on("display-removed", this.onDisplayLayoutChange);
  }

  private unsubscribeFromDisplayLayoutChanges(): void {
    screen.off("display-metrics-changed", this.onDisplayLayoutChange);
    screen.off("display-added", this.onDisplayLayoutChange);
    screen.off("display-removed", this.onDisplayLayoutChange);
  }

  private sameBounds(
    first: ReturnType<BrowserWindow["getBounds"]>,
    second: ReturnType<BrowserWindow["getBounds"]>,
  ): boolean {
    return first.x === second.x
      && first.y === second.y
      && first.width === second.width
      && first.height === second.height;
  }

  private clearPanelMoveTimer(): void {
    if (this.panelMoveTimer) {
      clearTimeout(this.panelMoveTimer);
      this.panelMoveTimer = undefined;
    }
  }

  private clearDisplayLayoutTimer(): void {
    if (this.displayLayoutTimer) {
      clearTimeout(this.displayLayoutTimer);
      this.displayLayoutTimer = undefined;
    }
  }

  private clearAttentionTimer(): void {
    if (this.attentionTimer) {
      clearTimeout(this.attentionTimer);
      this.attentionTimer = undefined;
    }
  }

  private sendToSurface(window: BrowserWindow | undefined, channel: string, payload: unknown): void {
    if (window && !window.isDestroyed()) {
      window.webContents.send(channel, payload);
    }
  }

  private async loadSurface(
    window: BrowserWindow,
    surface: RendererSurface,
    presentation?: AttentionPresentation,
  ): Promise<void> {
    const developmentUrl = process.env.VITE_DEV_SERVER_URL;
    if (developmentUrl) {
      await window.loadURL(rendererUrl(developmentUrl, surface, presentation));
      return;
    }

    const url = pathToFileURL(productionRendererPath);
    url.searchParams.set("surface", surface);
    if (presentation) {
      url.searchParams.set("presentation", presentation);
    }
    await window.loadURL(url.toString());
  }
}
