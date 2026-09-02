import { describe, expect, it } from "vitest";
import { parseRegistryValues, serializeRegistryValue } from "../src/main/settings-registry";
import { normalizeConfig } from "../src/shared/config";

describe("settings registry compatibility", () => {
  it("parses legacy Windows registry output and migrates attention values", () => {
    const values = parseRegistryValues([
      "HKEY_CURRENT_USER\\Software\\ZCodeStatusLight",
      "    show_idle    REG_SZ    1",
      "    panel_width    REG_SZ    380",
      "    display_id    REG_SZ    42",
      "    attention_mode    REG_SZ    center_overlay",
      "    attention_duration_ms    REG_SZ    1800",
    ].join("\r\n"));

    expect(normalizeConfig({
      showIdle: values.show_idle,
      panelWidth: values.panel_width,
      displayId: values.display_id,
      attentionMode: values.attention_mode,
      attentionDurationMs: values.attention_duration_ms,
    })).toMatchObject({
      showIdle: true,
      panelWidth: 380,
      displayId: "42",
      attentionMode: "center-overlay",
      attentionDurationMs: 1800,
    });
  });

  it("writes Electron settings in the Python-compatible registry representation", () => {
    expect(serializeRegistryValue("attentionMode", "corner-overlay")).toBe("corner_overlay");
    expect(serializeRegistryValue("showDuration", false)).toBe("0");
    expect(serializeRegistryValue("displayId", "42")).toBe("42");
    expect(serializeRegistryValue("panelWidth", 420)).toBe("420");
  });
});
