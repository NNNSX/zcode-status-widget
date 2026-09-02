import type { AppConfig } from "../shared/config";

export interface AttentionRequest {
  readonly durationMs: number;
  readonly kind: "none" | "edge" | "overlay";
  readonly placement?: "center" | "corner";
}

export const attentionRequestForConfig = (config: AppConfig, durationMs = config.attentionDurationMs): AttentionRequest => {
  switch (config.attentionMode) {
    case "off":
      return { kind: "none", durationMs };
    case "panel-pulse":
      return { kind: "edge", durationMs };
    case "corner-overlay":
      return { kind: "overlay", durationMs, placement: "corner" };
    case "center-overlay":
      return { kind: "overlay", durationMs, placement: "center" };
  }
};
