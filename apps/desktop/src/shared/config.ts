export type PanelCorner = "bottom-right" | "bottom-left" | "top-right" | "top-left";

export type AttentionMode = "off" | "panel-pulse" | "corner-overlay" | "center-overlay";

export interface AppConfig {
  readonly corner: PanelCorner;
  readonly marginX: number;
  readonly marginY: number;
  readonly displayId: string;
  readonly opacity: number;
  readonly showIdle: boolean;
  readonly showTodoProgress: boolean;
  readonly showDuration: boolean;
  readonly panelWidth: number;
  readonly doneTtlMinutes: number;
  readonly attentionMode: AttentionMode;
  readonly attentionDurationMs: number;
}

export const PANEL_WIDTH_MIN = 320;
export const PANEL_WIDTH_MAX = 640;
export const DONE_TTL_MINUTES_MIN = 1;
export const DONE_TTL_MINUTES_MAX = 30;
export const ATTENTION_DURATION_MS_MIN = 800;
export const ATTENTION_DURATION_MS_MAX = 5000;

export const DEFAULT_CONFIG: AppConfig = {
  corner: "bottom-right",
  marginX: 14,
  marginY: 52,
  displayId: "",
  opacity: 100,
  showIdle: true,
  showTodoProgress: true,
  showDuration: true,
  panelWidth: 380,
  doneTtlMinutes: 5,
  attentionMode: "center-overlay",
  attentionDurationMs: 1800,
};

const corners = new Set<PanelCorner>(["bottom-right", "bottom-left", "top-right", "top-left"]);
const attentionModes = new Set<AttentionMode>(["off", "panel-pulse", "corner-overlay", "center-overlay"]);
const legacyAttentionModes: Readonly<Record<string, AttentionMode>> = {
  panel_pulse: "panel-pulse",
  corner_overlay: "corner-overlay",
  center_overlay: "center-overlay",
};

const finiteNumber = (value: unknown, fallback: number): number => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const integerInRange = (value: unknown, fallback: number, minimum: number, maximum: number): number => {
  const parsed = Math.trunc(finiteNumber(value, fallback));
  return Math.min(maximum, Math.max(minimum, parsed));
};

const nonNegativeInteger = (value: unknown, fallback: number): number => Math.max(
  0,
  Math.trunc(finiteNumber(value, fallback)),
);

const displayIdValue = (value: unknown, fallback: string): string => {
  if (typeof value === "string") {
    return value.trim();
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(Math.trunc(value));
  }
  return fallback;
};

const booleanValue = (value: unknown, fallback: boolean): boolean => {
  if (typeof value === "boolean") {
    return value;
  }
  if (value === "1" || value === 1) {
    return true;
  }
  if (value === "0" || value === 0) {
    return false;
  }
  return fallback;
};

export type ConfigInput = { readonly [Key in keyof AppConfig]?: unknown };

export const resetPositionConfig = (config: AppConfig): AppConfig => ({
  ...config,
  corner: DEFAULT_CONFIG.corner,
  marginX: DEFAULT_CONFIG.marginX,
  marginY: DEFAULT_CONFIG.marginY,
  displayId: DEFAULT_CONFIG.displayId,
});

export const normalizeConfig = (candidate: ConfigInput = {}): AppConfig => {
  const corner = typeof candidate.corner === "string" && corners.has(candidate.corner as PanelCorner)
    ? candidate.corner as PanelCorner
    : DEFAULT_CONFIG.corner;
  const rawAttentionMode = typeof candidate.attentionMode === "string" ? candidate.attentionMode : "";
  const attentionMode = attentionModes.has(rawAttentionMode as AttentionMode)
    ? rawAttentionMode as AttentionMode
    : legacyAttentionModes[rawAttentionMode] ?? DEFAULT_CONFIG.attentionMode;

  return {
    corner,
    marginX: nonNegativeInteger(candidate.marginX, DEFAULT_CONFIG.marginX),
    marginY: nonNegativeInteger(candidate.marginY, DEFAULT_CONFIG.marginY),
    displayId: displayIdValue(candidate.displayId, DEFAULT_CONFIG.displayId),
    opacity: integerInRange(candidate.opacity, DEFAULT_CONFIG.opacity, 20, 100),
    showIdle: booleanValue(candidate.showIdle, DEFAULT_CONFIG.showIdle),
    showTodoProgress: booleanValue(candidate.showTodoProgress, DEFAULT_CONFIG.showTodoProgress),
    showDuration: booleanValue(candidate.showDuration, DEFAULT_CONFIG.showDuration),
    panelWidth: integerInRange(
      candidate.panelWidth,
      DEFAULT_CONFIG.panelWidth,
      PANEL_WIDTH_MIN,
      PANEL_WIDTH_MAX,
    ),
    doneTtlMinutes: integerInRange(
      candidate.doneTtlMinutes,
      DEFAULT_CONFIG.doneTtlMinutes,
      DONE_TTL_MINUTES_MIN,
      DONE_TTL_MINUTES_MAX,
    ),
    attentionMode,
    attentionDurationMs: integerInRange(
      candidate.attentionDurationMs,
      DEFAULT_CONFIG.attentionDurationMs,
      ATTENTION_DURATION_MS_MIN,
      ATTENTION_DURATION_MS_MAX,
    ),
  };
};
