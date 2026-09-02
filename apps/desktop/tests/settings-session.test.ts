import { describe, expect, it } from "vitest";
import { DEFAULT_CONFIG } from "../src/shared/config";
import { previewSettingsConfig, saveSettingsConfig } from "../src/shared/settings-session";

describe("settings session", () => {
  it("updates a preview without changing the saved source configuration", () => {
    const saved = { ...DEFAULT_CONFIG, opacity: 100, panelWidth: 380 };
    const preview = previewSettingsConfig(saved, undefined, { opacity: 60 });
    const nextPreview = previewSettingsConfig(saved, preview, { panelWidth: 520 });

    expect(saved).toMatchObject({ opacity: 100, panelWidth: 380 });
    expect(nextPreview).toMatchObject({ opacity: 60, panelWidth: 520 });
  });

  it("saves a complete draft while keeping unrelated saved settings", () => {
    const saved = { ...DEFAULT_CONFIG, corner: "top-left" as const, opacity: 100 };
    const savedDraft = saveSettingsConfig(saved, { ...saved, opacity: 55, showDuration: false });

    expect(savedDraft).toMatchObject({ corner: "top-left", opacity: 55, showDuration: false });
  });

  it("keeps attention mode and duration together across consecutive previews", () => {
    const firstPreview = previewSettingsConfig(DEFAULT_CONFIG, undefined, {
      attentionMode: "corner-overlay",
    });
    const secondPreview = previewSettingsConfig(DEFAULT_CONFIG, firstPreview, {
      attentionDurationMs: 4200,
    });
    const saved = saveSettingsConfig(DEFAULT_CONFIG, secondPreview);

    expect(secondPreview).toMatchObject({ attentionMode: "corner-overlay", attentionDurationMs: 4200 });
    expect(saved).toMatchObject({ attentionMode: "corner-overlay", attentionDurationMs: 4200 });
  });
});
