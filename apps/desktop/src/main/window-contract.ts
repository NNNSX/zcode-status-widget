import type { PanelCorner } from "../shared/config";

export const PANEL_BORDER_HEIGHT = 2;

export const PANEL_BOUNDS = {
  width: 520,
  height: 47,
  minWidth: 320,
  maxWidth: 640,
} as const;

export const SESSION_LIST_VERTICAL_PADDING = 18;
export const SESSION_ROW_HEIGHT = 27;
export const SESSION_ROW_GAP = 3;

export const panelHeightForRows = (rowCount: number, maximumHeight = Number.POSITIVE_INFINITY): number => {
  const rows = Math.max(1, Math.trunc(rowCount));
  const contentHeight = PANEL_BORDER_HEIGHT
    + SESSION_LIST_VERTICAL_PADDING
    + (rows * SESSION_ROW_HEIGHT)
    + ((rows - 1) * SESSION_ROW_GAP);
  const cappedHeight = Math.max(PANEL_BOUNDS.height, maximumHeight);
  return Math.min(cappedHeight, Math.max(PANEL_BOUNDS.height, contentHeight));
};

export const SETTINGS_BOUNDS = {
  width: 356,
  height: 760,
} as const;

export const SETTINGS_VERTICAL_MARGIN = 32;

export const settingsHeightForWorkArea = (workAreaHeight: number): number => {
  const availableHeight = Math.max(1, Math.trunc(workAreaHeight) - SETTINGS_VERTICAL_MARGIN);
  return Math.min(SETTINGS_BOUNDS.height, availableHeight);
};

export const settingsBoundsForWorkArea = (workArea: ScreenBounds): ScreenBounds => {
  const width = Math.min(SETTINGS_BOUNDS.width, Math.max(1, workArea.width));
  const height = settingsHeightForWorkArea(workArea.height);
  const origin = clampOrigin(workArea, { width, height }, workArea.x + workArea.width - width - 16, workArea.y + 16);
  return { ...origin, width, height };
};

export const ATTENTION_BOUNDS = {
  width: 304,
  height: 122,
} as const;

export type PanelVisibilityOverride = "visible" | "hidden" | undefined;

export interface ScreenBounds {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export const shouldShowPanel = (
  showIdle: boolean,
  hasSessions: boolean,
  override: PanelVisibilityOverride,
): boolean => override === "visible" || (override !== "hidden" && (showIdle || hasSessions));

export const clampOrigin = (
  workArea: ScreenBounds,
  bounds: Pick<ScreenBounds, "width" | "height">,
  x: number,
  y: number,
): Pick<ScreenBounds, "x" | "y"> => {
  const maximumX = Math.max(workArea.x, workArea.x + workArea.width - bounds.width);
  const maximumY = Math.max(workArea.y, workArea.y + workArea.height - bounds.height);
  return {
    x: Math.max(workArea.x, Math.min(x, maximumX)),
    y: Math.max(workArea.y, Math.min(y, maximumY)),
  };
};

export interface PanelPlacement {
  readonly corner: PanelCorner;
  readonly marginX: number;
  readonly marginY: number;
}

export const placementForBounds = (
  workArea: ScreenBounds,
  bounds: ScreenBounds,
): PanelPlacement => {
  const leftMargin = bounds.x - workArea.x;
  const rightMargin = workArea.x + workArea.width - (bounds.x + bounds.width);
  const topMargin = bounds.y - workArea.y;
  const bottomMargin = workArea.y + workArea.height - (bounds.y + bounds.height);
  const useRight = rightMargin <= leftMargin;
  const useBottom = bottomMargin <= topMargin;
  return {
    corner: `${useBottom ? "bottom" : "top"}-${useRight ? "right" : "left"}` as PanelCorner,
    marginX: Math.max(0, Math.round(useRight ? rightMargin : leftMargin)),
    marginY: Math.max(0, Math.round(useBottom ? bottomMargin : topMargin)),
  };
};

export const attentionOrigin = (
  workArea: ScreenBounds,
  attentionBounds: Pick<ScreenBounds, "width" | "height">,
  placement: "center" | "corner",
  panelBounds?: ScreenBounds,
): Pick<ScreenBounds, "x" | "y"> => {
  const x = placement === "corner" && panelBounds
    ? panelBounds.x - attentionBounds.width - 12
    : workArea.x + Math.round((workArea.width - attentionBounds.width) / 2);
  const y = placement === "corner" && panelBounds
    ? panelBounds.y - attentionBounds.height - 12
    : workArea.y + Math.round((workArea.height - attentionBounds.height) / 2);
  return clampOrigin(workArea, attentionBounds, x, y);
};

export interface WindowContract {
  readonly width: number;
  readonly height: number;
  readonly frame: boolean;
  readonly transparent: boolean;
  readonly alwaysOnTop: boolean;
  readonly focusable: boolean;
  readonly skipTaskbar: boolean;
}

export const panelWindowContract: WindowContract = {
  width: PANEL_BOUNDS.width,
  height: PANEL_BOUNDS.height,
  frame: false,
  transparent: true,
  alwaysOnTop: true,
  focusable: false,
  skipTaskbar: true,
};

export const settingsWindowContract: WindowContract = {
  width: SETTINGS_BOUNDS.width,
  height: SETTINGS_BOUNDS.height,
  frame: false,
  transparent: true,
  alwaysOnTop: true,
  focusable: true,
  skipTaskbar: true,
};

export const attentionWindowContract: WindowContract = {
  width: ATTENTION_BOUNDS.width,
  height: ATTENTION_BOUNDS.height,
  frame: false,
  transparent: true,
  alwaysOnTop: true,
  focusable: false,
  skipTaskbar: true,
};

export const clampPanelWidth = (value: number): number => {
  const rounded = Math.round(value);
  return Math.min(PANEL_BOUNDS.maxWidth, Math.max(PANEL_BOUNDS.minWidth, rounded));
};

export type RendererSurface = "panel" | "settings" | "attention";

export type AttentionPresentation = "card" | "edge";

export const rendererUrl = (
  baseUrl: string,
  surface: RendererSurface,
  presentation?: AttentionPresentation,
): string => {
  const url = new URL(baseUrl);
  url.searchParams.set("surface", surface);
  if (presentation) {
    url.searchParams.set("presentation", presentation);
  }
  return url.toString();
};
