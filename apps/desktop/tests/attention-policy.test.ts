import { describe, expect, it } from "vitest";
import { attentionRequestForConfig } from "../src/main/attention-policy";
import { DEFAULT_CONFIG } from "../src/shared/config";

describe("attention policy", () => {
  it.each([
    ["off", { kind: "none", durationMs: 800 }],
    ["panel-pulse", { kind: "edge", durationMs: 1800 }],
    ["corner-overlay", { kind: "overlay", durationMs: 5000, placement: "corner" }],
    ["center-overlay", { kind: "overlay", durationMs: 1800, placement: "center" }],
  ] as const)("maps %s to its visible behavior", (attentionMode, expected) => {
    const durationMs = expected.durationMs;

    expect(attentionRequestForConfig({ ...DEFAULT_CONFIG, attentionMode, attentionDurationMs: durationMs }))
      .toEqual(expected);
  });

  it("accepts an explicit duration for the shared preview path", () => {
    expect(attentionRequestForConfig(
      { ...DEFAULT_CONFIG, attentionMode: "panel-pulse", attentionDurationMs: 1800 },
      800,
    )).toEqual({ kind: "edge", durationMs: 800 });
  });
});
